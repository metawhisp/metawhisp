import Combine
import Foundation

struct MeetingCoachBusyRequest: Equatable {
    let requestID: UUID
    let generation: Int
}

/// Transient text owned by one request in one recording generation.
struct MeetingAnswerDraft: Equatable, Sendable {
    let requestID: UUID
    let generation: Int
    let kind: MeetingAnswerKind
    let heard: String?
    let blocks: [MeetingAnswerBlock]
    let question: String?
    let requestStartedAt: ContinuousClock.Instant

    init(requestID: UUID, generation: Int, kind: MeetingAnswerKind, heard: String?,
         blocks: [MeetingAnswerBlock], question: String? = nil,
         requestStartedAt: ContinuousClock.Instant = .now) {
        self.requestID = requestID
        self.generation = generation
        self.kind = kind
        self.heard = heard
        self.blocks = blocks
        self.question = question
        self.requestStartedAt = requestStartedAt
    }
}

/// The model the live meeting copilot overlay draws (ITER-076).
///
/// **The answers are the model.** `MeetingAnswerService` produces the answers
/// and publishes them here; the overlay shows the current draft or newest
/// published answer. Earlier answers remain available to service history.
///
/// The publishing is a method on the state, not a second copy of the answers
/// in the service: the state owns the list the overlay draws, so there is one
/// list and one owner. The service holds the state it publishes into — the
/// shared one in the app, its own one in a test.
///
/// Nothing is taken away while the meeting runs: the card keeps its answers
/// until `arm()` clears it for the next meeting.
///
/// Lifecycle:
/// - `arm()`  — meeting started; window can show; reset list
/// - `disarm()` — meeting stopped; window hides
@MainActor
final class MeetingCoachState: ObservableObject {
    enum Tab { case answers, transcript }
    static let shared = MeetingCoachState()
    /// Immediate acknowledgement belongs to the accepted request, including its preflight waits.
    @Published private(set) var busyRequest: MeetingCoachBusyRequest?
    @Published private(set) var isStopping = false
    @Published private var repeatPulses: [MeetingAnswerAction: Int] = [:]

    func showBusy(requestID: UUID, generation: Int) {
        busyRequest = MeetingCoachBusyRequest(requestID: requestID, generation: generation)
    }

    func clearBusy(requestID: UUID, generation: Int) {
        guard busyRequest?.requestID == requestID, busyRequest?.generation == generation else { return }
        busyRequest = nil
    }

    func repeatPulse(for action: MeetingAnswerAction) -> Int { repeatPulses[action, default: 0] }

    func flashRepeatedAction(_ action: MeetingAnswerAction) {
        repeatPulses[action, default: 0] += 1
    }

    @discardableResult
    func beginStopping() -> Bool {
        guard recordingSurface, !isStopping else { return false }
        closeAsk()
        isStopping = true
        return true
    }

    /// The most answers the card keeps. The oldest one falls off.
    static let maxAnswers = 3

    /// The answers, newest first.
    @Published private(set) var answers: [MeetingAnswer] = []
    @Published private(set) var draft: MeetingAnswerDraft?
    static let maxFinishedRequests = 256
    private struct RequestKey: Hashable {
        let id: UUID
        let generation: Int
    }
    private var finishedRequests: [RequestKey: ContinuousClock.Instant] = [:]
    private var finishedRequestOrder: [RequestKey] = []
    private var retiredThrough: ContinuousClock.Instant?
    var finishedRequestCount: Int { finishedRequests.count }
    /// True while a request runs — the overlay shows "THINKING…".
    @Published private(set) var isThinking: Bool = false
    /// The label of the help shortcut, when one is registered.
    @Published var shortcutLabel: String?
    /// Whether the answers come by themselves when the other side asks.
    @Published var autoAnswerOn: Bool = false
    /// True while a meeting is recording AND the user has the overlay enabled.
    @Published private(set) var isVisible: Bool = false
    /// A balance halt leaves the status visible but closes every manual control.
    @Published private(set) var isHalted = false
    var canRequestAnswers: Bool { isVisible && !isHalted }
    @Published private(set) var recordingSurface = false
    private(set) var recordingGeneration: Int?
    @Published private(set) var panelHidden = false
    @Published private(set) var hasUnseenAnswer = false
    @Published private(set) var selectedTab: Tab = .answers
    /// Only the derived last-four projection is cached; accepted lines stay in the session.
    var transcriptTailProvider: (() -> [LiveMeetingTranscript.Line])? {
        didSet { cachedTranscriptTail = nil }
    }
    private var cachedTranscriptTail: [LiveMeetingTranscript.Line]?
    @Published private var transcriptRevision = 0
    var transcriptTail: [LiveMeetingTranscript.Line] {
        if let cachedTranscriptTail { return cachedTranscriptTail }
        let tail = transcriptTailProvider?() ?? []
        cachedTranscriptTail = tail
        return tail
    }

    func transcriptDidChange() {
        cachedTranscriptTail = nil
        transcriptRevision += 1
    }
    let speakerModel = MeetingCoachSpeakerModel()
    var speaker: MeetingCoachSpeaker { speakerModel.speaker }

    /// Explicit card inputs exclude audio, native keystrokes and inactive transcript updates.
    var renderChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            $answers.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $draft.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $isThinking.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $shortcutLabel.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $isVisible.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $isHalted.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $recordingSurface.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $panelHidden.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $hasUnseenAnswer.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $selectedTab.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $isAskOpen.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $statusText.map { _ in () }.eraseToAnyPublisher(),
            $busyRequest.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $isStopping.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $repeatPulses.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $transcriptRevision.filter { [weak self] _ in self?.selectedTab == .transcript }
                .map { _ in () }.eraseToAnyPublisher()
        ]).eraseToAnyPublisher()
    }

    private var renderedBlockSource: [MeetingAnswerBlock]?
    private var cachedRenderedBlocks: [AttributedString] = []
    private(set) var markdownRenderCount = 0
    var renderedBlocks: [AttributedString] {
        let blocks = displayedBlocks
        if renderedBlockSource != blocks {
            renderedBlockSource = blocks
            cachedRenderedBlocks = blocks.map { MeetingAnswerContract.rendered($0.text) }
            markdownRenderCount += blocks.count
        }
        return cachedRenderedBlocks
    }

    private func clearRenderedBlocks() {
        renderedBlockSource = nil
        cachedRenderedBlocks = []
    }

    func showRecordingSurface(generation: Int) {
        if !recordingSurface || recordingGeneration != generation {
            clearAnswers()
            setStatus(nil)
            setThinking(false)
            isHalted = false
        }
        if recordingGeneration != generation {
            resetFinishedRequests()
            isStopping = false
            repeatPulses = [:]
            questionText = ""
            panelHidden = false
            hasUnseenAnswer = false
            selectedTab = .answers
        }
        recordingGeneration = generation
        recordingSurface = true
    }

    func setSpeaker(_ speaker: MeetingCoachSpeaker) {
        speakerModel.setSpeaker(speaker)
    }

    /// The session's manual request entry points, called at the click itself.
    var onHelp: (() -> Void)?
    var onAction: ((MeetingAnswerAction) -> Void)?
    var onQuestion: ((String) -> Void)?
    var onScreen: (() -> Void)?

    /// The field's draft, bounded in characters rather than encoded bytes.
    @Published private(set) var questionText = ""
    /// Whether the native field is currently editing.
    @Published private(set) var isQuestionEditing = false
    @Published private(set) var isAskOpen = false
    /// The panel's release sequence, installed by its controller.
    var onEndQuestionEditing: (() -> Void)?

    /// The text of the status line. `status` is what the overlay reads.
    @Published private var statusText: String?
    /// When the status line goes away.
    private var statusExpiresAt: Date?
    /// The task that takes the status line away when its lifetime is over.
    private var statusTask: Task<Void, Never>?
    /// The time now. The tests move it by hand.
    private let clock: () -> Date

    /// The clock the status line ages with. The tests move it by hand.
    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    // MARK: - The answers

    /// Publishes an answer into the card: the newest one first, and at most
    /// `maxAnswers` of them.
    func publish(_ answer: MeetingAnswer) {
        finishRequest(answer.id, generation: answer.generation, startedAt: answer.requestStartedAt)
        if let draft, draft.generation == answer.generation,
           draft.requestID == answer.id || draft.requestStartedAt <= answer.requestStartedAt {
            clearDraft(requestID: draft.requestID, generation: draft.generation,
                       requestStartedAt: draft.requestStartedAt)
        }
        if panelHidden { hasUnseenAnswer = true }
        answers.insert(answer, at: 0)
        if answers.count > Self.maxAnswers {
            answers.removeLast(answers.count - Self.maxAnswers)
        }
    }

    func showDraft(_ draft: MeetingAnswerDraft) {
        guard recordingGeneration == nil || recordingGeneration == draft.generation,
              recordingGeneration == nil || recordingSurface,
              !isHalted,
              finishedRequests[RequestKey(id: draft.requestID, generation: draft.generation)] == nil,
              (self.draft?.requestID == draft.requestID && self.draft?.generation == draft.generation)
                || (retiredThrough.map({ draft.requestStartedAt > $0 }) ?? true) else { return }
        guard self.draft?.requestID != draft.requestID || self.draft?.generation != draft.generation
            || self.draft?.blocks != draft.blocks else { return }
        self.draft = draft
    }

    /// Clearing is terminal, even if the request has not delivered its first delta.
    func clearDraft(requestID: UUID, generation: Int,
                    requestStartedAt: ContinuousClock.Instant? = nil) {
        guard recordingGeneration == nil || recordingGeneration == generation else { return }
        let start = requestStartedAt ?? (draft?.requestID == requestID && draft?.generation == generation
            ? draft?.requestStartedAt : nil) ?? .now
        finishRequest(requestID, generation: generation, startedAt: start)
        hideDraft(requestID: requestID, generation: generation)
    }

    /// Filtering an incomplete prefix does not finish its request.
    func hideDraft(requestID: UUID, generation: Int) {
        guard draft?.requestID == requestID, draft?.generation == generation else { return }
        draft = nil
    }

    private func finishRequest(_ id: UUID, generation: Int, startedAt: ContinuousClock.Instant) {
        guard recordingGeneration == nil || recordingGeneration == generation else { return }
        let key = RequestKey(id: id, generation: generation)
        guard finishedRequests[key] == nil else { return }
        finishedRequests[key] = startedAt
        finishedRequestOrder.append(key)
        if finishedRequestOrder.count > Self.maxFinishedRequests {
            let oldest = finishedRequestOrder.removeFirst()
            if let start = finishedRequests.removeValue(forKey: oldest) {
                retiredThrough = max(retiredThrough ?? start, start)
            }
        }
    }

    private func resetFinishedRequests() {
        finishedRequests.removeAll(keepingCapacity: true)
        finishedRequestOrder.removeAll(keepingCapacity: true)
        retiredThrough = nil
    }

    private func finishCurrentRequests() {
        if let draft { clearDraft(requestID: draft.requestID, generation: draft.generation) }
        if let busyRequest { clearDraft(requestID: busyRequest.requestID, generation: busyRequest.generation) }
    }

    /// Forgets the answers: a new meeting starts clean.
    func clearAnswers() {
        finishCurrentRequests()
        clearRenderedBlocks()
        busyRequest = nil
        draft = nil
        answers = []
    }

    /// Puts the card into the thinking state, or takes it out of it.
    func setThinking(_ thinking: Bool) {
        isThinking = thinking
    }

    /// Only the newest card may be expanded; an older answer is never used
    /// in place of a recap or an answer about the screen.
    var canExpandLatest: Bool { !isHalted && displayedDraft == nil && answers.first?.mayBeExpanded == true }

    /// Text and identity must select the same request. A late older draft may
    /// never cover an answer from a request that started at or after it.
    var displayedDraft: MeetingAnswerDraft? {
        guard let draft else { return nil }
        if let answer = answers.first, draft.requestStartedAt <= answer.requestStartedAt { return nil }
        return draft
    }

    var displayedBlocks: [MeetingAnswerBlock] {
        guard !isHalted else { return [] }
        return displayedDraft?.blocks ?? answers.first?.blocks ?? []
    }

    var displayedHeard: String? {
        guard !isHalted else { return nil }
        if let draft = displayedDraft { return draft.heard }
        return answers.first?.heard
    }

    var displayedQuestion: String? {
        guard recordingSurface, !isHalted else { return nil }
        if let draft = displayedDraft { return draft.question }
        return answers.first?.question
    }

    var showsThinkingPlaceholder: Bool { isThinking && displayedBlocks.isEmpty && !isHalted }

    func shouldShowPanel(isExpanded: Bool) -> Bool {
        guard recordingSurface, !panelHidden else { return false }
        if isHalted { return isExpanded && status != nil }
        if selectedTab == .transcript { return true }
        return isExpanded || isAskOpen || !displayedBlocks.isEmpty || status != nil || showsThinkingPlaceholder || busyRequest != nil
    }

    /// The same request as the help shortcut, including on an empty card.
    func helpPressed() {
        guard canRequestAnswers else { return }
        showPanel()
        onHelp?()
    }

    func hidePanel() {
        closeAsk()
        panelHidden = true
    }

    func showPanel() {
        panelHidden = false
        hasUnseenAnswer = false
        selectTab(.answers)
    }

    func selectTab(_ tab: Tab) {
        if tab == .transcript { closeAsk() }
        selectedTab = tab
    }

    /// Captures the screen request identity at the click, before any await.
    func screenPressed() {
        guard canRequestAnswers else { return }
        onScreen?()
    }

    /// Starts the selected action while the meeting is armed.
    func actionPressed(_ action: MeetingAnswerAction) {
        guard canRequestAnswers else { return }
        guard action != .more || canExpandLatest else { return }
        onAction?(action)
    }

    // MARK: - The question field

    var questionPlaceholder: String {
        guard let shortcutLabel, !shortcutLabel.isEmpty else { return "Ask about this call" }
        return "Ask about this call — \(shortcutLabel) for an answer now"
    }

    func openAsk() {
        guard canRequestAnswers else { return }
        isAskOpen = true
    }

    /// Release the native editor synchronously before SwiftUI removes it.
    func closeAsk() {
        releaseQuestionEditing()
        isAskOpen = false
    }

    func updateQuestionText(_ text: String) {
        questionText = String(text.prefix(MeetingAnswerService.maxQuestionCharacters))
    }

    func beginQuestionEditing() {
        guard canRequestAnswers else { return }
        isQuestionEditing = true
    }

    /// Native editing may also end when the user clicks outside the panel.
    func questionEditingEnded() {
        isQuestionEditing = false
    }

    /// Return takes the request identity synchronously through the callback.
    func submitQuestion(closeAfterSending: Bool = false) {
        guard canRequestAnswers else { return }
        let question = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        onQuestion?(question)
        questionText = ""
        releaseQuestionEditing()
        if closeAfterSending { isAskOpen = false }
    }

    /// Escape discards the draft and returns typing to the call.
    func cancelQuestion() {
        questionText = ""
        releaseQuestionEditing()
    }

    private func releaseQuestionEditing() {
        guard isQuestionEditing else { return }
        isQuestionEditing = false
        onEndQuestionEditing?()
    }

    // MARK: - The status line

    /// The status line the overlay shows, when there is one.
    ///
    /// A status that was given a lifetime goes away when that lifetime is
    /// over — the clock decides when it is over.
    var status: String? {
        if let expiry = statusExpiresAt, clock() >= expiry { return nil }
        return statusText
    }

    /// Puts a status line up. It stays until it is replaced.
    func setStatus(_ text: String?) {
        statusTask?.cancel()
        statusTask = nil
        statusExpiresAt = nil
        statusText = text
    }

    /// Puts a status line up for a while: it goes away after `seconds`.
    func setStatus(_ text: String, seconds: TimeInterval) {
        statusExpiresAt = clock().addingTimeInterval(seconds)
        statusText = text
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            // Only the line that is still up goes away.
            guard self.statusText == text else { return }
            self.statusText = nil
            self.statusExpiresAt = nil
        }
    }

    // MARK: - The lifecycle

    func arm(generation: Int? = nil) {
        closeAsk()
        transcriptTailProvider = nil
        selectedTab = .answers
        hasUnseenAnswer = false
        showRecordingSurface(generation: generation ?? (recordingGeneration ?? 0) + 1)
        setSpeaker(.unavailable)
        isHalted = false
        isVisible = true
        // The card starts clean: no answers, no status line, nothing running.
        clearAnswers()
        resetFinishedRequests()
        setStatus(nil)
        setThinking(false)
        isQuestionEditing = false
    }

    func haltForBalance() {
        finishCurrentRequests()
        clearRenderedBlocks()
        closeAsk()
        setSpeaker(.unavailable)
        isHalted = true
        draft = nil
        busyRequest = nil
        setThinking(false)
        autoAnswerOn = false
        releaseQuestionEditing()
        setStatus(MeetingAnswerStatus.balanceSpent)
    }

    func disarm(preservingQuestion: Bool = false) {
        finishCurrentRequests()
        clearRenderedBlocks()
        closeAsk()
        transcriptTailProvider = nil
        if !preservingQuestion { questionText = "" }
        recordingSurface = false
        setSpeaker(.unavailable)
        draft = nil
        busyRequest = nil
        setThinking(false)
        releaseQuestionEditing()
        isVisible = false
    }
}
