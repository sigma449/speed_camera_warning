import Foundation

/// 某個照相點目前已經提醒到哪個階段。
public enum AlertPhase: Int, Comparable, Sendable {
    /// 已經偵測到但還沒進入預告距離
    case approaching = 0
    /// 已播過預告
    case pre = 1
    /// 已播過近距提醒
    case near = 2

    public static func < (lhs: AlertPhase, rhs: AlertPhase) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 提醒引擎輸出的事件。App 端依事件播放語音、嗶聲，並更新 Live Activity。
public enum CameraAlertEvent: Equatable, Sendable {
    /// 預告（例如 300 m）
    case preAlert(camera: Camera, distance: Double)
    /// 近距（例如 100 m）。afterPre：這支已經預告過，語音只要念距離。
    case nearAlert(camera: Camera, distance: Double, afterPre: Bool = true)
    /// 通過照相點
    case passed(camera: Camera)
    /// 開始超速（播一次「超速」語音加嗶聲）
    case overspeedStarted(limit: Int, speedKmh: Double)
    /// 持續超速，每隔設定秒數嗶一聲
    case overspeedBeep
    /// 恢復到速限以內，或已通過照相點
    case overspeedEnded
}

/// 目前最需要注意的照相點（畫面與 Live Activity 顯示用）。
public struct CameraTarget: Equatable, Sendable {
    public var camera: Camera
    public var distance: Double
    public var phase: AlertPhase
    public var isOverspeed: Bool

    public init(camera: Camera, distance: Double, phase: AlertPhase, isOverspeed: Bool) {
        self.camera = camera
        self.distance = distance
        self.phase = phase
        self.isOverspeed = isOverspeed
    }
}

public struct CameraAlertResult: Equatable, Sendable {
    public var events: [CameraAlertEvent]
    public var target: CameraTarget?
}

/// 測速照相提醒引擎：
/// 1. 找出前方、方向相符的照相點
/// 2. 預告與近距各提醒一次
/// 3. 接近期間若超速，每隔固定秒數嗶一聲
/// 4. 通過後進入冷卻，不會重複提醒
public final class CameraAlertEngine {
    public var settings: AlertSettings
    public private(set) var index: SpatialIndex
    /// 區間清單：區間測速的照相機會套用附近區間（起點或終點 500 m 內）的個別容許值。
    public var sections: [SpeedSection] = [] {
        didSet { coveredBySection.removeAll() }
    }
    /// 區間照相機離區間路線多近，就算是那一段的一部分（公尺）。
    public var sectionCameraCoverage: Double = 300
    /// 超過這個秒數沒有定位，就依最後的車速推算（和區間倒數相同）。
    public var gpsGapSeconds: TimeInterval = 2.5
    /// 最後的車速低於這個值不推算：多半是停車或開進停車場，不是進隧道。
    public var noFixMinimumSpeedKmh: Double = 20
    /// 沒有定位時，最多推算到多遠的照相點（從最後一筆定位算，公尺）。
    public var noFixRange: Double = 1_500
    /// 地址寫著隧道的照相點可以推算到這麼遠（雪山隧道 13 km）。
    /// 其他照相點不推這麼遠，否則搭捷運進地下之後會一直誤報。
    public var noFixTunnelRange: Double = 15_000
    /// 沒有定位時，一般照相點要幾乎在正前方才算（度）。
    public var noFixAheadTolerance: Double = 30
    /// 隧道裡的照相點，取締方向和進隧道時的方向最多差幾度。資料的方向只有八方位，隧道又有弧度，
    /// 同方向最多差到 93°（萬里隧道），對向管道至少差 127°（過港隧道）。
    public var noFixTunnelDirectionTolerance: Double = 110
    /// 推算已經超過照相點這麼遠就不再追蹤，定位回來時才不會一次響好幾聲通過（公尺）。
    public var noFixForgetDistance: Double = 500
    /// 沒有定位時，超速狀態最多留幾秒：車速是舊的，不知道有沒有降速。
    public var noFixOverspeedHold: TimeInterval = 10

    private struct Tracked {
        var camera: Camera
        var phase: AlertPhase
        var minDistance: Double
        var distance: Double
        /// 這段沒有定位時推算過：定位回來時如果已經在後面，就算通過。
        var estimated = false
    }

    private struct Cooldown {
        var point: GeoPoint
        var time: Date
    }

    private var tracked: [String: Tracked] = [:]
    private var cooldown: [String: Cooldown] = [:]
    private var lastCourse: Double?
    private var isOverspeed = false
    private var lastBeep: Date?
    /// 區間照相機是否已經算在某一段區間裡（結果留著，不用每秒重算）。
    private var coveredBySection: [String: Bool] = [:]
    /// 最後一筆定位。App 只會把可靠的定位交給引擎。
    public private(set) var lastFix: VehicleFix?
    /// 這段沒有定位已經找過照相點了（記最後一筆定位的時間）。
    private var searchedWithoutFix: Date?

    public init(index: SpatialIndex, settings: AlertSettings = AlertSettings()) {
        self.index = index
        self.settings = settings
    }

    /// 換一份資料庫（例如資料更新後）。
    public func replaceIndex(_ index: SpatialIndex) {
        self.index = index
        reset()
    }

    public func reset() {
        tracked.removeAll()
        cooldown.removeAll()
        lastCourse = nil
        isOverspeed = false
        lastBeep = nil
        lastFix = nil
        searchedWithoutFix = nil
    }

    /// 目前採用的行進方向（低速時沿用上一次的有效方向）。
    public var currentCourse: Double? { lastCourse }

    public func process(_ fix: VehicleFix) -> CameraAlertResult {
        var events: [CameraAlertEvent] = []
        lastFix = fix

        if let course = fix.course, course >= 0, fix.speedKmh >= settings.minimumSpeedForCourse {
            lastCourse = GeoMath.normalize(course)
        }
        guard let heading = lastCourse else {
            return CameraAlertResult(events: [], target: nil)
        }

        expireCooldowns(at: fix)
        updateTracked(fix: fix, heading: heading, events: &events)
        addNewCandidates(fix: fix, heading: heading)

        // 目前目標：方向相符的照相點中最近的一個。
        let targetKey = tracked
            .filter { isRelevant($0.value.camera, distance: $0.value.distance, from: fix.point, heading: heading, isTracked: true) }
            .min { $0.value.distance < $1.value.distance }?.key

        var target: CameraTarget?
        if let key = targetKey, var t = tracked[key] {
            advancePhase(&t, speedKmh: fix.speedKmh, events: &events)
            tracked[key] = t
            updateOverspeed(target: t, fix: fix, events: &events)
            target = CameraTarget(camera: t.camera, distance: t.distance, phase: t.phase, isOverspeed: isOverspeed)
        } else if isOverspeed {
            isOverspeed = false
            events.append(.overspeedEnded)
        }

        return CameraAlertResult(events: events, target: target)
    }

    /// 沒有新定位時（隧道、訊號差）由 App 每秒呼叫。定位正常時回傳 nil。
    ///
    /// 依最後的車速和時間推算到照相點還有多遠：最後一筆定位到照相點的直線距離，減掉這段時間走的距離。
    /// 不推算位置：隧道有弧度（觀音隧道 8 km 偏離直線 1 km），照直線走會離照相點越來越遠。
    /// 直線距離比實際路程短，誤差是提早提醒，不會太晚。
    /// 「通過」要等定位回來才判斷，因為車速是舊的，不能確定真的過了。
    public func tick(now: Date) -> CameraAlertResult? {
        guard let last = lastFix, let heading = lastCourse else { return nil }
        let elapsed = now.timeIntervalSince(last.timestamp)
        guard elapsed >= gpsGapSeconds, last.speedKmh >= noFixMinimumSpeedKmh else { return nil }

        if searchedWithoutFix != last.timestamp {
            searchedWithoutFix = last.timestamp
            addCandidatesWithoutFix(last: last, heading: heading)
        }

        let moved = last.speedMps * elapsed
        var nearest: (key: String, distance: Double)?
        for (key, var t) in tracked {
            let fromLast = GeoMath.distance(last.point, t.camera.point)
            guard fromLast < 30 || isAheadWithoutFix(t.camera, distance: fromLast, from: last.point, heading: heading) else { continue }
            let remaining = fromLast - moved
            if remaining < -noFixForgetDistance {
                tracked[key] = nil
                continue
            }
            t.estimated = true
            t.distance = max(0, remaining)
            tracked[key] = t
            if remaining > 0, remaining < (nearest?.distance ?? .greatestFiniteMagnitude) {
                nearest = (key, remaining)
            }
        }

        var events: [CameraAlertEvent] = []
        // 車速是舊的：不嗶，太久沒有定位就當作結束
        if isOverspeed, elapsed >= noFixOverspeedHold {
            isOverspeed = false
            events.append(.overspeedEnded)
        }

        var target: CameraTarget?
        if let key = nearest?.key, var t = tracked[key] {
            advancePhase(&t, speedKmh: last.speedKmh, events: &events)
            tracked[key] = t
            target = CameraTarget(camera: t.camera, distance: t.distance, phase: t.phase, isOverspeed: isOverspeed)
        }
        return CameraAlertResult(events: events, target: target)
    }

    // MARK: - 內部流程

    /// 到了預告或近距的距離就提醒（每段只提醒一次）。
    private func advancePhase(_ t: inout Tracked, speedKmh: Double, events: inout [CameraAlertEvent]) {
        let th = settings.thresholds(speedLimit: t.camera.speedLimit, currentSpeedKmh: speedKmh)
        if t.distance <= th.near && t.phase < .near {
            let afterPre = t.phase == .pre
            t.phase = .near
            events.append(.nearAlert(camera: t.camera, distance: t.distance, afterPre: afterPre))
        } else if t.distance <= th.pre && t.phase < .pre {
            t.phase = .pre
            events.append(.preAlert(camera: t.camera, distance: t.distance))
        }
    }

    /// 隧道比搜尋半徑長時，隧道裡的照相點在定位中斷前還沒開始追蹤，這裡一次找出來。
    private func addCandidatesWithoutFix(last: VehicleFix, heading: Double) {
        for (cam, d) in index.cameras(near: last.point, radius: noFixTunnelRange) {
            guard tracked[cam.id] == nil, cooldown[cam.id] == nil, !isCoveredBySection(cam) else { continue }
            guard isAheadWithoutFix(cam, distance: d, from: last.point, heading: heading) else { continue }
            tracked[cam.id] = Tracked(camera: cam, phase: .approaching, minDistance: d, distance: d)
        }
    }

    /// 沒有定位時，這支照相點算不算在前面的路上。有定位時可以看距離有沒有真的變小，推算不行，所以另外判斷：
    /// - 地址寫著隧道：只要不是對向、大致在前方就算。隧道有弧度，進隧道時的方向可能差很多（雪山隧道往北差到 44°）。
    /// - 其他：範圍內而且幾乎在正前方才算。旁邊平行道路的照相點，推算時會一直靠近
    ///   （雪山隧道往北的入口，宜3線的照相點在右前方約 50°，模擬時誤報）。
    private func isAheadWithoutFix(_ camera: Camera, distance: Double, from point: GeoPoint, heading: Double) -> Bool {
        let aheadDiff = GeoMath.angleDifference(GeoMath.bearing(from: point, to: camera.point), heading)
        if camera.address.contains("隧道") {
            let sameWay = camera.heading.map { GeoMath.angleDifference(heading, $0) <= noFixTunnelDirectionTolerance } ?? true
            return sameWay && aheadDiff < 90
        }
        return distance <= noFixRange && aheadDiff <= noFixAheadTolerance
            && isRelevant(camera, distance: distance, from: point, heading: heading, isTracked: false)
    }

    private func expireCooldowns(at fix: VehicleFix) {
        cooldown = cooldown.filter { _, c in
            GeoMath.distance(c.point, fix.point) <= settings.rearmDistance
                && fix.timestamp.timeIntervalSince(c.time) < settings.rearmInterval
        }
    }

    private func updateTracked(fix: VehicleFix, heading: Double, events: inout [CameraAlertEvent]) {
        for (key, var t) in tracked {
            let d = GeoMath.distance(fix.point, t.camera.point)
            t.distance = d
            t.minDistance = min(t.minDistance, d)

            let aheadDiff = GeoMath.angleDifference(GeoMath.bearing(from: fix.point, to: t.camera.point), heading)
            let behindAndClose = d < 200 && aheadDiff > 100 && t.minDistance < 250
            let movingAwayAfterClose = t.minDistance < 150 && d > t.minDistance + 40
            // 沒有定位的那段已經過了：定位回來時可能離照相點很遠，上面兩個條件都不成立
            let passedWithoutFix = t.estimated && aheadDiff > 100
            t.estimated = false

            if behindAndClose || movingAwayAfterClose || passedWithoutFix {
                tracked[key] = nil
                cooldown[key] = Cooldown(point: t.camera.point, time: fix.timestamp)
                if t.phase >= .pre {
                    events.append(.passed(camera: t.camera))
                }
                continue
            }

            let lostByDistance = d > settings.searchRadius + 200
            let turnedAway = !isRelevant(t.camera, distance: d, from: fix.point, heading: heading, isTracked: true)
                && d > t.minDistance + 100
            if lostByDistance || turnedAway {
                tracked[key] = nil
                continue
            }
            tracked[key] = t
        }
    }

    private func addNewCandidates(fix: VehicleFix, heading: Double) {
        for (cam, d) in index.cameras(near: fix.point, radius: settings.searchRadius) {
            guard tracked[cam.id] == nil, cooldown[cam.id] == nil else { continue }
            guard !isCoveredBySection(cam) else { continue }
            guard isRelevant(cam, distance: d, from: fix.point, heading: heading, isTracked: false) else { continue }
            tracked[cam.id] = Tracked(camera: cam, phase: .approaching, minDistance: d, distance: d)
        }
    }

    /// 判斷照相點是否跟目前行進有關：必須在前方，且（有方向資料時）取締方向要相符。
    func isRelevant(_ camera: Camera, distance: Double, from point: GeoPoint,
                    heading: Double, isTracked: Bool) -> Bool {
        // 已經在追蹤、且非常接近時，GPS 方位角不準，直接視為相關。
        if isTracked && distance < 30 { return true }
        let aheadDiff = GeoMath.angleDifference(GeoMath.bearing(from: point, to: camera.point), heading)
        if let camHeading = camera.heading {
            return GeoMath.angleDifference(heading, camHeading) <= settings.directionTolerance
                && aheadDiff <= settings.aheadToleranceWithHeading
        }
        if let axis = camera.axis {
            // 雙向照相但已知道路軸向（南北或東西）：兩個方向都算，橫向道路的車不算。
            let d = GeoMath.angleDifference(heading, axis)
            return min(d, 180 - d) <= settings.directionTolerance
                && aheadDiff <= settings.aheadToleranceWithHeading
        }
        return aheadDiff <= settings.aheadToleranceWithoutHeading
    }

    /// 區間照相機落在已知的區間路線上：由 `SectionSpeedTracker` 提醒（預告、倒數），
    /// 這裡不再當成一支固定照相提醒，否則隧道中段的那支會在隧道裡才跳出來，也會和倒數重複。
    /// 資料裡沒有對應區間的區間照相機（無法解析的那些）仍然照一般照相提醒。
    func isCoveredBySection(_ camera: Camera) -> Bool {
        guard camera.type == .section else { return false }
        if let known = coveredBySection[camera.id] { return known }
        let covered = sections.contains { section in
            let path = section.displayPath
            return zip(path, path.dropFirst()).contains { a, b in
                GeoMath.project(camera.point, ontoSegment: a, b).distance <= sectionCameraCoverage
            }
        }
        coveredBySection[camera.id] = covered
        return covered
    }

    /// 找出起點或終點離照相機 500 m 內、最近的區間群組。
    func nearbySectionGroup(for camera: Camera) -> String? {
        var best: (String, Double)?
        for s in sections {
            let d = min(GeoMath.distance(camera.point, s.start), GeoMath.distance(camera.point, s.end))
            if d <= 500 && (best == nil || d < best!.1) {
                best = (s.groupID, d)
            }
        }
        return best?.0
    }

    private func updateOverspeed(target t: Tracked, fix: VehicleFix, events: inout [CameraAlertEvent]) {
        guard t.phase >= .pre, t.camera.type.enforcesSpeed, let limit = t.camera.speedLimit else {
            if isOverspeed {
                isOverspeed = false
                events.append(.overspeedEnded)
            }
            return
        }
        // 區間測速的照相機用「區間容許值」，其他照相用一般的超速容許值。
        let threshold = t.camera.type == .section
            ? settings.sectionEffectiveLimit(limit, sectionID: nearbySectionGroup(for: t.camera))
            : Double(limit) + settings.overspeedToleranceKmh
        let over = fix.speedKmh > threshold
        if over && !isOverspeed {
            isOverspeed = true
            lastBeep = fix.timestamp
            events.append(.overspeedStarted(limit: limit, speedKmh: fix.speedKmh))
        } else if over && isOverspeed {
            if let last = lastBeep, fix.timestamp.timeIntervalSince(last) >= settings.overspeedBeepInterval {
                lastBeep = fix.timestamp
                events.append(.overspeedBeep)
            }
        } else if !over && isOverspeed {
            isOverspeed = false
            events.append(.overspeedEnded)
        }
    }
}
