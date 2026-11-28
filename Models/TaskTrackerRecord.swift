import Foundation
import MetaWhispTrackerKit
import SwiftData

/// FEAT-0006 §3.1 — the tracker side of one `TaskItem` (1:1 by `taskId`), kept in `Tracker.store`, not the main
/// store. `TaskItem` stays the task and the truth for done and dismissed; this record adds the project, the
/// `TASK-n` key, In Progress, archive and the body agents write (description, criteria, plan, notes, summary…).
/// A task without a record is a plain task (voice, calls, older tasks).
/// spec://tracker/FEAT-0006#model.record
@Model
final class TaskTrackerRecord {
    var taskId: UUID
    /// `ProjectAlias.id`; nil = no project.
    var projectId: UUID?
    /// `12` or `12.1` (`TrackerKey.stored`); set together with the project.
    var key: String?
    /// The parent task's `TaskItem.id`, for a subtask.
    var parentTaskId: UUID?
    /// In Progress while set and the task is not done.
    var startedAt: Date?
    /// When it was archived. The column comes from the task: a tracker task that is dismissed, by any path, is
    /// archived; this only says when (FEAT-0006 §3.3).
    var archivedAt: Date?
    var ordinal: Double?
    /// `TrackerTaskBody` as JSON — one column, so later fields need no store migration.
    var bodyJSON: String
    var createdAt: Date
    var updatedAt: Date

    init(taskId: UUID, projectId: UUID?, key: String?, body: TrackerTaskBody, now: Date = Date()) {
        self.taskId = taskId
        self.projectId = projectId
        self.key = key
        self.bodyJSON = Self.encode(body)
        self.createdAt = now
        self.updatedAt = now
    }

    /// A body this build cannot read reads as empty rather than crashing; unknown fields are ignored.
    var body: TrackerTaskBody {
        get {
            guard let data = bodyJSON.data(using: .utf8),
                  let body = try? JSONDecoder().decode(TrackerTaskBody.self, from: data) else { return TrackerTaskBody() }
            return body
        }
        set { bodyJSON = Self.merging(newValue, into: bodyJSON) }
    }

    /// The new body over the stored JSON: fields this build knows are set or removed, fields a newer build wrote
    /// are kept (review P3-13: a rolled-back build must not drop them on its next edit).
    static func merging(_ body: TrackerTaskBody, into stored: String) -> String {
        guard let old = try? JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any],
              let newData = try? JSONEncoder().encode(body),
              let new = try? JSONSerialization.jsonObject(with: newData) as? [String: Any],
              let knownData = try? JSONEncoder().encode(TrackerTaskBody.allKeysFilled),
              let known = try? JSONSerialization.jsonObject(with: knownData) as? [String: Any]
        else { return encode(body) }
        var merged = old
        // Known keys are set or removed; any key the new body carries is written even if `allKeysFilled` misses it.
        for key in Set(known.keys).union(new.keys) { merged[key] = new[key] }
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return encode(body) }
        return text
    }

    var trackerKey: TrackerKey? { key.flatMap(TrackerKey.init(parsing:)) }

    private static func encode(_ body: TrackerTaskBody) -> String {
        guard let data = try? JSONEncoder().encode(body), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Owner 2026-11-27 (Q3) — notes a move in the task's history.
    func noteMove(from: String?, to: String, by: String?, at: Date) {
        var b = body
        b.recordMove(from: from, to: to, by: by, at: at)
        body = b
    }

    /// The column the task is in, from the pair (§3.3).
    func column(of task: TaskItem) -> TrackerStatus {
        task.completed ? .done : (startedAt != nil ? .inProgress : .toDo)
    }

    /// Owner 2026-11-27 (Q2) — out of In Progress, no agent holds it any more.
    func clearHolder() {
        guard body.holder != nil else { return }
        var b = body
        b.holder = nil
        body = b
    }
}
