import XCTest
@testable import MetaWhisp

/// ITER-049 A1 — `StoreBackup` is the safety net that turns a silent store-open
/// failure into a recoverable one: it COPIES the unopenable store + its WAL
/// sidecars to a timestamped sibling, never touching the originals.
final class StoreBackupTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storebackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func at(_ time: TimeInterval) -> Date { Date(timeIntervalSince1970: time) }

    func testCopiesStoreAndSidecarsLeavingOriginalsUntouched() throws {
        let store = dir.appendingPathComponent("MetaWhisp.store")
        try Data("main".utf8).write(to: store)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: store.path + "-shm"))

        let backup = try XCTUnwrap(StoreBackup.preserveUnopenableStore(storeURL: store, now: at(1_700_000_000)))

        // Originals untouched — preservation must be a COPY, never a move.
        XCTAssertEqual(try String(contentsOf: store, encoding: .utf8), "main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path + "-shm"))

        // All three copied into the backup dir, content intact.
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("MetaWhisp.store"), encoding: .utf8), "main")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("MetaWhisp.store-wal"), encoding: .utf8), "wal")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("MetaWhisp.store-shm"), encoding: .utf8), "shm")

        XCTAssertTrue(backup.lastPathComponent.hasPrefix("MetaWhisp.store.unopenable-"))
    }

    func testMissingSidecarsAreFine() throws {
        let store = dir.appendingPathComponent("MetaWhisp.store")
        try Data("main".utf8).write(to: store)   // no -wal / -shm

        let backup = try XCTUnwrap(StoreBackup.preserveUnopenableStore(storeURL: store, now: at(1_700_000_000)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("MetaWhisp.store").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent("MetaWhisp.store-wal").path))
    }

    func testReturnsNilWhenNoStoreFile() {
        let missing = dir.appendingPathComponent("Missing.store")
        XCTAssertNil(StoreBackup.preserveUnopenableStore(storeURL: missing, now: at(1_700_000_000)))
    }

    func testDistinctBackupDirsForDistinctTimes() throws {
        let store = dir.appendingPathComponent("MetaWhisp.store")
        try Data("main".utf8).write(to: store)
        let b1 = try XCTUnwrap(StoreBackup.preserveUnopenableStore(storeURL: store, now: at(1_700_000_000)))
        let b2 = try XCTUnwrap(StoreBackup.preserveUnopenableStore(storeURL: store, now: at(1_700_000_061)))
        XCTAssertNotEqual(b1.lastPathComponent, b2.lastPathComponent)
    }

    /// Review finding (ITER-049 A1, P3): a present sidecar that fails to copy must
    /// NOT be reported as a complete backup — a WAL store is only consistent with
    /// its sidecars. The partial dir must be cleaned up and nil returned.
    func testPresentSidecarCopyFailureReturnsNilAndCleansUp() throws {
        let store = dir.appendingPathComponent("MetaWhisp.store")
        try Data("main".utf8).write(to: store)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))

        let fm = FailingCopyFileManager(failSubstring: "-wal")
        let backup = StoreBackup.preserveUnopenableStore(storeURL: store, now: at(1_700_000_000), fileManager: fm)

        XCTAssertNil(backup, "main copied but a present sidecar failed → must report failure, not a partial backup")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("unopenable") }
        XCTAssertTrue(leftovers.isEmpty, "partial backup dir must be removed")
        // Originals untouched regardless.
        XCTAssertEqual(try String(contentsOf: store, encoding: .utf8), "main")
    }
}

/// Test double: a FileManager whose `copyItem` throws for any path containing a
/// given substring, delegating everything else to the real implementation.
private final class FailingCopyFileManager: FileManager {
    private let failSubstring: String
    init(failSubstring: String) { self.failSubstring = failSubstring; super.init() }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent.contains(failSubstring) {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}
