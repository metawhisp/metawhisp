import XCTest
@testable import MetaWhisp

@MainActor
final class TranscriptionCoordinatorHotkeyTests: XCTestCase {
    private var now = Date(timeIntervalSinceReferenceDate: 1_000)

    private func coordinator(_ microphone: FakeMicrophone) -> TranscriptionCoordinator {
        microphone.recording = [] // Stop synchronously without a model, network, or text delivery.
        return TranscriptionCoordinator(
            recorder: microphone, whisperEngine: nil, textInserter: TextInsertionService(),
            soundService: SoundService(enabled: { false }), settings: .shared,
            voiceQuestions: VoiceQuestionState(), cloudEngine: HeldEngine(answersAtOnce: true),
            openMicrophoneSettings: {}, proxyAvailable: { false }, clock: { self.now })
    }

    func testPTTReleaseLeavesMenuTapAndTranslatedRecordingsRunning() {
        checkRejectedStart(voiceQuestion: false)
    }

    func testVoiceQuestionReleaseLeavesMenuTapAndTranslatedRecordingsRunning() {
        checkRejectedStart(voiceQuestion: true)
    }

    private func checkRejectedStart(voiceQuestion: Bool) {
        // Menu and Right Command tap both call toggle; Right Option calls toggleWithTranslation.
        for translated in [false, true] {
            let microphone = FakeMicrophone()
            let flow = coordinator(microphone)
            translated ? flow.toggleWithTranslation() : flow.toggle()
            voiceQuestion ? flow.startVoiceQuestion() : flow.startPTT()
            voiceQuestion ? flow.stopVoiceQuestion() : flow.stopPTT()
            XCTAssertEqual(flow.stage, .recording)
            XCTAssertTrue(microphone.isRecording)
            XCTAssertEqual(microphone.stops, 0)
            now.addTimeInterval(1)
            flow.toggle()
        }
    }

    func testPTTReleaseStopsItsOwnRecordingExactlyOnce() { checkAcceptedStart(voiceQuestion: false) }
    func testVoiceQuestionReleaseStopsItsOwnRecordingExactlyOnce() { checkAcceptedStart(voiceQuestion: true) }

    private func checkAcceptedStart(voiceQuestion: Bool) {
        let microphone = FakeMicrophone()
        let flow = coordinator(microphone)
        voiceQuestion ? flow.startVoiceQuestion() : flow.startPTT()
        XCTAssertEqual(flow.stage, .recording)
        voiceQuestion ? flow.stopVoiceQuestion() : flow.stopPTT()
        voiceQuestion ? flow.stopVoiceQuestion() : flow.stopPTT()
        XCTAssertEqual(flow.stage, .idle)
        XCTAssertFalse(microphone.isRecording)
        XCTAssertEqual(microphone.stops, 1)
    }

    func testPTTReleaseLeavesANewMenuRecordingAfterATapStoppedItsOwn() { checkReplacedRecording(voiceQuestion: false) }
    func testVoiceQuestionReleaseLeavesANewMenuRecordingAfterATapStoppedItsOwn() { checkReplacedRecording(voiceQuestion: true) }

    private func checkReplacedRecording(voiceQuestion: Bool) {
        let microphone = FakeMicrophone()
        let flow = coordinator(microphone)
        voiceQuestion ? flow.startVoiceQuestion() : flow.startPTT()
        flow.toggle() // A tap ends the hold's recording.
        XCTAssertEqual(flow.stage, .idle)
        now.addTimeInterval(1) // Beyond the tap debounce, without sleeping.
        flow.toggle() // A new menu recording starts before the old hold releases.
        XCTAssertEqual(flow.stage, .recording)
        voiceQuestion ? flow.stopVoiceQuestion() : flow.stopPTT()
        XCTAssertEqual(flow.stage, .recording)
        XCTAssertTrue(microphone.isRecording)
        XCTAssertEqual(microphone.stops, 1)
        now.addTimeInterval(1)
        flow.toggle()
    }
}
