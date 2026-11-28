import Foundation

// FEAT-0006 §3.4, §4, §5 — the pure tracker rules.

// MARK: - IDs

/// A task's number inside its project: `TASK-12`, or `TASK-12.1` for a subtask.
public struct TrackerKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public static let prefix = "TASK"

    public let segments: [Int]

    public init(segments: [Int]) {
        self.segments = segments
    }

    /// Accepts `TASK-12`, `task-012`, `12`, `TASK-12.1`; case and leading zeros are ignored.
    public init?(parsing raw: String) {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = Self.prefix + "-"
        if body.uppercased().hasPrefix(head) { body = String(body.dropFirst(head.count)) }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var segments: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            segments.append(n)
        }
        self.segments = segments
    }

    /// What the store keeps: `12` or `12.1`.
    public var stored: String { segments.map(String.init).joined(separator: ".") }
    /// What people and agents see: `TASK-12.1`.
    public var display: String { Self.prefix + "-" + stored }
    public var description: String { display }
    public var isTopLevel: Bool { segments.count == 1 }

    public static func < (a: TrackerKey, b: TrackerKey) -> Bool {
        a.segments.lexicographicallyPrecedes(b.segments)
    }

    /// One above the highest top-level number; subtask numbers do not count.
    public static func nextTopLevel(existing: [TrackerKey]) -> TrackerKey {
        let top = existing.filter(\.isTopLevel).map { $0.segments[0] }.max() ?? 0
        return TrackerKey(segments: [top + 1])
    }

    /// One above the parent's highest direct child.
    public static func nextSubtask(of parent: TrackerKey, existing: [TrackerKey]) -> TrackerKey {
        let depth = parent.segments.count
        let children = existing.filter {
            $0.segments.count == depth + 1 && Array($0.segments.prefix(depth)) == parent.segments
        }
        let last = children.map { $0.segments[depth] }.max() ?? 0
        return TrackerKey(segments: parent.segments + [last + 1])
    }
}

// MARK: - Order

/// Board order: tasks with an ordinal first (ascending), then priority (high first), then ID numerically.
public struct TrackerSortKey: Sendable {
    public var ordinal: Double?
    public var priority: TrackerPriority?
    public var key: TrackerKey?
    public var createdAt: Date

    public init(ordinal: Double?, priority: TrackerPriority?, key: TrackerKey?, createdAt: Date = .distantPast) {
        self.ordinal = ordinal
        self.priority = priority
        self.key = key
        self.createdAt = createdAt
    }

    public static let ordinalStep: Double = 1000

    public static func precedes(_ a: TrackerSortKey, _ b: TrackerSortKey) -> Bool {
        switch (a.ordinal, b.ordinal) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        let ra = a.priority?.rank ?? 0, rb = b.priority?.rank ?? 0
        if ra != rb { return ra > rb }
        switch (a.key, b.key) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.createdAt < b.createdAt
        }
    }

    /// A new task goes after the highest ordinal; a board that uses none keeps its default order.
    public static func newOrdinal(existing: [Double?], boardIsEmpty: Bool) -> Double? {
        if let top = existing.compactMap({ $0 }).max() { return top + ordinalStep }
        return boardIsEmpty ? ordinalStep : nil
    }
}

// MARK: - Checklists

public enum ChecklistError: Error, Equatable, Sendable {
    case multiline
    case indexOutOfRange(index: Int, count: Int)

    public var message: String {
        switch self {
        case .multiline:
            return "Each criterion is one line. Add separate entries for separate items."
        case let .indexOutOfRange(index, count):
            return count == 0
                ? "Item #\(index) not found: the list is empty."
                : "Item #\(index) not found. Available indexes: #1-#\(count)."
        }
    }
}

/// Acceptance criteria and definition of done: positional, 1-based, one line per item.
public enum Checklist {
    /// Trimmed text; blank entries are dropped; a line break is refused.
    static func clean(_ texts: [String]) throws -> [String] {
        try texts.compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.contains(where: \.isNewline) { throw ChecklistError.multiline }
            return t.isEmpty ? nil : t
        }
    }

    public static func add(_ list: [ChecklistItem], texts: [String]) throws -> [ChecklistItem] {
        list + (try clean(texts)).map { ChecklistItem(text: $0, checked: false) }
    }

    /// Replaces the list. The same trimmed text keeps its tick, each old entry used once, in order.
    public static func set(_ old: [ChecklistItem], to texts: [String]) throws -> [ChecklistItem] {
        var unused = Array(old.indices)
        return try clean(texts).map { text in
            if let pos = unused.firstIndex(where: { old[$0].text == text }) {
                let item = old[unused.remove(at: pos)]
                return ChecklistItem(text: text, checked: item.checked)
            }
            return ChecklistItem(text: text, checked: false)
        }
    }

    /// One edit of a list, in the spec's order (§4): set, add, remove, then check and uncheck by the indexes of the
    /// list that results. Both lists of a task go through it, so their order cannot drift apart: the definition of
    /// done once removed last, so a check meant for the item that moved up ticked the removed one (Codex review).
    public static func edit(_ list: [ChecklistItem], set texts: [String]? = nil, add: [String] = [],
                            remove removed: [Int] = [], check: [Int] = [], uncheck: [Int] = []) throws -> [ChecklistItem] {
        var out = list
        if let texts { out = try set(out, to: texts) }
        out = try self.add(out, texts: add)
        out = try remove(out, indexes: removed)
        out = try mark(out, indexes: check, checked: true)
        return try mark(out, indexes: uncheck, checked: false)
    }

    public static func remove(_ list: [ChecklistItem], indexes: [Int]) throws -> [ChecklistItem] {
        try validate(indexes, count: list.count)
        var out = list
        for i in Set(indexes).sorted(by: >) { out.remove(at: i - 1) }
        return out
    }

    public static func mark(_ list: [ChecklistItem], indexes: [Int], checked: Bool) throws -> [ChecklistItem] {
        try validate(indexes, count: list.count)
        var out = list
        for i in indexes { out[i - 1].checked = checked }
        return out
    }

    private static func validate(_ indexes: [Int], count: Int) throws {
        if let bad = indexes.first(where: { $0 < 1 || $0 > count }) {
            throw ChecklistError.indexOutOfRange(index: bad, count: count)
        }
    }

    public static func entries(_ list: [ChecklistItem]) -> [TrackerChecklistEntry] {
        list.enumerated().map { TrackerChecklistEntry(index: $0.offset + 1, text: $0.element.text,
                                                      checked: $0.element.checked) }
    }
}

// MARK: - Dependencies

public enum DependencyGraph {
    /// The loop a new set of dependencies would close, as `task → … → task`, or nil.
    public static func cycle(adding deps: [UUID], to task: UUID, graph: [UUID: [UUID]]) -> [UUID]? {
        if deps.contains(task) { return [task, task] }
        var next = graph
        next[task] = (graph[task] ?? []) + deps.filter { !(graph[task] ?? []).contains($0) }
        for dep in deps {
            if let path = path(from: dep, to: task, graph: next) { return [task] + path }
        }
        return nil
    }

    private static func path(from start: UUID, to goal: UUID, graph: [UUID: [UUID]]) -> [UUID]? {
        var visited: Set<UUID> = []
        func walk(_ node: UUID) -> [UUID]? {
            if node == goal { return [node] }
            guard visited.insert(node).inserted else { return nil }
            for n in graph[node] ?? [] {
                if let rest = walk(n) { return [node] + rest }
            }
            return nil
        }
        return walk(start)
    }
}

// MARK: - Search

public enum TrackerSearch {
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// nil when some query word is missing; a word in the ID or title counts twice a word in the body.
    public static func score(query: String, id: String, title: String, body: String) -> Int? {
        let words = fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let head = fold(id) + "\n" + fold(title)
        let rest = fold(body)
        var score = 0
        for word in words {
            if head.contains(word) { score += 2 } else if rest.contains(word) { score += 1 } else { return nil }
        }
        return score
    }
}

// MARK: - Project names and folders

public enum ProjectNaming {
    /// Case, accents, spaces, dashes, underscores and dots do not tell projects apart.
    public static func normalized(_ name: String) -> String {
        TrackerSearch.fold(name).filter { !($0.isWhitespace || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    /// D7 — a different name close enough that MetaChat asks "add to it, or a new project?": one starts with the
    /// other, or they are one edit apart; names under four letters never count.
    public static func isSimilar(_ a: String, _ b: String) -> Bool {
        let x = normalized(a), y = normalized(b)
        guard x != y, min(x.count, y.count) >= 4 else { return false }
        if x.hasPrefix(y) || y.hasPrefix(x) { return true }
        return editDistance(x, y, limit: 1) <= 1
    }

    /// Levenshtein distance, stopped early past `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let s = Array(a), t = Array(b)
        if abs(s.count - t.count) > limit { return limit + 1 }
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            cur[0] = i
            var best = cur[0]
            for j in 1...t.count {
                cur[j] = s[i - 1] == t[j - 1] ? prev[j - 1] : 1 + min(prev[j - 1], prev[j], cur[j - 1])
                best = min(best, cur[j])
            }
            if best > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }

    /// `/`, the home folder and a folder directly under `/` are never a project's folder.
    public static func isRefusedFolder(_ path: String, home: String) -> Bool {
        let p = trimmed(path), h = trimmed(home)
        if p == "/" || p.isEmpty || p == h { return true }
        return URL(fileURLWithPath: p).standardizedFileURL.pathComponents.count <= 2
    }

    public static func projectName(forFolder path: String) -> String {
        URL(fileURLWithPath: trimmed(path)).lastPathComponent
    }

    /// A remembered folder covers itself and its subfolders.
    public static func folder(_ remembered: String, covers path: String) -> Bool {
        let r = trimmed(remembered), p = trimmed(path)
        return p == r || p.hasPrefix(r == "/" ? "/" : r + "/")
    }

    public static func trimmed(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

/// FEAT-0006 §5.1 — the folder a working directory belongs to: its repository (a worktree belongs to its
/// repository), or the directory itself.
public enum ProjectRoot {
    public static func resolve(workingDirectory: String, home: String,
                               fileManager: FileManager = .default) -> String {
        let start = URL(fileURLWithPath: workingDirectory).standardizedFileURL.resolvingSymlinksInPath()
        let stop = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
        var dir = start
        while dir.path != stop && dir.path != "/" {
            let git = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return dir.path }
                return repository(ofWorktreeFile: git, in: dir) ?? dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return start.path
    }

    /// A worktree's `.git` file reads `gitdir: <repo>/.git/worktrees/<name>`; anything else (a submodule) is not a
    /// worktree.
    private static func repository(ofWorktreeFile file: URL, in dir: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else {
            return nil
        }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let target = URL(fileURLWithPath: raw, relativeTo: dir).standardizedFileURL.resolvingSymlinksInPath().path
        guard let range = target.range(of: "/.git/worktrees/") else { return nil }
        return String(target[..<range.lowerBound])
    }
}
