import Foundation

// FEAT-0006 §6 — the typed inputs of every tool, read from JSON arguments with the same checks for the MCP server,
// the command-line tool and the app. Unknown fields, wrong types, empty titles and out-of-range values are refused.

/// A field an edit can set, clear, or leave alone.
public enum Clearable<T: Equatable & Sendable>: Equatable, Sendable {
    case unchanged
    case set(T)
    case clear
}

public struct TaskCreateInput: Equatable, Sendable {
    public var title: String
    public var description: String?
    public var status: TrackerStatus = .toDo
    public var priority: TrackerPriority?
    public var type: String?
    public var labels: [String] = []
    public var assignee: [String] = []
    public var dependencies: [String] = []
    public var references: [String] = []
    public var documentation: [String] = []
    public var modifiedFiles: [String] = []
    public var acceptanceCriteria: [String] = []
    public var definitionOfDoneAdd: [String] = []
    public var parentTaskId: String?
    public var dueDate: String?
    public var ordinal: Double?
    public var finalSummary: String?

    public init(title: String) { self.title = title }
}

public struct TaskEditInput: Equatable, Sendable {
    public var id: String
    public var title: String?
    public var description: String?
    public var status: TrackerStatus?
    public var priority: TrackerPriority?
    public var type: String?
    public var ordinal: Double?
    public var labels: [String]?
    public var addLabels: [String] = []
    public var removeLabels: [String] = []
    public var assignee: [String]?
    public var dependencies: [String]?
    public var addDependencies: [String] = []
    public var removeDependencies: [String] = []
    /// Moves to Done even with a subtask or a dependency still open (the caller says why in a comment).
    public var force = false
    /// The task's `revision` as last read: a task changed since is not edited (an index may point elsewhere now).
    public var expectedRevision: String?
    public var references: [String]?
    public var addReferences: [String] = []
    public var removeReferences: [String] = []
    public var documentation: [String]?
    public var addDocumentation: [String] = []
    public var removeDocumentation: [String] = []
    public var modifiedFiles: [String]?
    public var dueDate: Clearable<String> = .unchanged
    public var planSet: String?
    public var planAppend: [String] = []
    public var planClear = false
    public var notesSet: String?
    public var notesAppend: [String] = []
    public var notesClear = false
    public var finalSummary: String?
    public var finalSummaryAppend: [String] = []
    public var finalSummaryClear = false
    public var commentsAppend: [String] = []
    public var commentAuthor: String?
    public var acceptanceCriteriaSet: [String]?
    public var acceptanceCriteriaAdd: [String] = []
    public var acceptanceCriteriaRemove: [Int] = []
    public var acceptanceCriteriaCheck: [Int] = []
    public var acceptanceCriteriaUncheck: [Int] = []
    public var definitionOfDoneAdd: [String] = []
    public var definitionOfDoneRemove: [Int] = []
    public var definitionOfDoneCheck: [Int] = []
    public var definitionOfDoneUncheck: [Int] = []

    public init(id: String) { self.id = id }
}

public struct TaskListInput: Equatable, Sendable {
    public var status: TrackerStatus?
    public var assignee: String?
    public var unassigned = false
    public var labels: [String] = []
    public var search: String?
    public var ready = false
    public var limit: Int?

    public init() {}
}

public struct TaskSearchInput: Equatable, Sendable {
    public var query: String?
    public var status: TrackerStatus?
    public var priority: TrackerPriority?
    public var type: [String] = []
    public var modifiedFiles: [String] = []
    public var limit: Int?

    public init() {}
}

public struct TaskDeleteInput: Equatable, Sendable {
    public var id: String
    public var userConfirmed: Bool
}

public enum TrackerArgs {
    static let draftRefusal = "Drafts are the user's suggestions in MetaWhisp; agents cannot use status Draft. "
        + "Valid statuses are: " + TrackerStatus.validList

    public static func create(_ args: [String: JSONValue]) throws -> TaskCreateInput {
        let r = Reader(args, allowed: ["title", "description", "status", "priority", "type", "labels", "assignee",
                                       "dependencies", "references", "documentation", "modifiedFiles",
                                       "acceptanceCriteria", "definitionOfDoneAdd", "parentTaskId", "dueDate",
                                       "ordinal", "finalSummary"])
        var input = TaskCreateInput(title: try r.string("title", required: true, min: 1, max: 200)!)
        input.description = try r.string("description", max: 10_000)
        if let s = try r.status("status") { input.status = s }
        input.priority = try r.priority("priority")
        input.type = try r.taskType("type")
        input.labels = try r.strings("labels", max: 50)
        input.assignee = try r.strings("assignee", max: 100)
        input.dependencies = try r.strings("dependencies", max: 50)
        input.references = try r.strings("references", max: 500)
        input.documentation = try r.strings("documentation", max: 500)
        input.modifiedFiles = try r.strings("modifiedFiles", max: 500)
        input.acceptanceCriteria = try r.strings("acceptanceCriteria", max: 500, keepBlank: true)
        input.definitionOfDoneAdd = try r.strings("definitionOfDoneAdd", max: 500, keepBlank: true)
        input.parentTaskId = try r.string("parentTaskId", max: 50)
        input.dueDate = try r.day("dueDate")
        input.ordinal = try r.number("ordinal", min: 0)
        input.finalSummary = try r.string("finalSummary", max: 20_000)
        try r.finish()
        return input
    }

    public static func edit(_ args: [String: JSONValue]) throws -> TaskEditInput {
        let r = Reader(args, allowed: [
            "id", "title", "description", "status", "priority", "type", "ordinal", "labels", "addLabels",
            "removeLabels", "assignee", "dependencies", "addDependencies", "removeDependencies", "force",
            "expectedRevision", "references", "addReferences", "removeReferences", "documentation", "addDocumentation",
            "removeDocumentation", "modifiedFiles", "dueDate", "planSet", "planAppend", "planClear",
            "implementationPlan", "notesSet", "notesAppend", "notesClear", "implementationNotes", "finalSummary",
            "finalSummaryAppend", "finalSummaryClear", "commentsAppend", "commentAuthor", "acceptanceCriteriaSet",
            "acceptanceCriteriaAdd", "acceptanceCriteriaRemove", "acceptanceCriteriaCheck",
            "acceptanceCriteriaUncheck", "definitionOfDoneAdd", "definitionOfDoneRemove", "definitionOfDoneCheck",
            "definitionOfDoneUncheck",
        ])
        var e = TaskEditInput(id: try r.string("id", required: true, min: 1, max: 50)!)
        e.title = try r.string("title", min: 1, max: 200)
        e.description = try r.string("description", max: 10_000, keepEmpty: true)
        e.status = try r.status("status")
        e.priority = try r.priority("priority")
        e.type = try r.taskType("type")
        e.ordinal = try r.number("ordinal", min: 0)
        e.labels = try r.optionalStrings("labels", max: 50)
        e.addLabels = try r.strings("addLabels", max: 50)
        e.removeLabels = try r.strings("removeLabels", max: 50)
        e.assignee = try r.optionalStrings("assignee", max: 100)
        e.dependencies = try r.optionalStrings("dependencies", max: 50)
        e.addDependencies = try r.strings("addDependencies", max: 50)
        e.removeDependencies = try r.strings("removeDependencies", max: 50)
        e.force = try r.bool("force")
        e.expectedRevision = try r.string("expectedRevision", max: 40)
        e.references = try r.optionalStrings("references", max: 500)
        e.addReferences = try r.strings("addReferences", max: 500)
        e.removeReferences = try r.strings("removeReferences", max: 500)
        e.documentation = try r.optionalStrings("documentation", max: 500)
        e.addDocumentation = try r.strings("addDocumentation", max: 500)
        e.removeDocumentation = try r.strings("removeDocumentation", max: 500)
        e.modifiedFiles = try r.optionalStrings("modifiedFiles", max: 500)
        e.dueDate = try r.clearableDay("dueDate")
        e.planSet = try r.string("planSet", max: 20_000, keepEmpty: true)
            ?? (try r.string("implementationPlan", max: 20_000, keepEmpty: true))
        e.planAppend = try r.strings("planAppend", max: 5_000)
        e.planClear = try r.bool("planClear")
        e.notesSet = try r.string("notesSet", max: 20_000, keepEmpty: true)
            ?? (try r.string("implementationNotes", max: 20_000, keepEmpty: true))
        e.notesAppend = try r.strings("notesAppend", max: 5_000)
        e.notesClear = try r.bool("notesClear")
        e.finalSummary = try r.string("finalSummary", max: 20_000, keepEmpty: true)
        e.finalSummaryAppend = try r.strings("finalSummaryAppend", max: 5_000)
        e.finalSummaryClear = try r.bool("finalSummaryClear")
        e.commentsAppend = try r.strings("commentsAppend", max: 5_000)
        e.commentAuthor = try r.string("commentAuthor", max: 100)
        e.acceptanceCriteriaSet = try r.optionalStrings("acceptanceCriteriaSet", max: 500, keepBlank: true)
        e.acceptanceCriteriaAdd = try r.strings("acceptanceCriteriaAdd", max: 500, keepBlank: true)
        e.acceptanceCriteriaRemove = try r.indexes("acceptanceCriteriaRemove")
        e.acceptanceCriteriaCheck = try r.indexes("acceptanceCriteriaCheck")
        e.acceptanceCriteriaUncheck = try r.indexes("acceptanceCriteriaUncheck")
        e.definitionOfDoneAdd = try r.strings("definitionOfDoneAdd", max: 500, keepBlank: true)
        e.definitionOfDoneRemove = try r.indexes("definitionOfDoneRemove")
        e.definitionOfDoneCheck = try r.indexes("definitionOfDoneCheck")
        e.definitionOfDoneUncheck = try r.indexes("definitionOfDoneUncheck")
        try r.finish()
        return e
    }

    public static func list(_ args: [String: JSONValue]) throws -> TaskListInput {
        let r = Reader(args, allowed: ["status", "assignee", "unassigned", "labels", "search", "ready", "limit"])
        var l = TaskListInput()
        l.status = try r.status("status")
        l.assignee = try r.string("assignee", max: 100)
        l.unassigned = try r.bool("unassigned")
        if l.unassigned && l.assignee != nil {
            throw TrackerFailure.validation("unassigned cannot be combined with assignee.")
        }
        l.labels = try r.strings("labels", max: 50)
        l.search = try r.string("search", max: 200)
        l.ready = try r.bool("ready")
        l.limit = try r.integer("limit", min: 1, max: 1000)
        try r.finish()
        return l
    }

    public static func search(_ args: [String: JSONValue]) throws -> TaskSearchInput {
        let r = Reader(args, allowed: ["query", "status", "priority", "type", "modifiedFiles", "limit"])
        var s = TaskSearchInput()
        s.query = try r.string("query", max: 200)
        s.status = try r.status("status")
        s.priority = try r.priority("priority")
        s.type = try r.strings("type", max: 50).map { raw in
            guard let t = TrackerTaskType.parse(raw) else {
                throw TrackerFailure.validation("Invalid type: \(raw). Valid values: "
                                                + TrackerTaskType.all.joined(separator: ", "))
            }
            return t
        }
        s.modifiedFiles = try r.strings("modifiedFiles", max: 500)
        s.limit = try r.integer("limit", min: 1, max: 100)
        try r.finish()
        if s.query == nil && s.type.isEmpty && s.modifiedFiles.isEmpty {
            throw TrackerFailure.validation("Search query, modifiedFiles, or type filter is required.")
        }
        return s
    }

    public static func id(_ args: [String: JSONValue]) throws -> String {
        let r = Reader(args, allowed: ["id"])
        let id = try r.string("id", required: true, min: 1, max: 50)!
        try r.finish()
        return id
    }

    public static func delete(_ args: [String: JSONValue]) throws -> TaskDeleteInput {
        let r = Reader(args, allowed: ["id", "userConfirmed"])
        let id = try r.string("id", required: true, min: 1, max: 50)!
        let confirmed = try r.bool("userConfirmed")
        try r.finish()
        return TaskDeleteInput(id: id, userConfirmed: confirmed)
    }

    /// `search_memories` / `search_conversations`: a query and a limit.
    public static func query(_ args: [String: JSONValue], defaultLimit: Int,
                             maxLimit: Int) throws -> (query: String, limit: Int) {
        let r = Reader(args, allowed: ["query", "limit"])
        let q = try r.string("query", required: true, min: 1, max: 200)!
        let limit = try r.integer("limit", min: 1, max: maxLimit) ?? defaultLimit
        try r.finish()
        return (q, limit)
    }

    /// `recent_conversations`: a limit and an optional window in days.
    public static func recent(_ args: [String: JSONValue]) throws -> (limit: Int, sinceDays: Int?) {
        let r = Reader(args, allowed: ["limit", "since_days"])
        let limit = try r.integer("limit", min: 1, max: 50) ?? 10
        let days = try r.integer("since_days", min: 1, max: 3650)
        try r.finish()
        return (limit, days)
    }

    // MARK: - Reader

    struct Reader {
        private let args: [String: JSONValue]
        private let allowed: Set<String>

        init(_ args: [String: JSONValue], allowed: Set<String>) {
            self.args = args
            self.allowed = allowed
        }

        /// Refuses fields no schema knows.
        func finish() throws {
            if let unknown = args.keys.sorted().first(where: { !allowed.contains($0) }) {
                throw TrackerFailure.validation("Unknown field '\(unknown)' is not allowed.")
            }
        }

        private func value(_ key: String) -> JSONValue? {
            guard let v = args[key], !v.isNull else { return nil }
            return v
        }

        func string(_ key: String, required: Bool = false, min: Int = 0, max: Int,
                    keepEmpty: Bool = false) throws -> String? {
            guard let v = value(key) else {
                if required { throw TrackerFailure.validation("\(key) is required.") }
                return nil
            }
            guard let raw = v.stringValue else { throw TrackerFailure.validation("\(key) must be a string.") }
            let s = clean(raw)
            if s.isEmpty && !keepEmpty {
                if required || min > 0 { throw TrackerFailure.validation("\(key) cannot be empty.") }
                return nil
            }
            if s.count < min { throw TrackerFailure.validation("\(key) must be at least \(min) characters.") }
            if s.count > max { throw TrackerFailure.validation("\(key) must be at most \(max) characters.") }
            return s
        }

        func strings(_ key: String, max: Int, keepBlank: Bool = false) throws -> [String] {
            try optionalStrings(key, max: max, keepBlank: keepBlank) ?? []
        }

        /// nil when absent; an explicit empty array clears.
        func optionalStrings(_ key: String, max: Int, keepBlank: Bool = false) throws -> [String]? {
            guard let v = value(key) else { return nil }
            let items: [JSONValue]
            if let a = v.arrayValue { items = a } else if v.stringValue != nil { items = [v] } else {
                throw TrackerFailure.validation("\(key) must be an array of strings.")
            }
            if items.count > 100 { throw TrackerFailure.validation("\(key) has more than 100 entries.") }
            return try items.compactMap { item in
                guard let raw = item.stringValue else {
                    throw TrackerFailure.validation("\(key) must be an array of strings.")
                }
                if keepBlank {
                    if raw.count > max { throw TrackerFailure.validation("An entry of \(key) is longer than \(max).") }
                    return raw
                }
                let s = clean(raw)
                if s.count > max { throw TrackerFailure.validation("An entry of \(key) is longer than \(max).") }
                return s.isEmpty ? nil : s
            }
        }

        func bool(_ key: String) throws -> Bool {
            guard let v = value(key) else { return false }
            switch v {
            case .bool(let b): return b
            case .string(let s) where s.lowercased() == "true": return true
            case .string(let s) where s.lowercased() == "false": return false
            default: throw TrackerFailure.validation("\(key) must be true or false.")
            }
        }

        func number(_ key: String, min: Double) throws -> Double? {
            guard let v = value(key) else { return nil }
            let n: Double
            switch v {
            case .int(let i): n = Double(i)
            case .double(let d): n = d
            case .string(let s):
                guard let d = Double(s) else { throw TrackerFailure.validation("\(key) must be a number.") }
                n = d
            default: throw TrackerFailure.validation("\(key) must be a number.")
            }
            guard n.isFinite, n >= min else { throw TrackerFailure.validation("\(key) must be ≥ \(Int(min)).") }
            return n
        }

        func integer(_ key: String, min: Int, max: Int) throws -> Int? {
            guard let n = try number(key, min: Double(min)) else { return nil }
            guard n <= Double(max), n.rounded() == n else {
                throw TrackerFailure.validation("\(key) must be a whole number from \(min) to \(max).")
            }
            return Int(n)
        }

        func indexes(_ key: String) throws -> [Int] {
            guard let v = value(key) else { return [] }
            let items = v.arrayValue ?? [v]
            return try items.map { item in
                let n: Double?
                switch item {
                case .int(let i): n = Double(i)
                case .double(let d): n = d
                case .string(let s): n = Double(s)
                default: n = nil
                }
                // Finite and bounded before Int(): an agent's "inf" or 1e19 must never trap the app (review P1-1).
                guard let n, n.isFinite, n >= 1, n <= 10_000, n.rounded() == n else {
                    throw TrackerFailure.validation("\(key) takes 1-based indexes.")
                }
                return Int(n)
            }
        }

        func status(_ key: String) throws -> TrackerStatus? {
            guard let raw = try string(key, max: 100) else { return nil }
            if raw.lowercased() == "draft" { throw TrackerFailure.validation(TrackerArgs.draftRefusal) }
            guard let s = TrackerStatus.parse(raw) else {
                throw TrackerFailure.validation("Invalid status: \(raw). Valid statuses are: \(TrackerStatus.validList)")
            }
            return s
        }

        func priority(_ key: String) throws -> TrackerPriority? {
            guard let raw = try string(key, max: 50) else { return nil }
            guard let p = TrackerPriority.parse(raw) else {
                throw TrackerFailure.validation("Invalid priority: \(raw). Valid values: \(TrackerPriority.validList)")
            }
            return p
        }

        func taskType(_ key: String) throws -> String? {
            guard let raw = try string(key, max: 50) else { return nil }
            guard let t = TrackerTaskType.parse(raw) else {
                throw TrackerFailure.validation("Invalid type: \(raw). Valid values: "
                                                + TrackerTaskType.all.joined(separator: ", "))
            }
            return t
        }

        func day(_ key: String) throws -> String? {
            guard let raw = try string(key, max: 64) else { return nil }
            return try Self.validDay(raw, key: key)
        }

        func clearableDay(_ key: String) throws -> Clearable<String> {
            guard let v = args[key] else { return .unchanged }
            if v.isNull { return .clear }
            guard let raw = v.stringValue else { throw TrackerFailure.validation("\(key) must be a string or null.") }
            let s = clean(raw)
            if s.isEmpty { return .clear }
            return .set(try Self.validDay(s, key: key))
        }

        /// A due date names a day: `YYYY-MM-DD`.
        static func validDay(_ raw: String, key: String) throws -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            let day = String(raw.prefix(10))
            guard let d = f.date(from: day), f.string(from: d) == day else {
                throw TrackerFailure.validation("\(key) must be a day such as 2026-08-10.")
            }
            return day
        }

        private func clean(_ raw: String) -> String {
            raw.replacingOccurrences(of: "\0", with: "").replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
