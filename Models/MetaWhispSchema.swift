import Foundation
import SwiftData

/// Versioned SwiftData schema + migration plan (ITER-049 B / AUD-007).
///
/// Until now the store was built from a bare `Schema([... 14 models ...])` with
/// NO migration plan, so the first breaking `@Model` change would fail to open
/// an existing user's store (and A1's degraded path would catch it). This anchors
/// the CURRENT shape as `V1` and threads a `SchemaMigrationPlan` through the
/// container so future changes get an explicit, tested migration stage instead of
/// relying on implicit lightweight migration.
///
/// V1 is the baseline: it lists today's 14 models unchanged with version 1.0.0,
/// which is what the existing on-disk store was written with, so introducing it
/// is a no-op for current users (proven on a copy of the real store — see
/// `SchemaMigrationTests`).
///
/// **Freezing rule (Codex):** when the FIRST real change lands, do NOT edit these
/// model classes for the new version while V1 still references them — snapshot the
/// V1 field shapes into a frozen `MetaWhispSchemaV1` namespace, make the live
/// classes V2, and add a `.lightweight`/`.custom` stage from V1 to V2.
enum MetaWhispSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ]
    }
}

/// Migration plan for the live store. V1-only baseline: no stages yet — protection
/// begins with the first V2 stage. Keeping the plan threaded now means future
/// changes can't accidentally ship without a migration path.
enum MetaWhispMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MetaWhispSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
