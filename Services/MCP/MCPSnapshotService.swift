import Foundation
import SwiftData

/// Periodic dump of MetaWhisp's user-data state to a JSON file that the
/// standalone `metawhisp-mcp` CLI (Sources/MetaWhispMCP) reads when
/// Claude / Cursor invokes a tool. We don't share the SwiftData store
/// directly with the MCP binary — that'd require either duplicating
/// `@Model` classes across two SwiftPM targets or opening the SQLite
/// store concurrently from two processes (recipe for corruption). A
/// snapshot file is a clean read-only contract.
///
/// **File location:** `~/Library/Application Support/MetaWhisp/mcp-snapshot.json`
/// **Refresh cadence:** every 5 minutes (timer) + on key writes (debounced).
/// **Contents (v1):**
///   - `memories[]` — non-dismissed UserMemory rows
///   - `tasks[]`    — non-dismissed TaskItem rows
///   - `conversations[]` — last 50 finished conversations with title/overview
///
/// Privacy: snapshot lives ONLY on the user's disk, never uploaded. The
/// MCP binary is also local-only (stdio to Claude Desktop). Embeddings
/// (`Data` blobs) are omitted — too large + binary-unfriendly for JSON.
@MainActor
final class MCPSnapshotService {
    static let shared = MCPSnapshotService()

    private var modelContainer: ModelContainer?
    private var timerTask: Task<Void, Never>?

    /// Refresh cadence. 5 min strikes a balance: Claude users querying
    /// «last hour» see near-fresh data; the JSON write isn't a hot path.
    private let interval: TimeInterval = 300

    /// Where the snapshot lives. Stable path so the MCP binary reads
    /// from a known location without any IPC handshake.
    static var snapshotURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MetaWhisp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mcp-snapshot.json")
    }

    private init() {}

    func configure(container: ModelContainer) {
        self.modelContainer = container
    }

    /// Start periodic writer. Call from `AppDelegate.applicationDidFinishLaunching`
    /// after HistoryService is up.
    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            // First write immediately so the file exists on launch.
            await self?.writeSnapshot()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.interval ?? 300))
                if Task.isCancelled { return }
                await self?.writeSnapshot()
            }
        }
        NSLog("[MCPSnapshot] ✅ started (interval %.0fs, path=%@)",
              interval, Self.snapshotURL.path)
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Force a write. Called from services that mutate user data after
    /// significant events (new conversation closed, memory extracted,
    /// task completed) — keeps Claude's view fresh without waiting 5 min.
    func snapshotNow() {
        Task { @MainActor in await writeSnapshot() }
    }

    // MARK: - Internals

    private func writeSnapshot() async {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)

        // Pull memories (non-dismissed). Cap at 500 to keep JSON ≤ ~1 MB.
        var memDesc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        memDesc.fetchLimit = 500
        let memories: [UserMemory] = (try? ctx.fetch(memDesc)) ?? []

        // Pull tasks (non-dismissed, including completed for the «what
        // did I finish recently» query). Cap 500.
        var taskDesc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        taskDesc.fetchLimit = 500
        let tasks: [TaskItem] = (try? ctx.fetch(taskDesc)) ?? []

        // Conversations: last 100 finished, NOT discarded, with title or overview.
        var convoDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.finishedAt != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        convoDesc.fetchLimit = 100
        let convos: [Conversation] = (try? ctx.fetch(convoDesc)) ?? []

        // Map to wire-friendly DTOs.
        let memoryDTOs = memories.map { m in
            MCPMemory(
                id: m.id.uuidString,
                kind: m.kind ?? "FACT",
                subject: m.subject ?? "",
                content: m.content,
                category: m.category,
                project: m.project,
                createdAt: m.createdAt
            )
        }
        let taskDTOs = tasks.map { t in
            MCPTask(
                id: t.id.uuidString,
                description: t.taskDescription,
                completed: t.completed,
                dueAt: t.dueAt,
                createdAt: t.createdAt,
                completedAt: t.completedAt
            )
        }
        let convoDTOs = convos.map { c in
            MCPConversation(
                id: c.id.uuidString,
                title: c.title ?? "Untitled",
                overview: c.overview ?? "",
                category: c.category ?? "",
                project: c.primaryProject ?? "",
                startedAt: c.startedAt,
                finishedAt: c.finishedAt ?? c.startedAt
            )
        }

        let snapshot = MCPSnapshot(
            generatedAt: Date(),
            schemaVersion: 1,
            memories: memoryDTOs,
            tasks: taskDTOs,
            conversations: convoDTOs
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: Self.snapshotURL, options: .atomic)
            NSLog("[MCPSnapshot] wrote %d memories, %d tasks, %d conversations (%d bytes)",
                  memoryDTOs.count, taskDTOs.count, convoDTOs.count, data.count)
        } catch {
            NSLog("[MCPSnapshot] write failed: %@", error.localizedDescription)
        }
    }
}

// MARK: - Wire DTOs (shared schema with the MCP binary)

/// Stable on-disk schema. Bump `schemaVersion` in `MCPSnapshot` when you
/// change fields; the MCP binary's reader checks this.
struct MCPSnapshot: Codable {
    let generatedAt: Date
    let schemaVersion: Int
    let memories: [MCPMemory]
    let tasks: [MCPTask]
    let conversations: [MCPConversation]
}

struct MCPMemory: Codable {
    let id: String
    let kind: String       // FACT / OPINION / GOAL etc.
    let subject: String    // person / project / thing
    let content: String
    let category: String?  // optional cluster label
    let project: String?
    let createdAt: Date
}

struct MCPTask: Codable {
    let id: String
    let description: String
    let completed: Bool
    let dueAt: Date?
    let createdAt: Date
    let completedAt: Date?
}

struct MCPConversation: Codable {
    let id: String
    let title: String
    let overview: String
    let category: String
    let project: String
    let startedAt: Date
    let finishedAt: Date
}
