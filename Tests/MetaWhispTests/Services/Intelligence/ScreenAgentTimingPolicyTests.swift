import XCTest
@testable import MetaWhisp

/// The timing numbers live in one type so a change to one is made in sight of
/// the others. The meeting path is the cautionary tale: a chunk size and a
/// request timeout sat in different files contradicting each other for months,
/// and the way anyone found out was a user's transcript coming back with holes.
final class ScreenAgentTimingPolicyTests: XCTestCase {

    /// A settle window long enough to skip the windows a user tabs through,
    /// short enough not to be felt.
    func testSettleIsWithinAHumanPause() {
        XCTAssertGreaterThan(ScreenAgentTimingPolicy.settleSeconds, 0.2)
        XCTAssertLessThan(ScreenAgentTimingPolicy.settleSeconds, 2.0)
    }

    /// Re-checking a stable window has to be quicker than the deadline, or new
    /// content is noticed only after it is too late to say anything about it.
    func testProbeIsFasterThanTheDeadline() {
        XCTAssertLessThan(ScreenAgentTimingPolicy.sameWindowProbeSeconds,
                          ScreenAgentTimingPolicy.endToEndDeadline)
    }

    /// The deadline is the promise that nothing arrives after the user has
    /// moved on. Anything approaching a minute is not that promise.
    func testDeadlineStaysWithinAttentionSpan() {
        XCTAssertGreaterThan(ScreenAgentTimingPolicy.endToEndDeadline,
                             ScreenAgentTimingPolicy.settleSeconds)
        XCTAssertLessThanOrEqual(ScreenAgentTimingPolicy.endToEndDeadline, 15)
    }
}
