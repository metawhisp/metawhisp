import Combine
import Foundation

/// The live hints during a meeting recording (ITER-076).
///
/// The advisor owns one live-hints session per meeting: it builds the session
/// when the recording starts and stops it when the recording ends. Everything
/// the session does — the two trackers, the transcript, the answers and the
/// shortcut — lives in `LiveHintsMeeting`.
///
/// The old thirty-second loop is gone. It mixed the two streams, transcribed
/// them a second time and asked the model every thirty seconds, whatever was
/// said. The live hints read the streams as they come, and the model is asked
/// only when there is something to ask it: a question the other side asked,
/// or the shortcut the user pressed (§3.10).
///
/// Lifecycle: armed when `meetingRecorder.isRecording` becomes true, disarmed
/// when it becomes false. Nothing happens when the user turned the hints off
/// (`liveMeetingAdviceEnabled`).
///
/// spec://iterations/ITER-076-meeting-hints-v2
@MainActor
final class LiveMeetingAdvisor: ObservableObject {

    /// True while a meeting with the live hints is recording.
    @Published private(set) var isActive = false

    private weak var meetingRecorder: MeetingRecorder?
    private weak var coordinator: TranscriptionCoordinator?
    private weak var adviceService: AdviceService?
    private let settings = AppSettings.shared
    private var captureScreen: @MainActor @Sendable () async -> String? = { nil }

    /// The environment of the session: the app's services.
    ///
    /// The app fills it in `configure`; the tests fill it with fakes, so the
    /// wiring can be driven without a window server, an engine or a network.
    var environment: LiveHintsEnvironment?

    /// Builds the session of a meeting. The tests replace it.
    var sessionBuilder: (LiveHintsEnvironment) -> any LiveHintsSession = { LiveHintsMeeting(environment: $0) }

    /// The session of the running meeting.
    private var session: (any LiveHintsSession)?
    private var cancellables = Set<AnyCancellable>()

    /// True while a meeting is recording — with the hints on or off.
    ///
    /// The switch in the settings can be flipped in the middle of a meeting,
    /// and the hints follow it: off takes everything down, on brings it up
    /// while the meeting runs (§6.16).
    private var isRecording = false

    /// The observer of the settings.
    private var settingsObserver: NSObjectProtocol?

    init() {
        observeSettings()
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    func configure(meetingRecorder: MeetingRecorder,
                    coordinator: TranscriptionCoordinator,
                    adviceService: AdviceService,
                    captureScreen: @escaping @MainActor @Sendable () async -> String? = { nil }) {
        self.meetingRecorder = meetingRecorder
        self.coordinator = coordinator
        self.adviceService = adviceService
        self.captureScreen = captureScreen
        environment = appEnvironment()
        MeetingCoachWaveModel.shared.bind(me: meetingRecorder.mic.$audioLevel.eraseToAnyPublisher(),
            them: meetingRecorder.systemAudio.$audioLevel.eraseToAnyPublisher(), state: .shared)

        // Auto-arm/disarm based on the recorder's @Published isRecording.
        meetingRecorder.$isRecording
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] recording in
                if recording {
                    Task { @MainActor in await self?.arm() }
                } else {
                    self?.disarm()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - The lifecycle

    /// The recording started: the session goes up.
    ///
    /// Internal, not private: the tests drive the wiring without a recorder.
    func arm() async {
        isRecording = true
        await startSessionIfAllowed()
    }

    /// The recording stopped: the session goes down.
    ///
    /// Internal, not private: the tests drive the wiring without a recorder.
    func disarm() {
        isRecording = false
        stopSession()
    }

    /// The session goes up — when a meeting is recording and the settings
    /// allow the hints.
    private func startSessionIfAllowed() async {
        guard isRecording else { return }
        guard settings.liveMeetingAdviceEnabled else {
            NSLog("[LiveHints] the hints are off in the settings — nothing is armed")
            return
        }
        guard !isActive else { return }
        guard let environment else {
            NSLog("[LiveHints] no environment — nothing is armed")
            return
        }
        environment.state.showRecordingSurface(generation: environment.generation())
        let session = sessionBuilder(environment)
        self.session = session
        isActive = true
        await session.start()
        NSLog("[LiveHints] ✅ armed")
    }

    /// The session goes down: the shortcut is taken back and the card goes
    /// away.
    private func stopSession() {
        // ALWAYS hide the overlay — even if the session is already gone
        // because `finalize()` (called from `AppDelegate.stopMeetingRecording`)
        // took it down before this Combine-driven sink fired. Without the
        // unconditional call here, the overlay was getting stuck visible after
        // a stop and the next user click on the overlay's STOP button would
        // `toggle` to a NEW recording instead of dismissing the stale overlay.
        (environment?.state ?? .shared).disarm(preservingQuestion: isRecording)
        guard let session else { return }
        self.session = nil
        isActive = false
        session.stop()
        NSLog("[LiveHints] ⏹ disarmed")
    }

    // MARK: - The switch in the settings

    /// The switch that turns the hints off lives in the settings, and the
    /// advisor has to know the moment it changes: the hints stop at once, in
    /// the middle of the meeting (§6.16).
    private func observeSettings() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil) { [weak self] _ in
            Task { @MainActor in self?.settingsChanged() }
        }
    }

    /// The settings changed: the hints follow them.
    private func settingsChanged() {
        if settings.liveMeetingAdviceEnabled {
            Task { @MainActor in await self.startSessionIfAllowed() }
        } else {
            stopSession()
        }
    }

    // MARK: - Finalization (consumed by AppDelegate.stopMeetingRecording)

    /// What the live hints heard, when the meeting ended.
    struct FinalizationResult {
        /// The transcript of the meeting, as the live hints heard it.
        let text: String
        /// How many lines the live hints collected.
        let partialCount: Int
        /// How far the microphone had been read.
        let micOffsetAtFinalize: Int
        /// How far the system stream had been read.
        let sysOffsetAtFinalize: Int
    }

    /// Stops the session and returns what the live hints heard.
    ///
    /// The saved transcript of the meeting does not come from here: it comes
    /// from the dual-stream pass over the whole recording, so that every line
    /// carries its speaker. This text is the log line of the meeting.
    ///
    /// Nil when there was no session — the hints were off, or the recording
    /// never started.
    func finalize() -> FinalizationResult? {
        guard let session else { return nil }
        self.session = nil
        isActive = false
        let result = session.finalize()
        NSLog("[LiveHints] finalize → %d lines, %d chars, micOff=%d sysOff=%d",
              result.lineCount, result.text.count, result.micOffset, result.systemOffset)
        return FinalizationResult(
            text: result.text,
            partialCount: result.lineCount,
            micOffsetAtFinalize: result.micOffset,
            sysOffsetAtFinalize: result.systemOffset
        )
    }

    // MARK: - The environment

    /// The environment of the session, built out of the app's services.
    private func appEnvironment() -> LiveHintsEnvironment? {
        guard let recorder = meetingRecorder,
              let coordinator = coordinator,
              let advice = adviceService else { return nil }
        let settings = AppSettings.shared

        // The routes to the model: Pro first, then the user's own key, and
        // the local model only when neither cloud route exists.
        let routes = MeetingAnswerRoutes()
        routes.pro = ProAnswerRoute()
        routes.ownKey = OwnKeyAnswerRoute()
        routes.local = LocalAnswerRoute()

        return LiveHintsEnvironment(
            mic: recorder.mic,
            system: recorder.systemAudio,
            pauseWindows: { recorder.pauseWindowsSnapshot() },
            generation: { recorder.recordingGeneration },
            engine: { await coordinator.engineWhenReady(within: .seconds(10)) },
            language: { settings.transcriptionLanguage == "auto" ? nil : settings.transcriptionLanguage },
            promptWords: { language in TranscriptionLanguageResolver.enginePromptWords(language: language) },
            isAutoOn: { settings.meetingAutoAnswer },
            globalInputEnabled: { settings.globalInputEnabled },
            relevantMemories: { MeetingCoachService.shared.fetchRelevantMemoryContext(query: $0) },
            advice: advice,
            hotkey: MeetingHelpHotkey.shared,
            state: MeetingCoachState.shared,
            routes: routes,
            combo: { MeetingHelpCombo(keyCode: settings.meetingHelpKeyCode,
                                      modifiers: settings.meetingHelpModifiers) },
            screenEnabled: { settings.screenContextEnabled },
            captureScreen: captureScreen)
    }
}
