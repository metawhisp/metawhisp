import XCTest
@testable import MetaWhisp

/// ITER-076 stage 8b, 8.3 — "Use your own Chrome" in Settings → Agent: the browser it names serves the next errand,
/// a running errand finishes in its own, and once nothing runs the browser no errand uses any more is let go —
/// MetaWhisp's own Chrome window closes, or only the connection to the user's own Chrome. The quit closes MetaWhisp's
/// window whichever way is set; the user's own Chrome is never closed. A cleared MetaChat forgets MetaWhisp's own
/// Chrome once nothing runs. Two fake links stand for the two browsers; the way comes from the harness.
@MainActor
final class AgentServiceWayTests: XCTestCase {

    private static let done = ErrandOutcome(ending: .done, answer: "Ten jokes", sources: [], sheet: nil, rows: 0)

    /// The way named as an errand begins is its browser: a change serves the next errand, the running one keeps its
    /// own; once it ended, MetaWhisp's window — left — closes, and the user's Chrome is never closed.
    func testTheWayServesTheNextErrandAndARunningOneKeepsItsBrowser() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.owns = true
        h.link.connect()
        let users = FakeErrandLink()
        users.connect()
        let service = h.makeService(usersLink: users)
        let first = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        let run = await h.runner(for: first)
        XCTAssertTrue(run?.setup.bridge as AnyObject === h.link.bridge, "MetaWhisp's own Chrome")

        h.way = .usersChrome
        service.wayChanged()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(h.link.closes, 0, "the running errand keeps its browser")
        XCTAssertEqual(users.asked, 0)

        run?.finish(Self.done)
        await h.until({ h.link.closes == 1 }, "MetaWhisp's window to close once nothing runs")
        XCTAssertEqual(users.disconnects, 0, "the way now named keeps its connection")
        let second = try XCTUnwrap(service.start(goal: "Find 5 recipes", origin: .chat(messageID: UUID())).id)
        let next = await h.runner(for: second)
        XCTAssertTrue(next?.setup.bridge as AnyObject === users.bridge, "the user's own Chrome")
        XCTAssertEqual(users.closes, 0, "never closed")
        XCTAssertEqual(h.link.asked, 1, "MetaWhisp's own Chrome is not asked again")
    }

    /// A change while nothing runs lets go at once: leaving the own way closes its window; leaving the user's way
    /// drops only the connection to their Chrome.
    func testAChangeWhileNothingRunsLetsGoAtOnce() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.owns = true
        let users = FakeErrandLink()
        let service = h.makeService(usersLink: users)
        h.way = .usersChrome
        service.wayChanged()
        await h.until({ h.link.closes == 1 }, "MetaWhisp's window to close")
        XCTAssertEqual(users.disconnects, 0)

        h.way = .ownWindow
        service.wayChanged()
        await h.until({ users.disconnects == 1 }, "the connection to the user's Chrome to close")
        XCTAssertEqual(users.closes, 0, "the user's own Chrome is never closed")
        XCTAssertEqual(h.link.closes, 1, "nothing more of the own window")
    }

    /// The quit closes MetaWhisp's window whichever way is set — never the user's Chrome.
    func testTheQuitClosesTheOwnWindowWhicheverWayIsSet() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.owns = true
        let users = FakeErrandLink()
        h.way = .usersChrome
        let service = h.makeService(usersLink: users)
        let quit = try XCTUnwrap(service.appWillQuit(), "MetaWhisp's window to close")
        await quit.value
        XCTAssertEqual(h.link.closes, 1)
        XCTAssertEqual(users.closes, 0)
    }

    /// A cleared MetaChat forgets MetaWhisp's own Chrome — closed, its profile deleted — once nothing runs: not while
    /// an errand runs in it.
    func testAClearForgetsTheOwnChromeOnceNothingRuns() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.owns = true
        h.link.connect()
        let users = FakeErrandLink()
        let service = h.makeService(usersLink: users)
        let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        let run = await h.runner(for: id)
        service.deleteAllRecords()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(h.link.forgets, 0, "not while the errand runs in it")
        run?.finish(Self.done)
        await h.until({ h.link.forgets == 1 }, "MetaWhisp's own Chrome to be forgotten")
        XCTAssertEqual(users.forgets, 0)
        XCTAssertEqual(users.closes, 0)
    }
}
