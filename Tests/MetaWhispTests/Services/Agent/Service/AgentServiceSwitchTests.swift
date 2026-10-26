import XCTest
@testable import MetaWhisp

/// ITER-076 stage 8b — the user's own switch, "Browser agent" in Settings → Agent (8.1: on by default), and Pro
/// (8.5). MetaChat offers an errand with a run, the agent on and the owner's switch on — with or without Pro: without
/// it the start answers that the browser agent needs Pro. Turned off (8.4), every errand stops in the approved lines,
/// nothing starts, and once no run is out MetaWhisp's own Chrome window closes and the connection to the user's own
/// Chrome with it; the user's Allow is kept. Settings come from the harness, never the host's.
@MainActor
final class AgentServiceSwitchTests: XCTestCase {

    private static let stopped = ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0)
    private static let allStopped = ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0,
                                                  notRun: .stoppedAll)

    // MARK: - The offer and the start

    /// {Pro, no Pro} × {on, off} × {the owner's switch on, off}: the offer needs the agent on and the switch on, not
    /// Pro; an errand can start — MetaChat's example shows — only with all three; the start says which one is missing,
    /// and nothing is asked of the browser when it refuses.
    func testTheOfferAndTheStartForProTheSwitchAndTheOwnersSwitch() async {
        for pro in [true, false] {
            for on in [true, false] {
                for ownersSwitchOn in [true, false] {
                    let h = AgentServiceHarness()
                    defer { h.cleanUp() }
                    h.pro = pro
                    h.agentOn = on
                    h.link.connect()
                    let service = h.makeService()
                    let named = "pro=\(pro) on=\(on) ownersSwitch=\(ownersSwitchOn)"
                    if !ownersSwitchOn {
                        // The owner's switch is heard by a run: one errand, run with everything on, hears it.
                        let (wasPro, wasOn) = (h.pro, h.agentOn)
                        (h.pro, h.agentOn) = (true, true)
                        let id = service.start(goal: "Hear the switch", origin: .chat(messageID: UUID())).id!
                        let run = await h.runner(for: id)
                        run?.setup.switchedOff()
                        run?.finish(Self.stopped)
                        await h.until({ !service.errandRunning }, "the errand's end")
                        (h.pro, h.agentOn) = (wasPro, wasOn)
                        h.forgetRuns()
                    }
                    XCTAssertEqual(service.canRunErrands, on && ownersSwitchOn, "the offer: \(named)")
                    XCTAssertEqual(service.canStartErrands, on && ownersSwitchOn && pro, "an errand can start: \(named)")
                    let asked = h.link.asked
                    let admission = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID()))
                    let expected: ErrandAdmission.Refusal? = !pro ? .notPro : !(on && ownersSwitchOn) ? .unavailable : nil
                    if let expected {
                        XCTAssertEqual(admission, .refused(expected), named)
                        try? await Task.sleep(for: .milliseconds(20))
                        XCTAssertEqual(h.link.asked, asked, "nothing asked of the browser: \(named)")
                        XCTAssertTrue(h.runners.isEmpty, "no run: \(named)")
                    } else {
                        XCTAssertNotNil(admission.id, named)
                    }
                }
            }
        }
    }

    /// The approved lines for both refusals (8b-30, 8b-31): MetaChat's model reads them as the tool's result.
    func testTheRefusalsReadTheApprovedLines() {
        let executor = ChatToolExecutor()
        for (refusal, line) in [(ErrandAdmission.Refusal.notPro, "not started: the browser agent needs Pro"),
                                (.unavailable, "not started: the browser agent is not available yet")] {
            executor.startErrand = { _, _, _, _ in .refused(refusal) }
            XCTAssertEqual(executor.runErrand(.init(id: nil, tool: "runErrand", args: ["goal": "find 10 jokes"]),
                                              origin: .chat(messageID: UUID())).summary, line)
        }
    }

    // MARK: - Off

    /// Off while errands run (8.4): the running one stops ("Stopped."), the waiting ones end as all stopped ("Not
    /// started: all errands were stopped."), the Mac is free; while off nothing is offered and nothing starts; the
    /// user's Allow is kept, and on again the next errand runs without asking.
    func testOffStopsEveryErrandInTheApprovedLinesAndKeepsTheAllow() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let running = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        let waiting = try XCTUnwrap(service.start(goal: "Find 5 recipes", origin: .voice(questionID: UUID())).id)
        let run = await h.runner(for: running)

        h.agentOn = false
        service.turnedOff()
        XCTAssertEqual(run?.stops, 1, "the run is told to stop")
        XCTAssertEqual(h.events(of: running).last, .finished(Self.stopped))
        XCTAssertEqual(h.events(of: waiting).last, .finished(Self.allStopped))
        XCTAssertEqual(ChatService.errandEndingLine(Self.stopped), "Stopped.")
        XCTAssertEqual(ChatService.errandEndingLine(Self.allStopped), "Not started: all errands were stopped.")
        XCTAssertFalse(service.errandRunning)
        XCTAssertFalse(h.keepsAwake)
        XCTAssertFalse(service.canRunErrands, "MetaChat offers none while off")
        XCTAssertEqual(service.start(goal: "While off", origin: .chat(messageID: UUID())), .refused(.unavailable))
        XCTAssertEqual(h.runners.count, 1, "nothing else ran")
        XCTAssertTrue(h.allowed, "the Allow is kept")
        XCTAssertEqual(h.allows, 0)

        h.agentOn = true
        XCTAssertTrue(service.canRunErrands)
        let next = try XCTUnwrap(service.start(goal: "On again", origin: .chat(messageID: UUID())).id)
        let run2 = await h.runner(for: next)
        XCTAssertNotNil(run2, "it runs, with no question asked again")
        XCTAssertNil(service.disclosure)
    }

    /// Off closes MetaWhisp's own Chrome window and the connection to the user's Chrome — but only once the stopped
    /// run has returned, its tab closed by then. The user's own Chrome is never closed: only the connection to it.
    func testOffClosesTheOwnWindowAndTheConnectionOnceTheStoppedRunReturned() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.owns = true
        h.link.connect()
        let users = FakeErrandLink()
        users.connect()
        let service = h.makeService(usersLink: users)
        let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        let found = await h.runner(for: id)
        let run = try XCTUnwrap(found)
        run.returnsOnStop = false

        h.agentOn = false
        service.turnedOff()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.link.closes, 0, "not while the stopped run still closes its tab")
        XCTAssertEqual(users.disconnects, 0)
        run.finish(Self.stopped)
        await h.until({ h.link.closes == 1 && users.disconnects == 1 }, "the window and the connection to close")
        XCTAssertEqual(users.closes, 0, "the user's own Chrome is never closed")
        XCTAssertEqual(h.link.disconnects, 0)
    }

    /// The app tells its service as Settings → Agent changes — whoever wrote the setting, as for the app's other
    /// switches — and shows the disclosure from the service's own state.
    func testTheAppTellsItsServiceWhenTheAgentSettingsChangeAndShowsTheDisclosure() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../App/AppDelegate.swift").standardized
        let source = try String(contentsOf: file, encoding: .utf8)
        let observer = try XCTUnwrap(source.range(of: "NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)"))
        let off = try XCTUnwrap(source.range(of: "if !newAgentOn { Task { @MainActor in AgentService.shared.turnedOff() } }"))
        let way = try XCTUnwrap(source.range(of: "Task { @MainActor in AgentService.shared.wayChanged() }"))
        XCTAssertLessThan(observer.lowerBound, off.lowerBound, "in the settings' observer")
        XCTAssertLessThan(observer.lowerBound, way.lowerBound)
        XCTAssertNotNil(source.range(of: "AgentDisclosureController(disclosure: AgentService.shared.$disclosure"))
        XCTAssertNotNil(source.range(of: "allow: { AgentService.shared.allow() }"))
        XCTAssertNotNil(source.range(of: "notNow: { AgentService.shared.notNow() }"))
    }

    /// Off with nothing running closes them at once; on again, nothing more.
    func testOffWithNoErrandClosesAtOnce() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.owns = true
        let users = FakeErrandLink()
        let service = h.makeService(usersLink: users)
        h.agentOn = false
        service.turnedOff()
        await h.until({ h.link.closes == 1 && users.disconnects == 1 }, "the window and the connection to close")
        XCTAssertEqual(h.updates, [])
        XCTAssertEqual(users.closes, 0)
    }
}
