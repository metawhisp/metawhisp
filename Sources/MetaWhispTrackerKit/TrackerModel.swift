import Foundation

// FEAT-0006 §3 — the tracker's value types. Stored in the app's `Tracker.store`, carried over the socket, and
// printed by the command-line tool.

/// The three board columns an agent can use. Drafts are the user's (I3) and never a tracker status.
public enum TrackerStatus: String, Codable, CaseIterable, Sendable {
    case toDo = "To Do"
    case inProgress = "In Progress"
    case done = "Done"

    /// Case- and space-insensitive: "todo", "TO DO" and " to  do " are all To Do.
    public static func parse(_ raw: String) -> TrackerStatus? {
        let folded = squash(raw)
        guard !folded.isEmpty else { return nil }
        return allCases.first { squash($0.rawValue) == folded }
    }

    public static var validList: String { allCases.map(\.rawValue).joined(separator: ", ") }

    /// The mark a task view puts before the status.
    public var icon: String {
        switch self {
        case .toDo: return "○"
        case .inProgress: return "◒"
        case .done: return "✔"
        }
    }

    private static func squash(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace }
    }
}

public enum TrackerPriority: String, Codable, CaseIterable, Sendable {
    case high, medium, low

    public static func parse(_ raw: String) -> TrackerPriority? {
        TrackerPriority(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Higher sorts first; a task without a priority ranks 0.
    public var rank: Int {
        switch self {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }

    public var display: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    public static var validList: String { allCases.map(\.display).joined(separator: ", ") }
}

/// The kinds of work a task can be.
public enum TrackerTaskType {
    public static let all = ["bug", "feature", "enhancement", "task", "chore", "docs", "spike"]

    public static func parse(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.contains(t) ? t : nil
    }
}

/// One acceptance criterion or definition-of-done item. Shown 1-based by position.
public struct ChecklistItem: Codable, Equatable, Sendable {
    public var text: String
    public var checked: Bool

    public init(text: String, checked: Bool) {
        self.text = text
        self.checked = checked
    }
}

public struct TrackerComment: Codable, Equatable, Sendable {
    public var body: String
    public var author: String?
    public var createdAt: Date

    public init(body: String, author: String?, createdAt: Date) {
        self.body = body
        self.author = author
        self.createdAt = createdAt
    }
}

/// Everything a tracker record holds besides its scalar fields. One JSON column, every field optional, so later
/// fields need no store migration and a body written by a newer build still reads.
public struct TrackerTaskBody: Codable, Equatable, Sendable {
    public var description: String?
    public var priority: String?
    public var type: String?
    public var labels: [String]?
    public var assignee: [String]?
    /// `TaskItem.id`s of the tasks this one waits on.
    public var dependencies: [UUID]?
    public var references: [String]?
    public var documentation: [String]?
    public var modifiedFiles: [String]?
    public var acceptanceCriteria: [ChecklistItem]?
    public var definitionOfDone: [ChecklistItem]?
    public var implementationPlan: String?
    public var implementationNotes: String?
    public var comments: [TrackerComment]?
    public var finalSummary: String?
    /// Who made the task: "Claude Code", "Codex", "MetaChat", "user".
    public var createdBy: String?
    /// The task's due date names a day (an agent's `dueDate`), not a moment.
    public var dueIsDay: Bool?
    /// The agent session that took it to In Progress (owner 2026-11-27, Q2); cleared when it leaves In Progress.
    public var holder: TrackerHolder?
    /// Its moves, oldest first, at most `TrackerEvent.kept` (owner 2026-11-27, Q3: for agents only).
    public var events: [TrackerEvent]?

    public init() {}

    /// Every field set: its encoding names every key this build knows (used to keep the keys it does not).
    public static var allKeysFilled: TrackerTaskBody {
        var b = TrackerTaskBody()
        b.description = ""; b.priority = ""; b.type = ""; b.labels = []; b.assignee = []; b.dependencies = []
        b.references = []; b.documentation = []; b.modifiedFiles = []; b.acceptanceCriteria = []
        b.definitionOfDone = []; b.implementationPlan = ""; b.implementationNotes = ""; b.comments = []
        b.finalSummary = ""; b.createdBy = ""; b.dueIsDay = true
        b.holder = TrackerHolder(client: "", session: "", since: Date(timeIntervalSince1970: 0))
        b.events = []
        return b
    }

    /// Notes a move; the oldest go once there are more than `TrackerEvent.kept`.
    public mutating func recordMove(from: String?, to: String, by: String?, at: Date) {
        guard from != to else { return }
        var list = events ?? []
        list.append(TrackerEvent(at: at, by: by, from: from, to: to))
        events = Array(list.suffix(TrackerEvent.kept))
    }
}

/// One move of a task: a column, Archived, or its creation (`from` nil). `by` is the agent, "user", or "MetaWhisp".
public struct TrackerEvent: Codable, Equatable, Sendable {
    public static let kept = 50
    public var at: Date
    public var by: String?
    public var from: String?
    public var to: String

    public init(at: Date, by: String?, from: String?, to: String) {
        self.at = at
        self.by = by
        self.from = from
        self.to = to
    }
}

/// Who has a task In Progress: an agent and its session, since when.
public struct TrackerHolder: Codable, Equatable, Sendable {
    public var client: String?
    public var session: String?
    public var since: Date

    public init(client: String?, session: String?, since: Date) {
        self.client = client
        self.session = session
        self.since = since
    }

    /// The same session; without sessions on both sides, the same agent by name.
    public func isSame(client other: String?, session otherSession: String?) -> Bool {
        if let session, let otherSession { return session == otherSession }
        return (client ?? "").lowercased() == (other ?? "").lowercased()
    }
}

// MARK: - What an agent reads back

public struct TrackerTaskSummary: Codable, Equatable, Sendable {
    /// Changes with every write to the task: what `task_edit`'s `expectedRevision` compares. Stored, so `--json` and
    /// MCP's structured result carry it (a computed one was left out, and the ISO-8601 `updatedAt` drops the
    /// milliseconds it is made of; Codex review P2-10).
    public var revision: String

    public static func revision(of updatedAt: Date) -> String {
        String(Int64((updatedAt.timeIntervalSince1970 * 1000).rounded()))
    }

    public var id: String
    public var title: String
    public var status: String
    public var archived: Bool
    public var priority: String?
    public var type: String?
    public var labels: [String]
    public var assignee: [String]
    public var dependencies: [String]
    public var parentTaskId: String?
    public var acceptanceCriteriaCompleted: Int
    public var acceptanceCriteriaCount: Int
    /// A day, `YYYY-MM-DD`.
    public var dueDate: String?
    public var ordinal: Double?
    public var createdAt: Date
    public var updatedAt: Date
    public var isReady: Bool
    public var project: String
    /// When it went In Progress: with the assignee, tells live work from work someone left.
    public var startedAt: Date?
    /// The agent that has it In Progress (Q2).
    public var heldBy: String?

    public init(id: String, title: String, status: String, archived: Bool, priority: String?, type: String?,
                labels: [String], assignee: [String], dependencies: [String],
                parentTaskId: String?, acceptanceCriteriaCompleted: Int, acceptanceCriteriaCount: Int,
                dueDate: String?, ordinal: Double?, createdAt: Date, updatedAt: Date, isReady: Bool,
                project: String, startedAt: Date? = nil, heldBy: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.archived = archived
        self.priority = priority
        self.type = type
        self.labels = labels
        self.assignee = assignee
        self.dependencies = dependencies
        self.parentTaskId = parentTaskId
        self.acceptanceCriteriaCompleted = acceptanceCriteriaCompleted
        self.acceptanceCriteriaCount = acceptanceCriteriaCount
        self.dueDate = dueDate
        self.ordinal = ordinal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = Self.revision(of: updatedAt)
        self.isReady = isReady
        self.project = project
        self.startedAt = startedAt
        self.heldBy = heldBy
    }
}

public struct TrackerChecklistEntry: Codable, Equatable, Sendable {
    public var index: Int
    public var text: String
    public var checked: Bool

    public init(index: Int, text: String, checked: Bool) {
        self.index = index
        self.text = text
        self.checked = checked
    }
}

public struct TrackerCommentEntry: Codable, Equatable, Sendable {
    public var index: Int
    public var body: String
    public var author: String?
    public var createdAt: Date

    public init(index: Int, body: String, author: String?, createdAt: Date) {
        self.index = index
        self.body = body
        self.author = author
        self.createdAt = createdAt
    }
}

/// Another task named from this one: its parent, a subtask, a dependency or a dependent.
public struct TrackerTaskRef: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: String

    public init(id: String, title: String, status: String) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public struct TrackerTaskDetail: Codable, Equatable, Sendable {
    public var summary: TrackerTaskSummary
    public var description: String?
    public var acceptanceCriteria: [TrackerChecklistEntry] = []
    public var definitionOfDone: [TrackerChecklistEntry] = []
    public var implementationPlan: String?
    public var implementationNotes: String?
    public var comments: [TrackerCommentEntry] = []
    public var finalSummary: String?
    public var references: [String] = []
    public var documentation: [String] = []
    public var modifiedFiles: [String] = []
    public var parent: TrackerTaskRef?
    public var subtasks: [TrackerTaskRef] = []
    public var dependsOn: [TrackerTaskRef] = []
    public var dependents: [TrackerTaskRef] = []
    /// Its moves, oldest first (Q3).
    public var history: [TrackerEvent] = []

    public init(summary: TrackerTaskSummary) {
        self.summary = summary
    }
}
