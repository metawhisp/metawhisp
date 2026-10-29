import Foundation

// MARK: - The app's parts, as the session sees them

/// One stream of a meeting: the microphone or the system audio.
///
/// The live hints read the streams while the meeting records. The peek is
/// bounded, so the reader never copies the whole meeting behind it.
@MainActor
protocol LiveHintsAudioStream: AnyObject, Sendable {
    /// How many samples the stream holds.
    var currentSampleCount: Int { get }
    /// The silence at the front of the stream, when it joined late.
    var placedLeadingSilence: Int { get }
    /// The `count` samples starting at `from`.
    func peekSamples(from: Int, count: Int) -> [Float]
}

extension LiveHintsAudioStream {
    /// A stream that was there from the start carries no leading silence.
    var placedLeadingSilence: Int { 0 }
}

extension AudioRecordingService: LiveHintsAudioStream {}
extension SystemAudioCaptureService: LiveHintsAudioStream {}

/// The advice service, as the session sees it.
@MainActor
protocol LiveHintsAdvice: AnyObject, Sendable {
    /// Tells the advice service what was said.
    func triggerOnTranscription(text: String, source: String)
}

extension AdviceService: LiveHintsAdvice {}

/// What one live-hints session gives back when the meeting ends.
struct LiveHintsSessionResult: Equatable {
    /// The transcript of the meeting, every line.
    let text: String
    /// How many lines it holds.
    let lineCount: Int
    /// How far the microphone had been read.
    let micOffset: Int
    /// How far the system stream had been read.
    let systemOffset: Int
}

/// One live-hints session: the live hints of one meeting.
///
/// The advisor owns one of these while a meeting records. The session owns
/// the two trackers, the transcript, the answer service and the shortcut, and
/// it stops them all when the meeting ends.
@MainActor
protocol LiveHintsSession: AnyObject {
    /// Starts the session: the trackers, the shortcut, the answers.
    func start() async
    /// Stops the session and takes the shortcut back.
    func stop()
    /// Stops the session and gives back what the meeting said.
    func finalize() -> LiveHintsSessionResult
}

/// Everything one live-hints session needs from the app.
///
/// The app fills it with the real services; the tests fill it with fakes, so
/// the wiring can be driven without a window server, an engine or a network.
struct LiveHintsEnvironment: Sendable {
    /// The user's own side: the microphone.
    var mic: any LiveHintsAudioStream
    /// The other side: the system audio.
    var system: any LiveHintsAudioStream
    /// The dictation pause windows, on the mic's timeline.
    var pauseWindows: @MainActor @Sendable () -> [LiveSampleRange]
    /// The recording generation. A result of another meeting is dropped.
    var generation: @MainActor @Sendable () -> Int
    /// The engine, waited for while it is getting ready.
    var engine: @Sendable () async -> (any TranscriptionEngine)?
    /// The pinned transcription language, nil when it is automatic.
    var language: @MainActor @Sendable () -> String?
    /// The prompt words for a language.
    var promptWords: @Sendable (String?) async -> [String]
    /// Whether the answers come by themselves when the other side asks.
    var isAutoOn: @MainActor @Sendable () -> Bool
    /// The defaults the switch of the automatic answers lives in.
    ///
    /// The switch is watched there and not polled: every change is seen as
    /// it happens, and a switch that goes off and comes back inside one
    /// poll is still seen (§6.16).
    nonisolated(unsafe) var autoAnswerDefaults: UserDefaults = .standard
    /// The key the switch of the automatic answers is stored under.
    var autoAnswerKey: String = "meetingAutoAnswer"
    /// Whether the app may take a shortcut at all. The global input switch
    /// of the settings decides it, as it does for the other hotkeys (§3.9).
    var globalInputEnabled: @MainActor @Sendable () -> Bool = { true }
    /// The time now. The tests move it by hand.
    var clock: @MainActor @Sendable () -> Date = { Date() }
    /// What is known about the people and projects that were mentioned.
    var relevantMemories: @MainActor @Sendable (String) -> String
    /// The advice service.
    var advice: any LiveHintsAdvice
    /// The help shortcut.
    var hotkey: any MeetingHelpShortcut
    /// The card the overlay draws.
    var state: MeetingCoachState
    /// The routes to the model.
    var routes: MeetingAnswerRoutes
    /// The combo the shortcut is registered with.
    var combo: @MainActor @Sendable () -> MeetingHelpCombo
    /// How often the advice service hears what was said.
    var adviceInterval: Duration = .seconds(30)
    var screenEnabled: @MainActor @Sendable () -> Bool = { false }
    var captureScreen: @MainActor @Sendable () async -> String? = { nil }
}

/// Tracker dispatch is injectable so lifecycle races can pause at the actor hop.
struct LiveHintsTrackerOperations: Sendable {
    var append: @Sendable (UtteranceTracker.Speaker, [Float], UtteranceTracker) async -> Void = {
        _, samples, tracker in await tracker.append(samples)
    }
    var reset: @Sendable (UtteranceTracker) async -> Void = { tracker in await tracker.reset() }
    var readSamples: @Sendable (@MainActor @Sendable () -> [Float]) async -> [Float] = {
        read in await MainActor.run(body: read)
    }
}

// MARK: - The session

/// The live hints of one meeting.
///
/// The session reads the two streams, gives every finished utterance to the
/// transcript, and lets the answer service do the rest: the answer to a
/// question the other side asked, or the answer to the shortcut the user
/// pressed.
///
/// The old thirty-second loop is gone. Nothing is mixed, nothing is
/// transcribed twice, and the model is only asked when there is something to
/// ask it (§3.10).
@MainActor
final class LiveHintsMeeting: LiveHintsSession {

    // MARK: - The rules

    /// How often the streams are read.
    static let pollInterval: Duration = .milliseconds(250)
    /// How long the shortcut waits for a line that is still being transcribed.
    static let pendingWaitSeconds: Double = 2

    // MARK: - The state

    private let environment: LiveHintsEnvironment
    private let trackerOperations: LiveHintsTrackerOperations
    private let startsPolling: Bool

    /// The other side: what the system audio heard.
    private var themTracker: UtteranceTracker?
    /// The user's own side: what the microphone heard.
    private var meTracker: UtteranceTracker?
    /// The one place a live call reaches the engine.
    private var transcriber: LiveEngineTranscriber?
    /// The user's own side, batched.
    private var batcher: MeBatcher?
    /// The meeting as it was said.
    private var transcript: LiveMeetingTranscript?
    /// The answers.
    private var answerService: MeetingAnswerService?

    /// The task that reads the streams.
    private var pollTask: Task<Void, Never>?
    /// The task that tells the advice service what was said.
    private var adviceTask: Task<Void, Never>?
    /// The observation of the switch of the automatic answers.
    private var autoAnswerObserver: NSObjectProtocol?

    /// The lines of the meeting, as they were finished.
    ///
    /// The transcript holds them too; the session keeps its own record so the
    /// meeting can end without waiting for the transcript's actor.
    private var finishedLines: [LiveMeetingTranscript.Line] = []
    /// Me lines arrive through the batcher and can lag the other side's lines.
    /// This is a read-only tail of accepted lines, never another transcript store.
    private var transcriptTail: [LiveMeetingTranscript.Line] {
        finishedLines.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.startSample != rhs.element.startSample {
                    return lhs.element.startSample < rhs.element.startSample
                }
                return lhs.offset < rhs.offset
            }
            .suffix(4)
            .map(\.element)
    }
    /// Full transcript renders are reserved for a consumer that needs the text.
    private(set) var transcriptRenderCount = 0
    /// The lines finished since the last advice call.
    private var adviceLines: [LiveMeetingTranscript.Line] = []
    /// The combo the shortcut is registered with.
    private var registeredCombo: MeetingHelpCombo?
    /// The combo whose registration failed.
    ///
    /// The session holds no shortcut then, and it tries again when the global
    /// input comes back or when another combo is set — not on every poll
    /// (§3.9).
    private var failedCombo: MeetingHelpCombo?
    /// Whether the global input was on the last time the session looked.
    private var wasGlobalInputEnabled = true
    /// The one cancellation of this session.
    ///
    /// Every part that can reach the engine or the model holds it: the
    /// trackers, the batcher, the transcript, the answers and the backends.
    /// The session stops it, and only the session stops it — a part that ends
    /// its own work does not end the session's (§6.15).
    private let stopToken = LiveHintsStopToken()
    /// The owner of the shortcut registration.
    ///
    /// Only the owner may take the shortcut back: a session that was stopped
    /// never takes the shortcut away from the session that holds it now
    /// (§6.15).
    private let hotkeyOwner = UUID()
    /// How far the microphone has been read.
    private var micOffset = 0
    /// How far the system stream has been read.
    private var systemOffset = 0
    /// Where the other side's tracker numbers its zero: the index of that
    /// sample in the system buffer.
    ///
    /// The tracker counts the samples it receives from zero; the buffer
    /// counts them from the start of the meeting. A channel that joined late
    /// carries the silence of the part it missed at the front of its buffer,
    /// and that silence is the distance between the two timelines. The
    /// distance is applied to the audio the tracker reads and to the
    /// timestamps the transcript keeps, so both sides of the transcript speak
    /// of the same meeting (§3.2).
    private var systemBaseIndex: Int?
    /// The offset of the other side's tracker in the system buffer.
    ///
    /// The index of the tracker's zero in the buffer — the place the tracker
    /// reads its audio from. It is the base of the meeting, unless the
    /// capture was restarted: then the buffer starts somewhere else (§3.2).
    private var systemBufferOffset = 0
    /// The padding of the system buffer, as it was the last time the session
    /// read it.
    ///
    /// The capture may be restarted in the middle of a meeting: the buffer
    /// and its padding are replaced, and the session has to know that (§3.2).
    private var systemLeadingSilence: Int?
    /// How many samples the other side's tracker has received.
    private var systemSamplesFed = 0
    /// True when the live hints stopped because the monthly minutes are gone.
    private var isHalted = false
    /// Whether the automatic answers were on the last time the session looked.
    ///
    /// The session watches the switch of the settings: the moment it goes
    /// off, the lines that wait for a check go away with it (§6.16).
    private var wasAutoOn = false
    /// True when the session was stopped.
    ///
    /// A stopped session owns nothing any more: it starts no request, it
    /// publishes nothing into the card and it takes no shortcut (§6.15).
    /// Every await of the session checks the flag, so work that was on its
    /// way when the meeting ended goes nowhere.
    private var isStopped = false
    private var recordingGeneration: Int?

    init(environment: LiveHintsEnvironment,
         trackerOperations: LiveHintsTrackerOperations = LiveHintsTrackerOperations(),
         startsPolling: Bool = true) {
        self.environment = environment
        self.trackerOperations = trackerOperations
        self.startsPolling = startsPolling
    }

    // MARK: - The lifecycle

    /// Starts the session: the trackers, the shortcut, the answers.
    func start() async {
        // A stopped session is dead: it never comes up again. A new meeting
        /// builds a new session (§6.15).
        guard pollTask == nil, !isStopped, !isHalted else { return }
        let environment = self.environment
        recordingGeneration = environment.generation()

        let generation = environment.generation
        let language = environment.language
        let stopToken = self.stopToken
        let canReadCapture: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            // A replaced recording retires only this session's retained work.
            // Never disarm the coach state, which may already belong to its replacement.
            guard self.recordingGeneration == self.environment.generation() else {
                self.stopToken.stop()
                return false
            }
            return self.canFeedStreams
        }
        let transcriber = LiveEngineTranscriber(
            engineProvider: { await environment.engine() },
            languageProvider: { await language() },
            promptWordsProvider: { code in await environment.promptWords(code) },
            generationProvider: { await generation() },
            onBalanceSpent: { [weak self] in
                // The work runs off the main actor: the card is the main
                // actor's, and the halt belongs there.
                Task { @MainActor in self?.haltForBalance() }
            },
            stopToken: stopToken
        )
        self.transcriber = transcriber

        let themTracker = UtteranceTracker(speaker: .them,
                                           transcriber: transcriber,
                                           audioSource: StreamAudioSource(stream: environment.system,
                                                                          baseIndex: { [weak self] in
                                                                              self?.systemBufferOffset ?? 0
                                                                          },
                                                                          canRead: canReadCapture,
                                                                          readSamples: trackerOperations.readSamples),
                                           stopToken: stopToken)
        let meTracker = UtteranceTracker(speaker: .me,
                                         transcriber: transcriber,
                                         audioSource: StreamAudioSource(stream: environment.mic,
                                                                        canRead: canReadCapture,
                                                                        readSamples: trackerOperations.readSamples),
                                         stopToken: stopToken)
        self.themTracker = themTracker
        self.meTracker = meTracker

        // The user's own side is batched: its words are asked for later, and
        // never inside a dictation pause.
        let batcher = MeBatcher(audioSource: StreamAudioSource(stream: environment.mic,
                                                              canRead: canReadCapture,
                                                              readSamples: trackerOperations.readSamples),
                                transcriber: transcriber,
                                pauseWindows: { await environment.pauseWindows() },
                                streamClock: { await environment.mic.currentSampleCount },
                                stopToken: stopToken)
        self.batcher = batcher

        let transcript = LiveMeetingTranscript(memoProvider: environment.routes.makeMemoProvider(),
                                               stopToken: stopToken)
        self.transcript = transcript

        let answerService = MeetingAnswerService(
            transcript: transcript,
            routes: environment.routes,
            clock: { environment.clock() },
            isAutoOn: { environment.isAutoOn() },
            pendingThemText: { [weak self, weak themTracker] in
                guard let themTracker else { return nil }
                guard let pending = await themTracker.pendingText(within: Self.pendingWaitSeconds) else {
                    return nil
                }
                // The tracker's numbers are its own; the transcript's are the
                // meeting's. The end of the line comes with the text: an
                // answer given from it marks that line (§3.4).
                let offset = await MainActor.run { self?.systemBaseIndex ?? 0 }
                return LivePendingText(text: pending.text, endSample: pending.endSample + offset)
            },
            meSpeechSeconds: { [weak meTracker, environment] sample in
                guard let meTracker else { return 0 }
                let windows = await environment.pauseWindows()
                return await meTracker.speechSeconds(after: sample, excluding: windows)
            },
            relevantMemories: { query in environment.relevantMemories(query) },
            pinnedLanguage: { environment.language() },
            generation: { environment.generation() },
            state: environment.state,
            stopToken: stopToken,
            screenEnabled: environment.screenEnabled,
            captureScreen: environment.captureScreen)
        self.answerService = answerService

        // The routing: the other side's lines go to the transcript and to the
        // answers; the user's own lines go to the batcher.
        await themTracker.setHandler { [weak self] utterance in
            Task { @MainActor in await self?.themUtteranceClosed(utterance) }
        }
        // The session may have been stopped while it waited: nothing of it
        // may go on — no shortcut, no card (§6.15).
        guard !isStopped, !isHalted, !stopToken.isCancelled,
              recordingGeneration == environment.generation() else { return }
        await meTracker.setHandler { [weak self] utterance in
            Task { @MainActor in await self?.meUtteranceClosed(utterance) }
        }
        guard !isStopped, !isHalted, !stopToken.isCancelled,
              recordingGeneration == environment.generation() else { return }
        await batcher.setHandler { [weak self] batch in
            Task { @MainActor in await self?.batchReady(batch) }
        }
        guard !isStopped, !isHalted, !stopToken.isCancelled,
              recordingGeneration == environment.generation() else { return }

        // The card and the shortcut.
        environment.state.arm(generation: environment.generation())
        environment.state.transcriptTailProvider = { [weak self] in self?.transcriptTail ?? [] }
        environment.state.onHelp = { [weak self] in self?.shortcutPressed() }
        environment.state.onAction = { [weak self] action in
            guard let self, !self.isStopped, !self.isHalted else { return }
            self.answerService?.requestAction(action)
        }
        environment.state.onScreen = { [weak self] in
            guard let self, !self.isStopped, !self.isHalted else { return }
            self.answerService?.requestScreen()
        }
        environment.state.onQuestion = { [weak self] question in
            guard let self, !self.isStopped, !self.isHalted else { return }
            self.answerService?.requestQuestion(question)
        }
        // The automatic answers start where the settings say: the session
        // watches the switch from here (§6.16).
        wasAutoOn = environment.isAutoOn()
        environment.state.autoAnswerOn = wasAutoOn
        // The global input is watched from here: its coming back takes the
        // shortcut again (§3.9).
        wasGlobalInputEnabled = environment.globalInputEnabled()
        registerShortcut()
        // The switch of the automatic answers is watched, not polled: every
        // change is seen as it happens (§6.16).
        observeAutomaticAnswers()

        if startsPolling { startPoll() }
        startAdvice()
        NSLog("[LiveHints] ✅ the session is up")
    }

    /// Stops the session and takes the shortcut back.
    ///
    /// The session owns its work: the answers that are on their way, the
    /// batches, the trackers and the memo folds end with it. Nothing of this
    /// session may reach the next meeting (§6.15).
    func stop() {
        isStopped = true
        // The one cancellation of the session goes first: from now on no part
        // of it dispatches anything (§6.15).
        stopToken.stop()
        pollTask?.cancel()
        pollTask = nil
        adviceTask?.cancel()
        adviceTask = nil
        // The watch on the switch of the automatic answers goes with the
        // session.
        if let autoAnswerObserver {
            NotificationCenter.default.removeObserver(autoAnswerObserver)
            self.autoAnswerObserver = nil
        }
        // The shortcut: only the owner may take it back. A session that was
        // stopped never takes the shortcut away from the session that holds
        // it now (§6.15).
        if environment.hotkey.unregister(owner: hotkeyOwner) {
            registeredCombo = nil
            setShortcutLabel(nil)
        }
        // A session can end when hints are disabled within the same recording.
        // The advisor clears the draft when the recording itself ends.
        environment.state.disarm(preservingQuestion: true)
        // The answers: the line that waits for a check goes away, and the
        // requests that are running do not publish their result.
        answerService?.stop()
        // The trackers, the batches and the transcript are actors: their work
        // ends in the background.
        let themTracker = self.themTracker
        let meTracker = self.meTracker
        let batcher = self.batcher
        let transcript = self.transcript
        Task {
            await themTracker?.stop()
            await meTracker?.stop()
            await batcher?.stop()
            await transcript?.stop()
        }
        NSLog("[LiveHints] ⏹ the session is down")
    }

    /// Stops the session and gives back what the meeting said.
    func finalize() -> LiveHintsSessionResult {
        let result = LiveHintsSessionResult(text: renderedLines(),
                                             lineCount: finishedLines.count,
                                             micOffset: micOffset,
                                             systemOffset: systemOffset)
        stop()
        return result
    }

    /// The meeting as it was said, every line — the render of all the lines,
    /// without the divider that marks what came after the last answer.
    private func renderedLines() -> String {
        transcriptRenderCount += 1
        return finishedLines.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.startSample != rhs.element.startSample {
                    return lhs.element.startSample < rhs.element.startSample
                }
                return lhs.offset < rhs.offset
            }
            .map { LiveMeetingTranscript.renderedLine($0.element) }
            .joined(separator: "\n")
    }

    // MARK: - The streams

    /// Reads the streams and gives what is new to the trackers.
    private func startPoll() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.poll()
            }
        }
    }

    /// Ownership is rechecked at every suspension before touching capture again.
    private var canFeedStreams: Bool {
        !isStopped && !isHalted && !stopToken.isCancelled && !Task.isCancelled
            && recordingGeneration == environment.generation()
    }

    /// One turn of the poll: the settings first, then the audio.
    func poll() async {
        guard canFeedStreams else { return }
        // The shortcut follows the settings, and the card shows what the
        // settings say.
        updateShortcut()
        await feedStreams()
        guard canFeedStreams else { return }
        let windows = environment.pauseWindows()
        let me = await meTracker?.recentSpeech(excluding: windows) ?? false
        guard canFeedStreams else { return }
        let them = await themTracker?.recentSpeech(excluding: []) ?? false
        guard canFeedStreams else { return }
        environment.state.setSpeaker(.project(me: me, them: them))
    }

    /// The automatic answers follow the switch of the settings.
    ///
    /// The switch is watched where it lives, and not polled: the
    /// notification comes with every change, and the value is read in the
    /// notification itself — a switch that goes off and comes back inside
    /// one poll is still seen (§6.16).
    private func observeAutomaticAnswers() {
        let defaults = environment.autoAnswerDefaults
        let switchBox = AutomaticAnswerSwitch(defaults: defaults,
                                              key: environment.autoAnswerKey)
        autoAnswerObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil) { [weak self] _ in
                // The value is read here, in the notification: the switch may
                // be on again by the time the session acts on it.
                let isOn = switchBox.isOn
                Task { @MainActor in self?.automaticAnswersChanged(to: isOn) }
            }
    }

    /// The switch of the automatic answers changed.
    ///
    /// Every off drops the lines that wait for a check at once — not at the
    /// next poll (§6.16).
    private func automaticAnswersChanged(to isOn: Bool) {
        guard !isStopped, !isHalted, !stopToken.isCancelled,
              recordingGeneration == environment.generation() else { return }
        environment.state.autoAnswerOn = isOn
        guard isOn != wasAutoOn else { return }
        wasAutoOn = isOn
        guard !isOn else { return }
        answerService?.automaticTurnedOff()
    }

    /// The new samples of each stream go to their tracker.
    private func feedStreams() async {
        guard canFeedStreams else { return }
        let mic = environment.mic
        let micCount = mic.currentSampleCount - micOffset
        if micCount > 0 {
            guard canFeedStreams else { return }
            let samples = mic.peekSamples(from: micOffset, count: micCount)
            micOffset += samples.count
            guard canFeedStreams else { return }
            if let meTracker { await trackerOperations.append(.me, samples, meTracker) }
            guard canFeedStreams else { return }
        }

        let system = environment.system
        // The capture may have been restarted: the buffer and its padding are
        // replaced, and the session has to read the new one from its start
        // (§3.2).
        if isSystemBufferReplaced {
            guard canFeedStreams else { return }
            await rebaseSystemChannel()
            guard canFeedStreams else { return }
        }
        // The padding of the buffer is the one the session reads now: the
        // next poll compares against it.
        systemLeadingSilence = system.placedLeadingSilence
        // A system channel that joined late carries the silence of the part
        // of the meeting it missed. That silence is history: reading it now
        // would put the meeting's first minute against the mic's latest one.
        systemOffset = max(systemOffset, system.placedLeadingSilence)
        let systemCount = system.currentSampleCount - systemOffset
        if systemCount > 0 {
            guard canFeedStreams else { return }
            let samples = system.peekSamples(from: systemOffset, count: systemCount)
            // The first sample the other side's tracker sees is this one: its
            // zero sits here in the buffer (§3.2).
            if systemBaseIndex == nil {
                systemBaseIndex = systemOffset
                systemBufferOffset = systemOffset
            }
            systemOffset += samples.count
            systemSamplesFed += samples.count
            guard canFeedStreams else { return }
            if let themTracker { await trackerOperations.append(.them, samples, themTracker) }
            guard canFeedStreams else { return }
        }
    }

    /// True when the system buffer was replaced: the capture was restarted,
    /// and the buffer and its padding are new.
    ///
    /// Two signs say so: the buffer is shorter than what was read from the
    /// old one, and the padding of the buffer is not the padding of the old
    /// one (§3.2).
    private var isSystemBufferReplaced: Bool {
        // Nothing was read yet: there is nothing to rebase.
        guard systemSamplesFed > 0 else { return false }
        let system = environment.system
        if system.currentSampleCount < systemOffset { return true }
        guard let known = systemLeadingSilence else { return false }
        return known != system.placedLeadingSilence
    }

    /// The system buffer was replaced: the session starts over with it.
    ///
    /// The tracker counts the samples it receives from zero, so the new
    /// buffer has to be counted from zero as well: the utterance that was in
    /// progress goes away, the read cursor goes back to the silence that
    /// padded the new buffer, and the distance between the tracker's zero and
    /// the meeting is computed again (§3.2).
    private func rebaseSystemChannel() async {
        guard canFeedStreams else { return }
        let system = environment.system
        let newPadding = system.placedLeadingSilence
        // The meeting position of the new buffer's first sample. A buffer
        // that carries the silence of the part it missed starts at the
        // meeting's beginning; a buffer without it starts where the capture
        // did — which is where the meeting is now.
        let meetingNow = max(environment.mic.currentSampleCount,
                             (systemBaseIndex ?? 0) + systemSamplesFed)
        // A buffer without that silence holds the audio that came before
        // the moment the session looks at it: its first sample is the
        // meeting minus the samples it already holds (§3.2).
        let newMeetingBase = newPadding > 0
            ? newPadding
            : max(0, meetingNow - system.currentSampleCount)
        NSLog("[LiveHints] the system capture was restarted — the other side starts over")

        guard canFeedStreams else { return }
        if let themTracker { await trackerOperations.reset(themTracker) }
        guard canFeedStreams else { return }
        systemOffset = 0
        systemBufferOffset = newPadding
        systemBaseIndex = newMeetingBase
        systemSamplesFed = 0
        systemLeadingSilence = newPadding
    }

    // MARK: - The routing

    /// The other side said something: the line goes to the transcript and to
    /// the answers.
    private func themUtteranceClosed(_ utterance: UtteranceTracker.ClosedUtterance) async {
        guard !isStopped, !isHalted, !stopToken.isCancelled,
              recordingGeneration == environment.generation() else { return }
        guard let text = utterance.text, !text.isEmpty else { return }
        guard let transcript, let answerService else { return }

        // The tracker's numbers are its own; the transcript's are the
        // meeting's. The distance between the two is where the other side's
        // tracker starts in the system buffer (§3.2).
        let offset = systemBaseIndex ?? 0

        // The line the transcript made — or nothing: a transcription the gate
        // dropped is not a line. The caller must not act on the line before
        // it: a rejected transcription brings no question back (§3.4).
        guard let line = await transcript.appendThem(text: text,
                                                     startSample: utterance.startSample + offset,
                                                     endSample: utterance.endSample + offset,
                                                     rms: 0.05,
                                                     isContinuation: utterance.isContinuation) else { return }
        guard !isStopped, !isHalted, !stopToken.isCancelled,
              recordingGeneration == environment.generation() else { return }
        remember(line)
        await answerService.themLineEnded(line)
    }

    /// The user said something: the utterance waits for its batch.
    private func meUtteranceClosed(_ utterance: UtteranceTracker.ClosedUtterance) async {
        guard !isStopped, !isHalted, !stopToken.isCancelled,
              recordingGeneration == environment.generation() else { return }
        guard let batcher else { return }
        await batcher.append(MeBatcher.Utterance(startSample: utterance.startSample,
                                                 endSample: utterance.endSample))
    }

    /// The batch of the user's own side came back: its sentences go to the
    /// transcript, after the echo check.
    private func batchReady(_ batch: MeBatcher.Batch) async {
        guard !isStopped, !isHalted, !stopToken.isCancelled,
              recordingGeneration == environment.generation() else { return }
        guard let transcript else { return }
        let parts = batch.sentences.map {
            LiveMeetingTranscript.Part(text: $0.text,
                                       startSample: $0.startSample,
                                       endSample: $0.endSample)
        }
        let added = await transcript.appendMe(parts: parts, rms: batch.rms)
        guard !isStopped, !isHalted, !stopToken.isCancelled,
              recordingGeneration == environment.generation() else { return }
        for line in added { remember(line) }
    }

    /// Keeps the line in the session's own record of the meeting, and in the
    /// window the advice service hears.
    ///
    /// A line of the other side is one line: a continuation updates the line
    /// before it. A line of the user's own side is one sentence, and two
    /// sentences of the same utterance share their time — they are two
    /// lines, told apart by their words (§3.10).
    func remember(_ line: LiveMeetingTranscript.Line) {
        guard !isStopped, !isHalted, !stopToken.isCancelled,
              recordingGeneration == environment.generation() else { return }
        func index(in list: [LiveMeetingTranscript.Line]) -> Int? {
            list.firstIndex { other in
                guard other.speaker == line.speaker,
                      other.startSample == line.startSample else { return false }
                return line.speaker == .them || other.text == line.text
            }
        }
        if let index = index(in: finishedLines) {
            finishedLines[index] = line
        } else {
            finishedLines.append(line)
        }
        if let index = index(in: adviceLines) {
            adviceLines[index] = line
        } else {
            adviceLines.append(line)
        }
        environment.state.transcriptDidChange()
    }

    // MARK: - The advice

    /// Tells the advice service what was said, every thirty seconds (§3.10).
    private func startAdvice() {
        let interval = environment.adviceInterval
        adviceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.sendAdvice()
            }
        }
    }

    /// The lines of the window, joined, once.
    private func sendAdvice() {
        guard !isStopped, !isHalted, !stopToken.isCancelled,
              recordingGeneration == environment.generation() else { return }
        let lines = adviceLines
        adviceLines = []
        guard !lines.isEmpty else { return }
        let text = lines
            .sorted { $0.startSample < $1.startSample }
            .map { LiveMeetingTranscript.renderedLine($0) }
            .joined(separator: "\n")
        environment.advice.triggerOnTranscription(text: text, source: "meeting-live")
    }

    // MARK: - The shortcut

    /// The label of the shortcut on the card.
    ///
    /// The line that names the shortcut is put up again: the user has to
    /// press the shortcut they set, not the one the app shipped with, and a
    /// change during the backoff shows at once (§3.6).
    private func setShortcutLabel(_ label: String?) {
        environment.state.shortcutLabel = label
        answerService?.shortcutLabelChanged()
    }

    /// Registers the shortcut with the combo the settings hold.
    ///
    /// The global input switch decides whether the app may take a shortcut
    /// at all, as it does for the other hotkeys: with it off, nothing is
    /// registered and the overlay shows no shortcut (§3.9).
    ///
    /// The combo is remembered only when the shortcut was really taken: a
    /// registration that failed leaves the session without a shortcut, so the
    /// next chance takes it again (§3.9).
    private func registerShortcut() {
        guard environment.globalInputEnabled() else {
            if environment.hotkey.unregister(owner: hotkeyOwner) {
                registeredCombo = nil
                setShortcutLabel(nil)
            }
            return
        }
        let combo = environment.combo()
        if environment.hotkey.register(keyCode: combo.keyCode, modifiers: combo.modifiers, owner: hotkeyOwner) {
            registeredCombo = combo
            failedCombo = nil
        } else {
            // The shortcut was not taken: the session holds none, and the
            // combo that failed is not tried again and again (§3.9).
            registeredCombo = nil
            failedCombo = combo
        }
        environment.hotkey.onPress = { [weak self] in
            guard let self else { return }
            // The press belongs to the session: the session stops it with
            // everything else (§6.15).
            self.shortcutPressed()
        }
        setShortcutLabel(environment.hotkey.shortcutLabel)
    }

    /// A combo that changed while the meeting runs takes the old one back.
    ///
    /// The global input switch decides as well: with it off the shortcut goes
    /// back, and with it on again the shortcut is taken while the meeting
    /// runs (§3.9).
    private func updateShortcut() {
        let isEnabled = environment.globalInputEnabled()
        // The global input came back: the shortcut is taken again (§3.9).
        let cameBack = isEnabled && !wasGlobalInputEnabled
        wasGlobalInputEnabled = isEnabled
        guard isEnabled else {
            // The global input was turned off: the shortcut goes back.
            guard registeredCombo != nil else { return }
            if environment.hotkey.unregister(owner: hotkeyOwner) {
                registeredCombo = nil
                setShortcutLabel(nil)
            }
            return
        }
        guard let registered = registeredCombo else {
            // The session holds no shortcut: the global input may have come
            // back, or the last registration may have failed. The shortcut is
            // taken again when the global input came back, or when the combo
            // is not the one that failed (§3.9).
            if cameBack || failedCombo != environment.combo() {
                registerShortcut()
            }
            return
        }
        guard registered != environment.combo() else { return }
        registerShortcut()
    }

    /// The user pressed the shortcut: the words they have already said go
    /// out, and the answer comes.
    ///
    /// The user's own words are asked for in the background: the shortcut
    /// must not wait for the microphone, and a slow `.me` batch must never
    /// hold the answer back (§3.4). Only the other side's line that is still
    /// being transcribed is waited for — and that for two seconds at most.
    private func shortcutPressed() {
        guard !isStopped, !isHalted, !stopToken.isCancelled,
              recordingGeneration == environment.generation() else { return }
        environment.state.showPanel()
        // The batch goes out now, but its text is not waited for: it joins
        // the later answers.
        let batcher = self.batcher
        let flush = Task { await batcher?.flush() }
        stopToken.retain(flush)
        answerService?.requestShortcut()
    }

    // MARK: - The balance

    /// The monthly meeting minutes are gone: the live hints stop for this
    /// meeting, and the card says why (§3.2).
    func haltForBalance() {
        // The session may be over already: a balance failure that arrives
        // late belongs to a meeting that is gone, and it may not reach into
        // the session that runs now (§6.15).
        guard !stopToken.isCancelled,
              recordingGeneration == environment.generation() else { return }
        guard !isHalted else { return }
        isHalted = true
        // The halt also ends background memo folds and their queued requests.
        stopToken.stop()
        // Shut down requests through their handles, including the pending drain.
        answerService?.stop()
        pollTask?.cancel()
        pollTask = nil
        adviceTask?.cancel()
        adviceTask = nil
        if environment.hotkey.unregister(owner: hotkeyOwner) {
            registeredCombo = nil
            setShortcutLabel(nil)
        }
        environment.state.haltForBalance()
        let meTracker = self.meTracker
        let themTracker = self.themTracker
        Task {
            await meTracker?.stop()
            await themTracker?.stop()
        }
        NSLog("[LiveHints] ⏹ the live hints stopped — the monthly meeting minutes are used up")
    }
}

/// The switch of the automatic answers, in a box that may cross a thread.
///
/// `UserDefaults` is not `Sendable`, and the notification about a change
/// comes on the thread that made it.
private final class AutomaticAnswerSwitch: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    /// Whether the switch is on, read now.
    var isOn: Bool { defaults.bool(forKey: key) }
}

/// The audio of one stream, as the tracker asks for it.
///
/// The peek of the recorder lives on the main actor, and a request runs off
/// it — so the read is awaited there.
///
/// **The two timelines.** The tracker's numbers are its own: they start at
/// the first sample the session fed it. The buffer's numbers are the
/// meeting's: they start at the recording, and the silence of a channel that
/// joined late sits at the front of them. `baseIndex` — the buffer index of
/// the tracker's zero — is the distance between the two, and the read is
/// translated by it: the tracker asks for its own samples and gets the
/// meeting's (§3.2).
private final class StreamAudioSource: LiveAudioSource, @unchecked Sendable {
    private let stream: any LiveHintsAudioStream
    /// Where the tracker's zero sits in the buffer.
    private let baseIndex: @MainActor @Sendable () -> Int
    private let canRead: @MainActor @Sendable () -> Bool
    private let readSamples: @Sendable (@MainActor @Sendable () -> [Float]) async -> [Float]

    init(stream: any LiveHintsAudioStream,
         baseIndex: @escaping @MainActor @Sendable () -> Int = { 0 },
         canRead: @escaping @MainActor @Sendable () -> Bool,
         readSamples: @escaping @Sendable (@MainActor @Sendable () -> [Float]) async -> [Float]) {
        self.stream = stream
        self.baseIndex = baseIndex
        self.canRead = canRead
        self.readSamples = readSamples
    }

    func samples(from: Int, count: Int) async -> [Float] {
        await readSamples { [stream, baseIndex, canRead] in
            guard canRead() else { return [] }
            return stream.peekSamples(from: from + baseIndex(), count: count)
        }
    }
}
