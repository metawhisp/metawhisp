import XCTest
@testable import MetaWhisp

/// A visit is "the stretch of time the user spent looking at this one window".
/// Nothing in the app had that concept: work was keyed on a raw app/title pair
/// with no identity and no version, so no code could answer "is the screen this
/// result came from still the screen the user is looking at?"
///
/// That question is the whole point. A comment about a window the user left is
/// worse than no comment, and the only way to refuse one is to be able to tell.
@MainActor
final class ContextVisitCoordinatorTests: XCTestCase {

    private let t0 = ContinuousClock.now
    private let wall = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        t0.advanced(by: .milliseconds(Int(seconds * 1000)))
    }

    private func slack(_ title: String = "#launch", hash: Int = 1,
                       windowID: UInt32? = 11, displayID: UInt32? = 1)
    -> ContextVisitCoordinator.Sighting {
        .init(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
              rawTitle: title, windowID: windowID, displayID: displayID, contentHash: hash)
    }

    private func figma(hash: Int = 9) -> ContextVisitCoordinator.Sighting {
        .init(bundleID: "com.figma.Desktop", appName: "Figma",
              rawTitle: "Board", windowID: 22, displayID: 1, contentHash: hash)
    }

    /// propose + commit, for the cases that are not about the transaction.
    @discardableResult
    private func land(_ c: inout ContextVisitCoordinator,
                      _ s: ContextVisitCoordinator.Sighting,
                      at now: ContinuousClock.Instant) -> ContextVisitCoordinator.Proposal {
        let p = c.propose(s, at: now, wallClock: wall)
        c.commit(p, contentHash: s.contentHash, at: now)
        return p
    }

    private func visit(_ p: ContextVisitCoordinator.Proposal) -> ContextVisit? {
        switch p {
        case .opened(let v), .changed(let v): return v
        case .unchanged: return nil
        }
    }

    // MARK: identity

    func testFirstSightingOpensAVisit() {
        var c = ContextVisitCoordinator()
        guard case .opened(let v) = land(&c, slack(), at: at(0)) else {
            return XCTFail("first sighting must open a visit")
        }
        XCTAssertEqual(v.generation, 0)
        XCTAssertTrue(c.isCurrent(v, at: at(1)))
    }

    func testSameWindowSameContentIsUnchanged() {
        var c = ContextVisitCoordinator()
        land(&c, slack(), at: at(0))
        XCTAssertEqual(land(&c, slack(), at: at(30)), .unchanged)
    }

    /// Toggl-style titles mutate many times a second. A spinner frame and a
    /// ticking clock are not the user going somewhere.
    func testCosmeticTitleNoiseIsNotANewVisit() {
        var c = ContextVisitCoordinator()
        land(&c, slack("Toggl ⠋ work 00:05:23"), at: at(0))
        XCTAssertEqual(land(&c, slack("Toggl ⠹ work 00:05:24"), at: at(1)), .unchanged)
    }

    func testSwitchingAppOpensANewVisit() {
        var c = ContextVisitCoordinator()
        guard let a = visit(land(&c, slack(), at: at(0))) else { return XCTFail() }
        guard case .opened(let b) = land(&c, figma(), at: at(5)) else {
            return XCTFail("a different app is a different visit")
        }
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertFalse(c.isCurrent(a, at: at(5)), "the Slack visit is over")
        XCTAssertTrue(c.isCurrent(b, at: at(5)))
    }

    /// Two windows of one app are two visits — otherwise a claim about one
    /// browser tab can be attributed to another.
    func testSecondWindowOfSameAppIsANewVisit() {
        var c = ContextVisitCoordinator()
        guard let a = visit(land(&c, slack("#launch"), at: at(0))) else { return XCTFail() }
        guard case .opened(let b) = land(&c, slack("#random", windowID: 12), at: at(2)) else {
            return XCTFail("a different window is a different visit")
        }
        XCTAssertNotEqual(a.id, b.id)
    }

    /// The window ID is authoritative when the system gives one: a tab switch
    /// renames the same window and the visit continues.
    func testTitleChangeInAKnownWindowContinuesTheSameVisit() {
        var c = ContextVisitCoordinator()
        guard let first = visit(land(&c, slack("#launch", hash: 1), at: at(0))) else { return XCTFail() }
        guard case .changed(let next) = land(&c, slack("#random", hash: 2), at: at(2)) else {
            return XCTFail("the same window with a new title is the same visit")
        }
        XCTAssertEqual(next.id, first.id)
        XCTAssertEqual(next.generation, first.generation + 1)
    }

    func testWithoutAWindowIDTheTitleStillSeparatesVisits() {
        var c = ContextVisitCoordinator()
        guard let a = visit(land(&c, slack("#launch", windowID: nil), at: at(0))) else { return XCTFail() }
        guard case .opened(let b) = land(&c, slack("#random", windowID: nil), at: at(1)) else {
            return XCTFail("with no window id, a different title is a different window")
        }
        XCTAssertNotEqual(a.id, b.id)
    }

    /// Dragging a window to the other monitor changes which screen should be
    /// read. Display was recorded but never compared.
    func testMovingAWindowToAnotherDisplayIsAChange() {
        var c = ContextVisitCoordinator()
        guard let before = visit(land(&c, slack(displayID: 1), at: at(0))) else { return XCTFail() }
        XCTAssertNotEqual(land(&c, slack(displayID: 2), at: at(2)), .unchanged,
                          "a different screen is a different context")
        XCTAssertFalse(c.isCurrent(before, at: at(2)))
    }

    // MARK: content changes inside one window

    /// A new message arrives in an open channel and the title does not move, so
    /// today nothing is captured at all.
    func testNewContentInAStableTitleAdvancesTheGeneration() {
        var c = ContextVisitCoordinator()
        guard let first = visit(land(&c, slack(hash: 1), at: at(0))) else { return XCTFail() }
        guard case .changed(let next) = land(&c, slack(hash: 2), at: at(3)) else {
            return XCTFail("new content in the same window must be noticed")
        }
        XCTAssertEqual(next.id, first.id, "still the same window")
        XCTAssertEqual(next.generation, first.generation + 1)
        XCTAssertFalse(c.isCurrent(first, at: at(3)))
        XCTAssertTrue(c.isCurrent(next, at: at(3)))
    }

    // MARK: the transaction

    /// The bug this shape exists for: state used to advance the moment a
    /// sighting was observed. If the frame it described then failed to save,
    /// the generation and hash had already moved on, so the retry compared
    /// against state for a frame that was never stored and concluded nothing
    /// had changed — the window went quiet with nothing in history to show.
    func testAnUncommittedProposalLeavesNoTrace() {
        var c = ContextVisitCoordinator()
        land(&c, slack(hash: 1), at: at(0))

        // A frame is proposed and its save fails, so it is never committed.
        _ = c.propose(slack(hash: 2), at: at(3), wallClock: wall)

        // The retry must still see new content, not a phantom already-recorded one.
        guard case .changed = c.propose(slack(hash: 2), at: at(6), wallClock: wall) else {
            return XCTFail("an unsaved frame must not consume the change")
        }
    }

    func testProposeDoesNotMutateCurrent() {
        var c = ContextVisitCoordinator()
        guard let first = visit(land(&c, slack(hash: 1), at: at(0))) else { return XCTFail() }
        _ = c.propose(slack(hash: 2), at: at(3), wallClock: wall)
        XCTAssertEqual(c.current, first, "proposing must not install anything")
    }

    /// A window nobody is changing must not age out while the user reads it.
    func testCommittingUnchangedKeepsTheVisitAlive() {
        var c = ContextVisitCoordinator()
        guard let v = visit(land(&c, slack(hash: 1), at: at(0))) else { return XCTFail() }
        land(&c, slack(hash: 1), at: at(290))
        XCTAssertTrue(c.isCurrent(v, at: at(295)), "a quiet window is still the current one")
    }

    // MARK: freshness

    /// A -> B -> C while A is still being analyzed.
    func testRapidSwitchingInvalidatesEveryEarlierVisit() {
        var c = ContextVisitCoordinator()
        guard let a = visit(land(&c, slack(), at: at(0))) else { return XCTFail() }
        guard let b = visit(land(&c, figma(), at: at(1))) else { return XCTFail() }
        guard let cc = visit(land(&c, slack("#random", windowID: 33), at: at(2))) else { return XCTFail() }
        XCTAssertFalse(c.isCurrent(a, at: at(2)))
        XCTAssertFalse(c.isCurrent(b, at: at(2)))
        XCTAssertTrue(c.isCurrent(cc, at: at(2)))
    }

    /// Nothing calls back to say a window closed, that permission was revoked
    /// or that the Mac slept, so freshness has to expire by itself.
    func testAVisitGoesStaleOnItsOwnWithoutBeingToldTo() {
        var c = ContextVisitCoordinator()
        guard let v = visit(land(&c, slack(), at: at(0))) else { return XCTFail() }
        XCTAssertTrue(c.isCurrent(v, at: at(10)))
        XCTAssertFalse(c.isCurrent(v, at: at(301)))
    }

    /// A monotonic reading cannot go backwards, but a caller confusing two
    /// clocks could still hand one over. Refuse rather than extend freshness.
    func testATimeGoingBackwardsIsNotFresh() {
        var c = ContextVisitCoordinator()
        guard let v = visit(land(&c, slack(), at: at(10))) else { return XCTFail() }
        XCTAssertFalse(c.isCurrent(v, at: at(5)))
    }

    func testInvalidateStrandsWorkInFlight() {
        var c = ContextVisitCoordinator()
        guard let v = visit(land(&c, slack(), at: at(0))) else { return XCTFail() }
        XCTAssertTrue(c.isCurrent(v, at: at(0)))
        c.invalidateAll()
        XCTAssertFalse(c.isCurrent(v, at: at(0)),
                       "work started before the purge must not be able to finish")
    }

    func testInvalidateIsFollowedByAFreshVisit() {
        var c = ContextVisitCoordinator()
        guard let before = visit(land(&c, slack(), at: at(0))) else { return XCTFail() }
        c.invalidateAll()
        guard case .opened(let after) = land(&c, slack(), at: at(1)) else {
            return XCTFail("a sighting after invalidation must open a new visit")
        }
        XCTAssertNotEqual(before.id, after.id)
    }

    /// Returning to a window after a long gap is a new visit, not a resumption
    /// of the morning's.
    func testReturningAfterALongGapOpensANewVisit() {
        var c = ContextVisitCoordinator()
        guard let a = visit(land(&c, slack(), at: at(0))) else { return XCTFail() }
        guard case .opened(let b) = land(&c, slack(), at: at(301)) else {
            return XCTFail("a long absence ends the visit")
        }
        XCTAssertNotEqual(a.id, b.id)
    }
}
