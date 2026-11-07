import ActivityKit
import Foundation
import OSLog
import SpeedCamCore

private let activityLog = Logger(subsystem: "tw.speedcammap.app", category: "liveActivity")

/// AppModel 用的介面。需要的 API 是 iOS 16.2 才有的，舊系統用 `NoLiveActivity`。
@MainActor
protocol LiveActivityControlling: AnyObject {
    var enabled: Bool { get set }
    var needsRestart: Bool { get }
    /// 設定頁顯示的狀態，實機看不到時才知道原因。
    var statusText: String { get }
    func start(initial: SpeedCamActivityState)
    func update(_ state: SpeedCamActivityState, alert: ActivityAlertContent?)
    /// 不管節流，立刻更新一次（例如剛接上 CarPlay）。
    func refresh(_ state: SpeedCamActivityState)
    func end()
}

enum LiveActivityFactory {
    @MainActor
    static func make() -> any LiveActivityControlling {
        if #available(iOS 16.2, *), LegacySupport.supportsLiveActivity {
            return ActivityController()
        }
        return NoLiveActivity()
    }
}

/// 舊系統沒有 Live Activity，什麼都不做。
@MainActor
final class NoLiveActivity: LiveActivityControlling {
    var enabled = false
    var needsRestart: Bool { false }
    var statusText: String { "這支 iPhone 不支援" }
    func start(initial: SpeedCamActivityState) {}
    func update(_ state: SpeedCamActivityState, alert: ActivityAlertContent?) {}
    func refresh(_ state: SpeedCamActivityState) {}
    func end() {}
}

/// 管理 Live Activity：開始、節流更新、結束。
/// 只在本機更新（不使用推播），所以免費的開發者帳號也能用。
@available(iOS 16.2, *)
@MainActor
final class ActivityController: LiveActivityControlling {
    typealias State = SpeedCamActivityState

    private var activity: Activity<SpeedCamActivityAttributes>?
    private var lastState: State?
    private var lastUpdate = Date.distantPast
    private(set) var startedAt: Date?
    /// 最近一次開始失敗的原因。
    private var lastFailure: String?
    /// 還沒送出的最新內容。系統處理得慢時只留最新一筆，不要排隊，否則畫面會越來越落後。
    private var pending: (content: ActivityContent<State>, alert: AlertConfiguration?)?
    private var isSending = false

    var enabled = true

    var isRunning: Bool {
        guard let activity else { return false }
        return activity.activityState == .active || activity.activityState == .stale
    }

    /// 需要重新開始：沒有成功開始過（剛開 App 時可能被系統拒絕）、已經被結束，或接近 8 小時上限。
    var needsRestart: Bool {
        guard enabled else { return false }
        guard let startedAt else { return true }
        return Date().timeIntervalSince(startedAt) > 7.5 * 3600 || !isRunning
    }

    var statusText: String {
        if !enabled { return "已關閉" }
        if isRunning { return "顯示中" }
        if !ActivityAuthorizationInfo().areActivitiesEnabled { return "iPhone 設定裡的即時動態是關閉的" }
        if let lastFailure { return "沒有顯示：\(lastFailure)" }
        return "沒有顯示（開始巡航後會自動顯示）"
    }

    func start(initial: State) {
        guard enabled else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            activityLog.notice("live activity not enabled in Settings")
            return
        }
        let existing = Activity<SpeedCamActivityAttributes>.activities
        // App 重新開啟時已經有一個在跑：接著用，不要結束再開新的，CarPlay 上才不會消失又出現。
        if let current = existing.first(where: {
            $0.activityState == .active && Date().timeIntervalSince($0.attributes.startedAt) < 7.5 * 3600
        }) {
            for other in existing where other.id != current.id {
                Task { await other.end(nil, dismissalPolicy: .immediate) }
            }
            activity = current
            startedAt = current.attributes.startedAt
            lastFailure = nil
            activityLog.notice("live activity adopted \(current.id, privacy: .public)")
            refresh(initial)
            return
        }
        endAllExisting()
        do {
            let now = Date()
            activity = try Activity.request(attributes: SpeedCamActivityAttributes(startedAt: now),
                                            content: ActivityContent(state: initial, staleDate: nil),
                                            pushType: nil)
            startedAt = now
            lastState = initial
            lastUpdate = now
            lastFailure = nil
            activityLog.notice("live activity started")
        } catch {
            activity = nil
            startedAt = nil
            lastFailure = error.localizedDescription
            activityLog.error("live activity failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 更新內容。為了省電與避免被系統限流，只在有意義的變化時才更新：
    /// 模式或速限改變、超速狀態改變、距離變化超過一定幅度（近距離時 20 m，遠距離 50 m）、車速變化 5 km/h 以上。
    /// 距離和車速最多每 2 秒更新一次，名額留給模式改變和提醒。
    /// 有 alert 時一定會更新，並讓系統跳出提醒（CarPlay 不在 Dashboard 頁面時顯示為畫面底部的通知）。
    /// 本機更新就能發提醒，不需要推播。聲音目前用系統預設音（Apple 文件只有預設音和自訂檔案兩種，沒有靜音選項）。
    func update(_ state: State, alert: ActivityAlertContent?) {
        guard let activity else { return }
        if activity.activityState == .ended || activity.activityState == .dismissed {
            activityLog.notice("live activity ended by system: \(String(describing: activity.activityState), privacy: .public)")
            self.activity = nil
            return
        }
        let now = Date()
        let interval = now.timeIntervalSince(lastUpdate)
        if alert == nil, let last = lastState {
            let significant = state.mode != last.mode
                || state.speedLimit != last.speedLimit
                || state.isOverspeed != last.isOverspeed
                || state.cameraTypeName != last.cameraTypeName
                || state.sectionZero != last.sectionZero
                || state.sectionEarliestExit != last.sectionEarliestExit
                || (state.mode == .navigation && state.maneuverText != last.maneuverText)
            let distance = state.distanceMeters ?? state.maneuverDistance ?? 0
            let lastDistance = last.distanceMeters ?? last.maneuverDistance ?? 0
            let step: Double = distance < 400 ? 20 : 50
            let distanceChanged = abs(distance - lastDistance) >= step
            let speedChanged = abs(state.currentSpeedKmh - last.currentSpeedKmh) >= 5
            let averageChanged = state.sectionAverageKmh != last.sectionAverageKmh
            let hintChanged = state.navHint != last.navHint
            guard significant || ((distanceChanged || speedChanged || averageChanged || hintChanged) && interval >= 2) || interval >= 30 else {
                return
            }
        }
        send(state, alert: alert)
    }

    func refresh(_ state: State) {
        guard activity != nil else { return }
        send(state, alert: nil)
    }

    func end() {
        guard let activity else { return }
        let final = lastState ?? State()
        pending = nil
        Task {
            await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate)
        }
        self.activity = nil
        startedAt = nil
        lastState = nil
    }

    private func send(_ state: State, alert: ActivityAlertContent?) {
        guard let activity else { return }
        let now = Date()
        lastState = state
        lastUpdate = now
        let configuration = alert.map {
            AlertConfiguration(title: LocalizedStringResource(stringLiteral: $0.title),
                               body: LocalizedStringResource(stringLiteral: $0.body),
                               sound: .default)
        }
        // 蓋掉還沒送出的內容，但提醒要留著
        pending = (ActivityContent(state: state, staleDate: now.addingTimeInterval(120)), configuration ?? pending?.alert)
        guard !isSending else { return }
        isSending = true
        Task { [weak self] in
            while let self, let next = self.pending {
                self.pending = nil
                await activity.update(next.content, alertConfiguration: next.alert)
            }
            self?.isSending = false
        }
    }

    private func endAllExisting() {
        pending = nil
        for existing in Activity<SpeedCamActivityAttributes>.activities {
            Task {
                await existing.end(nil, dismissalPolicy: .immediate)
            }
        }
        activity = nil
    }
}
