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

    /// ITER-051 F1.9 review fix — the in-flight chat send for the CURRENT
    /// popup session. `dismiss()` cancels it, which (via the AsyncStream's
    /// onTermination) stops the local decode loop within ~1 token instead of
    /// letting a dismissed question keep burning GPU and then resurrect the
    /// pill with a stale answer.
    var activeSendTask: Task<Void, Never>?

    /// When the current voice popup session opened. ChatService voice path uses
    /// this as a lower bound when fetching `<previous_messages>` — so:
    ///   - popup open → LLM sees Q&A from THIS session (multi-turn within popup)
    ///   - popup dismissed → reset to nil → next ⌘ long-press starts fresh
    /// Typed MetaChat messages from other days are not surfaced to voice path.
    var voiceSessionStartedAt: Date?

    private init() {}

    func startListening() {
        // First listening event of a session — anchor the session start.
        // Subsequent listenings within the same open popup keep the same anchor
        // so multi-turn context survives.
        if voiceSessionStartedAt == nil {
            voiceSessionStartedAt = Date()
        }
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
        // F1.9 — a late-arriving answer must not resurrect a dismissed popup.
        guard phase != .idle else { return }
        phase = .answered(text: text)
    }

    func failed(_ text: String) {
        guard phase != .idle else { return }
        phase = .error(text: text)
    }

    /// Hide the window. Called on Esc, or auto after TTS finish.
    /// Clears `voiceSessionStartedAt` so the NEXT ⌘ long-press starts a fresh
    /// session — no chat history bleed across popup closures.
    func dismiss() {
        activeSendTask?.cancel()   // F1.9 — stop the in-flight generation
        activeSendTask = nil
        phase = .idle
        isSpeaking = false
        transcript = ""
        voiceSessionStartedAt = nil
    }

    var isVisible: Bool {
        if case .idle = phase { return false }
        return true
    }
}
