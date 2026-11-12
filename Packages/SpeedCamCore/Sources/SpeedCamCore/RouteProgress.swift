import Foundation

/// 路線上的一個步驟（由 App 從 MKRoute.Step 轉換而來）。
/// 依 MapKit 的實際行為，`instruction` 描述的是「這一步走完時」要做的動作，
/// 例如距離 982 m 的「右轉進入環河北路」是開 982 m 之後右轉。
/// 實測 84 條台灣路線：指示裡的左右轉和步驟終點的實際轉向有 96% 相符，和步驟起點只有 45%。
public struct RouteStepInfo: Equatable, Sendable {
    public var instruction: String
    /// 這一步的長度。App 用折線實際長度，比 Apple 回報的距離準（累積誤差最多 2.3%）。
    public var distance: Double
    public var shortInstruction: String?
    public var hintID: String?

    public init(instruction: String, distance: Double, shortInstruction: String? = nil, hintID: String? = nil) {
        self.instruction = instruction
        self.distance = distance
        self.shortInstruction = shortInstruction
        self.hintID = hintID
    }
}

/// 導航事件。
public enum RouteEvent: Equatable, Sendable {
    /// 播報下一個轉彎。distance 為播報門檻（1000、500、200），nil 表示「現在」。
    case announce(stepIndex: Int, instruction: String, distance: Int?)
    /// 偏離路線（需要重新規劃）。還沒回到路線上就會每隔一段時間再發一次。
    case offRoute
    /// 抵達目的地。
    case arrived
}

/// 導航進度（畫面與 Live Activity 顯示用）。
public struct RouteProgress: Equatable, Sendable {
    /// 下一個要執行的步驟（它的 instruction 就是下一個轉彎指示）。
    public var nextStepIndex: Int
    public var nextInstruction: String
    public var distanceToNextManeuver: Double
    public var distanceRemaining: Double
    public var distanceFromRoute: Double
    /// 已經判定偏離路線：下一步的指示不再正確，畫面改顯示重新規劃中。
    public var isOffRoute: Bool
    public var shortInstruction: String?
    public var hintID: String?

    public var maneuverText: String { shortInstruction ?? ManeuverText.short(nextInstruction) }

    public init(nextStepIndex: Int, nextInstruction: String, distanceToNextManeuver: Double,
                distanceRemaining: Double, distanceFromRoute: Double, isOffRoute: Bool = false,
                shortInstruction: String? = nil, hintID: String? = nil) {
        self.nextStepIndex = nextStepIndex
        self.nextInstruction = nextInstruction
        self.distanceToNextManeuver = distanceToNextManeuver
        self.distanceRemaining = distanceRemaining
        self.distanceFromRoute = distanceFromRoute
        self.isOffRoute = isOffRoute
        self.shortInstruction = shortInstruction
        self.hintID = hintID
    }
}

public struct RouteProgressResult: Equatable, Sendable {
    public var events: [RouteEvent]
    public var progress: RouteProgress?
}

/// 逐向導航的進度追蹤：把目前位置投影到路線上，算出走到哪一步、離下一個轉彎多遠，
/// 在 500 m、200 m 與轉彎點各播報一次（車速快時再加 1 km），並偵測偏離路線。
public final class RouteProgressTracker {
    public let polyline: [GeoPoint]
    public let steps: [RouteStepInfo]

    /// 偏離路線的距離門檻（公尺）。
    public var offRouteDistance: Double = 50
    /// 偏離持續多久才算偏離（秒）。
    public var offRouteDuration: TimeInterval = 5
    /// 方向和路線明顯不同時（路口轉錯）：離開這麼遠、持續這麼久就算偏離，不用等到上面的門檻。
    public var wrongWayDistance: Double = 30
    public var wrongWayDuration: TimeInterval = 3
    public var wrongWayAngle: Double = 50
    /// 低於這個車速（km/h）時 GPS 方向不可靠，不用方向判斷。
    public var wrongWayMinimumSpeed: Double = 15
    /// 還沒回到路線上時，每隔多久再要求重新規劃一次（上一次可能失敗，或新路線又走錯）。
    public var offRouteRepeatInterval: TimeInterval = 15
    /// 距離終點多近算抵達（公尺）。
    public var arrivalDistance: Double = 30
    /// 播報門檻（公尺），由遠到近；最後再加一次「現在」。
    public var announceThresholds: [Int] = [500, 200]
    /// 車速達到這個值（km/h）時，多一次 1 km 的播報（快速道路來不及切車道）。
    public var longAnnounceSpeed: Double = 70
    public var longAnnounceDistance: Int = 1_000
    public var announceNowDistance: Double = 40
    /// 「現在」要提早幾秒念：車速快時 40 m 只有一秒多，念完已經過了。
    public var announceNowSeconds: Double = 3

    /// 每個折線點的累積距離。
    private let cumulative: [Double]
    /// 每一步「結束時」在路線上的累積距離（已依折線總長等比例修正）。
    private let stepEnds: [Double]
    private var lastSegment = 0
    private var offRouteSince: Date?
    private var lastOffRouteEvent: Date?
    private var announced: [Int: Set<Int>] = [:]   // stepIndex -> 已播過的門檻（-1 代表「現在」）
    private var arrived = false

    public init(polyline: [GeoPoint], steps: [RouteStepInfo]) {
        self.polyline = polyline
        self.steps = steps
        var cum: [Double] = [0]
        if polyline.count > 1 {
            for i in 1..<polyline.count {
                cum.append(cum[i - 1] + GeoMath.distance(polyline[i - 1], polyline[i]))
            }
        }
        self.cumulative = cum
        let total = cum.last ?? 0
        let stepSum = steps.reduce(0) { $0 + max(0, $1.distance) }
        let scale = stepSum > 0 ? total / stepSum : 0
        var ends: [Double] = []
        var acc = 0.0
        for s in steps {
            acc += max(0, s.distance) * scale
            ends.append(acc)
        }
        if !ends.isEmpty { ends[ends.count - 1] = total }
        self.stepEnds = ends
    }

    public var totalDistance: Double { cumulative.last ?? 0 }

    public func process(_ fix: VehicleFix) -> RouteProgressResult {
        guard polyline.count > 1 else { return RouteProgressResult(events: [], progress: nil) }
        var events: [RouteEvent] = []

        let (segment, projection) = locate(fix.point)
        lastSegment = segment
        let along = cumulative[segment] + projection.t * (cumulative[segment + 1] - cumulative[segment])
        let remaining = max(0, totalDistance - along)

        let isOffRoute = updateOffRoute(fix: fix, segment: segment, distance: projection.distance, events: &events)

        // 抵達判斷
        if !arrived && remaining <= arrivalDistance {
            arrived = true
            events.append(.arrived)
        }

        // 下一個動作：還沒走完、而且有指示文字的第一步（第 0 步通常是空的）。
        let nextIndex = steps.indices.first { stepEnds[$0] > along + 0.5 && !steps[$0].instruction.isEmpty }
            ?? steps.indices.last { !steps[$0].instruction.isEmpty }
            ?? 0
        let distToManeuver = steps.isEmpty ? remaining : max(0, stepEnds[nextIndex] - along)
        let nextInstruction = steps.isEmpty ? "" : steps[nextIndex].instruction

        if !arrived && !isOffRoute && !steps.isEmpty {
            announceIfNeeded(stepIndex: nextIndex, instruction: nextInstruction,
                             distance: distToManeuver, speedMps: fix.speedMps, events: &events)
        }

        let progress = RouteProgress(nextStepIndex: nextIndex, nextInstruction: nextInstruction,
                                     distanceToNextManeuver: distToManeuver,
                                     distanceRemaining: remaining,
                                     distanceFromRoute: projection.distance,
                                     isOffRoute: isOffRoute,
                                     shortInstruction: steps.isEmpty ? nil : steps[nextIndex].shortInstruction,
                                     hintID: steps.isEmpty ? nil : steps[nextIndex].hintID)
        return RouteProgressResult(events: events, progress: progress)
    }

    /// 重新規劃後若仍要沿用同一個 tracker 物件，可呼叫此方法清除播報狀態。
    public func resetAnnouncements() {
        announced.removeAll()
        offRouteSince = nil
        lastOffRouteEvent = nil
    }

    // MARK: - 內部

    /// 回傳目前是不是已經判定偏離路線。
    private func updateOffRoute(fix: VehicleFix, segment: Int, distance: Double,
                                events: inout [RouteEvent]) -> Bool {
        let far = distance > offRouteDistance + max(0, fix.horizontalAccuracy - 10)
        var wrongWay = false
        if let course = fix.course, course >= 0, fix.speedKmh >= wrongWayMinimumSpeed, fix.horizontalAccuracy <= 30,
           distance > wrongWayDistance {
            let routeBearing = GeoMath.bearing(from: polyline[segment], to: polyline[segment + 1])
            wrongWay = GeoMath.angleDifference(course, routeBearing) >= wrongWayAngle
        }
        guard far || wrongWay else {
            offRouteSince = nil
            lastOffRouteEvent = nil
            return false
        }
        if offRouteSince == nil { offRouteSince = fix.timestamp }
        let elapsed = fix.timestamp.timeIntervalSince(offRouteSince ?? fix.timestamp)
        guard elapsed >= (wrongWay ? wrongWayDuration : offRouteDuration) else {
            return lastOffRouteEvent != nil
        }
        if let last = lastOffRouteEvent {
            if fix.timestamp.timeIntervalSince(last) >= offRouteRepeatInterval {
                lastOffRouteEvent = fix.timestamp
                events.append(.offRoute)
            }
        } else {
            lastOffRouteEvent = fix.timestamp
            events.append(.offRoute)
        }
        return true
    }

    private func announceIfNeeded(stepIndex: Int, instruction: String, distance: Double, speedMps: Double,
                                  events: inout [RouteEvent]) {
        guard !instruction.isEmpty else { return }
        var done = announced[stepIndex] ?? []
        if distance <= max(announceNowDistance, speedMps * announceNowSeconds) {
            if !done.contains(-1) {
                done.insert(-1)
                // 已經播過「現在」就把較遠的門檻也標記掉，避免倒序播報。
                for t in announceThresholds + [longAnnounceDistance] { done.insert(t) }
                events.append(.announce(stepIndex: stepIndex, instruction: instruction, distance: nil))
            }
        } else {
            let fast = SpeedUnit.kmh(fromMps: speedMps) >= longAnnounceSpeed
            let thresholds = fast ? [longAnnounceDistance] + announceThresholds : announceThresholds
            // 找出目前距離落在哪個門檻內（最小的那個），只播一次。
            let eligible = thresholds.filter { Double($0) >= distance }
            if let t = eligible.min(), !done.contains(t) {
                for larger in thresholds where larger >= t { done.insert(larger) }
                // 剛轉完彎就要再轉時，實際距離可能比門檻短很多：改念實際距離（取到 10 公尺）。
                let spoken = distance >= Double(t) - 30 ? t : max(10, Int((distance / 10).rounded()) * 10)
                events.append(.announce(stepIndex: stepIndex, instruction: instruction, distance: spoken))
            }
        }
        announced[stepIndex] = done
    }

    /// 找出最接近的路段：先在上一次位置附近搜尋，找不到合理結果再全路線搜尋。
    private func locate(_ p: GeoPoint) -> (Int, GeoMath.SegmentProjection) {
        let segCount = polyline.count - 1
        func search(_ range: ClosedRange<Int>) -> (Int, GeoMath.SegmentProjection) {
            var best = range.lowerBound
            var bestProj = GeoMath.project(p, ontoSegment: polyline[best], polyline[best + 1])
            for i in range where i != range.lowerBound {
                let proj = GeoMath.project(p, ontoSegment: polyline[i], polyline[i + 1])
                if proj.distance < bestProj.distance {
                    best = i
                    bestProj = proj
                }
            }
            return (best, bestProj)
        }
        let lo = max(0, lastSegment - 5)
        let hi = min(segCount - 1, lastSegment + 60)
        let local = search(lo...hi)
        if local.1.distance <= offRouteDistance { return local }
        let global = search(0...(segCount - 1))
        return global.1.distance < local.1.distance ? global : local
    }
}

/// 把 Apple 的導航指示縮短成「動作＋路名」，給 CarPlay、鎖定畫面和橫幅用。語音仍然念完整的句子。
/// 例如「靠右行駛上五股楊梅高架，朝桃園機場、中壢前進」→「靠右 上五股楊梅高架」，
/// 「從95A號出口下交流道，朝竹東、新竹前進」→「下交流道 95A出口」。
public enum ManeuverText {
    public static func short(_ instruction: String) -> String {
        let text = instruction.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return text }
        guard text.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) else {
            return shortEnglish(text)
        }

        var clauses = text.components(separatedBy: "，").filter { !$0.isEmpty }
        // 「在圓環，右轉進入…」：圓環和後面的動作合起來說
        var prefix = ""
        if clauses.count > 1, clauses[0] == "在圓環" {
            prefix = "圓環"
            clauses.removeFirst()
        }
        guard let first = clauses.first else { return text }
        let rest = Array(clauses.dropFirst())
        let hint = target(in: rest)

        // 目的地、停車這類本來就短，不用處理
        if first.hasPrefix("目的地在你的") { return first.replacingOccurrences(of: "你的", with: "") }

        // 下交流道
        if let range = first.range(of: "下交流道") {
            let after = String(first[range.upperBound...])
            var action = "下交流道"
            if first.hasPrefix("從"), let exit = first.range(of: "號出口") {
                let number = first[first.index(after: first.startIndex)..<exit.lowerBound]
                    .split(separator: " ").first.map(String.init) ?? ""
                let tail = roadPart(after) ?? hint
                // 下交流道直接接另一條路時，路名比「下交流道」重要
                return after.isEmpty ? "下交流道 \(number)出口" : "\(number)出口 \(tail ?? "下交流道")"
            }
            if first.hasPrefix("在左側") { action = "左側下交流道" }
            if first.hasPrefix("在右側") { action = "右側下交流道" }
            return join(action, roadPart(after) ?? hint)
        }

        // 圓環
        if let exit = first.range(of: "個出口離開圓環"), first.hasPrefix("從第") {
            let number = first[first.index(first.startIndex, offsetBy: 2)..<exit.lowerBound]
            return join("圓環第\(number)出口", hint)
        }
        if first.contains("離開圓環") { return join("離開圓環", hint) }

        // 繼續往前
        if first.hasPrefix("繼續往前走") { return prefix + "直行" }
        if first.hasPrefix("繼續往"), first.hasSuffix("前進") {
            let road = first.dropFirst(3).dropLast(2)
            return join(prefix + "直行", String(road))
        }
        if first.hasPrefix("繼續沿著"), first.hasSuffix("前進") {
            let road = first.dropFirst(4).dropLast(2)
            return join(prefix + "直行", String(road))
        }

        // 迴轉：「在大同路二段41巷迴轉」
        if first.hasPrefix("在"), first.hasSuffix("迴轉") {
            return join("迴轉", String(first.dropFirst().dropLast(2)))
        }

        // 左右轉、靠左靠右
        let actions: [(String, String)] = [
            ("稍向右轉", "靠右"), ("稍向左轉", "靠左"),
            ("靠右行駛", "靠右"), ("靠左行駛", "靠左"),
            ("向右急轉", "右轉"), ("向左急轉", "左轉"),
            ("右轉", "右轉"), ("左轉", "左轉"),
        ]
        for (words, action) in actions where first.hasPrefix(words) {
            let after = String(first.dropFirst(words.count))
            return join(prefix + action, roadPart(after) ?? hint)
        }

        return prefix.isEmpty ? join(first, nil) : prefix + first
    }

    private static func join(_ action: String, _ target: String?) -> String {
        guard let target, !target.isEmpty else { return action }
        return "\(action) \(target)"
    }

    /// 「進入環河北路」→「環河北路」；「上國1」→「上國1」（上下交流道要留「上」字）。
    private static func roadPart(_ text: String) -> String? {
        if text.hasPrefix("進入") { return String(text.dropFirst(2)) }
        if text.hasPrefix("上") { return text }
        return nil
    }

    /// 從後面的子句找目標：進入的路名、走的橋，或第一個前往的地點。
    private static func target(in clauses: [String]) -> String? {
        for clause in clauses {
            if clause.hasPrefix("進入") { return String(clause.dropFirst(2)) }
            if clause.hasPrefix("走") {
                return clause.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "()（）"))
            }
        }
        for clause in clauses where clause.hasPrefix("朝") && clause.hasSuffix("前進") {
            let places = clause.dropFirst().dropLast(2)
            if let place = places.components(separatedBy: "、").first, !place.isEmpty {
                return "往\(place)"
            }
        }
        return nil
    }

    private static func shortEnglish(_ text: String) -> String {
        var result = text
        if let range = result.range(of: " toward ") { result = String(result[..<range.lowerBound]) }
        if result.hasPrefix("Turn ") { result = String(result.dropFirst(5)) }
        guard let first = result.first else { return result }
        return first.uppercased() + result.dropFirst()
    }
}
