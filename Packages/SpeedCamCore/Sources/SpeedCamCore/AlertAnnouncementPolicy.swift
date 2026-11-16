import Foundation

public enum SpeechPriority: Int, Comparable, Sendable {
    case navigation, preAlert, section, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 只記錄既有語音引擎尚未完成的優先度，不保存語音或建立另一個佇列。
public struct SpeechPlaybackState: Sendable {
    private var priorities: [ObjectIdentifier: SpeechPriority] = [:]

    public init() {}

    /// 回傳是否應中斷原語音；同優先度保留原本「正在念才插播」的行為。
    public mutating func submit(_ id: ObjectIdentifier, priority: SpeechPriority,
                                urgent: Bool, isSpeaking: Bool) -> Bool {
        let highest = priorities.values.max()
        let mayInterrupt = highest.map { priority >= $0 } ?? true
        let replacesPendingLower = highest.map { priority > $0 } ?? false
        let interrupt = urgent && mayInterrupt && (isSpeaking || replacesPendingLower)
        if interrupt { priorities.removeAll() }
        priorities[id] = priority
        return interrupt
    }

    public mutating func finish(_ id: ObjectIdentifier) {
        priorities.removeValue(forKey: id)
    }

    public mutating func reset() {
        priorities.removeAll()
    }
}

/// 同一批先送近距／超速，再送區間、預告；跨批次的插播由 SpeechPlaybackState 保護。
public enum AlertAnnouncementPolicy {
    public static func speech(camera: CameraAlertResult?, section: SectionResult?, speedKmh: Double?,
                               settings: AlertSettings, suggestedKmh: Int?,
                               cameraOverspeedActive: Bool) -> [SpokenAnnouncement] {
        var candidates: [SpokenAnnouncement] = []
        if let camera, let speedKmh {
            candidates = CameraAnnouncementPolicy.speech(for: camera, speedKmh: speedKmh, settings: settings)
        }
        candidates += (section?.events ?? []).compactMap {
            sectionSpeech($0, settings: settings, suggestedKmh: suggestedKmh,
                          cameraOverspeedActive: cameraOverspeedActive)
        }
        return candidates.enumerated().sorted {
            if $0.element.priority == $1.element.priority { return $0.offset < $1.offset }
            return $0.element.priority > $1.element.priority
        }.map(\.element)
    }

    private static func sectionSpeech(_ event: SectionEvent, settings: AlertSettings, suggestedKmh: Int?,
                                       cameraOverspeedActive: Bool) -> SpokenAnnouncement? {
        let text: String
        var urgent = false
        var priority = SpeechPriority.section
        switch event {
        case let .approaching(section, distance):
            let threshold = settings.thresholds(speedLimit: section.speedLimit, currentSpeedKmh: 0).pre
            text = AnnouncementFormatter.sectionApproaching(section: section, announcedDistance:
                AnnouncementFormatter.announcedDistance(distance, threshold: threshold))
        case let .entered(section, minimumSeconds):
            text = AnnouncementFormatter.sectionEntered(section: section, minimumSeconds: minimumSeconds,
                effectiveLimitKmh: settings.sectionEffectiveLimit(section.speedLimit, sectionID: section.groupID))
            urgent = true
        case let .remaining(seconds):
            text = AnnouncementFormatter.sectionRemaining(seconds: seconds, suggestedKmh: suggestedKmh)
        case .zeroReached:
            text = AnnouncementFormatter.sectionZero
        case let .completed(_, averageKmh, withinLimit):
            text = AnnouncementFormatter.sectionCompleted(averageKmh: averageKmh, withinLimit: withinLimit)
        case let .overspeedStarted(threshold):
            guard !cameraOverspeedActive else { return nil }
            text = AnnouncementFormatter.sectionOverspeed(threshold: threshold)
            urgent = true
            priority = .critical
        case .aborted, .overspeedBeep, .overspeedEnded:
            return nil
        }
        return SpokenAnnouncement(text: text, urgent: urgent, priority: priority)
    }
}
