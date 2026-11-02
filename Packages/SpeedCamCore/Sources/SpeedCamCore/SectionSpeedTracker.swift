import Foundation

/// 區間測速事件。
public enum SectionEvent: Equatable, Sendable {
    /// 進入區間。minimumSeconds 為含安全餘裕的最短秒數。
    case entered(section: SpeedSection, minimumSeconds: Int)
    /// 倒數提醒：還有幾秒（每分鐘一次，以及最後 30、10 秒）。
    case remaining(seconds: Int)
    /// 倒數歸零：之後依速限行駛即可。
    case zeroReached
    /// 通過終點。averageKmh 以「區間長度 ÷ 實際花費時間」計算，和執法方式相同。
    case completed(section: SpeedSection, averageKmh: Double, withinLimit: Bool)
    /// 中途離開區間（例如下交流道），停止追蹤。
    case aborted(section: SpeedSection)
}

/// 區間測速目前的狀態（畫面與 Live Activity 顯示用）。
public struct SectionStatus: Equatable, Sendable {
    public var section: SpeedSection
    public var startTime: Date
    public var elapsed: TimeInterval
    /// 含安全餘裕的最短秒數。
    public var minimumSeconds: Double
    /// 還要至少幾秒才能到終點（0 表示已可依速限行駛）。
    public var remainingSeconds: Double
    /// 最早可以抵達終點的時間（Live Activity 用它做自動倒數）。
    public var earliestExit: Date
    public var traveledMeters: Double
    public var remainingMeters: Double
    /// 目前的平均時速。
    public var averageKmh: Double
    /// 剩下的路建議不要超過的時速。
    public var suggestedMaxKmh: Double

    /// 倒數秒數（無條件進位成整數，畫面顯示用）。
    public var remainingWholeSeconds: Int { Int(remainingSeconds.rounded(.up)) }
}

public struct SectionResult: Equatable, Sendable {
    public var events: [SectionEvent]
    public var status: SectionStatus?
}

/// 區間測速追蹤器：
/// - 經過起點時開始計時
/// - 倒數 = 區間長度 ÷ 速限 ×（1 + 安全餘裕）− 已經過秒數
/// - 倒數每跨過一個整分鐘提醒一次，最後 30、10 秒再各提醒一次，歸零時提醒一次
public final class SectionSpeedTracker {
    public var settings: AlertSettings
    public private(set) var sections: [SpeedSection]

    private struct Active {
        var section: SpeedSection
        var startTime: Date
        var minimumSeconds: Double
        var traveled: Double
        var lastPoint: GeoPoint
        var lastTime: Date
        var pendingMilestones: [Int]
        var zeroAnnounced: Bool
        var minEndDistance: Double
        var minEndTime: Date?
    }

    /// 進入起點範圍後，等到「最接近起點」的那一刻才開始計時（和照相點位置一致），
    /// 避免提早計時導致倒數偏短。
    private struct Arming {
        var section: SpeedSection
        var minDistance: Double
        var minTime: Date
        var minPoint: GeoPoint
    }

    private var active: Active?
    private var arming: Arming?
    private var lastCourse: Double?
    private var recentlyFinished: [String: Date] = [:]

    public init(sections: [SpeedSection], settings: AlertSettings = AlertSettings()) {
        self.sections = sections
        self.settings = settings
    }

    public func replaceSections(_ sections: [SpeedSection]) {
        self.sections = sections
        reset()
    }

    public func reset() {
        active = nil
        arming = nil
        lastCourse = nil
        recentlyFinished.removeAll()
    }

    public var isActive: Bool { active != nil }

    /// 依最短秒數產生要提醒的時間點（由大到小）。
    public static func milestones(forMinimumSeconds minSec: Double, finalCountdown: Bool) -> [Int] {
        var result: [Int] = []
        var m = Int(minSec.rounded(.down)) / 60 * 60
        if Double(m) >= minSec { m -= 60 }
        while m >= 60 {
            result.append(m)
            m -= 60
        }
        if finalCountdown {
            for extra in [30, 10] where Double(extra) < minSec {
                result.append(extra)
            }
        }
        return result.sorted(by: >)
    }

    public func process(_ fix: VehicleFix) -> SectionResult {
        if let course = fix.course, course >= 0, fix.speedKmh >= settings.minimumSpeedForCourse {
            lastCourse = GeoMath.normalize(course)
        }
        recentlyFinished = recentlyFinished.filter { fix.timestamp.timeIntervalSince($0.value) < 300 }

        var events: [SectionEvent] = []

        if active != nil {
            advance(fix: fix, events: &events)
        } else if let entered = updateArming(fix) {
            active = entered
            events.append(.entered(section: entered.section, minimumSeconds: Int(entered.minimumSeconds.rounded(.up))))
            // 啟動時可能已經過了起點幾秒，立刻檢查倒數提醒。
            advance(fix: fix, events: &events)
        }

        guard let a = active else {
            return SectionResult(events: events, status: nil)
        }
        return SectionResult(events: events, status: makeStatus(a, now: fix.timestamp))
    }

    // MARK: - 內部流程

    /// 處理「接近起點」階段；確定通過起點時回傳啟動後的狀態。
    private func updateArming(_ fix: VehicleFix) -> Active? {
        if var arm = arming {
            let d = GeoMath.distance(fix.point, arm.section.start)
            if d < arm.minDistance {
                arm.minDistance = d
                arm.minTime = fix.timestamp
                arm.minPoint = fix.point
            }
            let passedStart = d > arm.minDistance + 5 || d <= 5
            if passedStart {
                arming = nil
                let s = arm.section
                let startTime = d <= 5 ? fix.timestamp : arm.minTime
                let startPoint = d <= 5 ? fix.point : arm.minPoint
                let minSec = s.minimumSeconds * (1 + settings.sectionSafetyMargin)
                return Active(section: s, startTime: startTime, minimumSeconds: minSec,
                              traveled: 0, lastPoint: startPoint, lastTime: startTime,
                              pendingMilestones: Self.milestones(forMinimumSeconds: minSec,
                                                                 finalCountdown: settings.sectionFinalCountdown),
                              zeroAnnounced: false, minEndDistance: .greatestFiniteMagnitude,
                              minEndTime: nil)
            }
            if d > settings.sectionGateRadius * 2 {
                arming = nil   // 離開起點範圍但沒有真正通過（例如轉彎離開）
            } else {
                arming = arm
            }
            return nil
        }

        guard let heading = lastCourse else { return nil }
        for s in sections where recentlyFinished[s.id] == nil {
            let d = GeoMath.distance(fix.point, s.start)
            guard d <= settings.sectionGateRadius else { continue }
            // 道路可能彎曲，只要求大致朝終點方向（90° 以內）。
            guard GeoMath.angleDifference(heading, s.heading) <= 90 else { continue }
            arming = Arming(section: s, minDistance: d, minTime: fix.timestamp, minPoint: fix.point)
            return nil
        }
        return nil
    }

    private func advance(fix: VehicleFix, events: inout [SectionEvent]) {
        guard var a = active else { return }

        // 累計行駛距離；過濾掉不合理的 GPS 跳點。
        let step = GeoMath.distance(a.lastPoint, fix.point)
        let dt = max(0.1, fix.timestamp.timeIntervalSince(a.lastTime))
        let plausibleMax = max(80, fix.speedMps * dt * 1.8)
        a.traveled += min(step, plausibleMax)
        a.lastPoint = fix.point
        a.lastTime = fix.timestamp

        let elapsed = fix.timestamp.timeIntervalSince(a.startTime)
        let remaining = max(0, a.minimumSeconds - elapsed)

        // 倒數提醒：跨過多個時間點時（例如 GPS 中斷），只報最新的那一個。
        let crossed = a.pendingMilestones.filter { Double($0) >= remaining }
        if !crossed.isEmpty {
            a.pendingMilestones.removeAll { Double($0) >= remaining }
            if remaining > 0, let latest = crossed.min() {
                events.append(.remaining(seconds: latest))
            }
        }
        if remaining <= 0 && !a.zeroAnnounced {
            a.zeroAnnounced = true
            events.append(.zeroReached)
        }

        // 終點判定：進入終點範圍後開始遠離，或行駛距離明顯超過區間長度。
        let dEnd = GeoMath.distance(fix.point, a.section.end)
        if dEnd <= settings.sectionGateRadius * 3 && dEnd < a.minEndDistance {
            a.minEndDistance = dEnd
            a.minEndTime = fix.timestamp
        }
        let leftEndGate = a.minEndDistance <= settings.sectionGateRadius && dEnd > a.minEndDistance + 20
        let overshot = a.traveled >= a.section.lengthMeters + 150
            && a.minEndDistance <= settings.sectionGateRadius * 3

        if leftEndGate || overshot {
            // 以最接近終點那一刻的時間計算平均速度（和終點照相的位置一致）。
            let endTime = a.minEndTime ?? fix.timestamp
            let total = endTime.timeIntervalSince(a.startTime)
            let avgKmh = total > 0 ? SpeedUnit.kmh(fromMps: a.section.lengthMeters / total) : 0
            events.append(.completed(section: a.section, averageKmh: avgKmh,
                                     withinLimit: avgKmh <= Double(a.section.speedLimit)))
            recentlyFinished[a.section.id] = fix.timestamp
            active = nil
            return
        }

        // 中途離開：跑太遠、離終點太遠，或時間太久。
        let wentTooFar = a.traveled > a.section.lengthMeters + 600
        let farFromEnd = dEnd > a.section.lengthMeters + 1_000
        let timedOut = elapsed > a.minimumSeconds * 4 + 600
        if wentTooFar || farFromEnd || timedOut {
            events.append(.aborted(section: a.section))
            recentlyFinished[a.section.id] = fix.timestamp
            active = nil
            return
        }

        active = a
    }

    private func makeStatus(_ a: Active, now: Date) -> SectionStatus {
        let elapsed = max(0, now.timeIntervalSince(a.startTime))
        let remaining = max(0, a.minimumSeconds - elapsed)
        let remainingMeters = max(0, a.section.lengthMeters - a.traveled)
        let avg = elapsed > 1 ? SpeedUnit.kmh(fromMps: a.traveled / elapsed) : 0
        let limit = Double(a.section.speedLimit)
        var suggested = limit
        if remaining > 0.5 {
            suggested = min(limit, SpeedUnit.kmh(fromMps: remainingMeters / remaining))
        }
        return SectionStatus(section: a.section, startTime: a.startTime, elapsed: elapsed,
                             minimumSeconds: a.minimumSeconds, remainingSeconds: remaining,
                             earliestExit: a.startTime.addingTimeInterval(a.minimumSeconds),
                             traveledMeters: a.traveled, remainingMeters: remainingMeters,
                             averageKmh: avg, suggestedMaxKmh: suggested)
    }
}
