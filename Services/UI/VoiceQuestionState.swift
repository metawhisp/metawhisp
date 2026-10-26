import Foundation

/// Observable state machine for the floating voice-question window, and the
/// owner of each voice question from the long press to its answer or its
/// error (ITER-079). Drives the voice Island (`VoiceIslandPresenter`,
/// `VoiceIslandView`, ITER-078): listening → transcribing → thinking →
/// answered or error → idle.
///
/// Every step names its question. A step for a question that was closed — Esc,
/// the auto-dismiss — or replaced by a newer one changes nothing, so a closed
/// question never comes back and an old answer never lands under a new
/// question. Every way the ask ends, including no answer in time, ends the
/// question.
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

    /// How a question ends, from what its ask came to (ITER-079).
    enum Ending: Equatable {
        case answer(String, speaks: Bool)
        case error(String, retryByVoice: Bool)
    }

    /// Written only here: every step names its question (ITER-079).
    @Published private(set) var phase: Phase = .idle
    @Published var isSpeaking: Bool = false
    @Published private(set) var transcript: String = ""
    /// The current error can be fixed by asking again by voice (ITER-078):
    /// decided where the question failed, and only then does the island say
    /// "Hold Right ⌘ to try again".
    @Published private(set) var errorRetriesByVoice = false

    /// The question the island is about; nil once it is closed.
    private(set) var question: UUID?

    /// Told when a question is closed or replaced, so what it still has
    /// running outside the island — its recording, its transcription, its
    /// answer's speech — stops too. The coordinator sets it.
    var onQuestionClosed: ((UUID) -> Void)?

    /// The current question's wait for its answer (ITER-051 F1.9, ITER-079).
    /// Closing or replacing the question cancels it, and that cancels the chat
    /// send it waits on — which (via the AsyncStream's onTermination) stops the
    /// local decode loop within ~1 token instead of letting a closed question
    /// keep burning GPU.
    private var activeSendTask: Task<Void, Never>?
    /// The chat send itself. A newer question's send waits for it to finish
    /// unwinding: MetaChat answers one message at a time.
    private var activeAsk: Task<ChatService.SendOutcome, Never>?
    /// The question whose ask has started: a question is asked once (Codex
    /// review round 1, P2-1).
    private var askedQuestion: UUID?

    /// When the current voice popup session opened. ChatService voice path uses
    /// this as a lower bound when fetching `<previous_messages>` — so:
    ///   - popup open → LLM sees Q&A from THIS session (multi-turn within popup)
    ///   - popup dismissed → reset to nil → next ⌘ long-press starts fresh
    /// Typed MetaChat messages from other days are not surfaced to voice path.
    var voiceSessionStartedAt: Date?

    /// The app uses `shared`; tests make their own.
    init() {}

    /// A new question: the island listens. A question still open is replaced:
    /// its ask is cancelled and its owner is told. A send left running after
    /// its question ran out of time stops too: the user has moved on.
    @discardableResult
    func startListening() -> UUID {
        // First listening event of a session — anchor the session start.
        // Subsequent listenings within the same open popup keep the same anchor
        // so multi-turn context survives.
        if voiceSessionStartedAt == nil {
            voiceSessionStartedAt = Date()
        }
        let replaced = question
        activeSendTask?.cancel()
        activeAsk?.cancel()
        let id = UUID()
        question = id
        transcript = ""
        errorRetriesByVoice = false
        phase = .listening
        if let replaced { onQuestionClosed?(replaced) }
        return id
    }

    /// Whether `id` is the question the island shows now.
    func isOpen(_ id: UUID) -> Bool {
        question == id && phase != .idle
    }

    func transcribing(_ id: UUID) {
        guard isOpen(id) else { return }
        phase = .transcribing
    }

    func thinking(_ id: UUID, transcript: String) {
        guard isOpen(id) else { return }
        self.transcript = transcript
        phase = .thinking
    }

    /// Shows the answer; false when the question is no longer open — a late
    /// answer must not resurrect a closed or replaced question (F1.9).
    @discardableResult
    func answered(_ id: UUID, _ text: String) -> Bool {
        guard isOpen(id) else { return false }
        phase = .answered(text: text)
        return true
    }

    /// `retryByVoice`: asking again by voice can fix it — too quiet, too
    /// short, nothing heard — unlike a dead microphone or a missing engine.
    func failed(_ id: UUID, _ text: String, retryByVoice: Bool = false) {
        guard isOpen(id) else { return }
        errorRetriesByVoice = retryByVoice
        phase = .error(text: text)
    }

    /// Asks for `id`'s answer and ends the question with it — or with an error
    /// for every other outcome, and when nothing comes within `limit`. A
    /// cancelled ask ends nothing: its question was closed or replaced, and its
    /// send stops. A late send goes on, so its reply still lands in MetaChat.
    /// `speak` says an answer that asks for no confirm; nil keeps it silent.
    func answer(_ id: UUID, transcript: String, within limit: Duration,
                ask: @escaping @Sendable (String) async -> ChatService.SendOutcome,
                speak: ((String) -> Void)?) {
        guard isOpen(id), askedQuestion != id else { return }
        askedQuestion = id
        // A send this question replaced finishes unwinding first, inside this
        // question's limit; a send cancelled while it waits never goes out.
        let previousAsk = activeAsk
        let send = Task { () -> ChatService.SendOutcome in
            _ = await previousAsk?.value
            guard !Task.isCancelled else { return .failed("Cancelled") }
            return await ask(transcript)
        }
        activeAsk = send
        activeSendTask = Task { [weak self] in
            let outcome = await Deadline.run(within: limit) { await send.value }
            // Closed or replaced: the send stops too. Late: only the island ends.
            if outcome == nil, Task.isCancelled { send.cancel() }
            guard !Task.isCancelled, let self else { return }
            switch Self.ending(of: outcome) {
            case .answer(let text, let speaks):
                let shown = self.answered(id, text)
                NSLog("[VoiceQuestion] answer %d chars, shown=%@ spoken=%@", text.count,
                      shown ? "yes" : "no", shown && speaks && speak != nil ? "yes" : "no")
                if shown, speaks { speak?(text) }
            case .error(let text, let retryByVoice):
                NSLog("[VoiceQuestion] ended in an error (%@)", outcome.map { Self.kind(of: $0) } ?? "no answer in time")
                self.failed(id, text, retryByVoice: retryByVoice)
            }
        }
    }

    /// How a question ends, from what its ask came to; nil is an ask that did
    /// not answer in time.
    static func ending(of outcome: ChatService.SendOutcome?) -> Ending {
        switch outcome {
        case .answered(let text, let pendingTool)?:
            // A change waits for its confirm in MetaChat: it is read, not
            // spoken, and the island says where to confirm it.
            guard pendingTool else { return .answer(text, speaks: !text.isEmpty) }
            let hint = "Open MetaChat to confirm."
            return .answer(text.isEmpty ? hint : text + "\n\n" + hint, speaks: false)
        case .busy?:
            // The island adds "Hold Right ⌘ to try again".
            return .error("MetaChat is still answering another message.", retryByVoice: true)
        case .noAccess?:
            return .error("No AI is set up to answer. Sign in to Pro, add an API key, or turn on the local model in Settings.",
                          retryByVoice: false)
        case .failed(let message)?:
            return .error(message, retryByVoice: false)
        case .empty?:
            return .error("Nothing was heard.", retryByVoice: true)
        case .errandStarted?:
            // The errand started; its own result comes later in MetaChat.
            return .answer("", speaks: false)
        case nil:
            return .error("No answer came in time.", retryByVoice: false)
        }
    }

    /// The outcome's kind for the log; never its text, which is the user's.
    private static func kind(of outcome: ChatService.SendOutcome) -> String {
        switch outcome {
        case .answered: "answered"
        case .busy: "busy"
        case .noAccess: "no access"
        case .failed: "failed"
        case .empty: "empty"
        case .errandStarted: "errand started"
        }
    }

    /// The user closes the island: Esc, or its close button. Clears
    /// `voiceSessionStartedAt` so the NEXT ⌘ long-press starts a fresh
    /// session — no chat history bleed across popup closures. The question is
    /// closed: its ask is cancelled — also one still running after the island
    /// ran out of time, so a late reply starts nothing the user closed (Codex
    /// review round 1, P1-2) — and its owner is told (ITER-079).
    func dismiss() {
        activeAsk?.cancel()
        close()
    }

    /// The island closes itself after an answer or an error: `question` only
    /// if it is still the one shown — a timer set for an old question never
    /// closes a newer one (ITER-079). A send still running after the island
    /// ran out of time goes on, so its reply lands in MetaChat (P3-C).
    func dismiss(ifStill question: UUID) {
        guard self.question == question else { return }
        close()
    }

    private func close() {
        let closed = question
        question = nil
        activeSendTask?.cancel()   // F1.9 — stop the in-flight generation
        phase = .idle
        isSpeaking = false
        transcript = ""
        errorRetriesByVoice = false
        voiceSessionStartedAt = nil
        if let closed { onQuestionClosed?(closed) }
    }

    var isVisible: Bool {
        if case .idle = phase { return false }
        return true
    }
}
