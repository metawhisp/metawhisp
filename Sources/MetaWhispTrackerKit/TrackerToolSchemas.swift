import Foundation

/// FEAT-0006 §6 — the MCP tools an agent sees. Field names and checks match `TrackerArgs`.
public enum TrackerToolSchemas {

    private static func string(_ description: String? = nil, min: Int? = nil, max: Int) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("string"), "maxLength": .int(max)]
        if let min { o["minLength"] = .int(min) }
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    private static func strings(_ description: String? = nil, max: Int) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("array"),
                                      "items": .object(["type": .string("string"), "maxLength": .int(max)])]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    private static func indexes(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "description": .string(description),
                 "items": .object(["type": .string("number"), "minimum": .int(1)])])
    }

    private static func bool(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func number(_ description: String, min: Int, max: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("number"), "minimum": .int(min), "description": .string(description)]
        if let max { o["maximum"] = .int(max) }
        return .object(o)
    }

    private static var status: JSONValue {
        .object(["type": .string("string"),
                 "enum": .array(TrackerStatus.allCases.map { .string($0.rawValue) }),
                 "description": .string("Board column (case-insensitive): \(TrackerStatus.validList). "
                                        + "Drafts are the user's and not available to agents.")])
    }

    private static var priority: JSONValue {
        .object(["type": .string("string"), "enum": .array(TrackerPriority.allCases.map { .string($0.display) }),
                 "description": .string("Optional priority (case-insensitive): \(TrackerPriority.validList)")])
    }

    private static var type: JSONValue {
        .object(["type": .string("string"), "enum": .array(TrackerTaskType.all.map { .string($0) }),
                 "description": .string("Optional kind of work: \(TrackerTaskType.all.joined(separator: ", "))")])
    }

    private static let id = string("Task ID in this folder's project, e.g. TASK-12", min: 1, max: 50)

    private static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue],
                             required: [String] = [], readOnly: Bool = false, destructive: Bool = false) -> JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
                "additionalProperties": .bool(false),
            ]),
            "annotations": .object(["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive)]),
        ])
    }

    public static let tools: [JSONValue] = [
        tool("get_metawhisp_instructions",
             "How to work with MetaWhisp tasks. Read the overview at the start of a session; read the matching guide "
             + "before creating, working on, or finishing tasks.",
             ["instruction": .object(["type": .string("string"),
                                      "enum": .array(TrackerGuides.all.map { .string($0.name) })])],
             readOnly: true),
        tool("task_create",
             "Create a task in the MetaWhisp project of your working folder (the project is created, named after the "
             + "folder, with its first task). Give the why in the description and testable acceptance criteria.",
             ["title": string(min: 1, max: 200),
              "description": string("Why the task exists: the problem, trigger or value, and context the code "
                                    + "cannot give.", max: 10_000),
              "status": status, "priority": priority, "type": type,
              "labels": strings(max: 50),
              "assignee": strings("Who works on it, e.g. @claude", max: 100),
              "dependencies": strings("IDs of tasks this one waits on", max: 50),
              "references": strings("URLs or paths related to the task", max: 500),
              "documentation": strings("Design docs, specs or manuals that explain the task", max: 500),
              "modifiedFiles": strings("Project-relative paths the task changes", max: 500),
              "acceptanceCriteria": strings("One single-line, testable criterion per entry", max: 500),
              "definitionOfDoneAdd": strings("Completion checks for this task only", max: 500),
              "parentTaskId": string("Existing task ID to make this a subtask of", max: 50),
              "dueDate": string("A day, e.g. 2026-08-10", max: 64),
              "ordinal": number("Manual order; lower first. Prefer spaced numbers like 1000, 2000.", min: 0),
              "finalSummary": string("Only for work created already done", max: 20_000)],
             required: ["title"]),
        tool("task_list",
             "List the board of your folder's project: To Do, In Progress, Done (archived tasks are not listed). "
             + "Filter by status to keep the answer short.",
             ["status": status,
              "assignee": string(max: 100),
              "unassigned": bool("Only tasks with no assignee"),
              "labels": strings("All of these labels", max: 50),
              "search": string("Words that must appear in the task", max: 200),
              "ready": bool("Only tasks free to pick up: To Do, with every dependency done or archived. With limit 1, the next task"),
              "limit": number("At most this many", min: 1, max: 1000)],
             readOnly: true),
        tool("task_search",
             "Search the tasks of your folder's project, archived ones included, by words, type, priority or "
             + "modified file paths. A query, a type or modifiedFiles is required.",
             ["query": string(max: 200), "status": status, "priority": priority,
              "type": .object(["type": .string("array"),
                               "items": .object(["type": .string("string"),
                                                 "enum": .array(TrackerTaskType.all.map { .string($0) })])]),
              "modifiedFiles": strings("Substrings of modified file paths", max: 500),
              "limit": number("At most this many", min: 1, max: 100)],
             readOnly: true),
        tool("task_view",
             "Read one task in full: description, criteria, plan, notes, comments, summary, dependencies.",
             ["id": id], required: ["id"], readOnly: true),
        tool("task_edit",
             "Change a task: move it between To Do, In Progress and Done, record the plan and notes, tick criteria, "
             + "write the final summary. Archived tasks must be restored first. Done is refused while a subtask or a "
             + "dependency is open, unless force.",
             ["id": id,
              "title": string(min: 1, max: 200),
              "description": string(max: 10_000),
              "status": status, "priority": priority, "type": type,
              "ordinal": number("Manual order; lower first", min: 0),
              "labels": strings("Replaces the labels; [] clears", max: 50),
              "addLabels": strings(max: 50), "removeLabels": strings(max: 50),
              "assignee": strings("Replaces the assignees; [] clears", max: 100),
              "dependencies": strings("Replaces the dependencies; [] clears", max: 50),
              "addDependencies": strings("Task IDs this one also waits on", max: 50),
              "removeDependencies": strings(max: 50),
              "force": bool("Move to Done although a subtask or a dependency is still open; say why in commentsAppend"),
              "expectedRevision": string("The revision task_view showed; the edit is refused if the task changed "
                                         + "since. Send it with criteria indexes.", max: 40),
              "references": strings("Replaces the references", max: 500),
              "addReferences": strings(max: 500), "removeReferences": strings(max: 500),
              "documentation": strings("Replaces the documentation links", max: 500),
              "addDocumentation": strings(max: 500), "removeDocumentation": strings(max: 500),
              "modifiedFiles": strings("Replaces the modified file paths", max: 500),
              "dueDate": .object(["type": .array([.string("string"), .string("null")]),
                                  "description": .string("A day, e.g. 2026-08-10; null clears")]),
              "planSet": string(max: 20_000), "planAppend": strings(max: 5_000),
              "planClear": bool("Clear the implementation plan"),
              "notesSet": string(max: 20_000), "notesAppend": strings(max: 5_000),
              "notesClear": bool("Clear the implementation notes"),
              "finalSummary": string("What changed, why, how it was verified, what is left", max: 20_000),
              "finalSummaryAppend": strings(max: 5_000), "finalSummaryClear": bool("Clear the final summary"),
              "commentsAppend": strings("Discussion or review notes", max: 5_000),
              "commentAuthor": string(max: 100),
              "acceptanceCriteriaSet": strings("Replaces all criteria; the same text keeps its tick", max: 500),
              "acceptanceCriteriaAdd": strings(max: 500),
              "acceptanceCriteriaRemove": indexes("1-based"),
              "acceptanceCriteriaCheck": indexes("1-based; tick only what was verified"),
              "acceptanceCriteriaUncheck": indexes("1-based"),
              "definitionOfDoneAdd": strings(max: 500),
              "definitionOfDoneRemove": indexes("1-based"),
              "definitionOfDoneCheck": indexes("1-based"),
              "definitionOfDoneUncheck": indexes("1-based")],
             required: ["id"]),
        tool("task_archive",
             "Take a task off the board, in any column: finished work at cleanup, or cancelled, duplicate or invalid "
             + "work. It keeps its ID and record, stays readable, and can be restored. Prefer this to deleting.",
             ["id": id], required: ["id"], destructive: true),
        tool("task_restore",
             "Bring an archived task back to the board, to the column it had.",
             ["id": id], required: ["id"]),
        tool("task_delete",
             "Delete an archived task forever. Only when the user asked for it and said yes to deleting it forever "
             + "in this chat; set userConfirmed only then. Archive first; a task with subtasks is not deleted.",
             ["id": id, "userConfirmed": bool("The user said yes to deleting this task forever")],
             required: ["id", "userConfirmed"], destructive: true),
        tool("search_memories",
             "Search what MetaWhisp remembers from the user's calls, dictations and notes (facts, decisions, people).",
             ["query": string(min: 1, max: 200), "limit": number("Default 10", min: 1, max: 50)],
             required: ["query"], readOnly: true),
        tool("search_conversations",
             "Search the user's recorded conversations (calls, voice notes) by title, summary and project.",
             ["query": string(min: 1, max: 200), "limit": number("Default 5", min: 1, max: 50)],
             required: ["query"], readOnly: true),
        tool("recent_conversations",
             "The user's latest recorded conversations with their summaries, newest first.",
             ["limit": number("Default 10", min: 1, max: 50),
              "since_days": number("Only the last N days", min: 1, max: 3650)],
             readOnly: true),
    ]
}
