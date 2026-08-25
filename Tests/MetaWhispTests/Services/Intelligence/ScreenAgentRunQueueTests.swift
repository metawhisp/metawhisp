import XCTest
@testable import MetaWhisp

/// What happens to a context that arrives while the previous one is still being
/// analyzed.
///
/// Today: it is dropped. `ProactiveContextService` guards on `isRunning` and
/// returns, so while a twenty-second model call is in flight every screen the
/// user actually moves to is discarded — and the answer, when it comes, is
/// about the screen they left. The agent is structurally guaranteed to comment
/// on the past.
///
/// The rule instead: one run active, one newest context waiting, newer replaces
/// older. The user's most recent screen is never the one thrown away.
@MainActor
final class ScreenAgentRunQueueTests: XCTestCase {

    private func token(_ n: Int) -> String { "ctx-\(n)" }
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func start(_ q: inout ScreenAgentRunQueue<String>, _ n: Int,
                       at: Date? = nil) -> ScreenAgentRunQueue<String>.RunPermit {
        guard case .startNow(_, let permit) = q.submit(token(n), at: at ?? t0) else {
            fatalError("expected \(n) to start")
        }
        return permit
    }

    func testFirstContextStartsImmediately() {
        var q = ScreenAgentRunQueue<String>()
        _ = start(&q, 1)
        XCTAssertTrue(q.isRunning)
    }

    /// The defect. A context arriving mid-run must be held, not dropped.
    func testContextArrivingMidRunIsHeldNotDropped() {
        var q = ScreenAgentRunQueue<String>()
        let a = start(&q, 1)
        XCTAssertEqual(q.submit(token(2), at: t0), .queued,
                       "the screen the user just moved to was being thrown away")
        guard case .startNow(let next, _) = q.finish(a, at: t0) else {
            return XCTFail("the held context must run next")
        }
        XCTAssertEqual(next, token(2))
    }

    /// Newest wins: while one run is busy, only the latest screen is worth
    /// anything. B is superseded by C before either runs.
    func testNewerPendingReplacesOlderPending() {
        var q = ScreenAgentRunQueue<String>()
        let a = start(&q, 1)
        XCTAssertEqual(q.submit(token(2), at: t0), .queued)
        XCTAssertEqual(q.submit(token(3), at: t0), .replacedPending(dropped: token(2)))
        guard case .startNow(let next, _) = q.finish(a, at: t0) else { return XCTFail() }
        XCTAssertEqual(next, token(3), "C is current, B never was")
    }

    func testQueueDrainsToIdle() {
        var q = ScreenAgentRunQueue<String>()
        let a = start(&q, 1)
        XCTAssertEqual(q.finish(a, at: t0), .idle)
        XCTAssertFalse(q.isRunning)
    }

    /// Turning the feature off, deleting screen history, or the owner changing
    /// must strand both the active run and anything waiting.
    func testCancelAllClearsRunningAndPending() {
        var q = ScreenAgentRunQueue<String>()
        let a = start(&q, 1)
        _ = q.submit(token(2), at: t0)
        q.cancelAll()
        XCTAssertFalse(q.isRunning)
        XCTAssertEqual(q.finish(a, at: t0), .idle, "nothing queued may start after a cancel")
    }

    /// A run that ends after a cancel must not be able to start the next one —
    /// the cancel happened while it was in flight.
    func testFinishAfterCancelDoesNotResurrectAPendingContext() {
        var q = ScreenAgentRunQueue<String>()
        let a = start(&q, 1)
        _ = q.submit(token(2), at: t0)
        q.cancelAll()
        XCTAssertEqual(q.finish(a, at: t0), .idle)
    }

    // MARK: run identity — Codex review

    /// The bug a permit exists to stop: a run that was cancelled comes back
    /// late and finishes somebody else's run.
    ///
    /// submit(A) -> cancelAll() -> submit(C) -> late finish(A). Without run
    /// identity that stale completion clears isRunning, so D can start
    /// alongside C, or it promotes D while C is still going.
    func testAStaleCompletionCannotFinishANewerRun() {
        var q = ScreenAgentRunQueue<String>()
        let a = start(&q, 1)
        q.cancelAll()
        let c = start(&q, 3)
        XCTAssertEqual(q.finish(a, at: t0), .idle, "A's completion must be ignored entirely")
        XCTAssertTrue(q.isRunning, "C is still running")
        guard case .startNow(let next, _) = { () -> ScreenAgentRunQueue<String>.Outcome in
            _ = q.submit(token(4), at: t0)
            return q.finish(c, at: t0)
        }() else { return XCTFail("C's own completion should promote D") }
        XCTAssertEqual(next, token(4))
    }

    /// A run reporting completion twice must not promote two contexts.
    func testDoubleCompletionIsIgnored() {
        var q = ScreenAgentRunQueue<String>()
        let a = start(&q, 1)
        _ = q.submit(token(2), at: t0)
        guard case .startNow(_, _) = q.finish(a, at: t0) else { return XCTFail() }
        XCTAssertEqual(q.finish(a, at: t0), .idle, "the same run cannot finish twice")
    }

    // MARK: deadline

    /// A context that waited out the deadline is not worth showing — by then
    /// the user has moved on, which is the entire failure this iteration
    /// exists to stop.
    func testAContextThatWaitedPastTheDeadlineIsDropped() {
        var q = ScreenAgentRunQueue<String>()
        let a = start(&q, 1)
        _ = q.submit(token(2), at: t0)
        let late = t0.addingTimeInterval(ScreenAgentTimingPolicy.endToEndDeadline + 1)
        XCTAssertEqual(q.finish(a, at: late), .expired(token(2)))
        XCTAssertFalse(q.isRunning, "an expired context does not occupy the runner")
    }

    func testAContextInsideTheDeadlineStillRuns() {
        var q = ScreenAgentRunQueue<String>()
        let a = start(&q, 1)
        _ = q.submit(token(2), at: t0)
        let soon = t0.addingTimeInterval(ScreenAgentTimingPolicy.endToEndDeadline - 1)
        guard case .startNow(let next, _) = q.finish(a, at: soon) else { return XCTFail() }
        XCTAssertEqual(next, token(2))
    }

    /// The watchdog pattern: a stuck run is finished FOR it at the deadline,
    /// the pending context starts, and when the stuck call finally returns its
    /// permit is a stranger — the queue neither double-finishes nor stops the
    /// run the watchdog started.
    func testAWatchdogCanReleaseAStuckRunAndTheLateFinishIsAStranger() {
        var q = ScreenAgentRunQueue<String>()
        let stuck = start(&q, 1)
        _ = q.submit(token(2), at: t0)

        // Deadline passes; the watchdog finishes on the stuck run's behalf.
        let atDeadline = t0.addingTimeInterval(ScreenAgentTimingPolicy.endToEndDeadline)
        guard case .startNow(let next, _) = q.finish(stuck, at: atDeadline) else {
            return XCTFail("the pending context must start when the watchdog releases the queue")
        }
        XCTAssertEqual(next, token(2))
        XCTAssertTrue(q.isRunning)

        // The stuck model call eventually returns and reports in.
        XCTAssertEqual(q.finish(stuck, at: atDeadline.addingTimeInterval(30)), .idle)
        XCTAssertTrue(q.isRunning, "a stale completion must not stop the successor run")
    }
}
