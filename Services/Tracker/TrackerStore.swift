import Foundation
import SwiftData

/// FEAT-0006 §3 — the tracker's own store file, `Tracker.store`, beside the main store.
///
/// Why not new entities in the main store: a new main schema version raises `MWSchemaVersion`, the test-build swap
/// (`scripts/lib/app-install.sh`) then refuses the build because its rollback could not undo the migration, and an
/// older build rolled back onto the newer store could not open it. This file leaves the main store's shape alone;
/// an older build ignores it.
///
/// Freezing rule (same as the main schema): when a tracker model changes shape, snapshot the V1 classes into a frozen
/// namespace, make the live classes V2, and add a stage.
enum TrackerSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [TaskTrackerRecord.self, TrackedProject.self] }
}

/// V2 adds `ArchivedProject` (owner 2026-11-27, Q4): a new entity, nothing already stored changes shape, so the
/// stage is lightweight and V1's models need no frozen copy.
enum TrackerSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { TrackerSchemaV1.models + [ArchivedProject.self] }
}

enum TrackerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TrackerSchemaV1.self, TrackerSchemaV2.self] }
    static var stages: [MigrationStage] {
        [MigrationStage.lightweight(fromVersion: TrackerSchemaV1.self, toVersion: TrackerSchemaV2.self)]
    }
}

enum TrackerStore {
    /// `~/Library/Application Support/<support folder>/Tracker.store`.
    static var fileURL: URL {
        AppIdentity.current.supportDirectory.appendingPathComponent("Tracker.store")
    }

    static func makeContainer(url: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: TrackerSchemaV2.self)
        let config = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, migrationPlan: TrackerMigrationPlan.self, configurations: [config])
    }

    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: TrackerSchemaV2.self)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}

extension TrackerStore {
    /// FEAT-0006 §8 — the read-only `mcp-snapshot.json` older versions wrote for the old MCP tool. Agents now read
    /// live through the tracker, so a copy left on disk is deleted (it held memories and tasks in plain text).
    static func removeLegacySnapshot(in directory: URL = AppIdentity.current.supportDirectory) {
        let url = directory.appendingPathComponent("mcp-snapshot.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            NSLog("[Tracker] removed the old MCP snapshot file")
        } catch {
            NSLog("[Tracker] old MCP snapshot not removed: %@", error.localizedDescription)
        }
    }
}
