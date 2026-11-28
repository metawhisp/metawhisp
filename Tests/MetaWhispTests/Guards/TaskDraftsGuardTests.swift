import XCTest

/// FEAT-0005 I1 / I5 — automatic tasks are drafts: the extractor writes nothing but `staged` rows, posts no
/// "task added" notice and exports nothing to the vault; the vault exporter writes tasks only.
final class TaskDraftsGuardTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        // …/Tests/MetaWhispTests/Guards/TaskDraftsGuardTests.swift → repo root
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheExtractorWritesDraftsOnly() throws {
        let code = try source("Services/Intelligence/TaskExtractor.swift")
        let makes = code.components(separatedBy: "TaskItem(").count - 1
        XCTAssertGreaterThan(makes, 0, "the extractor no longer makes rows — update the guard")
        XCTAssertEqual(code.components(separatedBy: "status: \"staged\"").count - 1, makes,
                       "every row the extractor makes is a draft")
    }

    func testTheExtractorNeitherNotifiesNorExports() throws {
        let code = try source("Services/Intelligence/TaskExtractor.swift")
        XCTAssertFalse(code.contains("postNewTask"), "no 'task added' notice for a draft")
        XCTAssertFalse(code.contains("exportTask"), "no vault file for a draft")
    }

    func testTheVaultTakesTasksOnly() throws {
        let code = try source("Services/Export/ObsidianExporter.swift")
        XCTAssertTrue(code.contains("guard task.isTask else"), "a single task export skips drafts")
        XCTAssertFalse(code.contains("where !t.isDismissed"), "the full export lists tasks, not drafts")
        XCTAssertFalse(code.contains("$0.conversationId == id && !$0.isDismissed }"), "a meeting note lists tasks only")
        XCTAssertFalse(code.contains("$0.conversationId == conv.id && !$0.isDismissed }"), "a hub lists tasks only")
        XCTAssertFalse(code.contains("$0.createdAt < dayEnd && !$0.isDismissed }\n            .sorted { $0.createdAt < $1.createdAt }\n        let taskItems"),
                       "a daily note lists tasks only")
    }
}
