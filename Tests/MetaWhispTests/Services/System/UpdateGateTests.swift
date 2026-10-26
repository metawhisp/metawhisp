import XCTest
@testable import MetaWhisp

/// ITER-076 stage 9d, № 209 — an update never cuts a running errand short:
/// Sparkle's install waits for the errand's end, at most the errand's own
/// ceiling (31 minutes), and then goes; meanwhile nothing new starts and the
/// waiting errands end as not started. An update that does not happen lets
/// errands start again.
@MainActor
final class UpdateGateTests: XCTestCase {

    /// Sparkle's install handler, counted.
    @MainActor
    private final class Install {
        var calls = 0
        var handler: () -> Void { { self.calls += 1 } }
    }

    /// The gate's own timers: the errand's ceiling, which the service sets
    /// too, is not the update's.
    @MainActor
    private final class Timers {
        var set: [(delay: Duration, action: @MainActor () -> Void)] = []
        var schedule: AgentService.Schedule { { delay, action in self.set.append((delay, action)) } }

        func fire(after delay: Duration, file: StaticString = #filePath, line: UInt = #line) {
            guard let index = set.firstIndex(where: { $0.delay == delay }) else {
                return XCTFail("no timer set for \(delay)", file: file, line: line)
            }
            set.remove(at: index).action()
        }
    }

    /// The install waits while an errand runs: the errand goes on, the
    /// waiting one ends as not started, nothing new starts.
    func testTheInstallWaitsWhileAnErrandRuns() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let running = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id!
        let waiting = service.start(goal: "Find 5 recipes", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: running)
        let timers = Timers()
        let gate = UpdateGate(service: service, schedule: timers.schedule)
        let install = Install()

        XCTAssertTrue(gate.postpone(until: install.handler), "the relaunch waits")
        XCTAssertEqual(install.calls, 0)
        XCTAssertEqual(run?.stops, 0, "the errand goes on")
        XCTAssertEqual(h.events(of: waiting).last,
                       .finished(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0,
                                               notRun: .updateWaiting)))
        XCTAssertEqual(ChatService.errandEndingLine(ErrandOutcome(ending: .stopped, answer: nil, sources: [],
                                                                  sheet: nil, rows: 0, notRun: .updateWaiting)),
                       "Not started: an update is waiting.")
        XCTAssertEqual(service.start(goal: "During the update", origin: .chat(messageID: UUID())),
                       .refused(.updateWaiting))
        XCTAssertEqual(timers.set.map(\.delay), [AgentService.ceiling], "the wait has its bound")
        XCTAssertEqual(AgentService.ceiling, .seconds(31 * 60), "the errand's own: 31 minutes")
    }

    /// The errand ends: the install goes, once.
    func testTheInstallGoesOnceTheErrandEnds() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: id)
        let timers = Timers()
        let gate = UpdateGate(service: service, schedule: timers.schedule)
        let install = Install()
        XCTAssertTrue(gate.postpone(until: install.handler))

        run?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ install.calls == 1 }, "the install once the errand ended")
        timers.fire(after: AgentService.ceiling)
        XCTAssertEqual(install.calls, 1, "once")
    }

    /// An errand still running at the bound does not hold the update: the
    /// install goes anyway — and the quit stops the errand then.
    func testTheInstallGoesAnywayAfterTheBound() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: id)
        let timers = Timers()
        let gate = UpdateGate(service: service, schedule: timers.schedule)
        let install = Install()
        XCTAssertTrue(gate.postpone(until: install.handler))

        timers.fire(after: AgentService.ceiling)
        XCTAssertEqual(install.calls, 1, "the install goes at the bound")
        run?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ !service.errandRunning }, "the errand's end")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(install.calls, 1, "once")
    }

    /// No errand runs: the install goes at once, and nothing starts before
    /// the quit it brings.
    func testWithNoErrandTheInstallGoesAtOnce() {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let timers = Timers()
        let gate = UpdateGate(service: service, schedule: timers.schedule)
        let install = Install()
        XCTAssertFalse(gate.postpone(until: install.handler), "no wait")
        XCTAssertEqual(service.start(goal: "Before the quit", origin: .chat(messageID: UUID())), .refused(.updateWaiting))
    }

    /// The update does not happen after all — it failed, or it was put off:
    /// errands start again, and a wait set for it installs nothing later.
    func testAnUpdateThatDoesNotHappenLetsErrandsStartAgain() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: id)
        let timers = Timers()
        let gate = UpdateGate(service: service, schedule: timers.schedule)
        let install = Install()
        XCTAssertTrue(gate.postpone(until: install.handler))

        gate.updateEnded()
        XCTAssertNotNil(service.start(goal: "After the update gave up", origin: .chat(messageID: UUID())).id,
                        "errands start again")
        timers.fire(after: AgentService.ceiling)
        run?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(install.calls, 0, "nothing to install")
    }

    /// Sparkle asks a delegate only what it answers, by its selector
    /// (`respondsToSelector:`): a method whose Swift name nearly matches is
    /// never called.
    func testSparkleFindsWhatItAsks() {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let gate = UpdateGate(service: h.makeService())
        XCTAssertTrue(gate.responds(to: NSSelectorFromString("updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:")),
                      "the install's relaunch")
        XCTAssertTrue(gate.responds(to: NSSelectorFromString("updater:didFinishUpdateCycleForUpdateCheck:error:")),
                      "the update's end")
    }

    /// Sparkle keeps its delegate weakly: the app holds the gate itself, and
    /// gives it to the updater.
    func testTheAppHoldsTheGateAndGivesItToSparkle() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../App/AppDelegate.swift").standardized
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("private var updateGate: UpdateGate!"), "a strong owner")
        XCTAssertTrue(source.contains("updateGate = UpdateGate(service: AgentService.shared)"))
        XCTAssertTrue(source.contains("updaterDelegate: updateGate"), "the updater's delegate")
        let gate = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Services/System/UpdateGate.swift").standardized, encoding: .utf8)
        XCTAssertTrue(gate.contains("shouldPostponeRelaunchForUpdate item: SUAppcastItem,"), "Sparkle asks it")
        XCTAssertTrue(gate.contains("postpone(until: installHandler)"))
        XCTAssertTrue(gate.contains("didFinishUpdateCycleFor updateCheck: SPUUpdateCheck"))
    }
}
