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
        case taskSaved(UUID)        // insert or in-place edit → re-export the file
        case taskDeleted(UUID)      // hard delete → remove the vault file
        case taskDismissed(UUID)    // soft dismiss (row kept) → remove the vault file
        case memorySaved(UUID)      // insert or in-place edit → re-export
        case memoryDeleted(UUID)    // hard delete → remove the vault file
        case memoryDismissed(UUID)  // soft dismiss (row kept) → remove the vault file
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
    if !StoreHealthSignal.shared.isHealthy { NSLog("[MutationService] refused %@ — store degraded (temporary in-memory session)", String(describing: mutation)) }
        // ITER-049 A2 — refuse mutations at the owner layer in a degraded (temporary
        // in-memory) session: neither the empty-store save NOR the post-commit hooks
        // (Obsidian re-export, MCP snapshot) may fire, or the standalone MCP CLI's
        // mcp-snapshot.json and the user's vault get rewritten from empty data.
        // Reachable in degraded via the voice-question hotkey, which bypasses the
        // main-window recovery overlay.
        guard StoreHealthSignal.shared.isHealthy else { throw MutationError.storeDegraded }
        mutate()
        try save(ctx)        // PROPAGATES — never `try?`
        runHooks(mutation)   // unreachable if the save threw
        NSLog("[MutationService] committed %@", String(describing: mutation))
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
        case .taskSaved(let id):
            Task { await exporter?.exportTask(id) }
            // ITER-057.1 (Codex) — chat dismissals and completions arrive as
            // .taskSaved (status/completed flipped in-place), so this path must
            // ALSO poke the promotion loop. Safe: promoteIfNeeded is guarded
            // against re-entry, and a full slot set makes it a no-op count.
            TaskPromotionService.shared.noteSlotMaybeVacated()
        case .taskDeleted(let id),
             .taskDismissed(let id):
            Task { await exporter?.deleteTaskFile(id) }
            // ITER-057.1 — a task left the active set: a slot may have opened.
            TaskPromotionService.shared.noteSlotMaybeVacated()
        case .memorySaved(let id):   Task { await exporter?.exportMemory(id) }
        case .memoryDeleted(let id),
             .memoryDismissed(let id): Task { await exporter?.deleteMemoryFile(id) }
        }
        // MCP snapshot refreshes on every committed mutation.
        MCPSnapshotService.shared.snapshotNow()
    }
}

/// Raised by `MutationService.commit` when the persistent store is degraded
/// (temporary in-memory session) so callers don't persist into a volatile store
/// or fire external hooks. Callers already wrap `commit` in do/catch.
enum MutationError: Error {
    case storeDegraded
}
