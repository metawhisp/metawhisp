import Combine
import XCTest
@testable import MetaWhisp

/// ITER-076 B1b, review round 1 — the service's own ceiling: a run that has
/// not returned by its absolute expiry, plus a margin, is ended by the
/// service, so a run that never returns cannot hold the Mac awake and the
/// lease busy for good. Before that, it never ends an errand.
@MainActor
final class AgentServiceCeilingTests: XCTestCase {

    private let done = ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0)

    func testTheCeilingDoesNotEndAnErrandBeforeItsTime() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let first = service.start(goal: "First errand", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: first)
        XCTAssertEqual(h.timers.map(\.delay), [AgentService.ceiling], "set when the run starts")
        XCTAssertGreaterThan(AgentService.ceiling, AgentBudget.Limits.standard.expiry,
                             "never before the run's own expiry")
        XCTAssertEqual(h.events(of: first).filter(\.isFinished), [], "the errand goes on until then")
        XCTAssertTrue(h.keepsAwake)

        // The ceiling of an errand that ended leaves the next one alone.
        run?.finish(done)
        await h.until({ !service.errandRunning }, "the first errand's end")
        let second = service.start(goal: "Second errand", origin: .chat(messageID: UUID())).id!
        let next = await h.runner(for: second)
        h.fireFirstTimer(after: AgentService.ceiling)
        XCTAssertEqual(next?.stops, 0)
        XCTAssertEqual(h.events(of: second).filter(\.isFinished), [])
        XCTAssertTrue(service.errandRunning)
    }

    func testTheCeilingEndsARunThatNeverReturns() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        var states: [ActivityLease.State] = []
        let lease = ActivityLeaseTracker(pid: 4242, executable: "/Applications/Test.app/Contents/MacOS/Test",
                                         write: { states.append($0.state) })
        let feed = service.$errandRunning.sink { lease.errand(isRunning: $0) }
        defer { feed.cancel() }
        let id = service.start(goal: "Collect five sites", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: id)
        run?.returnsOnStop = false
        run?.collect(2)

        h.fireFirstTimer(after: AgentService.ceiling)
        let atCeiling = ErrandOutcome(ending: .ceiling, answer: nil,
                                      sources: [URL(string: "https://site-1.test/")!, URL(string: "https://site-2.test/")!],
                                      sheet: nil, rows: 2)
        XCTAssertEqual(h.events(of: id).last, .finished(atCeiling), "ended at a ceiling, with what it collected")
        XCTAssertEqual(run?.stops, 1, "the run is told to stop")
        XCTAssertEqual(h.saved(id)?.record.ending, .ceiling)
        XCTAssertFalse(h.keepsAwake)
        XCTAssertEqual(states.last, .idle)
    }
}
