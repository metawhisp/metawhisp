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
            TaskItem.self, ChatMessage.self, Conversation.self,
            MetaWhispSchemaV1.ScreenObservation.self,   // frozen pre-embedding shape
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ]
    }

    /// FROZEN V1 shape of ScreenObservation — the on-disk layout BEFORE
    /// ITER-053.4 added `embedding`. Nested under the version enum with the
    /// SAME type name so the entity name matches the store. Never edit this
    /// copy. Unchanged models above are shared with V2 by reference — only the
    /// changed model gets frozen (freezing rule in this file's header).
    @Model
    final class ScreenObservation {
        var id: UUID
        var screenContextId: UUID?
        var appName: String
        var windowTitle: String?
        var contextSummary: String
        var currentActivity: String
        var hasTask: Bool
        var taskTitle: String?
        var sourceCategory: String?
        var focusStatus: String?
        var startedAt: Date
        var endedAt: Date
        var createdAt: Date

        init(
            screenContextId: UUID?, appName: String, windowTitle: String?,
            contextSummary: String, currentActivity: String, hasTask: Bool,
            taskTitle: String? = nil, sourceCategory: String? = nil,
            focusStatus: String? = nil, startedAt: Date, endedAt: Date
        ) {
            self.id = UUID()
            self.screenContextId = screenContextId
            self.appName = appName
            self.windowTitle = windowTitle
            self.contextSummary = contextSummary
            self.currentActivity = currentActivity
            self.hasTask = hasTask
            self.taskTitle = taskTitle
            self.sourceCategory = sourceCategory
            self.focusStatus = focusStatus
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.createdAt = Date()
        }
    }
}

/// ITER-053.4 slice 2 — V2 adds `ScreenObservation.embedding: Data?` (semantic
/// screen-history search). Additive optional column → lightweight stage.
enum MetaWhispSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ]
    }
}

/// Migration plan for the live store. V1 → V2 is the first real stage:
/// lightweight (additive optional column), verified by `SchemaMigrationTests`.
enum MetaWhispMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MetaWhispSchemaV1.self, MetaWhispSchemaV2.self] }
    static var stages: [MigrationStage] {
        [
            MigrationStage.lightweight(
                fromVersion: MetaWhispSchemaV1.self,
                toVersion: MetaWhispSchemaV2.self
            ),
        ]
    }
}
