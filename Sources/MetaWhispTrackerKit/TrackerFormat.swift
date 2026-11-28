import Foundation

/// FEAT-0006 §6 — the plain text agents read: task lines, lists grouped by column, search results, a task view.
public enum TrackerFormat {

    public static func line(_ t: TrackerTaskSummary, withStatus: Bool = false) -> String {
        var s = "  "
        if let p = t.priority { s += "[\(p.uppercased())] " }
        if let type = t.type { s += "[\(type)] " }
        s += "\(t.id) - \(t.title)"
        // In Progress says who holds it and since when: live work and work someone left look alike otherwise.
        let holder: String? = t.status == TrackerStatus.inProgress.rawValue && !t.archived
            ? (t.assignee.isEmpty ? (t.heldBy ?? "no assignee") : t.assignee.joined(separator: ", "))
                + (t.startedAt.map { ", since \(day($0))" } ?? "")
            : nil
        if withStatus { s += " (\(t.status)\(t.archived ? ", archived" : "")\(holder.map { ", \($0)" } ?? ""))" }
        if t.acceptanceCriteriaCount > 0 { s += " (ac: \(t.acceptanceCriteriaCompleted)/\(t.acceptanceCriteriaCount))" }
        if let due = t.dueDate { s += " (due \(due))" }
        if !withStatus, let holder { s += " (\(holder))" }
        return s
    }

    /// Sections in board order; the input order inside a section is kept.
    public static func list(project: String, tasks: [TrackerTaskSummary]) -> String {
        var out = "Project: \(project)\n\n"
        guard !tasks.isEmpty else { return out + "No tasks found." }
        let sections = TrackerStatus.allCases.compactMap { status -> String? in
            let rows = tasks.filter { $0.status == status.rawValue }
            guard !rows.isEmpty else { return nil }
            return "\(status.rawValue):\n" + rows.map { line($0) }.joined(separator: "\n")
        }
        out += sections.joined(separator: "\n\n")
        return out
    }

    public static func search(project: String, query: String, tasks: [TrackerTaskSummary]) -> String {
        let head = "Project: \(project)\n\n"
        guard !tasks.isEmpty else {
            return head + (query.isEmpty ? "No tasks found." : "No tasks found for \"\(query)\".")
        }
        return head + "Tasks:\n" + tasks.map { line($0, withStatus: true) }.joined(separator: "\n")
    }

    public static func view(_ d: TrackerTaskDetail) -> String {
        let t = d.summary
        let rule = String(repeating: "-", count: 50)
        var head: [String] = ["Task \(t.id) - \(t.title)", String(repeating: "=", count: 50), ""]
        let icon = TrackerStatus(rawValue: t.status)?.icon ?? "○"
        head.append("Status: \(icon) \(t.status)\(t.archived ? " (archived)" : "")")
        if let p = t.priority { head.append("Priority: \(TrackerPriority(rawValue: p)?.display ?? p)") }
        if let type = t.type { head.append("Type: \(type)") }
        head.append("Project: \(t.project)")
        if !t.assignee.isEmpty { head.append("Assignee: \(t.assignee.joined(separator: ", "))") }
        head.append("Created: \(timestamp(t.createdAt))")
        if let started = t.startedAt {
            head.append("Started: \(timestamp(started))\(t.heldBy.map { " by \($0)" } ?? "")")
        }
        if t.updatedAt != t.createdAt { head.append("Updated: \(timestamp(t.updatedAt))") }
        head.append("Revision: \(t.revision)")
        if let due = t.dueDate { head.append("Due: \(due)") }
        if !t.labels.isEmpty { head.append("Labels: \(t.labels.joined(separator: ", "))") }
        if let p = d.parent { head.append("Parent: \(p.id) - \(p.title)") }
        if !d.subtasks.isEmpty {
            head.append("Subtasks (\(d.subtasks.count)):")
            head += d.subtasks.map { "- \($0.id) - \($0.title)" }
        }
        if !d.references.isEmpty { head.append("References: \(d.references.joined(separator: ", "))") }
        if !d.documentation.isEmpty { head.append("Documentation: \(d.documentation.joined(separator: ", "))") }
        if !d.dependsOn.isEmpty {
            head.append("Depends on:")
            head += d.dependsOn.map { "- \($0.id) - \($0.title) [\($0.status)]" }
        }
        if !d.dependents.isEmpty {
            head.append("Dependents:")
            head += d.dependents.map { "- \($0.id) - \($0.title) [\($0.status)]" }
        }

        var blocks: [String] = [head.joined(separator: "\n")]
        func block(_ title: String, _ body: String) { blocks.append("\(title):\n\(rule)\n\(body)") }
        block("Description", nonEmpty(d.description) ?? "No description provided")
        block("Acceptance Criteria", d.acceptanceCriteria.isEmpty
              ? "No acceptance criteria defined" : checklist(d.acceptanceCriteria))
        block("Definition of Done", d.definitionOfDone.isEmpty
              ? "No Definition of Done items defined" : checklist(d.definitionOfDone))
        if let plan = nonEmpty(d.implementationPlan) { block("Implementation Plan", plan) }
        if let notes = nonEmpty(d.implementationNotes) { block("Implementation Notes", notes) }
        if !d.modifiedFiles.isEmpty { block("Modified files", d.modifiedFiles.map { "- \($0)" }.joined(separator: "\n")) }
        if !d.comments.isEmpty {
            block("Comments", d.comments.map { c in
                "#\(c.index)\(c.author.map { " - \($0)" } ?? "") - \(timestamp(c.createdAt))\n\(c.body)"
            }.joined(separator: "\n\n"))
        }
        if let summary = nonEmpty(d.finalSummary) { block("Final Summary", summary) }
        // Q3 — what happened to it, newest last: a card the user dragged back from Done says so here.
        if !d.history.isEmpty {
            block("History", d.history.suffix(10).map { e in
                "\(timestamp(e.at)) · \(e.by ?? "unknown") · \(e.from.map { "\($0) → " } ?? "created in ")\(e.to)"
            }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// A write's answer: the task's line, its criteria ticks, and the revision to send with the next edit.
    public static func brief(_ d: TrackerTaskDetail) -> String {
        var out = line(d.summary, withStatus: true).trimmingCharacters(in: .whitespaces)
        if !d.acceptanceCriteria.isEmpty { out += "\nAcceptance Criteria:\n" + checklist(d.acceptanceCriteria) }
        if !d.definitionOfDone.isEmpty { out += "\nDefinition of Done:\n" + checklist(d.definitionOfDone) }
        return out + "\nRevision: \(d.summary.revision)"
    }

    static func checklist(_ items: [TrackerChecklistEntry]) -> String {
        items.map { "- [\($0.checked ? "x" : " ")] #\($0.index) \($0.text)" }.joined(separator: "\n")
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    public static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date) + " UTC"
    }

    /// A due date names a day: `YYYY-MM-DD` in UTC.
    public static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
