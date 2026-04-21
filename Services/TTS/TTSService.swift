import AVFoundation
import Foundation

/// Text-to-speech service. Two providers:
/// - Local (default): AVSpeechSynthesizer — offline, free, robotic
/// - Cloud (Pro only): OpenAI TTS via Pro proxy — natural voices (alloy/echo/fable/onyx/nova/shimmer)
///
/// Falls back to local if cloud fails (network down, license expired, server error).
/// spec://BACKLOG#Phase6
@MainActor
final class TTSService: ObservableObject {
    @Published var isSpeaking = false

    /// OpenAI TTS voice ids exposed to the Settings picker.
    static let cloudVoices = ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]

    private let synthesizer = AVSpeechSynthesizer()
    private let synthDelegate = SynthesizerDelegate()
    private var audioPlayer: AVAudioPlayer?
    private let playerDelegate = PlayerDelegate()
    private var currentDownload: Task<Void, Never>?

    init() {
        synthesizer.delegate = synthDelegate
        synthDelegate.onStart = { [weak self] in
            self?.isSpeaking = true
            VoiceQuestionState.shared.isSpeaking = true
        }
        synthDelegate.onFinish = { [weak self] in
            self?.isSpeaking = false
            VoiceQuestionState.shared.isSpeaking = false
        }
        playerDelegate.onFinish = { [weak self] in
            self?.audioPlayer = nil
            self?.isSpeaking = false
            VoiceQuestionState.shared.isSpeaking = false
        }
    }

    /// Speak the given text. Routes to cloud if Pro + enabled, else local.
    /// Falls back to local on cloud error. Interrupts any ongoing utterance first.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()

        if shouldUseCloud {
            // Set isSpeaking=true IMMEDIATELY so the floating UI's 6s auto-dismiss
            // timer extends while the mp3 is still downloading (download + playback
            // can easily exceed 6s on slow networks). Without this, stop() fires
            // from the auto-dismiss path and cancels the in-flight download.
            isSpeaking = true
            VoiceQuestionState.shared.isSpeaking = true
            currentDownload = Task { [weak self] in
                await self?.speakCloud(trimmed)
            }
        } else {
            speakLocal(trimmed)
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if let player = audioPlayer, player.isPlaying {
            player.stop()
        }
        audioPlayer = nil
        currentDownload?.cancel()
        currentDownload = nil
        isSpeaking = false
        VoiceQuestionState.shared.isSpeaking = false
    }

    // MARK: - Routing

    private var shouldUseCloud: Bool {
        AppSettings.shared.ttsCloudEnabled && LicenseService.shared.isPro
    }

    // MARK: - Local (AVSpeech)

    private func speakLocal(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = selectedLocalVoice(forHint: text)
        utterance.rate = rate(for: AppSettings.shared.ttsSpeed)
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    private func selectedLocalVoice(forHint text: String) -> AVSpeechSynthesisVoice? {
        let configured = AppSettings.shared.ttsVoice
        if !configured.isEmpty, let v = AVSpeechSynthesisVoice(identifier: configured) {
            return v
        }
        let isCyrillic = text.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        let preferredLang = isCyrillic ? "ru-RU" : Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        return AVSpeechSynthesisVoice(language: preferredLang)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func rate(for speedMultiplier: Double) -> Float {
        let base = Double(AVSpeechUtteranceDefaultSpeechRate)
        let raw = base * speedMultiplier
        let minR = Double(AVSpeechUtteranceMinimumSpeechRate)
        let maxR = Double(AVSpeechUtteranceMaximumSpeechRate)
        return Float(min(max(raw, minR), maxR))
    }

    // MARK: - Cloud (OpenAI via Pro proxy)

    private func speakCloud(_ text: String) async {
        do {
            let mp3 = try await fetchCloudTTS(text: text)
            try Task.checkCancellation()
            try await MainActor.run {
                try playCloudAudio(data: mp3)
            }
        } catch is CancellationError {
            // stop() was called (user dismissed / new speak started) — don't play anything
            await MainActor.run {
                self.isSpeaking = false
                VoiceQuestionState.shared.isSpeaking = false
            }
            NSLog("[TTS] Cloud cancelled, no fallback")
        } catch let error as URLError where error.code == .cancelled {
            // URLSession-level cancellation surfaces as URLError not CancellationError
            await MainActor.run {
                self.isSpeaking = false
                VoiceQuestionState.shared.isSpeaking = false
            }
            NSLog("[TTS] Cloud URLSession cancelled, no fallback")
        } catch {
            NSLog("[TTS] Cloud failed (%@), falling back to local", error.localizedDescription)
            await MainActor.run {
                // Reset before local path so synth didStart will set it again cleanly
                self.isSpeaking = false
                VoiceQuestionState.shared.isSpeaking = false
                self.speakLocal(text)
            }
        }
    }

    private func fetchCloudTTS(text: String) async throws -> Data {
        guard let key = LicenseService.shared.licenseKey else {
            throw NSError(domain: "TTS", code: 401, userInfo: [NSLocalizedDescriptionKey: "no license key"])
        }
        let url = URL(string: "https://api.metawhisp.com/api/pro/tts")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let body: [String: Any] = [
            "text": text,
            "voice": AppSettings.shared.ttsCloudVoice,
            "speed": AppSettings.shared.ttsSpeed,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "TTS", code: -1, userInfo: [NSLocalizedDescriptionKey: "no HTTP response"])
        }
        guard http.statusCode == 200 else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw NSError(domain: "TTS", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(snippet)"])
        }
        return data
    }

    private func playCloudAudio(data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = playerDelegate
        audioPlayer = player
        player.play()
        isSpeaking = true
        VoiceQuestionState.shared.isSpeaking = true
    }

    // MARK: - Voice list (Settings UI)

    /// Local AVSpeech voices filtered to en + ru.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { v in
            v.language.hasPrefix("en") || v.language.hasPrefix("ru")
        }
        .sorted { $0.name < $1.name }
    }
}

// MARK: - Delegates

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

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinish?() }
    }
}
