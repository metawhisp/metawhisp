import Foundation

/// Outcome of a single extraction attempt, used to decide queue removal.
enum ExtractionOutcome {
    /// The conversation was processed (extracted, or definitively nothing to
    /// extract) — remove it from the queue.
    case completed
    /// Could not process now for ENVIRONMENTAL reasons (no LLM access yet,
    /// model not loaded) — keep it queued, uncounted; retry on the next
    /// enqueue / model-ready / launch.
    case retryLater
    /// The attempt RAN and failed on the content (unparseable LLM output,
    /// thrown mid-generation). Counted — ITER-051 review fix: a
    /// permanently-unparseable conversation is dropped after
    /// `ExtractionQueueStore.maxFailedAttempts`, so it can't burn a full
    /// local generation on every drain trigger forever.
    case failedAttempt
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
    /// Counted content-failures per queued id (see `ExtractionOutcome.failedAttempt`).
    private var attempts: [UUID: Int]
    static let maxFailedAttempts = 5

    /// - Parameters:
    ///   - filename: JSON file name, e.g. `"memory-extraction-queue.json"`.
    ///   - directory: override for tests; defaults to `Application Support/MetaWhisp`.
    init(filename: String, directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent(filename)
        let loaded = Self.load(from: fileURL)
        self.ids = loaded.ids
        self.attempts = loaded.attempts
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
        attempts.removeValue(forKey: id)
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
            switch await process(id) {
            case .completed:
                remove(id)
            case .retryLater:
                break   // environmental — uncounted, stays queued
            case .failedAttempt:
                let n = (attempts[id] ?? 0) + 1
                attempts[id] = n
                if n >= Self.maxFailedAttempts {
                    NSLog("[ExtractionQueue] ⚠️ dropping %@ after %d failed attempts (unparseable content)",
                          id.uuidString.prefix(8) as CVarArg, n)
                    remove(id)
                } else {
                    persist()
                }
            }
        }
    }

    // MARK: - Persistence

    /// V2 on-disk format (ids + attempt counts). V1 was a bare `[UUID]`
    /// array — `load` still accepts it so existing queues survive the update.
    private struct Persisted: Codable {
        let ids: [UUID]
        let attempts: [String: Int]
    }

    private func persist() {
        do {
            let payload = Persisted(
                ids: ids,
                attempts: Dictionary(uniqueKeysWithValues: attempts.map { ($0.key.uuidString, $0.value) })
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Make a durability failure observable instead of silently letting
            // the on-disk queue diverge (disk full / permissions / encode error).
            NSLog("[ExtractionQueue] ⚠️ failed to persist %@: %@",
                  fileURL.lastPathComponent, error.localizedDescription)
        }
    }

    private static func load(from url: URL) -> (ids: [UUID], attempts: [UUID: Int]) {
        guard let data = try? Data(contentsOf: url) else { return ([], [:]) }
        if let v2 = try? JSONDecoder().decode(Persisted.self, from: data) {
            var map: [UUID: Int] = [:]
            for (k, v) in v2.attempts { if let u = UUID(uuidString: k) { map[u] = v } }
            return (v2.ids, map)
        }
        // Legacy V1 — bare id array.
        if let v1 = try? JSONDecoder().decode([UUID].self, from: data) {
            return (v1, [:])
        }
        return ([], [:])
    }

    private static var defaultDirectory: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MetaWhisp", isDirectory: true)
    }
}
