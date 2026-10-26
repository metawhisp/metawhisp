import SwiftData
import XCTest
@testable import MetaWhisp

/// C6 / PRD P0 3 — the practice's text exists in its own window and nowhere
/// else: no clipboard, history, export, recovery audio or insertion, on
/// success, error and cancel alike. The dictation pipeline is wired beside it,
/// sharing its engine, with a spy for recovery audio and a history of its own;
/// its clipboard and insertion paths both leave `lastResult` behind, and the
/// source guard below keeps the practice from holding any of them. Nothing
/// here can paste: auto-paste is off. An attempt cancelled or ended drops what
/// comes back late.
@MainActor
final class PracticeRecorderTests: XCTestCase {
    private var savedEngine = ""
    private var savedAutoSubmit = true
    private var recoverySaves = 0
    private var history: HistoryService!
    private var engine: PracticeEngine!
    private var dictation: TranscriptionCoordinator!
    private var capture: CaptureArbiter!

    override func setUpWithError() throws {
        savedEngine = AppSettings.shared.transcriptionEngine
        savedAutoSubmit = AppSettings.shared.autoSubmit
        AppSettings.shared.transcriptionEngine = "cloud"   // the spy engine stands in for the cloud one
        AppSettings.shared.autoSubmit = false
        recoverySaves = 0
        let container = try ModelContainer(for: Schema(versionedSchema: MetaWhispSchemaV9.self),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        history = HistoryService(container: container)
        engine = PracticeEngine()
        dictation = TranscriptionCoordinator(recorder: FakeMicrophone(), whisperEngine: nil,
                                             textInserter: TextInsertionService(),
                                             soundService: SoundService(enabled: { false }), settings: AppSettings.shared,
                                             voiceQuestions: VoiceQuestionState(), cloudEngine: engine,
                                             openMicrophoneSettings: {},
                                             proxyAvailable: { true })   // A4: cloud in use needs Pro or a key
        dictation.historyService = history
        dictation.saveRecoveryAudio = { [unowned self] _ in recoverySaves += 1; return nil }
        capture = CaptureArbiter(busyElsewhere: { false })
        dictation.captureArbiter = capture
    }

    override func tearDownWithError() throws {
        engine.finish()
        AppSettings.shared.transcriptionEngine = savedEngine
        AppSettings.shared.autoSubmit = savedAutoSubmit
    }

    private func practice(_ microphone: FakeMicrophone? = nil) -> PracticeRecorder {
        let flow = dictation!
        let practice = PracticeRecorder(microphone: microphone ?? FakeMicrophone(), engine: { flow.activeEngine }, arbiter: capture,
                                        language: { nil })
        practice.begin()
        return practice
    }

    private func settle(_ practice: PracticeRecorder) {
        let deadline = Date().addingTimeInterval(2)
        while practice.phase == .transcribing, !engine.isWaiting, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Nothing reached any sink a dictation writes to.
    private func assertNothingLeftThePractice(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(recoverySaves, 0, "recovery audio", file: file, line: line)
        XCTAssertEqual(try ModelContext(history.modelContainer).fetchCount(FetchDescriptor<HistoryItem>()), 0,
                       "history — and the export that follows a saved item", file: file, line: line)
        XCTAssertNil(dictation.lastResult, "the clipboard and insertion paths both set it", file: file, line: line)
        XCTAssertNil(dictation.lastError, file: file, line: line)
        XCTAssertEqual(dictation.stage, .idle, file: file, line: line)
    }

    // MARK: - Every path keeps nothing

    func testAResultStaysInThePractice() throws {
        let practice = practice()
        practice.toggle()
        practice.toggle()
        settle(practice)
        XCTAssertEqual(practice.phase, .result("what is on my screen"))
        try assertNothingLeftThePractice()
    }

    func testAFailedTranscriptionKeepsNoAudio() throws {
        engine.error = URLError(.notConnectedToInternet)
        let practice = practice()
        practice.toggle()
        practice.toggle()
        settle(practice)
        guard case .failed = practice.phase else { return XCTFail("\(practice.phase)") }
        try assertNothingLeftThePractice()
    }

    func testACancelledAttemptKeepsNothingAndDropsItsLateResult() throws {
        engine.holds = true
        let practice = practice()
        practice.toggle()
        practice.toggle()
        settle(practice)
        XCTAssertTrue(engine.isWaiting)
        practice.cancel()
        XCTAssertEqual(practice.phase, .ready)
        engine.finish()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(practice.phase, .ready, "a result for a cancelled attempt never lands")
        try assertNothingLeftThePractice()
    }

    func testEndingTheScreenDropsALateResult() throws {
        engine.holds = true
        let practice = practice()
        practice.toggle()
        practice.toggle()
        settle(practice)
        practice.end()
        engine.finish()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if case .result = practice.phase { XCTFail("the late result landed after the screen ended") }
        try assertNothingLeftThePractice()
    }

    /// Step-1 review #5: the screen goes away mid-transcription without
    /// end() — the held transcription must keep nothing alive, and capture and
    /// the lease come back.
    func testDroppingAPracticeMidTranscriptionGivesCaptureAndTheLeaseBack() {
        engine.holds = true
        var busy: [Bool] = []
        capture.onPracticeBusy = { busy.append($0) }
        var practice: PracticeRecorder? = self.practice()
        practice?.toggle()
        practice?.toggle()
        settle(practice!)
        XCTAssertTrue(engine.isWaiting)
        weak var gone = practice
        practice = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(gone, "the transcription keeps no practice alive")
        // Read before anything asks the arbiter: asking settles the claim too.
        XCTAssertEqual(busy.last, false, "the lease goes idle unasked")
        XCTAssertNil(capture.refusal, "capture is back")
        engine.finish()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(capture.refusal)
    }

    /// The same for a screen that goes away while listening: its microphone
    /// stops, so nothing keeps recording beside the next dictation.
    func testDroppingAListeningPracticeStopsItsMicrophone() {
        let microphone = FakeMicrophone()
        var busy: [Bool] = []
        capture.onPracticeBusy = { busy.append($0) }
        var practice: PracticeRecorder? = self.practice(microphone)
        practice?.toggle()
        XCTAssertTrue(microphone.isRecording)
        practice = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(microphone.isRecording, "the microphone stopped with the screen")
        XCTAssertEqual(busy.last, false, "the lease goes idle unasked")
    }

    /// Round-2 N3: the practice microphone is one the app keeps, so the next
    /// practice records on the same one. An ended practice's teardown must
    /// not stop the recording that came after it.
    func testAnEndedPracticeGoingAwayLeavesTheNextRecordingOnTheSameMicrophone() {
        let microphone = FakeMicrophone()
        var old: PracticeRecorder? = self.practice(microphone)
        old?.toggle()
        old?.end()
        weak var gone = old
        let next = self.practice(microphone)
        next.toggle()
        XCTAssertTrue(microphone.isRecording)
        old = nil
        XCTAssertNil(gone)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(microphone.isRecording, "the next recording keeps running")
        XCTAssertEqual(next.phase, .listening)
        next.end()
    }

    /// A practice dropped without `end()` stops only the recording it was
    /// listening in: not one the microphone has moved on to since…
    func testATeardownLeavesARecordingTheMicrophoneMovedOnTo() throws {
        let microphone = FakeMicrophone()
        var old: PracticeRecorder? = self.practice(microphone)
        old?.toggle()
        _ = microphone.stop()
        try microphone.start()                 // another recording on the app's microphone
        old = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(microphone.isRecording, "not the practice's recording")
    }

    /// …but its own, even while a device change has paused it: the follow
    /// waiting to resume it would otherwise bring it back with no one to stop it.
    func testATeardownStopsItsOwnRecordingThatADeviceChangePaused() {
        let microphone = FakeMicrophone()
        var old: PracticeRecorder? = self.practice(microphone)
        old?.toggle()
        microphone.isRecording = false         // the input went away; the follow waits for the next one
        let stops = microphone.stops
        old = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(microphone.stops, stops + 1, "stopped, and the follow with it")
    }

    /// A practice is never counted against the Pro minutes.
    func testThePracticeIsNotBilled() {
        let practice = practice()
        practice.toggle()
        practice.toggle()
        settle(practice)
        XCTAssertEqual(engine.billed, [false])
    }

    // MARK: - No speech

    func testATapTooShortOrTooQuietIsNoSpeechAndTranscribesNothing() {
        for recording in [Array(repeating: Float(0.1), count: 3_000), Array(repeating: Float(0.0001), count: 16_000)] {
            let microphone = FakeMicrophone()
            microphone.recording = recording
            let practice = practice(microphone)
            practice.toggle()
            practice.toggle()
            XCTAssertEqual(practice.phase, .noSpeech)
            practice.end()
        }
        XCTAssertEqual(engine.billed, [], "nothing was sent")
    }

    func testADeadMicrophoneSaysSo() {
        let microphone = FakeMicrophone()
        microphone.recording = Array(repeating: 0, count: 16_000)
        let practice = practice(microphone)
        practice.toggle()
        practice.toggle()
        XCTAssertEqual(practice.phase, .failed(AudioRecordingService.deadMicMessage))
    }

    /// Dictation's capture path judges a microphone that delivered nothing by the clock and says so after the
    /// recording (59a8953): an empty recording with that verdict is the dead microphone, as dictation says it —
    /// never "No speech detected. Try again a little closer to the microphone."
    func testAnEmptyRecordingFromAMicrophoneJudgedDeadSaysSo() {
        let microphone = FakeMicrophone()
        microphone.recording = []
        microphone.micHealthError = AudioRecordingService.deadMicMessage
        let practice = practice(microphone)
        practice.toggle()
        practice.toggle()
        XCTAssertEqual(practice.phase, .failed(AudioRecordingService.deadMicMessage))
        XCTAssertEqual(engine.billed, [], "nothing was sent")
    }

    /// The paired case: an empty recording with no verdict is a tap too short, no speech.
    func testAnEmptyRecordingWithoutAVerdictIsNoSpeech() {
        let microphone = FakeMicrophone()
        microphone.recording = []
        let practice = practice(microphone)
        practice.toggle()
        practice.toggle()
        XCTAssertEqual(practice.phase, .noSpeech)
    }

    func testWhatTheFiltersCatchIsNoSpeech() throws {
        for text in ["", "♪♪♪", "Subtitles by DimaTorzok"] {
            engine.text = text
            let practice = practice()
            practice.toggle()
            practice.toggle()
            settle(practice)
            XCTAssertEqual(practice.phase, .noSpeech, text)
            practice.end()
        }
        try assertNothingLeftThePractice()
    }

    // MARK: - Dictation's capture

    /// The practice records the way dictation records: the input alone (`InputOnlyCapture`), not the
    /// AVAudioEngine a Bluetooth headset resets until it records nothing (59a8953 moved dictation, and the practice
    /// stayed behind on the engine). The app makes the practice's microphone from dictation's own path, so the two
    /// cannot part again.
    func testThePracticeRecordsOnDictationsCapturePath() throws {
        let app = try OnboardingWindowTests.codeLines(of: "App/AppDelegate.swift")
        let dictation = try XCTUnwrap(app.first { $0.contains("let recorder = AudioRecordingService(") })
        XCTAssertTrue(dictation.contains("path: .inputOnly"), "dictation records the input alone: \(dictation)")
        let practices = app.filter { $0.contains("practiceMic = AudioRecordingService(") }
        XCTAssertEqual(practices.count, 1, "\(practices)")
        XCTAssertTrue(practices.allSatisfy { $0.contains("AudioRecordingService(path: recorder.path)") },
                      "the practice takes dictation's path: \(practices)")
        XCTAssertTrue(app.contains { $0.contains("microphone: practiceMic") }, "and the onboarding gets that one")
    }

    // MARK: - The source holds no way out

    /// Nothing in the practice can reach a clipboard, the history, an export,
    /// the recovery folder or the focused app.
    func testThePracticeHoldsNothingThatKeepsOrDeliversText() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Services/System/PracticeRecorder.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        for sink in ["NSPasteboard", "saveSuspectToClipboard", "TextInsertionService", "insertResult", "historyService",
                     "HistoryService", "saveSamplesAsWav", "saveRecoveryAudio", "recoveryDirectory", "exportHistoryItem",
                     "ObsidianExporter", "conversationGrouper", "lastResult"] {
            XCTAssertFalse(source.contains(sink), "PracticeRecorder.swift mentions \(sink)")
        }
    }
}

/// The engine dictation and the practice share: answers at once or when told,
/// or fails, and records whether each call was billed.
final class PracticeEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "Practice engine"
    let isModelLoaded = true
    private let lock = NSLock()
    private var held: CheckedContinuation<TranscriptionResult, Error>?
    private var _billed: [Bool] = []
    private var _holds = false
    private var _error: Error?
    private var _text = "what is on my screen"

    var holds: Bool {
        get { lock.withLock { _holds } }
        set { lock.withLock { _holds = newValue } }
    }
    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    var text: String {
        get { lock.withLock { _text } }
        set { lock.withLock { _text = newValue } }
    }
    var billed: [Bool] { lock.withLock { _billed } }
    var isWaiting: Bool { lock.withLock { held != nil } }

    func loadModel(_ modelName: String, progressHandler: (@Sendable (Double) -> Void)?) async throws {}
    func unloadModel() async {}

    func transcribe(audioSamples: [Float], language: String?, promptWords: [String],
                    countUsage: Bool) async throws -> TranscriptionResult {
        let (holds, error) = lock.withLock { () -> (Bool, Error?) in
            _billed.append(countUsage)
            return (_holds, _error)
        }
        if let error { throw error }
        if !holds { return result }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { held = continuation }
        }
    }

    func finish() {
        let continuation = lock.withLock { () -> CheckedContinuation<TranscriptionResult, Error>? in
            defer { held = nil }
            return held
        }
        continuation?.resume(returning: result)
    }

    private var result: TranscriptionResult {
        TranscriptionResult(text: text, language: "en", duration: 1, processingTime: 0.1, segments: [])
    }
}
