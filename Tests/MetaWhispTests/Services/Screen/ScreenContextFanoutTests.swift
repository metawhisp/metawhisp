import XCTest
@testable import MetaWhisp

/// ITER-064A.4 — the task reactor and the proactive path are independent
/// consumers of the same captured context.
///
/// They were chained: the reactor was awaited first, and its model call is
/// allowed 20 seconds, so a screen the user was looking at right now did not
/// reach the proactive path until the task classifier had finished with it.
/// By then the user has usually moved on.
@MainActor
final class ScreenContextFanoutTests: XCTestCase {

    private func makeContext() -> ScreenContext {
        ScreenContext(appName: "Slack", windowTitle: "#launch", ocrText: "hello")
    }

    /// The defect: a slow reactor must not hold up the proactive path.
    func testProactiveIsNotQueuedBehindASlowTaskReactor() async {
        let proactiveRan = expectation(description: "proactive consumer ran")
        ScreenContextFanout.dispatch(
            makeContext(),
            toTaskReactor: { _ in try? await Task.sleep(for: .seconds(3)) },
            toProactive: { _ in proactiveRan.fulfill() }
        )
        await fulfillment(of: [proactiveRan], timeout: 0.5)
    }

    /// Symmetry: a consumer that throws the whole run away must not silence
    /// the other one either.
    func testBothConsumersReceiveTheSameContext() async {
        let reactorRan = expectation(description: "reactor consumer ran")
        let proactiveRan = expectation(description: "proactive consumer ran")
        let ctx = makeContext()
        var reactorSawID: UUID?
        var proactiveSawID: UUID?

        ScreenContextFanout.dispatch(
            ctx,
            toTaskReactor: { c in reactorSawID = c.id; reactorRan.fulfill() },
            toProactive: { c in proactiveSawID = c.id; proactiveRan.fulfill() }
        )

        await fulfillment(of: [reactorRan, proactiveRan], timeout: 1.0)
        XCTAssertEqual(reactorSawID, ctx.id)
        XCTAssertEqual(proactiveSawID, ctx.id)
    }
    /// Stage 2.1-bis — the ceiling on the picture gate stores a row for a window
    /// nobody touched so that an hour of reading is not a hole in history. The
    /// pixels are the ones both consumers already saw, so waking them would buy
    /// a model call every ceiling interval for a screen that did not change:
    /// the cost the gate exists to avoid, arriving through the fix for the gate.
    func testAForcedRereadWakesNeitherConsumer() async {
        var reactorRan = false
        var proactiveRan = false
        ScreenContextFanout.dispatch(
            makeContext(),
            isForcedReread: true,
            toTaskReactor: { _ in reactorRan = true },
            toProactive: { _ in proactiveRan = true }
        )
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(reactorRan, "nothing on the screen changed")
        XCTAssertFalse(proactiveRan, "nothing on the screen changed")
    }
}
