import Combine
import XCTest
@testable import MetaWhisp

/// ITER-076 B1b, review round 1, S4 — an errand shows the browser link as it
/// stands for its own request: a new attempt, one already under way, or the
/// open connection — never the last attempt's end. On folders of the test's
/// own: no browser is touched.
@MainActor
final class AgentServiceLinkTests: XCTestCase {

    private func emptyApplicationSupport() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mw-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A Chrome profile whose DevTools port is `port`: a held port asks for
    /// Allow and never answers, as Chrome does until the user clicks.
    private func applicationSupport(chromeOn port: HeldPort) throws -> URL {
        let support = try emptyApplicationSupport()
        let profile = support.appendingPathComponent("Google/Chrome", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try "\(port.port)\n/devtools/browser/held".write(to: profile.appendingPathComponent("DevToolsActivePort"),
                                                        atomically: true, encoding: .utf8)
        return support
    }

    private let askingForAllow = ChromeLink.State.waitingForAllow(browser: "Google Chrome")

    /// The owner's part: ChromeLink says `.connecting` in the turn a new
    /// attempt is asked for, not when the attempt's task gets to run.
    func testANewAttemptSaysConnectingAsItIsAskedFor() async throws {
        let link = ChromeLink(applicationSupport: try emptyApplicationSupport(), settleLimit: .milliseconds(300),
                              application: { URL(fileURLWithPath: "/Applications/Google Chrome.app") })
        _ = await link.connect()
        XCTAssertEqual(link.state, .notRunning)
        var inTheAskingTurn = true
        Task { @MainActor in inTheAskingTurn = false }
        var first: (state: ChromeLink.State, inTheAskingTurn: Bool)?
        let watch = link.$state.dropFirst().sink { state in
            if first == nil { first = (state, inTheAskingTurn) }
        }
        defer { watch.cancel() }
        _ = await link.connect()
        XCTAssertEqual(first?.state, .connecting)
        XCTAssertEqual(first?.inTheAskingTurn, true, "said as the attempt is made")
        XCTAssertEqual(link.state, .notRunning)
    }

    /// Only a new attempt says `.connecting`: a request that reuses the open
    /// connection leaves the link connected.
    func testReusingTheOpenConnectionLeavesTheLinkConnected() async throws {
        let port = try await HeldPort.start(speaking: true)
        defer { port.stop() }
        let support = try emptyApplicationSupport()
        let profile = support.appendingPathComponent("Google/Chrome", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try "\(port.port)\n/devtools/browser/held".write(to: profile.appendingPathComponent("DevToolsActivePort"),
                                                        atomically: true, encoding: .utf8)
        let link = ChromeLink(applicationSupport: support)
        let first = await link.connect()
        XCTAssertNotNil(first)
        XCTAssertEqual(link.state, .connected(browser: "Google Chrome"))
        let again = await link.connect()
        XCTAssertTrue(again === first)
        XCTAssertEqual(link.state, .connected(browser: "Google Chrome"), "a reuse is not a new attempt")
    }

    /// Review of B1, round 2: the last caller stops while the browser asks for
    /// Allow, and a new caller comes right after, before the stopped attempt
    /// has ended. The new caller gets an attempt of its own — a second
    /// connection, its own Allow question — never the stopped attempt's nil.
    func testACallerRightAfterTheLastOneStoppedGetsAnAttemptOfItsOwn() async throws {
        let port = try await HeldPort.start()
        defer { port.stop() }
        let link = ChromeLink(applicationSupport: try applicationSupport(chromeOn: port))
        let h = AgentServiceHarness()
        let first = Task { await link.connect() }
        await h.until({ link.state == askingForAllow }, "the browser asking for Allow", limit: .seconds(5))
        first.cancel()
        let stopped = await first.value
        XCTAssertNil(stopped)
        var nextReturned = false
        let next = Task {
            let connection = await link.connect()
            nextReturned = true
            return connection
        }
        await h.until({ port.connections == 2 && link.state == askingForAllow }, "an Allow question of its own",
                      limit: .seconds(5))
        XCTAssertFalse(nextReturned, "it waits for its own Allow")
        // The stopped attempt, ending meanwhile, left the new one in place: a
        // caller that comes now joins it — no third question to the user.
        let joining = Task { await link.connect() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(port.connections, 2)
        XCTAssertEqual(link.state, askingForAllow)
        next.cancel()
        joining.cancel()
        _ = await next.value
        _ = await joining.value
    }

    /// Whether the errand waits on a live Allow question: its last event asks
    /// for Allow, it has not ended, and one question is open. Whether it joined
    /// the question the stopped caller was still leaving or opened its own
    /// depends on timing, and both are right (review of B1c, round 2).
    private func waitsOnALiveAllow(_ errand: UUID, _ h: AgentServiceHarness, _ port: HeldPort) -> Bool {
        h.events(of: errand).last == .connecting(askingForAllow)
            && !h.events(of: errand).contains(where: \.isFinished)
            && port.connections - port.ended == 1
    }

    /// With the real link: after a Stop during the Allow question, the errand
    /// queued behind waits on a live Allow question; it does not end as not
    /// allowed — not even a moment later.
    func testAfterAStopDuringTheAllowQuestionTheQueuedErrandWaitsForItsOwnAllow() async throws {
        let port = try await HeldPort.start()
        defer { port.stop() }
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService(link: ChromeLink(applicationSupport: try applicationSupport(chromeOn: port)))
        let first = service.start(goal: "First errand", origin: .chat(messageID: UUID())).id!
        let second = service.start(goal: "Second errand", origin: .chat(messageID: UUID())).id!
        await h.until({ h.events(of: first).last == .connecting(askingForAllow) }, "the Allow question",
                      limit: .seconds(5))
        service.stop(first)
        await h.until({ self.waitsOnALiveAllow(second, h, port) }, "the queued errand on a live Allow question",
                      limit: .seconds(5))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(waitsOnALiveAllow(second, h, port), "it did not end as not allowed")
    }

    /// The same for an errand started in the turn the other one was stopped.
    func testAfterAStopDuringTheAllowQuestionAnErrandStartedAtOnceWaitsForItsOwnAllow() async throws {
        let port = try await HeldPort.start()
        defer { port.stop() }
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService(link: ChromeLink(applicationSupport: try applicationSupport(chromeOn: port)))
        let first = service.start(goal: "First errand", origin: .chat(messageID: UUID())).id!
        await h.until({ h.events(of: first).last == .connecting(askingForAllow) }, "the Allow question",
                      limit: .seconds(5))
        service.stop(first)
        let second = service.start(goal: "Second errand", origin: .chat(messageID: UUID())).id!
        await h.until({ self.waitsOnALiveAllow(second, h, port) }, "the new errand on a live Allow question",
                      limit: .seconds(5))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(waitsOnALiveAllow(second, h, port), "it did not end as not allowed")
    }

    /// With the real link: after an errand the browser did not let in, the
    /// next errand's first event is its own attempt.
    func testAnErrandsFirstEventIsItsOwnAttemptNeverTheLastOnesEnd() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let link = ChromeLink(applicationSupport: try emptyApplicationSupport(), settleLimit: .milliseconds(300),
                              application: { URL(fileURLWithPath: "/Applications/Google Chrome.app") })
        let service = h.makeService(link: link)
        let first = service.start(goal: "First errand", origin: .chat(messageID: UUID())).id!
        await h.until({ !service.errandRunning }, "the first errand's end")
        XCTAssertEqual(h.events(of: first).last,
                       .finished(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0,
                                               notRun: .browserNotRunning)))
        let second = service.start(goal: "Second errand", origin: .chat(messageID: UUID())).id!
        await h.until({ !service.errandRunning }, "the second errand's end")
        XCTAssertEqual(h.events(of: second).first, .connecting(.connecting))
        XCTAssertEqual(h.events(of: second), [.connecting(.connecting), .connecting(.notRunning),
                                              .finished(ErrandOutcome(ending: .stopped, answer: nil, sources: [],
                                                                      sheet: nil, rows: 0,
                                                                      notRun: .browserNotRunning))])
    }

    /// A request that joins an attempt under way — the Allow question already
    /// up — shows it.
    func testAnErrandThatJoinsAnAttemptUnderWayShowsWhereItStands() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.attemptUnderWay = true
        h.link.state = .waitingForAllow(browser: "Google Chrome")
        let service = h.makeService()
        let id = service.start(goal: "Find five competitors", origin: .chat(messageID: UUID())).id!
        await h.until({ !h.events(of: id).isEmpty }, "the errand's first event")
        XCTAssertEqual(h.events(of: id), [.connecting(.waitingForAllow(browser: "Google Chrome"))])
        h.link.connect()
        _ = await h.runner(for: id)
        XCTAssertEqual(h.events(of: id), [.connecting(.waitingForAllow(browser: "Google Chrome")),
                                          .connecting(.connected(browser: "Google Chrome"))])
    }
}
