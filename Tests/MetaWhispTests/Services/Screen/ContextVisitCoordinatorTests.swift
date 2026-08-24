import XCTest
@testable import MetaWhisp

/// A visit is "the stretch of time the user spent looking at this one window".
/// Nothing in the app had that concept: work was keyed on a raw app/title pair
/// with no identity and no version, so no piece of code could answer "is the
/// screen this result came from still the screen the user is looking at?"
///
/// That question is the whole point. A comment about a window the user left is
/// worse than no comment, and the only way to refuse one is to be able to tell.
@MainActor
final class ContextVisitCoordinatorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func slack(_ title: String = "#launch", hash: Int = 1) -> ContextVisitCoordinator.Sighting {
        .init(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
              rawTitle: title, windowID: 11, displayID: 1, contentHash: hash)
    }
    private func figma(hash: Int = 9) -> ContextVisitCoordinator.Sighting {
        .init(bundleID: "com.figma.Desktop", appName: "Figma",
              rawTitle: "Board", windowID: 22, displayID: 1, contentHash: hash)
    }

    // MARK: identity

    func testFirstSightingOpensAVisit() {
        var c = ContextVisitCoordinator()
        guard case .opened(let visit) = c.observe(slack(), at: t0) else {
            return XCTFail("first sighting must open a visit")
        }
        XCTAssertEqual(visit.generation, 0)
        XCTAssertTrue(c.isCurrent(visit))
    }

    func testSameWindowSameContentDoesNotReopen() {
        var c = ContextVisitCoordinator()
        _ = c.observe(slack(), at: t0)
        XCTAssertEqual(c.observe(slack(), at: t0.addingTimeInterval(30)), .unchanged)
    }

    /// Toggl-style titles mutate many times a second. A spinner or a timer
    /// ticking is not the user going somewhere.
    func testCosmeticTitleNoiseIsNotANewVisit() {
        var c = ContextVisitCoordinator()
        _ = c.observe(slack("Toggl ⠋ work 00:05:23"), at: t0)
        XCTAssertEqual(
            c.observe(slack("Toggl ⠹ work 00:05:24"), at: t0.addingTimeInterval(1)),
            .unchanged,
            "a spinner frame and a ticking clock are the same window")
    }

    func testSwitchingAppOpensANewVisit() {
        var c = ContextVisitCoordinator()
        guard case .opened(let a) = c.observe(slack(), at: t0) else { return XCTFail() }
        guard case .opened(let b) = c.observe(figma(), at: t0.addingTimeInterval(5)) else {
            return XCTFail("a different app is a different visit")
        }
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertFalse(c.isCurrent(a), "the Slack visit is over")
        XCTAssertTrue(c.isCurrent(b))
    }

    /// Two windows of one app are two visits — otherwise a claim about one
    /// browser tab can be attributed to another.
    func testSecondWindowOfSameAppIsANewVisit() {
        var c = ContextVisitCoordinator()
        guard case .opened(let a) = c.observe(slack("#launch"), at: t0) else { return XCTFail() }
        var other = slack("#random"); other.windowID = 12
        guard case .opened(let b) = c.observe(other, at: t0.addingTimeInterval(2)) else {
            return XCTFail("a different window is a different visit")
        }
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: content changes inside one window

    /// The defect this exists for: a new message arrives in the open Slack
    /// channel and the window title does not move, so today nothing is captured
    /// at all. Same window, new content — same visit, next generation.
    func testNewContentInAStableTitleAdvancesTheGeneration() {
        var c = ContextVisitCoordinator()
        guard case .opened(let first) = c.observe(slack(hash: 1), at: t0) else { return XCTFail() }
        guard case .changed(let next) = c.observe(slack(hash: 2), at: t0.addingTimeInterval(3)) else {
            return XCTFail("new content in the same window must be noticed")
        }
        XCTAssertEqual(next.id, first.id, "still the same window")
        XCTAssertEqual(next.generation, first.generation + 1)
        XCTAssertFalse(c.isCurrent(first), "the older generation is no longer current")
        XCTAssertTrue(c.isCurrent(next))
    }

    // MARK: freshness — the reason all of this exists

    /// A -> B -> C while A is still being analyzed. Neither A nor B may pass a
    /// freshness check once C is current.
    func testRapidSwitchingInvalidatesEveryEarlierVisit() {
        var c = ContextVisitCoordinator()
        guard case .opened(let a) = c.observe(slack(), at: t0) else { return XCTFail() }
        guard case .opened(let b) = c.observe(figma(), at: t0.addingTimeInterval(1)) else { return XCTFail() }
        var third = slack("#random"); third.windowID = 33
        guard case .opened(let cc) = c.observe(third, at: t0.addingTimeInterval(2)) else { return XCTFail() }

        XCTAssertFalse(c.isCurrent(a))
        XCTAssertFalse(c.isCurrent(b))
        XCTAssertTrue(c.isCurrent(cc))
    }

    /// Deleting screen history, turning the feature off, or the data owner
    /// changing must strand everything in flight.
    func testInvalidateStrandsWorkInFlight() {
        var c = ContextVisitCoordinator()
        guard case .opened(let visit) = c.observe(slack(), at: t0) else { return XCTFail() }
        XCTAssertTrue(c.isCurrent(visit))
        c.invalidateAll()
        XCTAssertFalse(c.isCurrent(visit), "work started before the purge must not be able to finish")
    }

    /// After invalidation the very next sighting opens a fresh visit rather
    /// than silently resuming the stranded one.
    func testInvalidateIsFollowedByAFreshVisit() {
        var c = ContextVisitCoordinator()
        guard case .opened(let before) = c.observe(slack(), at: t0) else { return XCTFail() }
        c.invalidateAll()
        guard case .opened(let after) = c.observe(slack(), at: t0.addingTimeInterval(1)) else {
            return XCTFail("a sighting after invalidation must open a new visit")
        }
        XCTAssertNotEqual(before.id, after.id)
    }

    /// Returning to a window after a long gap is a new visit, not a resumption
    /// of the morning's.
    func testReturningAfterALongGapOpensANewVisit() {
        var c = ContextVisitCoordinator()
        guard case .opened(let a) = c.observe(slack(), at: t0) else { return XCTFail() }
        let later = t0.addingTimeInterval(ContextVisitCoordinator.maxGapSeconds + 1)
        guard case .opened(let b) = c.observe(slack(), at: later) else {
            return XCTFail("a long absence ends the visit")
        }
        XCTAssertNotEqual(a.id, b.id)
    }
}
