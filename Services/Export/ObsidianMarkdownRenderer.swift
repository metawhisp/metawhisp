import Foundation

/// Pure-function rendering of MetaWhisp entities → Obsidian-flavoured Markdown
/// with YAML frontmatter (ITER-035). No FileManager, no SwiftData. Caller
/// gathers the data, hands a value-struct in, gets a string back. Test surface
/// is `ObsidianMarkdownRendererTests`.
///
/// Why structs instead of @Model directly: SwiftData @Model instances aren't
/// Sendable, can't easily be passed through pure layers, and force tests to
/// spin up a ModelContainer. The renderer takes plain Codable value types;
/// the caller (`ObsidianExporter`) maps from @Model → struct before calling.
enum ObsidianMarkdownRenderer {

    // MARK: - Input value-types (one per entity)

    struct VoiceInput {
        let id: UUID
        let createdAt: Date
        let project: String?            // Conversation.primaryProject (nil → "Untagged")
        let conversationId: UUID?       // wikilink target
        let language: String?           // "ru" | "en" | …
        let sourceApp: String?          // App where dictation happened
        let textRaw: String?            // verbatim transcription
        let textProcessed: String?      // structured / clean text if available
        let durationSec: Double?        // audio length
    }

    struct MeetingInput {
        let id: UUID                    // Conversation.id
        let title: String
        let emoji: String?
        let startedAt: Date
        let finishedAt: Date?
        let calendarEventTitle: String?
        let calendarAttendees: [String]
        let overview: String?
        let actionItems: [String]       // already extracted task summaries
        let memoriesInline: [String]    // short bullets for in-meeting memories
        let fullTranscript: String?
    }

    struct TaskInput {
        let id: UUID
        let taskID: String              // "T-0001" prefix
        let description: String
        let createdAt: Date
        let dueAt: Date?
        let completed: Bool
        let assignee: String?
        let priority: String?           // "high"|"normal"|"low"
        let project: String?            // (если будет когда-нибудь — пока nil)
        let conversationId: UUID?       // wikilink target
        let sourceApp: String?
    }

    struct MemoryInput {
        let id: UUID
        let content: String             // канонический текст memory
        let headline: String?
        let reasoning: String?
        let category: String            // "system"|"interesting"
        let kind: String?               // "person"|"project"|"decision"|"preference"|"fact"
        let subject: String?
        let characterization: String?
        let project: String?            // UserMemory.project (nil → "General")
        let sourceApp: String
        let confidence: Double
        let createdAt: Date
        let tagsCSV: String?
        let conversationId: UUID?
    }

    struct InsightInput {
        let id: UUID
        let body: String                // ≤120 chars actionable advice
        let headline: String?
        let reasoning: String?
        let category: String            // productivity/communication/learning/other
        let sourceApp: String
        let confidence: Double
        let createdAt: Date
    }

    // MARK: - Renderers

    static func renderVoice(_ v: VoiceInput) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("type: voice")
        lines.append("id: \(v.id.uuidString)")
        lines.append("created: \(iso(v.createdAt))")
        if let p = v.project, !p.isEmpty {
            lines.append("project: \(yamlString(p))")
        }
        if let cid = v.conversationId {
            lines.append("conversation_id: \(cid.uuidString)")
        }
        if let lang = v.language, !lang.isEmpty {
            lines.append("language: \(lang)")
        }
        if let app = v.sourceApp, !app.isEmpty {
            lines.append("source_app: \(yamlString(app))")
        }
        if let d = v.durationSec {
            lines.append(String(format: "duration_sec: %.1f", d))
        }
        lines.append("tags: [voice, metawhisp]")
        lines.append("---")
        lines.append("")

        let title = ObsidianPath.conversationProjectFolderName(v.project)
        lines.append("# Voice — \(title) (\(timeOfDay(v.createdAt)))")
        lines.append("")

        if let processed = v.textProcessed,
           !processed.isEmpty,
           processed != v.textRaw {
            lines.append("## Cleaned")
            lines.append("")
            lines.append(processed)
            lines.append("")
        }

        if let raw = v.textRaw, !raw.isEmpty {
            lines.append("## Raw transcription")
            lines.append("")
            lines.append(raw)
            lines.append("")
        }

        if let cid = v.conversationId {
            lines.append("---")
            lines.append("Part of: [[Conversations/\(cid.uuidString)]]")
        }

        return lines.joined(separator: "\n")
    }

    static func renderMeeting(_ m: MeetingInput) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("type: meeting")
        lines.append("id: \(m.id.uuidString)")
        lines.append("started: \(iso(m.startedAt))")
        if let f = m.finishedAt {
            lines.append("finished: \(iso(f))")
        }
        if let cal = m.calendarEventTitle {
            lines.append("calendar_event: \(yamlString(cal))")
        }
        if !m.calendarAttendees.isEmpty {
            lines.append("attendees:")
            for a in m.calendarAttendees {
                lines.append("  - \(yamlString(a))")
            }
        }
        lines.append("tags: [meeting, metawhisp]")
        lines.append("---")
        lines.append("")

        let titleLine = m.emoji.map { "# \($0) \(m.title)" } ?? "# \(m.title)"
        lines.append(titleLine)
        lines.append("")

        if let overview = m.overview, !overview.isEmpty {
            lines.append("## Summary")
            lines.append("")
            lines.append(overview)
            lines.append("")
        }

        if !m.actionItems.isEmpty {
            lines.append("## Action items")
            lines.append("")
            for ai in m.actionItems {
                lines.append("- [ ] \(ai)")
            }
            lines.append("")
        }

        if !m.memoriesInline.isEmpty {
            lines.append("## Memories from this meeting")
            lines.append("")
            for mem in m.memoriesInline {
                lines.append("- \(mem)")
            }
            lines.append("")
        }

        if let t = m.fullTranscript, !t.isEmpty {
            lines.append("## Transcript")
            lines.append("")
            lines.append(t)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    static func renderTask(_ t: TaskInput) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("type: task")
        lines.append("id: \(t.id.uuidString)")
        lines.append("task_id: \(t.taskID)")
        lines.append("created: \(iso(t.createdAt))")
        if let d = t.dueAt {
            lines.append("due: \(iso(d))")
        }
        lines.append("completed: \(t.completed)")
        if let a = t.assignee, !a.isEmpty {
            lines.append("assignee: \(yamlString(a))")
        }
        if let p = t.priority, !p.isEmpty {
            lines.append("priority: \(p)")
        }
        if let proj = t.project, !proj.isEmpty {
            lines.append("project: \(yamlString(proj))")
        }
        if let cid = t.conversationId {
            lines.append("conversation_id: \(cid.uuidString)")
        }
        if let app = t.sourceApp, !app.isEmpty {
            lines.append("source_app: \(yamlString(app))")
        }
        lines.append("tags: [task, metawhisp]")
        lines.append("---")
        lines.append("")

        let checkbox = t.completed ? "[x]" : "[ ]"
        lines.append("# \(checkbox) \(t.taskID): \(t.description)")
        lines.append("")

        if let due = t.dueAt {
            lines.append("**Due:** \(humanDate(due))")
            lines.append("")
        }
        if let assignee = t.assignee, !assignee.isEmpty {
            lines.append("**Assignee:** \(assignee)")
            lines.append("")
        }
        if let cid = t.conversationId {
            lines.append("Source: [[Conversations/\(cid.uuidString)]]")
        }

        return lines.joined(separator: "\n")
    }

    static func renderMemory(_ m: MemoryInput) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("type: memory")
        lines.append("id: \(m.id.uuidString)")
        lines.append("created: \(iso(m.createdAt))")
        lines.append("category: \(m.category)")
        if let k = m.kind, !k.isEmpty {
            lines.append("kind: \(k)")
        }
        if let s = m.subject, !s.isEmpty {
            lines.append("subject: \(yamlString(s))")
        }
        if let proj = m.project, !proj.isEmpty {
            lines.append("project: \(yamlString(proj))")
        }
        lines.append("source_app: \(yamlString(m.sourceApp))")
        lines.append(String(format: "confidence: %.2f", m.confidence))
        if let cid = m.conversationId {
            lines.append("conversation_id: \(cid.uuidString)")
        }
        if let tags = m.tagsCSV, !tags.isEmpty {
            let arr = tags.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            lines.append("tags: [\((["memory", "metawhisp"] + arr).joined(separator: ", "))]")
        } else {
            lines.append("tags: [memory, metawhisp]")
        }
        lines.append("---")
        lines.append("")

        let headerText = m.headline?.isEmpty == false ? m.headline! : m.content
        lines.append("# \(headerText)")
        lines.append("")

        if let charact = m.characterization, !charact.isEmpty {
            lines.append(charact)
            lines.append("")
        } else if m.headline != nil {
            // Headline present but no characterization — show full content
            // under heading so файл self-contained
            lines.append(m.content)
            lines.append("")
        }

        if let reasoning = m.reasoning, !reasoning.isEmpty {
            lines.append("## Reasoning")
            lines.append("")
            lines.append(reasoning)
            lines.append("")
        }

        if let cid = m.conversationId {
            lines.append("---")
            lines.append("Source: [[Conversations/\(cid.uuidString)]]")
        }

        return lines.joined(separator: "\n")
    }

    static func renderInsight(_ i: InsightInput) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("type: insight")
        lines.append("id: \(i.id.uuidString)")
        lines.append("created: \(iso(i.createdAt))")
        lines.append("category: \(i.category)")
        lines.append("source_app: \(yamlString(i.sourceApp))")
        lines.append(String(format: "confidence: %.2f", i.confidence))
        lines.append("tags: [insight, metawhisp, \(i.category)]")
        lines.append("---")
        lines.append("")

        if let h = i.headline, !h.isEmpty {
            lines.append("# \(h)")
        } else {
            lines.append("# Insight")
        }
        lines.append("")
        lines.append(i.body)
        lines.append("")

        if let r = i.reasoning, !r.isEmpty {
            lines.append("## Why")
            lines.append("")
            lines.append(r)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Format helpers (pure)

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static func timeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private static func humanDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy 'at' HH:mm"
        return f.string(from: date)
    }

    /// Quote a YAML scalar that may contain special chars. Conservative: always
    /// double-quote and escape internal quotes + backslashes. Safe for any
    /// title / project name / app name string.
    static func yamlString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}
