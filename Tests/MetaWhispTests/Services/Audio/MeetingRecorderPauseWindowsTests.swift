import XCTest
@testable import MetaWhisp

/// The dictation pause windows, read-only, on the mic's sample timeline.
///
/// The live hints drop the mic utterances that fall inside a pause — the
/// user's dictated words are not part of the meeting. The recording itself
/// must not change: the snapshot reads the windows, it never takes them.
@MainActor
final class MeetingRecorderPauseWindowsTests: XCTestCase {

    /// The pause in progress is in the snapshot, on the mic's own timeline.
    func testTheOpenPauseIsInTheSnapshot() async throws {
        let recorder = makeRecorder()
        recorder.micClockStart = SuspendingClock.now.advanced(by: .seconds(-1))
        recorder.isRecording = true
        recorder.pauseMic()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let windows = recorder.pauseWindowsSnapshot()

        XCTAssertEqual(windows.count, 1, "the pause in progress is not in the snapshot")
        XCTAssertGreaterThan(windows[0].from, 15_000,
                             "the pause did not land a second into the mic's timeline")
        XCTAssertLessThan(windows[0].from, 16_100, "the pause landed later than it did")
        XCTAssertGreaterThan(windows[0].to, windows[0].from, "the open pause has no length")
        XCTAssertLessThan(windows[0].to - windows[0].from, 16_000,
                          "the open pause is longer than the pause was")
    }

    /// The closed pause is in the snapshot, and reading it changed nothing.
    func testTheClosedPauseIsInTheSnapshotAndTheReadingChangedNothing() async throws {
        let recorder = makeRecorder()
        recorder.micClockStart = SuspendingClock.now.advanced(by: .seconds(-1))
        recorder.isRecording = true
        recorder.pauseMic()
        try? await Task.sleep(nanoseconds: 50_000_000)
        recorder.resumeMic()

        let closed = recorder.pauseWindowsSnapshot()

        XCTAssertEqual(closed.count, 1, "the closed pause is not in the snapshot")
        XCTAssertGreaterThan(closed[0].from, 15_000)
        XCTAssertGreaterThan(closed[0].to, closed[0].from, "the closed pause has no length")
        XCTAssertEqual(recorder.pauseWindowsSnapshot(), closed,
                       "the snapshot took the window instead of reading it")
    }

    /// A meeting that never paused has no windows.
    func testAMeetingWithoutAPauseHasNoWindows() {
        let recorder = makeRecorder()
        XCTAssertTrue(recorder.pauseWindowsSnapshot().isEmpty)
    }

    private func makeRecorder() -> MeetingRecorder {
        MeetingRecorder(mic: AudioRecordingService(), systemAudio: SystemAudioCaptureService())
    }
}
