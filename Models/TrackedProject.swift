import Foundation
import SwiftData

/// FEAT-0006 §3.2 — a project the tracker knows. Its existence makes the project real: the automatic project passes
/// never prune, merge away or rename it (I6). Kept in `Tracker.store`; `projectId` is the `ProjectAlias.id`.
/// spec://tracker/FEAT-0006#model.project
@Model
final class TrackedProject {
    var projectId: UUID
    /// `TrackedProjectOrigin.rawValue`.
    var origin: String
    /// `[String]` — the root folders agents worked from (T10), resolved absolute paths.
    var foldersJSON: String
    var createdAt: Date
    var updatedAt: Date

    init(projectId: UUID, origin: TrackedProjectOrigin, folders: [String], now: Date = Date()) {
        self.projectId = projectId
        self.origin = origin.rawValue
        self.foldersJSON = Self.encode(folders)
        self.createdAt = now
        self.updatedAt = now
    }

    var originKind: TrackedProjectOrigin { TrackedProjectOrigin(rawValue: origin) ?? .agent }

    var folders: [String] {
        get {
            guard let data = foldersJSON.data(using: .utf8),
                  let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return list
        }
        set { foldersJSON = Self.encode(newValue) }
    }

    private static func encode(_ folders: [String]) -> String {
        guard let data = try? JSONEncoder().encode(folders), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
}

/// Who made the project real (T4, D7).
enum TrackedProjectOrigin: String {
    /// Claude Code / Codex, named after their folder.
    case agent
    /// The user, by hand.
    case user
    /// MetaChat, on the user's explicit "create project X".
    case chat
}
