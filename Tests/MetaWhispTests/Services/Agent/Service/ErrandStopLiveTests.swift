import Combine
import XCTest
@testable import MetaWhisp

/// ITER-076 I-05, review round 1 — Stop in the middle of a click, in a real
/// Chrome, through a recorded DevTools transport (`CDPProxy`): the service
/// drives the run the factory made, and the proxy holds Chrome's reply to the
/// press while the test presses Stop. Skipped without Chrome.
@MainActor
final class ErrandStopLiveTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("mw-errand-stop-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    /// Chrome behind the proxy, and the agent's hands on it.
    @MainActor
    private struct Rig {
        let chrome: TestChrome
        let proxy: CDPProxy
        let connection: CDPConnection
        let fixtures: ChromeFixtures
        let bridge: ChromeBridge

        func stop() {
            fixtures.stop()
            let connection = connection
            Task { await connection.close() }
            proxy.stop()
            chrome.quit()
        }
    }

    private func rig() async throws -> Rig {
        let chrome = try await TestChrome.launch()
        let proxy = try await CDPProxy.start(to: chrome.endpoint.webSocketURL)
        let connection = CDPConnection(url: proxy.url)
        try await connection.open()
        let fixtures = ChromeFixtures(connection: connection)
        await fixtures.start()
        let bridge = ChromeBridge(connection: connection, prepareTab: { try await fixtures.serve($0) },
                                  resolve: ChromeFixtures.resolve)
        return Rig(chrome: chrome, proxy: proxy, connection: connection, fixtures: fixtures, bridge: bridge)
    }

    private func plan() throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: "Show the details", subgoals: [.init(description: "Show the details",
                                                                            terms: ["details"])],
                                searches: [URL(string: "https://site-82.test/")!], columns: ["Name"],
                                sheetTitle: "Details", rowsWanted: 1, emptyCell: "n/a"))
    }

    /// Clicks "Show details" — a page that takes a person's click only — and
    /// is done after that.
    private nonisolated static func showDetails() -> ScriptedEngine {
        let once = FirstTime()
        return ScriptedEngine(choice: { request in
            if let show = request.candidates.first(where: { $0.action.target?.name == "Show details" }), once.take() {
                return ScriptedEngine.pick(show)
            }
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        })
    }

    private nonisolated static let press = "\"mousePressed\""
    private nonisolated static let release = "\"mouseReleased\""
    private nonisolated static let look = "JSON.stringify(observe().report)"

    /// Stop right after the press went out, before Chrome answered it: the
    /// click is in the record the service saves at Stop and in the final one,
    /// its release still goes out, and whether it took is checked.
    func testAClickStoppedAfterItsPressIsKeptAndChecked() async throws {
        let rig = try await rig()
        defer { rig.stop() }
        let factory = AgentRun.factory(planner: FixedPlanner(plan: try plan()), engine: Self.showDetails(),
                                       writer: FakeWriter(), sheet: { _ in FixtureSheet() })
        var runs: [ReturnWatch] = []
        let service = AgentService(link: FixedLink(rig.bridge), keepAwake: KeepAwake(create: { 1 }, release: { _ in }),
                                   store: ErrandRecordStore(directory: folder),
                                   notificationCenter: NotificationCenter(), isPro: { true },
                                   makeRunner: { setup in
                                       let run = ReturnWatch(factory(setup))
                                       runs.append(run)
                                       return run
                                   }, schedule: { _, _ in }, settings: .allowedForTests)
        let errand = Box<UUID>()
        let atStop = Box<ErrandRecord>()
        rig.proxy.holdsReply = { $0.contains(Self.press) }
        rig.proxy.onHeld = { release in
            Task { @MainActor in
                if let id = errand.value {
                    service.stop(id)
                    atStop.value = self.saved(id)?.record
                }
                release()
            }
        }
        errand.value = service.start(goal: "Show the details", origin: .chat(messageID: UUID())).id
        let id = try XCTUnwrap(errand.value)
        let deadline = ContinuousClock.now + .seconds(40)
        while !(runs.first?.returned ?? false), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(runs.first?.returned, true, "the run returned")

        let stopped = try XCTUnwrap(atStop.value, "the service saved the record at Stop")
        XCTAssertEqual(stopped.steps.last?.operation, "click", "the press was on its way: the click is recorded at Stop")
        let final = try XCTUnwrap(saved(id)?.record)
        let click = try XCTUnwrap(final.steps.last { $0.operation == "click" }, "and in the final record")
        XCTAssertEqual(click.outcome, .acted, "its check saw the details shown")
        XCTAssertEqual(final.ending, .stopped)

        let sent = rig.proxy.messages
        let pressed = try XCTUnwrap(sent.firstIndex { $0.contains(Self.press) })
        let released = try XCTUnwrap(sent.firstIndex { $0.contains(Self.release) }, "the release followed its press")
        XCTAssertLessThan(pressed, released)
        XCTAssertTrue(sent[released...].contains { $0.contains(Self.look) }, "the page was read again to check the click")
    }

    /// Stop bounds what follows it — the check of the click sent and the
    /// tab's close — as a whole: every reply late, each well within its own
    /// deadline, and the run still returns within Stop's limit.
    func testAfterStopTheRunReturnsWithinItsLimitHoweverSlowTheBrowser() async throws {
        let rig = try await rig()
        defer { rig.stop() }
        let run = AgentRun(plan: try plan(), errandID: UUID(),
                           collaborators: .init(bridge: rig.bridge, engine: Self.showDetails(), writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }),
                           stopLimit: .seconds(1))
        let stoppedAt = Box<ContinuousClock.Instant>()
        rig.proxy.holdsReply = { $0.contains(Self.press) }
        rig.proxy.onHeld = { release in
            Task { @MainActor in
                run.stop()
                stoppedAt.value = .now
                rig.proxy.delayReplies(by: 1.2)
                release()
            }
        }
        let outcome = await run.run(report: { _ in })
        let returned = ContinuousClock.now
        let stop = try XCTUnwrap(stoppedAt.value, "Stop was pressed at the press")
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertLessThan(returned - stop, .milliseconds(2_200), "Stop's limit, not the sum of every call's")
        // The check ended with the limit: it does not go on reading the page
        // alone. (The tab's close may: a tab is always closed.)
        let reads = rig.proxy.messages.filter { $0.contains("Runtime.evaluate") }.count
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(rig.proxy.messages.filter { $0.contains("Runtime.evaluate") }.count, reads,
                       "no read of the page after Stop's limit")
    }

    private func saved(_ id: UUID) -> ErrandRecordStore.Saved? {
        let file = ErrandRecordStore(directory: folder).fileURL(for: id)
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ErrandRecordStore.Saved.self, from: $0) }
    }
}

/// A value set from anywhere, read on the main actor.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// A run, and whether it has returned.
@MainActor
final class ReturnWatch: ErrandRunner {
    private let inner: any ErrandRunner
    private(set) var returned = false

    init(_ inner: any ErrandRunner) { self.inner = inner }

    var record: ErrandRecord { inner.record }

    func run(report: @escaping @MainActor (ErrandProgress) -> Void) async -> ErrandOutcome {
        let outcome = await inner.run(report: report)
        returned = true
        return outcome
    }

    func stop() { inner.stop() }
}
