import Foundation
import SwiftData

/// ITER-053.1 — retention policy for the screen-intelligence store.
///
/// History: ScreenContext (raw per-capture OCR text) and ScreenObservation
/// (hourly LLM digest) were NEVER pruned — a plaintext history of everything
/// on screen accumulated unbounded (thousands of rows/day at the 30s
/// window-change cadence). The flagship privacy promise is «локально +
/// bounded + one-click delete»; this is the bounded/one-click part.
///
/// Two INDEPENDENT windows on purpose: raw OCR is the privacy-hot artifact and
/// dies young (`screenRetentionDays`, default 30); observations are distilled,
/// low-risk and power the Rewind timeline, so they live longer
/// (`observationRetentionDays`, default 180). 0 = keep forever.
///
/// ITER-053.3 will extend both `prune` and `deleteAll` to the frame files
/// (invariant I5: retention covers pixels too — pixels without a lifespan
/// don't get written).
@MainActor
enum ScreenRetention {

    /// Oldest-allowed timestamp for a retention window. `days <= 0` = forever.
    nonisolated static func cutoff(now: Date, days: Int) -> Date? {
        guard days > 0 else { return nil }
        return now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// Delete rows past their retention window. Saves only when something was
    /// actually deleted. Returns per-table delete counts (logged by callers).
    @discardableResult
    static func prune(
        in ctx: ModelContext,
        now: Date = Date(),
        rawDays: Int,
        observationDays: Int
    ) throws -> (contexts: Int, observations: Int) {
        var contexts = 0
        var observations = 0

        // Codex review — batch delete via predicate, NEVER materialize the
        // expired rows: months of 30s OCR captures fetched with their ocrText
        // on the main actor would freeze launch. fetchCount is index-only.
        if let cut = cutoff(now: now, days: rawDays) {
            let pred = #Predicate<ScreenContext> { $0.timestamp < cut }
            contexts = try ctx.fetchCount(FetchDescriptor<ScreenContext>(predicate: pred))
            if contexts > 0 { try ctx.delete(model: ScreenContext.self, where: pred) }
        }
        if let cut = cutoff(now: now, days: observationDays) {
            let pred = #Predicate<ScreenObservation> { $0.endedAt < cut }
            observations = try ctx.fetchCount(FetchDescriptor<ScreenObservation>(predicate: pred))
            if observations > 0 { try ctx.delete(model: ScreenObservation.self, where: pred) }
        }
        if contexts + observations > 0 { try ctx.save() }
        return (contexts, observations)
    }

    /// Result of `deleteAll`. Carries the IDs of the deleted derived artifacts
    /// so the caller can run the EXTERNAL cleanup hooks (Obsidian vault files,
    /// MCP snapshot) that a batch delete bypasses — Codex review: without this,
    /// «Delete screen history» left the same screen-derived text sitting in the
    /// user's vault indefinitely.
    struct DeleteAllResult {
        let contexts: Int
        let observations: Int
        let taskIds: [UUID]
        let memoryIds: [UUID]
        var tasks: Int { taskIds.count }
        var memories: Int { memoryIds.count }
    }

    /// The one-click promise: wipe the ENTIRE screen history — both tables PLUS
    /// the unconfirmed artifacts derived from it (Codex review): staged AND
    /// dismissed screen-sourced TaskItems, and screen-sourced UserMemories,
    /// would otherwise keep resurfacing "deleted" OCR via review candidates /
    /// memory retrieval. What the user CONFIRMED stays: promoted tasks
    /// (status = committed) live their own life (I3/I4), matching the confirm
    /// dialog's wording.
    @discardableResult
    static func deleteAll(in ctx: ModelContext) throws -> DeleteAllResult {
        // OCR tables: count cheaply, batch-delete by model type — never
        // materialize (months of ocrText rows). The artifact sets below are
        // small (capped per extraction), so fetching THEM for IDs is fine.
        let contexts = try ctx.fetchCount(FetchDescriptor<ScreenContext>())
        let observations = try ctx.fetchCount(FetchDescriptor<ScreenObservation>())
        let taskPred = #Predicate<TaskItem> {
            $0.screenContextId != nil &&
            ($0.status == "staged" || $0.status == "dismissed" || $0.isDismissed)
        }
        let memoryPred = #Predicate<UserMemory> { $0.screenContextId != nil }
        let doomedTasks = try ctx.fetch(FetchDescriptor<TaskItem>(predicate: taskPred))
        let doomedMemories = try ctx.fetch(FetchDescriptor<UserMemory>(predicate: memoryPred))
        let taskIds = doomedTasks.map(\.id)
        let memoryIds = doomedMemories.map(\.id)
        if contexts > 0 { try ctx.delete(model: ScreenContext.self) }
        if observations > 0 { try ctx.delete(model: ScreenObservation.self) }
        for row in doomedTasks { ctx.delete(row) }
        for row in doomedMemories { ctx.delete(row) }
        if contexts + observations + taskIds.count + memoryIds.count > 0 { try ctx.save() }
        return DeleteAllResult(contexts: contexts, observations: observations,
                               taskIds: taskIds, memoryIds: memoryIds)
    }
}
