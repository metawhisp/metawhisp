import XCTest
@testable import MetaWhisp

/// Capture fires when the window title moves. A new message arriving in an
/// already-open channel moves nothing — same app, same title, same frame — so
/// the agent has never seen one. `ScreenContentFingerprint` was written for
/// exactly this and has never been called from production.
///
/// This is the piece that was missing between them: how often to look, and what
/// counts as an answer.
final class SameWindowProbeTests: XCTestCase {

    private func fingerprint(_ value: UInt8) -> ScreenContentFingerprint {
        ScreenContentFingerprint(pixels: [UInt8](repeating: value, count: 64),
                                 width: 8, height: 8)
    }

    /// The first look establishes what the window looks like. Calling that a
    /// change would capture every window the moment it goes quiet — the exact
    /// storm this probe exists to avoid.
    func testTheFirstLookIsABaselineNotAChange() {
        var probe = SameWindowProbe()
        XCTAssertEqual(probe.look(at: fingerprint(10), now: Date()), .quiet)
    }

    func testAnUnchangedWindowStaysQuiet() {
        var probe = SameWindowProbe()
        let start = Date()
        _ = probe.look(at: fingerprint(10), now: start)
        probe.noteStored(at: start)
        XCTAssertEqual(probe.look(at: fingerprint(10), now: start.addingTimeInterval(30)), .quiet)
    }

    /// The whole point: something happened inside the window and nothing in the
    /// title said so.
    func testANewMessageInAnOpenChannelIsSeen() {
        var probe = SameWindowProbe()
        let start = Date()
        _ = probe.look(at: fingerprint(10), now: start)
        XCTAssertNotEqual(probe.look(at: fingerprint(200), now: start.addingTimeInterval(30)), .quiet)
    }

    /// A screenshot costs something, so the cadence is checked before one is
    /// taken rather than after.
    func testLookingIsRateLimited() {
        var probe = SameWindowProbe()
        let start = Date()
        XCTAssertTrue(probe.shouldLook(at: start), "the first tick has nothing to wait for")
        _ = probe.look(at: fingerprint(10), now: start)
        XCTAssertFalse(probe.shouldLook(at: start.addingTimeInterval(1)))
        XCTAssertTrue(probe.shouldLook(
            at: start.addingTimeInterval(ScreenAgentTimingPolicy.sameWindowProbeSeconds + 0.1)))
    }

    /// Comparing one window's picture against another's would report a change
    /// every single time. The baseline belongs to the window it was taken from.
    func testChangingWindowDropsTheBaseline() {
        var probe = SameWindowProbe()
        let start = Date()
        _ = probe.look(at: fingerprint(10), now: start)
        probe.reset()
        XCTAssertEqual(probe.look(at: fingerprint(200), now: start.addingTimeInterval(30)), .quiet,
                       "a fresh window starts with a baseline, not with a verdict")
    }
    // MARK: - The ceiling (Stage 2.1-bis)

    /// The defect the gate shipped with. "The picture is identical" stayed true
    /// for as long as a person read one document, and the answer to it was
    /// silence with no end — an hour of reading produced no rows at all. Sitting
    /// still in front of a document is what reading looks like, not what an
    /// empty desk looks like.
    func testAQuietWindowIsReadAnywayOnceTheCeilingPasses() {
        var probe = SameWindowProbe()
        let start = Date()
        _ = probe.look(at: fingerprint(10), now: start)
        probe.noteStored(at: start)
        let justUnder = start.addingTimeInterval(ScreenAgentTimingPolicy.forcedReadSeconds - 1)
        XCTAssertEqual(probe.look(at: fingerprint(10), now: justUnder), .quiet)
        let justOver = start.addingTimeInterval(ScreenAgentTimingPolicy.forcedReadSeconds + 1)
        XCTAssertEqual(probe.look(at: fingerprint(10), now: justOver), .forced,
                       "reading is activity, not absence")
    }

    /// A forced read restarts the clock. Without this every tick after the
    /// ceiling captures, which turns the ceiling into no gate at all.
    func testAForcedReadRestartsTheClockRatherThanOpeningTheFloodgate() {
        var probe = SameWindowProbe()
        let start = Date()
        _ = probe.look(at: fingerprint(10), now: start)
        probe.noteStored(at: start)
        let forced = start.addingTimeInterval(ScreenAgentTimingPolicy.forcedReadSeconds + 1)
        XCTAssertEqual(probe.look(at: fingerprint(10), now: forced), .forced)
        probe.noteStored(at: forced)
        XCTAssertEqual(probe.look(at: fingerprint(10), now: forced.addingTimeInterval(30)), .quiet,
                       "the next tick is quiet again")
    }

    /// A real change also restarts it: the window was just read, so the ceiling
    /// has nothing to make up for.
    func testARealChangeAlsoRestartsTheClock() {
        var probe = SameWindowProbe()
        let start = Date()
        _ = probe.look(at: fingerprint(10), now: start)
        probe.noteStored(at: start)
        let changed = start.addingTimeInterval(ScreenAgentTimingPolicy.forcedReadSeconds - 1)
        XCTAssertEqual(probe.look(at: fingerprint(200), now: changed), .moved)
        probe.noteStored(at: changed)
        XCTAssertEqual(probe.look(at: fingerprint(200), now: changed.addingTimeInterval(30)), .quiet)
    }

    /// Wake from sleep and NTP corrections put `now` behind the last look. A
    /// backwards clock must count as due rather than wedge capture shut until
    /// real time catches up.
    func testAClockThatJumpedBackwardsCountsAsDue() {
        var probe = SameWindowProbe()
        let start = Date()
        _ = probe.look(at: fingerprint(10), now: start)
        probe.noteStored(at: start)
        XCTAssertEqual(probe.look(at: fingerprint(10), now: start.addingTimeInterval(-90)), .forced)
    }

    /// Two gates in series multiply: if the cadence check ever outgrew the
    /// ceiling, the ceiling could never be reached and the starvation would be
    /// back with both rules looking correct on their own.
    func testTheCadenceCheckCannotOutgrowTheCeiling() {
        XCTAssertLessThan(ScreenAgentTimingPolicy.sameWindowProbeSeconds,
                          ScreenAgentTimingPolicy.forcedReadSeconds)
    }

    /// The ceiling is derived from the visit gap, not picked round: forcing at
    /// half of it keeps an hour of reading inside one unbroken visit even when
    /// a tick is lost.
    func testTheCeilingStaysUnderTheVisitGap() {
        XCTAssertLessThan(ScreenAgentTimingPolicy.forcedReadSeconds,
                          Double(ContextVisitCoordinator.maxGapSeconds.components.seconds),
                          "a window read continuously must not fall out of its own visit")
    }
    // MARK: - Review findings (Codex, 2026-08-29)

    /// The ceiling used to be spent by *deciding* to read, not by reading. A
    /// capture that failed after that decision wrote nothing and still bought
    /// another full interval of silence, so a window whose screenshots keep
    /// failing starves exactly as it did before the ceiling existed — the
    /// original bug, wearing the fix as a disguise.
    func testAReadThatStoredNothingDoesNotSpendTheCeiling() {
        var probe = SameWindowProbe()
        let start = Date()
        _ = probe.look(at: fingerprint(10), now: start)
        probe.noteStored(at: start)

        let due = start.addingTimeInterval(ScreenAgentTimingPolicy.forcedReadSeconds + 1)
        XCTAssertEqual(probe.look(at: fingerprint(10), now: due), .forced)
        // No `noteStored` — the capture or the save failed.
        XCTAssertEqual(probe.look(at: fingerprint(10), now: due.addingTimeInterval(30)), .forced,
                       "a read that stored nothing must be retried, not waited out")
    }

    /// And a read that did land spends it.
    func testAStoredReadSpendsTheCeiling() {
        var probe = SameWindowProbe()
        let start = Date()
        _ = probe.look(at: fingerprint(10), now: start)
        probe.noteStored(at: start)
        let due = start.addingTimeInterval(ScreenAgentTimingPolicy.forcedReadSeconds + 1)
        XCTAssertEqual(probe.look(at: fingerprint(10), now: due), .forced)
        probe.noteStored(at: due)
        XCTAssertEqual(probe.look(at: fingerprint(10), now: due.addingTimeInterval(30)), .quiet)
    }

    /// Two gates in series again, and the reason the backwards-clock test above
    /// was false comfort: it calls `look` directly, but production asks
    /// `shouldLook` first, and that one rejected a negative interval outright —
    /// so the recovery branch it was meant to prove could never be reached.
    func testABackwardsClockDoesNotWedgeTheCadenceCheckEither() {
        var probe = SameWindowProbe()
        let start = Date()
        _ = probe.look(at: fingerprint(10), now: start)
        XCTAssertTrue(probe.shouldLook(at: start.addingTimeInterval(-90)),
                      "a clock that went backwards must not lock the probe out")
    }
}
