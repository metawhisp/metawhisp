import XCTest
@testable import MetaWhisp

/// C4 / PRD P0 1 — launch asks for no permission, in any state. The microphone
/// is asked for by the first record press instead: the release of "never at
/// launch". A fake microphone stands in for the system prompt, so nothing here
/// can show one.
@MainActor
final class MicrophoneFirstUseTests: XCTestCase {
    private var savedEngine = ""
    private var savedAutoSubmit = true
    private var settingsOpened = 0
    private var island = VoiceQuestionState()

    override func setUpWithError() throws {
        savedEngine = AppSettings.shared.transcriptionEngine
        savedAutoSubmit = AppSettings.shared.autoSubmit
        // The held engine stands in for the cloud one, and nothing is ever pasted.
        AppSettings.shared.transcriptionEngine = "cloud"
        AppSettings.shared.autoSubmit = false
        settingsOpened = 0
        island = VoiceQuestionState()
    }

    override func tearDownWithError() throws {
        island.dismiss()
        AppSettings.shared.transcriptionEngine = savedEngine
        AppSettings.shared.autoSubmit = savedAutoSubmit
    }

    private enum Answer: String { case granted, neverAsked, denied }

    private func microphone(_ answer: Answer) -> FakeMicrophone {
        let microphone = FakeMicrophone()
        microphone.hasPermission = answer == .granted
        microphone.permissionUndetermined = answer == .neverAsked
        return microphone
    }

    private func coordinator(_ microphone: FakeMicrophone) -> TranscriptionCoordinator {
        TranscriptionCoordinator(recorder: microphone, whisperEngine: nil, textInserter: TextInsertionService(),
                                 soundService: SoundService(enabled: { false }), settings: AppSettings.shared,
                                 voiceQuestions: island, cloudEngine: HeldEngine(answersAtOnce: true),
                                 openMicrophoneSettings: { [weak self] in self?.settingsOpened += 1 },
                                 proxyAvailable: { true })   // A4: cloud in use needs Pro or a key
    }

    private func spin(until done: () -> Bool, within seconds: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Launch

    /// The warm-up touches the input node, which can bring the prompt up as
    /// well, so only a granted microphone is warmed.
    func testLaunchAsksForNothingAndWarmsOnlyAGrantedMicrophone() {
        for answer in [Answer.granted, .neverAsked, .denied] {
            let microphone = microphone(answer)
            let flow = coordinator(microphone)
            var warmUps = 0
            flow.prepareMicrophoneAtLaunch(warmUp: { warmUps += 1 })
            XCTAssertEqual(microphone.permissionRequests, 0, "\(answer.rawValue): launch asks nothing")
            XCTAssertEqual(warmUps, answer == .granted ? 1 : 0, answer.rawValue)
        }
        XCTAssertEqual(settingsOpened, 0)
    }

    /// The popover's red line is the slot that says so; nothing is added to the popover.
    func testAMissingMicrophoneIsSaidInTheRedLineThatExists() {
        let neverAsked = coordinator(microphone(.neverAsked))
        neverAsked.prepareMicrophoneAtLaunch(warmUp: {})
        XCTAssertEqual(neverAsked.lastError, TranscriptionCoordinator.microphoneNotAllowedYet)

        let denied = coordinator(microphone(.denied))
        denied.prepareMicrophoneAtLaunch(warmUp: {})
        XCTAssertEqual(denied.lastError, TranscriptionCoordinator.microphoneDeniedAtLaunch)

        let granted = coordinator(microphone(.granted))
        granted.prepareMicrophoneAtLaunch(warmUp: {})
        XCTAssertNil(granted.lastError)
    }

    // MARK: - The first record press

    /// The menu and Dashboard RECORD buttons and Right ⌘ all toggle the coordinator.
    func testTheFirstRecordPressAsksForTheMicrophone() {
        let microphone = microphone(.neverAsked)
        let flow = coordinator(microphone)
        flow.lastError = TranscriptionCoordinator.microphoneNotAllowedYet   // as launch left it
        flow.toggle()
        spin(until: { microphone.permissionRequests > 0 && flow.lastError == nil })
        XCTAssertEqual(microphone.permissionRequests, 1, "the press shows the prompt")
        XCTAssertEqual(settingsOpened, 0, "never answered: the prompt, not System Settings")
        XCTAssertEqual(flow.stage, .idle, "the press that asks records nothing")
        XCTAssertFalse(microphone.isRecording)
        XCTAssertNil(flow.lastError, "allowed: the red line goes")

        spin(until: { false }, within: 0.05)   // the toggle's debounce
        flow.toggle()
        XCTAssertEqual(flow.stage, .recording, "the next press records")
        XCTAssertEqual(microphone.permissionRequests, 1)
    }

    func testAFirstPressAnsweredNoSaysSoAndTheNextOpensSystemSettings() {
        let microphone = microphone(.neverAsked)
        microphone.grantsOnRequest = false
        let flow = coordinator(microphone)
        flow.toggle()
        spin(until: { microphone.permissionRequests > 0 && flow.lastError?.contains("denied") == true })
        XCTAssertEqual(microphone.permissionRequests, 1)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertTrue(flow.lastError?.contains("denied") == true, "\(flow.lastError ?? "nil")")

        spin(until: { false }, within: 0.05)
        flow.toggle()
        XCTAssertEqual(settingsOpened, 1, "a standing no: System Settings, as before")
        XCTAssertEqual(microphone.permissionRequests, 1, "macOS would not show the prompt again")
    }

    /// The key is released, and pressed again, while the prompt is still up.
    func testPushToTalkAsksOnceAndRecordsNothing() {
        let microphone = microphone(.neverAsked)
        let flow = coordinator(microphone)
        flow.startPTT()
        flow.stopPTT()
        flow.startPTT()
        spin(until: { microphone.permissionRequests > 0 && flow.lastError == nil })
        XCTAssertEqual(microphone.permissionRequests, 1, "one prompt, however often the key goes down")
        XCTAssertEqual(flow.stage, .idle)
        XCTAssertFalse(microphone.isRecording)
    }

    /// D3 — the onboarding's "Allow microphone" is the first press's own prompt: a record press while it is up
    /// asks nothing more, and the red line follows the answer.
    func testTheOnboardingsAllowIsTheFirstPressPromptAndAsksOnce() {
        let microphone = microphone(.neverAsked)
        let flow = coordinator(microphone)
        flow.lastError = TranscriptionCoordinator.microphoneNotAllowedYet   // as launch left it
        var answers: [Bool] = []
        flow.askForMicrophone(PermissionAsk()) { answers.append($0) }
        flow.toggle()
        spin(until: { answers.count == 1 })
        XCTAssertEqual(microphone.permissionRequests, 1, "one prompt")
        XCTAssertEqual(answers, [true])
        XCTAssertEqual(flow.stage, .idle, "the asking records nothing")
        XCTAssertNil(flow.lastError, "allowed: the red line goes")
        XCTAssertEqual(settingsOpened, 0)
    }

    func testAVoiceQuestionOnAMicrophoneNeverAskedAsksForIt() {
        let microphone = microphone(.neverAsked)
        let flow = coordinator(microphone)
        flow.startVoiceQuestion()
        spin(until: { microphone.permissionRequests > 0 })
        XCTAssertEqual(microphone.permissionRequests, 1)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertEqual(flow.stage, .idle)
        guard case .error(let text) = island.phase else { return XCTFail("the island must not sit in Listening: \(island.phase)") }
        XCTAssertTrue(text.contains("Allow the microphone"), text)
    }
}
