import XCTest
@testable import MetaWhisp

/// ITER-060.5 — an empty meeting transcript must name its REAL cause.
///
/// 2026-08-10 bug report: the founder recorded, spoke, and got «🎤 No speech
/// detected in recording» — while the mic had in fact never captured anything
/// (AEC regression). `MeetingRecorder` swallows a mic-start failure into
/// `micOnlyMode` with only an NSLog, so the finalize path blamed the user's
/// silence for the app's own failure. These cases pin the honest mapping.
final class MeetingEmptyReasonTests: XCTestCase {

    private typealias R = MeetingRecorder.EmptyTranscriptReason

    func test_failedChunksWin_overEverything() {
        // Transcription errors are the most specific signal — report them even
        // if the mic was also missing.
        XCTAssertEqual(
            MeetingRecorder.emptyTranscriptReason(failedChunks: 3, micSamples: 0, systemSamples: 0),
            R.chunksFailed(3)
        )
        XCTAssertEqual(
            MeetingRecorder.emptyTranscriptReason(failedChunks: 1, micSamples: 999_999, systemSamples: 0),
            R.chunksFailed(1)
        )
    }

    func test_micCapturedNothing_isNotUserSilence() {
        // The screenshot case: user spoke, mic recorded zero samples.
        XCTAssertEqual(
            MeetingRecorder.emptyTranscriptReason(failedChunks: 0, micSamples: 0, systemSamples: 0),
            R.micNeverCaptured
        )
        // System audio present, mic dead → still a mic failure, not silence.
        XCTAssertEqual(
            MeetingRecorder.emptyTranscriptReason(failedChunks: 0, micSamples: 0, systemSamples: 480_000),
            R.micNeverCaptured
        )
    }

    func test_micBarelyCaptured_countsAsNeverCaptured() {
        // Under half a second of mic audio is a broken capture, not a meeting.
        XCTAssertEqual(
            MeetingRecorder.emptyTranscriptReason(failedChunks: 0, micSamples: 4000, systemSamples: 0),
            R.micNeverCaptured
        )
    }

    func test_realSilence_reportedAsSilence() {
        // Mic genuinely recorded a quiet room — that IS «no speech».
        XCTAssertEqual(
            MeetingRecorder.emptyTranscriptReason(failedChunks: 0, micSamples: 16000 * 30, systemSamples: 0),
            R.genuinelySilent
        )
    }

    func test_messages_areDistinctAndActionable() {
        let mic = R.micNeverCaptured.userMessage
        let silent = R.genuinelySilent.userMessage
        let failed = R.chunksFailed(2).userMessage
        XCTAssertNotEqual(mic, silent)
        XCTAssertTrue(failed.contains("2"))
        // The mic message must point at the mic, not blame the user's speech.
        XCTAssertTrue(mic.lowercased().contains("microphone"))
        XCTAssertFalse(mic.lowercased().contains("no speech"))
    }

    /// The menu bar opens the Privacy pane for a message carrying 🎤 and for
    /// no other (`MenuBarView.errorSettingsPane`). "Check your permission" is
    /// the right advice for a mic that captured nothing; it is the wrong
    /// advice for a device that ran and delivered silence — that one needs
    /// the dead-device remedy, not a Settings pane (independent review, v22).
    func test_onlyTheCaptureNothingMessageRoutesToPrivacy() {
        XCTAssertTrue(R.micNeverCaptured.userMessage.contains("🎤"))
        for reason in [R.micDeliveredSilence, R.genuinelySilent, R.chunksFailed(2)] {
            XCTAssertFalse(reason.userMessage.contains("🎤"), "\(reason) must not open the Privacy pane")
        }
    }
}
