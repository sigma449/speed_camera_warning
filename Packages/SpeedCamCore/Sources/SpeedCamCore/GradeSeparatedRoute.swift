import Foundation

/// 導航路線上「確定走在高架／快速道路／國道主線上」的區段，以及在這些區段要略過的平面照相點。
///
/// 只用座標分不出高架和正下方的平面道路，所以兩個證據都要有才算在上面：
/// 1. Apple 指示明說「上○○高架／快速道路／高速公路／國道」，或上一段已確定在上面、而這次的動作不是下去或轉彎；
/// 2. 這一步的路形確實疊在內建的高架／快速道路／國道主線（`road_lines.json`）上。
///
/// 在這些區段上，正下方平面路口的科技執法、闖紅燈、聲音照相不會發生在駕駛身上（2026-11-22 使用者在建國高架實測，
/// 長春路到和平東路的平面路口一路報）。測速類（含平面測速）、移動測速熱點、高架上的照相點照舊提醒：
/// 判斷錯了最多是少報非測速提醒，不會漏報測速。巡航（沒有導航）沒有路線可依，不略過。
public struct GradeSeparatedRoute: Sendable {
    public struct Segment: Equatable, Sendable {
        /// 沿路線的起訖距離（公尺）。
        public var start: Double
        public var end: Double
        /// 這一段要略過的照相點。
        public var cameraIDs: Set<String>

        public init(start: Double, end: Double, cameraIDs: Set<String>) {
            self.start = start
            self.end = end
            self.cameraIDs = cameraIDs
        }
    }

    public let segments: [Segment]

    public static let none = GradeSeparatedRoute(segments: [])

    /// 照相點離這一段路線多近算在正下方（高架寬度＋Apple／官方座標誤差）。
    public static let cameraRadius = 40.0
    /// 這一步至少要有這麼長真的疊在主線上（短於 600 m 的步驟改看比例）。
    static let minimumCloseRun = 300.0
    /// 這一步至少要有這個比例落在主線 30 m 內（上下匝道本身不在主線線形裡）。
    static let minimumOverlapRatio = 0.6

    public init(segments: [Segment]) {
        self.segments = segments
    }

    /// polyline：整條導航折線；steps：Apple 原始步驟（長度依折線等比例換算，和 `RouteProgressTracker` 相同）。
    /// roads：高架／快速道路／國道主線的線形。
    public init(polyline: [GeoPoint], steps: [RouteStepInfo], roads: RoadMatcher, cameras: SpatialIndex) {
        guard polyline.count >= 2, steps.count >= 2, !roads.isEmpty else {
            self.init(segments: [])
            return
        }
        let total = GeoMath.length(of: polyline)
        let stepSum = steps.reduce(0) { $0 + max(0, $1.distance) }
        guard total > 0, stepSum > 0 else {
            self.init(segments: [])
            return
        }
        let scale = total / stepSum
        var ends: [Double] = []
        var acc = 0.0
        for step in steps {
            acc += max(0, step.distance) * scale
            ends.append(acc)
        }
        ends[ends.count - 1] = total

        var onTop = [Bool](repeating: false, count: steps.count)
        var result: [Segment] = []
        for k in 1..<steps.count {
            let start = ends[k - 1], end = ends[k]
            let previous = steps[k - 1].instruction
            let entered = Self.isEntry(previous) || (onTop[k - 1] && !Self.isExitOrTurn(previous))
            guard entered, end - start >= 50 else { continue }
            let path = RoadSnapping.subpath(polyline, from: start, to: end)
            let overlap = roads.overlap(with: path)
            let length = end - start
            guard overlap.longestCloseRun >= min(Self.minimumCloseRun, length * 0.5),
                  overlap.total >= length * Self.minimumOverlapRatio else { continue }
            onTop[k] = true
            let ids = Self.surfaceCameras(along: path, cameras: cameras)
            if var last = result.last, abs(last.end - start) < 1 {
                last.end = end
                last.cameraIDs.formUnion(ids)
                result[result.count - 1] = last
            } else {
                result.append(Segment(start: start, end: end, cameraIDs: ids))
            }
        }
        self.init(segments: result)
    }

    /// 目前沿路線的位置（公尺）要略過的照相點；不在高架區段上時為空。
    public func suppressedCameraIDs(along: Double) -> Set<String> {
        guard along.isFinite else { return [] }
        var ids = Set<String>()
        for segment in segments where along >= segment.start && along <= segment.end {
            ids.formUnion(segment.cameraIDs)
        }
        return ids
    }

    /// 在高架上時不會發生在駕駛身上的平面照相點：路口科技執法、闖紅燈、聲音照相，且沒有標高架。
    public static func isSurfaceOnlyAlert(_ camera: Camera) -> Bool {
        guard [.tech, .redLight, .noise].contains(camera.type), !camera.enforcesSpeed else { return false }
        if camera.level == .elevated { return false }
        return !camera.address.contains("高架")
    }

    /// 「上建國南北快速道路」「上市民大道高架道路」「上交流道往國道1號」「上高速公路」。只看同一個子句，
    /// 「右轉進入八德路，朝市民大道高架道路前進」「朝上塔悠、市民大道高架道路前進」這種方向說明不算。
    static func isEntry(_ instruction: String) -> Bool {
        instruction.range(of: #"(?<!朝)上[^，,、。；;]*(高架|快速道路|高速公路|國道)"#, options: .regularExpression) != nil
    }

    /// 下高架、出口、匝道或任何轉彎：之後不能再沿用「仍在上面」。
    static func isExitOrTurn(_ instruction: String) -> Bool {
        let words = ["下", "出口", "匝道", "駛離", "左轉", "右轉", "迴轉", "圓環", "目的地", "抵達"]
        return words.contains { instruction.contains($0) }
    }

    private static func surfaceCameras(along path: [GeoPoint], cameras: SpatialIndex) -> Set<String> {
        guard path.count >= 2 else { return [] }
        var ids = Set<String>()
        var checked = Set<String>()
        let spacing = 30.0
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i]
            let length = GeoMath.distance(a, b)
            let samples = max(1, Int(ceil(length / spacing)))
            for s in 0...samples {
                let t = Double(s) / Double(samples)
                let p = GeoPoint(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
                for (camera, _) in cameras.cameras(near: p, radius: cameraRadius + spacing) {
                    // 距離是對整段路線算的，每支照相點算一次就夠。
                    guard checked.insert(camera.id).inserted else { continue }
                    if isSurfaceOnlyAlert(camera), distance(from: camera.point, to: path) <= cameraRadius {
                        ids.insert(camera.id)
                    }
                }
            }
        }
        return ids
    }

    private static func distance(from p: GeoPoint, to path: [GeoPoint]) -> Double {
        var best = Double.infinity
        for i in 1..<path.count {
            best = min(best, GeoMath.project(p, ontoSegment: path[i - 1], path[i]).distance)
        }
        return best
    }
}
