import Combine
import XCTest
@testable import MetaWhisp

/// ITER-076 B1b, review round 1 — events go out once the service's state is
/// whole: a subscriber that calls back finds every errand where it now is.
/// And from the moment the Mac goes to sleep or the app quits, nothing starts.
@MainActor
final class AgentServiceReentryTests: XCTestCase {

    private let done = ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0)

    /// S1: Stop in answer to an errand's end finds it over — one `.finished`,
    /// its record as it ended — and the errand waiting behind it still runs.
    func testStopFromASubscriberOnAnErrandsEndChangesNothing() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let first = service.start(goal: "First errand", origin: .chat(messageID: UUID())).id!
        let second = service.start(goal: "Second errand", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: first)
        let echo = service.events.sink { update in
            if update.id == first, case .finished = update.event { service.stop(first) }
        }
        defer { echo.cancel() }

        run?.finish(done)
        _ = await h.runner(for: second)
        await h.until(second, shows: .connecting(.connected(browser: "Google Chrome")))
        XCTAssertEqual(h.events(of: first).filter(\.isFinished), [.finished(done)], "one end")
        XCTAssertEqual(h.saved(first)?.outcome, done, "the record keeps how it ended")
        XCTAssertEqual(run?.stops, 0)
        XCTAssertEqual(service.latest?.id, second, "the waiting errand is not lost")
        XCTAssertTrue(service.errandRunning)
    }

    /// Stop in answer to an errand's first event, or right after its start,
    /// comes before the errand's task runs: the browser is never asked for it.
    func testAnErrandStoppedBeforeItsTaskRunsNeverAsksTheBrowser() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let id = service.start(goal: "Stopped at once", origin: .chat(messageID: UUID())).id!
        service.stop(id)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.link.asked, 0, "no request, no Allow question for an errand that is over")
        XCTAssertEqual(h.events(of: id).last?.isFinished, true)
    }

    /// S2: an errand a subscriber asks for as the others end is refused, from
    /// the moment the Mac says it is going to sleep until it wakes.
    func testNothingStartsFromTheMomentTheMacGoesToSleepUntilItWakes() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let running = service.start(goal: "Running errand", origin: .chat(messageID: UUID())).id!
        _ = service.start(goal: "Waiting errand", origin: .chat(messageID: UUID()))
        _ = await h.runner(for: running)
        var admissions: [ErrandAdmission] = []
        let echo = service.events.sink { update in
            guard case .finished = update.event else { return }
            admissions.append(service.start(goal: "During sleep", origin: .voice(questionID: UUID())))
        }

        h.macWillSleep()
        echo.cancel()
        XCTAssertEqual(admissions, [.refused(.macAsleep), .refused(.macAsleep)])
        XCTAssertFalse(service.errandRunning)
        XCTAssertFalse(h.keepsAwake)
        XCTAssertEqual(h.runners.count, 1, "nothing ran")
        XCTAssertEqual(service.start(goal: "Still asleep", origin: .chat(messageID: UUID())), .refused(.macAsleep))
        h.macDidWake()
        XCTAssertNotNil(service.start(goal: "After the Mac woke", origin: .chat(messageID: UUID())).id,
                        "the wake ends the latch")
    }

    /// The same at quit: a wake does not end it — the exit does, or, for a
    /// quit that did not end the app, its limit (ITER-076 stage 9d, № 25).
    func testNothingStartsOnceTheAppIsQuitting() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let running = service.start(goal: "Running errand", origin: .chat(messageID: UUID())).id!
        _ = service.start(goal: "Waiting errand", origin: .chat(messageID: UUID()))
        _ = await h.runner(for: running)
        var admissions: [ErrandAdmission] = []
        let echo = service.events.sink { update in
            guard case .finished = update.event else { return }
            admissions.append(service.start(goal: "During the quit", origin: .voice(questionID: UUID())))
        }

        service.appWillQuit()
        echo.cancel()
        XCTAssertEqual(admissions, [.refused(.appQuitting), .refused(.appQuitting)])
        XCTAssertFalse(service.errandRunning)
        XCTAssertEqual(h.runners.count, 1, "nothing ran")
        h.macDidWake()
        XCTAssertEqual(service.start(goal: "Later", origin: .chat(messageID: UUID())), .refused(.appQuitting))
    }
}
