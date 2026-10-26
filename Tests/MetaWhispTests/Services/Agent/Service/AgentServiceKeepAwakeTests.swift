import Combine
import XCTest
@testable import MetaWhisp

/// ITER-076 B1 — while an errand runs the Mac stays awake and the activity
/// lease says so; both are free again after every way an errand ends.
@MainActor
final class AgentServiceKeepAwakeTests: XCTestCase {

    private let failed = ErrandOutcome(ending: .failed, answer: nil, sources: [], sheet: nil, rows: 0)

    /// A running errand, and the Mac kept awake for it.
    private func runningErrand(_ h: AgentServiceHarness, _ service: AgentService) async -> (UUID, FakeErrandRunner?) {
        h.link.connect()
        let id = service.start(goal: "Find five competitors", origin: .chat(messageID: UUID())).id!
        XCTAssertTrue(h.keepsAwake, "awake from the start")
        return (id, await h.runner(for: id))
    }

    func testTheMacIsFreeAfterAnErrandIsDone() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (_, run) = await runningErrand(h, service)
        run?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ !service.errandRunning }, "the errand's end")
        XCTAssertEqual(h.assertionsReleased, [1])
        XCTAssertFalse(h.keepsAwake)
    }

    func testTheMacIsFreeAfterStop() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, _) = await runningErrand(h, service)
        service.stop(id)
        XCTAssertEqual(h.assertionsReleased, [1], "at once")
    }

    func testTheMacIsFreeAfterARunFails() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (_, run) = await runningErrand(h, service)
        run?.finish(failed)
        await h.until({ !service.errandRunning }, "the errand's end")
        XCTAssertFalse(h.keepsAwake)
    }

    func testTheMacIsFreeWhenTheBrowserDoesNotLetTheErrandIn() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        _ = service.start(goal: "Find five competitors", origin: .chat(messageID: UUID()))
        await h.until({ h.link.waiting == 1 }, "the errand asking for the browser")
        h.link.fail(.remoteDebuggingOff)
        await h.until({ !service.errandRunning }, "the errand's end")
        XCTAssertEqual(h.assertionsMade, 1)
        XCTAssertFalse(h.keepsAwake)
    }

    /// A run cut short by the cancellation of its task still ends the
    /// errand: the Mac is free, the lease idle, and the next errand starts.
    func testARunWhoseTaskIsCancelledStillEndsTheErrandAndFreesTheMac() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        h.runsCancelTheirTask = true
        let service = h.makeService()
        let first = service.start(goal: "First errand", origin: .chat(messageID: UUID())).id!
        await h.until({ h.events(of: first).last?.isFinished == true }, "the first errand's end")
        XCTAssertEqual(h.events(of: first).last, .finished(failed))
        XCTAssertFalse(service.errandRunning)
        XCTAssertFalse(h.keepsAwake)

        h.runsCancelTheirTask = false
        let second = service.start(goal: "Second errand", origin: .chat(messageID: UUID())).id!
        _ = await h.runner(for: second)
        XCTAssertTrue(h.keepsAwake, "the next errand is kept awake again")
    }

    /// Errands back to back keep one assertion, and the lease never reads
    /// idle between them — a swap could slip in there.
    func testErrandsBackToBackKeepTheMacAwakeAndTheLeaseBusyThroughout() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        var states: [ActivityLease.State] = []
        let lease = ActivityLeaseTracker(pid: 4242, executable: "/Applications/Test.app/Contents/MacOS/Test",
                                         write: { states.append($0.state) })
        // As the app feeds it.
        let feed = service.$errandRunning.sink { lease.errand(isRunning: $0) }
        defer { feed.cancel() }

        let first = service.start(goal: "First errand", origin: .chat(messageID: UUID())).id!
        let second = service.start(goal: "Second errand", origin: .chat(messageID: UUID())).id!
        await h.runner(for: first)?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        let run = await h.runner(for: second)
        XCTAssertEqual(h.assertionsMade, 1, "one assertion for both")
        XCTAssertTrue(h.keepsAwake)
        run?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ !service.errandRunning }, "the second errand's end")
        XCTAssertEqual(h.assertionsReleased, [1])
        XCTAssertEqual(states, [.idle, .errand, .idle], "errand while they run, idle after")
    }
}
