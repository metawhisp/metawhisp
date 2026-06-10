import XCTest
import SwiftData
@testable import MetaWhisp

/// SB-2 (ITER-045 Iter 2) — ChatToolExecutor mutations route through MutationService,
/// so a failed DB save is reported to chat as a failure (`ok == false`) instead of
/// the old `try? ctx.save(); ok = true` that claimed success regardless.
@MainActor
final class ChatToolExecutorSB2Tests: XCTestCase {

    private struct Boom: Error {}

    /// Build an executor on an in-memory store. `failing` injects a MutationService
    /// whose save always throws; otherwise a real save with no-op (silent) hooks so
    /// tests don't touch the Obsidian vault / MCP snapshot on disk.
    private func makeExecutor(failing: Bool) throws -> (ChatToolExecutor, ModelContext) {
        let container = try ModelContainer(
            for: TaskItem.self, UserMemory.self, Goal.self, AuditLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let exec = ChatToolExecutor()
        exec.configure(modelContainer: container)
        exec.mutationService = failing
            ? MutationService(save: { _ in throw Boom() }, runHooks: { _ in })
            : MutationService(runHooks: { _ in })
        return (exec, ModelContext(container))
    }

    func testAddTask_success() throws {
        let (exec, _) = try makeExecutor(failing: false)
        let r = exec.execute(ChatToolExecutor.ToolCall(id: nil, tool: "addTask",
                                                       args: ["description": "buy milk"]))
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.summary.contains("buy milk"))
    }

    func testAddTask_saveFailureIsReported() throws {
        let (exec, _) = try makeExecutor(failing: true)
        let r = exec.execute(ChatToolExecutor.ToolCall(id: nil, tool: "addTask",
                                                       args: ["description": "buy milk"]))
        XCTAssertFalse(r.ok, "a failed save must NOT report success to chat")
        XCTAssertTrue(r.summary.lowercased().contains("couldn't save"), "chat should see the real error")
    }

    func testDismissTask_saveFailureIsReported() throws {
        let (exec, ctx) = try makeExecutor(failing: true)
        let task = TaskItem(taskDescription: "stale task")
        ctx.insert(task)
        try ctx.save()
        let r = exec.execute(ChatToolExecutor.ToolCall(id: nil, tool: "dismissTask",
                                                       args: ["id": task.id.uuidString]))
        XCTAssertFalse(r.ok)
    }

    func testCompleteTask_success() throws {
        let (exec, ctx) = try makeExecutor(failing: false)
        let task = TaskItem(taskDescription: "finish report")
        ctx.insert(task)
        try ctx.save()
        let r = exec.execute(ChatToolExecutor.ToolCall(id: nil, tool: "completeTask",
                                                       args: ["id": task.id.uuidString]))
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.summary.contains("finish report"))
    }
}
