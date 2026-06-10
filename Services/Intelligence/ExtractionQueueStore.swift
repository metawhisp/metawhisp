import Foundation

/// Outcome of a single extraction attempt, used to decide queue removal.
enum ExtractionOutcome {
    /// The conversation was processed (extracted, or definitively nothing to
    /// extract) — remove it from the queue.
    case completed
    /// Could not process now (no LLM access yet, or a transient failure) — keep
    /// it queued and retry on the next enqueue or the next launch.
    case retryLater
}

/// SB-1 — a durable FIFO queue of conversation IDs awaiting Second-Brain
/// extraction (memories or tasks).
///
/// Replaces the old `guard !isRunning else { return }` that SILENTLY DROPPED a
/// conversation whenever an extraction was already running (two calls ending at
/// once → only the first got memories/tasks). The queue also survives app quit /
/// crash, so a conversation that was still pending is backfilled on next launch.
///
/// Persisted as a tiny JSON array of UUIDs under the app's existing
/// `Application Support/MetaWhisp` directory. Deliberately NOT SwiftData: the
/// live store has no migration plan (AUD-007), so a plain file adds zero
/// schema-migration risk.
///
/// `@MainActor` so all mutation is serialized with the extractors that own it —
/// no locking required.
@MainActor
final class ExtractionQueueStore {

    private let fileURL: URL
    private var ids: [UUID]

    /// - Parameters:
    ///   - filename: JSON file name, e.g. `"memory-extraction-queue.json"`.
    ///   - directory: override for tests; defaults to `Application Support/MetaWhisp`.
    init(filename: String, directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent(filename)
        self.ids = Self.load(from: fileURL)
    }

    /// Add a conversation to the queue. Idempotent — a conversation already
    /// queued is not duplicated (so a double close, or a backfill that re-runs,
    /// can't extract it twice).
    func enqueue(_ id: UUID) {
        guard !ids.contains(id) else { return }
        ids.append(id)
        persist()
    }

    /// Remove a conversation from the queue (after it completes).
    func remove(_ id: UUID) {
        let before = ids.count
        ids.removeAll { $0 == id }
        if ids.count != before { persist() }
    }

    /// Snapshot of currently-queued conversation IDs, in enqueue order.
    func pending() -> [UUID] { ids }

    /// Drain the queue serially: process each pending conversation **once**,
    /// removing it on `.completed` and keeping it on `.retryLater`. IDs enqueued
    /// *during* the drain are picked up in the same pass (no drop). A
    /// `.retryLater` id is left for the next enqueue / launch rather than being
    /// retried in a tight loop, so one persistently-failing conversation can't
    /// spin or block the others within a pass.
    ///
    /// Re-entrancy is the caller's responsibility (the extractors guard with
    /// their `isRunning` flag).
    func drain(_ process: (UUID) async -> ExtractionOutcome) async {
        var attempted = Set<UUID>()
        while let id = ids.first(where: { !attempted.contains($0) }) {
            attempted.insert(id)
            if case .completed = await process(id) {
                remove(id)
            }
        }
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(ids)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Make a durability failure observable instead of silently letting
            // the on-disk queue diverge (disk full / permissions / encode error).
            NSLog("[ExtractionQueue] ⚠️ failed to persist %@: %@",
                  fileURL.lastPathComponent, error.localizedDescription)
        }
    }

    private static func load(from url: URL) -> [UUID] {
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([UUID].self, from: data)
        else { return [] }
        return ids
    }

    private static var defaultDirectory: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MetaWhisp", isDirectory: true)
    }
}
