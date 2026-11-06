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
    /// 近距（例如 100 m）
    case nearAlert(camera: Camera, distance: Double)
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
    public var sections: [SpeedSection] = []

    private struct Tracked {
        var camera: Camera
        var phase: AlertPhase
        var minDistance: Double
        var distance: Double
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
    }

    /// 目前採用的行進方向（低速時沿用上一次的有效方向）。
    public var currentCourse: Double? { lastCourse }

    public func process(_ fix: VehicleFix) -> CameraAlertResult {
        var events: [CameraAlertEvent] = []

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
            let th = settings.thresholds(speedLimit: t.camera.speedLimit, currentSpeedKmh: fix.speedKmh)
            if t.distance <= th.near && t.phase < .near {
                t.phase = .near
                events.append(.nearAlert(camera: t.camera, distance: t.distance))
            } else if t.distance <= th.pre && t.phase < .pre {
                t.phase = .pre
                events.append(.preAlert(camera: t.camera, distance: t.distance))
            }
            tracked[key] = t
            updateOverspeed(target: t, fix: fix, events: &events)
            target = CameraTarget(camera: t.camera, distance: t.distance, phase: t.phase, isOverspeed: isOverspeed)
        } else if isOverspeed {
            isOverspeed = false
            events.append(.overspeedEnded)
        }

        return CameraAlertResult(events: events, target: target)
    }

    // MARK: - 內部流程

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

            if behindAndClose || movingAwayAfterClose {
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
