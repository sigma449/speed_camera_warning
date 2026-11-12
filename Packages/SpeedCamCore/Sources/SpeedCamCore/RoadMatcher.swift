import Foundation

/// App 內建的道路線形（`SpeedCam/Resources/road_lines.json`，由 `data-pipeline/build_road_lines.py` 產生）。
public struct RoadLineData: Decodable, Sendable {
    public var generatedAt: String
    public var attribution: String
    /// 國道主線（不含匝道：快速道路常和國道共用交流道，算進去會誤判）。
    public var freeways: [[GeoPoint]]
    /// Apple 不算 highway、但不是平面道路的高架和快速道路（白牌不走）。
    public var whitePlateRestricted: [[GeoPoint]]
    /// 有名稱的主線；國道另帶編號，供指示校正與資料稽核使用。
    public var namedRoads: [NamedRoadLine]

    private enum CodingKeys: String, CodingKey {
        case generatedAt, attribution, freeways, whitePlateRestricted, namedRoads
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decode(String.self, forKey: .generatedAt)
        attribution = try c.decode(String.self, forKey: .attribution)
        freeways = Self.lines(try c.decode([[[Double]]].self, forKey: .freeways))
        whitePlateRestricted = Self.lines(try c.decode([[[Double]]].self, forKey: .whitePlateRestricted))
        namedRoads = try c.decodeIfPresent([NamedRoadLine].self, forKey: .namedRoads) ?? []
    }

    public static func decode(from data: Data) throws -> RoadLineData {
        try JSONDecoder().decode(RoadLineData.self, from: data)
    }

    fileprivate static func lines(_ raw: [[[Double]]]) -> [[GeoPoint]] {
        raw.map { line in
            line.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[0], lon: $0[1]) : nil }
        }
    }
}

public struct NamedRoadLine: Decodable, Sendable {
    public var name: String
    public var freewayRef: String?
    public var lines: [[GeoPoint]]

    public init(name: String, freewayRef: String? = nil, lines: [[GeoPoint]]) {
        self.name = name
        self.freewayRef = freewayRef
        self.lines = lines
    }

    private enum CodingKeys: String, CodingKey { case name, freewayRef, lines }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        freewayRef = try c.decodeIfPresent(String.self, forKey: .freewayRef)
        lines = RoadLineData.lines(try c.decode([[[Double]]].self, forKey: .lines))
    }
}

/// 一條路線有多少長度疊在某組道路上。
public struct RoadOverlap: Equatable, Sendable {
    /// 合計長度（公尺）。
    public var total: Double
    /// 最長連續一段（公尺），包含貼著道路旁邊走的情況。
    public var longestRun: Double
    /// 真的走在上面的最長連續一段（公尺）：這一段和線形的距離中位數在 `RoadMatcher.closeOffset` 以內。
    /// 判斷有沒有走這條路要看這個，平行的側道也可能連續幾公里都在 30 m 內（例如宜蘭的縣道 191 和國 5）。
    public var longestCloseRun: Double

    public init(total: Double = 0, longestRun: Double = 0, longestCloseRun: Double = 0) {
        self.total = total
        self.longestRun = longestRun
        self.longestCloseRun = longestCloseRun
    }
}

/// 比對路線座標和道路線形。
///
/// 只比平面座標，分不出高架和正下方的平面道路；這點由使用的一方處理（見 `RouteRules`）。
public struct RoadMatcher: Sendable {
    /// 路線離線形多遠以內算在附近。雙向車道各有一條線，Apple 和 OSM 的座標也有幾公尺的差距。
    static let maxDistance = 30.0
    /// 連續一段的距離中位數在這以內才算真的走在上面。
    /// 2026-11-06 實測：真的走國道時，每一段的中位數最多 6.1 m；平行的道路大多超過 10 m，只有一段 7.7 m。
    /// 誤判成國道只是多排除一條路線，放過真的國道則會把機車帶上去，所以取偏大的值。
    public static let closeOffset = 10.0
    /// 方向要差不多。橫越國道的道路會差很多；不分順逆向，因為有些道路只畫成一條線。
    static let maxAngle = 35.0
    /// 路線每隔多遠檢查一次。
    static let sampleSpacing = 25.0
    /// 路線的點至少隔這麼遠才算方向，太近的兩點算出來的方向不穩定。
    static let routePointSpacing = 50.0
    /// 中斷超過這個距離，連續長度就重新計算。
    static let maxGap = 100.0
    /// 格子約 100 m，要大於 `maxDistance` 才只需要看相鄰的格子。
    static let cellSize = 0.001

    private struct Segment: Sendable {
        let a: GeoPoint
        let b: GeoPoint
        let bearing: Double
    }

    private struct CellKey: Hashable, Sendable {
        let x: Int
        let y: Int

        init(_ p: GeoPoint) {
            x = Int(floor(p.lon / RoadMatcher.cellSize))
            y = Int(floor(p.lat / RoadMatcher.cellSize))
        }

        init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    private let segments: [Segment]
    private let cells: [CellKey: [Int32]]

    /// 沒有線形資料（載入失敗或是空檔案）。
    public var isEmpty: Bool { segments.isEmpty }

    public init(lines: [[GeoPoint]]) {
        var segments: [Segment] = []
        var cells: [CellKey: [Int32]] = [:]
        for line in lines where line.count >= 2 {
            for i in 1..<line.count {
                let a = line[i - 1], b = line[i]
                let length = GeoMath.distance(a, b)
                guard length > 0 else { continue }
                let index = Int32(segments.count)
                segments.append(Segment(a: a, b: b, bearing: GeoMath.bearing(from: a, to: b)))
                // 線段經過的格子。每 40 m 取一點會漏掉剛好切過角落的格子，但查詢時會看相鄰的格子。
                let steps = max(1, Int(length / 40))
                var last: CellKey?
                for s in 0...steps {
                    let key = CellKey(Self.interpolate(a, b, Double(s) / Double(steps)))
                    if key != last {
                        if cells[key]?.last != index { cells[key, default: []].append(index) }
                        last = key
                    }
                }
            }
        }
        self.segments = segments
        self.cells = cells
    }

    public func overlap(with route: [GeoPoint]) -> RoadOverlap {
        guard !isEmpty else { return RoadOverlap() }
        let points = Self.thinned(route)
        guard points.count >= 2 else { return RoadOverlap() }

        var result = RoadOverlap()
        var run = 0.0, gap = 0.0
        var offsets: [Double] = []

        func finishRun() {
            result.longestRun = max(result.longestRun, run)
            if run > result.longestCloseRun, Self.median(offsets) <= Self.closeOffset {
                result.longestCloseRun = run
            }
            run = 0
            gap = 0
            offsets.removeAll(keepingCapacity: true)
        }

        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let length = GeoMath.distance(a, b)
            guard length >= 1 else { continue }
            let bearing = GeoMath.bearing(from: a, to: b)
            let samples = max(1, Int(length / Self.sampleSpacing))
            let part = length / Double(samples)
            for s in 0..<samples {
                let p = Self.interpolate(a, b, (Double(s) + 0.5) / Double(samples))
                if let offset = nearestOffset(p, bearing: bearing) {
                    result.total += part
                    run += part + gap
                    gap = 0
                    offsets.append(offset)
                } else {
                    gap += part
                    if gap > Self.maxGap { finishRun() }
                }
            }
        }
        finishRun()
        return result
    }

    /// 方向相近的線形中最近的距離；`maxDistance` 內都沒有就回傳 nil。
    private func nearestOffset(_ p: GeoPoint, bearing: Double) -> Double? {
        let center = CellKey(p)
        var best: Double?
        for dy in -1...1 {
            for dx in -1...1 {
                guard let list = cells[CellKey(x: center.x + dx, y: center.y + dy)] else { continue }
                for index in list {
                    let segment = segments[Int(index)]
                    let angle = GeoMath.angleDifference(bearing, segment.bearing)
                    guard min(angle, 180 - angle) <= Self.maxAngle else { continue }
                    let distance = GeoMath.project(p, ontoSegment: segment.a, segment.b).distance
                    if distance <= Self.maxDistance, best == nil || distance < best! {
                        best = distance
                    }
                }
            }
        }
        return best
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .infinity }
        return values.sorted()[values.count / 2]
    }

    private static func interpolate(_ a: GeoPoint, _ b: GeoPoint, _ t: Double) -> GeoPoint {
        GeoPoint(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
    }

    private static func thinned(_ route: [GeoPoint]) -> [GeoPoint] {
        guard let first = route.first, let end = route.last, route.count > 2 else { return route }
        var out = [first]
        var last = first
        for p in route.dropFirst().dropLast() where GeoMath.distance(last, p) >= routePointSpacing {
            out.append(p)
            last = p
        }
        out.append(end)
        return out
    }
}
