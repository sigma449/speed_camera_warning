import Foundation

/// 路線上的一個步驟（由 App 從 MKRoute.Step 轉換而來）。
/// 依 MapKit 的慣例，`instruction` 描述的是「這一步開始時」要做的動作。
public struct RouteStepInfo: Equatable, Sendable {
    public var instruction: String
    public var distance: Double

    public init(instruction: String, distance: Double) {
        self.instruction = instruction
        self.distance = distance
    }
}

/// 導航事件。
public enum RouteEvent: Equatable, Sendable {
    /// 播報下一個轉彎。distance 為播報門檻（500、200），nil 表示「現在」。
    case announce(stepIndex: Int, instruction: String, distance: Int?)
    /// 偏離路線（需要重新規劃）。
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

    public init(nextStepIndex: Int, nextInstruction: String, distanceToNextManeuver: Double,
                distanceRemaining: Double, distanceFromRoute: Double) {
        self.nextStepIndex = nextStepIndex
        self.nextInstruction = nextInstruction
        self.distanceToNextManeuver = distanceToNextManeuver
        self.distanceRemaining = distanceRemaining
        self.distanceFromRoute = distanceFromRoute
    }
}

public struct RouteProgressResult: Equatable, Sendable {
    public var events: [RouteEvent]
    public var progress: RouteProgress?
}

/// 逐向導航的進度追蹤：把目前位置投影到路線上，算出走到哪一步、離下一個轉彎多遠，
/// 在 500 m、200 m 與轉彎點各播報一次，並偵測偏離路線。
public final class RouteProgressTracker {
    public let polyline: [GeoPoint]
    public let steps: [RouteStepInfo]

    /// 偏離路線的距離門檻（公尺）。
    public var offRouteDistance: Double = 50
    /// 偏離持續多久才算偏離（秒）。
    public var offRouteDuration: TimeInterval = 5
    /// 距離終點多近算抵達（公尺）。
    public var arrivalDistance: Double = 30
    /// 播報門檻（公尺），由遠到近；最後再加一次「現在」。
    public var announceThresholds: [Int] = [500, 200]
    public var announceNowDistance: Double = 40

    /// 每個折線點的累積距離。
    private let cumulative: [Double]
    /// 每一步「結束時」在路線上的累積距離（已依折線總長等比例修正）。
    private let stepEnds: [Double]
    private var lastSegment = 0
    private var offRouteSince: Date?
    private var offRouteReported = false
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

        // 偏離路線判斷
        if projection.distance > offRouteDistance + max(0, fix.horizontalAccuracy - 10) {
            if offRouteSince == nil { offRouteSince = fix.timestamp }
            if let since = offRouteSince, !offRouteReported,
               fix.timestamp.timeIntervalSince(since) >= offRouteDuration {
                offRouteReported = true
                events.append(.offRoute)
            }
        } else {
            offRouteSince = nil
            offRouteReported = false
        }

        // 抵達判斷
        if !arrived && remaining <= arrivalDistance {
            arrived = true
            events.append(.arrived)
        }

        // 目前所在的步驟：第一個「結束距離」大於目前位置的步驟。
        var current = stepEnds.firstIndex { $0 > along + 0.5 } ?? max(0, steps.count - 1)
        current = min(current, max(0, steps.count - 1))
        let nextIndex = min(current + 1, steps.count - 1)
        let distToManeuver = max(0, (stepEnds.isEmpty ? totalDistance : stepEnds[current]) - along)
        let nextInstruction = steps.isEmpty ? "" : steps[nextIndex].instruction

        // 最後一步沒有「下一個轉彎」，只剩抵達事件。
        if !arrived && !offRouteReported && nextIndex > current {
            announceIfNeeded(stepIndex: nextIndex, instruction: nextInstruction,
                             distance: distToManeuver, events: &events)
        }

        let progress = RouteProgress(nextStepIndex: nextIndex, nextInstruction: nextInstruction,
                                     distanceToNextManeuver: distToManeuver,
                                     distanceRemaining: remaining,
                                     distanceFromRoute: projection.distance)
        return RouteProgressResult(events: events, progress: progress)
    }

    /// 重新規劃後若仍要沿用同一個 tracker 物件，可呼叫此方法清除播報狀態。
    public func resetAnnouncements() {
        announced.removeAll()
        offRouteSince = nil
        offRouteReported = false
    }

    // MARK: - 內部

    private func announceIfNeeded(stepIndex: Int, instruction: String, distance: Double,
                                  events: inout [RouteEvent]) {
        guard !instruction.isEmpty else { return }
        var done = announced[stepIndex] ?? []
        if distance <= announceNowDistance {
            if !done.contains(-1) {
                done.insert(-1)
                // 已經播過「現在」就把較遠的門檻也標記掉，避免倒序播報。
                for t in announceThresholds { done.insert(t) }
                events.append(.announce(stepIndex: stepIndex, instruction: instruction, distance: nil))
            }
        } else {
            // 找出目前距離落在哪個門檻內（最小的那個），只播一次。
            let eligible = announceThresholds.filter { Double($0) >= distance }
            if let t = eligible.min(), !done.contains(t) {
                for larger in announceThresholds where larger >= t { done.insert(larger) }
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
