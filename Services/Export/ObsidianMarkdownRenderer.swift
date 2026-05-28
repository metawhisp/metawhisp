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
        let conversationId: UUID?       // legacy — kept for traceability in frontmatter only
        let language: String?           // "ru" | "en" | …
        let sourceApp: String?          // App where dictation happened
        let textRaw: String?            // verbatim transcription
        let textProcessed: String?      // structured / clean text if available
        let durationSec: Double?        // audio length
        // wikilink target like "MetaWhisp/2026-05-12/conversations/09h15--metawhisp-deploy".
        // Defaulted nil so existing tests + callers that don't yet plug in
        // conversation hubs keep compiling; production callers (Exporter)
        // resolve it from Conversation.title.
        var conversationHubLink: String? = nil
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
        let conversationId: UUID?       // legacy — frontmatter trace only
        let sourceApp: String?
        // Defaulted nil so existing callers stay compiling.
        var conversationHubLink: String? = nil
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
        // wikilink target like "MetaWhisp/<date>/conversations/<time>--<slug>".
        // Defaulted nil for back-compat with existing tests/callers.
        var conversationHubLink: String? = nil
    }

    /// Voice line inside a `ConversationHubInput` — one bullet point per
    /// voice in the conversation, with timestamp + transcript snippet +
    /// optional wikilink to the per-voice file (for full transcript drill-in).
    struct VoiceLine {
        let createdAt: Date
        let snippet: String         // first ~60 chars of cleaned/raw text
        let voiceFileRelativePath: String?  // for wikilink target, e.g. "MetaWhisp/2026-05-12/voices/09h15--MetaWhisp"
    }

    /// Conversation hub — aggregates many voices (and inline memories/tasks)
    /// under a single topic. Replaces the "raw voice file porridge" with
    /// structured topic-level notes. Date-first path: `<date>/conversations/<HHhMM>--<slug>.md`.
    struct ConversationHubInput {
        let id: UUID
        let title: String                       // от StructuredGenerator или fallback snippet
        let emoji: String?                       // optional UI flair
        let startedAt: Date
        let finishedAt: Date?
        let project: String?                     // primaryProject — для wikilink + tag
        let category: String?                    // technology/design/marketing/etc
        let overview: String?                    // optional summary
        let voices: [VoiceLine]                  // every voice in this conversation
        let actionItems: [String]                // extracted tasks (short summaries)
        let memoriesInline: [String]             // extracted memories (short bullets)
    }

    /// Daily summary hub — one per active day. Aggregates pointers to
    /// everything the day contained. Path: `MetaWhisp/<date>/_summary.md`.
    struct DailySummaryInput {
        struct Item {
            let timeOfDay: String                // "09:15"
            let label: String                     // "voice — first snippet" / "task T-0001"
            let wikilink: String                  // target inside [[ ... ]]
        }
        let date: Date
        let voices: [Item]
        let conversations: [Item]
        let tasks: [Item]
        let memories: [Item]
        let insights: [Item]
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
        // tags: kind + per-project tag so the Obsidian Tags pane groups
        // every voice/task/memory mention of the same project together.
        var tags: [String] = ["voice", "metawhisp"]
        if let pTag = ObsidianPath.projectTag(v.project) {
            tags.append(pTag)
        }
        lines.append("tags: [\(tags.joined(separator: ", "))]")
        lines.append("---")
        lines.append("")

        // Title — derive from actual transcript text so graph node labels
        // are recognisable. Falls back to "<Project> @ HH:mm" only when
        // no transcript is present (rare/error case). Previously was
        // hardcoded "Voice — Untagged (HH:mm)" which made every voice
        // file look identical in the graph view.
        let snippet = firstSnippet(v.textProcessed ?? v.textRaw, maxLength: 60)
        let time = timeOfDay(v.createdAt)
        if let snip = snippet {
            lines.append("# \(snip) — \(time)")
        } else {
            let bucket = ObsidianPath.conversationProjectFolderName(v.project)
            lines.append("# \(bucket) — \(time)")
        }
        lines.append("")

        // Inline graph link to the project hub — this is what populates
        // the graph view with edges instead of orphan nodes. Skipped when
        // the conversation has no project assigned (Untagged) — those stay
        // unlinked rather than all clustering under a fake hub.
        var headerLinks: [String] = []
        if let target = ObsidianPath.projectWikilinkTarget(v.project) {
            headerLinks.append("Project: [[\(target)]]")
        }
        // Conversation hub link — replaces the old UUID-based reference at
        // the bottom of the file. Resolved by the exporter from the
        // conversation's title (Conversation.title or fallback snippet).
        if let convLink = v.conversationHubLink, !convLink.isEmpty {
            let link = convLink.hasSuffix(".md") ? String(convLink.dropLast(3)) : convLink
            headerLinks.append("Conversation: [[\(link)]]")
        }
        // Day summary hub link — every voice/task/memory in a given day
        // points to `MetaWhisp/<date>/_summary` so the graph clusters by
        // date as well as by project/topic.
        let dayLink = ObsidianPath.dailySummaryWikilink(date: v.createdAt)
        headerLinks.append("Day: [[\(dayLink)|\(ObsidianPath.dateFolder(for: v.createdAt))]]")
        for hl in headerLinks { lines.append(hl) }
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

        // The legacy `[[Conversations/<UUID>]]` footer has been replaced by
        // the explicit `Conversation: [[…]]` header link above, which points
        // to a real on-disk hub file with a readable slug. UUID stays in
        // frontmatter for traceability but is no longer emitted as a link.

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
        var tTags: [String] = ["task", "metawhisp"]
        if let pTag = ObsidianPath.projectTag(t.project) {
            tTags.append(pTag)
        }
        lines.append("tags: [\(tTags.joined(separator: ", "))]")
        lines.append("---")
        lines.append("")

        let checkbox = t.completed ? "[x]" : "[ ]"
        lines.append("# \(checkbox) \(t.taskID): \(t.description)")
        lines.append("")

        var tHeaderLinks: [String] = []
        if let target = ObsidianPath.projectWikilinkTarget(t.project) {
            tHeaderLinks.append("Project: [[\(target)]]")
        }
        if let convLink = t.conversationHubLink, !convLink.isEmpty {
            let link = convLink.hasSuffix(".md") ? String(convLink.dropLast(3)) : convLink
            tHeaderLinks.append("Source: [[\(link)]]")
        }
        let tDayLink = ObsidianPath.dailySummaryWikilink(date: t.createdAt)
        tHeaderLinks.append("Day: [[\(tDayLink)|\(ObsidianPath.dateFolder(for: t.createdAt))]]")
        for hl in tHeaderLinks { lines.append(hl) }
        lines.append("")

        if let due = t.dueAt {
            lines.append("**Due:** \(humanDate(due))")
            lines.append("")
        }
        if let assignee = t.assignee, !assignee.isEmpty {
            lines.append("**Assignee:** \(assignee)")
            lines.append("")
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
        var memTags: [String] = ["memory", "metawhisp"]
        if let csv = m.tagsCSV, !csv.isEmpty {
            memTags.append(contentsOf:
                csv.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            )
        }
        if let pTag = ObsidianPath.projectTag(m.project) {
            memTags.append(pTag)
        }
        lines.append("tags: [\(memTags.joined(separator: ", "))]")
        lines.append("---")
        lines.append("")

        let headerText = m.headline?.isEmpty == false ? m.headline! : m.content
        lines.append("# \(headerText)")
        lines.append("")

        var mHeaderLinks: [String] = []
        if let target = ObsidianPath.projectWikilinkTarget(m.project) {
            mHeaderLinks.append("Project: [[\(target)]]")
        }
        if let convLink = m.conversationHubLink, !convLink.isEmpty {
            let link = convLink.hasSuffix(".md") ? String(convLink.dropLast(3)) : convLink
            mHeaderLinks.append("Source: [[\(link)]]")
        }
        let mDayLink = ObsidianPath.dailySummaryWikilink(date: m.createdAt)
        mHeaderLinks.append("Day: [[\(mDayLink)|\(ObsidianPath.dateFolder(for: m.createdAt))]]")
        for hl in mHeaderLinks { lines.append(hl) }
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

        // Conversation link is now in the header (Source: …) above. The
        // UUID footer is dropped — the readable hub link covers traceability.

        return lines.joined(separator: "\n")
    }

    /// Conversation hub render. Designed so the file is a useful read on its
    /// own (overview + voice timeline) AND a graph aggregation node (wikilinks
    /// to project, daily summary, and each voice file). Replaces the "raw
    /// voice porridge" the user complained about — 5611 voice files now group
    /// under ~1800 conversation hubs.
    static func renderConversation(_ c: ConversationHubInput) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("type: conversation")
        lines.append("id: \(c.id.uuidString)")
        lines.append("started: \(iso(c.startedAt))")
        if let f = c.finishedAt {
            lines.append("finished: \(iso(f))")
        }
        if let p = c.project, !p.isEmpty {
            lines.append("project: \(yamlString(p))")
        }
        if let cat = c.category, !cat.isEmpty {
            lines.append("category: \(cat)")
        }
        lines.append("voice_count: \(c.voices.count)")
        var convTags: [String] = ["conversation", "metawhisp"]
        if let cat = c.category, !cat.isEmpty {
            convTags.append("category/\(cat.lowercased())")
        }
        if let pTag = ObsidianPath.projectTag(c.project) {
            convTags.append(pTag)
        }
        lines.append("tags: [\(convTags.joined(separator: ", "))]")
        lines.append("---")
        lines.append("")

        let titleLine = c.emoji.map { "# \($0) \(c.title)" } ?? "# \(c.title)"
        lines.append(titleLine)
        lines.append("")

        // Wikilink ribbon — three potential edges in the graph.
        if let target = ObsidianPath.projectWikilinkTarget(c.project) {
            lines.append("Project: [[\(target)]]")
        }
        let dayLink = ObsidianPath.dailySummaryWikilink(date: c.startedAt)
        lines.append("Day: [[\(dayLink)|\(ObsidianPath.dateFolder(for: c.startedAt))]]")
        lines.append("")

        if let overview = c.overview, !overview.isEmpty {
            lines.append("## Overview")
            lines.append("")
            lines.append(overview)
            lines.append("")
        }

        if !c.voices.isEmpty {
            lines.append("## Voices")
            lines.append("")
            for v in c.voices {
                let timeStr = timeOfDay(v.createdAt)
                if let voiceFile = v.voiceFileRelativePath {
                    // Strip .md if accidentally passed; Obsidian wikilinks omit extension.
                    let target = voiceFile.hasSuffix(".md")
                        ? String(voiceFile.dropLast(3))
                        : voiceFile
                    lines.append("- **\(timeStr)** — [[\(target)|\(v.snippet)]]")
                } else {
                    lines.append("- **\(timeStr)** — \(v.snippet)")
                }
            }
            lines.append("")
        }

        if !c.actionItems.isEmpty {
            lines.append("## Action items")
            lines.append("")
            for ai in c.actionItems {
                lines.append("- [ ] \(ai)")
            }
            lines.append("")
        }

        if !c.memoriesInline.isEmpty {
            lines.append("## Memories")
            lines.append("")
            for m in c.memoriesInline {
                lines.append("- \(m)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Daily summary — one file per active day, lists everything that
    /// happened that day with wikilinks. Lets the graph cluster by date
    /// in addition to by topic.
    static func renderDailySummary(_ d: DailySummaryInput) -> String {
        var lines: [String] = []
        let dateStr = ObsidianPath.dateFolder(for: d.date)
        lines.append("---")
        lines.append("type: daily-summary")
        lines.append("date: \(dateStr)")
        let totalItems = d.voices.count + d.conversations.count + d.tasks.count + d.memories.count + d.insights.count
        lines.append("item_count: \(totalItems)")
        lines.append("tags: [daily-summary, metawhisp]")
        lines.append("---")
        lines.append("")
        lines.append("# \(dateStr) — daily summary")
        lines.append("")
        lines.append("_\(totalItems) entries this day._")
        lines.append("")

        func section(title: String, items: [DailySummaryInput.Item]) {
            guard !items.isEmpty else { return }
            lines.append("## \(title) (\(items.count))")
            lines.append("")
            for item in items {
                lines.append("- **\(item.timeOfDay)** — [[\(item.wikilink)|\(item.label)]]")
            }
            lines.append("")
        }

        section(title: "Conversations", items: d.conversations)
        section(title: "Voices", items: d.voices)
        section(title: "Tasks",   items: d.tasks)
        section(title: "Memories",items: d.memories)
        section(title: "Insights",items: d.insights)

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

    /// Pull the first sentence (or first `maxLength` chars on a sentence-
    /// boundary) from a transcript so we can use it as a recognisable
    /// h1 title for voice notes. Returns nil for empty/whitespace input
    /// so the caller can fall back to a project-bucket label.
    ///
    /// Trims trailing punctuation, collapses internal whitespace, and
    /// strips Obsidian-special chars (`#`, `[`, `]`, `|`) that would
    /// break the markdown heading or downstream wikilinks.
    static func firstSnippet(_ text: String?, maxLength: Int = 60) -> String? {
        guard var s = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        // Collapse internal whitespace + linebreaks.
        s = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
             .joined(separator: " ")
        // Drop chars that break Obsidian's markdown title/link parsing.
        s = String(s.unicodeScalars.filter { c in
            c != "#" && c != "[" && c != "]" && c != "|" && c != "\"" && c != "`"
        })
        // First sentence boundary (Russian period, Latin period, !, ?).
        let sentenceEnders: Set<Character> = [".", "!", "?", "…"]
        if let idx = s.firstIndex(where: { sentenceEnders.contains($0) }),
           s.distance(from: s.startIndex, to: idx) >= 8 {
            s = String(s[..<idx])
        }
        // Cap at maxLength on a word boundary (avoid mid-word cut).
        if s.count > maxLength {
            let cap = s.prefix(maxLength)
            if let lastSpace = cap.lastIndex(of: " "),
               cap.distance(from: cap.startIndex, to: lastSpace) > maxLength / 2 {
                s = String(cap[..<lastSpace]) + "…"
            } else {
                s = String(cap) + "…"
            }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}
