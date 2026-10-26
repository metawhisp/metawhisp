import XCTest
@testable import MetaWhisp

/// ITER-076 stage 3 (№ 10, 114) — the user's part, waited for: a run's pause
/// reaches the card as `.paused`, and the first Continue — from the card or
/// MetaChat, through the same call — goes back to the run. Its window, Stop,
/// the Mac's sleep, the app's quit or the run giving up end it without one;
/// a Continue that belongs to no open pause does nothing. Show tab fronts the
/// running errand's own tab, and only while it waits.
@MainActor
final class AgentServicePauseTests: XCTestCase {

    private let working = ErrandEvent.working(title: "Finding the price", done: 0, wanted: nil)
    private let signIn = ErrandHandover(kind: .signIn, host: "site-5.test")
    private let tab = BrowserTab(windowID: "target-1", tabID: "session-1")

    /// A running errand whose run has said what it is doing.
    private func runningErrand(_ h: AgentServiceHarness, _ service: AgentService) async -> (UUID, FakeErrandRunner?) {
        h.link.connect()
        let id = service.start(goal: "Find the price", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: id)
        run?.say(.working(title: "Finding the price", done: 0, wanted: nil))
        return (id, run)
    }

    /// The pause the service shows, once it does.
    private func shownPause(_ h: AgentServiceHarness, _ service: AgentService) async throws -> ErrandPause {
        await h.until({ if case .paused = service.latest?.event { true } else { false } }, "the pause")
        guard case .paused(let pause)? = service.latest?.event else { throw NoPause() }
        return pause
    }

    private struct NoPause: Error {}

    func testAPauseReachesTheCardAndTheFirstContinueGoesBackToTheRun() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        let asked = run!.pause(signIn, in: tab, window: .seconds(600))
        let pause = try await shownPause(h, service)
        XCTAssertEqual(pause.handover, signIn, "the card says what and where")

        XCTAssertTrue(service.proceed(id, after: pause))
        XCTAssertFalse(service.proceed(id, after: pause), "a second Continue does not count")
        await h.until({ asked.isAnswered }, "the answer")
        XCTAssertTrue(asked.continued, "the first Continue counts")
        XCTAssertEqual(h.events(of: id).suffix(3), [working, .paused(pause), working],
                       "once it went on, the errand shows what it was doing again")
        XCTAssertTrue(h.timers.contains { $0.delay == .seconds(600) }, "the pause's own window is set")
    }

    /// The window is the run's: never past the errand's expiry, which the run
    /// counts (`AgentRun`). The service sets the one it was given.
    func testThePausesWindowIsTheOneTheRunPassed() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (_, run) = await runningErrand(h, service)
        let asked = run!.pause(signIn, in: tab, window: .seconds(300))
        _ = try await shownPause(h, service)
        XCTAssertEqual(h.timers.filter { $0.delay == .seconds(300) }.count, 1)

        h.fireFirstTimer(after: .seconds(300))
        await h.until({ asked.isAnswered }, "the answer")
        XCTAssertFalse(asked.continued, "its window ran out: no Continue")
        XCTAssertEqual(service.latest?.event, working)
    }

    func testAContinueAfterTheWindowRanOutDoesNothing() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        let asked = run!.pause(signIn, in: tab, window: .seconds(600))
        let pause = try await shownPause(h, service)
        h.fireFirstTimer(after: .seconds(600))
        await h.until({ asked.isAnswered }, "the answer")
        let before = h.updates.count
        XCTAssertFalse(service.proceed(id, after: pause), "a late Continue does not count")
        XCTAssertEqual(h.updates.count, before)
    }

    /// Stop during a pause ends the errand within a second (stage 2, № 242)
    /// and the pause with it, without a Continue.
    func testStopDuringAPauseEndsTheErrandWithinASecond() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        let asked = run!.pause(signIn, in: tab, window: .seconds(600))
        let pause = try await shownPause(h, service)

        let pressed = ContinuousClock.now
        service.stop(id)
        await h.until({ h.events(of: id).last?.isFinished == true }, "the end")
        XCTAssertLessThan(ContinuousClock.now - pressed, .seconds(1))
        await h.until({ asked.isAnswered }, "the answer")
        XCTAssertFalse(asked.continued)
        XCTAssertEqual(run?.stops, 1)
        XCTAssertFalse(service.proceed(id, after: pause), "Continue after Stop does nothing")
        XCTAssertFalse(service.showTab(id), "nor does Show tab")
    }

    func testTheMacsSleepAndTheAppsQuitEndAPause() async throws {
        for quits in [false, true] {
            let h = AgentServiceHarness()
            let service = h.makeService()
            let (id, run) = await runningErrand(h, service)
            let asked = run!.pause(signIn, in: tab, window: .seconds(600))
            let pause = try await shownPause(h, service)
            if quits { service.appWillQuit() } else { h.macWillSleep() }
            await h.until({ asked.isAnswered }, "the answer")
            XCTAssertFalse(asked.continued, quits ? "quit" : "sleep")
            XCTAssertEqual(h.events(of: id).last?.isFinished, true)
            XCTAssertFalse(service.proceed(id, after: pause))
            h.cleanUp()
        }
    }

    /// A Continue counts only for the pause it names, of the errand that
    /// waits on it: another errand's, or an earlier pause the run gave up on,
    /// never continues the one open now.
    func testAContinueThatBelongsToNoOpenPauseDoesNothing() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        let before = h.updates.count
        XCTAssertFalse(service.proceed(id, after: ErrandPause(id: UUID(), handover: signIn)), "no pause is open")
        XCTAssertEqual(h.updates.count, before)

        let first = run!.pause(signIn, in: tab, window: .seconds(600))
        let earlier = try await shownPause(h, service)
        first.giveUp()
        await h.until({ first.isAnswered }, "the run to give up")
        await h.until({ service.latest?.event == working }, "the first pause to close")
        let second = run!.pause(ErrandHandover(kind: .captcha, host: "site-5.test"), in: tab, window: .seconds(600))
        await h.until({ service.latest?.event != working }, "the second pause")
        let now = try await shownPause(h, service)
        XCTAssertNotEqual(now, earlier)

        XCTAssertFalse(service.proceed(id, after: earlier), "an earlier pause's Continue")
        XCTAssertFalse(service.proceed(UUID(), after: now), "another errand's")
        XCTAssertFalse(second.isAnswered)
        XCTAssertTrue(service.proceed(id, after: now))
        await h.until({ second.isAnswered }, "the answer")
        XCTAssertTrue(second.continued)
    }

    /// Show tab fronts the errand's own tab — the one its run waits in — and
    /// only while it waits (№ 114).
    func testShowTabFrontsTheRunningErrandsOwnTabOnlyWhileItWaits() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        XCTAssertFalse(service.showTab(id), "no pause: nothing to show")

        let asked = run!.pause(signIn, in: tab, window: .seconds(600))
        let pause = try await shownPause(h, service)
        XCTAssertFalse(service.showTab(UUID()), "another errand's")
        XCTAssertTrue(service.showTab(id))
        await h.until({ !h.link.bridge.shown.isEmpty }, "the tab fronted")
        XCTAssertEqual(h.link.bridge.shown, [tab], "the errand's own tab, once")

        XCTAssertTrue(service.proceed(id, after: pause))
        await h.until({ asked.isAnswered }, "the answer")
        XCTAssertFalse(service.showTab(id), "the pause is over")
        XCTAssertEqual(h.link.bridge.shown, [tab])
    }

    /// A pause asked once the errand has ended never opens.
    func testAPauseAfterTheErrandEndedEndsAtOnce() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        service.stop(id)
        let asked = run!.pause(signIn, in: tab, window: .seconds(600))
        await h.until({ asked.isAnswered }, "the answer")
        XCTAssertFalse(asked.continued)
        XCTAssertFalse(h.events(of: id).contains { if case .paused = $0 { true } else { false } })
    }
}
