import XCTest
@testable import MetaWhisp

/// The log must survive the run that filled it.
///
/// `FileLogger` emptied the file whenever it passed 1 MB at launch — which is
/// precisely the launch after a long, misbehaving run. Two days of evidence
/// about a wedged capture path (2 212 skipped screenshots, 219 refused writes,
/// three meetings that never started) were destroyed by the restart that was
/// meant to diagnose them, 2026-09-16 17:41.
///
/// One previous generation is kept. That is the difference between "it broke
/// again" and knowing what it did the first time.
final class LogRotationTests: XCTestCase {

    func testASmallLogIsAppendedTo() {
        XCTAssertEqual(FileLogger.plan(size: 0), .append)
        XCTAssertEqual(FileLogger.plan(size: FileLogger.rotateAboveBytes), .append)
    }

    func testAFullLogIsRotated() {
        XCTAssertEqual(FileLogger.plan(size: FileLogger.rotateAboveBytes + 1), .rotate)
    }

    /// The point of the whole change: rotating keeps the old run readable.
    func testRotationKeepsThePreviousRunOnDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logrot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("MetaWhisp.log")
        let previous = dir.appendingPathComponent("MetaWhisp.log.1")
        try "the run that broke".write(to: log, atomically: true, encoding: .utf8)

        FileLogger.rotate(log, to: previous)

        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "the run that broke",
                       "the evidence must outlive the restart that was meant to explain it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path),
                       "the live log starts empty")
    }

    /// Only one generation is kept — the disk is not a museum.
    func testASecondRotationReplacesTheOlderGeneration() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logrot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("MetaWhisp.log")
        let previous = dir.appendingPathComponent("MetaWhisp.log.1")
        try "first".write(to: log, atomically: true, encoding: .utf8)
        FileLogger.rotate(log, to: previous)
        try "second".write(to: log, atomically: true, encoding: .utf8)
        FileLogger.rotate(log, to: previous)

        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "second")
    }
}
