import XCTest
@testable import MetaWhisp

/// ITER-076 stage 8b, 8.2 — the disclosure before the first errand: an errand that starts with no Allow kept waits,
/// its browser never asked — MetaWhisp's own Chrome never started, no tab — and nothing of it shows but the
/// disclosure: no card, no line. Allow is kept for good, and this errand and the waiting ones go on. Not now is this
/// time only: this errand stopped, the waiting ones all stopped, nothing kept, and the next errand asks again. Ten
/// minutes with no answer end it as one that waited too long; Stop, Stop all, the Mac's sleep, the quit and the agent
/// turned off end it too, and keep nothing.
@MainActor
final class AgentServiceConsentTests: XCTestCase {

    private static let stopped = ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0)
    private static let allStopped = ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0,
                                                  notRun: .stoppedAll)

    /// The pair's first: with no Allow, the errand starts and waits — the browser is never asked, no run is made,
    /// nothing shows of it but the disclosure, and it says the browser it will run in.
    func testAHeldErrandDoesNotStart() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.allowed = false
        let service = h.makeService()
        let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        await h.until({ service.disclosure != nil }, "the disclosure")
        XCTAssertEqual(service.disclosure, .ownWindow, "MetaWhisp's own window: its line shows")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.link.asked, 0, "the browser is never asked: MetaWhisp's Chrome never starts")
        XCTAssertTrue(h.runners.isEmpty, "no run")
        XCTAssertEqual(h.events(of: id), [], "no card, no line")
        XCTAssertNil(h.saved(id)?.record.ending, "it has not ended")
        XCTAssertFalse(h.allowed, "nothing kept")
        XCTAssertEqual(h.timers.map(\.delay), [AgentService.consentWindow])
    }

    /// The pair's second: ten minutes with no answer end it — "Not started: it waited too long." — unreported, with
    /// nothing kept and the browser never asked.
    func testAHoldEndsAfterTenMinutes() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.allowed = false
        let service = h.makeService()
        let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        await h.until({ service.disclosure != nil }, "the disclosure")
        XCTAssertEqual(AgentService.consentWindow, .seconds(600))
        XCTAssertEqual(AgentService.consentWindow, AgentRun.pauseWindow, "the pause's window (A1)")
        h.fireFirstTimer(after: AgentService.consentWindow)
        let expired = ErrandOutcome(ending: .ceiling, answer: nil, sources: [], sheet: nil, rows: 0, notRun: .expired)
        XCTAssertEqual(h.events(of: id), [.finished(expired)])
        XCTAssertEqual(ChatService.errandEndingLine(expired), "Not started: it waited too long.")
        XCTAssertFalse(AgentService.reportedEndings.contains(expired.ending), "not reported")
        XCTAssertNil(service.disclosure, "the disclosure closes")
        XCTAssertFalse(service.errandRunning)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.link.asked, 0)
        XCTAssertFalse(h.allowed)
    }

    /// Allow: kept, the disclosure closes, the errand asks for its browser and runs — and the waiting one after it
    /// asks nothing.
    func testAllowIsKeptAndTheErrandAndTheWaitingOnesGoOn() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.allowed = false
        let service = h.makeService()
        let first = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        let second = try XCTUnwrap(service.start(goal: "Find 5 recipes", origin: .chat(messageID: UUID())).id)
        await h.until({ service.disclosure != nil }, "the disclosure")

        service.allow()
        XCTAssertTrue(h.allowed)
        XCTAssertEqual(h.allows, 1)
        XCTAssertNil(service.disclosure)
        await h.until({ h.link.waiting == 1 }, "the errand asking for its browser")
        h.link.connect()
        let run = await h.runner(for: first)
        run?.finish(ErrandOutcome(ending: .done, answer: "Ten jokes", sources: [], sheet: nil, rows: 0))
        let next = await h.runner(for: second)
        XCTAssertNotNil(next, "the waiting one runs")
        XCTAssertNil(service.disclosure, "and asks nothing")
        XCTAssertEqual(h.allows, 1)
    }

    /// Not now: this errand "Stopped.", the waiting ones "Not started: all errands were stopped.", nothing kept, the
    /// browser never asked — and the next errand asks again.
    func testNotNowStopsThisAndTheWaitingOnesKeepsNothingAndTheNextErrandAsksAgain() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.allowed = false
        let service = h.makeService()
        let held = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        let waiting = try XCTUnwrap(service.start(goal: "Find 5 recipes", origin: .voice(questionID: UUID())).id)
        await h.until({ service.disclosure != nil }, "the disclosure")

        service.notNow()
        XCTAssertEqual(h.events(of: held), [.finished(Self.stopped)])
        XCTAssertEqual(h.events(of: waiting), [.queued(position: 1), .finished(Self.allStopped)])
        XCTAssertNil(service.disclosure)
        XCTAssertFalse(h.allowed, "nothing kept")
        XCTAssertEqual(h.allows, 0)
        XCTAssertFalse(service.errandRunning)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.link.asked, 0)
        XCTAssertTrue(h.runners.isEmpty)

        let next = try XCTUnwrap(service.start(goal: "Find 3 poems", origin: .chat(messageID: UUID())).id)
        await h.until({ service.disclosure != nil }, "the disclosure, again")
        XCTAssertEqual(h.events(of: next), [])
    }

    /// Stop, Stop all, the Mac's sleep, the quit and the agent turned off each end a held errand: the disclosure
    /// closes, nothing is kept, the browser is never asked.
    func testEveryStopEndsAHoldAndKeepsNothing() async throws {
        let ends: [(String, (AgentService, AgentServiceHarness, UUID) -> Void)] = [
            ("stop", { service, _, id in service.stop(id) }),
            ("stop all", { service, _, _ in service.stopAll() }),
            ("sleep", { _, h, _ in h.macWillSleep() }),
            ("quit", { service, _, _ in service.appWillQuit() }),
            ("off", { service, h, _ in
                h.agentOn = false
                service.turnedOff()
            }),
        ]
        for (name, end) in ends {
            let h = AgentServiceHarness()
            defer { h.cleanUp() }
            h.allowed = false
            let service = h.makeService()
            let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
            await h.until({ service.disclosure != nil }, "the disclosure: \(name)")
            end(service, h, id)
            XCTAssertEqual(h.events(of: id), [.finished(Self.stopped)], name)
            XCTAssertNil(service.disclosure, name)
            XCTAssertFalse(service.errandRunning, name)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(h.link.asked, 0, name)
            XCTAssertFalse(h.allowed, name)
        }
    }

    /// An Allow that comes after the errand ended — a panel answered late — is kept, and starts nothing.
    func testAnAllowAfterTheEndIsKeptAndStartsNothing() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.allowed = false
        let service = h.makeService()
        let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        await h.until({ service.disclosure != nil }, "the disclosure")
        service.stop(id)
        service.allow()
        XCTAssertTrue(h.allowed)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.link.asked, 0)
        XCTAssertTrue(h.runners.isEmpty)
        XCTAssertEqual(h.events(of: id), [.finished(Self.stopped)])
        XCTAssertFalse(service.errandRunning)

        // Not now with no errand waiting on it does nothing.
        let other = AgentServiceHarness()
        defer { other.cleanUp() }
        other.link.connect()
        let running = other.makeService()
        let errand = try XCTUnwrap(running.start(goal: "Find 5 recipes", origin: .chat(messageID: UUID())).id)
        let run = await other.runner(for: errand)
        running.notNow()
        XCTAssertEqual(run?.stops, 0, "an errand the user allowed is not stopped by a stale Not now")
        XCTAssertTrue(running.errandRunning)
    }

    /// The app's settings (8.1, 8.2): the agent on and no Allow until the user gives it on the disclosure, kept in
    /// `AppSettings`; MetaWhisp's own window until "Use your own Chrome". Read here through the test process's own
    /// defaults, unset as on a fresh install. Each setting is put back through `AppSettings` itself — it keeps what it
    /// last wrote, and a key removed under it would not reach it — and the keys are removed after.
    func testTheAppKeepsNoAllowUntilTheUserGivesItAndTheAgentIsOnByDefault() {
        let defaults = UserDefaults.standard
        let keys = ["browserAgentOn", "browserAgentAllowed", "agentBrowser"]
        keys.forEach(defaults.removeObject(forKey:))
        let settings = AppSettings.shared
        defer {
            (settings.browserAgentOn, settings.browserAgentAllowed) = (true, false)
            settings.agentBrowser = AgentBrowser.ownWindow.rawValue
            keys.forEach(defaults.removeObject(forKey:))
        }
        let app = AgentSettings.app
        XCTAssertTrue(app.isOn(), "on by default (8.1)")
        XCTAssertFalse(app.isAllowed(), "no Allow until the user gives it (8.2)")
        XCTAssertEqual(app.way(), .ownWindow)
        app.allow()
        XCTAssertTrue(app.isAllowed())
        XCTAssertTrue(AppSettings.shared.browserAgentAllowed, "kept in the settings")
        AppSettings.shared.browserAgentOn = false
        AppSettings.shared.agentBrowser = AgentBrowser.usersChrome.rawValue
        XCTAssertFalse(app.isOn())
        XCTAssertEqual(app.way(), .usersChrome)
    }

    /// The disclosure says the browser the held errand will run in: the user's own Chrome shows no line about
    /// MetaWhisp's window.
    func testTheDisclosureSaysTheBrowserTheErrandRunsIn() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.allowed = false
        h.way = .usersChrome
        let service = h.makeService(usersLink: FakeErrandLink())
        _ = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID()))
        await h.until({ service.disclosure != nil }, "the disclosure")
        XCTAssertEqual(service.disclosure, .usersChrome)
    }
}
