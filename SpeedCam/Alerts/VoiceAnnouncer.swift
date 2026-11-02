import AVFoundation
import Foundation
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

    var voiceEnabled = true
    var beepEnabled = true

    override init() {
        super.init()
        synthesizer.delegate = self
        beepPlayer = try? AVAudioPlayer(data: ToneGenerator.wavData(frequency: 1_400, duration: 0.18, volume: 0.9))
        passPlayer = try? AVAudioPlayer(data: ToneGenerator.doubleBeep())
        beepPlayer?.prepareToPlay()
        passPlayer?.prepareToPlay()
    }

    /// 念出一句話。urgent = true 時會打斷正在念的內容（例如近距提醒、超速）。
    func speak(_ text: String, urgent: Bool = false) {
        guard voiceEnabled, !text.isEmpty else { return }
        activateSession()
        if urgent && synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .word)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = 0.53
        utterance.volume = 1.0
        synthesizer.speak(utterance)
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
        synthesizer.stopSpeaking(at: .immediate)
        beepPlayer?.stop()
        passPlayer?.stop()
        deactivateIfIdle()
    }

    // MARK: - 音訊工作階段

    private func activateSession() {
        deactivateTask?.cancel()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            // 無法取得音訊時（例如正在通話）就略過，不影響其他功能。
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
        let busy = synthesizer.isSpeaking || (beepPlayer?.isPlaying ?? false) || (passPlayer?.isPlaying ?? false)
        guard !busy else {
            scheduleDeactivate(after: 0.5)
            return
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.scheduleDeactivate(after: 0.4)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.scheduleDeactivate(after: 0.4)
        }
    }
}
