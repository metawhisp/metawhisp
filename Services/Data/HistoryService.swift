import Foundation
import SwiftData
import os

/// Manages persistent transcription history via SwiftData.
@MainActor
final class HistoryService: ObservableObject {
    private static let log = Logger(subsystem: "com.metawhisp.app", category: "History")

    let modelContainer: ModelContainer

    /// AUD-007 / ITER-049 A1 — `.degraded` when the on-disk store couldn't open.
    /// The UI surfaces a blocking recovery overlay instead of the app silently
    /// running on a throwaway in-memory store.
    @Published private(set) var health: StoreHealth = .healthy

    /// Where SwiftData puts the named `"MetaWhisp"` store. Used only to preserve
    /// the file on a failed open — never to bypass SwiftData's own pathing.
    private static var storeURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MetaWhisp.store")
    }

    init() {
        do {
            // ITER-049 B — versioned schema + migration plan (AUD-007).
            // ITER-053.4 — live shape is V2 (adds ScreenObservation.embedding);
            // existing V1 stores migrate through the plan's lightweight stage.
            let schema = Schema(versionedSchema: MetaWhispSchemaV2.self)
            let config = ModelConfiguration("MetaWhisp", schema: schema)
            modelContainer = try ModelContainer(
                for: schema, migrationPlan: MetaWhispMigrationPlan.self, configurations: [config])
            Self.log.info("History database ready")
        } catch {
            // AUD-007 / ITER-049 A1 — do NOT silently bypass the user's data.
            // Preserve the on-disk store (a copy; originals untouched) and flag
            // degraded so the UI warns this is a non-persisting temporary session.
            Self.log.error("Failed to open persistent store: \(error)")
            let backupPath = Self.storeURL.flatMap {
                StoreBackup.preserveUnopenableStore(storeURL: $0, now: Date())?.path
            }
            health = .degraded(reason: (error as NSError).localizedDescription, backupPath: backupPath)
            StoreHealthSignal.shared.set(healthy: false)   // ITER-049 A2 — reachable by singleton hooks
            Self.log.error("Store DEGRADED — running a temporary in-memory session; original store preserved")
            do {
                modelContainer = try ModelContainer(
                    for: HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self, TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self, IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self, AuditLog.self, PatternDigest.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            } catch {
                Self.log.error("In-memory fallback also failed: \(error)")
                fatalError("Cannot create any ModelContainer — app cannot function without data storage")
            }
        }
    }

    /// Save a transcription result to history. Returns the item for further modification.
    @discardableResult
    func save(_ result: TranscriptionResult) -> HistoryItem? {
        // ITER-049 A2 — in a degraded (temporary in-memory) session don't fake a
        // persistent save; the dictation paste already happened, history just
        // can't be kept until the store is recovered.
        guard health.isHealthy else {
            Self.log.error("Store degraded — skipping history save (temporary session)")
            return nil
        }
        let context = modelContainer.mainContext
        let item = HistoryItem(result: result)
        context.insert(item)
        do {
            try context.save()
            Self.log.info("Saved history item: \(item.wordCount) words")
            return item
        } catch {
            Self.log.error("Failed to save: \(error)")
            return nil
        }
    }

    /// Delete a single item.
    func delete(_ item: HistoryItem) {
        guard health.isHealthy else { return }   // ITER-049 A2 — no-op in a temporary session
        let context = modelContainer.mainContext
        context.delete(item)
        try? context.save()
    }

    /// Delete all history.
    func deleteAll() {
        guard health.isHealthy else { return }   // ITER-049 A2 — no-op in a temporary session
        let context = modelContainer.mainContext
        do {
            try context.delete(model: HistoryItem.self)
            try context.save()
            Self.log.info("All history deleted")
        } catch {
            Self.log.error("Failed to delete all: \(error)")
        }
    }
}
