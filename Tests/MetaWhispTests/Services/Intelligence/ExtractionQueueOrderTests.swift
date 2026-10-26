import XCTest
@testable import MetaWhisp

/// ITER-075 step 1 (1.5) — what the summary queue needs from the queue store:
/// a conversation that just closed goes first, a sweep queues hundreds with one
/// write and says when the write failed, the failed runs are counted per id,
/// and a queue can set its own failure limit. The memory and task queues keep
/// the default of five.
@MainActor
final class ExtractionQueueOrderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eqorder-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir.path))
    }

    private func makeStore(limit: Int = ExtractionQueueStore.maxFailedAttempts) -> ExtractionQueueStore {
        ExtractionQueueStore(filename: "q.json", directory: dir, maxFailedAttempts: limit)
    }

    func testEnqueueFirstPutsAnIdAtTheFrontAndMovesOneAlreadyQueued() {
        let store = makeStore()
        let a = UUID(), b = UUID(), c = UUID()
        store.enqueue(a); store.enqueue(b)
        store.enqueueFirst(c)
        XCTAssertEqual(store.pending(), [c, a, b])
        store.enqueueFirst(b)
        XCTAssertEqual(store.pending(), [b, c, a])
        XCTAssertEqual(makeStore().pending(), [b, c, a], "kept on disk")
    }

    func testEnqueueContentsOfKeepsTheOrderAndSkipsWhatIsQueued() {
        let store = makeStore()
        let a = UUID(), b = UUID(), c = UUID()
        store.enqueue(b)
        XCTAssertTrue(store.enqueue(contentsOf: [a, b, c, a]))
        XCTAssertEqual(store.pending(), [b, a, c])
        XCTAssertEqual(makeStore().pending(), [b, a, c], "kept on disk")
    }

    func testEnqueueContentsOfSaysWhenTheQueueCouldNotBeWritten() throws {
        try Data().write(to: URL(fileURLWithPath: dir.path))   // a plain file where the folder should be
        let store = makeStore()
        XCTAssertFalse(store.enqueue(contentsOf: [UUID()]))
        XCTAssertTrue(store.enqueue(contentsOf: []), "nothing to add, nothing to write")
    }

    /// A caller that learns only later how a run went records it like a drain.
    func testRecordCountsAFailureOnlyForAnIdStillQueued() {
        let store = makeStore(limit: 2)
        let id = UUID()
        store.enqueue(id)
        store.record(id, .failedAttempt)
        XCTAssertEqual(store.failedAttempts(for: id), 1)
        store.record(UUID(), .failedAttempt)
        XCTAssertEqual(store.pending(), [id], "an id no longer queued is left alone")
        store.record(id, .failedAttempt)
        XCTAssertEqual(store.pending(), [], "its own limit, as in a drain")
    }

    func testFailedRunsAreCountedPerId() async {
        let store = makeStore()
        let a = UUID(), b = UUID()
        store.enqueue(a); store.enqueue(b)
        await store.drain { $0 == a ? .failedAttempt : .retryLater }
        XCTAssertEqual(store.failedAttempts(for: a), 1)
        XCTAssertEqual(store.failedAttempts(for: b), 0)
    }

    func testAQueueCanSetItsOwnFailureLimit() async {
        let store = makeStore(limit: 2)
        let id = UUID()
        store.enqueue(id)
        await store.drain { _ in .failedAttempt }
        XCTAssertEqual(store.pending(), [id])
        await store.drain { _ in .failedAttempt }
        XCTAssertEqual(store.pending(), [], "its own limit, not the default five")
    }

    func testTheDefaultLimitStaysFive() {
        XCTAssertEqual(ExtractionQueueStore.maxFailedAttempts, 5)
    }
}
