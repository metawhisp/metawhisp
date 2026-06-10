import Foundation
import SwiftData

/// CC-1 — the single entry point for `TaskItem` / `UserMemory` mutations, so a DB
/// save and its external side-effects (Obsidian vault, MCP snapshot) never diverge.
///
/// Fixes the `try? ctx.save(); ok = true` pattern (e.g. ChatToolExecutor) that
/// reported success even when the commit failed. Contract:
/// - `commit(...)` **propagates** a save failure (throws). Callers must handle it —
///   never paper over it with `ok = true`.
/// - Post-commit hooks (Obsidian re-export / delete + MCP snapshot) run **only**
///   after a successful save. A hook is best-effort/logged and never flips a
///   failed mutation to success (nor a successful one to failure).
///
/// Narrow by design (Codex review): owns ONLY `TaskItem` + `UserMemory`. Daily
/// summaries stay local in `DailySummaryService` (SB-7).
@MainActor
final class MutationService {

    /// What was mutated — drives which external surfaces refresh.
    enum Mutation: Equatable {
        case taskSaved(UUID)      // insert or in-place edit
        case taskDeleted(UUID)
        case memorySaved(UUID)
        case memoryDeleted(UUID)
    }

    /// Injection seams. Production defaults below; tests substitute spies so the
    /// "propagate + hooks-only-on-success" contract is verifiable without having
    /// to force a real SwiftData failure.
    private let save: @MainActor (ModelContext) throws -> Void
    private let runHooks: @MainActor (Mutation) -> Void

    init(
        save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() },
        runHooks: @escaping @MainActor (Mutation) -> Void = MutationService.productionHooks
    ) {
        self.save = save
        self.runHooks = runHooks
    }

    /// Shared production instance (real SwiftData save + real Obsidian/MCP hooks).
    static let shared = MutationService()

    /// Core: apply `mutate` to `ctx`, commit (throws on failure), then fire the
    /// post-commit hooks only if the commit succeeded. Use the empty-`mutate`
    /// form for an in-place edit (caller already changed the object's fields).
    func commit(_ mutation: Mutation, in ctx: ModelContext, _ mutate: () -> Void = {}) throws {
        mutate()
        try save(ctx)        // PROPAGATES — never `try?`
        runHooks(mutation)   // unreachable if the save threw
    }

    // MARK: - Convenience (explicit insert / delete)

    func insert(_ task: TaskItem, in ctx: ModelContext) throws {
        try commit(.taskSaved(task.id), in: ctx) { ctx.insert(task) }
    }

    /// HARD delete — actually removes the row and the vault file. The app's normal
    /// "delete" is a SOFT dismiss (`isDismissed`/`status`), which is a `.taskSaved`
    /// field mutation, not this. Named explicitly so a dismiss path can't call it
    /// by mistake (Codex CC-1 review).
    func hardDelete(_ task: TaskItem, in ctx: ModelContext) throws {
        let id = task.id
        try commit(.taskDeleted(id), in: ctx) { ctx.delete(task) }
    }

    func insert(_ memory: UserMemory, in ctx: ModelContext) throws {
        try commit(.memorySaved(memory.id), in: ctx) { ctx.insert(memory) }
    }

    /// HARD delete — see `hardDelete(_ task:)`. Soft dismiss is a `.memorySaved`
    /// field mutation, not this.
    func hardDelete(_ memory: UserMemory, in ctx: ModelContext) throws {
        let id = memory.id
        try commit(.memoryDeleted(id), in: ctx) { ctx.delete(memory) }
    }

    // MARK: - Production hooks

    /// Default post-commit side-effects: re-export the single item to the Obsidian
    /// vault and refresh the MCP snapshot. Best-effort and async; failures here do
    /// not affect the already-committed mutation.
    static func productionHooks(_ mutation: Mutation) {
        let exporter = AppDelegate.shared?.obsidianExporter
        switch mutation {
        case .taskSaved(let id):   Task { await exporter?.exportTask(id) }
        case .taskDeleted(let id): Task { await exporter?.deleteTaskFile(id) }
        case .memorySaved(let id): Task { await exporter?.exportMemory(id) }
        case .memoryDeleted(let id):
            // SB-3 will add `ObsidianExporter.deleteMemoryFile`; until then the
            // vault file lingers (AUD-030). MCP still refreshes below.
            NSLog("[Mutation] memory %@ deleted — Obsidian file delete pending SB-3 (AUD-030)",
                  id.uuidString.prefix(8) as CVarArg)
        }
        // MCP snapshot refreshes on every committed mutation.
        MCPSnapshotService.shared.snapshotNow()
    }
}
