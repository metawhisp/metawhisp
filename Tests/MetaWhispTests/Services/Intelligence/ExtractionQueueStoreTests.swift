import XCTest
@testable import MetaWhisp

/// SB-1 (ITER-045 Iter 2) — pins the durable extraction queue that replaces the
/// silent `guard !isRunning` drop. Guarantees: nothing is dropped, the queue
/// survives a relaunch (backfill), `.retryLater` keeps work, and an id enqueued
/// mid-drain (a second conversation closing) is still processed.
@MainActor
final class ExtractionQueueStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eqstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore(_ name: String = "q.json") -> ExtractionQueueStore {
        ExtractionQueueStore(filename: name, directory: dir)
    }

    // MARK: - queue semantics

    func testEnqueueIsIdempotent() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(id)
        store.enqueue(id)
        XCTAssertEqual(store.pending(), [id])
    }

    func testEnqueuePreservesOrder() {
        let store = makeStore()
        let a = UUID(), b = UUID(), c = UUID()
        store.enqueue(a); store.enqueue(b); store.enqueue(c)
        XCTAssertEqual(store.pending(), [a, b, c])
    }

    func testRemove() {
        let store = makeStore()
        let a = UUID(), b = UUID()
        store.enqueue(a); store.enqueue(b)
        store.remove(a)
        XCTAssertEqual(store.pending(), [b])
    }

    // MARK: - durability (survives relaunch → backfill)

    func testPersistsAcrossReload() {
        let a = UUID(), b = UUID()
        do {
            let store = makeStore()
            store.enqueue(a); store.enqueue(b)
        }
        // Fresh instance on the same file == next app launch.
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.pending(), [a, b])
    }

    func testRemovePersistsAcrossReload() {
        let a = UUID(), b = UUID()
        do {
            let store = makeStore()
            store.enqueue(a); store.enqueue(b)
            store.remove(a)
        }
        XCTAssertEqual(makeStore().pending(), [b])
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertTrue(makeStore("does-not-exist.json").pending().isEmpty)
    }

    // MARK: - drain

    func testDrainProcessesAllAndRemovesCompleted() async {
        let store = makeStore()
        let ids = [UUID(), UUID(), UUID()]
        ids.forEach { store.enqueue($0) }

        var processed: [UUID] = []
        await store.drain { id in processed.append(id); return .completed }

        XCTAssertEqual(processed, ids)
        XCTAssertTrue(store.pending().isEmpty)
    }

    func testDrainKeepsRetryLaterAndPersists() async {
        let store = makeStore()
        let keep = UUID(), done = UUID()
        store.enqueue(keep); store.enqueue(done)

        await store.drain { id in id == keep ? .retryLater : .completed }

        XCTAssertEqual(store.pending(), [keep])              // kept in memory
        XCTAssertEqual(makeStore().pending(), [keep])        // and on disk
    }

    /// The core no-drop guarantee: a second conversation that closes WHILE the
    /// first is being extracted (enqueued mid-drain) is still processed.
    func testDrainPicksUpIdEnqueuedMidDrain() async {
        let store = makeStore()
        let first = UUID(), second = UUID()
        store.enqueue(first)

        var processed: [UUID] = []
        await store.drain { id in
            processed.append(id)
            if id == first { store.enqueue(second) }   // a second close arrives
            return .completed
        }

        XCTAssertEqual(processed, [first, second])
        XCTAssertTrue(store.pending().isEmpty)
    }

    /// A `.retryLater` id must not be retried again within the same pass (no
    /// tight loop / head-of-line spin).
    func testDrainAttemptsEachIdAtMostOncePerPass() async {
        let store = makeStore()
        let a = UUID(), b = UUID()
        store.enqueue(a); store.enqueue(b)

        var counts: [UUID: Int] = [:]
        await store.drain { id in counts[id, default: 0] += 1; return .retryLater }

        XCTAssertEqual(counts[a], 1)
        XCTAssertEqual(counts[b], 1)
        XCTAssertEqual(store.pending(), [a, b])   // both kept for next pass
    }
}
