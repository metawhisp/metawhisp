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

    func testFirstContextStartsImmediately() {
        var q = ScreenAgentRunQueue<String>()
        XCTAssertEqual(q.submit(token(1)), .startNow(token(1)))
        XCTAssertTrue(q.isRunning)
    }

    /// The defect. A context arriving mid-run must be held, not dropped.
    func testContextArrivingMidRunIsHeldNotDropped() {
        var q = ScreenAgentRunQueue<String>()
        _ = q.submit(token(1))
        XCTAssertEqual(q.submit(token(2)), .queued,
                       "the screen the user just moved to was being thrown away")
        XCTAssertEqual(q.finish(), .startNow(token(2)))
    }

    /// Newest wins: while one run is busy, only the latest screen is worth
    /// anything. B is superseded by C before either runs.
    func testNewerPendingReplacesOlderPending() {
        var q = ScreenAgentRunQueue<String>()
        _ = q.submit(token(1))
        XCTAssertEqual(q.submit(token(2)), .queued)
        XCTAssertEqual(q.submit(token(3)), .replacedPending(dropped: token(2)))
        XCTAssertEqual(q.finish(), .startNow(token(3)), "C is current, B never was")
    }

    func testQueueDrainsToIdle() {
        var q = ScreenAgentRunQueue<String>()
        _ = q.submit(token(1))
        XCTAssertEqual(q.finish(), .idle)
        XCTAssertFalse(q.isRunning)
    }

    /// Turning the feature off, deleting screen history, or the owner changing
    /// must strand both the active run and anything waiting.
    func testCancelAllClearsRunningAndPending() {
        var q = ScreenAgentRunQueue<String>()
        _ = q.submit(token(1))
        _ = q.submit(token(2))
        q.cancelAll()
        XCTAssertFalse(q.isRunning)
        XCTAssertEqual(q.finish(), .idle, "nothing queued may start after a cancel")
    }

    /// A run that ends after a cancel must not be able to start the next one —
    /// the cancel happened while it was in flight.
    func testFinishAfterCancelDoesNotResurrectAPendingContext() {
        var q = ScreenAgentRunQueue<String>()
        _ = q.submit(token(1))
        _ = q.submit(token(2))
        q.cancelAll()
        XCTAssertEqual(q.finish(), .idle)
    }
}
