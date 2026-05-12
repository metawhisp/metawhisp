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

        // Resolve project via parent conversation (если есть)
        let project: String? = {
            guard let cid = item.conversationId else { return nil }
            let cdesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid })
            return (try? ctx.fetch(cdesc))?.first?.primaryProject
        }()

        let input = ObsidianMarkdownRenderer.VoiceInput(
            id: item.id,
            createdAt: item.createdAt,
            project: project,
            conversationId: item.conversationId,
            language: item.language,
            sourceApp: item.source,
            textRaw: item.text,
            textProcessed: item.processedText,
            durationSec: item.audioDuration > 0 ? item.audioDuration : nil
        )
        let md = ObsidianMarkdownRenderer.renderVoice(input)
        let path = ObsidianPath.voicePath(date: item.createdAt, project: project)
        write(md, to: path, kind: "voice")
    }

    /// Meeting Conversation — one self-contained file with summary, action items,
    /// memories inline, transcript. Skips non-meeting conversations (their
    /// HistoryItems go through `exportHistoryItem` individually).
    func exportConversation(_ id: UUID) async {
        guard let ctx = makeContext() else { return }
        let convDesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        guard let conv = (try? ctx.fetch(convDesc))?.first else { return }
        guard conv.source == "meeting" else { return }
        guard !conv.discarded else { return }

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
            .filter { $0.conversationId == id && !$0.isDismissed }
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
        let path = ObsidianPath.meetingPath(date: conv.startedAt, title: title)
        write(md, to: path, kind: "meeting")
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
    }

    /// `UserMemory` rows are split: `tagsCSV` contains "insight" → goes to
    /// Insights/ folder (rendered via renderInsight). Everything else →
    /// Memories/<project>/ (renderMemory).
    func exportMemory(_ id: UUID) async {
        guard let ctx = makeContext() else { return }
        let desc = FetchDescriptor<UserMemory>(predicate: #Predicate { $0.id == id })
        guard let mem = (try? ctx.fetch(desc))?.first else { return }
        guard !mem.isDismissed else { return }

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

    // MARK: - Bulk export

    @discardableResult
    func bulkExportAll() async -> ExportStats {
        guard !isExporting else { return stats }
        guard let ctx = makeContext() else { return stats }
        guard vaultURL() != nil else {
            lastError = "Vault path not set or does not exist."
            return stats
        }

        isExporting = true
        defer { isExporting = false }
        lastError = nil

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
        for mem in mems where !mem.isDismissed {
            if isInsightTagged(mem) {
                exportInsightMemory(mem)
                s.insights += 1
            } else {
                exportRegularMemory(mem)
                s.memories += 1
            }
        }

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
        let input = ObsidianMarkdownRenderer.MemoryInput(
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
        let md = ObsidianMarkdownRenderer.renderMemory(input)
        let path = ObsidianPath.memoryPath(
            date: mem.createdAt,
            project: mem.project,
            content: mem.content
        )
        write(md, to: path, kind: "memory")
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
            body: mem.content
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
        return ObsidianMarkdownRenderer.TaskInput(
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
        } catch {
            lastError = "Write failed for \(kind) at \(relativePath): \(error.localizedDescription)"
            stats.errors += 1
            NSLog("[ObsidianExporter] ❌ write failed (%@): %@", kind, error.localizedDescription)
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
        guard let container = modelContainer else { return nil }
        return ModelContext(container)
    }
}
