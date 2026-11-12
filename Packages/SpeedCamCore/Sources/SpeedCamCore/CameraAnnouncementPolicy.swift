import Foundation

public struct SpokenAnnouncement: Equatable, Sendable {
    public var text: String
    public var urgent: Bool

    public init(text: String, urgent: Bool = false) {
        self.text = text
        self.urgent = urgent
    }
}

/// App 與 replay 共用同一批次的語音選擇；不能只看這一秒是否有超速開始事件。
public enum CameraAnnouncementPolicy {
    public static func speech(for result: CameraAlertResult, speedKmh: Double,
                               settings: AlertSettings) -> [SpokenAnnouncement] {
        let combinedNear = result.events.contains {
            if case let .nearAlert(camera, _, afterPre) = $0 {
                return afterPre && isOverspeed(camera, target: result.target)
            }
            return false
        }
        return result.events.compactMap { event in
            switch event {
            case let .preAlert(camera, distance):
                let th = settings.thresholds(speedLimit: camera.speedLimit, currentSpeedKmh: speedKmh)
                return SpokenAnnouncement(text: AnnouncementFormatter.cameraAlert(
                    camera: camera, announcedDistance: AnnouncementFormatter.announcedDistance(distance, threshold: th.pre)))
            case let .nearAlert(camera, distance, afterPre):
                let th = settings.thresholds(speedLimit: camera.speedLimit, currentSpeedKmh: speedKmh)
                let announced = AnnouncementFormatter.announcedDistance(distance, threshold: th.near)
                let text = afterPre
                    ? AnnouncementFormatter.cameraNearAfterPre(announcedDistance: announced,
                                                                isOverspeed: isOverspeed(camera, target: result.target))
                    : AnnouncementFormatter.cameraAlert(camera: camera, announcedDistance: announced)
                return SpokenAnnouncement(text: text, urgent: true)
            case let .overspeedStarted(limit, _):
                return combinedNear ? nil : SpokenAnnouncement(text: AnnouncementFormatter.overspeed(limit: limit), urgent: true)
            case .passed, .overspeedBeep, .overspeedEnded:
                return nil
            }
        }
    }

    private static func isOverspeed(_ camera: Camera, target: CameraTarget?) -> Bool {
        camera.enforcesSpeed && camera.speedLimit != nil
            && target?.camera.id == camera.id && target?.isOverspeed == true
    }
}
