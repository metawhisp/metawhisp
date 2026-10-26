import XCTest
@testable import MetaWhisp

/// Errands take turns (ITER-074 §8, §11, US-8): one runs, at most three wait,
/// a waiting one is dropped thirty minutes after it was queued, and nothing
/// new starts while an update waits.
final class AgentQueueTests: XCTestCase {

    private let start = ContinuousClock.now

    private func errand(_ goal: String, queuedAfter offset: Duration = .zero) -> AgentQueue.Errand {
        AgentQueue.Errand(id: UUID(), goal: goal, queuedAt: start.advanced(by: offset))
    }

    func testTheFirstErrandStarts() {
        var queue = AgentQueue()
        let first = errand("first")
        XCTAssertEqual(queue.submit(first, now: start).admission, .started)
        XCTAssertEqual(queue.running, first)
    }

    /// US-8: a second errand waits — the card says so — and starts when the
    /// first one ends.
    func testASecondErrandWaitsAndStartsWhenTheFirstEnds() {
        var queue = AgentQueue()
        _ = queue.submit(errand("first"), now: start)
        let second = errand("second")
        XCTAssertEqual(queue.submit(second, now: start).admission, .queued(position: 1))
        XCTAssertEqual(queue.finishRunning(now: start.advanced(by: .seconds(60))).started, second)
        XCTAssertEqual(queue.running, second)
        XCTAssertTrue(queue.waiting.isEmpty)
    }

    func testAtMostThreeWaitAndAFourthIsRefused() {
        var queue = AgentQueue()
        _ = queue.submit(errand("running"), now: start)
        for position in 1...3 {
            XCTAssertEqual(queue.submit(errand("waiting \(position)"), now: start).admission,
                           .queued(position: position))
        }
        XCTAssertEqual(queue.submit(errand("fourth"), now: start).admission, .refused(.queueFull))
        XCTAssertEqual(queue.waiting.count, 3)
    }

    func testErrandsStartInTheOrderTheyWereAskedFor() {
        var queue = AgentQueue()
        _ = queue.submit(errand("running"), now: start)
        let waiting = ["A", "B", "C"].map { errand($0) }
        for item in waiting { _ = queue.submit(item, now: start) }
        let order = (0..<3).compactMap { _ in queue.finishRunning(now: start).started }
        XCTAssertEqual(order, waiting)
        XCTAssertNil(queue.finishRunning(now: start).started)
        XCTAssertNil(queue.running)
    }

    /// A waiting errand that has not started within thirty minutes of being
    /// queued is dropped, and the card says which (§8).
    func testAWaitingErrandExpiresAfterThirtyMinutes() {
        var queue = AgentQueue()
        _ = queue.submit(errand("running"), now: start)
        let early = errand("early")
        let late = errand("late", queuedAfter: .seconds(1))
        _ = queue.submit(early, now: start)
        _ = queue.submit(late, now: start.advanced(by: .seconds(1)))
        let next = queue.finishRunning(now: start.advanced(by: .seconds(1_800)))
        XCTAssertEqual(next.notStarted, [AgentQueue.NotStarted(errand: early, reason: .expired)])
        XCTAssertEqual(next.started, late, "queued 29:59 ago, it still starts")
    }

    func testAnExpiredErrandFreesItsPlace() {
        var queue = AgentQueue()
        _ = queue.submit(errand("running"), now: start)
        for index in 0..<3 { _ = queue.submit(errand("old \(index)"), now: start) }
        let later = start.advanced(by: .seconds(1_800))
        let result = queue.submit(errand("new", queuedAfter: .seconds(1_800)), now: later)
        XCTAssertEqual(result.admission, .queued(position: 1))
        XCTAssertEqual(result.notStarted.map(\.reason), [.expired, .expired, .expired])
    }

    /// Stop all ends the waiting errands too; the running one is stopped by
    /// its run, and then nothing starts (US-5).
    func testStopAllClearsTheQueue() {
        var queue = AgentQueue()
        _ = queue.submit(errand("running"), now: start)
        let waiting = errand("waiting")
        _ = queue.submit(waiting, now: start)
        XCTAssertEqual(queue.stopAll(), [AgentQueue.NotStarted(errand: waiting, reason: .stoppedAll)])
        XCTAssertNil(queue.finishRunning(now: start).started)
        XCTAssertNil(queue.running)
    }

    /// Stop on one waiting errand (ITER-076 B1): it leaves the queue, the
    /// others keep their order, and its place is free.
    func testRemoveTakesOutOneWaitingErrand() {
        var queue = AgentQueue()
        let running = errand("running")
        _ = queue.submit(running, now: start)
        let waiting = ["A", "B", "C"].map { errand($0) }
        for item in waiting { _ = queue.submit(item, now: start) }
        XCTAssertEqual(queue.remove(waiting[1].id), waiting[1])
        XCTAssertEqual(queue.waiting, [waiting[0], waiting[2]])
        XCTAssertEqual(queue.running, running)
        XCTAssertEqual(queue.submit(errand("D"), now: start).admission, .queued(position: 3), "its place is free")
    }

    /// The running errand is stopped by its run, not taken out here.
    func testRemoveLeavesTheRunningErrandAndUnknownIdsAlone() {
        var queue = AgentQueue()
        let running = errand("running")
        _ = queue.submit(running, now: start)
        let waiting = errand("waiting")
        _ = queue.submit(waiting, now: start)
        XCTAssertNil(queue.remove(running.id))
        XCTAssertNil(queue.remove(UUID()))
        XCTAssertEqual(queue.running, running)
        XCTAssertEqual(queue.waiting, [waiting])
        XCTAssertEqual(queue.remove(waiting.id), waiting)
        XCTAssertNil(queue.remove(waiting.id), "a second remove finds nothing")
    }

    /// An update is ready: the running errand finishes, nothing new starts,
    /// and the waiting ones are recorded as not started (§11).
    func testAnUpdateLetsTheRunningErrandFinishAndStartsNothingNew() {
        var queue = AgentQueue()
        let running = errand("running")
        _ = queue.submit(running, now: start)
        let waiting = errand("waiting")
        _ = queue.submit(waiting, now: start)
        XCTAssertEqual(queue.updateIsReady(), [AgentQueue.NotStarted(errand: waiting, reason: .updateWaiting)])
        XCTAssertEqual(queue.running, running)
        XCTAssertEqual(queue.submit(errand("new"), now: start).admission, .refused(.updateWaiting))
        XCTAssertNil(queue.finishRunning(now: start).started)
    }

    /// The freeze has a release: if the update does not happen after all,
    /// errands start again.
    func testErrandsStartAgainOnceTheUpdateIsWithdrawn() {
        var queue = AgentQueue()
        _ = queue.updateIsReady()
        XCTAssertEqual(queue.submit(errand("blocked"), now: start).admission, .refused(.updateWaiting))
        queue.updateWithdrawn()
        XCTAssertEqual(queue.submit(errand("after"), now: start).admission, .started)
    }
}
