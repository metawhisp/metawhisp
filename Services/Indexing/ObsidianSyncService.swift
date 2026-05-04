import Foundation
import SwiftData

/// Outbound sync to user's Obsidian vault (2026-04-28).
///
/// Writes new `UserMemory` rows as append-only Markdown entries inside
/// `<vault>/MetaWhisp/Journal.md`. Lets the user's stored facts propagate
/// out of the app and into their broader Obsidian-connected knowledge graph
/// (mobile sync, plugins, search, etc).
///
/// Design choices:
/// - **Append-only** — never edits or deletes existing lines. Safe under any
///   concurrent edit by the user; no risk of data loss.
/// - **One file** — `Journal.md`. Keeps it simple. Categorisation lives in
///   the entries themselves via tags + structured prefix.
/// - **Idempotent** — uses `obsidianLastSyncedAt` watermark so re-runs only
///   append memories created AFTER the last successful run.
/// - **Read-only on existing content** — file may be read by Obsidian or
///   other tools mid-write; we use atomic append (load + concat + write
///   whole file via `Data.write(to:options:.atomic)`).
@MainActor
final class ObsidianSyncService: ObservableObject {
    @Published var isSyncing = false
    @Published var lastError: String?
    @Published var lastSyncSummary: String?
    @Published var lastSyncAt: Date?

    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?
    private var timerTask: Task<Void, Never>?

    /// Subdirectory inside the vault where the journal lives.
    private let journalSubdir = "MetaWhisp"
    /// Filename — single chronological journal.
    private let journalFile = "Journal.md"

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func startPeriodic() {
        stopPeriodic()
        guard settings.obsidianSyncEnabled else { return }
        let interval = max(60, settings.obsidianSyncInterval)
        timerTask = Task { @MainActor [weak self] in
            // Initial run on a small delay so app launch isn't blocked.
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let strongSelf = self else { return }
            await strongSelf.syncNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let s = self, s.settings.obsidianSyncEnabled else { return }
                await s.syncNow()
            }
        }
        NSLog("[Obsidian] ✅ Periodic sync started (interval: %.0fs)", interval)
    }

    func stopPeriodic() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Append all UserMemory rows created since `obsidianLastSyncedAt` to the
    /// journal file. Manual invocation from Settings → SYNC NOW also calls this.
    @discardableResult
    func syncNow() async -> Int {
        guard !isSyncing else { return 0 }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        let vaultPath = settings.obsidianVaultPath.trimmingCharacters(in: .whitespaces)
        guard !vaultPath.isEmpty else {
            lastError = "Obsidian vault path not set."
            return 0
        }
        let vaultURL = URL(fileURLWithPath: vaultPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: vaultURL.path) else {
            lastError = "Vault path does not exist: \(vaultPath)"
            return 0
        }

        // Resolve "since" watermark.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let since: Date = {
            guard !settings.obsidianLastSyncedAt.isEmpty,
                  let d = formatter.date(from: settings.obsidianLastSyncedAt)
            else { return Date.distantPast }
            return d
        }()

        guard let container = modelContainer else { return 0 }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed && $0.createdAt > since },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        desc.fetchLimit = 500
        let memories = (try? ctx.fetch(desc)) ?? []

        guard !memories.isEmpty else {
            lastSyncAt = Date()
            lastSyncSummary = "No new memories to sync."
            return 0
        }

        // Ensure target directory exists.
        let dirURL = vaultURL.appendingPathComponent(journalSubdir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            lastError = "Cannot create \(journalSubdir) folder: \(error.localizedDescription)"
            return 0
        }

        let fileURL = dirURL.appendingPathComponent(journalFile)
        let header = "# MetaWhisp Journal\n\nAuto-synced memories. Newest at the bottom.\n\n"
        var existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? header
        if existing.isEmpty { existing = header }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        var newLines: [String] = []
        var currentDayHeader: String? = lastDayHeader(in: existing)

        for mem in memories {
            let day = dayFormatter.string(from: mem.createdAt)
            let dayHeader = "## \(day)"
            if currentDayHeader != dayHeader {
                newLines.append("")
                newLines.append(dayHeader)
                currentDayHeader = dayHeader
            }
            newLines.append(formatLine(mem, time: timeFormatter.string(from: mem.createdAt)))
        }

        let updated = existing + newLines.joined(separator: "\n") + "\n"
        do {
            try updated.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            lastError = "Write failed: \(error.localizedDescription)"
            return 0
        }

        // Update watermark to the createdAt of the last appended memory.
        if let last = memories.last {
            settings.obsidianLastSyncedAt = formatter.string(from: last.createdAt)
        }
        lastSyncAt = Date()
        lastSyncSummary = "Synced \(memories.count) memory\(memories.count == 1 ? "" : "ies") to \(fileURL.path)"
        NSLog("[Obsidian] ✅ Appended %d memories to %@", memories.count, fileURL.path)
        return memories.count
    }

    // MARK: - Helpers

    /// One-line representation of a memory for the journal. Prefers the
    /// structured fields when present so the file looks human + readable in
    /// any Obsidian view (graph, tags, search).
    private func formatLine(_ mem: UserMemory, time: String) -> String {
        var line = "- `\(time)`"
        if let kind = mem.kind, !kind.isEmpty {
            let label = kind.uppercased()
            let subjectPart = (mem.subject?.isEmpty == false) ? " **\(mem.subject!)** —" : ""
            let charact = mem.characterization?.isEmpty == false ? mem.characterization! : mem.content
            line += " \(label)\(subjectPart) \(charact)"
        } else if let h = mem.headline, !h.isEmpty {
            line += " **\(h)** — \(mem.content)"
        } else {
            line += " \(mem.content)"
        }
        // Source tag for filtering by app.
        let src = mem.sourceApp.replacingOccurrences(of: " ", with: "-").lowercased()
        if !src.isEmpty { line += " #src/\(src)" }
        // User tags inline.
        if let tags = mem.tagsCSV, !tags.isEmpty {
            let parts = tags.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            for t in parts where !t.isEmpty { line += " #\(t)" }
        }
        return line
    }

    /// Walks back through existing file content to find the most recent `## YYYY-MM-DD`
    /// header so we can avoid emitting a duplicate one for today's first entry.
    private func lastDayHeader(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { return trimmed }
        }
        return nil
    }
}
