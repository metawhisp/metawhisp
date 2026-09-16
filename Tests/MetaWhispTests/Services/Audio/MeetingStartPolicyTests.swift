import XCTest
@testable import MetaWhisp

/// A meeting is abandoned only when there is nothing left to record.
///
/// `start()` treated the two channels differently: a microphone that failed to
/// come up was survivable — the meeting ran on system audio, the banner said
/// so, and recovery kept trying to bring the mic in — but a system channel
/// that failed aborted the whole meeting, microphone included. Three calendar
/// auto-starts died that way (owner's log, 2026-09-15 08:30, 2026-09-16 08:30
/// and 12:00): system audio did not come up inside the 5-second budget, and
/// the meeting was thrown away rather than recorded from the microphone alone.
///
/// The banner the owner saw — `System audio failed: … CancellationError` — was
/// our own abort reported as a system failure. The defect is not the wording:
/// it is that one dead channel took the other down with it.
final class MeetingStartPolicyTests: XCTestCase {

    // MARK: - What a start does with what it has

    func testBothChannelsUpRecordsBoth() {
        XCTAssertEqual(MeetingStartPolicy.start(micAvailable: true, systemAvailable: true),
                       .record(mic: true, system: true))
    }

    /// The bug, stated as a test: the microphone was available every one of
    /// those three mornings.
    func testADeadSystemChannelStillRecordsTheMic() {
        XCTAssertEqual(MeetingStartPolicy.start(micAvailable: true, systemAvailable: false),
                       .record(mic: true, system: false),
                       "a meeting with one working channel is a meeting, not a failure")
    }

    /// The direction that already worked keeps working.
    func testADeadMicStillRecordsTheSystemChannel() {
        XCTAssertEqual(MeetingStartPolicy.start(micAvailable: false, systemAvailable: true),
                       .record(mic: false, system: true))
    }

    func testOnlyBothChannelsDownAbandonsTheMeeting() {
        XCTAssertEqual(MeetingStartPolicy.start(micAvailable: false, systemAvailable: false),
                       .abandon)
    }

    // MARK: - The missing channel is chased, and the chase ends

    /// A meeting that started without the other side keeps asking for it —
    /// the same courtesy `armMicRecovery` extends to a dead microphone.
    func testTheSystemChannelIsChasedWhileTheMeetingRuns() {
        XCTAssertTrue(MeetingStartPolicy.shouldChaseSystem(isRecording: true, systemUp: false, attempts: 0))
        XCTAssertTrue(MeetingStartPolicy.shouldChaseSystem(isRecording: true, systemUp: false,
                                                           attempts: MeetingStartPolicy.maxSystemJoinAttempts - 1))
    }

    /// Every gate needs a release. A channel that will not come up must stop
    /// being asked, or the chase outlives the meeting.
    func testTheChaseStopsAtTheCeiling() {
        XCTAssertFalse(MeetingStartPolicy.shouldChaseSystem(isRecording: true, systemUp: false,
                                                            attempts: MeetingStartPolicy.maxSystemJoinAttempts),
                       "an endless chase is a leak, not a recovery")
    }

    func testAChannelThatCameBackIsNotChased() {
        XCTAssertFalse(MeetingStartPolicy.shouldChaseSystem(isRecording: true, systemUp: true, attempts: 0))
    }

    func testNothingIsChasedAfterTheMeetingEnds() {
        XCTAssertFalse(MeetingStartPolicy.shouldChaseSystem(isRecording: false, systemUp: false, attempts: 0))
    }
}

/// A channel that joins mid-meeting joins at the second it actually arrived.
/// The buffers are flat and mixing pairs index 0 with index 0, so a late
/// channel with no leading silence would put the other side's voice at the
/// start of the meeting — a recording that lies about when things were said.
final class SystemChannelPlacementTests: XCTestCase {

    func testAChannelJoiningLateIsPaddedForWhatItMissed() {
        XCTAssertEqual(SystemAudioCaptureService.leadingSilenceSamples(seconds: 30, rate: 16_000), 480_000)
        XCTAssertEqual(SystemAudioCaptureService.leadingSilenceSamples(seconds: 0.5, rate: 16_000), 8_000)
    }

    func testAChannelThatWasNeverLateIsNotPadded() {
        XCTAssertEqual(SystemAudioCaptureService.leadingSilenceSamples(seconds: 0, rate: 16_000), 0)
        XCTAssertEqual(SystemAudioCaptureService.leadingSilenceSamples(seconds: -3, rate: 16_000), 0,
                       "a clock that ran backwards is not a reason to invent audio")
    }
}
