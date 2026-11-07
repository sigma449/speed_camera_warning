import Foundation

/// 區間測速事件。
public enum SectionEvent: Equatable, Sendable {
    /// 接近區間起點（每段只提醒一次）。distance 為目前到起點的距離。
    case approaching(section: SpeedSection, distance: Double)
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
    /// 區間內車速超過「速限＋區間容許值」（播一次語音加嗶聲）。
    case overspeedStarted(threshold: Int)
    /// 持續超速，每隔設定秒數嗶一聲。
    case overspeedBeep
    /// 恢復到門檻以內，或離開區間。
    case overspeedEnded
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
    /// 計算用的時速（速限＋區間容許值）。
    public var effectiveLimitKmh: Double

    public init(section: SpeedSection, startTime: Date, elapsed: TimeInterval, minimumSeconds: Double,
                remainingSeconds: Double, earliestExit: Date, traveledMeters: Double, remainingMeters: Double,
                averageKmh: Double, suggestedMaxKmh: Double, effectiveLimitKmh: Double) {
        self.section = section
        self.startTime = startTime
        self.elapsed = elapsed
        self.minimumSeconds = minimumSeconds
        self.remainingSeconds = remainingSeconds
        self.earliestExit = earliestExit
        self.traveledMeters = traveledMeters
        self.remainingMeters = remainingMeters
        self.averageKmh = averageKmh
        self.suggestedMaxKmh = suggestedMaxKmh
        self.effectiveLimitKmh = effectiveLimitKmh
    }

    /// 倒數秒數（無條件進位成整數，畫面顯示用）。
    public var remainingWholeSeconds: Int { Int(remainingSeconds.rounded(.up)) }

    /// 建議時速（無條件捨去，偏保守）：剩下的路照這個時速以下開，平均就不會超過「速限＋容許值」。
    public var suggestedWholeKmh: Int { Int(suggestedMaxKmh.rounded(.down)) }
}

/// 正在接近的區間（畫面與 Live Activity 顯示用）。
public struct SectionApproach: Equatable, Sendable {
    public var section: SpeedSection
    public var distance: Double

    public init(section: SpeedSection, distance: Double) {
        self.section = section
        self.distance = distance
    }

    /// 橫幅沿用照相點的版面：同一種提醒長得一樣，不用多一種畫面。
    public var asCameraTarget: CameraTarget {
        let camera = Camera(id: "section-approach-\(section.id)", type: .section,
                            lat: section.start.lat, lon: section.start.lon,
                            speedLimit: section.speedLimit, address: section.shortName)
        return CameraTarget(camera: camera, distance: distance, phase: .pre, isOverspeed: false)
    }
}

public struct SectionResult: Equatable, Sendable {
    public var events: [SectionEvent]
    public var status: SectionStatus?
    public var approach: SectionApproach?

    public init(events: [SectionEvent], status: SectionStatus?, approach: SectionApproach? = nil) {
        self.events = events
        self.status = status
        self.approach = approach
    }
}

/// 區間測速追蹤器：
/// - 接近起點時預告一次（距離和一般照相相同：速限 ≥ 80 為 600 m，其他 300 m）
/// - 經過起點時開始計時；沒有定位時（隧道）依最後的車速推算
/// - 倒數 = 區間長度 ÷（速限＋區間容許值）×（1 + 安全餘裕）− 已經過秒數
/// - 區間內車速超過「速限＋區間容許值」時，每隔固定秒數嗶一聲
/// - 倒數每跨過一個整分鐘提醒一次，最後 30、10 秒再各提醒一次，歸零時提醒一次
public final class SectionSpeedTracker {
    public var settings: AlertSettings
    public private(set) var sections: [SpeedSection]
    /// 超過這個秒數沒有新定位，`tick` 才開始依時間推算。
    public var gpsGapSeconds: TimeInterval = 2.5
    /// 沒經過起點的判定範圍、但已經在區間前段時，這個距離內仍算剛進入區間（公尺）。
    public var lateEntryDistance: Double = 300
    /// 判斷「走在區間路線上」的橫向距離（公尺）。
    public var onPathDistance: Double = 50

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
        var isOverspeed = false
        var lastBeep: Date?
    }

    /// 進入起點範圍後，等到「最接近起點」的那一刻才開始計時（和照相點位置一致），
    /// 避免提早計時導致倒數偏短。
    private struct Arming {
        var section: SpeedSection
        var minDistance: Double
        var minTime: Date
        var minPoint: GeoPoint
    }

    /// 預告過、還沒進入的區間。
    private struct Approaching {
        var section: SpeedSection
        var distance: Double
        var minDistance: Double
    }

    private var active: Active?
    private var arming: Arming?
    private var approaching: Approaching?
    private var lastCourse: Double?
    private var lastFix: VehicleFix?
    private var recentlyFinished: [String: Date] = [:]
    /// 已經預告過的區間，同一段不重複預告。
    private var announcedApproach: [String: Date] = [:]

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
        approaching = nil
        lastCourse = nil
        lastFix = nil
        recentlyFinished.removeAll()
        announcedApproach.removeAll()
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
            // 短的區間（辛亥隧道只要 31 秒）進入時的語音還沒念完，不要馬上接「還有 30 秒」
            for extra in [30, 10] where minSec - Double(extra) >= 10 {
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
        announcedApproach = announcedApproach.filter { fix.timestamp.timeIntervalSince($0.value) < 300 }
        lastFix = fix

        var events: [SectionEvent] = []

        if active != nil {
            advance(fix: fix, events: &events)
        } else if let entered = updateArming(fix) ?? lateEntry(fix) {
            begin(entered, events: &events)
            // 啟動時可能已經過了起點幾秒，立刻檢查倒數提醒。
            advance(fix: fix, events: &events)
        } else {
            updateApproach(fix, events: &events)
        }

        guard let a = active else {
            return SectionResult(events: events, status: nil, approach: currentApproach)
        }
        return SectionResult(events: events, status: makeStatus(a, now: fix.timestamp))
    }

    /// 沒有新定位時（隧道、訊號差）由 App 每秒呼叫，依最後的車速和時間推算。
    /// 定位正常時回傳 nil，表示沒有要更新的內容。
    public func tick(now: Date) -> SectionResult? {
        guard let last = lastFix, now.timeIntervalSince(last.timestamp) >= gpsGapSeconds else { return nil }
        var events: [SectionEvent] = []

        if active == nil, let entered = enterWithoutFix(last: last, now: now) {
            begin(entered, events: &events)
        }
        if var a = active {
            updateCountdown(&a, now: now, events: &events)
            active = a
            return SectionResult(events: events, status: makeStatus(a, now: now, assumedSpeed: last.speedMps))
        }
        guard var ap = approaching else { return nil }
        // 畫面上的距離也繼續往下算
        let moved = max(0, last.speedMps) * now.timeIntervalSince(last.timestamp)
        ap.distance = max(0, GeoMath.distance(last.point, ap.section.start) - moved)
        approaching = ap
        return SectionResult(events: events, status: nil, approach: currentApproach)
    }

    // MARK: - 內部流程

    private var currentApproach: SectionApproach? {
        approaching.map { SectionApproach(section: $0.section, distance: $0.distance) }
    }

    private func begin(_ entered: Active, events: inout [SectionEvent]) {
        active = entered
        arming = nil
        approaching = nil
        events.append(.entered(section: entered.section, minimumSeconds: Int(entered.minimumSeconds.rounded(.up))))
    }

    private func makeActive(_ s: SpeedSection, startTime: Date, point: GeoPoint, lastTime: Date,
                            traveled: Double = 0) -> Active {
        let minSec = s.minimumSeconds(atKmh: settings.sectionEffectiveLimit(s.speedLimit, sectionID: s.groupID))
            * (1 + settings.sectionSafetyMargin)
        return Active(section: s, startTime: startTime, minimumSeconds: minSec,
                      traveled: traveled, lastPoint: point, lastTime: lastTime,
                      pendingMilestones: Self.milestones(forMinimumSeconds: minSec,
                                                         finalCountdown: settings.sectionFinalCountdown),
                      zeroAnnounced: false, minEndDistance: .greatestFiniteMagnitude,
                      minEndTime: nil)
    }

    /// 預告距離：和一般照相點相同的規則。
    private func approachDistance(for s: SpeedSection) -> Double {
        settings.thresholds(speedLimit: s.speedLimit, currentSpeedKmh: 0).pre
    }

    /// 是不是朝著起點、順著區間的方向開過去：
    /// 行進方向和區間進入方向不能相反，起點要在前方，而且要從起點的「後面」接近（不是橫向路過）。
    private func isHeadingToStart(of s: SpeedSection, from point: GeoPoint, heading: Double) -> Bool {
        let toStart = GeoMath.bearing(from: point, to: s.start)
        return GeoMath.angleDifference(heading, s.entryHeading) <= 90
            && GeoMath.angleDifference(toStart, heading) <= 70
            && GeoMath.angleDifference(toStart, s.entryHeading) <= 70
    }

    private func updateApproach(_ fix: VehicleFix, events: inout [SectionEvent]) {
        guard let heading = lastCourse else { return }
        if var ap = approaching {
            let d = GeoMath.distance(fix.point, ap.section.start)
            ap.distance = d
            ap.minDistance = min(ap.minDistance, d)
            let turnedAway = !isHeadingToStart(of: ap.section, from: fix.point, heading: heading)
                && d > ap.minDistance + 60
            if d > approachDistance(for: ap.section) + 200 || turnedAway {
                approaching = nil
            } else {
                approaching = ap
                return
            }
        }
        var best: (section: SpeedSection, distance: Double)?
        for s in sections where recentlyFinished[s.id] == nil && announcedApproach[s.id] == nil {
            let d = GeoMath.distance(fix.point, s.start)
            guard d > settings.sectionGateRadius, d <= approachDistance(for: s),
                  isHeadingToStart(of: s, from: fix.point, heading: heading),
                  d < (best?.distance ?? .greatestFiniteMagnitude) else { continue }
            best = (s, d)
        }
        guard let best else { return }
        announcedApproach[best.section.id] = fix.timestamp
        approaching = Approaching(section: best.section, distance: best.distance, minDistance: best.distance)
        events.append(.approaching(section: best.section, distance: best.distance))
    }

    /// 沒有經過起點的判定範圍（隧道口訊號差、GPS 跳點、匝道在起點之後才併入），但已經走在區間前段：
    /// 一樣算進入，開始時間依目前車速往回推，倒數才不會偏長。
    private func lateEntry(_ fix: VehicleFix) -> Active? {
        guard arming == nil, let heading = lastCourse, fix.speedKmh >= settings.minimumSpeedForCourse else { return nil }
        for s in sections where recentlyFinished[s.id] == nil {
            guard let spot = locateNearStart(of: s, point: fix.point),
                  spot.lateral <= onPathDistance,
                  GeoMath.angleDifference(heading, spot.bearing) <= 45 else { continue }
            let startTime = fix.timestamp.addingTimeInterval(-spot.along / max(1, fix.speedMps))
            return makeActive(s, startTime: startTime, point: fix.point, lastTime: fix.timestamp, traveled: spot.along)
        }
        return nil
    }

    /// 把點投影到區間前段（起點開始 `lateEntryDistance` 公尺內）。
    private func locateNearStart(of s: SpeedSection, point: GeoPoint) -> (along: Double, lateral: Double, bearing: Double)? {
        // 先用直線距離過濾，大部分區間都不用算
        guard GeoMath.distance(point, s.start) <= lateEntryDistance + onPathDistance else { return nil }
        let path = s.displayPath
        var walked = 0.0
        var best: (along: Double, lateral: Double, bearing: Double)?
        for (a, b) in zip(path, path.dropFirst()) {
            let length = GeoMath.distance(a, b)
            let projection = GeoMath.project(point, ontoSegment: a, b)
            let along = walked + projection.t * length
            if along <= lateEntryDistance, projection.distance < (best?.lateral ?? .greatestFiniteMagnitude) {
                best = (along, projection.distance, GeoMath.bearing(from: a, to: b))
            }
            walked += length
            if walked > lateEntryDistance { break }
        }
        return best
    }

    /// 沒有定位：最後一筆定位在起點前面時，依車速推算什麼時候經過起點。
    private func enterWithoutFix(last: VehicleFix, now: Date) -> Active? {
        let target: SpeedSection?
        if let arm = arming {
            target = arm.section
        } else {
            target = approaching?.section
        }
        guard let s = target, last.speedKmh >= settings.minimumSpeedForCourse else { return nil }
        let eta = GeoMath.distance(last.point, s.start) / max(1, last.speedMps)
        let startTime = last.timestamp.addingTimeInterval(eta)
        guard now >= startTime else { return nil }
        return makeActive(s, startTime: startTime, point: s.start, lastTime: startTime)
    }

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
                let startTime = d <= 5 ? fix.timestamp : arm.minTime
                let startPoint = d <= 5 ? fix.point : arm.minPoint
                return makeActive(arm.section, startTime: startTime, point: startPoint, lastTime: startTime)
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
            // 有起點道路方向（里程牌計算）就用它；否則用起終點直線方向。兩者都只要求 90° 以內。
            guard GeoMath.angleDifference(heading, s.entryHeading) <= 90 else { continue }
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
        updateCountdown(&a, now: fix.timestamp, events: &events)

        // 區間內超速警示（以瞬間車速判斷）
        let threshold = settings.sectionEffectiveLimit(a.section.speedLimit, sectionID: a.section.groupID)
        let over = fix.speedKmh > threshold
        if over && !a.isOverspeed {
            a.isOverspeed = true
            a.lastBeep = fix.timestamp
            events.append(.overspeedStarted(threshold: Int(threshold.rounded())))
        } else if over, let last = a.lastBeep,
                  fix.timestamp.timeIntervalSince(last) >= settings.overspeedBeepInterval {
            a.lastBeep = fix.timestamp
            events.append(.overspeedBeep)
        } else if !over && a.isOverspeed {
            a.isOverspeed = false
            events.append(.overspeedEnded)
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
            if a.isOverspeed { events.append(.overspeedEnded) }
            events.append(.completed(section: a.section, averageKmh: avgKmh,
                                     withinLimit: avgKmh <= settings.sectionEffectiveLimit(a.section.speedLimit, sectionID: a.section.groupID)))
            recentlyFinished[a.section.id] = fix.timestamp
            active = nil
            return
        }

        // 中途離開：跑太遠、離終點太遠，或時間太久。
        let wentTooFar = a.traveled > a.section.lengthMeters + 600
        let farFromEnd = dEnd > a.section.lengthMeters + 1_000
        let timedOut = elapsed > a.minimumSeconds * 4 + 600
        if wentTooFar || farFromEnd || timedOut {
            if a.isOverspeed { events.append(.overspeedEnded) }
            events.append(.aborted(section: a.section))
            recentlyFinished[a.section.id] = fix.timestamp
            active = nil
            return
        }

        active = a
    }

    /// 倒數提醒：跨過多個時間點時（例如 GPS 中斷），只報最新的那一個。
    private func updateCountdown(_ a: inout Active, now: Date, events: inout [SectionEvent]) {
        let remaining = max(0, a.minimumSeconds - now.timeIntervalSince(a.startTime))
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
    }

    /// assumedSpeed：沒有定位時，用最後的車速推算這段時間走了多遠（不影響累計的 traveled）。
    private func makeStatus(_ a: Active, now: Date, assumedSpeed: Double = 0) -> SectionStatus {
        let elapsed = max(0, now.timeIntervalSince(a.startTime))
        let remaining = max(0, a.minimumSeconds - elapsed)
        let traveled = a.traveled + max(0, assumedSpeed) * max(0, now.timeIntervalSince(a.lastTime))
        let remainingMeters = max(0, a.section.lengthMeters - traveled)
        let avg = elapsed > 1 ? SpeedUnit.kmh(fromMps: traveled / elapsed) : 0
        let limit = settings.sectionEffectiveLimit(a.section.speedLimit, sectionID: a.section.groupID)
        var suggested = limit
        if remaining > 0.5 {
            suggested = min(limit, SpeedUnit.kmh(fromMps: remainingMeters / remaining))
        }
        return SectionStatus(section: a.section, startTime: a.startTime, elapsed: elapsed,
                             minimumSeconds: a.minimumSeconds, remainingSeconds: remaining,
                             earliestExit: a.startTime.addingTimeInterval(a.minimumSeconds),
                             traveledMeters: traveled, remainingMeters: remainingMeters,
                             averageKmh: avg, suggestedMaxKmh: suggested,
                             effectiveLimitKmh: limit)
    }
}
