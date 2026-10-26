import XCTest
@testable import MetaWhisp

/// C6 — one owner of microphone capture. While the onboarding practice has it,
/// every other entry point is refused politely, and a hotkey drives the
/// practice instead. The practice in turn waits for a dictation or a meeting.
/// Every refusal is paired with its release: capture works again once the
/// practice ends, is cancelled and closed, or simply goes away.
@MainActor
final class CaptureArbiterTests: XCTestCase {
    private var savedEngine = ""
    private var savedAutoSubmit = true
    private var island = VoiceQuestionState()
    /// What the lease would say about dictations and meetings.
    private var busyElsewhere = false

    override func setUpWithError() throws {
        savedEngine = AppSettings.shared.transcriptionEngine
        savedAutoSubmit = AppSettings.shared.autoSubmit
        AppSettings.shared.transcriptionEngine = "cloud"
        AppSettings.shared.autoSubmit = false
        island = VoiceQuestionState()
        busyElsewhere = false
    }

    override func tearDownWithError() throws {
        island.dismiss()
        AppSettings.shared.transcriptionEngine = savedEngine
        AppSettings.shared.autoSubmit = savedAutoSubmit
    }

    private func arbiter() -> CaptureArbiter {
        CaptureArbiter(busyElsewhere: { [unowned self] in busyElsewhere })
    }

    private func dictation(_ microphone: FakeMicrophone, _ arbiter: CaptureArbiter) -> TranscriptionCoordinator {
        let flow = TranscriptionCoordinator(recorder: microphone, whisperEngine: nil, textInserter: TextInsertionService(),
                                            soundService: SoundService(enabled: { false }), settings: AppSettings.shared,
                                            voiceQuestions: island, cloudEngine: HeldEngine(answersAtOnce: true),
                                            openMicrophoneSettings: {},
                                            proxyAvailable: { true })   // A4: cloud in use needs Pro or a key
        flow.captureArbiter = arbiter
        return flow
    }

    private func practice(_ arbiter: CaptureArbiter, microphone: FakeMicrophone? = nil) -> PracticeRecorder {
        PracticeRecorder(microphone: microphone ?? FakeMicrophone(), engine: { HeldEngine(answersAtOnce: true) }, arbiter: arbiter,
                         language: { nil })
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// A meeting recorder that asks the arbiter. Its system audio can neither
    /// capture nor ask; every test stops a start that went ahead in the same
    /// turn, before its task runs. Returned once the relay has delivered its
    /// first value, which would otherwise clear the line a turn later.
    private func meeting(_ arbiter: CaptureArbiter) -> (MeetingRecorder, SystemAudioCaptureService) {
        let system = SystemAudioCaptureService()
        system.screenRecordingGranted = { false }
        system.askForScreenRecording = { _ in XCTFail("nothing here may ask"); return false }
        let meeting = MeetingRecorder(mic: AudioRecordingService(), systemAudio: system)
        meeting.captureArbiter = arbiter
        spin(0.05)
        return (meeting, system)
    }

    // MARK: - While the practice has the microphone

    func testADictationIsRefusedPolitelyFromEveryEntryPoint() {
        let capture = arbiter()
        let microphone = FakeMicrophone()
        let flow = dictation(microphone, capture)
        let practice = practice(capture)
        practice.begin()

        flow.toggle()   // the menu and Dashboard RECORD buttons, Right ⌘
        XCTAssertEqual(flow.stage, .idle)
        XCTAssertFalse(microphone.isRecording)
        XCTAssertEqual(flow.lastError, CaptureArbiter.finishThePracticeFirst)

        flow.startPTT()
        XCTAssertFalse(microphone.isRecording, "push-to-talk")

        flow.startVoiceQuestion()
        XCTAssertFalse(microphone.isRecording, "voice question")
        guard case .error(let text) = island.phase else { return XCTFail("the island must not sit in Listening: \(island.phase)") }
        XCTAssertEqual(text, CaptureArbiter.finishThePracticeFirst)
    }

    /// Step-1 review #10 — a meeting is refused on the line the popover shows
    /// (`MeetingRecorder.lastError`), and the refusal is still there after the
    /// system-audio relay's next turn: a reset queued before it used to erase
    /// it. The line holds an earlier meeting's failure first, as after a
    /// failed start.
    func testAMeetingIsRefusedOnTheLineThePopoverShows() {
        let capture = arbiter()
        let (meeting, system) = meeting(capture)
        system.lastError = "System audio failed: No display found for system audio capture"
        spin(0.05)
        let practice = practice(capture)
        practice.begin()

        let started = meeting.start(manualMode: true, ask: PermissionAsk())
        if started { _ = meeting.stop() }     // a broken refusal must not reach any capture
        XCTAssertFalse(started)
        spin(0.1)                             // the relay's turn
        XCTAssertEqual(meeting.lastError, CaptureArbiter.finishThePracticeFirst)
        XCTAssertFalse(meeting.isStarting)
        XCTAssertFalse(system.isStarting, "nothing was started")
    }

    /// …and the refusal goes with its cause: once the practice ends the line
    /// clears and the same start goes ahead.
    func testAMeetingRefusedWhileThePracticeHadTheMicrophoneStartsOnceItEnds() {
        let capture = arbiter()
        let (meeting, system) = meeting(capture)
        let practice = practice(capture)
        practice.begin()
        let refused = meeting.start(manualMode: false)
        if refused { _ = meeting.stop() }
        XCTAssertFalse(refused)
        XCTAssertEqual(meeting.lastError, CaptureArbiter.finishThePracticeFirst)

        practice.end()
        spin(0.05)
        XCTAssertNil(meeting.lastError, "the refusal goes with its cause")
        let started = meeting.start(manualMode: false)
        let wasStarting = meeting.isStarting
        _ = meeting.stop()                    // retires the start before its task reaches any capture
        XCTAssertTrue(started)
        XCTAssertTrue(wasStarting)
        spin(0.05)
        XCTAssertFalse(system.isStarting)
    }

    func testAHotkeyDrivesThePractice() {
        let capture = arbiter()
        let microphone = FakeMicrophone()
        let practice = practice(capture, microphone: microphone)
        var dictations = 0
        capture.route(dictation: { dictations += 1 }, practice: { $0.toggle() })
        XCTAssertEqual(dictations, 1, "no practice: the hotkey dictates")

        practice.begin()
        capture.route(dictation: { dictations += 1 }, practice: { $0.toggle() })
        XCTAssertEqual(dictations, 1)
        XCTAssertEqual(practice.phase, .listening, "Right ⌘ records the practice")
        XCTAssertTrue(microphone.isRecording)
    }

    // MARK: - The release of each refusal

    func testCaptureComesBackWhenThePracticeEnds() {
        let capture = arbiter()
        let microphone = FakeMicrophone()
        let flow = dictation(microphone, capture)
        let practice = practice(capture)
        practice.begin()
        flow.toggle()
        XCTAssertEqual(flow.lastError, CaptureArbiter.finishThePracticeFirst)

        practice.end()
        XCTAssertNil(capture.refusal)
        XCTAssertNil(flow.lastError, "the refusal line goes with its cause")
        spin(0.05)   // the toggle's debounce
        flow.toggle()
        XCTAssertEqual(flow.stage, .recording)
        XCTAssertTrue(microphone.isRecording)
    }

    /// Esc during an attempt, then the window closed.
    func testCaptureComesBackWhenThePracticeIsCancelledAndClosed() {
        let capture = arbiter()
        let dictationMicrophone = FakeMicrophone()
        let practiceMicrophone = FakeMicrophone()
        let flow = dictation(dictationMicrophone, capture)
        let practice = practice(capture, microphone: practiceMicrophone)
        practice.begin()
        practice.start()
        XCTAssertTrue(practiceMicrophone.isRecording)
        practice.cancel()
        XCTAssertFalse(practiceMicrophone.isRecording, "Esc stops the practice's microphone")
        XCTAssertEqual(capture.refusal, CaptureArbiter.finishThePracticeFirst, "the screen is still up")
        practice.end()
        flow.toggle()
        XCTAssertEqual(flow.stage, .recording)
    }

    /// A practice screen torn down without saying so cannot hold the microphone.
    func testCaptureComesBackWhenThePracticeGoesAway() {
        let capture = arbiter()
        var practice: PracticeRecorder? = practice(capture)
        practice?.begin()
        XCTAssertNotNil(capture.refusal)
        practice = nil
        XCTAssertNil(capture.refusal)
    }

    // MARK: - The practice waits

    func testThePracticeWaitsForADictationOrMeetingAndGetsInWhenItEnds() {
        let capture = arbiter()
        let microphone = FakeMicrophone()
        let practice = practice(capture, microphone: microphone)
        busyElsewhere = true
        practice.begin()
        XCTAssertEqual(practice.phase, .waiting(CaptureArbiter.finishYourDictationFirst))
        practice.toggle()
        XCTAssertFalse(microphone.isRecording, "it waits")
        XCTAssertNil(capture.refusal, "the dictation keeps its microphone")

        busyElsewhere = false
        capture.recheck()   // the lease reports the dictation's end
        XCTAssertEqual(practice.phase, .ready)
        XCTAssertEqual(capture.refusal, CaptureArbiter.finishThePracticeFirst)
        practice.toggle()
        XCTAssertTrue(microphone.isRecording)
    }

    func testAPracticeThatLeftWhileWaitingNeverTakesTheMicrophoneLater() {
        let capture = arbiter()
        let practice = practice(capture)
        busyElsewhere = true
        practice.begin()
        practice.end()
        busyElsewhere = false
        capture.recheck()
        XCTAssertNil(capture.refusal)
        XCTAssertNotEqual(practice.phase, .listening)
    }

    // MARK: - The lease

    func testTheLeaseHearsWhenThePracticeRecordsAndTranscribes() {
        let capture = arbiter()
        var busy: [Bool] = []
        capture.onPracticeBusy = { busy.append($0) }
        let practice = practice(capture)
        practice.begin()
        practice.start()
        practice.stop()
        let deadline = Date().addingTimeInterval(2)
        while practice.phase == .transcribing, Date() < deadline { spin(0.01) }
        XCTAssertEqual(practice.phase, .result("what is on my screen"))
        XCTAssertEqual(busy, [true, false], "busy from the first sound to the result")
    }

    func testEndingTheScreenLeavesTheLeaseIdle() {
        let capture = arbiter()
        var busy: [Bool] = []
        capture.onPracticeBusy = { busy.append($0) }
        let practice = practice(capture)
        practice.begin()
        practice.start()
        practice.end()
        XCTAssertEqual(busy.last, false)
    }
}

/// Step-1 review #9 — the practice's first record press on a microphone
/// nobody answered asks, the same one-shot way dictation's does: the press
/// that asks records nothing, the next one records; a "no" is said, and asked
/// again it stays one prompt.
@MainActor
final class PracticeMicrophoneTests: XCTestCase {
    private func practice(_ microphone: FakeMicrophone) -> PracticeRecorder {
        let practice = PracticeRecorder(microphone: microphone, engine: { HeldEngine(answersAtOnce: true) },
                                        arbiter: CaptureArbiter(busyElsewhere: { false }), language: { nil })
        practice.begin()
        return practice
    }

    private func neverAsked(grants: Bool) -> FakeMicrophone {
        let microphone = FakeMicrophone()
        microphone.hasPermission = false
        microphone.permissionUndetermined = true
        microphone.grantsOnRequest = grants
        return microphone
    }

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    func testTheFirstPressAsksAndTheNextRecords() {
        let microphone = neverAsked(grants: true)
        let practice = practice(microphone)
        practice.toggle()
        practice.toggle()            // pressed again before the answer
        XCTAssertFalse(microphone.isRecording, "the press that asks records nothing")
        spin()
        XCTAssertEqual(microphone.permissionRequests, 1, "one prompt")
        XCTAssertEqual(practice.phase, .ready)
        practice.toggle()
        XCTAssertEqual(practice.phase, .listening)
        XCTAssertTrue(microphone.isRecording)
    }

    func testANoIsSaidAndAskingAgainShowsNoSecondPrompt() {
        let microphone = neverAsked(grants: false)
        let practice = practice(microphone)
        practice.toggle()
        spin()
        XCTAssertEqual(practice.phase, .failed(PracticeRecorder.microphoneOff))
        practice.toggle()            // tried again: macOS keeps the "no"
        spin()
        XCTAssertEqual(microphone.permissionRequests, 1)
        XCTAssertEqual(practice.phase, .failed(PracticeRecorder.microphoneOff))
        XCTAssertFalse(microphone.isRecording)
    }

    /// Allowed later in System Settings: the next press records.
    func testAMicrophoneAllowedLaterRecordsOnTheNextPress() {
        let microphone = neverAsked(grants: false)
        let practice = practice(microphone)
        practice.toggle()
        spin()
        microphone.hasPermission = true
        practice.toggle()
        XCTAssertEqual(practice.phase, .listening)
        XCTAssertTrue(microphone.isRecording)
    }
}
