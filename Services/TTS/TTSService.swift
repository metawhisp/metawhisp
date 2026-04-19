import AVFoundation
import Foundation

/// Text-to-speech service. MVP uses AVSpeechSynthesizer (Apple-native, offline, free).
/// Premium TTS (OpenAI / ElevenLabs — "Sloane") deferred — see BACKLOG#Phase6+.
/// spec://BACKLOG#Phase6
@MainActor
final class TTSService: ObservableObject {
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private let delegateShim = SynthesizerDelegate()

    init() {
        synthesizer.delegate = delegateShim
        delegateShim.onStart = { [weak self] in
            self?.isSpeaking = true
            VoiceQuestionState.shared.isSpeaking = true
        }
        delegateShim.onFinish = { [weak self] in
            self?.isSpeaking = false
            VoiceQuestionState.shared.isSpeaking = false
        }
    }

    /// Speak the given text. Respects settings (voice id + speed).
    /// Interrupts any ongoing utterance first.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = selectedVoice(forHint: trimmed)
        utterance.rate = rate(for: AppSettings.shared.ttsSpeed)
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - Voice selection

    /// Returns configured voice, or falls back to system default for detected language of the text.
    private func selectedVoice(forHint text: String) -> AVSpeechSynthesisVoice? {
        let configured = AppSettings.shared.ttsVoice
        if !configured.isEmpty, let v = AVSpeechSynthesisVoice(identifier: configured) {
            return v
        }
        // Heuristic: detect Cyrillic → ru-RU voice, else system locale.
        let isCyrillic = text.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        let preferredLang = isCyrillic ? "ru-RU" : Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        return AVSpeechSynthesisVoice(language: preferredLang)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Map user 0.5x–2.0x multiplier to AVSpeechUtterance rate range (0.0…1.0).
    /// AVSpeechUtteranceDefaultSpeechRate ≈ 0.5 (normal).
    private func rate(for speedMultiplier: Double) -> Float {
        let base = Double(AVSpeechUtteranceDefaultSpeechRate)  // ≈ 0.5
        let raw = base * speedMultiplier
        let minR = Double(AVSpeechUtteranceMinimumSpeechRate)
        let maxR = Double(AVSpeechUtteranceMaximumSpeechRate)
        return Float(min(max(raw, minR), maxR))
    }

    /// Voices filtered to languages we care about (en, ru). Used by Settings UI.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { v in
            v.language.hasPrefix("en") || v.language.hasPrefix("ru")
        }
        .sorted { $0.name < $1.name }
    }
}

/// Small NSObject shim because AVSpeechSynthesizerDelegate requires NSObject conformance.
private final class SynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onStart?() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }
}
