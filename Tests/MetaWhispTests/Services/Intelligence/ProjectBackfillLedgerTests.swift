import XCTest
@testable import MetaWhisp

/// ITER-075 step 1 (1.6) — the project backfill checks each conversation once,
/// not at every launch; a run that got no answer is tried again.
final class ProjectBackfillLedgerTests: XCTestCase {

    private var folder: URL!
    private var url: URL { ProjectBackfillLedger.fileURL(in: folder) }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-backfill-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTheListIsAFileInTheGivenFolder() {
        XCTAssertEqual(url.deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(url.lastPathComponent, "project-backfill-checked.json")
    }

    func testAConversationWithAResultIsCheckedAndStaysCheckedAfterARelaunch() throws {
        var ledger = ProjectBackfillLedger(fileURL: url)
        let id = UUID()
        try ledger.record(id, outcome: .written)
        XCTAssertTrue(ledger.checked.contains(id))
        XCTAssertTrue(ProjectBackfillLedger(fileURL: url).checked.contains(id), "a relaunch reads it back")
    }

    func testNothingToChangeCountsAsChecked() throws {
        var ledger = ProjectBackfillLedger(fileURL: url)
        let id = UUID()
        try ledger.record(id, outcome: .unchanged)
        XCTAssertTrue(ProjectBackfillLedger(fileURL: url).checked.contains(id))
    }

    /// Codex review F10: marked only after a result; no answer means another try.
    func testARunWithNoAnswerIsNotChecked() throws {
        var ledger = ProjectBackfillLedger(fileURL: url)
        try ledger.record(UUID(), outcome: .notNow)
        try ledger.record(UUID(), outcome: .failed)
        XCTAssertTrue(ledger.checked.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing to save")
    }

    func testMarkingWithoutARunIsKept() throws {
        var ledger = ProjectBackfillLedger(fileURL: url)
        let ids = [UUID(), UUID()]
        try ledger.mark(ids)
        XCTAssertEqual(ProjectBackfillLedger(fileURL: url).checked, Set(ids))
    }

    /// An unreadable list starts empty, and is kept aside rather than overwritten.
    func testAnUnreadableListStartsEmptyAndIsKeptAside() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a list".utf8).write(to: url)
        XCTAssertTrue(ProjectBackfillLedger(fileURL: url).checked.isEmpty)
        let aside = url.appendingPathExtension("unreadable")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "not a list")
    }

    /// Two writers: a pass that loaded the list earlier keeps the marks another
    /// writer saved since (a project deleted during the pass).
    func testASaveKeepsMarksAnotherWriterAdded() throws {
        var pass = ProjectBackfillLedger(fileURL: url)
        var deletion = ProjectBackfillLedger(fileURL: url)
        let deleted = UUID()
        try deletion.mark([deleted])
        let checkedByPass = UUID()
        try pass.record(checkedByPass, outcome: .written)
        XCTAssertEqual(ProjectBackfillLedger(fileURL: url).checked, [deleted, checkedByPass])
    }

    func testPendingSkipsCheckedRowsBeforeTakingTheLimit() {
        let ids = (0..<5).map { _ in UUID() }
        let pending = ProjectBackfillLedger.pending(ids, id: { $0 }, checked: [ids[0], ids[1]], limit: 2)
        XCTAssertEqual(pending, [ids[2], ids[3]], "older unchecked rows are reached")
    }
}
