import EventKit
import Foundation
import SwiftData

/// Writes a per-meeting Markdown file into the user's Obsidian vault when a
/// meeting closes (2026-04-29). Companion to `ObsidianSyncService` (which
/// appends individual memories to a chronological `Journal.md`) — this one
/// emits a self-contained file per meeting with the full transcript, action
/// items, memories, and (optional) calendar event metadata.
///
/// File path: `<vault>/MetaWhisp/Meetings/YYYY-MM-DD · <safe-title>.md`
///
/// When the meeting matched a calendar event (via `CalendarReaderService`),
/// this writer ALSO patches the EKEvent's `notes` field with a back-link to
/// the Markdown file (Obsidian URI scheme `obsidian://open?...`), so the user
/// sees a transcript link in macOS Calendar.app.
@MainActor
final class MeetingObsidianWriter {
    static let shared = MeetingObsidianWriter()

    private let settings = AppSettings.shared
    private let store = EKEventStore()

    private init() {}

    /// Build + write the per-meeting markdown. Idempotent — overwriting an
    /// existing file with the same path is safe (later passes typically have
    /// more extracted content).
    func write(
        conversationId: UUID,
        modelContainer: ModelContainer
    ) async {
        guard settings.obsidianSyncEnabled else { return }
        let vault = settings.obsidianVaultPath.trimmingCharacters(in: .whitespaces)
        guard !vault.isEmpty else { return }

        let ctx = ModelContext(modelContainer)
        var convDesc = FetchDescriptor<Conversation>()
        convDesc.fetchLimit = 1000
        let allConv = (try? ctx.fetch(convDesc)) ?? []
        guard let conv = allConv.first(where: { $0.id == conversationId }) else { return }

        // Tasks linked to this conversation.
        var taskDesc = FetchDescriptor<TaskItem>()
        taskDesc.fetchLimit = 500
        let allTasks = (try? ctx.fetch(taskDesc)) ?? []
        let tasks = allTasks.filter { $0.conversationId == conversationId }

        // Memories linked.
        var memDesc = FetchDescriptor<UserMemory>()
        memDesc.fetchLimit = 500
        let allMems = (try? ctx.fetch(memDesc)) ?? []
        let memories = allMems.filter { $0.conversationId == conversationId && !$0.isDismissed }

        // Transcripts (HistoryItem) for this conversation — concatenated.
        var histDesc = FetchDescriptor<HistoryItem>()
        histDesc.fetchLimit = 500
        let allHist = (try? ctx.fetch(histDesc)) ?? []
        let transcripts = allHist.filter { $0.conversationId == conversationId }
            .sorted { $0.createdAt < $1.createdAt }
        let fullTranscript = transcripts.map { $0.text }.joined(separator: "\n\n")

        // Filename.
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let day = dayFormatter.string(from: conv.startedAt)
        let title = (conv.title?.isEmpty == false ? conv.title! : "Meeting")
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = "\(day) · \(safeTitle).md"

        // Ensure folder exists.
        let vaultURL = URL(fileURLWithPath: vault, isDirectory: true)
        let dirURL = vaultURL.appendingPathComponent("MetaWhisp", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            NSLog("[MeetingObsidian] mkdir failed: %@", error.localizedDescription)
            return
        }
        let fileURL = dirURL.appendingPathComponent(filename)

        // Build markdown.
        var md = "---\n"
        md += "type: meeting\n"
        md += "date: \(day)\n"
        if let cat = conv.category, !cat.isEmpty { md += "category: \(cat)\n" }
        if let calTitle = conv.calendarEventTitle { md += "calendar_event: \"\(calTitle)\"\n" }
        if let started = conv.startedAt as Date? {
            let iso = ISO8601DateFormatter()
            md += "started: \(iso.string(from: started))\n"
        }
        if let finished = conv.finishedAt {
            let iso = ISO8601DateFormatter()
            md += "finished: \(iso.string(from: finished))\n"
        }
        md += "tags: [meeting, metawhisp]\n"
        md += "---\n\n"

        if let emoji = conv.emoji, !emoji.isEmpty {
            md += "# \(emoji) \(title)\n\n"
        } else {
            md += "# \(title)\n\n"
        }

        if let overview = conv.overview, !overview.isEmpty {
            md += "## Summary\n\n\(overview)\n\n"
        }

        if !tasks.isEmpty {
            md += "## Action Items\n\n"
            for t in tasks {
                let mark = t.completed ? "x" : " "
                let assignee = t.assignee.map { " (waiting on \($0))" } ?? ""
                md += "- [\(mark)] \(t.taskDescription)\(assignee)\n"
            }
            md += "\n"
        }

        if !memories.isEmpty {
            md += "## Memories\n\n"
            for m in memories {
                if let kind = m.kind, let subj = m.subject, !subj.isEmpty,
                   let charact = m.characterization, !charact.isEmpty {
                    md += "- **[\(kind.uppercased())]** \(subj) — \(charact)\n"
                } else {
                    md += "- \(m.content)\n"
                }
            }
            md += "\n"
        }

        if !fullTranscript.isEmpty {
            md += "## Transcript\n\n\(fullTranscript)\n"
        }

        // Write atomically.
        do {
            try md.write(to: fileURL, atomically: true, encoding: .utf8)
            NSLog("[MeetingObsidian] ✅ wrote %@", fileURL.path)
        } catch {
            NSLog("[MeetingObsidian] write failed: %@", error.localizedDescription)
            return
        }

        // Calendar back-link (if matched).
        if let eventId = conv.calendarEventId {
            patchCalendarEventNotes(eventId: eventId, vaultName: vaultURL.lastPathComponent, relativePath: "MetaWhisp/Meetings/\(filename)")
        }
    }

    /// Append `obsidian://open?vault=X&file=Y` to the matched EKEvent's notes
    /// so the user sees a transcript link inside macOS Calendar.app. Idempotent
    /// — checks if a previous MetaWhisp link is already present and replaces it.
    private func patchCalendarEventNotes(eventId: String, vaultName: String, relativePath: String) {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return }
        guard let event = store.event(withIdentifier: eventId) else { return }

        let encoded: (String) -> String = {
            $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0
        }
        let link = "obsidian://open?vault=\(encoded(vaultName))&file=\(encoded(relativePath.replacingOccurrences(of: ".md", with: "")))"
        let marker = "📝 MetaWhisp transcript:"
        let newLine = "\(marker) \(link)"

        var notes = event.notes ?? ""
        // Remove any prior MetaWhisp line (idempotent).
        let lines = notes.components(separatedBy: "\n").filter { !$0.contains(marker) }
        notes = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { notes += "\n\n" }
        notes += newLine
        event.notes = notes

        do {
            try store.save(event, span: .thisEvent, commit: true)
            NSLog("[MeetingObsidian] patched calendar event %@ with transcript link", eventId)
        } catch {
            NSLog("[MeetingObsidian] calendar patch failed: %@", error.localizedDescription)
        }
    }
}
