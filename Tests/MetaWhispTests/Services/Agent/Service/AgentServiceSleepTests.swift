import Combine
import XCTest
@testable import MetaWhisp

/// ITER-076 B1, owner decision 12 of 2026-09-26 — a closed lid stops the
/// errand, and what it collected is saved: before the Mac sleeps, the running
/// errand stops with its record on disk, the waiting ones do not start, the
/// Mac is free and the lease goes idle.
@MainActor
final class AgentServiceSleepTests: XCTestCase {

    func testTheMacGoingToSleepStopsTheErrandAndSavesItsRecord() async {
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

        h.macWillSleep()
        XCTAssertEqual(run?.stops, 1, "the run is stopped")
        XCTAssertEqual(h.events(of: running).last?.isFinished, true)
        XCTAssertEqual(h.saved(running)?.record.rows.count, 2, "what it collected is on disk before the Mac sleeps")
        XCTAssertEqual(h.saved(running)?.record.ending, .stopped)
        XCTAssertEqual(h.events(of: waiting).last,
                       .finished(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0,
                                               notRun: .macSlept)),
                       "nothing starts while the Mac sleeps, and the card can tell sleep from Stop all")
        XCTAssertEqual(h.saved(waiting)?.outcome.notRun, .macSlept)
        XCTAssertEqual(h.assertionsReleased, [1])
        XCTAssertFalse(service.errandRunning)
        XCTAssertEqual(states.last, .idle)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.runners.count, 1)
    }

    func testSleepWithNoErrandDoesNothing() {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        h.macWillSleep()
        XCTAssertEqual(h.updates, [])
        XCTAssertEqual(h.assertionsMade, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.folder.path), "nothing is written")
        XCTAssertEqual(service.start(goal: "While it sleeps", origin: .chat(messageID: UUID())), .refused(.macAsleep))
        h.macDidWake()
        XCTAssertNotNil(service.start(goal: "After the Mac woke", origin: .chat(messageID: UUID())).id)
    }
}
