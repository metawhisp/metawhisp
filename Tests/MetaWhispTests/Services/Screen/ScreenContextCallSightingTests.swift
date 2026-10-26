import XCTest
@testable import MetaWhisp

/// 2026-10-20 — the calendar-end check now reads when the call detector last
/// saw a call. Both detector passes (the poll and the instant app-switch
/// check) report what they saw here. The time has to move on every pass that
/// sees a call, not only on a change: the detector logs changes, and a Meet
/// held in front for seven minutes (17:52:22 to 17:59:22 in the owner's log)
/// is a single change.
@MainActor
final class ScreenContextCallSightingTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_760_970_000)

    /// A call that stays in front keeps being seen: the second pass with the
    /// same call is no change, yet it is a sighting.
    func testACallStillInFrontIsSeenAtEveryPassNotOnlyOnAChange() {
        let screen = ScreenContextService()
        XCTAssertTrue(screen.noteCallDetection("Google Meet", at: t0), "the first sighting is a change")
        XCTAssertFalse(screen.noteCallDetection("Google Meet", at: t0.addingTimeInterval(240)),
                       "the same call again is not a change")
        XCTAssertEqual(screen.lastCallSeenAt, t0.addingTimeInterval(240))
    }

    /// Leaving the call is a change, and the last sighting stays: that moment
    /// is what the calendar check's five-minute window counts from.
    func testLeavingTheCallKeepsTheLastSighting() {
        let screen = ScreenContextService()
        _ = screen.noteCallDetection("Google Meet", at: t0)
        XCTAssertTrue(screen.noteCallDetection(nil, at: t0.addingTimeInterval(30)), "leaving is a change")
        XCTAssertFalse(screen.noteCallDetection(nil, at: t0.addingTimeInterval(60)))
        XCTAssertEqual(screen.lastCallSeenAt, t0)
    }

    /// No call ever seen: nothing to count from.
    func testNoCallIsNeverSeen() {
        let screen = ScreenContextService()
        XCTAssertFalse(screen.noteCallDetection(nil, at: t0), "nil after nil is no change")
        XCTAssertNil(screen.lastCallSeenAt)
    }
}
