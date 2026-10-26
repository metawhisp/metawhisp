import XCTest
@testable import MetaWhisp

/// ITER-076 A1b — `Deadline.run` is how the agent's calls keep to their limit
/// and to Stop. Once Stop has returned, no work it guards may still find
/// itself wanted: a send that checks for Stop after that must not go out.
final class DeadlineTests: XCTestCase {

    /// One run of the race, seen from the work's thread and from the test's.
    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var stopReturned = false
        private var foundCancelled: Bool?

        func markStarted() { lock.lock(); started = true; lock.unlock() }
        var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
        func markStopReturned() { lock.lock(); stopReturned = true; lock.unlock() }
        var hasStopReturned: Bool { lock.lock(); defer { lock.unlock() }; return stopReturned }
        func record(cancelled: Bool) { lock.lock(); foundCancelled = cancelled; lock.unlock() }
        var result: Bool? { lock.lock(); defer { lock.unlock() }; return foundCancelled }

        /// Holds the work until Stop has returned, at most 2 s: a send's
        /// guard reached just after Stop.
        func waitForStop() {
            let end = Date().addingTimeInterval(2)
            while !hasStopReturned, Date() < end {}
        }
    }

    /// Waits, at most `limit`, for `condition`.
    private func until(_ condition: () -> Bool, within limit: Duration = .seconds(2)) async -> Bool {
        let end = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < end else { return false }
            await Task.yield()
        }
        return true
    }

    // MARK: - Stop

    /// Run many times: the gap this closes was a race.
    func testOnceStopHasReturnedTheWorkFindsItselfCancelled() async {
        let runs = 1_000
        var stillWanted = 0
        for _ in 0..<runs {
            let race = Race()
            let caller = Task {
                await Deadline.run(within: .seconds(30)) { () async -> Void in
                    race.markStarted()
                    race.waitForStop()
                    race.record(cancelled: Task.isCancelled)
                }
            }
            guard await until({ race.hasStarted }) else { return XCTFail("the work never started") }
            caller.cancel()
            race.markStopReturned()
            _ = await caller.value
            guard await until({ race.result != nil }) else { return XCTFail("the work never checked") }
            if race.result == false { stillWanted += 1 }
        }
        XCTAssertEqual(stillWanted, 0, "work found itself still wanted after Stop returned, in \(stillWanted) of \(runs) runs")
    }

    // MARK: - Cleanup

    /// The timer ends with the call: nothing the call returned is held until
    /// its deadline, long after the call is over.
    func testTheTimerEndsWithTheCall() async {
        final class Answer: Sendable {}
        weak var held: Answer?
        do {
            let answer = await Deadline.run(within: .seconds(60)) { Answer() }
            held = answer
            XCTAssertNotNil(held)
        }
        let end = ContinuousClock.now + .seconds(2)
        while held != nil, ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(held, "the call's result is still held by its timer")
    }

    // MARK: - Limit

    /// An unlimited limit is no limit: the call waits for its work, and the
    /// clock is never asked for a wait past what it can represent, which
    /// traps.
    func testAnUnlimitedLimitWaitsForTheWork() async {
        let value = await Deadline.run(within: .seconds(Int64.max)) { () async throws -> Int in
            try await Task.sleep(for: .milliseconds(50))
            return 42
        }
        XCTAssertEqual(value, 42)
    }

    /// A caller already stopped when the call begins starts no work at all.
    func testACallerStoppedBeforeTheCallStartsNoWork() async {
        let race = Race()
        let caller = Task { () -> Int? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await Deadline.run(within: .seconds(10)) { () async -> Int in
                race.markStarted()
                return 1
            }
        }
        let value = await caller.value
        XCTAssertNil(value)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(race.hasStarted)
    }
}
