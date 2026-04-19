import Foundation

/// Observable state machine for the floating voice-question window.
/// Drives FloatingVoiceView's visuals: listening → transcribing → thinking → answered → idle.
///
/// spec://BACKLOG#Phase6
@MainActor
final class VoiceQuestionState: ObservableObject {
    static let shared = VoiceQuestionState()

    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case thinking
        case answered(text: String)
        case error(text: String)
    }

    @Published var phase: Phase = .idle
    @Published var isSpeaking: Bool = false
    @Published var transcript: String = ""

    private init() {}

    func startListening() {
        transcript = ""
        phase = .listening
    }

    func transcribing() {
        phase = .transcribing
    }

    func thinking(transcript: String) {
        self.transcript = transcript
        phase = .thinking
    }

    func answered(_ text: String) {
        phase = .answered(text: text)
    }

    func failed(_ text: String) {
        phase = .error(text: text)
    }

    /// Hide the window. Called on Esc, or auto after TTS finish.
    func dismiss() {
        phase = .idle
        isSpeaking = false
        transcript = ""
    }

    var isVisible: Bool {
        if case .idle = phase { return false }
        return true
    }
}
