import XCTest
@testable import MetaWhisp

/// ITER-076 B1 — before its run, an errand waits for the user's browser and
/// says where that stands. When the browser does not let it in, the errand
/// ends with the reason, and nothing else is done for it.
@MainActor
final class AgentServiceBrowserTests: XCTestCase {

    func testWhileTheBrowserAsksForAllowTheErrandSaysSo() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let id = service.start(goal: "Find five competitors", origin: .chat(messageID: UUID())).id!
        await h.until({ h.link.waiting == 1 }, "the errand asking for the browser")
        h.link.state = .connecting
        h.link.state = .connecting
        h.link.state = .waitingForAllow(browser: "Google Chrome")
        XCTAssertEqual(service.latest?.event, .connecting(.waitingForAllow(browser: "Google Chrome")))
        XCTAssertTrue(h.runners.isEmpty, "no run before the browser lets the errand in")
        h.link.connect()
        _ = await h.runner(for: id)
        XCTAssertEqual(h.events(of: id), [.connecting(.connecting),
                                          .connecting(.waitingForAllow(browser: "Google Chrome")),
                                          .connecting(.connected(browser: "Google Chrome"))],
                       "each state of its own attempt once, in order")
    }

    func testABrowserThatDoesNotLetTheErrandInEndsItWithTheReason() async {
        let cases: [(ChromeLink.State, ErrandOutcome.NotRun)] = [(.remoteDebuggingOff, .remoteDebuggingOff),
                                                                 (.notAllowed, .notAllowed),
                                                                 (.notRunning, .browserNotRunning)]
        for (state, reason) in cases {
            let h = AgentServiceHarness()
            defer { h.cleanUp() }
            let service = h.makeService()
            let id = service.start(goal: "Find five competitors", origin: .chat(messageID: UUID())).id!
            await h.until({ h.link.waiting == 1 }, "the errand asking for the browser")
            h.link.fail(state)
            await h.until({ !service.errandRunning }, "the errand's end")
            XCTAssertEqual(h.events(of: id).last,
                           .finished(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0,
                                                   notRun: reason)), "\(state)")
            XCTAssertTrue(h.runners.isEmpty, "no run is made for it")
            XCTAssertEqual(h.link.asked, 1, "the browser is not asked again on its own")
        }
    }

    func testTheNextErrandStartsAfterOneTheBrowserDidNotLetIn() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let first = service.start(goal: "First errand", origin: .chat(messageID: UUID())).id!
        let second = service.start(goal: "Second errand", origin: .chat(messageID: UUID())).id!
        await h.until({ h.link.waiting == 1 }, "the first errand asking for the browser")
        h.link.fail(.notAllowed)
        await h.until({ h.link.asked == 2 }, "the second errand asking for the browser")
        XCTAssertEqual(h.events(of: first).last?.isFinished, true)
        XCTAssertEqual(service.latest?.id, second)
        XCTAssertTrue(service.errandRunning)
    }
}

extension ErrandEvent {
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}
