import Foundation

/// App 的音訊循環只依這份節拍排程；Core 的定位事件仍保留供語音、Live Activity 與 replay 使用。
public struct FixedCameraBeepSchedule: Sendable {
    public struct Playback: Equatable, Sendable {
        public let firstBeepAt: Date
        public let interval: TimeInterval

        public func lastBeep(at now: Date) -> Date? {
            let elapsed = now.timeIntervalSince(firstBeepAt)
            guard elapsed >= 0 else { return nil }
            return firstBeepAt.addingTimeInterval(floor(elapsed / interval) * interval)
        }
    }

    public enum Change: Equatable, Sendable {
        case unchanged
        case start(Playback)
        case stop
    }

    public private(set) var playback: Playback?
    public private(set) var expiresAt: Date?
    private var previousBeepAt: Date?

    public init() {}

    public func lastBeep(at now: Date) -> Date? {
        guard let expiresAt, now < expiresAt else { return nil }
        return playback?.lastBeep(at: now) ?? previousBeepAt
    }

    public mutating func update(target: CameraTarget?, fix: VehicleFix?, interval: TimeInterval,
                                now: Date, gpsGapSeconds: TimeInterval = 2.5) -> Change {
        guard let target, target.isOverspeed, target.phase >= .pre,
              target.camera.enforcesSpeed, target.camera.speedLimit != nil,
              let fix, fix.isReliable, fix.speedMps.isFinite,
              now >= fix.timestamp, now.timeIntervalSince(fix.timestamp) < gpsGapSeconds else {
            return stop()
        }
        let expired = expiresAt.map { now >= $0 } ?? true
        let last = lastBeep(at: now)
        expiresAt = fix.timestamp.addingTimeInterval(gpsGapSeconds)
        let interval = AlertSettings.clampedOverspeedBeepInterval(interval)
        if playback == nil || expired {
            previousBeepAt = nil
            let next = Playback(firstBeepAt: now, interval: interval)
            playback = next
            return .start(next)
        }
        guard playback?.interval != interval else { return .unchanged }
        previousBeepAt = last
        let due = last?.addingTimeInterval(interval) ?? now
        let next = Playback(firstBeepAt: max(now, due), interval: interval)
        playback = next
        return .start(next)
    }

    public mutating func expire(at now: Date) -> Change {
        guard let expiresAt, now >= expiresAt else { return .unchanged }
        return stop()
    }

    @discardableResult
    public mutating func stop() -> Change {
        let wasPlaying = playback != nil
        playback = nil
        expiresAt = nil
        previousBeepAt = nil
        return wasPlaying ? .stop : .unchanged
    }
}
