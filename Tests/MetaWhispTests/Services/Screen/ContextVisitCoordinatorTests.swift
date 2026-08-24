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
        XCTAssertTrue(c.isCurrent(visit, at: t0))
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
        XCTAssertFalse(c.isCurrent(a, at: t0), "the Slack visit is over")
        XCTAssertTrue(c.isCurrent(b, at: t0))
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
        XCTAssertFalse(c.isCurrent(first, at: t0), "the older generation is no longer current")
        XCTAssertTrue(c.isCurrent(next, at: t0))
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

        XCTAssertFalse(c.isCurrent(a, at: t0))
        XCTAssertFalse(c.isCurrent(b, at: t0))
        XCTAssertTrue(c.isCurrent(cc, at: t0))
    }

    /// Deleting screen history, turning the feature off, or the data owner
    /// changing must strand everything in flight.
    func testInvalidateStrandsWorkInFlight() {
        var c = ContextVisitCoordinator()
        guard case .opened(let visit) = c.observe(slack(), at: t0) else { return XCTFail() }
        XCTAssertTrue(c.isCurrent(visit, at: t0))
        c.invalidateAll()
        XCTAssertFalse(c.isCurrent(visit, at: t0), "work started before the purge must not be able to finish")
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

    // MARK: Codex review

    /// A visit the user left behind must stop being current on its own. The
    /// window was closed, capture permission was revoked, the Mac slept —
    /// nothing calls back to say so, and a visit that stays current forever
    /// means late work is accepted forever.
    func testAVisitGoesStaleOnItsOwnWithoutBeingToldTo() {
        var c = ContextVisitCoordinator()
        guard case .opened(let visit) = c.observe(slack(), at: t0) else { return XCTFail() }
        XCTAssertTrue(c.isCurrent(visit, at: t0.addingTimeInterval(10)))
        XCTAssertFalse(
            c.isCurrent(visit, at: t0.addingTimeInterval(ContextVisitCoordinator.maxGapSeconds + 1)),
            "nothing reported this window closing, so freshness has to expire by itself")
    }

    /// Dragging a window to the other monitor changes which screen the agent
    /// should be reading. The display was recorded but never compared, so this
    /// returned .unchanged and work bound to the old screen stayed current.
    func testMovingAWindowToAnotherDisplayIsAChange() {
        var c = ContextVisitCoordinator()
        var onFirst = slack(); onFirst.displayID = 1
        guard case .opened(let before) = c.observe(onFirst, at: t0) else { return XCTFail() }
        var onSecond = slack(); onSecond.displayID = 2
        let result = c.observe(onSecond, at: t0.addingTimeInterval(2))
        XCTAssertNotEqual(result, .unchanged, "a different screen is a different context")
        XCTAssertFalse(c.isCurrent(before, at: t0.addingTimeInterval(2)))
    }

    /// The window ID is authoritative when the system gives us one. A tab
    /// switch or a document rename changes the title of the same window, and
    /// that is the same visit continuing — not a brand new one.
    func testTitleChangeInAKnownWindowContinuesTheSameVisit() {
        var c = ContextVisitCoordinator()
        guard case .opened(let first) = c.observe(slack("#launch", hash: 1), at: t0) else {
            return XCTFail()
        }
        let renamed = ContextVisitCoordinator.Sighting(
            bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
            rawTitle: "#random", windowID: 11, displayID: 1, contentHash: 2)
        guard case .changed(let next) = c.observe(renamed, at: t0.addingTimeInterval(2)) else {
            return XCTFail("the same window with a new title is the same visit")
        }
        XCTAssertEqual(next.id, first.id)
        XCTAssertEqual(next.generation, first.generation + 1)
    }

    /// Without a window ID the normalized title is all there is to go on, so it
    /// still separates visits.
    func testWithoutAWindowIDTheTitleStillSeparatesVisits() {
        var c = ContextVisitCoordinator()
        var a = slack("#launch"); a.windowID = nil
        var b = slack("#random"); b.windowID = nil
        guard case .opened(let first) = c.observe(a, at: t0) else { return XCTFail() }
        guard case .opened(let second) = c.observe(b, at: t0.addingTimeInterval(1)) else {
            return XCTFail("with no window id, a different title is a different window")
        }
        XCTAssertNotEqual(first.id, second.id)
    }

    /// A timestamp that goes backwards must not corrupt the gap arithmetic —
    /// it would otherwise make a live window look abandoned on the next tick.
    func testATimestampGoingBackwardsIsIgnored() {
        var c = ContextVisitCoordinator()
        guard case .opened(let first) = c.observe(slack(hash: 1), at: t0) else { return XCTFail() }
        _ = c.observe(slack(hash: 1), at: t0.addingTimeInterval(-600))
        let result = c.observe(slack(hash: 2), at: t0.addingTimeInterval(1))
        guard case .changed(let next) = result else {
            return XCTFail("a backwards clock reading must not end the visit")
        }
        XCTAssertEqual(next.id, first.id)
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
