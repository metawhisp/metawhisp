import Foundation

/// What kind of answer a card holds.
enum MeetingAnswerKind: String, Equatable, Sendable {
    /// The answer to a question: the shortcut, the automatic check, or a typed question.
    case answer
    /// The answer to an action: Questions, Recap, More, Screen.
    case action
}

/// Where an answer came from.
enum MeetingAnswerProvenance: String, Equatable, Sendable {
    /// The transcript of the meeting.
    case transcript
    /// The text on the screen.
    case screen
}

/// The action a card came from.
enum MeetingAnswerAction: String, Equatable, Sendable {
    /// The questions the user can ask now.
    case questions
    /// The recap of the meeting so far.
    case recap
    /// The deeper answer to the newest card.
    case more
    /// The answer about the text on the screen.
    case screen
}

/// The blocks an answer is made of, in the order they are read.
enum MeetingAnswerBlock: Equatable, Sendable {
    /// The bold sentence that opens an answer.
    case headline(String)
    /// A catch point.
    case bullet(String)
    /// A line of prose.
    case paragraph(String)

    /// The text of the block.
    var text: String {
        switch self {
        case .headline(let text), .bullet(let text), .paragraph(let text):
            return text
        }
    }
}

/// One answer, as the overlay shows it.
struct MeetingAnswer: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The recording generation captured by the request that produced this card.
    let generation: Int
    /// The line of the other side the answer is about, when there was one.
    let heard: String?
    /// What kind of answer this is.
    let kind: MeetingAnswerKind
    /// Where the answer came from.
    let provenance: MeetingAnswerProvenance
    /// The action the answer came from, when it came from one.
    let action: MeetingAnswerAction?
    /// The blocks of the answer, in the order they are read.
    let blocks: [MeetingAnswerBlock]
    /// When it was made.
    let createdAt: Date
    /// The typed question owned by this answer's request, when there was one.
    let question: String?
    /// Captured when the request starts, before any asynchronous work.
    let requestStartedAt: ContinuousClock.Instant

    init(id: UUID, generation: Int = 0, heard: String?, kind: MeetingAnswerKind,
         provenance: MeetingAnswerProvenance, action: MeetingAnswerAction?,
         blocks: [MeetingAnswerBlock], createdAt: Date, question: String? = nil,
         requestStartedAt: ContinuousClock.Instant = .now) {
        self.id = id
        self.generation = generation
        self.heard = heard
        self.kind = kind
        self.provenance = provenance
        self.action = action
        self.blocks = blocks
        self.createdAt = createdAt
        self.question = question
        self.requestStartedAt = requestStartedAt
    }

    /// The bold sentence that opens the answer.
    var headline: String? {
        for block in blocks {
            if case .headline(let text) = block { return text }
        }
        return nil
    }

    /// The catch points of the answer.
    var bullets: [String] {
        blocks.compactMap { block in
            if case .bullet(let text) = block { return text }
            return nil
        }
    }

    /// The answer as one text.
    var plainText: String {
        blocks.map(\.text).joined(separator: "\n")
    }

    /// Whether the answer joins the earlier exchanges of the next request.
    ///
    /// Only a transcript answer joins reusable history. An action is passed
    /// explicitly only when More expands it; screen content is never reused.
    var joinsHistory: Bool {
        kind == .answer && provenance == .transcript
    }

    /// Whether the answer marks the transcript it used.
    ///
    /// The same rule as the history: only a plain answer advances the
    /// answered boundary (§3.0).
    var advancesAnsweredBoundary: Bool { joinsHistory }

    /// Whether the *More* button may expand this answer.
    ///
    /// A recap may not: it is the meeting, not an answer to expand. An
    /// answer about the screen may not either — the screen text reaches no
    /// later request (§3.0).
    var mayBeExpanded: Bool {
        switch provenance {
        case .screen:
            return false
        case .transcript:
            switch kind {
            case .answer:
                return true
            case .action:
                return action == .questions || action == .more
            }
        }
    }
}

extension MeetingAnswerText {
    /// The blocks of a plain answer: the headline and the catch points, in
    /// that order. The card draws a plain answer exactly as it did before
    /// (§3.0).
    var blocks: [MeetingAnswerBlock] {
        [.headline(headline)] + bullets.map { .bullet($0) }
    }
}

/// The status lines the overlay shows.
enum MeetingAnswerStatus {
    /// Nothing was heard yet.
    static let nothingHeard = "Nothing heard yet"
    static let nothingReadable = "Nothing readable on the screen"
    /// The session ended; the answers need a new sign-in.
    static let signInAgain = "Sign in again to get answers"
    /// There is no route to the model at all.
    static let noRoute = "Answers need Pro or your own AI key"
    /// The answer did not come in time.
    static let noAnswerInTime = "No answer in time — press again"
    /// The answer could not be read.
    static let couldNotGetAnAnswer = "Could not get an answer — press again"
    /// The beginning of the line that says the automatic answers are paused.
    ///
    /// The card shows the line, and the line is rendered again when the
    /// shortcut of the user changes — the kind of the status is kept, not
    /// the text (§3.6).
    static let automaticPausedPrefix = "Automatic answers paused — press "
    /// The automatic answers are paused.
    ///
    /// The line names the shortcut that is registered now — the one the user
    /// actually presses. Without a registered shortcut it asks for the help
    /// shortcut, which the user may still have (§3.6).
    static func automaticPaused(shortcutLabel: String?) -> String {
        guard let shortcutLabel, !shortcutLabel.isEmpty else {
            return automaticPausedPrefix + "your help shortcut"
        }
        return automaticPausedPrefix + shortcutLabel
    }
    /// The monthly meeting minutes are gone.
    static let balanceSpent = "Live hints stopped — monthly meeting minutes used up"

    /// The status lines an answer takes away.
    ///
    /// An answer takes them away: the answer is on the card now, and the
    /// line under it is stale — the sign-in and the missing route are stale
    /// too, once an answer came through them.
    ///
    /// The line of the spent balance is not among them: it is not about this
    /// answer, it is about the meeting (§3.4).
    static let clearedByAnAnswer: Set<String> = [nothingHeard, nothingReadable,
                                                 noAnswerInTime,
                                                 couldNotGetAnAnswer,
                                                 signInAgain,
                                                 noRoute]
}

/// What a route to the model answered.
struct MeetingAnswerReply: Equatable, Sendable {
    /// The status of the route: 200 when it worked, 401 when the session
    /// ended, 408 when the deadline came first.
    var status: Int
    /// How long the route asked us to wait before trying again.
    var retryAfter: TimeInterval?
    /// The raw reply.
    var text: String?
}

/// One route to the model.
@MainActor
protocol MeetingAnswerRoute: AnyObject {
    /// The route's name, for the logs.
    var routeName: String { get }
    /// Whether the route can be used now.
    var isAvailable: Bool { get }
    /// Asks the model.
    ///
    /// The token is the one of the session that asks. The route holds no
    /// session state of its own: the routes outlive a session, and a request
    /// that was on its way when the meeting ended never leaves the app
    /// (§6.15).
    func answer(system: String,
                user: String,
                deadlineMs: Int,
                stopToken: LiveHintsStopToken) async throws -> MeetingAnswerReply
    func stream(system: String,
                user: String,
                deadlineMs: Int,
                stopToken: LiveHintsStopToken,
                handle: LiveHintsRequestHandle) -> AsyncStream<MeetingAnswerStreamEvent>
}

/// The Pro route: the heavy tier, over the real adapter.
@MainActor
final class ProAnswerRoute: MeetingAnswerRoute {
    let routeName = "pro"

    private let client: ProAdviceClient

    init(client: ProAdviceClient? = nil) {
        self.client = client ?? .live
    }

    var isAvailable: Bool { client.hasLicenseKey }

    func answer(system: String,
                user: String,
                deadlineMs: Int,
                stopToken: LiveHintsStopToken) async throws -> MeetingAnswerReply {
        // The session may be over: the request never leaves the app (§6.15).
        guard !stopToken.isCancelled else { throw CancellationError() }
        let (status, retryAfter, text) = try await client.call(system: system,
                                                              user: user,
                                                              deadlineMs: deadlineMs)
        return MeetingAnswerReply(status: status, retryAfter: retryAfter, text: text)
    }

    func stream(system: String, user: String, deadlineMs: Int, stopToken: LiveHintsStopToken,
                handle: LiveHintsRequestHandle) -> AsyncStream<MeetingAnswerStreamEvent> {
        client.stream(system: system, user: user, deadlineMs: deadlineMs, stopToken: stopToken, handle: handle)
    }
}

/// The user's own key: the provider the settings name, under a deadline.
@MainActor
final class OwnKeyAnswerRoute: MeetingAnswerRoute {
    let routeName = "own-key"

    /// The key the user set.
    var apiKey: () -> String
    /// The provider the user set.
    var provider: () -> LLMProvider
    /// The completion. The live one is the OpenAI service; the tests bring
    /// their own so nothing reaches the network.
    var complete: @Sendable (String, String, String, LLMProvider) async throws -> String
    let lineTransport: MeetingAnswerLineTransport?

    init(apiKey: (() -> String)? = nil,
         provider: (() -> LLMProvider)? = nil,
         complete: (@Sendable (String, String, String, LLMProvider) async throws -> String)? = nil,
         lineTransport: MeetingAnswerLineTransport? = nil) {
        self.apiKey = apiKey ?? { AppSettings.shared.activeAPIKey }
        self.provider = provider ?? { LLMProvider(rawValue: AppSettings.shared.llmProvider) ?? .openai }
        self.complete = complete ?? { system, user, key, provider in
            try await OwnKeyAnswerRoute.liveCompletion(system: system, user: user, apiKey: key, provider: provider)
        }
        if let lineTransport {
            self.lineTransport = lineTransport
        } else if complete == nil {
            self.lineTransport = { request in try await MeetingAnswerStreamTransport.live(request) }
        } else {
            self.lineTransport = nil
        }
    }

    /// The live completion: the OpenAI service, with the provider the user set.
    nonisolated static func liveCompletion(system: String,
                                           user: String,
                                           apiKey: String,
                                           provider: LLMProvider) async throws -> String {
        try await OpenAIService().complete(system: system,
                                           user: user,
                                           apiKey: apiKey,
                                           provider: provider)
    }

    var isAvailable: Bool { !apiKey().isEmpty }

    func answer(system: String,
                user: String,
                deadlineMs: Int,
                stopToken: LiveHintsStopToken) async throws -> MeetingAnswerReply {
        let complete = self.complete
        let key = apiKey()
        let chosen = provider()
        let outcome = await LiveCall.run(within: .milliseconds(deadlineMs)) {
            // The session may be over: the request never leaves the app
            // (§6.15).
            guard !stopToken.isCancelled else { throw CancellationError() }
            return try await complete(system, user, key, chosen)
        }
        switch outcome {
        case .text(let text):
            return MeetingAnswerReply(status: 200, retryAfter: nil, text: text)
        case .timeout:
            return MeetingAnswerReply(status: 408, retryAfter: nil, text: nil)
        case .cancelled:
            return MeetingAnswerReply(status: 499, retryAfter: nil, text: nil)
        case .failed(let error):
            if let transportError = error as? URLError, transportError.code == .timedOut {
                return MeetingAnswerReply(status: 408, retryAfter: nil, text: nil)
            }
            if case let ProcessingError.http(status, _, retryAfter) = error {
                return MeetingAnswerReply(status: status, retryAfter: retryAfter, text: nil)
            }
            return MeetingAnswerReply(status: 500, retryAfter: nil, text: nil)
        }
    }
}

/// The local model: used only when neither cloud route exists.
@MainActor
final class LocalAnswerRoute: MeetingAnswerRoute {
    let routeName = "local"

    /// The most characters of the user message the local model takes.
    static let maxUserCharacters = 6_000

    /// Whether the local model is ready.
    var isReady: () -> Bool
    /// The completion. The live one is the local model; the tests bring their
    /// own so nothing is loaded.
    var complete: @Sendable (String, String, Int) async throws -> String

    init(isReady: (() -> Bool)? = nil,
         complete: @escaping @Sendable (String, String, Int) async throws -> String = { system, user, maxUserChars in
             try await LocalLLMService.shared.completeBlocking(system: system,
                                                                user: user,
                                                                maxUserChars: maxUserChars)
         }) {
        self.isReady = isReady ?? { LocalLLMService.shared.isReady }
        self.complete = complete
    }

    var isAvailable: Bool { isReady() }

    func answer(system: String,
                user: String,
                deadlineMs: Int,
                stopToken: LiveHintsStopToken) async throws -> MeetingAnswerReply {
        let complete = self.complete
        let outcome = await LiveCall.run(within: .milliseconds(deadlineMs)) {
            // The session may be over: the request never leaves the app
            // (§6.15).
            guard !stopToken.isCancelled else { throw CancellationError() }
            return try await complete(system, user, Self.maxUserCharacters)
        }
        switch outcome {
        case .text(let text):
            return MeetingAnswerReply(status: 200, retryAfter: nil, text: text)
        case .timeout:
            return MeetingAnswerReply(status: 408, retryAfter: nil, text: nil)
        case .cancelled:
            return MeetingAnswerReply(status: 499, retryAfter: nil, text: nil)
        case .failed:
            return MeetingAnswerReply(status: 500, retryAfter: nil, text: nil)
        }
    }
}

/// The identity of one request: the id that owns the card, the generation of
/// the meeting it belongs to, and the handle that calls it off.
///
/// The identity is taken when the user acts — before any await — so a request
/// that waits for something cannot lose its place to a request that came
/// after it (§3.0).
struct MeetingRequestIdentity {
    let uuid: UUID
    /// The id of the request. The newest one owns the card.
    let id: UInt64
    /// The generation of the recording when the request was made.
    let generation: Int
    /// The handle that calls this request off.
    let handle: LiveHintsRequestHandle
    /// Captured at the action, including any pending transcript or screen capture wait.
    let startedAt: ContinuousClock.Instant

    init(id: UInt64, generation: Int, handle: LiveHintsRequestHandle, startedAt: ContinuousClock.Instant) {
        self.uuid = UUID()
        self.id = id
        self.generation = generation
        self.handle = handle
        self.startedAt = startedAt
    }
}

/// What came back from the routes.
enum MeetingAnswerOutcome: Equatable {
    /// The model answered.
    case text(String)
    /// The session ended.
    case unauthorized
    /// A route answered with a status that is not 200.
    case failed(status: Int, retryAfter: TimeInterval?)
    /// There is no route at all.
    case noRoute
    /// The session was stopped before the request went out.
    case cancelled
}

/// The routes to the model, and the memo's summary call over the same chain.
@MainActor
final class MeetingAnswerRoutes {

    enum Kind: String {
        case pro
        case ownKey = "own-key"
        case local
    }

    /// The Pro route.
    var pro: MeetingAnswerRoute?
    /// The user's own key.
    var ownKey: MeetingAnswerRoute?
    /// The local model — used only when neither cloud route exists.
    var local: MeetingAnswerRoute?

    /// The prompt the memo asks for.
    var summaryPrompt: String = MeetingCoachService.summaryPrompt

    /// The budget the user message is built for.
    var budget: MeetingAnswerPrompts.Budget {
        (pro?.isAvailable == true || ownKey?.isAvailable == true) ? .cloud : .local
    }

    /// Asks the model.
    ///
    /// One route answers the request: the first one that can be used now, in
    /// the order of §3.4 — Pro, the user's own key, then the local model. The
    /// answer of that route is the answer of the request: a refusal is not
    /// hidden behind the next route, and the request gets one deadline, not
    /// one per route.
    ///
    /// The token is the one of the session that asks. The routes hold no
    /// session state: they outlive a session, and a session that starts
    /// while another one is still winding down must not lend its token to
    /// the old session's request (§6.15).
    func ask(system: String,
             user: String,
             deadlineMs: Int,
             stopToken: LiveHintsStopToken) async -> MeetingAnswerOutcome {
        // The session may be over: the request never leaves the app (§6.15).
        guard !stopToken.isCancelled else { return .cancelled }
        guard let (_, route) = eligibleRoute() else { return .noRoute }
        do {
            let reply = try await route.answer(system: system,
                                               user: user,
                                               deadlineMs: deadlineMs,
                                               stopToken: stopToken)
            if reply.status == 200, let text = reply.text { return .text(text) }
            if reply.status == 401 { return .unauthorized }
            return .failed(status: reply.status, retryAfter: reply.retryAfter)
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .timedOut {
            return .failed(status: 408, retryAfter: nil)
        } catch {
            return .failed(status: 0, retryAfter: nil)
        }
    }

    /// The route the request goes to: the first one that can be used now. The
    /// local model is used only when neither cloud route exists.
    private func eligibleRoute() -> (Kind, MeetingAnswerRoute)? {
        if let pro, pro.isAvailable { return (.pro, pro) }
        if let ownKey, ownKey.isAvailable { return (.ownKey, ownKey) }
        if let local, local.isAvailable { return (.local, local) }
        return nil
    }

    /// Card callers stream; memo requests use whole replies.
    func stream(system: String, user: String, deadlineMs: Int,
                stopToken: LiveHintsStopToken, handle: LiveHintsRequestHandle)
        -> (Kind, AsyncStream<MeetingAnswerStreamEvent>)? {
        guard let (kind, route) = eligibleRoute() else { return nil }
        return (kind, route.stream(system: system, user: user, deadlineMs: deadlineMs,
                                   stopToken: stopToken, handle: handle))
    }

    /// The memo provider of the transcript: the summary prompt, over the same
    /// routes the answers use.
    ///
    /// The token travels with the fold: the provider is called with the token
    /// of the session the fold belongs to, and with no other one (§6.15).
    func makeMemoProvider() -> LiveMeetingTranscript.MemoProvider {
        let routes = self
        return { previous, lines, stopToken in
            await routes.summarize(previous: previous, lines: lines, stopToken: stopToken)
        }
    }

    /// Asks for the summary of the lines that fell out of the window.
    private func summarize(previous: String?,
                           lines: [LiveMeetingTranscript.Line],
                           stopToken: LiveHintsStopToken) async -> String? {
        guard !lines.isEmpty else { return nil }
        // The session may be over: the summary never leaves the app (§6.15).
        guard !stopToken.isCancelled else { return nil }
        let body = memoBody(previous: previous, lines: lines)
        let outcome = await ask(system: summaryPrompt,
                                user: body,
                                deadlineMs: MeetingAnswerService.automaticDeadlineMs,
                                stopToken: stopToken)
        if case .text(let text) = outcome { return text }
        return nil
    }

    /// The body of the summary: what was said before, and what was said since.
    private func memoBody(previous: String?, lines: [LiveMeetingTranscript.Line]) -> String {
        var parts: [String] = []
        if let previous, !previous.isEmpty {
            parts.append(MeetingAnswerPrompts.memoLabel + "\n" + previous)
        }
        let rendered = lines.map { LiveMeetingTranscript.renderedLine($0) }.joined(separator: "\n")
        parts.append("Lines since that summary:\n" + rendered)
        return parts.joined(separator: "\n\n")
    }
}

/// The in-call answers: what the model is asked, what it answered, and what
/// the overlay shows.
///
/// Why a `@MainActor` class and not an actor: everything it publishes — the
/// answers, the status line, the thinking flag — is state the overlay reads
/// on the main thread, and `MeetingCoachService`, the Pro route it calls,
/// lives there too. One actor for the state means the overlay never reads
/// half of an update. The work itself is asynchronous: every model call
/// suspends, and nothing blocks the main thread while it waits.
@MainActor
final class MeetingAnswerService {

    // MARK: - The rules

    /// The deadline of a shortcut request, in milliseconds.
    static let shortcutDeadlineMs = 6_000
    /// The deadline of an automatic check, in milliseconds.
    static let automaticDeadlineMs = 8_000
    static let actionDeadlineMs = 10_000
    /// How long the shortcut waits for a line that is still being transcribed.
    static let pendingThemWait: Duration = .seconds(2)
    /// The shortest gap between two started automatic checks.
    static let automaticSpacing: TimeInterval = 6
    /// The most automatic checks in one rolling hour.
    static let automaticCap = 240
    /// The window the cap counts in.
    static let automaticCapWindow: TimeInterval = 60 * 60
    /// The shortest gap between two shortcut presses.
    static let shortcutRepeatGuard: TimeInterval = 1
    /// The typed field and its request accept at most this many characters.
    static let maxQuestionCharacters = 500
    /// The pause after a 503 that has no Retry-After.
    static let defaultRetryAfter: TimeInterval = 60
    /// The most earlier exchanges kept.
    static let maxHistory = 6
    /// The most characters of an earlier answer kept.
    static let historyAnswerCharacters = 300
    /// The fewest letters or digits a line needs before it calls the model.
    static let minLetters = 4
    /// How long the "no answer" status stays.
    static let rejectStatusSeconds: TimeInterval = 5
    /// The seconds of the user's own speech after a line that answer it.
    static let answeredSpeechSeconds: Double = 1.5
    /// How often the waiting line looks at the clock.
    static let drainPoll: TimeInterval = 0.2

    // MARK: - What it is given

    /// The transcript of the meeting.
    private let transcript: LiveMeetingTranscript
    /// The routes to the model.
    private let routes: MeetingAnswerRoutes
    /// The time now. The tests move it by hand.
    private let clock: () -> Date
    private let timingNow: () -> ContinuousClock.Instant
    private let timingLog: (String) -> Void
    private let diagnosticLog: (String) -> Void
    /// Whether the automatic answers are on.
    private let isAutoOn: @MainActor () -> Bool
    /// The text of the `.them` utterance that is open or awaiting its final
    /// text, once it is known, and where that utterance ended. The app puts
    /// the line into the transcript before it answers.
    private let pendingThemText: @Sendable () async -> LivePendingText?
    /// The seconds of the user's own speech after a sample. The tracker that
    /// heard the speech is an actor, so the count is awaited.
    private let speechSeconds: @Sendable (Int) async -> Double
    /// What is known about the people and projects that were mentioned.
    private let relevantMemories: @MainActor @Sendable (String) -> String
    /// The pinned transcription language, when there is one.
    private let pinnedLanguage: @MainActor () -> String?
    /// The generation of the recording. A result of an older meeting is
    /// dropped.
    private let generation: @MainActor () -> Int
    /// The card the overlay draws. The answers, the status line and the
    /// thinking flag are published into it — the card owns that list, so
    /// there is one list and one owner.
    private let state: MeetingCoachState
    /// The cancellation of the session this service belongs to.
    ///
    /// The service asks the model only while the session runs: a shortcut
    /// that was waiting for a line, an automatic check and a memo fold that
    /// were on their way when the meeting ended never reach the model
    /// (§6.15).
    private let stopToken: LiveHintsStopToken
    private let screenEnabled: @MainActor () -> Bool
    private let captureScreen: @MainActor () async -> String?
    private let streamSleep: @MainActor @Sendable (Int) async throws -> Void

    // MARK: - The state

    /// The earlier exchanges, oldest first.
    private var history: [MeetingAnswerPrompts.Exchange] = []
    /// The automatic check that is running.
    private var runningCheck: RunningCheck?
    /// The line that waits for a check.
    private var pendingLine: LiveMeetingTranscript.Line?
    /// When the last automatic check started.
    private var lastAutomaticStart: Date?
    /// When the automatic checks started, for the cap.
    private var automaticStarts: [Date] = []
    /// Until when the automatic answers are paused.
    private var automaticPauseEnd: Date?
    /// The kind of the status line the service put up itself.
    ///
    /// The kind is kept, not the text: the line that names the shortcut is
    /// rendered again when the shortcut of the user changes (§3.6).
    private enum AutomaticStatus {
        /// The automatic answers are paused.
        case automaticPaused
    }
    /// The status line the service put up, and the kind it is.
    private var automaticStatus: AutomaticStatus?
    /// The last accepted press of each guarded manual action.
    private var lastManualPress: [ManualKind: Date] = [:]
    /// The end of the line the last answer was about.
    private var answeredThemEndSample: Int?
    /// The newest user request. Its result owns the card (§3.0).
    private var newestUserRequestId: UInt64 = 0
    /// The user request that is running.
    private var runningUserRequest: MeetingRequestIdentity?
    /// The newest automatic check.
    ///
    /// Its result owns the card while it is the newest one and no user
    /// request took its place (§3.4).
    private var newestAutomaticId: UInt64 = 0
    /// The requests that are running.
    private var runningRequests = 0
    /// The task that waits for the pending line.
    private var drainTask: Task<Void, Never>?
    /// The task that watches the pause of the automatic answers.
    private var pauseWatch: Task<Void, Never>?
    /// True when the meeting is over: the service starts nothing new, and the
    /// results of the requests that are running are dropped (§6.15).
    private var isStopped = false

    // MARK: - Setting it up

    init(transcript: LiveMeetingTranscript,
         routes: MeetingAnswerRoutes,
         clock: @escaping () -> Date = { Date() },
         timingNow: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
         timingLog: @escaping (String) -> Void = { NSLog("%@", $0) },
         diagnosticLog: @escaping (String) -> Void = { NSLog("%@", $0) },
         isAutoOn: @escaping @MainActor () -> Bool = { false },
         pendingThemText: @escaping @Sendable () async -> LivePendingText? = { nil },
         meSpeechSeconds: @escaping @Sendable (Int) async -> Double = { _ in 0 },
         relevantMemories: @escaping @MainActor @Sendable (String) -> String = { _ in "" },
         pinnedLanguage: @escaping @MainActor () -> String? = { nil },
         generation: @escaping @MainActor () -> Int = { 0 },
         state: MeetingCoachState = .shared,
         stopToken: LiveHintsStopToken = LiveHintsStopToken(),
         screenEnabled: @escaping @MainActor () -> Bool = { AppSettings.shared.screenContextEnabled },
         captureScreen: @escaping @MainActor () async -> String? = { nil },
         streamSleep: @escaping @MainActor @Sendable (Int) async throws -> Void = {
             try await Task.sleep(for: .milliseconds($0))
         }) {
        self.transcript = transcript
        self.routes = routes
        self.clock = clock
        self.timingNow = timingNow
        self.timingLog = timingLog
        self.diagnosticLog = diagnosticLog
        self.isAutoOn = isAutoOn
        self.pendingThemText = pendingThemText
        self.speechSeconds = meSpeechSeconds
        self.relevantMemories = relevantMemories
        self.pinnedLanguage = pinnedLanguage
        self.generation = generation
        self.state = state
        self.stopToken = stopToken
        self.screenEnabled = screenEnabled
        self.captureScreen = captureScreen
        self.streamSleep = streamSleep
    }

    // MARK: - What the overlay reads

    /// The answers, newest first. The card owns the list the overlay draws.
    var answers: [MeetingAnswer] { state.answers }

    /// Whether a request is running.
    var isThinking: Bool { state.isThinking }

    /// The status line the overlay shows.
    var status: String? { state.status }

    /// The automatic checks that were started in the last hour. The cap counts
    /// them, the superseded ones included.
    var startedAutomaticCheckCount: Int {
        pruneAutomaticStarts()
        return automaticStarts.count
    }

    /// Until when the automatic answers are paused.
    var automaticPausedUntil: Date? { automaticPauseEnd }

    /// Puts a status line up. It stays until it is replaced.
    func setStatus(_ text: String?) {
        state.setStatus(text)
    }

    /// Puts a status line up for a while.
    func setStatus(_ text: String, seconds: TimeInterval) {
        state.setStatus(text, seconds: seconds)
    }

    // MARK: - The triggers

    private enum ManualKind: String, Hashable {
        case shortcut, typed, questions, recap, more, screen

        init(_ action: MeetingAnswerAction) {
            switch action {
            case .questions: self = .questions
            case .recap: self = .recap
            case .more: self = .more
            case .screen: self = .screen
            }
        }
    }

    private enum PreflightReason: String {
        case repeatGuard = "repeat_guard"
        case emptyTranscript = "empty_transcript"
        case noExpandableCard = "no_expandable_card"
        case screenNil = "screen_nil"
        case settingOff = "setting_off"
        case superseded
        case noRoute = "no_route"
        case emptyQuestion = "empty_question"
        case unsupportedAction = "unsupported_action"
    }

    private func logManualEntry(_ kind: ManualKind) {
        diagnosticLog("[LiveHints] manual kind=\(kind.rawValue) phase=entry")
    }

    private func logPreflightExit(_ kind: ManualKind?, _ reason: PreflightReason) {
        guard let kind else { return }
        diagnosticLog("[LiveHints] manual kind=\(kind.rawValue) phase=preflight_exit reason=\(reason.rawValue)")
    }

    private func preflightIsCurrent(_ identity: MeetingRequestIdentity, kind: ManualKind?,
                                    check: RunningCheck? = nil) -> Bool {
        guard isCurrent(identity, check: check) else {
            logPreflightExit(kind, .superseded)
            return false
        }
        return true
    }

    /// The shortcut was pressed: the user wants to know what to say.
    func shortcutPressed() async {
        await requestShortcut()?.value
    }

    /// Captures identity in the event callback, before scheduling any work.
    @discardableResult
    func requestShortcut() -> Task<Void, Never>? {
        logManualEntry(.shortcut)
        guard let identity = beginUserRequest(kind: .shortcut) else { return nil }
        let task = Task { await performShortcut(identity) }
        identity.handle.attach { task.cancel() }
        stopToken.retain(task)
        return task
    }

    /// A button takes ownership before it reads the transcript or starts a task.
    @discardableResult
    func requestAction(_ action: MeetingAnswerAction) -> Task<Void, Never>? {
        let kind = ManualKind(action)
        logManualEntry(kind)
        guard action != .screen else {
            logPreflightExit(kind, .unsupportedAction)
            return nil
        }
        let expansion: String?
        if action == .more {
            guard state.displayedDraft == nil, let newest = answers.first, newest.mayBeExpanded else {
                logPreflightExit(kind, .noExpandableCard)
                return nil
            }
            expansion = newest.plainText
        } else {
            expansion = nil
        }
        guard let identity = beginUserRequest(kind: kind) else { return nil }
        let task = Task {
            defer { finishUserRequest(identity) }
            guard preflightIsCurrent(identity, kind: kind) else { return }
            let lines = await transcript.lines
            guard preflightIsCurrent(identity, kind: kind) else { return }
            guard action == .more || !lines.isEmpty else {
                logPreflightExit(kind, .emptyTranscript)
                setStatus(MeetingAnswerStatus.nothingHeard)
                return
            }
            let prompt = MeetingAnswerPrompts.actionPrompt(for: action)
            // This final history entry is required context, so it shares the ask's budget priority.
            let ask = expansion.map { MeetingAnswerPrompts.answeredLabel + $0 + "\n\n" + prompt } ?? prompt
            await runRequest(ask: ask, heard: nil, identity: identity,
                             deadlineMs: Self.actionDeadlineMs, check: nil, action: action)
        }
        identity.handle.attach { task.cancel() }
        stopToken.retain(task)
        return task
    }

    /// A distinct typed question takes ownership at Return or Send.
    @discardableResult
    func requestQuestion(_ text: String) -> Task<Void, Never>? {
        logManualEntry(.typed)
        guard !isStopped, !stopToken.isCancelled else {
            logPreflightExit(.typed, .superseded)
            return nil
        }
        let question = String(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.maxQuestionCharacters))
        guard !question.isEmpty else {
            logPreflightExit(.typed, .emptyQuestion)
            return nil
        }
        let identity = takeUserRequestIdentity()
        let task = Task {
            defer { finishUserRequest(identity) }
            guard preflightIsCurrent(identity, kind: .typed) else { return }
            await runRequest(ask: MeetingAnswerPrompts.typedAsk(text: question), heard: nil,
                             identity: identity, deadlineMs: Self.shortcutDeadlineMs, check: nil,
                             isTypedQuestion: true, question: question)
        }
        identity.handle.attach { task.cancel() }
        stopToken.retain(task)
        return task
    }

    /// Capture belongs only to this press; no screen-derived state is retained.
    @discardableResult
    func requestScreen() -> Task<Void, Never>? {
        logManualEntry(.screen)
        guard screenEnabled() else {
            logPreflightExit(.screen, .settingOff)
            return nil
        }
        guard let identity = beginUserRequest(kind: .screen) else { return nil }
        let task = Task {
            defer { finishUserRequest(identity) }
            guard preflightIsCurrent(identity, kind: .screen) else { return }
            guard screenEnabled() else {
                logPreflightExit(.screen, .settingOff)
                return
            }
            let captured = await captureScreen()
            guard preflightIsCurrent(identity, kind: .screen) else { return }
            guard screenEnabled() else {
                logPreflightExit(.screen, .settingOff)
                return
            }
            guard let captured, !captured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logPreflightExit(.screen, .screenNil)
                setStatus(MeetingAnswerStatus.nothingReadable, seconds: Self.rejectStatusSeconds)
                return
            }
            let screen = MeetingAnswerPrompts.screenBlock(String(captured.prefix(3_000)))
            let ask = screen + "\n\n" + MeetingAnswerPrompts.actionPrompt(for: .screen)
            await runRequest(ask: ask, heard: nil, identity: identity,
                             deadlineMs: Self.actionDeadlineMs, check: nil, action: .screen)
        }
        identity.handle.attach { task.cancel() }
        stopToken.retain(task)
        return task
    }

    private func beginUserRequest(kind: ManualKind) -> MeetingRequestIdentity? {
        guard !isStopped, !stopToken.isCancelled else {
            logPreflightExit(kind, .superseded)
            return nil
        }
        let now = clock()
        if let last = lastManualPress[kind], now.timeIntervalSince(last) < Self.shortcutRepeatGuard {
            logPreflightExit(kind, .repeatGuard)
            if let action = MeetingAnswerAction(rawValue: kind.rawValue) { state.flashRepeatedAction(action) }
            return nil
        }
        lastManualPress[kind] = now
        return takeUserRequestIdentity()
    }

    private func performShortcut(_ identity: MeetingRequestIdentity) async {
        defer { finishUserRequest(identity) }
        guard preflightIsCurrent(identity, kind: .shortcut) else { return }

        // A line that is still being transcribed: wait for it, but not long.
        let pending = await waitForPendingThemText()

        // The meeting may have ended while the shortcut waited: the question
        // belongs to a meeting that is over, and it is not answered (§6.15).
        guard preflightIsCurrent(identity, kind: .shortcut) else { return }

        let lines = await transcript.lines
        guard preflightIsCurrent(identity, kind: .shortcut) else { return }
        // The transcript can be empty while the question is still being
        // transcribed: what was heard is the text that is coming, and it is
        // enough to answer (§3.4).
        let isPendingKnown = !(pending?.text.isEmpty ?? true)
        guard !lines.isEmpty || isPendingKnown else {
            logPreflightExit(.shortcut, .emptyTranscript)
            setStatus(MeetingAnswerStatus.nothingHeard)
            return
        }

        let heard = newestHeardLine(lines, pending: pending)
        let ask: String
        if let heard, await isUnanswered(heard), letterCount(heard.text) >= Self.minLetters {
            ask = MeetingAnswerPrompts.forcedAsk(line: heard.text)
        } else {
            ask = MeetingAnswerPrompts.whatShouldISayAsk()
        }

        // The shortcut runs at once, even beside an automatic check.
        await runRequest(ask: ask,
                         heard: heard,
                         identity: identity,
                         deadlineMs: Self.shortcutDeadlineMs,
                         check: nil)
    }

    /// A line of the other side ended: the automatic check may fire.
    func themLineEnded(_ line: LiveMeetingTranscript.Line) async {
        guard !isStopped else { return }
        guard isAutoOn() else { return }
        guard letterCount(line.text) >= Self.minLetters else { return }

        if let running = runningCheck,
           running.line.startSample == line.startSample,
           running.line.text != line.text {
            // A continuation of the line the running check is about: that
            // check is superseded, and a new check for the joined line starts
            // at once — exempt from the spacing, counted toward the cap.
            running.superseded = true
            cancelCheck(running)
            runningCheck = nil
            if !startAutomatic(for: line, exemptFromSpacing: true) {
                pendingLine = join(pendingLine, line)
                scheduleDrain()
            }
            return
        }

        if runningCheck != nil {
            // A check is running: the line waits for it.
            pendingLine = join(pendingLine, line)
            // The drain watches the waiting line while the check runs: the
            // switch that goes off in the meantime is seen (§6.16).
            scheduleDrain()
            return
        }

        if startAutomatic(for: line, exemptFromSpacing: false) { return }

        // The spacing, the cap or the pause holds it back: the line waits.
        pendingLine = join(pendingLine, line)
        scheduleDrain()
    }

    /// The automatic answers were turned off: the line that waits for a check
    /// goes away at once (§6.16).
    ///
    /// The switch is not a poll: the line that waited must not be checked
    /// later, not even when the user turns the automatic answers on again.
    ///
    /// The automatic check that is running is called off by its handle. The
    /// session's token is not stopped: the manual answers, the speech
    /// recognition, the batches and the memo keep running (§3.0).
    func automaticTurnedOff() {
        guard !isStopped else { return }
        pendingLine = nil
        cancelCheck(runningCheck)
        runningCheck = nil
    }

    /// Forgets everything: a new meeting starts clean.
    func reset() {
        cancelCheck(runningCheck)
        cancelUserRequest(runningUserRequest)
        drainTask?.cancel()
        drainTask = nil
        pauseWatch?.cancel()
        pauseWatch = nil
        state.clearAnswers()
        history = []
        runningCheck = nil
        pendingLine = nil
        lastAutomaticStart = nil
        automaticStarts = []
        automaticPauseEnd = nil
        lastManualPress = [:]
        answeredThemEndSample = nil
        newestUserRequestId &+= 1
        runningUserRequest = nil
        newestAutomaticId &+= 1
        runningRequests = 0
        state.setThinking(false)
        state.setStatus(nil)
    }

    /// The meeting is over: nothing this service started goes on (§6.15).
    ///
    /// The line that waits for a check is dropped, the drain stops, and the
    /// requests that are running do not publish their answer — a result of a
    /// meeting that is over belongs to no meeting, and the next one must not
    /// answer the old one's question.
    func stop() {
        isStopped = true
        cancelCheck(runningCheck)
        cancelUserRequest(runningUserRequest)
        drainTask?.cancel()
        drainTask = nil
        pauseWatch?.cancel()
        pauseWatch = nil
        pendingLine = nil
        runningCheck = nil
        runningUserRequest = nil
        // Every request that is running becomes stale: its result is dropped.
        newestUserRequestId = newestUserRequestId &+ 1
        newestAutomaticId = newestAutomaticId &+ 1
    }

    // MARK: - The automatic checks

    /// Starts an automatic check for a line. Answers whether it started: the
    /// spacing, the cap or the pause may hold it back.
    ///
    /// The switch is read here, where the check is dispatched — not only where
    /// the line arrived. A line that waited for the spacing must not be
    /// checked after the user turned the automatic answers off (§6.16).
    ///
    /// One automatic check runs at a time (§3.4): a check that is running is
    /// never replaced by a waiting line. The continuation is the one rule
    /// that may start a check beside a running one — it takes the running
    /// check back before it comes here.
    @discardableResult
    private func startAutomatic(for line: LiveMeetingTranscript.Line, exemptFromSpacing: Bool) -> Bool {
        guard isAutoOn() else { return false }
        // A user request owns the card until it is done: no automatic check
        // starts beside it (§3.0).
        guard runningUserRequest == nil else { return false }
        guard runningCheck == nil else { return false }
        let now = clock()

        pruneAutomaticStarts()
        if automaticStarts.count >= Self.automaticCap {
            setAutomaticPausedStatus()
            return false
        }
        if let until = automaticPauseEnd, now < until {
            return false
        }
        if !exemptFromSpacing,
           let last = lastAutomaticStart,
           now.timeIntervalSince(last) < Self.automaticSpacing {
            return false
        }

        automaticStarts.append(now)
        lastAutomaticStart = now

        let check = RunningCheck(requestId: nextAutomaticId(), line: line)
        runningCheck = check
        // The line that is being checked is not waiting any more. A line that
        // waits for another check keeps waiting.
        if let pending = pendingLine,
           pending.startSample == line.startSample,
           pending.text == line.text {
            pendingLine = nil
        }

        let identity = MeetingRequestIdentity(id: check.requestId,
                                              generation: generation(),
                                              handle: check.handle,
                                              startedAt: timingNow())
        check.identity = identity
        let task = Task { [weak self] in
            guard let self else { return }
            let ask = MeetingAnswerPrompts.gatedAsk(line: check.line.text)
            let heard = HeardLine(text: check.line.text, endSample: check.line.endSample)
            await self.runRequest(ask: ask,
                                  heard: heard,
                                  identity: identity,
                                  deadlineMs: Self.automaticDeadlineMs,
                                  check: check)
        }
        check.handle.attach { task.cancel() }
        // The check belongs to the session: it ends with it (§6.15).
        stopToken.retain(task)
        return true
    }

    /// Waits for the line that waits for a check.
    private func scheduleDrain() {
        guard !isStopped else { return }
        guard drainTask == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            while !self.isStopped, let line = self.pendingLine {
                if self.startAutomatic(for: line, exemptFromSpacing: false) { break }
                // The user turned the automatic answers off: the line that
                // waits goes away with the switch (§6.16).
                if !self.isAutoOn() {
                    self.pendingLine = nil
                    break
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.drainPoll * 1_000_000_000))
            }
            self.drainTask = nil
        }
        drainTask = task
        // The drain belongs to the session: it ends with it (§6.15).
        stopToken.retain(task)
    }

    /// Forgets the checks that fell out of the rolling hour.
    private func pruneAutomaticStarts() {
        let now = clock()
        automaticStarts.removeAll { now.timeIntervalSince($0) >= Self.automaticCapWindow }
    }

    // MARK: - The request

    private enum TimingOutcome: String {
        case published, skipped, rejected, failed, cancelled, timeout
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = start.duration(to: timingNow()).components
        return elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
    }

    /// Asks the model and publishes what it answered.
    private func runRequest(ask: String,
                            heard: HeardLine?,
                            identity: MeetingRequestIdentity,
                            deadlineMs: Int,
                            check: RunningCheck?,
                            action: MeetingAnswerAction? = nil,
                            isTypedQuestion: Bool = false,
                            question: String? = nil) async {
        let manualKind: ManualKind? = check == nil
            ? (action.map(ManualKind.init) ?? (isTypedQuestion ? .typed : .shortcut)) : nil
        guard preflightIsCurrent(identity, kind: manualKind, check: check) else { return }
        runningRequests += 1
        state.setThinking(true)
        defer {
            clearDraft(identity)
            runningRequests -= 1
            if !isStopped, !stopToken.isCancelled, generation() == identity.generation {
                state.setThinking(runningRequests > 0)
            }
            if check != nil { identity.handle.finish() }
            // The check is done — its result is published or it was dropped.
            // The slot it held is free now, and the drain may take the next
            // line: a waiting line never takes the slot of a running check
            // (§3.4).
            if let check, runningCheck === check { runningCheck = nil }
            // A line that waited for this request may go now.
            scheduleDrain()
        }

        let system: String
        if action == .screen {
            system = MeetingAnswerPrompts.screenSystemText(language: pinnedLanguage())
        } else if action != nil {
            system = MeetingAnswerPrompts.actionSystemText(language: pinnedLanguage())
        } else {
            system = MeetingAnswerPrompts.systemText(language: pinnedLanguage())
        }
        let built = await buildUserMessage(ask: ask, tagTranscript: action != nil)
        // The check stands right before the call: the meeting may have ended
        // while the message was built, and a request of a meeting that is over
        // never reaches the model (§6.15).
        guard preflightIsCurrent(identity, kind: manualKind, check: check) else { return }

        // A terminal stops the transport without invalidating the request that
        // may still publish a valid deadline partial.
        let streamHandle = LiveHintsRequestHandle()
        identity.handle.attach { streamHandle.cancel() }
        defer { streamHandle.cancel() }
        guard let (route, source) = routes.stream(system: system, user: built.user, deadlineMs: deadlineMs,
                                         stopToken: stopToken, handle: streamHandle) else {
            logPreflightExit(manualKind, .noRoute)
            setStatus(MeetingAnswerStatus.noRoute)
            return
        }
        // One timing event per dispatched card stream. Preflight exits have no route or stream to measure.
        let kind = action?.rawValue ?? (check != nil ? "automatic" :
            (isTypedQuestion ? "typed" : "shortcut"))
        var firstDrawMs: Int64 = -1
        var timingOutcome = TimingOutcome.cancelled
        // Zero means no terminal response was received, including a local deadline or cancellation.
        var httpStatus = 0
        defer {
            timingLog("[LiveHints] answer kind=\(kind) route=\(route.rawValue) first_draw_ms=\(firstDrawMs) end_ms=\(milliseconds(since: identity.startedAt)) outcome=\(timingOutcome.rawValue) status=\(httpStatus)")
        }
        var filter = MeetingAnswerStreamFilter(kind: action == nil ? .answer : .action, action: action)
        var outcome = MeetingAnswerOutcome.cancelled
        var reachedDeadline = false
        let events = MeetingAnswerStreamReader.bounded(source, deadlineMs: deadlineMs, sleep: streamSleep)
        streamLoop: for await event in events {
            guard isCurrent(identity, check: check) else { return }
            switch event {
            case .reply(.delta(let delta)):
                filter.append(delta)
                if !filter.visibleText.isEmpty, !filter.isSuppressed {
                    state.showDraft(MeetingAnswerDraft(requestID: identity.uuid, generation: identity.generation,
                                                       kind: .answer, heard: heard?.text, blocks: filter.blocks,
                                                       question: question, requestStartedAt: identity.startedAt))
                    if firstDrawMs == -1 { firstDrawMs = milliseconds(since: identity.startedAt) }
                } else {
                    state.hideDraft(requestID: identity.uuid, generation: identity.generation)
                }
            case .reply(.end(let reply)):
                httpStatus = reply.status
                if reply.status == 200 { outcome = .text(filter.raw) }
                else if reply.status == 401 { outcome = .unauthorized }
                else if reply.status == 499 { outcome = .cancelled }
                else { outcome = .failed(status: reply.status, retryAfter: reply.retryAfter) }
                break streamLoop
            case .deadline:
                reachedDeadline = true
                outcome = .text(filter.raw)
                break streamLoop
            }
        }

        // Retire pending deltas before any terminal cleanup or publication.
        streamHandle.cancel()
        // Only the newest valid result is published.
        guard isCurrent(identity, check: check) else { return }

        switch outcome {
        case .text(let raw):
            filter.finish()
            timingOutcome = reachedDeadline ? .timeout : .rejected
            if let action {
                guard !filter.isSuppressed else {
                    timingOutcome = .skipped
                    return
                }
                let blocks = MeetingActionContract.evaluate(raw, action: action)
                guard !filter.isRejected, let blocks else {
                    rejectStream(check: check, reachedDeadline: reachedDeadline)
                    return
                }
                clearDraft(identity)
                let answer = MeetingAnswer(id: identity.uuid, generation: identity.generation,
                                           heard: nil, kind: .action,
                                           provenance: action == .screen ? .screen : .transcript, action: action,
                                           blocks: blocks, createdAt: clock(), question: question,
                                           requestStartedAt: identity.startedAt)
                timingOutcome = .published
                await publish(answer, heard: nil, boundary: nil)
                return
            }
            let contract = filter.isSuppressed ? MeetingAnswerContract.Outcome.skip : MeetingAnswerContract.evaluate(raw)
            switch contract {
            case .skip:
                timingOutcome = .skipped
                if isTypedQuestion {
                    setStatus(MeetingAnswerStatus.couldNotGetAnAnswer, seconds: Self.rejectStatusSeconds)
                }
            case .reject:
                rejectStream(check: check, reachedDeadline: reachedDeadline)
            case .answer(let text):
                guard !filter.isRejected else {
                    rejectStream(check: check, reachedDeadline: reachedDeadline)
                    return
                }
                clearDraft(identity)
                // The boundary is the end of the transcript the request was
                // built from. When the transcript was empty, the answer was
                // given from the line that was still being transcribed: the
                // end of that line is the boundary, and never the end of the
                // transcript as it is now — the speech that came in while the
                // answer was on its way was not answered (§3.4).
                let boundary = built.boundary ?? heard?.endSample
                let answer = MeetingAnswer(id: identity.uuid,
                                           generation: identity.generation,
                                           heard: heard?.text,
                                           kind: .answer,
                                           provenance: .transcript,
                                           action: nil,
                                           blocks: text.blocks,
                                           createdAt: clock(), question: question,
                                           requestStartedAt: identity.startedAt)
                timingOutcome = .published
                await publish(answer, heard: heard, boundary: boundary)
            }
        case .unauthorized:
            timingOutcome = .failed
            setStatus(MeetingAnswerStatus.signInAgain)
        case .noRoute:
            timingOutcome = .failed
            setStatus(MeetingAnswerStatus.noRoute)
        case .cancelled:
            // The meeting ended before the request went out: there is nothing
            // to show (§6.15).
            break
        case .failed(let status, let retryAfter):
            timingOutcome = status == 408 ? .timeout : .failed
            if status == 503 {
                pauseAutomatic(for: retryAfter ?? Self.defaultRetryAfter)
            }
            if check == nil {
                // The answer did not come: the deadline came first, or the
                // server refused to work past it.
                if status == 408 || status == 503 {
                    setStatus(MeetingAnswerStatus.noAnswerInTime)
                } else {
                    setStatus(MeetingAnswerStatus.couldNotGetAnAnswer, seconds: Self.rejectStatusSeconds)
                }
            }
        }
    }

    private func rejectStream(check: RunningCheck?, reachedDeadline: Bool) {
        guard check == nil else { return }
        if reachedDeadline {
            setStatus(MeetingAnswerStatus.noAnswerInTime)
        } else {
            setStatus(MeetingAnswerStatus.couldNotGetAnAnswer, seconds: Self.rejectStatusSeconds)
        }
    }

    private func clearDraft(_ identity: MeetingRequestIdentity) {
        state.clearDraft(requestID: identity.uuid, generation: identity.generation,
                         requestStartedAt: identity.startedAt)
    }

    private func cancelUserRequest(_ identity: MeetingRequestIdentity?) {
        guard let identity else { return }
        clearDraft(identity)
        state.clearBusy(requestID: identity.uuid, generation: identity.generation)
        identity.handle.cancel()
    }

    private func cancelCheck(_ check: RunningCheck?) {
        guard let check else { return }
        if let identity = check.identity { clearDraft(identity) }
        check.handle.cancel()
    }

    /// Publishes an answer and remembers what it was about.
    ///
    /// What the answer touches is the table of §3.0: a plain answer joins the
    /// earlier exchanges and marks the transcript it used; actions and screen
    /// answers do neither.
    func publish(_ answer: MeetingAnswer, heard: HeardLine?, boundary: Int?) async {
        state.publish(answer)

        // The answer is on the card: the line that said the shortcut could
        // not answer goes away with it (§3.4).
        if let status = state.status, MeetingAnswerStatus.clearedByAnAnswer.contains(status) {
            setStatus(nil)
        }

        guard answer.joinsHistory else { return }

        if let endSample = heard?.endSample {
            answeredThemEndSample = endSample
        }

        history.append(MeetingAnswerPrompts.Exchange(
            heard: answer.heard,
            answer: String(answer.plainText.prefix(Self.historyAnswerCharacters))))
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }

        // The divider of the transcript moves to the end of the transcript
        // this answer used — the lines that came in while it was on its way
        // are after it. The memo may follow, but only now, after the answer
        // was published.
        await transcript.markAnswered(boundary: boundary)
    }

    /// Builds the user message of the request.
    ///
    /// The boundary of the transcript comes with it: the answer marks the
    /// transcript it used, not the one that is there when it comes back.
    private func buildUserMessage(ask: String, tagTranscript: Bool = false) async -> (user: String, boundary: Int?) {
        let rendered = await transcript.renderedLines()
        let memo = await transcript.memo
        let query = rendered.lines.joined(separator: "\n")
        let memories = relevantMemories(query)
        let user = MeetingAnswerPrompts.userMessage(memo: memo,
                                                     memories: memories,
                                                     transcriptLines: rendered.lines,
                                                     answeredIndex: rendered.answeredIndex,
                                                     history: history,
                                                     ask: ask,
                                                     budget: routes.budget,
                                                     tagTranscript: tagTranscript)
        return (user, rendered.boundary)
    }

    // MARK: - The heard line

    /// The line the answer is about.
    struct HeardLine: Equatable {
        let text: String
        /// Where the line ended, when that is known.
        let endSample: Int?
    }

    /// The newest line of the other side, or the one that was still being
    /// transcribed when the shortcut was pressed.
    private func newestHeardLine(_ lines: [LiveMeetingTranscript.Line],
                                  pending: LivePendingText?) -> HeardLine? {
        let newestThem = lines.last(where: { $0.speaker == .them })
        if let pending, !pending.text.isEmpty {
            if let newestThem, newestThem.text == pending.text {
                return HeardLine(text: pending.text, endSample: newestThem.endSample)
            }
            // The line is not in the transcript yet: the end of the utterance
            // is what the answer used, and it marks the transcript (§3.4).
            return HeardLine(text: pending.text, endSample: pending.endSample)
        }
        guard let newestThem else { return nil }
        return HeardLine(text: newestThem.text, endSample: newestThem.endSample)
    }

    /// Whether the line still waits for an answer.
    ///
    /// A line is answered when an answer was shown for it, or when the user
    /// spoke for a second and a half after it — that is the user answering on
    /// their own.
    private func isUnanswered(_ heard: HeardLine) async -> Bool {
        if let endSample = heard.endSample,
           let answered = answeredThemEndSample,
           endSample <= answered {
            return false
        }
        guard let endSample = heard.endSample else { return true }
        return await meSpeechSeconds(after: endSample) < Self.answeredSpeechSeconds
    }

    /// The seconds of the user's own speech after a sample. The app counts
    /// the speech outside the dictation pauses.
    private func meSpeechSeconds(after sample: Int) async -> Double {
        await speechSeconds(sample)
    }

    /// Waits for the line that is still being transcribed.
    private func waitForPendingThemText() async -> LivePendingText? {
        let pending = self.pendingThemText
        let outcome = await LiveCall.run(within: Self.pendingThemWait) {
            await pending()
        }
        if case .text(let text) = outcome { return text }
        return nil
    }

    // MARK: - The helpers

    /// Joins a waiting line with a line that arrived after it.
    private func join(_ pending: LiveMeetingTranscript.Line?,
                      _ line: LiveMeetingTranscript.Line) -> LiveMeetingTranscript.Line {
        guard let pending else { return line }
        if pending.startSample == line.startSample {
            // The same utterance, longer: the newer text wins.
            return LiveMeetingTranscript.Line(speaker: .them,
                                              text: line.text,
                                              startSample: pending.startSample,
                                              endSample: max(pending.endSample, line.endSample))
        }
        return LiveMeetingTranscript.Line(speaker: .them,
                                          text: pending.text + " " + line.text,
                                          startSample: pending.startSample,
                                          endSample: line.endSample)
    }

    /// The next request id. The newest one owns the answer.
    private func nextAutomaticId() -> UInt64 {
        newestAutomaticId += 1
        return newestAutomaticId
    }

    private func isCurrent(_ identity: MeetingRequestIdentity, check: RunningCheck? = nil) -> Bool {
        guard !Task.isCancelled, !isStopped, !stopToken.isCancelled, !identity.handle.isCancelled,
              generation() == identity.generation else { return false }
        if let check {
            return check.requestId == newestAutomaticId && runningCheck === check
        }
        return identity.id == newestUserRequestId
    }

    /// Takes the identity of a user request.
    ///
    /// The request that is running is called off by its handle, and the
    /// automatic checks are superseded: the user's action owns the card until
    /// it is done (§3.0).
    private func takeUserRequestIdentity() -> MeetingRequestIdentity {
        cancelUserRequest(runningUserRequest)
        supersedeAutomaticChecks()
        newestUserRequestId += 1
        let identity = MeetingRequestIdentity(id: newestUserRequestId,
                                              generation: generation(),
                                              handle: LiveHintsRequestHandle(),
                                              startedAt: timingNow())
        runningUserRequest = identity
        state.showBusy(requestID: identity.uuid, generation: identity.generation)
        return identity
    }

    /// The user's request is done: the automatic checks may run again.
    private func finishUserRequest(_ identity: MeetingRequestIdentity) {
        clearDraft(identity)
        state.clearBusy(requestID: identity.uuid, generation: identity.generation)
        identity.handle.finish()
        if runningUserRequest?.handle === identity.handle {
            runningUserRequest = nil
        }
        // A line that waited for a check may go now.
        scheduleDrain()
    }

    /// The automatic checks are superseded: the one that is running is thrown
    /// away, and none starts while the user's request runs (§3.0).
    private func supersedeAutomaticChecks() {
        runningCheck?.superseded = true
        cancelCheck(runningCheck)
        runningCheck = nil
    }

    /// Pauses the automatic answers.
    private func pauseAutomatic(for seconds: TimeInterval) {
        let until = clock().addingTimeInterval(seconds)
        if let existing = automaticPauseEnd, existing >= until { return }
        automaticPauseEnd = until
        setAutomaticPausedStatus()
    }

    /// Puts the line up that says the automatic answers are paused, and
    /// watches it: the line goes away when the pause is over (§3.6).
    ///
    /// The line names the shortcut that is registered now: the user has to
    /// press the one they set, not the one the app shipped with.
    private func setAutomaticPausedStatus() {
        automaticStatus = .automaticPaused
        setStatus(renderAutomaticStatus())
        guard pauseWatch == nil else { return }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.drainPoll * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.clearAutomaticPauseIfItIsOver()
            }
        }
        pauseWatch = task
        // The watcher belongs to the session: it ends with it (§6.15).
        stopToken.retain(task)
    }

    /// The line that says the automatic answers are paused, with the shortcut
    /// that is registered now.
    private func renderAutomaticStatus() -> String {
        MeetingAnswerStatus.automaticPaused(shortcutLabel: state.shortcutLabel)
    }

    /// The shortcut of the user changed: the line that names it is put up
    /// again, with the shortcut that is registered now (§3.6).
    ///
    /// The line is stored as a kind, so a change that happens during the
    /// backoff shows at once — the user must not be told to press a shortcut
    /// they do not press any more.
    func shortcutLabelChanged() {
        guard automaticStatus != nil else { return }
        // Another line is on the card: it is not the one to render again.
        guard isPauseLineOnTheCard else { return }
        setStatus(renderAutomaticStatus())
    }

    /// Whether the card shows the line that says the automatic answers are
    /// paused.
    private var isPauseLineOnTheCard: Bool {
        guard let status = state.status else { return false }
        return status.hasPrefix(MeetingAnswerStatus.automaticPausedPrefix)
    }

    /// The pause is over — the backoff ended, or the cap has room again:
    /// the line that says the automatic answers are paused goes away with it.
    private func clearAutomaticPauseIfItIsOver() {
        guard automaticStatus != nil else { return }
        guard isPauseLineOnTheCard else { return }
        let now = clock()
        pruneAutomaticStarts()
        let isBackoffOver = automaticPauseEnd.map { now >= $0 } ?? true
        let isCapRoom = automaticStarts.count < Self.automaticCap
        guard isBackoffOver, isCapRoom else { return }
        automaticStatus = nil
        setStatus(nil)
    }

    /// The letters and digits of a text: the fewest a line needs before it
    /// calls the model.
    private func letterCount(_ text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if character.isLetter || character.isNumber { count += 1 }
        }
    }

    /// The automatic check that is running.
    private final class RunningCheck {
        let requestId: UInt64
        var identity: MeetingRequestIdentity?
        let line: LiveMeetingTranscript.Line
        /// The handle that calls the check off.
        let handle = LiveHintsRequestHandle()
        var superseded = false

        init(requestId: UInt64, line: LiveMeetingTranscript.Line) {
            self.requestId = requestId
            self.line = line
        }
    }
}
