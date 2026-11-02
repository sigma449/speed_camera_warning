import ActivityKit
import Foundation

/// 管理 Live Activity：開始、節流更新、結束。
/// 只在本機更新（不使用推播），所以免費的開發者帳號也能用。
@MainActor
final class ActivityController {
    typealias State = SpeedCamActivityAttributes.ContentState

    private var activity: Activity<SpeedCamActivityAttributes>?
    private var lastState: State?
    private var lastUpdate = Date.distantPast
    private(set) var startedAt: Date?

    var enabled = true

    var isRunning: Bool {
        guard let activity else { return false }
        return activity.activityState == .active || activity.activityState == .stale
    }

    /// Live Activity 最長可以存在 8 小時；接近上限時，App 回到前景會重新開始。
    var needsRestart: Bool {
        guard let startedAt else { return false }
        return Date().timeIntervalSince(startedAt) > 7.5 * 3600 || !isRunning
    }

    func start(initial: State) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endAllExisting()
        do {
            let attributes = SpeedCamActivityAttributes(startedAt: Date())
            activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: initial, staleDate: nil),
                                            pushType: nil)
            startedAt = Date()
            lastState = initial
            lastUpdate = Date()
        } catch {
            activity = nil
            startedAt = nil
        }
    }

    /// 更新內容。為了省電與避免被系統限流，只在有意義的變化時才更新：
    /// 模式或速限改變、超速狀態改變、距離變化超過一定幅度（近距離時 20 m，遠距離 50 m）、車速變化 5 km/h 以上。
    func update(_ state: State, force: Bool = false) {
        guard let activity else { return }
        if activity.activityState == .ended || activity.activityState == .dismissed {
            self.activity = nil
            return
        }
        let now = Date()
        let interval = now.timeIntervalSince(lastUpdate)
        if !force, let last = lastState {
            let significant = state.mode != last.mode
                || state.speedLimit != last.speedLimit
                || state.isOverspeed != last.isOverspeed
                || state.cameraTypeName != last.cameraTypeName
                || state.sectionZero != last.sectionZero
                || state.sectionEarliestExit != last.sectionEarliestExit
                || state.maneuverText != last.maneuverText
            let distance = state.distanceMeters ?? state.maneuverDistance ?? 0
            let lastDistance = last.distanceMeters ?? last.maneuverDistance ?? 0
            let step: Double = distance < 400 ? 20 : 50
            let distanceChanged = abs(distance - lastDistance) >= step
            let speedChanged = abs(state.currentSpeedKmh - last.currentSpeedKmh) >= 5
            let averageChanged = state.sectionAverageKmh != last.sectionAverageKmh
            guard significant || ((distanceChanged || speedChanged || averageChanged) && interval >= 1) || interval >= 30 else {
                return
            }
        }
        lastState = state
        lastUpdate = now
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(120))
        Task {
            await activity.update(content)
        }
    }

    func end() {
        guard let activity else { return }
        let final = lastState ?? State()
        Task {
            await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate)
        }
        self.activity = nil
        startedAt = nil
        lastState = nil
    }

    private func endAllExisting() {
        for existing in Activity<SpeedCamActivityAttributes>.activities {
            Task {
                await existing.end(nil, dismissalPolicy: .immediate)
            }
        }
        activity = nil
    }
}
