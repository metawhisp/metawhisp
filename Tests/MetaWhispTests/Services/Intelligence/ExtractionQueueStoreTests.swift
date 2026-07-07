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

// MARK: - ITER-051 review fix: counted content-failures

@MainActor
final class ExtractionQueueAttemptsTests: XCTestCase {
    private func makeStore() -> (ExtractionQueueStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-attempts-\(UUID().uuidString)", isDirectory: true)
        return (ExtractionQueueStore(filename: "q.json", directory: dir), dir)
    }

    func testFailedAttemptDropsAfterCap() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        store.enqueue(id)
        for i in 1...ExtractionQueueStore.maxFailedAttempts {
            await store.drain { _ in .failedAttempt }
            if i < ExtractionQueueStore.maxFailedAttempts {
                XCTAssertEqual(store.pending(), [id], "attempt \(i): must stay queued")
            }
        }
        XCTAssertTrue(store.pending().isEmpty, "dropped after \(ExtractionQueueStore.maxFailedAttempts) content failures")
    }

    func testRetryLaterIsNotCounted() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        store.enqueue(id)
        for _ in 0..<(ExtractionQueueStore.maxFailedAttempts * 3) {
            await store.drain { _ in .retryLater }
        }
        XCTAssertEqual(store.pending(), [id], "environmental retries never drop the id")
    }

    func testLegacyV1ArrayFileStillLoads() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-v1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ids = [UUID(), UUID()]
        let data = try JSONEncoder().encode(ids)
        try data.write(to: dir.appendingPathComponent("q.json"))
        let store = ExtractionQueueStore(filename: "q.json", directory: dir)
        XCTAssertEqual(store.pending(), ids, "V1 bare-array format must load")
    }

    func testCompletedClearsAttempts() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        store.enqueue(id)
        await store.drain { _ in .failedAttempt }
        await store.drain { _ in .completed }
        XCTAssertTrue(store.pending().isEmpty)
        // Re-enqueue starts fresh — no leftover attempt count.
        store.enqueue(id)
        XCTAssertEqual(store.pending(), [id])
    }
}
