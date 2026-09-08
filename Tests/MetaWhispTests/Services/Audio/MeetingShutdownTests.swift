import XCTest
@testable import MetaWhisp

/// Quitting during a meeting used to throw the meeting away.
///
/// `applicationWillTerminate` stopped the layout controller, logged
/// "Terminating", and returned. The mic and system buffers live in RAM until
/// `stop()` hands them to transcription, so ⌘Q — or Sparkle's own
/// Install-and-Relaunch — dropped an hour of audio with no file, no card and
/// no line in the log (audit, 2026-09-06, P1).
///
/// Dictation already had the answer: when transcription fails, the samples go
/// to `~/Library/Application Support/MetaWhisp/Recovery/` as a WAV the user
/// can re-submit. A meeting owes the same, for both channels.
final class MeetingShutdownTests: XCTestCase {

    // MARK: - What a shutdown owes a live meeting

    func testALiveMeetingIsRescued() {
        XCTAssertEqual(
            MeetingShutdown.plan(isRecording: true, isStarting: false, micSamples: 160_000, systemSamples: 160_000),
            .rescue(micSamples: 160_000, systemSamples: 160_000))
    }

    /// A meeting still starting has a system channel and no mic yet — it is
    /// still a meeting, and what it has is still worth keeping.
    func testAMeetingThatIsStillStartingIsRescued() {
        XCTAssertEqual(
            MeetingShutdown.plan(isRecording: false, isStarting: true, micSamples: 0, systemSamples: 48_000),
            .rescue(micSamples: 0, systemSamples: 48_000))
    }

    func testNoMeetingMeansNothingToDo() {
        XCTAssertEqual(
            MeetingShutdown.plan(isRecording: false, isStarting: false, micSamples: 0, systemSamples: 0),
            .nothingToDo)
    }

    /// A meeting that captured nothing at all has nothing to write; quitting
    /// must not hold the app open to save two empty files.
    func testAnEmptyMeetingIsNotWorthHoldingTheQuitFor() {
        XCTAssertEqual(
            MeetingShutdown.plan(isRecording: true, isStarting: false, micSamples: 0, systemSamples: 0),
            .nothingToDo)
    }

    /// Under a second of audio is a false start, not a meeting.
    func testAMeetingShorterThanASecondIsNotRescued() {
        XCTAssertEqual(
            MeetingShutdown.plan(isRecording: true, isStarting: false, micSamples: 8_000, systemSamples: 8_000),
            .nothingToDo)
        XCTAssertEqual(
            MeetingShutdown.plan(isRecording: true, isStarting: false, micSamples: 16_000, systemSamples: 0),
            .rescue(micSamples: 16_000, systemSamples: 0))
    }

    // MARK: - The two channels are told apart

    func testTheTwoChannelsGetNamesAPersonCanRead() {
        let names = MeetingShutdown.fileNames(stamp: "2026-09-08-14-31-02")
        XCTAssertEqual(names.mic, "meeting-2026-09-08-14-31-02-me.wav")
        XCTAssertEqual(names.system, "meeting-2026-09-08-14-31-02-them.wav")
        XCTAssertNotEqual(names.mic, names.system, "one file must never overwrite the other")
    }

    // MARK: - How long the quit may be held

    /// The rescue runs while macOS waits for the app to finish quitting. That
    /// wait has to end: a buffer that cannot be written must not turn ⌘Q into
    /// a hang.
    func testTheQuitIsHeldForABoundedTime() {
        XCTAssertLessThanOrEqual(MeetingShutdown.rescueDeadlineSeconds, 10,
                                 "a quit the user cannot complete is its own bug")
        XCTAssertGreaterThanOrEqual(MeetingShutdown.rescueDeadlineSeconds, 2,
                                    "…but long enough to write an hour of audio")
    }
}
