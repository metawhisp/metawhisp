import Foundation

/// FEAT-0006 §6 — `metawhisp-cli`'s words, turned into the same requests the MCP tools send.
public enum TrackerCLI {

    public enum Command: Equatable {
        /// A request for the app; `json` prints the data instead of the text.
        case request(op: String, args: [String: JSONValue], json: Bool)
        case instructions(String)
        case mcpStart(cwd: String?)
        case help(String)
    }

    public struct UsageError: Error, CustomStringConvertible, Equatable {
        public let description: String
        init(_ d: String) { description = d }
    }

    public static let usage = """
    metawhisp-cli — MetaWhisp tasks for the project in this folder

      task create <title> [-d text] [-s status] [--priority p] [--type t] [-l a,b] [-a who]
                          [--ac text]... [--dod text]... [-p parent] [--dep id]... [--ref x]... [--doc x]...
                          [--modified-file path]... [--due-date yyyy-mm-dd] [--ordinal n]
      task list   [-s status] [-a who] [--unassigned] [-l a,b] [--search words] [--ready] [--limit n]
      task view <id>          (or: task <id>)
      task edit <id> [-t title] [-d text] [-s status] [--priority p] [--type t] [-l a,b] [-a who]
                     [--ac text]... [--check-ac n]... [--uncheck-ac n]... [--remove-ac n]...
                     [--dod text]... [--check-dod n]... [--uncheck-dod n]... [--remove-dod n]...
                     [--plan text] [--append-plan text] [--notes text] [--append-notes text]
                     [--final-summary text] [--append-final-summary text] [--comment text] [--comment-author who]
                     [--dep id]... [--remove-dep id]... [--ref x]... [--doc x]... [--due-date day|""]
                     [--ordinal n] [--force] [--expected-revision r]
      task archive <id>  |  task restore <id>  |  task delete <id> --yes   (only after the user's yes)
      search <words>
      project
      instructions [overview|task-creation|task-execution|task-finalization]
      mcp start [--cwd folder]

    Statuses: To Do, In Progress, Done. Add --json for data, --cwd <folder> for another project folder.
    """

    /// The `--cwd` value, wherever it is.
    public static func cwdOverride(_ argv: [String]) throws -> String? {
        guard let i = argv.firstIndex(of: "--cwd") else { return nil }
        guard i + 1 < argv.count else { throw UsageError("--cwd needs a folder.") }
        return argv[i + 1]
    }

    public static func parse(_ raw: [String]) throws -> Command {
        var argv = raw
        if let i = argv.firstIndex(of: "--cwd") {
            guard i + 1 < argv.count else { throw UsageError("--cwd needs a folder.") }
            if argv.first != "mcp" { argv.removeSubrange(i...(i + 1)) }
        }
        guard let head = argv.first, head != "--help", head != "-h", head != "help" else { return .help(usage) }
        let rest = Array(argv.dropFirst())
        switch head {
        case "task", "tasks": return try task(rest)
        case "search":
            var p = Flags(rest, known: ["--json": .bool, "--limit": .value])
            let words = try p.positionals()
            guard !words.isEmpty else { throw UsageError("search needs words.") }
            var args: [String: JSONValue] = ["query": .string(words.joined(separator: " "))]
            if let l = try p.int("--limit") { args["limit"] = .int(l) }
            return .request(op: "task_search", args: args, json: p.has("--json"))
        case "project":
            return .request(op: "project_info", args: [:], json: false)
        case "instructions":
            let name = rest.first ?? "overview"
            guard TrackerGuides.guide(named: name) != nil else {
                throw UsageError("Unknown guide: \(name). Valid: " + TrackerGuides.all.map(\.name).joined(separator: ", "))
            }
            return .instructions(name)
        case "mcp":
            guard rest.first == "start" else { throw UsageError("Use: mcp start [--cwd folder]") }
            return .mcpStart(cwd: try cwdOverride(rest))
        default:
            throw UsageError("Unknown command: \(head). Run metawhisp-cli --help.")
        }
    }

    private static func task(_ argv: [String]) throws -> Command {
        guard let verb = argv.first else { throw UsageError("Use: task create|list|view|edit|archive|restore|delete") }
        let rest = Array(argv.dropFirst())
        switch verb {
        case "create":
            var p = Flags(rest, known: createFlags)
            let title = try p.positionals().joined(separator: " ")
            guard !title.isEmpty else { throw UsageError("task create needs a title.") }
            var args: [String: JSONValue] = ["title": .string(title)]
            try p.copy(into: &args, [("-d", "description"), ("--description", "description"), ("-s", "status"),
                                     ("--status", "status"), ("--priority", "priority"), ("--type", "type"),
                                     ("-p", "parentTaskId"), ("--parent", "parentTaskId"), ("--due-date", "dueDate"),
                                     ("--final-summary", "finalSummary")])
            try p.copyLists(into: &args, [(["-l", "--labels"], "labels", true), (["-a", "--assignee"], "assignee", true),
                                          (["--ac"], "acceptanceCriteria", false), (["--dod"], "definitionOfDoneAdd", false),
                                          (["--dep"], "dependencies", true), (["--ref"], "references", false),
                                          (["--doc"], "documentation", false), (["--modified-file"], "modifiedFiles", false)])
            if let o = try p.double("--ordinal") { args["ordinal"] = .double(o) }
            return .request(op: "task_create", args: args, json: p.has("--json"))
        case "list":
            var p = Flags(rest, known: ["-s": .value, "--status": .value, "-a": .value, "--assignee": .value,
                                        "--unassigned": .bool, "-l": .list, "--labels": .list, "--search": .value,
                                        "--ready": .bool, "--limit": .value, "--json": .bool])
            _ = try p.positionals(max: 0)
            var args: [String: JSONValue] = [:]
            try p.copy(into: &args, [("-s", "status"), ("--status", "status"), ("-a", "assignee"),
                                     ("--assignee", "assignee"), ("--search", "search")])
            try p.copyLists(into: &args, [(["-l", "--labels"], "labels", true)])
            if p.has("--unassigned") { args["unassigned"] = .bool(true) }
            if p.has("--ready") { args["ready"] = .bool(true) }
            if let l = try p.int("--limit") { args["limit"] = .int(l) }
            return .request(op: "task_list", args: args, json: p.has("--json"))
        case "view", "archive", "restore":
            var p = Flags(rest, known: ["--json": .bool])
            let id = try single(try p.positionals(), verb)
            return .request(op: "task_\(verb)", args: ["id": .string(id)], json: p.has("--json"))
        case "delete":
            var p = Flags(rest, known: ["--yes": .bool, "--json": .bool])
            let id = try single(try p.positionals(), verb)
            return .request(op: "task_delete", args: ["id": .string(id), "userConfirmed": .bool(p.has("--yes"))],
                            json: false)
        case "edit":
            var p = Flags(rest, known: editFlags)
            let id = try single(try p.positionals(), verb)
            var args: [String: JSONValue] = ["id": .string(id)]
            try p.copy(into: &args, [("-t", "title"), ("--title", "title"), ("-d", "description"),
                                     ("--description", "description"), ("-s", "status"), ("--status", "status"),
                                     ("--priority", "priority"), ("--type", "type"), ("--plan", "planSet"),
                                     ("--notes", "notesSet"), ("--final-summary", "finalSummary"),
                                     ("--comment-author", "commentAuthor")])
            try p.copyLists(into: &args, [(["-l", "--labels"], "labels", true), (["-a", "--assignee"], "assignee", true),
                                          (["--ac"], "acceptanceCriteriaAdd", false),
                                          (["--dod"], "definitionOfDoneAdd", false),
                                          // --dep adds, like --ref and --doc; it never drops the others.
                                          (["--dep"], "addDependencies", false),
                                          (["--remove-dep"], "removeDependencies", false),
                                          (["--ref"], "addReferences", false),
                                          (["--doc"], "addDocumentation", false),
                                          (["--modified-file"], "modifiedFiles", false),
                                          (["--append-plan"], "planAppend", false),
                                          (["--append-notes"], "notesAppend", false),
                                          (["--append-final-summary"], "finalSummaryAppend", false),
                                          (["--comment"], "commentsAppend", false)])
            for (flag, key) in [("--check-ac", "acceptanceCriteriaCheck"), ("--uncheck-ac", "acceptanceCriteriaUncheck"),
                                ("--remove-ac", "acceptanceCriteriaRemove"), ("--check-dod", "definitionOfDoneCheck"),
                                ("--uncheck-dod", "definitionOfDoneUncheck"), ("--remove-dod", "definitionOfDoneRemove")] {
                let ns = try p.ints(flag)
                if !ns.isEmpty { args[key] = .array(ns.map { .int($0) }) }
            }
            if let due = p.values("--due-date").last { args["dueDate"] = due.isEmpty ? .null : .string(due) }
            if let o = try p.double("--ordinal") { args["ordinal"] = .double(o) }
            if p.has("--force") { args["force"] = .bool(true) }
            if let r = p.values("--expected-revision").last { args["expectedRevision"] = .string(r) }
            return .request(op: "task_edit", args: args, json: p.has("--json"))
        default:
            // `task 12` = `task view 12`.
            if TrackerKey(parsing: verb) != nil, rest.allSatisfy({ $0 == "--json" }) {
                return .request(op: "task_view", args: ["id": .string(verb)], json: rest.contains("--json"))
            }
            throw UsageError("Unknown task command: \(verb).")
        }
    }

    private static func single(_ ids: [String], _ verb: String) throws -> String {
        guard ids.count == 1 else { throw UsageError("task \(verb) needs one task ID.") }
        return ids[0]
    }

    private static let createFlags: [String: Flags.Kind] = [
        "-d": .value, "--description": .value, "-s": .value, "--status": .value, "--priority": .value,
        "--type": .value, "-l": .list, "--labels": .list, "-a": .list, "--assignee": .list, "--ac": .list,
        "--dod": .list, "-p": .value, "--parent": .value, "--dep": .list, "--ref": .list, "--doc": .list,
        "--modified-file": .list, "--due-date": .value, "--ordinal": .value, "--final-summary": .value, "--json": .bool,
    ]

    private static let editFlags: [String: Flags.Kind] = [
        "-t": .value, "--title": .value, "-d": .value, "--description": .value, "-s": .value, "--status": .value,
        "--priority": .value, "--type": .value, "-l": .list, "--labels": .list, "-a": .list, "--assignee": .list,
        "--ac": .list, "--check-ac": .list, "--uncheck-ac": .list, "--remove-ac": .list, "--dod": .list,
        "--check-dod": .list, "--uncheck-dod": .list, "--remove-dod": .list, "--plan": .value, "--append-plan": .list,
        "--notes": .value, "--append-notes": .list, "--final-summary": .value, "--append-final-summary": .list,
        "--comment": .list, "--comment-author": .value, "--dep": .list, "--remove-dep": .list, "--ref": .list,
        "--doc": .list, "--modified-file": .list, "--due-date": .value, "--ordinal": .value, "--force": .bool,
        "--expected-revision": .value, "--json": .bool,
    ]

    /// Splits a command line like a shell would for quotes and backslashes (tests and the help examples).
    public static func split(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inWord = false
        var quote: Character?
        var escape = false
        for ch in line {
            if escape { cur.append(ch); escape = false; inWord = true; continue }
            if ch == "\\" && quote != "'" { escape = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; inWord = true; continue }
            if ch.isWhitespace {
                if inWord { out.append(cur); cur = ""; inWord = false }
                continue
            }
            cur.append(ch)
            inWord = true
        }
        if inWord { out.append(cur) }
        return out
    }

    /// Flags and positional words of one command.
    struct Flags {
        enum Kind { case bool, value, list }

        private var seen: [String: [String]] = [:]
        private var words: [String] = []
        private var problem: UsageError?

        init(_ argv: [String], known: [String: Kind]) {
            var i = 0
            while i < argv.count {
                let a = argv[i]
                if a.hasPrefix("-"), a.count > 1, Double(a) == nil {
                    guard let kind = known[a] else { problem = UsageError("Unknown option: \(a)"); return }
                    if kind == .bool { seen[a, default: []].append("true"); i += 1; continue }
                    guard i + 1 < argv.count else { problem = UsageError("\(a) needs a value."); return }
                    seen[a, default: []].append(argv[i + 1])
                    i += 2
                } else {
                    words.append(a)
                    i += 1
                }
            }
        }

        mutating func positionals(max: Int = .max) throws -> [String] {
            if let problem { throw problem }
            if words.count > max { throw UsageError("Unexpected: \(words.joined(separator: " "))") }
            return words
        }

        func has(_ flag: String) -> Bool { seen[flag] != nil }
        func values(_ flag: String) -> [String] { seen[flag] ?? [] }

        func copy(into args: inout [String: JSONValue], _ map: [(String, String)]) throws {
            if let problem { throw problem }
            for (flag, key) in map { if let v = values(flag).last { args[key] = .string(v) } }
        }

        /// `comma`: "a,b" splits into two entries.
        func copyLists(into args: inout [String: JSONValue], _ map: [([String], String, Bool)]) throws {
            if let problem { throw problem }
            for (flags, key, comma) in map {
                var items: [String] = flags.flatMap { values($0) }
                if comma {
                    items = items.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                        .filter { !$0.isEmpty }
                }
                if !items.isEmpty { args[key] = .array(items.map { .string($0) }) }
            }
        }

        func int(_ flag: String) throws -> Int? {
            guard let v = values(flag).last else { return nil }
            guard let n = Int(v) else { throw UsageError("\(flag) needs a whole number.") }
            return n
        }

        func ints(_ flag: String) throws -> [Int] {
            try values(flag).flatMap { $0.split(separator: ",") }.map { s in
                guard let n = Int(s.trimmingCharacters(in: .whitespaces)) else {
                    throw UsageError("\(flag) needs whole numbers.")
                }
                return n
            }
        }

        func double(_ flag: String) throws -> Double? {
            guard let v = values(flag).last else { return nil }
            guard let n = Double(v) else { throw UsageError("\(flag) needs a number.") }
            return n
        }
    }
}
