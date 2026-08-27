import Foundation

/// The user's own open work, put in front of the model instead of hoping it
/// asks for it.
///
/// The agent had `search_tasks` and `search_memories` available for its whole
/// life and called neither, not once, across 36 shipped comments and roughly
/// ninety-five model turns. Nothing was broken: the tools were declared, the
/// executor was wired, the JSON matched. The mandatory workflow in the prompt
/// simply names screen history and nothing else, so screen history is all the
/// model ever looked at — and a comment built only from screens can only ever
/// retell the screen the user is already reading.
///
/// The reference implementation does not make its model go looking either: the
/// user's facts are assembled and placed in the prompt before the call. This is
/// that, ported — with the same three rules it enforces.
///
///   1. A hard cap. Prompt context is a bounded intake, never an export of
///      everything the app knows.
///   2. Rejected and unconfirmed rows stay out. A fact the user has not agreed
///      to is not something to reason from.
///   3. What the user stated about themselves is kept apart from what the app
///      inferred, because the two do not deserve equal weight.
struct InsightContextPack: Equatable {

    /// One row the model may cite, carrying the id the evidence check knows it
    /// by. Injected records have to be citable, or a comment resting on a real
    /// open task gets killed as ungrounded and B makes things worse than A.
    struct Entry: Equatable {
        let id: String
        let text: String
    }

    /// Things the user said they would do, still open.
    var tasks: [Entry] = []
    /// Facts the user stated about themselves.
    var stated: [Entry] = []
    /// Facts the app worked out and the user confirmed.
    var inferred: [Entry] = []

    var isEmpty: Bool { tasks.isEmpty && stated.isEmpty && inferred.isEmpty }

    /// Every entry, for the evidence allowlist.
    var allEntries: [Entry] { tasks + stated + inferred }

    // MARK: - Bounds

    /// Ported caps. The reference bounds by row count; this also bounds by
    /// characters, because one pasted paragraph stored as a "fact" would
    /// otherwise eat the whole budget and push the screen itself out of the
    /// prompt.
    static let maxTasks = 30
    static let maxMemories = 40
    static let maxEntryChars = 220
    static let maxTotalChars = 4000

    /// Trim one record to something quotable without letting it dominate.
    static func clip(_ text: String) -> String {
        let squeezed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard squeezed.count > maxEntryChars else { return squeezed }
        return String(squeezed.prefix(maxEntryChars)) + "…"
    }

    /// Apply the total-character budget, spending it in priority order: open
    /// tasks first (a promise with a deadline outranks a fact about the user),
    /// then what the user said about themselves, then what the app inferred.
    func bounded() -> InsightContextPack {
        var remaining = Self.maxTotalChars
        func take(_ entries: [Entry]) -> [Entry] {
            var kept: [Entry] = []
            for entry in entries {
                let cost = entry.text.count + entry.id.count + 4
                guard cost <= remaining else { break }
                remaining -= cost
                kept.append(entry)
            }
            return kept
        }
        var packed = InsightContextPack()
        packed.tasks = take(Array(tasks.prefix(Self.maxTasks)))
        packed.stated = take(Array(stated.prefix(Self.maxMemories)))
        packed.inferred = take(Array(inferred.prefix(Self.maxMemories)))
        return packed
    }

    // MARK: - Rendering

    /// The block that goes into the user prompt.
    ///
    /// Data, not instructions: each line is a record with the id the model must
    /// cite if it uses it. Deliberately not phrased as guidance — the workflow
    /// belongs in the system prompt and is not this type's business.
    func promptBlock() -> String {
        guard !isEmpty else { return "" }
        var lines: [String] = []
        if !tasks.isEmpty {
            lines.append("OPEN TASKS (the user's own, still not done):")
            lines.append(contentsOf: tasks.map { "  [\($0.id)] \($0.text)" })
        }
        if !stated.isEmpty {
            lines.append("THE USER SAID THIS ABOUT THEMSELVES:")
            lines.append(contentsOf: stated.map { "  [\($0.id)] \($0.text)" })
        }
        if !inferred.isEmpty {
            lines.append("CONFIRMED FACTS ABOUT THE USER:")
            lines.append(contentsOf: inferred.map { "  [\($0.id)] \($0.text)" })
        }
        return lines.joined(separator: "\n")
    }
}
