import XCTest
@testable import MetaWhisp

/// ITER-076 B1 — Stop ends an errand at once, running or waiting, and keeps
/// what it collected; Stop all also drops the waiting ones as not started.
@MainActor
final class AgentServiceStopTests: XCTestCase {

    private func sources(_ count: Int) -> [URL] {
        (1...count).map { URL(string: "https://site-\($0).test/")! }
    }

    func testStopEndsTheRunningErrandAtOnceAndTheNextStarts() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let first = service.start(goal: "First errand", origin: .chat(messageID: UUID())).id!
        let second = service.start(goal: "Second errand", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: first)
        run?.collect(2)

        service.stop(first)
        XCTAssertEqual(run?.stops, 1, "the run is told to stop")
        XCTAssertEqual(h.events(of: first).last,
                       .finished(ErrandOutcome(ending: .stopped, answer: nil, sources: sources(2), sheet: nil, rows: 2)),
                       "at once, with what it collected")
        XCTAssertTrue(service.errandRunning, "the next one starts at once")
        _ = await h.runner(for: second)
        await h.until(second, shows: .connecting(.connected(browser: "Google Chrome")))
        XCTAssertEqual(service.latest?.id, second)
        XCTAssertEqual(h.events(of: second), [.queued(position: 1), .connecting(.connected(browser: "Google Chrome"))])
        XCTAssertEqual(h.events(of: first).filter(\.isFinished).count, 1, "what the stopped run returns is dropped")
    }

    /// ITER-076 stage 7: Stop once a form's Send was pressed keeps how its
    /// form stands — MetaChat never says only "Stopped." of a form that may
    /// have gone.
    func testStopAfterAFormsSendWasPressedKeepsHowItsFormStands() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Request a demo", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: id)
        let pressed = FormEnding(kind: .notConfirmed, host: "site-440.test", url: "https://site-440.test/")
        run?.record.form = pressed
        service.stop(id)
        guard case .finished(let outcome)? = h.events(of: id).last else { return XCTFail("\(h.events(of: id))") }
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(outcome.form, pressed)
        XCTAssertTrue(ChatService.errandResultText(outcome).hasPrefix("Not confirmed: Send was pressed on site-440.test"))
    }

    func testStopAllEndsTheRunningOneAndDropsTheWaitingAsNotStarted() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let ids = (1...3).map { service.start(goal: "Errand \($0)", origin: .chat(messageID: UUID())).id! }
        _ = await h.runner(for: ids[0])

        service.stopAll()
        XCTAssertEqual(h.events(of: ids[0]).last,
                       .finished(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0)))
        for waiting in ids.dropFirst() {
            XCTAssertEqual(h.events(of: waiting).last,
                           .finished(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0,
                                                   notRun: .stoppedAll)))
        }
        XCTAssertFalse(service.errandRunning)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.runners.count, 1, "the waiting ones never run")
        XCTAssertEqual(h.link.asked, 1)
        XCTAssertNotNil(service.start(goal: "After stop all", origin: .chat(messageID: UUID())).id, "errands start again")
    }

    func testStopOnAWaitingErrandEndsItAndMovesTheOthersUp() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let ids = (1...4).map { service.start(goal: "Errand \($0)", origin: .chat(messageID: UUID())).id! }
        let run = await h.runner(for: ids[0])
        await h.until(ids[0], shows: .connecting(.connected(browser: "Google Chrome")))

        service.stop(ids[2])
        XCTAssertEqual(h.events(of: ids[2]),
                       [.queued(position: 2), .finished(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0))])
        XCTAssertEqual(h.events(of: ids[1]), [.queued(position: 1)])
        XCTAssertEqual(h.events(of: ids[3]), [.queued(position: 3), .queued(position: 2)])
        XCTAssertEqual(run?.stops, 0, "the running errand goes on")
        XCTAssertEqual(service.latest?.id, ids[0])
        let fifth = service.start(goal: "Errand 5", origin: .chat(messageID: UUID()))
        XCTAssertEqual(fifth, .queued(id: fifth.id!, position: 3), "its place is free again")
    }

    /// Stop ends the errand it names and no other: the ones still waiting keep
    /// their place — even ones past their wait, which the queue drops, all of
    /// them, when it next moves.
    func testStopOnAWaitingErrandEndsThatOneOnly() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let ids = (1...4).map { service.start(goal: "Errand \($0)", origin: .chat(messageID: UUID())).id! }
        let run = await h.runner(for: ids[0])
        h.now += AgentQueue.maxWait

        service.stop(ids[2])
        XCTAssertEqual(h.events(of: ids[1]), [.queued(position: 1)], "not ended by another errand's Stop")
        XCTAssertEqual(h.events(of: ids[3]), [.queued(position: 3), .queued(position: 2)])
        run?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ !service.errandRunning }, "the running errand's end")
        let expired = ErrandEvent.finished(ErrandOutcome(ending: .ceiling, answer: nil, sources: [], sheet: nil, rows: 0,
                                                         notRun: .expired))
        XCTAssertEqual(h.events(of: ids[1]).last, expired)
        XCTAssertEqual(h.events(of: ids[3]).last, expired)
    }

    /// Stop while the browser has not let the errand in yet: the errand ends,
    /// its wait for the browser ends too — with it Chrome's Allow question —
    /// and no run is made when the browser answers later.
    func testStopBeforeTheBridgeArrivesEndsTheWaitForTheBrowser() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let id = service.start(goal: "Find five competitors", origin: .chat(messageID: UUID())).id!
        await h.until({ h.link.waiting == 1 }, "the errand asking for the browser")
        h.link.state = .waitingForAllow(browser: "Google Chrome")

        service.stop(id)
        XCTAssertEqual(h.events(of: id).last,
                       .finished(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0)))
        XCTAssertFalse(service.errandRunning)
        await h.until({ h.link.waiting == 0 }, "the wait for the browser to end")
        h.link.connect()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(h.runners.isEmpty, "no run after Stop")
        XCTAssertEqual(h.events(of: id).count, 3, "nothing after the end: \(h.events(of: id))")
    }

    func testTwoStopsInARowEndTheErrandOnce() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Find five competitors", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: id)
        service.stop(id)
        service.stop(id)
        service.stop(UUID())
        XCTAssertEqual(run?.stops, 1)
        XCTAssertEqual(h.events(of: id).filter(\.isFinished).count, 1)
    }

    /// ITER-076 brain, step 2: an answer errand that Stop, the Mac's sleep or
    /// the app's quit ends shows the answer its facts make — each quote and
    /// its page's link, as its run would give it — and those pages as its
    /// sources; its saved record keeps the facts. Stage 1: an errand that did
    /// not end done shows what it read beside them, as context.
    func testStopSleepAndQuitEndAnAnswerErrandWithTheAnswerItsFactsMake() async {
        let facts: [ErrandRecord.Fact] = [
            .init(requirements: ["r1"], quote: "Joke 1", source: "main/:2", url: "https://site-404.test/"),
            .init(requirements: [], quote: "Six jokes", source: "main/:1", url: "https://site-405.test/a"),
            .init(requirements: ["r1"], quote: "Joke 2", source: "main/:4", url: "https://site-405.test/a"),
        ]
        for way in ["stop", "sleep", "quit"] {
            let h = AgentServiceHarness()
            defer { h.cleanUp() }
            h.link.connect()
            let service = h.makeService()
            let id = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id!
            let run = await h.runner(for: id)
            run?.record.facts = facts
            switch way {
            case "stop": service.stop(id)
            case "sleep": h.macWillSleep()
            default: service.appWillQuit()
            }
            XCTAssertEqual(h.events(of: id).last,
                           .finished(ErrandOutcome(ending: .stopped,
                                                   answer: "Joke 1\nhttps://site-404.test/\n\nJoke 2\nhttps://site-405.test/a"
                                                       + "\n\nSix jokes\nhttps://site-405.test/a",
                                                   sources: [URL(string: "https://site-404.test/")!,
                                                             URL(string: "https://site-405.test/a")!],
                                                   sheet: nil, rows: 0)), way)
            XCTAssertEqual(h.saved(id)?.record.facts, facts, way)
        }
    }
}

/// ITER-076 B1 — the queue's own ends reach the errand: a waiting errand that
/// expires, or that an update drops, ends as not started and says why; while
/// an update waits nothing new starts, and errands start again once it is
/// withdrawn.
@MainActor
final class AgentServiceQueueTests: XCTestCase {

    func testAWaitingErrandThatExpiresEndsAsNotStarted() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let running = service.start(goal: "Long errand", origin: .chat(messageID: UUID())).id!
        let waiting = service.start(goal: "Waiting errand", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: running)
        h.now += AgentQueue.maxWait
        run?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ !service.errandRunning }, "the long errand's end")
        XCTAssertEqual(h.events(of: waiting).last,
                       .finished(ErrandOutcome(ending: .ceiling, answer: nil, sources: [], sheet: nil, rows: 0,
                                               notRun: .expired)))
        XCTAssertEqual(h.runners.count, 1, "it never ran")
    }

    func testAnExpiredErrandFoundAtAStartEndsAsNotStarted() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        _ = service.start(goal: "Long errand", origin: .chat(messageID: UUID()))
        let old = service.start(goal: "Old errand", origin: .chat(messageID: UUID())).id!
        h.now += AgentQueue.maxWait
        let new = service.start(goal: "New errand", origin: .chat(messageID: UUID()))
        XCTAssertEqual(new, .queued(id: new.id!, position: 1), "the expired one's place is free")
        XCTAssertEqual(h.events(of: old).last?.isFinished, true)
    }

    /// An update is ready: the running errand finishes, the waiting ones end
    /// as not started, and nothing new starts until the update is withdrawn.
    func testWhileAnUpdateWaitsNothingNewStartsAndErrandsStartAgainAfter() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let running = service.start(goal: "Running errand", origin: .chat(messageID: UUID())).id!
        let waiting = service.start(goal: "Waiting errand", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: running)

        service.updateIsReady()
        XCTAssertEqual(h.events(of: waiting).last,
                       .finished(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0,
                                               notRun: .updateWaiting)))
        XCTAssertEqual(run?.stops, 0, "the running errand goes on")
        XCTAssertEqual(service.start(goal: "During the update", origin: .chat(messageID: UUID())), .refused(.updateWaiting))

        service.updateWithdrawn()
        run?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ !service.errandRunning }, "the running errand's end")
        XCTAssertNotNil(service.start(goal: "After the update", origin: .chat(messageID: UUID())).id,
                        "errands start again once the update is withdrawn")
    }
}
