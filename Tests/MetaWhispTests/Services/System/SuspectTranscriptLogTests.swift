import XCTest
@testable import MetaWhisp

/// TR-12 (ITER-046 E3) — pins the suspect log: dropped meeting text is appended
/// durably with reason+context, empty text is skipped, and the file rotates at
/// the cap instead of growing unbounded.
final class SuspectTranscriptLogTests: XCTestCase {

    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("suspectlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("suspect-transcripts.log")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAppendWritesReasonContextAndText() throws {
        SuspectTranscriptLog.write("Продолжение следует", reason: "always-hallucination", context: "Them chunk 3", to: file)
        SuspectTranscriptLog.write("second line", reason: "strip-emptied", context: "Me chunk 1 utt", to: file)
        let content = try String(contentsOf: file, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("[always-hallucination] [Them chunk 3] Продолжение следует"))
        XCTAssertTrue(lines[1].contains("[strip-emptied] [Me chunk 1 utt] second line"))
    }

    func testEmptyTextIsSkipped() {
        SuspectTranscriptLog.write("   \n", reason: "x", context: "y", to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testFileIsOwnerOnlyAfterEveryWrite() throws {
        // Pre-create with loose perms — every write must re-assert 0600 (Codex P2).
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        SuspectTranscriptLog.write("dropped speech", reason: "gate", context: "Them chunk 2", to: file)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
    }

    func testRotatesAtCap() throws {
        // Pre-fill past the cap, then one more write must rotate to .old.log.
        let big = String(repeating: "a", count: SuspectTranscriptLog.maxBytes + 1)
        try Data(big.utf8).write(to: file)
        SuspectTranscriptLog.write("after rotation", reason: "gate", context: "Them chunk 9", to: file)

        let old = file.deletingPathExtension().appendingPathExtension("old.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "oversized log must rotate")
        let fresh = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(fresh.contains("after rotation"))
        XCTAssertLessThan(fresh.count, 1_000, "fresh file must start over, not carry the old bytes")
    }
}
