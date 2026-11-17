import AVFoundation
import Combine
import Foundation
import os
import SpeedCamCore

/// 語音與提示音。
/// - 播報時把其他音訊（音樂、Podcast）暫時調小聲（ducking），播完再恢復。
/// - 嗶聲用程式產生的 WAV，不需要另外的音檔。
@MainActor
final class VoiceAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "zh-TW")
    private var beepPlayer: AVAudioPlayer?
    private var passPlayer: AVAudioPlayer?
    private var deactivateTask: Task<Void, Never>?
    private var playbackState = SpeechPlaybackState()
    private var fixedBeepSchedule = FixedCameraBeepSchedule()
    private var fixedBeepPlayer: AVAudioPlayer?
    private var fixedBeepExpiryTask: Task<Void, Never>?
    private var interruptionSubscription: AnyCancellable?
    private var audioInterrupted = false

    var voiceEnabled = true
    var beepEnabled = true {
        didSet { if !beepEnabled { stopFixedCameraBeep() } }
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        beepPlayer = try? AVAudioPlayer(data: ToneGenerator.overspeedBeep())
        passPlayer = try? AVAudioPlayer(data: ToneGenerator.doubleBeep())
        beepPlayer?.prepareToPlay()
        passPlayer?.prepareToPlay()
        interruptionSubscription = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else {
                    Logger(subsystem: "tw.speedcammap.app", category: "audio")
                        .error("音訊中斷通知缺少有效類型")
                    return
                }
                let interrupted = type == .began
                Task { @MainActor [weak self] in
                    self?.audioInterrupted = interrupted
                    self?.stopFixedCameraBeep()
                }
            }
    }

    /// urgent 只允許打斷同等或較低優先度；未插播的內容仍交給原本的語音引擎。
    func speak(_ text: String, urgent: Bool = false, priority: SpeechPriority = .navigation) {
        guard voiceEnabled, !text.isEmpty else { return }
        activateSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = 0.53
        utterance.volume = 1.0
        if playbackState.submit(ObjectIdentifier(utterance), priority: priority,
                                urgent: urgent, isSpeaking: synthesizer.isSpeaking) {
            synthesizer.stopSpeaking(at: .word)
        }
        updateFixedBeepVolume()
        synthesizer.speak(utterance)
    }

    func synchronizeFixedCameraBeep(target: CameraTarget?, fix: VehicleFix?,
                                    interval: TimeInterval, gpsGapSeconds: TimeInterval) {
        let previousExpiry = fixedBeepSchedule.expiresAt
        let change = fixedBeepSchedule.update(target: beepEnabled && !audioInterrupted ? target : nil, fix: fix,
            interval: interval, now: Date(), gpsGapSeconds: gpsGapSeconds)
        switch change {
        case .unchanged:
            break
        case .stop:
            stopFixedCameraBeep()
            return
        case let .start(playback):
            fixedBeepPlayer?.stop()
            fixedBeepPlayer = nil
            do {
                let player = try AVAudioPlayer(data: ToneGenerator.repeatingOverspeedBeep(interval: playback.interval))
                player.numberOfLoops = -1
                player.volume = playbackState.hasCriticalSpeech ? 0 : 1
                player.prepareToPlay()
                guard activateSession() else {
                    stopFixedCameraBeep()
                    return
                }
                let delay = max(0, playback.firstBeepAt.timeIntervalSinceNow)
                guard player.play(atTime: player.deviceCurrentTime + delay) else {
                    Logger(subsystem: "tw.speedcammap.app", category: "audio")
                        .error("固定照相嗶聲循環無法開始播放")
                    stopFixedCameraBeep()
                    return
                }
                fixedBeepPlayer = player
            } catch {
                Logger(subsystem: "tw.speedcammap.app", category: "audio")
                    .error("固定照相嗶聲循環建立失敗：\(error.localizedDescription, privacy: .public)")
                stopFixedCameraBeep()
                return
            }
        }
        if fixedBeepSchedule.expiresAt != previousExpiry { scheduleFixedBeepExpiry() }
    }

    private func scheduleFixedBeepExpiry() {
        fixedBeepExpiryTask?.cancel()
        guard let expiry = fixedBeepSchedule.expiresAt else { return }
        // 這是定位失聯的截止鬧鐘，不是第二套嗶聲計時；實際節拍由 WAV／音訊時鐘處理。
        fixedBeepExpiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let remaining = expiry.timeIntervalSinceNow
                if remaining <= 0 { break }
                try? await Task.sleep(nanoseconds: UInt64(ceil(remaining * 1_000_000_000)))
            }
            guard !Task.isCancelled, let self, self.fixedBeepSchedule.expiresAt == expiry else { return }
            if self.fixedBeepSchedule.expire(at: Date()) == .stop { self.stopFixedCameraBeep() }
        }
    }

    private func stopFixedCameraBeep() {
        let hadPlayback = fixedBeepSchedule.playback != nil || fixedBeepPlayer != nil
        fixedBeepSchedule.stop()
        fixedBeepExpiryTask?.cancel()
        fixedBeepExpiryTask = nil
        fixedBeepPlayer?.stop()
        fixedBeepPlayer = nil
        if hadPlayback { scheduleDeactivate(after: 0.4) }
    }

    private func updateFixedBeepVolume() {
        // 近距／超速語音優先；略過的嗶聲不補播，也不移動下一聲節拍。
        fixedBeepPlayer?.volume = playbackState.hasCriticalSpeech ? 0 : 1
    }

    /// 超速嗶聲。
    func beep() {
        guard beepEnabled, let player = beepPlayer else { return }
        activateSession()
        player.currentTime = 0
        player.play()
        scheduleDeactivate(after: 0.6)
    }

    /// 通過照相點的雙嗶聲。
    func passTone() {
        guard beepEnabled, let player = passPlayer else { return }
        activateSession()
        player.currentTime = 0
        player.play()
        scheduleDeactivate(after: 0.8)
    }

    func stopAll() {
        playbackState.reset()
        synthesizer.stopSpeaking(at: .immediate)
        beepPlayer?.stop()
        passPlayer?.stop()
        stopFixedCameraBeep()
        deactivateIfIdle()
    }

    // MARK: - 音訊工作階段

    @discardableResult
    private func activateSession() -> Bool {
        deactivateTask?.cancel()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
            return true
        } catch {
            Logger(subsystem: "tw.speedcammap.app", category: "audio")
                .error("音訊工作階段啟用失敗：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func scheduleDeactivate(after seconds: Double) {
        deactivateTask?.cancel()
        deactivateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.deactivateIfIdle()
        }
    }

    private func deactivateIfIdle() {
        guard fixedBeepSchedule.playback == nil else { return }
        let busy = synthesizer.isSpeaking || (beepPlayer?.isPlaying ?? false) || (passPlayer?.isPlaying ?? false)
        guard !busy else {
            scheduleDeactivate(after: 0.5)
            return
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.playbackState.finish(ObjectIdentifier(utterance))
            self?.updateFixedBeepVolume()
            self?.scheduleDeactivate(after: 0.4)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.playbackState.finish(ObjectIdentifier(utterance))
            self?.updateFixedBeepVolume()
            self?.scheduleDeactivate(after: 0.4)
        }
    }
}
