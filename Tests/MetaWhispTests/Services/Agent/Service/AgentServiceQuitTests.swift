import Combine
import XCTest
@testable import MetaWhisp

/// ITER-076 B1, ITER-074 §11 — quitting the app mid-errand is Stop: before the
/// app exits, the running errand stops with its record on disk, the waiting
/// ones are recorded as not started, the Mac is free and the lease idle.
@MainActor
final class AgentServiceQuitTests: XCTestCase {

    func testQuittingStopsTheErrandAndSavesEverythingBeforeTheAppExits() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        var states: [ActivityLease.State] = []
        let lease = ActivityLeaseTracker(pid: 4242, executable: "/Applications/Test.app/Contents/MacOS/Test",
                                         write: { states.append($0.state) })
        let feed = service.$errandRunning.sink { lease.errand(isRunning: $0) }
        defer { feed.cancel() }
        let running = service.start(goal: "Collect five sites", origin: .chat(messageID: UUID())).id!
        let waiting = service.start(goal: "Collect three more", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: running)
        run?.collect(2)

        service.appWillQuit()
        // All of it before the call returns: the app exits right after.
        XCTAssertEqual(run?.stops, 1, "the run is stopped")
        XCTAssertEqual(h.saved(running)?.record.rows.count, 2, "what it collected is on disk")
        XCTAssertEqual(h.saved(running)?.record.ending, .stopped)
        XCTAssertEqual(h.saved(waiting)?.outcome,
                       ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0, notRun: .appQuit),
                       "the waiting one is recorded as not started, and why")
        XCTAssertEqual(h.assertionsReleased, [1])
        XCTAssertFalse(service.errandRunning)
        XCTAssertEqual(states.last, .idle)
    }

    func testQuittingWithNoErrandDoesNothing() {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        XCTAssertNil(service.appWillQuit(), "nothing to wait for")
        XCTAssertEqual(h.updates, [])
        XCTAssertEqual(h.assertionsMade, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.folder.path), "nothing is written")
    }

    /// ITER-076 stage 9d, № 20 — the quit hands the app what to wait for: the
    /// stopped run's return, by which its tab is closed — or Stop's limit is
    /// over. With no meeting the app used to exit at once, the tab still open.
    func testTheQuitHandsBackTheStoppedRunsReturn() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id!
        let found = await h.runner(for: id)
        let run = try XCTUnwrap(found)
        run.returnsOnStop = false

        let returned = try XCTUnwrap(service.appWillQuit(), "a run to wait for")
        XCTAssertEqual(run.stops, 1, "the run is stopped at once")
        XCTAssertEqual(h.saved(id)?.record.ending, .stopped, "and its record is on disk")
        let waited = Box<Bool>()
        Task { await returned.value; waited.value = true }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(waited.value, "the run is still closing its tab")
        run.finish(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ waited.value == true }, "the wait to end once the run returned")
    }

    /// A run Stop ended a moment before the quit may still be closing its
    /// tab: the quit waits for it too.
    func testTheQuitAlsoWaitsForARunStoppedJustBeforeIt() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id!
        let found = await h.runner(for: id)
        let run = try XCTUnwrap(found)
        run.returnsOnStop = false
        service.stop(id)
        XCTAssertFalse(service.errandRunning, "the errand ended")

        let returned = try XCTUnwrap(service.appWillQuit(), "its run has not returned")
        let waited = Box<Bool>()
        Task { await returned.value; waited.value = true }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(waited.value)
        run.finish(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ waited.value == true }, "the wait to end once the run returned")
    }

    /// ITER-076 stage 9d, № 25 — nothing starts while the app quits: not
    /// while the stopped run closes its tab, not once it returned, not after
    /// the Mac woke. The latch's release is set past the longest the quit can
    /// wait — Stop's limit — so no errand starts during a quit.
    func testTheQuitLatchHoldsWhileTheQuitLasts() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id!
        let found = await h.runner(for: id)
        let run = try XCTUnwrap(found)
        run.returnsOnStop = false

        let returned = try XCTUnwrap(service.appWillQuit())
        XCTAssertEqual(service.start(goal: "While the tab closes", origin: .chat(messageID: UUID())),
                       .refused(.appQuitting))
        run.finish(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0))
        await returned.value
        XCTAssertEqual(service.start(goal: "Once the run returned", origin: .chat(messageID: UUID())),
                       .refused(.appQuitting))
        h.macDidWake()
        XCTAssertEqual(service.start(goal: "After a wake", origin: .voice(questionID: UUID())), .refused(.appQuitting))
        XCTAssertEqual(h.timers.map(\.delay).filter { $0 == AgentService.quitLimit }.count, 1,
                       "the latch's release is set")
        XCTAssertGreaterThan(AgentService.quitLimit, AgentRun.stopLimit, "past the longest the quit waits")
        XCTAssertEqual(h.runners.count, 1, "nothing ran")
    }

    /// ITER-076 stage 9d, № 25 — a quit that did not end the app by its
    /// limit was cancelled: errands start again, rather than stay refused
    /// until the app is opened again. An earlier quit's release never lifts a
    /// later quit's latch.
    func testTheQuitLatchIsReleasedAfterACancelledQuit() {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        service.appWillQuit()
        XCTAssertEqual(service.start(goal: "During the quit", origin: .chat(messageID: UUID())), .refused(.appQuitting))
        h.fireFirstTimer(after: AgentService.quitLimit)
        XCTAssertNotNil(service.start(goal: "After the quit was cancelled", origin: .chat(messageID: UUID())).id,
                        "errands start again")
        service.stopAll()

        service.appWillQuit()
        service.appWillQuit()
        h.fireFirstTimer(after: AgentService.quitLimit)
        XCTAssertEqual(service.start(goal: "During the last quit", origin: .chat(messageID: UUID())),
                       .refused(.appQuitting), "an earlier quit's release is not the last quit's")
        h.fireFirstTimer(after: AgentService.quitLimit)
        XCTAssertNotNil(service.start(goal: "After it too was cancelled", origin: .chat(messageID: UUID())).id)
    }

    /// The app stops errands as soon as it is asked to quit — before the
    /// meeting rescue, which can keep the app up a while, and so before the
    /// lease's last write.
    func testTheAppStopsErrandsFirstWhenItQuits() throws {
        let body = try Self.quitBody()
        let stop = try XCTUnwrap(body.range(of: "AgentService.shared.appWillQuit()"), "the quit stops errands")
        let rescue = try XCTUnwrap(body.range(of: "MeetingShutdown.plan("))
        XCTAssertLessThan(stop.lowerBound, rescue.lowerBound, "before the meeting rescue")
    }

    /// ITER-076 stage 9d, № 20 — the app waits for the stopped runs before it
    /// exits, in one answer with the meeting rescue: what `appWillQuit` hands
    /// back is waited for within Stop's limit, and the quit is answered once,
    /// by the quit's reply — never at once past it.
    func testTheAppWaitsForTheStoppedRunsBeforeItQuits() throws {
        let body = try Self.quitBody()
        XCTAssertTrue(body.contains("= AgentService.shared.appWillQuit()"), "what the service hands back is kept")
        XCTAssertTrue(body.contains(".wait(within: AgentRun.stopLimit)"), "and waited for, within Stop's limit")
        XCTAssertEqual(body.components(separatedBy: "reply(toApplicationShouldTerminate:").count - 1, 1, "one answer")
        XCTAssertFalse(body.contains(".terminateNow"), "the quit's reply says now or later")
    }

    /// `applicationShouldTerminate`'s body.
    private static func quitBody() throws -> Substring {
        // …/Tests/MetaWhispTests/Services/Agent/Service/AgentServiceQuitTests.swift → repo root
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../App/AppDelegate.swift").standardized
        let source = try String(contentsOf: file, encoding: .utf8)
        let declaration = try XCTUnwrap(source.range(of: "func applicationShouldTerminate("))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: declaration.upperBound..<source.endIndex))
        return source[declaration.upperBound..<end.lowerBound]
    }
}
