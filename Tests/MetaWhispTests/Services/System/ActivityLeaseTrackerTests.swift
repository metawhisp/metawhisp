import XCTest
@testable import MetaWhisp

/// ITER-075 step 0, US-0.2 — the order in which the lease is written: an
/// install script must never read "idle" while a call is being recorded or
/// transcribed.
@MainActor
final class ActivityLeaseTrackerTests: XCTestCase {

    private final class Sink {
        var states: [ActivityLease.State] = []
        var failNext = false
    }

    private func tracker(_ sink: Sink) -> ActivityLeaseTracker {
        ActivityLeaseTracker(pid: 4242, executable: "/Applications/Test.app/Contents/MacOS/Test", write: { record in
            if sink.failNext {
                sink.failNext = false
                throw CocoaError(.fileWriteUnknown)
            }
            sink.states.append(record.state)
        })
    }

    /// A meeting stop goes from recording straight to transcribing: the
    /// counter is raised before the recorder stops.
    func testAMeetingStopNeverReadsIdleBetweenRecordingAndTranscribing() {
        let sink = Sink()
        let lease = tracker(sink)
        lease.recorderAndDictation(isRecording: true, isStarting: false, stage: .idle)
        lease.meetingTranscriptionStarted()
        lease.recorderAndDictation(isRecording: false, isStarting: false, stage: .idle)
        lease.meetingTranscriptionFinished()
        XCTAssertEqual(sink.states, [.recording, .transcribing, .idle])
    }

    func testTheMeetingCounterBalancesAndNeverGoesBelowZero() {
        let sink = Sink()
        let lease = tracker(sink)
        lease.meetingTranscriptionStarted()
        lease.meetingTranscriptionStarted()
        lease.meetingTranscriptionFinished()
        XCTAssertEqual(lease.written, .transcribing, "one meeting is still being transcribed")
        lease.meetingTranscriptionFinished()
        lease.meetingTranscriptionFinished()
        XCTAssertEqual(lease.meetingsInFlight, 0)
        XCTAssertEqual(sink.states, [.transcribing, .idle])
    }

    func testAFailedWriteIsTriedAgainOnTheNextChange() {
        let sink = Sink()
        let lease = tracker(sink)
        sink.failNext = true
        lease.recorderAndDictation(isRecording: true, isStarting: false, stage: .idle)
        XCTAssertNil(lease.written)
        lease.recorderAndDictation(isRecording: true, isStarting: false, stage: .recording)
        XCTAssertEqual(sink.states, [.recording])
        XCTAssertEqual(lease.written, .recording)
    }

    /// C6 — the practice is part of the one lease: busy while it records and
    /// transcribes, idle again when it ends.
    func testThePracticeKeepsTheLeaseBusyUntilItEnds() {
        let sink = Sink()
        let lease = tracker(sink)
        lease.practice(isBusy: true)
        XCTAssertEqual(lease.current, .practice)
        lease.practice(isBusy: false)
        XCTAssertEqual(sink.states, [.practice, .idle])
    }

    /// The capture arbiter hears every change, written or not, and reads the
    /// values the change carried — never the properties a publisher has not
    /// changed yet.
    func testEveryChangeIsReportedWithTheNewState() {
        let sink = Sink()
        let lease = tracker(sink)
        var seen: [ActivityLease.State] = []
        lease.onChange = { seen.append(lease.current) }
        lease.recorderAndDictation(isRecording: false, isStarting: false, stage: .recording)
        lease.recorderAndDictation(isRecording: false, isStarting: false, stage: .recording)
        lease.recorderAndDictation(isRecording: false, isStarting: false, stage: .idle)
        XCTAssertEqual(seen, [.recording, .recording, .idle])
        XCTAssertEqual(sink.states, [.recording, .idle], "writes only on a change of state, as before")
    }

    /// A second instance quits at launch before it ever wrote the lease; its
    /// quit must not overwrite the running instance's "recording" with idle.
    func testOnlyTheProcessThatOwnsTheLeaseWritesIdleAtQuit() {
        let stranger = Sink()
        tracker(stranger).quitting()
        XCTAssertEqual(stranger.states, [])
        let owner = Sink()
        let lease = tracker(owner)
        lease.recorderAndDictation(isRecording: true, isStarting: false, stage: .idle)
        lease.quitting()
        XCTAssertEqual(owner.states, [.recording, .idle])
    }
}
