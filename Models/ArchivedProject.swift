import Foundation
import SwiftData

/// Owner 2026-11-27 (Q4) — a project the user put away: out of the Projects grid and every project picker, its tasks
/// still in Tasks. In `Tracker.store` (a new entity, so the store's migration only adds a table; the main store keeps
/// its shape). Removed when the user restores it, or when an agent writes a task in its folder.
@Model
final class ArchivedProject {
    var projectId: UUID
    var archivedAt: Date

    init(projectId: UUID, archivedAt: Date) {
        self.projectId = projectId
        self.archivedAt = archivedAt
    }
}
