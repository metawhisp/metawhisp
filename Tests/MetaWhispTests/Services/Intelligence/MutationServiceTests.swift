import XCTest
import SwiftData
@testable import MetaWhisp

/// CC-1 (ITER-045 Iter 2) — pins MutationService's contract: a save failure
/// PROPAGATES (no silent `try?`), post-commit hooks fire ONLY after a successful
/// save, and the convenience insert/delete map to the right Obsidian/MCP hook.
@MainActor
final class MutationServiceTests: XCTestCase {

    private func makeCtx() throws -> ModelContext {
        let container = try ModelContainer(
            for: TaskItem.self, UserMemory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private struct Boom: Error {}

    // MARK: - core contract

    func testCommit_firesHooksOnSuccess() throws {
        var fired: [MutationService.Mutation] = []
        let svc = MutationService(save: { _ in }, runHooks: { fired.append($0) })
        let id = UUID()
        try svc.commit(.taskSaved(id), in: try makeCtx())
        XCTAssertEqual(fired, [.taskSaved(id)])
    }

    func testCommit_saveFailurePropagatesAndSkipsHooks() throws {
        var fired: [MutationService.Mutation] = []
        let svc = MutationService(save: { _ in throw Boom() }, runHooks: { fired.append($0) })
        XCTAssertThrowsError(try svc.commit(.memoryDeleted(UUID()), in: try makeCtx()))
        XCTAssertTrue(fired.isEmpty, "hooks must NOT fire when the save throws")
    }

    func testCommit_orderIsMutateThenSaveThenHooks() throws {
        var order: [String] = []
        let svc = MutationService(
            save: { _ in order.append("save") },
            runHooks: { _ in order.append("hook") }
        )
        try svc.commit(.taskSaved(UUID()), in: try makeCtx()) { order.append("mutate") }
        XCTAssertEqual(order, ["mutate", "save", "hook"])
    }

    func testCommit_mutateRunsEvenWhenSaveFails() throws {
        // The mutation closure runs before the (failing) save — proves we don't
        // skip the DB change, we just refuse to report success.
        var mutated = false
        let svc = MutationService(save: { _ in throw Boom() }, runHooks: { _ in })
        XCTAssertThrowsError(try svc.commit(.taskSaved(UUID()), in: try makeCtx()) { mutated = true })
        XCTAssertTrue(mutated)
    }

    // MARK: - convenience mapping

    func testInsertTask_mapsToTaskSaved() throws {
        var fired: [MutationService.Mutation] = []
        let svc = MutationService(save: { _ in }, runHooks: { fired.append($0) })
        let task = TaskItem(taskDescription: "ship it")
        try svc.insert(task, in: try makeCtx())
        XCTAssertEqual(fired, [.taskSaved(task.id)])
    }

    func testDeleteTask_mapsToTaskDeleted() throws {
        var fired: [MutationService.Mutation] = []
        let svc = MutationService(save: { _ in }, runHooks: { fired.append($0) })
        let ctx = try makeCtx()
        let task = TaskItem(taskDescription: "drop it")
        ctx.insert(task)
        let id = task.id
        try svc.hardDelete(task, in: ctx)
        XCTAssertEqual(fired, [.taskDeleted(id)])
    }

    func testInsertMemory_mapsToMemorySaved() throws {
        var fired: [MutationService.Mutation] = []
        let svc = MutationService(save: { _ in }, runHooks: { fired.append($0) })
        let mem = UserMemory(content: "likes tea", category: "preference", sourceApp: "test", confidence: 0.9)
        try svc.insert(mem, in: try makeCtx())
        XCTAssertEqual(fired, [.memorySaved(mem.id)])
    }

    func testDeleteMemory_mapsToMemoryDeleted() throws {
        var fired: [MutationService.Mutation] = []
        let svc = MutationService(save: { _ in }, runHooks: { fired.append($0) })
        let ctx = try makeCtx()
        let mem = UserMemory(content: "x", category: "fact", sourceApp: "test", confidence: 0.9)
        ctx.insert(mem)
        let id = mem.id
        try svc.hardDelete(mem, in: ctx)
        XCTAssertEqual(fired, [.memoryDeleted(id)])
    }

    func testDismissCases_flowThroughCommit() throws {
        // SB-3 — soft-dismiss cases reach the hook (which maps them to vault-file
        // deletion) without a hard ctx.delete.
        var fired: [MutationService.Mutation] = []
        let svc = MutationService(save: { _ in }, runHooks: { fired.append($0) })
        let tid = UUID(), mid = UUID()
        try svc.commit(.taskDismissed(tid), in: try makeCtx())
        try svc.commit(.memoryDismissed(mid), in: try makeCtx())
        XCTAssertEqual(fired, [.taskDismissed(tid), .memoryDismissed(mid)])
    }

    func testConvenience_saveFailureSkipsHook() throws {
        var fired: [MutationService.Mutation] = []
        let svc = MutationService(save: { _ in throw Boom() }, runHooks: { fired.append($0) })
        XCTAssertThrowsError(try svc.insert(TaskItem(taskDescription: "x"), in: try makeCtx()))
        XCTAssertTrue(fired.isEmpty)
    }
}
