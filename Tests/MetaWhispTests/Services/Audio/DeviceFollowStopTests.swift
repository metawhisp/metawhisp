import XCTest
@testable import MetaWhisp

/// Step-1 review #4 — a device change mid-recording drops `isRecording` and
/// schedules a follow that resumes on the new input once it settles. An
/// explicit stop or cancel in between must win: the follow used to resume
/// anyway, and the practice's microphone captured again beside a dictation
/// or a meeting. No real input device is bound here.
@MainActor
final class DeviceFollowStopTests: XCTestCase {

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(MicDeviceFollow.settleDelaySeconds + 0.3))
    }

    func testAStopWhileTheDeviceSettlesCancelsTheFollow() {
        let microphone = AudioRecordingService()
        var resumes = 0
        microphone.followResume = { _ in resumes += 1 }
        microphone.follow(afterChangeWhileRecording: true)   // a device change mid-recording
        _ = microphone.stop()                                 // the owner stops or cancels meanwhile
        settle()
        XCTAssertEqual(resumes, 0, "a stopped recording stays stopped")
    }

    /// The practice is cancelled while its microphone, mid device change,
    /// reports not recording.
    func testCancellingThePracticeStopsAMicrophoneThatADeviceChangeInterrupted() {
        let microphone = FakeMicrophone()
        let practice = PracticeRecorder(microphone: microphone, engine: { HeldEngine(answersAtOnce: true) },
                                        arbiter: CaptureArbiter(busyElsewhere: { false }), language: { nil })
        practice.begin()
        practice.toggle()
        microphone.isRecording = false             // the device change
        practice.cancel()
        XCTAssertEqual(microphone.stops, 1, "torn down, so its pending follow is dropped")
    }

    /// The release: a follow nobody stopped resumes, and a later recording's
    /// follow is not blocked by an earlier stop.
    func testAFollowNobodyStoppedResumes() {
        let microphone = AudioRecordingService()
        var resumes = 0
        microphone.followResume = { _ in resumes += 1 }
        microphone.follow(afterChangeWhileRecording: true)
        _ = microphone.stop()
        microphone.follow(afterChangeWhileRecording: true)   // the next recording's device change
        settle()
        XCTAssertEqual(resumes, 1)
        XCTAssertFalse(microphone.followInFlight)
    }

    /// Ending the practice screen mid device change tears the capture down
    /// too, and the dictation that follows records.
    func testEndingThePracticeMidDeviceChangeLeavesDictationFree() {
        let practiceMicrophone = FakeMicrophone()
        let capture = CaptureArbiter(busyElsewhere: { false })
        let practice = PracticeRecorder(microphone: practiceMicrophone, engine: { HeldEngine(answersAtOnce: true) },
                                        arbiter: capture, language: { nil })
        practice.begin()
        practice.toggle()
        practiceMicrophone.isRecording = false     // the device change
        practice.end()
        XCTAssertEqual(practiceMicrophone.stops, 1)
        XCTAssertNil(capture.refusal)
        let dictationMicrophone = FakeMicrophone()
        let dictation = TranscriptionCoordinator(recorder: dictationMicrophone, whisperEngine: nil,
                                                 textInserter: TextInsertionService(), soundService: SoundService(enabled: { false }),
                                                 settings: AppSettings.shared, voiceQuestions: VoiceQuestionState(),
                                                 cloudEngine: HeldEngine(answersAtOnce: true), openMicrophoneSettings: {})
        dictation.captureArbiter = capture
        dictation.toggle()
        XCTAssertEqual(dictation.stage, .recording)
        XCTAssertTrue(dictationMicrophone.isRecording)
    }
}
