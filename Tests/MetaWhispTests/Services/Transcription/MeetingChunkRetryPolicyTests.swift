import XCTest
@testable import MetaWhisp

/// The meeting finalize pass retries a chunk twice before giving up on it.
/// That retry re-sends the identical audio — and `CloudWhisperEngine` documents
/// exactly why that is dangerous for the two errors it happens to hit most:
/// a timed-out or connection-lost POST may already have been accepted,
/// transcribed and metered by the server, and these requests carry no
/// idempotency key. The engine's own retry ladder excludes both for that
/// reason; the meeting layer above it retried everything.
///
/// Dropping the retry is not an option — that is how chunks were lost in the
/// first place. So the retry stays and the meter moves: only the first attempt
/// is billable, which makes a re-send safe no matter what the server did with
/// the attempt that vanished.
final class MeetingChunkRetryPolicyTests: XCTestCase {

    func testFirstAttemptIsBillable() {
        XCTAssertTrue(MeetingChunkRetryPolicy.shouldMeter(attempt: 1, callerWantsMetering: true))
    }

    func testRetriesAreNeverBillable() {
        XCTAssertFalse(MeetingChunkRetryPolicy.shouldMeter(attempt: 2, callerWantsMetering: true))
        XCTAssertFalse(MeetingChunkRetryPolicy.shouldMeter(attempt: 3, callerWantsMetering: true))
    }

    /// ITER-054 bills a dual-stream meeting once, by metering a single channel.
    /// The non-metered channel must stay non-metered on attempt 1 too.
    func testTheNonMeteredChannelStaysFree() {
        XCTAssertFalse(MeetingChunkRetryPolicy.shouldMeter(attempt: 1, callerWantsMetering: false))
        XCTAssertFalse(MeetingChunkRetryPolicy.shouldMeter(attempt: 2, callerWantsMetering: false))
    }
}
