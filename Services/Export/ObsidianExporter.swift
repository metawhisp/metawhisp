import Foundation
import SwiftData

/// One-way SwiftData → Obsidian vault sync (ITER-035 v2).
///
/// Replaces the older `ObsidianSyncService` (append-only `Journal.md`) and
/// `MeetingObsidianWriter` (per-meeting in flat `Meetings/`). New layout —
/// date-first folders for time-bound entities + project-first for memories.
/// See `ObsidianPath` for the exact path schema and `ObsidianMarkdownRenderer`
/// for the markdown shape.
///
/// **Non-destructive on the legacy data** — existing `Journal.md` and `Meetings/`
/// files in user's vault are NOT touched. They remain as historical archive
/// until the user runs a migration (separate iteration).
///
/// **Public surface**:
/// - `configure(modelContainer:)` — once at app launch.
/// - `bulkExportAll()` — manual button in Settings; re-renders everything.
/// - `exportHistoryItem(_:)`, `exportConversation(_:)`, `exportTask(_:)`,
///   `exportMemory(_:)` — called on every `ctx.save()` via service hooks.
/// - `deleteTaskFile(_:)` — for two-way delete (user dismisses task → file removed).
/// - `writeReadmeIfMissing()` — onboarding doc on first sync.
///
/// **Error handling**: silent on failure (NSLog warning, `lastError` set).
/// We never throw upward — sync should never block a SwiftData save. Bad
/// vault path → just stop writing until path fixed.
@MainActor
final class ObsidianExporter: ObservableObject {

    // MARK: - Published state (Settings UI shows progress)

    @Published var isExporting = false
    @Published var lastError: String?
    @Published var stats: ExportStats = .empty

    struct ExportStats: Equatable {
        var voices: Int = 0
        var meetings: Int = 0
        var tasks: Int = 0
        var memories: Int = 0
        var insights: Int = 0
        var errors: Int = 0
        static let empty = ExportStats()
    }

    // MARK: - Dependencies

    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Public exports (called on save)

    /// Voice dictation — one file per HistoryItem under
    /// `<vault>/MetaWhisp/<date>/voices/<HHhMM>--<project>.md`.
    func exportHistoryItem(_ id: UUID) async {
        guard let ctx = makeContext() else { return }
        let desc = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.id == id })
        guard let item = (try? ctx.fetch(desc))?.first else { return }
        // Only export real dictations — skip meeting-derived HistoryItems
        // (those go through `exportConversation` as part of the meeting file).
        if item.source == "meeting" { return }

        // Resolve parent conversation once — we need its project AND a
        // wikilink target to the conversation hub for graph linking.
        let parent: Conversation? = {
            guard let cid = item.conversationId else { return nil }
            let cdesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid })
            return (try? ctx.fetch(cdesc))?.first
        }()
        let project = parent?.primaryProject
        let convHubLink: String? = parent.flatMap { conversationHubWikilink(for: $0, ctx: ctx) }

        let input = ObsidianMarkdownRenderer.VoiceInput(
            id: item.id,
            createdAt: item.createdAt,
            project: project,
            conversationId: item.conversationId,
            language: item.language,
            sourceApp: item.source,
            textRaw: item.text,
            textProcessed: item.processedText,
            durationSec: item.audioDuration > 0 ? item.audioDuration : nil,
            conversationHubLink: convHubLink
        )
        let md = ObsidianMarkdownRenderer.renderVoice(input)
        let path = ObsidianPath.voicePath(date: item.createdAt, project: project, id: item.id)
        write(md, to: path, kind: "voice")
        ensureProjectStub(for: project)
    }

    /// Resolve a conversation to a readable hub wikilink target
    /// (`MetaWhisp/<date>/conversations/<HHhMM>--<slug>`). Falls back to
    /// snippet of first HistoryItem text if `conversation.title` is nil
    /// — which is the common case until StructuredGenerator runs on every
    /// conversation. Slug computed from the same string used for the file
    /// path, so wikilink ↔ file path agree.
    private func conversationHubWikilink(for conv: Conversation, ctx: ModelContext) -> String? {
        let title = conversationDisplayTitle(for: conv, ctx: ctx)
        guard !title.isEmpty else { return nil }
        return ObsidianPath.conversationHubWikilink(date: conv.startedAt, title: title, id: conv.id)
    }

    /// Title to use when rendering a conversation hub OR a wikilink to it.
    /// Single source of truth so the hub file's path and every voice's
    /// wikilink stay consistent across runs.
    private func conversationDisplayTitle(for conv: Conversation, ctx: ModelContext) -> String {
        if let t = conv.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        // Fallback: snippet from the first HistoryItem text.
        let cid = conv.id
        var hDesc = FetchDescriptor<HistoryItem>()
        hDesc.fetchLimit = 1
        // We can't filter+sort+limit in one FetchDescriptor predicate easily
        // for @Model with this Swift version; cheap workaround — pull a
        // small page and pick min.
        var allDesc = FetchDescriptor<HistoryItem>()
        allDesc.fetchLimit = 50
        let candidates = ((try? ctx.fetch(allDesc)) ?? [])
            .filter { $0.conversationId == cid }
            .sorted { $0.createdAt < $1.createdAt }
        let firstText = candidates.first?.processedText ?? candidates.first?.text
        let snippet = ObsidianMarkdownRenderer.firstSnippet(firstText, maxLength: 60)
            ?? "conversation"
        return snippet
    }

    /// Meeting OR dictation Conversation — writes a single hub file
    /// aggregating everything that happened during that conversation.
    /// Meetings keep their current rich rendering (summary + action items +
    /// transcript); non-meeting (dictation) conversations get the lighter
    /// `renderConversation` layout (project link + voice timeline).
    /// Discarded conversations are skipped.
    func exportConversation(_ id: UUID) async {
        guard let ctx = makeContext() else { return }
        let convDesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        guard let conv = (try? ctx.fetch(convDesc))?.first else { return }
        guard !conv.discarded else { return }

        // Branch by source: meetings get the existing rich rendering;
        // everything else (dictation, screen-derived) goes through the
        // new conversation-hub renderer (voice timeline + project link).
        if conv.source != "meeting" {
            await exportConversationHub(conv, ctx: ctx)
            return
        }

        // Tasks tied to this conversation — collect short summaries.
        var tDesc = FetchDescriptor<TaskItem>()
        tDesc.fetchLimit = 500
        let tasks = ((try? ctx.fetch(tDesc)) ?? [])
            .filter { $0.conversationId == id && !$0.isDismissed }
        let actionItems = tasks.map { $0.taskDescription }

        // Memories tied to this conversation — inline bullets.
        var mDesc = FetchDescriptor<UserMemory>()
        mDesc.fetchLimit = 500
        let memories = ((try? ctx.fetch(mDesc)) ?? [])
            .filter { $0.conversationId == id && !$0.isDismissed && !$0.needsReview }
        let memoriesInline = memories.map { mem -> String in
            if let s = mem.subject, !s.isEmpty,
               let c = mem.characterization, !c.isEmpty {
                return "\(s) — \(c)"
            }
            return mem.content
        }

        // Transcript — concat all HistoryItems for this conversation in order.
        var hDesc = FetchDescriptor<HistoryItem>()
        hDesc.fetchLimit = 500
        let history = ((try? ctx.fetch(hDesc)) ?? [])
            .filter { $0.conversationId == id }
            .sorted { $0.createdAt < $1.createdAt }
        let fullTranscript = history.map { $0.displayText }.joined(separator: "\n\n")

        // Attendees JSON → array
        let attendees: [String] = {
            guard let raw = conv.calendarAttendeesJSON,
                  let data = raw.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return arr
        }()

        let input = ObsidianMarkdownRenderer.MeetingInput(
            id: conv.id,
            title: conv.title?.isEmpty == false ? conv.title! : "Meeting",
            emoji: conv.emoji,
            startedAt: conv.startedAt,
            finishedAt: conv.finishedAt,
            calendarEventTitle: conv.calendarEventTitle,
            calendarAttendees: attendees,
            overview: conv.overview,
            actionItems: actionItems,
            memoriesInline: memoriesInline,
            fullTranscript: fullTranscript.isEmpty ? nil : fullTranscript
        )
        let md = ObsidianMarkdownRenderer.renderMeeting(input)
        let title = input.title
        let path = ObsidianPath.meetingPath(date: conv.startedAt, title: title, id: conv.id)
        write(md, to: path, kind: "meeting")
    }

    /// Non-meeting Conversation hub. Aggregates a series of voices that
    /// landed in the same `Conversation` (grouped by `ConversationGrouper`
    /// — 2-min silence split + topic continuity). Replaces the "5611 raw
    /// voice files in the graph" feeling with ~1800 topic-level hubs.
    private func exportConversationHub(_ conv: Conversation, ctx: ModelContext) async {
        let title = conversationDisplayTitle(for: conv, ctx: ctx)
        guard !title.isEmpty else { return }

        // Voices in this conversation, oldest first.
        var allHistory = FetchDescriptor<HistoryItem>()
        allHistory.fetchLimit = 1000
        let voices = ((try? ctx.fetch(allHistory)) ?? [])
            .filter { $0.conversationId == conv.id && $0.source != "meeting" }
            .sorted { $0.createdAt < $1.createdAt }

        let voiceLines: [ObsidianMarkdownRenderer.VoiceLine] = voices.map { v in
            let snippet = ObsidianMarkdownRenderer.firstSnippet(v.processedText ?? v.text, maxLength: 80) ?? "(voice)"
            let voicePath = ObsidianPath.voicePath(date: v.createdAt, project: conv.primaryProject, id: v.id)
            return .init(
                createdAt: v.createdAt,
                snippet: snippet,
                voiceFileRelativePath: voicePath
            )
        }

        // Tasks tied to this conversation (short summaries).
        var tDesc = FetchDescriptor<TaskItem>()
        tDesc.fetchLimit = 500
        let actionItems = ((try? ctx.fetch(tDesc)) ?? [])
            .filter { $0.conversationId == conv.id && !$0.isDismissed }
            .map { $0.taskDescription }

        // Memories tied to this conversation.
        var mDesc = FetchDescriptor<UserMemory>()
        mDesc.fetchLimit = 500
        let memoriesInline = ((try? ctx.fetch(mDesc)) ?? [])
            .filter { $0.conversationId == conv.id && !$0.isDismissed && !$0.needsReview }
            .map { mem -> String in
                if let s = mem.subject, !s.isEmpty,
                   let c = mem.characterization, !c.isEmpty {
                    return "\(s) — \(c)"
                }
                return mem.content
            }

        let input = ObsidianMarkdownRenderer.ConversationHubInput(
            id: conv.id,
            title: title,
            emoji: conv.emoji,
            startedAt: conv.startedAt,
            finishedAt: conv.finishedAt,
            project: conv.primaryProject,
            category: conv.category,
            overview: conv.overview,
            voices: voiceLines,
            actionItems: actionItems,
            memoriesInline: memoriesInline
        )
        let md = ObsidianMarkdownRenderer.renderConversation(input)
        let path = ObsidianPath.conversationHubPath(date: conv.startedAt, title: title, id: conv.id)
        write(md, to: path, kind: "conversation")
        ensureProjectStub(for: conv.primaryProject)
    }

    /// Daily summary hub — `MetaWhisp/<date>/_summary.md`. Aggregates
    /// pointers to every voice/conversation/task/memory/insight of a given
    /// day. Lets the graph cluster by date as well as by project/topic.
    /// Idempotent (overwrites by path).
    func exportDailySummary(for day: Date) async {
        guard let ctx = makeContext() else { return }
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? day.addingTimeInterval(86400)

        func timeStr(_ d: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HH:mm"
            return f.string(from: d)
        }

        // Voices: non-meeting HistoryItems landing this day.
        var hDesc = FetchDescriptor<HistoryItem>()
        hDesc.fetchLimit = 2000
        let dayVoices = ((try? ctx.fetch(hDesc)) ?? [])
            .filter { $0.createdAt >= dayStart && $0.createdAt < dayEnd && $0.source != "meeting" }
            .sorted { $0.createdAt < $1.createdAt }
        let voiceItems: [ObsidianMarkdownRenderer.DailySummaryInput.Item] = dayVoices.map { v in
            let label = ObsidianMarkdownRenderer.firstSnippet(v.processedText ?? v.text, maxLength: 80) ?? "(voice)"
            let projForPath: String? = {
                guard let cid = v.conversationId else { return nil }
                let cdesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid })
                return (try? ctx.fetch(cdesc))?.first?.primaryProject
            }()
            let path = ObsidianPath.voicePath(date: v.createdAt, project: projForPath, id: v.id)
            let link = path.hasSuffix(".md") ? String(path.dropLast(3)) : path
            return .init(timeOfDay: timeStr(v.createdAt), label: label, wikilink: link)
        }

        // Conversations starting this day (both meetings + dictation hubs).
        var cDesc = FetchDescriptor<Conversation>()
        cDesc.fetchLimit = 500
        let dayConvs = ((try? ctx.fetch(cDesc)) ?? [])
            .filter { $0.startedAt >= dayStart && $0.startedAt < dayEnd && !$0.discarded }
            .sorted { $0.startedAt < $1.startedAt }
        let convItems: [ObsidianMarkdownRenderer.DailySummaryInput.Item] = dayConvs.map { c in
            let title = conversationDisplayTitle(for: c, ctx: ctx)
            let link: String
            if c.source == "meeting" {
                let p = ObsidianPath.meetingPath(date: c.startedAt, title: title, id: c.id)
                link = p.hasSuffix(".md") ? String(p.dropLast(3)) : p
            } else {
                link = ObsidianPath.conversationHubWikilink(date: c.startedAt, title: title, id: c.id)
            }
            return .init(timeOfDay: timeStr(c.startedAt), label: title, wikilink: link)
        }

        // Tasks created this day, non-dismissed.
        var tDesc = FetchDescriptor<TaskItem>()
        tDesc.fetchLimit = 500
        let dayTasks = ((try? ctx.fetch(tDesc)) ?? [])
            .filter { $0.createdAt >= dayStart && $0.createdAt < dayEnd && !$0.isDismissed }
            .sorted { $0.createdAt < $1.createdAt }
        let taskItems: [ObsidianMarkdownRenderer.DailySummaryInput.Item] = dayTasks.map { t in
            let input = toTaskInput(t)
            let path = ObsidianPath.taskPath(date: t.createdAt, taskID: input.taskID, description: t.taskDescription)
            let link = path.hasSuffix(".md") ? String(path.dropLast(3)) : path
            return .init(timeOfDay: timeStr(t.createdAt), label: "\(input.taskID): \(t.taskDescription)", wikilink: link)
        }

        // Memories + Insights created this day.
        var mDesc = FetchDescriptor<UserMemory>()
        mDesc.fetchLimit = 1000
        let dayMems = ((try? ctx.fetch(mDesc)) ?? [])
            .filter { $0.createdAt >= dayStart && $0.createdAt < dayEnd && !$0.isDismissed }
            .sorted { $0.createdAt < $1.createdAt }
        var memItems: [ObsidianMarkdownRenderer.DailySummaryInput.Item] = []
        var insItems: [ObsidianMarkdownRenderer.DailySummaryInput.Item] = []
        for mem in dayMems {
            let label = mem.headline?.isEmpty == false ? mem.headline! : mem.content
            if isInsightTagged(mem) {
                let path = ObsidianPath.insightPath(date: mem.createdAt, headline: mem.headline, body: mem.content, id: mem.id)
                let link = path.hasSuffix(".md") ? String(path.dropLast(3)) : path
                insItems.append(.init(timeOfDay: timeStr(mem.createdAt), label: label, wikilink: link))
            } else {
                let path = ObsidianPath.memoryPath(date: mem.createdAt, project: mem.project, content: mem.content, id: mem.id)
                let link = path.hasSuffix(".md") ? String(path.dropLast(3)) : path
                memItems.append(.init(timeOfDay: timeStr(mem.createdAt), label: label, wikilink: link))
            }
        }

        // Skip empty days entirely — no point in a hub with zero items.
        let total = voiceItems.count + convItems.count + taskItems.count + memItems.count + insItems.count
        guard total > 0 else { return }

        let summary = ObsidianMarkdownRenderer.DailySummaryInput(
            date: dayStart,
            voices: voiceItems,
            conversations: convItems,
            tasks: taskItems,
            memories: memItems,
            insights: insItems
        )
        let md = ObsidianMarkdownRenderer.renderDailySummary(summary)
        let path = ObsidianPath.dailySummaryPath(date: dayStart)
        write(md, to: path, kind: "daily-summary")
    }

    func exportTask(_ id: UUID) async {
        guard let ctx = makeContext() else { return }
        let desc = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        guard let task = (try? ctx.fetch(desc))?.first else { return }
        // Dismissed → delete the file (two-way delete).
        if task.isDismissed {
            await deleteTaskFile(id)
            return
        }
        let input = toTaskInput(task)
        let md = ObsidianMarkdownRenderer.renderTask(input)
        let path = ObsidianPath.taskPath(
            date: task.createdAt,
            taskID: input.taskID,
            description: task.taskDescription
        )
        write(md, to: path, kind: "task")
        ensureProjectStub(for: input.project)
    }

    /// `UserMemory` rows are split: `tagsCSV` contains "insight" → goes to
    /// Insights/ folder (rendered via renderInsight). Everything else →
    /// Memories/<project>/ (renderMemory).
    func exportMemory(_ id: UUID) async {
        guard let ctx = makeContext() else { return }
        let desc = FetchDescriptor<UserMemory>(predicate: #Predicate { $0.id == id })
        guard let mem = (try? ctx.fetch(desc))?.first else { return }
        guard !mem.isDismissed else { return }
        // ITER-071.6 — an unconfirmed proposal must not reach the vault: it is
        // read by other tools as an established fact about the user.
        guard !mem.needsReview else { return }

        if isInsightTagged(mem) {
            exportInsightMemory(mem)
        } else {
            exportRegularMemory(mem)
        }
    }

    /// Remove on-disk task file when user dismisses / deletes a TaskItem.
    /// Searches whole `MetaWhisp/<date>/tasks/` tree for a file with matching
    /// `taskID` prefix (we don't have stable date because dismissed task may
    /// have been edited).
    func deleteTaskFile(_ id: UUID) async {
        let taskID = shortTaskID(id)
        guard let vault = vaultURL() else { return }
        let metawhispRoot = vault.appendingPathComponent(ObsidianPath.rootSubdir, isDirectory: true)
        guard FileManager.default.fileExists(atPath: metawhispRoot.path) else { return }
        // Walk only the date folders (top level under MetaWhisp/) — skip Memories/Insights.
        guard let entries = try? FileManager.default.contentsOfDirectory(at: metawhispRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries {
            // Date folders match `YYYY-MM-DD` pattern.
            let name = entry.lastPathComponent
            guard isDateFolder(name) else { continue }
            let tasksDir = entry.appendingPathComponent("tasks", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil) else {
                continue
            }
            for f in files where f.lastPathComponent.hasPrefix("\(taskID)--") {
                do {
                    try FileManager.default.removeItem(at: f)
                    NSLog("[ObsidianExporter] 🗑 Deleted task file %@", f.path)
                } catch {
                    NSLog("[ObsidianExporter] delete failed: %@", error.localizedDescription)
                }
            }
        }
    }

    /// SB-3 / AUD-030 — remove the on-disk memory (or insight) file when a memory
    /// is dismissed / deleted. Memory files live at
    /// `Memories/<project>/<day>--<slug>--<shortID>.md` and insights at
    /// `Insights/<day>/<time>--<slug>--<shortID>.md`, so we recursively walk both
    /// trees and match the `--<shortID>.md` filename SUFFIX (the id is a suffix
    /// for memories, unlike the task `T-xxxx--` prefix).
    func deleteMemoryFile(_ id: UUID) async {
        let suffix = "--\(ObsidianPath.shortID(id)).md"
        guard let vault = vaultURL() else { return }
        let root = vault.appendingPathComponent(ObsidianPath.rootSubdir, isDirectory: true)
        for sub in [ObsidianPath.memoriesSubdir, ObsidianPath.insightsSubdir] {
            let base = root.appendingPathComponent(sub, isDirectory: true)
            guard FileManager.default.fileExists(atPath: base.path),
                  let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            else { continue }
            for case let f as URL in walker where f.lastPathComponent.hasSuffix(suffix) {
                do {
                    try FileManager.default.removeItem(at: f)
                    NSLog("[ObsidianExporter] 🗑 Deleted memory file %@", f.path)
                } catch {
                    NSLog("[ObsidianExporter] memory delete failed: %@", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Bulk export

    @discardableResult
    func bulkExportAll() async -> ExportStats {
        guard !isExporting else { return stats }
        guard let ctx = makeContext() else { return stats }
        guard vaultURL() != nil else {
            lastError = "Vault path not set or does not exist."
            NSLog("[ObsidianExporter] ❌ bulk export refused: vault path not set or does not exist")
            return stats
        }

        isExporting = true
        defer { isExporting = false }
        lastError = nil
        NSLog("[ObsidianExporter] bulk export start (Settings button)")

        var s = ExportStats.empty

        // README — once per session bulk.
        await writeReadmeIfMissing()

        // Voices — HistoryItems where source != "meeting"
        var hDesc = FetchDescriptor<HistoryItem>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        hDesc.fetchLimit = 10_000
        let history = (try? ctx.fetch(hDesc)) ?? []
        for item in history {
            if item.source == "meeting" { continue }
            await exportHistoryItem(item.id)
            s.voices += 1
        }

        // Meetings — Conversation where source == "meeting" && !discarded
        var cDesc = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.startedAt, order: .forward)])
        cDesc.fetchLimit = 5_000
        let convs = (try? ctx.fetch(cDesc)) ?? []
        for c in convs where c.source == "meeting" && !c.discarded {
            await exportConversation(c.id)
            s.meetings += 1
        }

        // Tasks — non-dismissed
        var tDesc = FetchDescriptor<TaskItem>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        tDesc.fetchLimit = 5_000
        let tasks = (try? ctx.fetch(tDesc)) ?? []
        for t in tasks where !t.isDismissed {
            await exportTask(t.id)
            s.tasks += 1
        }

        // Memories + Insights (split inside exportMemory)
        var mDesc = FetchDescriptor<UserMemory>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        mDesc.fetchLimit = 10_000
        let mems = (try? ctx.fetch(mDesc)) ?? []
        for mem in mems where !mem.isDismissed && !mem.needsReview {
            if isInsightTagged(mem) {
                exportInsightMemory(mem)
                s.insights += 1
            } else {
                exportRegularMemory(mem)
                s.memories += 1
            }
        }

        // Phase 2 — Daily summary hubs. One per active day. Cheap: iterates
        // a Set of unique day-anchors across all entities already fetched
        // above, then renders/writes each. exportDailySummary skips empty
        // days by itself so we won't pollute the vault.
        var dayAnchors: Set<Date> = []
        let cal = Calendar.current
        for e in history { dayAnchors.insert(cal.startOfDay(for: e.createdAt)) }
        for e in convs   { dayAnchors.insert(cal.startOfDay(for: e.startedAt)) }
        for e in tasks   { dayAnchors.insert(cal.startOfDay(for: e.createdAt)) }
        for e in mems    { dayAnchors.insert(cal.startOfDay(for: e.createdAt)) }
        for day in dayAnchors.sorted() {
            await exportDailySummary(for: day)
        }
        NSLog("[ObsidianExporter] ✅ wrote %d daily summary hubs", dayAnchors.count)

        stats = s
        NSLog("[ObsidianExporter] ✅ bulk export done: voices=%d meetings=%d tasks=%d memories=%d insights=%d",
              s.voices, s.meetings, s.tasks, s.memories, s.insights)
        return s
    }

    // MARK: - README (one-shot onboarding)

    func writeReadmeIfMissing() async {
        guard let vault = vaultURL() else { return }
        let path = "\(ObsidianPath.rootSubdir)/README.md"
        let url = vault.appendingPathComponent(path)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        let readme = """
        # MetaWhisp Vault

        Auto-synced from MetaWhisp (macOS dictation + meeting recorder + intelligence app).

        ## Layout

        - **`<YYYY-MM-DD>/`** — daily folder for time-bound artefacts:
          - `voices/` — every dictation as `<HHhMM>--<project>.md`
          - `meetings/` — every recorded meeting as `<HHhMM>--<title>.md`
          - `tasks/` — open / completed tasks as `T-XXXXXXXX--<slug>.md`
        - **`Memories/<project>/`** — durable facts as `<YYYY-MM-DD>--<slug>.md`
          - Default project bucket: `General`
        - **`Insights/<YYYY-MM-DD>/`** — surfaced advice from screen activity

        ## Frontmatter

        Each file has YAML frontmatter with `type`, `id` (stable UUID),
        `created`, `tags`, and entity-specific fields (e.g. `project`,
        `conversation_id`, `category`, `confidence`).

        Use Obsidian's filtering / tag search to slice:
        - `tags:meeting` → all recorded meetings
        - `tags:insight category:productivity` → productivity insights
        - `project:MetaWhisp` → everything for the MetaWhisp project

        ## Wikilinks

        Voices, tasks, and memories link back to their parent conversation via
        `[[Conversations/<uuid>]]`. The conversation file itself is the meeting
        markdown if the conversation is a meeting; otherwise it's implicit
        (no separate file, just the wikilink target as identifier).

        ## Tasks (two-way)

        - Mark a task completed in MetaWhisp → file's `completed: true`
        - Dismiss / delete a task in MetaWhisp → file is **removed** from the vault

        ## Don't edit `*.md` files manually

        This vault is one-way (MetaWhisp → here). Manual edits will be
        overwritten on the next sync of that entity. Plan: add two-way sync
        in a future iteration.

        ---

        Generated by `ObsidianExporter` (ITER-035, 2026-05-12).
        """

        write(readme, to: path, kind: "readme")
    }

    // MARK: - Internal: insight vs memory routing

    private func isInsightTagged(_ mem: UserMemory) -> Bool {
        guard let tags = mem.tagsCSV else { return false }
        return tags.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .contains("insight")
    }

    private func exportRegularMemory(_ mem: UserMemory) {
        let convHubLink: String? = {
            guard let ctx = makeContext(), let cid = mem.conversationId else { return nil }
            let cdesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid })
            guard let conv = (try? ctx.fetch(cdesc))?.first else { return nil }
            return conversationHubWikilink(for: conv, ctx: ctx)
        }()
        var input = ObsidianMarkdownRenderer.MemoryInput(
            id: mem.id,
            content: mem.content,
            headline: mem.headline,
            reasoning: mem.reasoning,
            category: mem.category,
            kind: mem.kind,
            subject: mem.subject,
            characterization: mem.characterization,
            project: mem.project,
            sourceApp: mem.sourceApp,
            confidence: mem.confidence,
            createdAt: mem.createdAt,
            tagsCSV: mem.tagsCSV,
            conversationId: mem.conversationId
        )
        input.conversationHubLink = convHubLink
        let md = ObsidianMarkdownRenderer.renderMemory(input)
        let path = ObsidianPath.memoryPath(
            date: mem.createdAt,
            project: mem.project,
            content: mem.content,
            id: mem.id
        )
        write(md, to: path, kind: "memory")
        ensureProjectStub(for: mem.project)
    }

    private func exportInsightMemory(_ mem: UserMemory) {
        // Insights live in UserMemory with tag "insight" + a domain tag
        // (productivity/communication/learning/other). Pull domain from tagsCSV.
        let domain = parseInsightCategory(mem.tagsCSV)
        let input = ObsidianMarkdownRenderer.InsightInput(
            id: mem.id,
            body: mem.content,
            headline: mem.headline,
            reasoning: mem.reasoning,
            category: domain,
            sourceApp: mem.sourceApp,
            confidence: mem.confidence,
            createdAt: mem.createdAt
        )
        let md = ObsidianMarkdownRenderer.renderInsight(input)
        let path = ObsidianPath.insightPath(
            date: mem.createdAt,
            headline: mem.headline,
            body: mem.content,
            id: mem.id
        )
        write(md, to: path, kind: "insight")
    }

    private func parseInsightCategory(_ tagsCSV: String?) -> String {
        guard let csv = tagsCSV else { return "other" }
        let tags = csv.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        let domains: Set<String> = ["productivity", "communication", "learning", "other"]
        return tags.first(where: { domains.contains($0) }) ?? "other"
    }

    // MARK: - Internal: mapping helpers

    private func toTaskInput(_ task: TaskItem) -> ObsidianMarkdownRenderer.TaskInput {
        let convHubLink: String? = {
            guard let ctx = makeContext(), let cid = task.conversationId else { return nil }
            let cdesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid })
            guard let conv = (try? ctx.fetch(cdesc))?.first else { return nil }
            return conversationHubWikilink(for: conv, ctx: ctx)
        }()
        var input = ObsidianMarkdownRenderer.TaskInput(
            id: task.id,
            taskID: shortTaskID(task.id),
            description: task.taskDescription,
            createdAt: task.createdAt,
            dueAt: task.dueAt,
            completed: task.completed,
            assignee: task.assignee,
            priority: nil,  // TaskItem has no priority field yet
            project: nil,   // TaskItem has no project field yet
            conversationId: task.conversationId,
            sourceApp: task.sourceApp
        )
        input.conversationHubLink = convHubLink
        return input
    }

    /// `T-<first 8 hex of UUID>`. Stable across description edits.
    private func shortTaskID(_ id: UUID) -> String {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "T-\(String(hex.prefix(8)))"
    }

    // MARK: - Internal: filesystem

    /// Resolved + validated vault URL. Returns nil if path empty or doesn't exist.
    private func vaultURL() -> URL? {
        let raw = settings.obsidianVaultPath.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else {
            lastError = "Obsidian vault path not set."
            return nil
        }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "Vault path does not exist: \(raw)"
            NSLog("[ObsidianExporter] ❌ vault path does not exist — export skipped")
            return nil
        }
        return url
    }

    /// Write `content` to `<vault>/<relativePath>`, atomically.
    /// Creates parent directories. Bumps stats / errors on failure.
    private func write(_ content: String, to relativePath: String, kind: String) {
        guard let vault = vaultURL() else { return }
        let fileURL = vault.appendingPathComponent(relativePath)
        let dirURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            if !isExporting { NSLog("[ObsidianExporter] ✅ wrote %@ (%d chars)", kind, content.count) }
        } catch {
            lastError = "Write failed for \(kind) at \(relativePath): \(error.localizedDescription)"
            stats.errors += 1
            NSLog("[ObsidianExporter] ❌ write failed (%@): %@", kind, error.localizedDescription)
        }
    }

    /// Create `<vault>/Projects/<Project>.md` if the user doesn't already
    /// have a hub note (or hub folder) for that project. Called every time
    /// we emit a `[[Projects/<Project>]]` wikilink so the link isn't
    /// dangling in the graph view.
    ///
    /// Idempotent: skips entirely when any of these exist:
    ///   - `Projects/<Project>.md` (file at the wikilink target)
    ///   - `Projects/<Project>/` (folder convention some users prefer,
    ///     where the hub note lives inside as `<Project>/<Project>.md`)
    ///
    /// The stub is intentionally minimal — just the H1 and project tag.
    /// Users are expected to expand it themselves; MetaWhisp must not
    /// overwrite hub notes the user wrote.
    func ensureProjectStub(for rawProject: String?) {
        guard let project = rawProject?.trimmingCharacters(in: .whitespacesAndNewlines),
              !project.isEmpty,
              let stubRel = ObsidianPath.projectStubPath(project),
              let target = ObsidianPath.projectWikilinkTarget(project),
              let vault = vaultURL() else { return }

        let stubURL = vault.appendingPathComponent(stubRel)
        // Skip if either `Projects/<P>.md` or `Projects/<P>/` already exists.
        if FileManager.default.fileExists(atPath: stubURL.path) { return }
        let folderURL = vault.appendingPathComponent(target, isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue {
            return
        }
        let projectTag = ObsidianPath.projectTag(project) ?? "project"
        let stub = """
        ---
        type: project
        created: \(ISO8601DateFormatter().string(from: Date()))
        tags: [\(projectTag), hub, metawhisp]
        ---

        # \(project)

        _MetaWhisp auto-stub. Replace with your own project notes; the wikilinks from voice/task/memory files will keep working as long as this file (or `\(target)/\(project).md`) exists._

        ## Recent
        ```dataview
        list from #\(projectTag) sort file.ctime desc limit 20
        ```
        """
        do {
            let dirURL = stubURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try stub.write(to: stubURL, atomically: true, encoding: .utf8)
            NSLog("[ObsidianExporter] ✅ created project stub: %@", stubRel)
        } catch {
            NSLog("[ObsidianExporter] ⚠️ failed to create project stub %@: %@", stubRel, error.localizedDescription)
        }
    }

    /// `YYYY-MM-DD` shape check — 10 chars with two dashes at index 4 and 7.
    private func isDateFolder(_ name: String) -> Bool {
        guard name.count == 10 else { return false }
        let chars = Array(name)
        guard chars[4] == "-", chars[7] == "-" else { return false }
        return chars[0..<4].allSatisfy { $0.isNumber }
            && chars[5..<7].allSatisfy { $0.isNumber }
            && chars[8..<10].allSatisfy { $0.isNumber }
    }

    // MARK: - SwiftData

    private func makeContext() -> ModelContext? {
        // AUD-042 — the v2 Obsidian exporter ONLY writes to the vault; it has no
        // read-only path. When the user turns Obsidian Sync off, no exporter
        // operation may run, so gate the single shared entry point here — this
        // covers every public export path (per-item auto-exports AND the manual
        // bulkExportAll). The vault path can still be configured while sync is
        // off; `obsidianSyncEnabled` is the master switch. The legacy writers
        // already check this toggle; the v2 exporter previously did not.
        guard AppSettings.shared.obsidianSyncEnabled else { return nil }
        guard let container = modelContainer else { return nil }
        return ModelContext(container)
    }
}
