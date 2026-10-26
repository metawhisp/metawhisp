import XCTest
@testable import MetaWhisp

/// ITER-075 step 1 (1.5) — a conversation's summary is never dropped: a run
/// without access waits for access, a failed run is tried again after a pause
/// that grows, three times, and an outage gives up no one.
@MainActor
final class StructuredQueueTests: XCTestCase {

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var waits: [TimeInterval] = []
    }

    private var folder: URL!
    private var clock: Clock!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-structured-queue-\(UUID().uuidString)", isDirectory: true)
        clock = Clock()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A queue on the test clock. With `retriesItself`, its retry timer waits
    /// no real time: it moves the clock on by the pause it was asked for.
    /// Without it, the timer never fires and the test moves the clock itself.
    private func makeQueue(healthy: Bool = true, retriesItself: Bool = false,
                           route: @escaping (Bool) -> StructuredRoute? = { _ in .cloud },
                           run: @escaping (UUID, String?, Bool) async -> StructuredOutcome) -> StructuredQueue {
        let clock = self.clock!
        return StructuredQueue(directory: folder, route: route, isStoreHealthy: { healthy }, now: { clock.now },
                               sleep: { seconds in
                                   guard retriesItself else { throw CancellationError() }
                                   clock.waits.append(seconds)
                                   clock.now = clock.now.addingTimeInterval(seconds)
                               },
                               run: run)
    }

    // MARK: - Access

    func testARunWithoutAccessWaitsAndRunsOnceAccessComes() async {
        var access = false
        var runs = 0
        let queue = makeQueue(route: { _ in access ? .cloud : nil }) { _, _, _ in
            runs += 1
            return .written
        }
        let id = UUID()
        queue.enqueue([id])
        await queue.drain()
        XCTAssertEqual(queue.pending, [id], "no access: it stays")
        XCTAssertEqual(runs, 0, "and nothing runs")
        access = true
        await queue.drain()
        XCTAssertEqual(queue.pending, [], "access came: it ran and left")
        XCTAssertEqual(runs, 1)
    }

    /// Waiting for access never uses up a conversation's attempts, and starts
    /// no timer: access coming is what releases it.
    func testWaitingForAccessIsNotAFailureAndStartsNoTimer() async {
        let queue = makeQueue(route: { _ in nil }) { _, _, _ in .written }
        let id = UUID()
        queue.enqueue([id])
        for _ in 0..<10 { await queue.drain() }
        XCTAssertEqual(queue.pending, [id])
        XCTAssertNil(queue.scheduledRetry)
    }

    /// Only a conversation that closed in this session may use the local model.
    func testWithTheLocalModelAloneOnlyAFreshConversationRuns() async {
        var ran: [UUID] = []
        let queue = makeQueue(route: { mayUseLocal in mayUseLocal ? .local : nil }) { id, _, _ in
            ran.append(id)
            return .written
        }
        let older = UUID()
        let fresh = UUID()
        queue.enqueue([older])
        queue.enqueueFresh(fresh, knownTranscript: nil)
        await queue.drain()
        XCTAssertEqual(ran, [fresh])
        XCTAssertEqual(queue.pending, [older], "the older one waits for cloud access")
    }

    // MARK: - Failed runs

    func testAFailedRunWaitsItsPauseBeforeItIsTriedAgain() async {
        var runs = 0
        let queue = makeQueue { _, _, _ in
            runs += 1
            return .failed
        }
        queue.enqueue([UUID()])
        await queue.drain()
        clock.now = clock.now.addingTimeInterval(59)
        await queue.drain()
        XCTAssertEqual(runs, 1, "a minute has not passed: no retry yet")
        clock.now = clock.now.addingTimeInterval(1)
        await queue.drain()
        XCTAssertEqual(runs, 2, "the first pause is one minute")
    }

    func testThePausesGrowAndAFourthFailureLeavesTheQueue() async {
        var runs = 0
        let queue = makeQueue { _, _, _ in
            runs += 1
            return .failed
        }
        queue.enqueue([UUID()])
        await queue.drain()
        XCTAssertEqual(runs, 1)
        for (retry, pause) in StructuredQueue.retryPauses.enumerated() {
            clock.now = clock.now.addingTimeInterval(pause - 1)
            await queue.drain()
            XCTAssertEqual(runs, retry + 1, "retry \(retry + 1) waits its whole pause")
            clock.now = clock.now.addingTimeInterval(1)
            await queue.drain()
            XCTAssertEqual(runs, retry + 2)
        }
        XCTAssertEqual(queue.pending, [], "a fourth failed run leaves the queue")
        XCTAssertEqual(StructuredQueue.retryPauses, [60, 300, 1800])
        XCTAssertEqual(StructuredQueue.maxFailedRuns, 4)
    }

    /// The release of the pause: its timer runs the retry with no other
    /// trigger at all.
    func testAFailedRunIsTriedAgainAfterItsPauseWithoutAnyTrigger() async {
        var runs = 0
        let queue = makeQueue(retriesItself: true) { _, _, _ in
            runs += 1
            return runs == 1 ? .failed : .written
        }
        queue.enqueue([UUID()])
        await queue.drain()
        XCTAssertNotNil(queue.scheduledRetry, "a failed run leaves a retry behind")
        await queue.scheduledRetry?.value
        XCTAssertEqual(clock.waits, [60])
        XCTAssertEqual(runs, 2)
        XCTAssertEqual(queue.pending, [])
        XCTAssertNil(queue.scheduledRetry, "nothing is left to retry")
    }

    /// A failed run whose pause ends while there is no access waits for access
    /// with no timer: its spent date must not start a retry every instant.
    func testAFailedRunDueWithoutAccessLeavesNoTimerBehind() async {
        var access = true
        var runs = 0
        let queue = makeQueue(route: { _ in access ? .cloud : nil }) { _, _, _ in
            runs += 1
            return .failed
        }
        queue.enqueue([UUID()])
        await queue.drain()
        access = false
        clock.now = clock.now.addingTimeInterval(60)
        await queue.drain()
        XCTAssertEqual(runs, 1)
        XCTAssertNil(queue.scheduledRetry, "no retry until access comes")
        access = true
        await queue.drain()
        XCTAssertEqual(runs, 2, "access came: the retry runs")
    }

    /// A service that fails every run must not use up the whole queue's
    /// attempts at once: two failures in a row stop the pass, and the rest runs
    /// on the next one.
    func testTwoFailedRunsInARowStopThePass() async {
        var ran: [UUID] = []
        let queue = makeQueue { id, _, _ in
            ran.append(id)
            return .failed
        }
        let ids = [UUID(), UUID(), UUID()]
        queue.enqueue(ids)
        await queue.drain()
        XCTAssertEqual(ran, [ids[0], ids[1]], "the third is not charged for the same failure")
        await queue.drain()
        XCTAssertEqual(ran, ids, "the next pass reaches it; the first two wait their pause")
    }

    /// A drain stopped by two failures that both left the queue still leaves a
    /// timer for the rest: nothing waits for a close or a launch.
    func testADrainStoppedByFailuresThatLeftStillRetriesTheRest() async {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let queue = makeQueue { id, _, _ in id == c ? .written : .failed }
        queue.enqueue([a, b])
        for pause in [0, 60, 300] as [TimeInterval] {   // three failed runs each
            clock.now = clock.now.addingTimeInterval(pause)
            await queue.drain()
        }
        queue.enqueue([c])
        clock.now = clock.now.addingTimeInterval(1800)
        await queue.drain()                              // a and b fail a fourth time and leave
        XCTAssertEqual(queue.pending, [c])
        XCTAssertNotNil(queue.scheduledRetry, "c must not wait for a close or a launch")
    }

    // MARK: - Runs the cloud turned away

    /// The cloud turning runs away (no network, the key, the service
    /// unavailable) charges no conversation: the drain stops at the first, and
    /// each try after a rest is a single run.
    func testTheCloudTurningRunsAwayChargesNoOne() async {
        var ran: [UUID] = []
        let queue = makeQueue { id, _, _ in
            ran.append(id)
            return .notNow
        }
        let ids = [UUID(), UUID(), UUID()]
        queue.enqueue(ids)
        await queue.drain()
        XCTAssertEqual(ran, [ids[0]], "the others would be turned away the same way")
        for _ in 0..<10 {
            clock.now = clock.now.addingTimeInterval(1800)
            await queue.drain()
        }
        XCTAssertEqual(ran.count, 11, "one try per drain, never a burst")
        XCTAssertGreaterThan(Set(ran).count, 1, "the tries move along the queue")
        XCTAssertEqual(queue.pending.count, 3, "no conversation is given up")
        XCTAssertEqual(ids.map { queue.failedRuns(for: $0) }, [0, 0, 0])
    }

    /// The release of a turn-away: the conversation is tried again after its
    /// own pause, twice the cloud's rest, and that pause grows.
    func testATurnedAwayConversationIsTriedAgainAfterAPauseThatGrows() async {
        var calls = 0
        let queue = makeQueue(retriesItself: true) { _, _, _ in
            calls += 1
            return calls <= 2 ? .notNow : .written
        }
        queue.enqueue([UUID()])
        await queue.drain()
        await queue.scheduledRetry?.value
        await queue.scheduledRetry?.value
        XCTAssertEqual(clock.waits, [120, 600])
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(queue.pending, [])
    }

    /// While one conversation is turned away, the ones behind it go first
    /// when the cloud's rest ends: none of them waits on it.
    func testWhileOneConversationIsTurnedAwayTheOthersGoFirst() async {
        let stuck = UUID()
        let next = UUID()
        var ran: [UUID] = []
        let queue = makeQueue { id, _, _ in
            ran.append(id)
            return id == stuck ? .notNow : .written
        }
        queue.enqueue([stuck, next])
        await queue.drain()
        clock.now = clock.now.addingTimeInterval(60)
        await queue.drain()
        XCTAssertEqual(ran, [stuck, next])
        XCTAssertEqual(queue.pending, [stuck])
        XCTAssertEqual(queue.failedRuns(for: stuck), 0, "turned away is not failed")
    }

    // MARK: - Fresh conversations

    func testAFreshConversationGoesFirstAndMayUseTheLocalModel() async {
        var ran: [UUID] = []
        var mayUseLocal: [Bool] = []
        let queue = makeQueue { id, _, local in
            ran.append(id)
            mayUseLocal.append(local)
            return .written
        }
        let older = UUID()
        let fresh = UUID()
        queue.enqueue([older])
        queue.enqueueFresh(fresh, knownTranscript: nil)
        await queue.drain()
        XCTAssertEqual(ran, [fresh, older], "the conversation that just closed goes first")
        XCTAssertEqual(mayUseLocal, [true, false], "only it may use the local model")
    }

    /// The close runs its own conversation at once, and the rest afterwards.
    func testTheCloseRunsItsConversationFirstAndTheRestAfterwards() async {
        var ran: [UUID] = []
        let queue = makeQueue { id, _, _ in
            ran.append(id)
            return .written
        }
        let older = UUID()
        let closed = UUID()
        queue.enqueue([older])
        await queue.runFresh(closed, knownTranscript: "Hello there")
        XCTAssertEqual(ran, [closed], "the close waits for its own conversation only")
        XCTAssertEqual(queue.pending, [older])
        for _ in 0..<200 where !queue.pending.isEmpty { await Task.yield() }
        XCTAssertEqual(ran, [closed, older], "the rest runs on its own")
    }

    /// The close runs its conversation even while the cloud rests after an
    /// outage: the user just finished it, and one try is cheap.
    func testTheCloseRunsItsConversationWhileTheCloudRests() async {
        var ran: [UUID] = []
        let older = UUID()
        let queue = makeQueue { id, _, _ in
            ran.append(id)
            return id == older ? .notNow : .written
        }
        queue.enqueue([older])
        await queue.drain()                                  // turned away: the cloud rests
        let closed = UUID()
        await queue.runFresh(closed, knownTranscript: nil)
        XCTAssertEqual(ran, [older, closed])
    }

    /// A drain that starts while the close runs its conversation leaves that
    /// conversation to the close.
    func testADrainLeavesTheConversationTheCloseIsRunning() async {
        let older = UUID()
        let closed = UUID()
        var ran: [UUID] = []
        var queue: StructuredQueue!
        queue = makeQueue { id, _, _ in
            ran.append(id)
            if id == closed { await queue.drain() }   // a drain starts meanwhile
            return .written
        }
        queue.enqueue([older])
        await queue.runFresh(closed, knownTranscript: nil)
        XCTAssertEqual(ran, [closed, older], "the drain ran only the other one")
        XCTAssertEqual(queue.pending, [])
    }

    /// After a relaunch, a conversation left in the queue is an older one: it
    /// uses the cloud only.
    func testAfterARelaunchAFreshConversationUsesTheCloudOnly() async {
        let id = UUID()
        let before = makeQueue { _, _, _ in .notNow }
        before.enqueueFresh(id, knownTranscript: nil)
        var mayUseLocal: [Bool] = []
        let relaunched = makeQueue { _, _, local in
            mayUseLocal.append(local)
            return .written
        }
        await relaunched.drain()
        XCTAssertEqual(mayUseLocal, [false])
        XCTAssertEqual(relaunched.pending, [])
    }

    /// A conversation that closes during a drain is run in that drain.
    func testAConversationThatClosesDuringADrainIsRunInIt() async {
        let first = UUID()
        let second = UUID()
        var ran: [UUID] = []
        var queue: StructuredQueue!
        queue = makeQueue { id, _, _ in
            ran.append(id)
            if id == first { queue.enqueueFresh(second, knownTranscript: nil) }
            return .written
        }
        queue.enqueue([first])
        await queue.drain()
        XCTAssertEqual(ran, [first, second])
        XCTAssertEqual(queue.pending, [])
    }

    /// A trigger that arrives while a drain runs (a retry's timer, access, a
    /// close) makes that drain go round again for what was not due before.
    func testATriggerDuringADrainMakesItGoRoundAgain() async {
        let early = UUID()
        let late = UUID()
        var ran: [UUID] = []
        var queue: StructuredQueue!
        queue = makeQueue { id, _, _ in
            ran.append(id)
            if ran.count == 1 { return .failed }   // early fails: its pause starts
            if id == late {
                self.clock.now = self.clock.now.addingTimeInterval(60)   // the pause ends meanwhile
                await queue.drain()                // and its timer fires during this drain
            }
            return .written
        }
        queue.enqueue([early])
        await queue.drain()
        queue.enqueue([late])
        await queue.drain()
        XCTAssertEqual(ran, [early, late, early])
        XCTAssertEqual(queue.pending, [])
    }

    /// The fresh transcript goes to the first run that ran, and to no later one.
    func testTheFreshTranscriptGoesToTheFirstRunThatRanOnly() async {
        var transcripts: [String?] = []
        let queue = makeQueue(retriesItself: true) { _, transcript, _ in
            transcripts.append(transcript)
            return transcripts.count == 1 ? .failed : .written
        }
        queue.enqueueFresh(UUID(), knownTranscript: "Hello there")
        await queue.drain()
        await queue.scheduledRetry?.value
        XCTAssertEqual(transcripts, ["Hello there", nil])
    }

    /// A run the cloud turned away has not used the transcript up.
    func testARunTheCloudTurnedAwayKeepsTheFreshTranscript() async {
        var transcripts: [String?] = []
        let queue = makeQueue(retriesItself: true) { _, transcript, _ in
            transcripts.append(transcript)
            return transcripts.count == 1 ? .notNow : .written
        }
        queue.enqueueFresh(UUID(), knownTranscript: "Hello there")
        await queue.drain()
        await queue.scheduledRetry?.value
        XCTAssertEqual(transcripts, ["Hello there", "Hello there"])
    }

    // MARK: - Disk and store

    /// The queue survives a relaunch.
    func testTheQueueIsKeptOnDisk() {
        let id = UUID()
        let queue = makeQueue { _, _, _ in .notNow }
        queue.enqueue([id])
        let relaunched = makeQueue { _, _, _ in .written }
        XCTAssertEqual(relaunched.pending, [id])
    }

    /// A degraded store reads as empty, so nothing runs against it; the next
    /// launch, with the store back, runs what waited.
    func testADegradedStoreRunsNothingAndTheNextLaunchRunsIt() async {
        var runs = 0
        let id = UUID()
        let degraded = makeQueue(healthy: false) { _, _, _ in
            runs += 1
            return .unchanged
        }
        degraded.enqueue([id])
        await degraded.drain()
        XCTAssertEqual(runs, 0, "every conversation would have left the queue as not found")
        XCTAssertEqual(degraded.pending, [id])
        let healthy = makeQueue { _, _, _ in
            runs += 1
            return .written
        }
        await healthy.drain()
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(healthy.pending, [])
    }

    func testEachOutcomeMapsToWhatTheQueueDoes() {
        XCTAssertEqual(StructuredQueue.extractionOutcome(.written), .completed)
        XCTAssertEqual(StructuredQueue.extractionOutcome(.unchanged), .completed)
        XCTAssertEqual(StructuredQueue.extractionOutcome(.notNow), .retryLater)
        XCTAssertEqual(StructuredQueue.extractionOutcome(.failed), .failedAttempt)
    }
}
