import XCTest
@testable import MetaWhisp

@MainActor
final class PracticeRecorderHotkeyTests: XCTestCase {
    private func practice(_ microphone: FakeMicrophone) -> (PracticeRecorder, CaptureArbiter) {
        microphone.recording = []
        let arbiter = CaptureArbiter(busyElsewhere: { false })
        let practice = PracticeRecorder(microphone: microphone, engine: { nil }, arbiter: arbiter, language: { nil })
        practice.begin()
        return (practice, arbiter)
    }

    func testPTTReleaseLeavesAButtonOrTapRecordingRunning() { checkRejectedStart(voiceQuestion: false) }
    func testVoiceQuestionReleaseLeavesAButtonOrTapRecordingRunning() { checkRejectedStart(voiceQuestion: true) }

    private func checkRejectedStart(voiceQuestion: Bool) {
        let microphone = FakeMicrophone()
        let (flow, arbiter) = practice(microphone)
        defer { flow.end(); withExtendedLifetime(arbiter) {} }
        flow.toggle() // Record button, tap, and translated tap share the practice toggle.
        voiceQuestion ? flow.startVoiceQuestion() : flow.startPTT()
        voiceQuestion ? flow.stopVoiceQuestion() : flow.stopPTT()
        XCTAssertEqual(flow.phase, .listening)
        XCTAssertTrue(microphone.isRecording)
        XCTAssertEqual(microphone.stops, 0)
    }

    func testPTTReleaseStopsItsOwnRecordingExactlyOnce() { checkAcceptedStart(voiceQuestion: false) }
    func testVoiceQuestionReleaseStopsItsOwnRecordingExactlyOnce() { checkAcceptedStart(voiceQuestion: true) }

    private func checkAcceptedStart(voiceQuestion: Bool) {
        let microphone = FakeMicrophone()
        let (flow, arbiter) = practice(microphone)
        defer { flow.end(); withExtendedLifetime(arbiter) {} }
        voiceQuestion ? flow.startVoiceQuestion() : flow.startPTT()
        XCTAssertEqual(flow.phase, .listening)
        voiceQuestion ? flow.stopVoiceQuestion() : flow.stopPTT()
        voiceQuestion ? flow.stopVoiceQuestion() : flow.stopPTT()
        XCTAssertEqual(flow.phase, .noSpeech)
        XCTAssertFalse(microphone.isRecording)
        XCTAssertEqual(microphone.stops, 1)
    }

    func testPTTReleaseLeavesANewRecordingAfterATapStoppedItsOwn() { checkReplacedRecording(voiceQuestion: false) }
    func testVoiceQuestionReleaseLeavesANewRecordingAfterATapStoppedItsOwn() { checkReplacedRecording(voiceQuestion: true) }

    private func checkReplacedRecording(voiceQuestion: Bool) {
        let microphone = FakeMicrophone()
        let (flow, arbiter) = practice(microphone)
        defer { flow.end(); withExtendedLifetime(arbiter) {} }
        voiceQuestion ? flow.startVoiceQuestion() : flow.startPTT()
        flow.toggle()
        XCTAssertEqual(flow.phase, .noSpeech)
        flow.toggle()
        XCTAssertEqual(flow.phase, .listening)
        voiceQuestion ? flow.stopVoiceQuestion() : flow.stopPTT()
        XCTAssertEqual(flow.phase, .listening)
        XCTAssertTrue(microphone.isRecording)
        XCTAssertEqual(microphone.stops, 1)
    }
}
