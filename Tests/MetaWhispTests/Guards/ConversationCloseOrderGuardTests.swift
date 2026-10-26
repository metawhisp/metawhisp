import XCTest

/// ITER-075 step 1 (1.5) — a closed conversation is linked to its calendar
/// event before any extractor starts (the task extractor reads the link); its
/// own summary runs next, awaited, so the Library and the recap show it first;
/// then its memories and tasks. The close waits for no other conversation's
/// summary: the rest of that queue runs on its own.
final class ConversationCloseOrderGuardTests: XCTestCase {

    private func closeSource() throws -> String {
        // …/Tests/MetaWhispTests/Guards/ConversationCloseOrderGuardTests.swift → repo root
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Services/Intelligence/ConversationGrouper.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func scheduleOnClose("),
                                  "scheduleOnClose is gone — update the guard")
        return String(source[start.upperBound...].prefix(1400))
    }

    func testTheCloseLinksThenSummarizesThenExtracts() throws {
        let body = try closeSource()
        let steps = ["await app.structuredGenerator.linkCalendar(conversationId)",
                     "await app.structuredGenerator.summarizeClosed(conversationId",
                     "app.memoryExtractor.triggerOnConversationClose",
                     "app.taskExtractor.triggerOnConversationClose"]
        var previous = body.startIndex
        for step in steps {
            let found = try XCTUnwrap(body.range(of: step), "\(step) is gone — update the guard")
            XCTAssertLessThan(previous, found.lowerBound, "\(step) is out of order")
            previous = found.lowerBound
        }
    }

    /// Every step runs in the close's own task: a step wrapped in a task of its
    /// own would no longer be waited for, and the order would be gone.
    func testNoStepRunsInATaskOfItsOwn() throws {
        XCTAssertEqual(try closeSource().components(separatedBy: "Task {").count - 1, 1,
                       "only the close's own task")
    }
}
