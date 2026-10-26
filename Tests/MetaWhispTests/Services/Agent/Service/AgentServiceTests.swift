import XCTest
@testable import MetaWhisp

/// ITER-076 B1 — errands take turns: one runs, three wait and a fifth is
/// refused. Without Pro, without a goal or in a build with no run, nothing
/// starts and nothing is made.
@MainActor
final class AgentServiceTests: XCTestCase {

    private let done = ErrandOutcome(ending: .done, answer: "Five competitors", sources: [], sheet: nil, rows: 0)

    func testAnErrandStartsWhenNoneRuns() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let origin = ErrandOrigin.chat(messageID: UUID())
        let admission = service.start(goal: "  Find five competitors of an app \n", origin: origin)
        guard case .started(let id) = admission else { return XCTFail("\(admission)") }
        XCTAssertTrue(service.errandRunning)
        await h.until({ h.link.waiting == 1 }, "the errand asking for the browser")
        XCTAssertEqual(h.updates, [ErrandUpdate(id: id, origin: origin, event: .connecting(.connecting))])
        XCTAssertEqual(service.latest, h.updates.last, "a view reads the running errand's latest event")

        h.link.connect()
        let run = await h.runner(for: id)
        XCTAssertEqual(run?.setup.goal, "Find five competitors of an app", "the user's own words, trimmed")
        XCTAssertTrue(run?.setup.bridge as AnyObject === h.link.bridge, "the run drives the link's bridge")
        XCTAssertEqual(h.events(of: id), [.connecting(.connecting), .connecting(.connected(browser: "Google Chrome"))])
    }

    /// The start the chat gives — the address the user named when MetaChat's goal lost it (2026-10-12) — reaches the
    /// run with its goal; an errand given none has none.
    func testTheStartTheChatGivesReachesTheRun() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let start = URL(string: "https://duckduckgo.com/")!
        let id = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID()), start: start).id!
        let run = await h.runner(for: id)
        XCTAssertEqual(run?.setup.start, start)
        XCTAssertEqual(run?.setup.goal, "Find 10 jokes")
        run?.finish(done)
        let plain = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id!
        let other = await h.runner(for: plain)
        XCTAssertNil(other?.setup.start)
    }

    /// What the run reports is the errand's, and the run's end is its last
    /// event.
    func testTheRunsReportsAndEndAreTheErrandsEvents() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Find five competitors", origin: .voice(questionID: UUID())).id!
        let run = await h.runner(for: id)
        await h.until(id, shows: .connecting(.connected(browser: "Google Chrome")))
        run?.say(.working(title: "Searching", done: 1, wanted: 5))
        run?.say(.needsUser(ErrandHandover(kind: .signIn, host: "site-1.test")))
        run?.finish(done)
        await h.until({ !service.errandRunning }, "the errand's end")
        XCTAssertEqual(h.events(of: id), [.connecting(.connected(browser: "Google Chrome")),
                                          .working(title: "Searching", done: 1, wanted: 5),
                                          .needsUser(ErrandHandover(kind: .signIn, host: "site-1.test")),
                                          .finished(done)])
        XCTAssertEqual(service.latest?.event, .finished(done), "the last errand's end stays readable")
    }

    /// Once an errand has ended, nothing the service gave its run — the
    /// question, the reports — keeps the run, its bridge and its record alive.
    func testARunIsLetGoOnceItsErrandEnds() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let finished = service.start(goal: "Finished errand", origin: .chat(messageID: UUID())).id!
        weak let finishedRun = await h.runner(for: finished)
        finishedRun?.finish(done)
        await h.until({ !service.errandRunning }, "the first errand's end")
        let stopped = service.start(goal: "Stopped errand", origin: .chat(messageID: UUID())).id!
        weak let stoppedRun = await h.runner(for: stopped)
        service.stop(stopped)
        h.forgetRuns()
        await h.until({ finishedRun == nil && stoppedRun == nil }, "the runs to be let go")
    }

    func testASecondErrandWaitsAtPositionOneAndStartsWhenTheFirstEnds() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let first = service.start(goal: "First errand", origin: .chat(messageID: UUID())).id!
        let second = service.start(goal: "Second errand", origin: .chat(messageID: UUID()))
        XCTAssertEqual(second, .queued(id: second.id!, position: 1))
        XCTAssertEqual(h.events(of: second.id!), [.queued(position: 1)])
        await h.until({ h.link.waiting == 1 }, "the first errand asking for the browser")
        XCTAssertEqual(service.latest?.id, first, "a waiting errand is not the running one")

        h.link.connect()
        await h.runner(for: first)?.finish(done)
        _ = await h.runner(for: second.id!)
        await h.until(second.id!, shows: .connecting(.connected(browser: "Google Chrome")))
        XCTAssertEqual(h.events(of: first).last, .finished(done))
        XCTAssertEqual(h.events(of: second.id!), [.queued(position: 1), .connecting(.connected(browser: "Google Chrome"))])
        XCTAssertEqual(service.latest?.id, second.id)
        XCTAssertTrue(service.errandRunning)
    }

    func testAFifthErrandIsRefusedAsTheQueueIsFull() {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let admissions = (1...5).map { service.start(goal: "Errand \($0)", origin: .chat(messageID: UUID())) }
        XCTAssertEqual(admissions.map { $0.id == nil }, [false, false, false, false, true])
        XCTAssertEqual(admissions.dropFirst().map { admission -> Int? in
            if case .queued(_, let position) = admission { return position }
            return nil
        }, [1, 2, 3, nil])
        XCTAssertEqual(admissions.last, .refused(.queueFull))
        XCTAssertTrue(Set(h.updates.map(\.id)).isSubset(of: Set(admissions.compactMap(\.id))),
                      "the refused errand has no events")
    }

    func testWithoutProNothingStartsAndNoBridgeOrRunIsMade() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.pro = false
        h.link.connect()
        let service = h.makeService()
        XCTAssertEqual(service.start(goal: "Find five competitors", origin: .chat(messageID: UUID())), .refused(.notPro))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.link.asked, 0, "no bridge was asked for")
        XCTAssertTrue(h.runners.isEmpty, "no run was made")
        XCTAssertEqual(h.updates, [])
        XCTAssertEqual(h.assertionsMade, 0, "the Mac is not kept awake")
        XCTAssertFalse(service.errandRunning)
    }

    func testAnEmptyGoalIsRefused() {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        XCTAssertEqual(service.start(goal: " \n\t", origin: .chat(messageID: UUID())), .refused(.emptyGoal))
        XCTAssertEqual(h.updates, [])
        XCTAssertFalse(service.errandRunning)
    }

    /// Until the agent's run is wired into the app, every errand is refused
    /// honestly and nothing is asked of the browser.
    func testABuildWithNoRunRefusesEveryErrand() {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService(withRunner: false)
        XCTAssertEqual(service.start(goal: "Find five competitors", origin: .chat(messageID: UUID())), .refused(.unavailable))
        XCTAssertEqual(h.link.asked, 0)
        XCTAssertEqual(h.updates, [])
    }

    /// ITER-076 I-04: the service says whether an errand can run — only with
    /// a run for it — so MetaChat offers an errand only then.
    func testAnErrandCanRunOnlyWithARunForIt() {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        XCTAssertTrue(h.makeService().canRunErrands)
        XCTAssertFalse(h.makeService(withRunner: false).canRunErrands)
    }

    /// ITER-076 I-06a, changed by stage 8b (owner decision 8.5): MetaChat
    /// offers an errand with a run for it, with or without Pro — without it
    /// the start says the browser agent needs Pro, in the approved words —
    /// and an errand can start only with Pro too, read each time.
    func testAnErrandIsOfferedWithARunAndCanStartOnlyWithPro() {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        XCTAssertTrue(service.canRunErrands, "a run and Pro")
        XCTAssertTrue(service.canStartErrands)
        h.pro = false
        XCTAssertTrue(service.canRunErrands, "a run, no Pro: offered all the same (8.5)")
        XCTAssertFalse(service.canStartErrands, "a run, no Pro")
        XCTAssertEqual(service.start(goal: "Find five competitors", origin: .chat(messageID: UUID())), .refused(.notPro),
                       "as start says")
        h.pro = true
        XCTAssertTrue(service.canStartErrands, "Pro back")
        XCTAssertFalse(h.makeService(withRunner: false).canRunErrands, "Pro, no run")
    }

    /// ITER-076 stage 9d, № 27 — the owner's switch: once a run heard the
    /// server say the agent is off, MetaChat offers no errand and none starts
    /// — the waiting ones end as all stopped — while the minute lasts.
    func testCanRunErrandsStaysOffWhileTheOwnersSwitchIsOff() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let running = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id!
        let waiting = service.start(goal: "Find 5 recipes", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: running)

        run?.setup.switchedOff()
        let allStopped = ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0, notRun: .stoppedAll)
        XCTAssertEqual(h.events(of: waiting).last, .finished(allStopped))
        XCTAssertEqual(ChatService.errandEndingLine(allStopped), "Not started: all errands were stopped.")
        XCTAssertFalse(service.canRunErrands, "MetaChat offers none")
        XCTAssertEqual(service.start(goal: "During the switch", origin: .chat(messageID: UUID())), .refused(.unavailable))
        h.now += AgentService.switchRecheck - .seconds(1)
        XCTAssertFalse(service.canRunErrands, "still off within the minute")
        XCTAssertEqual(service.start(goal: "Still off", origin: .voice(questionID: UUID())), .refused(.unavailable))
        XCTAssertEqual(h.runners.count, 1, "nothing else ran")
    }

    /// … and they come back a minute later, when the next errand asks the
    /// server again — or at the next launch.
    func testCanRunErrandsComesBackAfterTheSwitchsMinuteOrTheNextLaunch() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: id)
        run?.setup.switchedOff()
        run?.finish(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ !service.errandRunning }, "the errand's end")
        XCTAssertFalse(service.canRunErrands)

        h.now += AgentService.switchRecheck
        XCTAssertTrue(service.canRunErrands, "a minute later")
        XCTAssertNotNil(service.start(goal: "Ask the server again", origin: .chat(messageID: UUID())).id)
        XCTAssertTrue(h.makeService().canRunErrands, "a new launch starts with errands on")
        XCTAssertEqual(AgentService.switchRecheck, .seconds(60))
    }

    /// ITER-076 I-06a: the service says, under each errand's id, its start,
    /// its place in the queue, what stopped it — the user, stop all, the
    /// Mac's sleep, the service's ceiling, the app's quit — and the ending it
    /// saved, with why a waiting one never ran. Never the goal.
    func testTheServiceSaysEachErrandsStartQueueStopAndSavedEnding() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        var runs: [FakeErrandRunner] = []
        func begin(_ goal: String) async -> UUID {
            let id = service.start(goal: goal, origin: .chat(messageID: UUID())).id!
            if let run = await h.runner(for: id) {
                run.returnsOnStop = false
                runs.append(run)
            }
            return id
        }
        let byUser = await begin("Invoice errand one")
        let queued = service.start(goal: "Invoice errand two", origin: .chat(messageID: UUID())).id!
        service.stop(queued)
        service.stop(byUser)
        let all = await begin("Invoice errand three")
        let waiting = service.start(goal: "Invoice errand four", origin: .chat(messageID: UUID())).id!
        service.stopAll()
        let slept = await begin("Invoice errand five")
        h.macWillSleep()
        h.macDidWake()
        let ceiling = await begin("Invoice errand six")
        h.timers.last?.action()
        let quit = await begin("Invoice errand seven")
        service.appWillQuit()

        XCTAssertEqual(h.logged.lines(of: byUser), ["started", "stop: the user", "#1 ending kind=stopped rows=0"])
        XCTAssertEqual(h.logged.lines(of: queued), ["queued at 1", "stop: the user", "#1 ending kind=stopped rows=0"])
        XCTAssertEqual(h.logged.lines(of: all), ["started", "stop: stop all", "#1 ending kind=stopped rows=0"])
        XCTAssertEqual(h.logged.lines(of: waiting), ["queued at 1", "#1 ending kind=stopped notRun=stoppedAll rows=0"])
        XCTAssertEqual(h.logged.lines(of: slept), ["started", "stop: the Mac sleeps", "#1 ending kind=stopped rows=0"])
        XCTAssertEqual(h.logged.lines(of: ceiling), ["started", "stop: past its ceiling", "#1 ending kind=ceiling rows=0"])
        XCTAssertEqual(h.logged.lines(of: quit), ["started", "stop: the app quits", "#1 ending kind=stopped rows=0"])
        XCTAssertFalse(h.logged.all.contains { $0.contains("Invoice") }, "never the goal")

        for run in runs { run.finish(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0)) }
        await h.until({ !runs.contains(where: \.isRunning) }, "the runs' return")
    }
}
