import Foundation

/// Live Activity 更新時一併發出的提醒內容。
/// iPhone 和 CarPlay 由系統顯示 Live Activity 本身；標題和內文依 Apple 文件只有 Apple Watch 會用到。
public struct ActivityAlertContent: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// 決定哪些事件要讓 Live Activity 跳出提醒。
/// 不在 CarPlay 的 Dashboard 頁面時，系統只會用畫面底部的通知呈現提醒，所以重要時刻一定要發。
/// 持續嗶聲、每分鐘倒數這類重複的事件只靠語音，不跳通知，以免畫面一直被打斷。
public enum ActivityAlertPolicy {
    /// 一次定位只會發一則提醒，同時有多個事件時取最重要的：
    /// 超速 > 近距 > 區間超速 > 進入區間 > 區間歸零 > 預告。
    /// - Parameter cameraOverspeedActive: 照相機前已經在超速警示；這時區間超速不重複提醒（和語音的規則相同）。
    public static func alert(cameraEvents: [CameraAlertEvent],
                             sectionEvents: [SectionEvent],
                             cameraOverspeedActive: Bool = false) -> ActivityAlertContent? {
        var overspeed: ActivityAlertContent?
        var near: ActivityAlertContent?
        var pre: ActivityAlertContent?
        for event in cameraEvents {
            switch event {
            case let .overspeedStarted(limit, _):
                overspeed = ActivityAlertContent(title: "您已超速", body: "速限\(limit)")
            case let .nearAlert(camera, distance, _):
                near = cameraAlert(camera, distance: distance)
            case let .preAlert(camera, distance):
                pre = cameraAlert(camera, distance: distance)
            case .passed, .overspeedBeep, .overspeedEnded:
                break
            }
        }

        var sectionOverspeed: ActivityAlertContent?
        var entered: ActivityAlertContent?
        var zero: ActivityAlertContent?
        for event in sectionEvents {
            switch event {
            case let .approaching(section, distance):
                pre = pre ?? ActivityAlertContent(title: "前方區間測速",
                                                  body: "\(AnnouncementFormatter.spokenDistance(distance))後進入，速限\(section.speedLimit)")
            case let .overspeedStarted(threshold):
                if !cameraOverspeedActive {
                    sectionOverspeed = ActivityAlertContent(title: "區間測速超速", body: "車速超過\(threshold)")
                }
            case let .entered(section, minimumSeconds):
                entered = ActivityAlertContent(title: "進入區間測速",
                                               body: "速限\(section.speedLimit)，至少需要\(minimumSeconds)秒")
            case .zeroReached:
                zero = ActivityAlertContent(title: "區間時間已到", body: "可依速限行駛")
            case .remaining, .completed, .aborted, .overspeedBeep, .overspeedEnded:
                break
            }
        }

        return overspeed ?? near ?? sectionOverspeed ?? entered ?? zero ?? pre
    }

    private static func cameraAlert(_ camera: Camera, distance: Double) -> ActivityAlertContent {
        var body = "前方\(AnnouncementFormatter.spokenDistance(distance))"
        if let limit = camera.speedLimit, camera.type.enforcesSpeed {
            body += "，速限\(limit)"
        }
        return ActivityAlertContent(title: camera.displayTypeName, body: body)
    }
}
