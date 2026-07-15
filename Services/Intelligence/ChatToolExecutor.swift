import Foundation
import SwiftData

/// Executes mutation tools surfaced by the MetaChat LLM (ITER-016, v1).
///
/// Transport: LLM is instructed via system-prompt to emit a structured
/// `<tool_call>{"tool":"<name>","args":{...}}</tool_call>` block whenever the user
/// asks for a mutation action. `ChatService` extracts the block, the UI shows a
/// confirmation bubble, and — on user approval — calls `execute(_:in:)` here.
///
/// v1 scope (what's live):
/// - 6 tools: dismissTask, completeTask, dismissMemory, updateGoalProgress, addTask, addMemory.
/// - Validation before mutation (existence + state sanity).
/// - Human-readable result message used to compose the assistant's final text reply.
///
/// v2 (deferred to next session):
/// - Undo toast + per-session rate limit + `AuditLog` model.
/// - Switch to native Anthropic/OpenAI tool use (drop `<tool_call>` parsing).
///
/// spec://iterations/ITER-016-conversational-mutation
@MainActor
final class ChatToolExecutor: ObservableObject {

    enum ToolError: Error, LocalizedError {
        case unknownTool(String)
        case invalidArgs(String)
        case notFound(String)
        case alreadyInState(String)

        var errorDescription: String? {
            switch self {
            case .unknownTool(let n): return "Unknown tool: \(n)"
            case .invalidArgs(let m): return "Bad arguments: \(m)"
            case .notFound(let m):    return "Not found: \(m)"
            case .alreadyInState(let m): return "Already: \(m)"
            }
        }
    }

    /// Result of a single tool execution. `summary` becomes the user-visible
    /// line in the chat bubble after execute. `ok == false` short-circuits the
    /// followup — the assistant should say "I couldn't do that because <err>".
    /// `auditId` is the AuditLog row inserted by execute() — non-nil even on
    /// failure (we audit attempts) so the UI can offer undo when applicable.
    struct ExecResult {
        let ok: Bool
        let summary: String
        let auditId: UUID?
    }

    // MARK: - Rate limit (ITER-016 v2)

    /// Max mutations allowed within a rolling window. Defends against a
    /// runaway agentic loop OR a user pasting "delete everything" rapidly.
    private static let rateLimitMax = 5
    private static let rateLimitWindowSeconds: TimeInterval = 60

    /// Timestamps of recent successful execute() calls (rolling window). In-memory
    /// only — no need to persist; the limit is per process session.
    private var recentExecutionTimestamps: [Date] = []

    /// Returns true when a fresh execute() must be rejected. Side-effect: prunes
    /// the window so repeat checks stay O(N) where N <= rateLimitMax.
    private func isRateLimited() -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.rateLimitWindowSeconds)
        recentExecutionTimestamps = recentExecutionTimestamps.filter { $0 >= cutoff }
        return recentExecutionTimestamps.count >= Self.rateLimitMax
    }

    private func recordExecution() {
        recentExecutionTimestamps.append(Date())
    }

    /// Parsed representation of a tool call extracted from LLM output.
    struct ToolCall: Equatable {
        /// Native `tool_call_id` from Groq function-calling. Nil for legacy
        /// `<tool_call>` regex path (non-Pro). Required by ITER-017 v2 multi-step
        /// loop to correlate the corresponding `{role:"tool", tool_call_id}` reply.
        let id: String?
        let tool: String
        /// Normalized argument map. All values kept as strings for schema simplicity.
        let args: [String: String]
    }

    private var modelContainer: ModelContainer?
    /// Optional — if wired, search* tools rank results by semantic similarity to
    /// the query string. Without it they fall back to substring match (still useful).
    weak var embeddingService: EmbeddingService?

    /// SB-2 — route Task/UserMemory commits through MutationService so a failed
    /// save propagates (no more `try? + ok = true`) and Obsidian/MCP refresh on
    /// success. Injectable so tests can substitute no-op hooks.
    var mutationService: MutationService = .shared

    func configure(modelContainer: ModelContainer, embeddingService: EmbeddingService? = nil) {
        self.modelContainer = modelContainer
        self.embeddingService = embeddingService
    }

    // MARK: - Public: validation + execution

    /// Pre-flight check — does the target exist? Is the requested state-change sensible?
    /// Returns a short human-readable preview string for the confirm UI (e.g.
    /// `"Dismiss task \"Reply to Mike\""`) or an error to surface instead of
    /// offering confirmation.
    func validate(_ call: ToolCall) -> Result<String, ToolError> {
        guard let container = modelContainer else {
            return .failure(.invalidArgs("model container not configured"))
        }
        let ctx = ModelContext(container)

        switch call.tool {
        case "dismissTask", "completeTask":
            guard let idStr = call.args["id"], let uuid = UUID(uuidString: idStr) else {
                return .failure(.invalidArgs("id must be a UUID"))
            }
            guard let task = fetchOne(TaskItem.self, id: uuid, in: ctx) else {
                return .failure(.notFound("task with id \(idStr.prefix(8))…"))
            }
            if call.tool == "completeTask" && task.completed {
                return .failure(.alreadyInState("task already done"))
            }
            if call.tool == "dismissTask" && (task.isDismissed || task.status == "dismissed") {
                return .failure(.alreadyInState("task already dismissed"))
            }
            let action = call.tool == "dismissTask" ? "Dismiss" : "Mark done"
            return .success("\(action) task \"\(task.taskDescription)\"")

        case "dismissMemory":
            guard let idStr = call.args["id"], let uuid = UUID(uuidString: idStr) else {
                return .failure(.invalidArgs("id must be a UUID"))
            }
            guard let mem = fetchOne(UserMemory.self, id: uuid, in: ctx) else {
                return .failure(.notFound("memory with id \(idStr.prefix(8))…"))
            }
            if mem.isDismissed {
                return .failure(.alreadyInState("memory already dismissed"))
            }
            return .success("Forget memory \"\(mem.content.prefix(80))\"")

        case "updateGoalProgress":
            guard let idStr = call.args["id"], let uuid = UUID(uuidString: idStr) else {
                return .failure(.invalidArgs("id must be a UUID"))
            }
            guard let deltaStr = call.args["delta"], let delta = Int(deltaStr) else {
                return .failure(.invalidArgs("delta must be an integer"))
            }
            guard let goal = fetchOne(Goal.self, id: uuid, in: ctx) else {
                return .failure(.notFound("goal with id \(idStr.prefix(8))…"))
            }
            let direction = delta >= 0 ? "+\(delta)" : "\(delta)"
            return .success("Adjust goal \"\(goal.title)\" by \(direction)")

        case "addTask":
            guard let desc = call.args["description"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !desc.isEmpty else {
                return .failure(.invalidArgs("description required"))
            }
            let words = desc.split(separator: " ").count
            if words > 15 {
                return .failure(.invalidArgs("description too long (>15 words) — rephrase"))
            }
            var preview = "Create task \"\(desc)\""
            if let a = call.args["assignee"], !a.isEmpty, a != "null" { preview += " (waiting on \(a))" }
            return .success(preview)

        case "addMemory":
            guard let content = call.args["content"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                return .failure(.invalidArgs("content required"))
            }
            let cat = call.args["category"]?.lowercased() ?? "system"
            guard ["system", "interesting"].contains(cat) else {
                return .failure(.invalidArgs("category must be system or interesting"))
            }
            return .success("Store memory \"\(content.prefix(80))\"")

        default:
            return .failure(.unknownTool(call.tool))
        }
    }

    /// Execute a validated tool call. Returns an `ExecResult` — callers read
    /// `summary` as the single-line "what happened" string to splice into the
    /// followup assistant turn. ITER-016 v2: enforces rate limit, captures
    /// snapshot for undo, writes to `AuditLog`.
    ///
    /// `chatMessageId` is the message that triggered the call (binds the audit
    /// row back to chat for the per-message Undo button).
    func execute(_ call: ToolCall, chatMessageId: UUID? = nil) -> ExecResult {
        guard let container = modelContainer else {
            return ExecResult(ok: false, summary: "Internal error — no DB", auditId: nil)
        }

        // Rate limit BEFORE side effects. Reject loudly with a clear summary so
        // the chat bubble explains why nothing happened.
        if isRateLimited() {
            let result = ExecResult(
                ok: false,
                summary: "Rate-limited (max \(Self.rateLimitMax) actions per minute) — try again shortly",
                auditId: nil
            )
            // Still audit the rejection so reviews show "tried to dismiss X but rate-limited".
            _ = writeAudit(
                tool: call.tool,
                args: call.args,
                summary: result.summary,
                success: false,
                snapshotJSON: nil,
                chatMessageId: chatMessageId
            )
            return result
        }

        let ctx = ModelContext(container)
        var snapshotJSON: String? = nil
        var summary = ""
        var ok = false

        switch call.tool {
        case "dismissTask":
            guard let idStr = call.args["id"], let uuid = UUID(uuidString: idStr),
                  let task = fetchOne(TaskItem.self, id: uuid, in: ctx) else {
                let r = ExecResult(ok: false, summary: "Task not found", auditId: nil)
                _ = writeAudit(tool: call.tool, args: call.args, summary: r.summary,
                               success: false, snapshotJSON: nil, chatMessageId: chatMessageId)
                return r
            }
            // Snapshot BEFORE mutation.
            snapshotJSON = encodeSnapshot([
                "taskId": task.id.uuidString,
                "wasIsDismissed": task.isDismissed,
                "wasStatus": task.status ?? "committed",
            ])
            do {
                try mutationService.commit(.taskSaved(task.id), in: ctx) {
                    task.isDismissed = true
                    task.status = "dismissed"
                    task.updatedAt = Date()
                }
                ok = true
                summary = "Dismissed task: \(task.taskDescription)"
            } catch {
                summary = "Couldn't save — the task wasn't dismissed (\(error.localizedDescription))"
            }

        case "completeTask":
            guard let idStr = call.args["id"], let uuid = UUID(uuidString: idStr),
                  let task = fetchOne(TaskItem.self, id: uuid, in: ctx) else {
                let r = ExecResult(ok: false, summary: "Task not found", auditId: nil)
                _ = writeAudit(tool: call.tool, args: call.args, summary: r.summary,
                               success: false, snapshotJSON: nil, chatMessageId: chatMessageId)
                return r
            }
            snapshotJSON = encodeSnapshot([
                "taskId": task.id.uuidString,
                "wasCompleted": task.completed,
                "wasCompletedAt": task.completedAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
            ])
            do {
                try mutationService.commit(.taskSaved(task.id), in: ctx) {
                    task.completed = true
                    task.completedAt = Date()
                    task.updatedAt = Date()
                }
                ok = true
                summary = "Marked done: \(task.taskDescription)"
            } catch {
                summary = "Couldn't save — the task wasn't marked done (\(error.localizedDescription))"
            }

        case "dismissMemory":
            guard let idStr = call.args["id"], let uuid = UUID(uuidString: idStr),
                  let mem = fetchOne(UserMemory.self, id: uuid, in: ctx) else {
                let r = ExecResult(ok: false, summary: "Memory not found", auditId: nil)
                _ = writeAudit(tool: call.tool, args: call.args, summary: r.summary,
                               success: false, snapshotJSON: nil, chatMessageId: chatMessageId)
                return r
            }
            snapshotJSON = encodeSnapshot([
                "memoryId": mem.id.uuidString,
                "wasIsDismissed": mem.isDismissed,
            ])
            do {
                // .memoryDismissed (not .memorySaved): the saved-hook calls
                // exportMemory, which no-ops on a dismissed memory — leaving the
                // stale .md in the vault (AUD-030). The dismissed-hook deletes it.
                // (Tasks don't need this: exportTask itself deletes when dismissed.)
                try mutationService.commit(.memoryDismissed(mem.id), in: ctx) {
                    mem.isDismissed = true
                    mem.updatedAt = Date()
                }
                ok = true
                summary = "Forgot: \(mem.content.prefix(80))"
            } catch {
                summary = "Couldn't save — the memory wasn't forgotten (\(error.localizedDescription))"
            }

        case "updateGoalProgress":
            guard let idStr = call.args["id"], let uuid = UUID(uuidString: idStr),
                  let goal = fetchOne(Goal.self, id: uuid, in: ctx),
                  let deltaStr = call.args["delta"], let delta = Int(deltaStr) else {
                let r = ExecResult(ok: false, summary: "Bad goal update", auditId: nil)
                _ = writeAudit(tool: call.tool, args: call.args, summary: r.summary,
                               success: false, snapshotJSON: nil, chatMessageId: chatMessageId)
                return r
            }
            goal.resetIfNewDay()
            snapshotJSON = encodeSnapshot([
                "goalId": goal.id.uuidString,
                "previousValue": goal.currentValue,
            ])
            // Goal uses a single `currentValue: Double` across all three types.
            // Semantics per type:
            // - boolean: 0 or 1. Any delta >= 1 → 1 (done); delta <= -1 → 0 (reset).
            // - scale: clamped to [minValue ?? 1, maxValue ?? 10].
            // - numeric: 0…∞, clamp to >= 0.
            switch goal.goalType {
            case "boolean":
                goal.currentValue = delta >= 1 ? 1 : 0
            case "scale":
                let lo = goal.minValue ?? 1
                let hi = goal.maxValue ?? 10
                goal.currentValue = max(lo, min(hi, goal.currentValue + Double(delta)))
            case "numeric":
                goal.currentValue = max(0, goal.currentValue + Double(delta))
            default:
                let r = ExecResult(ok: false, summary: "Unknown goal type", auditId: nil)
                _ = writeAudit(tool: call.tool, args: call.args, summary: r.summary,
                               success: false, snapshotJSON: nil, chatMessageId: chatMessageId)
                return r
            }
            goal.lastProgressAt = Date()
            goal.updatedAt = Date()
            // Goal is outside MutationService's Task/UserMemory scope (it has no
            // Obsidian export); still propagate the save so a failure isn't
            // reported as success.
            do {
                try ctx.save()
                ok = true
                summary = "Updated goal \"\(goal.title)\" → \(goal.progressLabel)"
            } catch {
                summary = "Couldn't save — the goal wasn't updated (\(error.localizedDescription))"
            }

        case "addTask":
            guard let desc = call.args["description"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !desc.isEmpty else {
                let r = ExecResult(ok: false, summary: "Description required", auditId: nil)
                _ = writeAudit(tool: call.tool, args: call.args, summary: r.summary,
                               success: false, snapshotJSON: nil, chatMessageId: chatMessageId)
                return r
            }
            let assignee: String? = {
                guard let raw = call.args["assignee"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty, raw.lowercased() != "null" else { return nil }
                return raw
            }()
            var dueAt: Date? = nil
            if let raw = call.args["dueAt"], !raw.isEmpty, raw.lowercased() != "null" {
                let df = ISO8601DateFormatter()
                df.formatOptions = [.withInternetDateTime]
                dueAt = df.date(from: raw)
            }
            let task = TaskItem(
                taskDescription: desc,
                dueAt: dueAt,
                sourceApp: "MetaChat",
                assignee: assignee
            )
            do {
                try mutationService.insert(task, in: ctx)
                // Snapshot AFTER insert — undo = soft-delete the row we just created.
                snapshotJSON = encodeSnapshot(["createdTaskId": task.id.uuidString])
                ok = true
                let tag = assignee.map { " (waiting on \($0))" } ?? ""
                summary = "Added task: \(desc)\(tag)"
            } catch {
                summary = "Couldn't save the new task (\(error.localizedDescription))"
            }

        case "addMemory":
            guard let content = call.args["content"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                let r = ExecResult(ok: false, summary: "Content required", auditId: nil)
                _ = writeAudit(tool: call.tool, args: call.args, summary: r.summary,
                               success: false, snapshotJSON: nil, chatMessageId: chatMessageId)
                return r
            }
            let cat = call.args["category"]?.lowercased() ?? "system"
            let mem = UserMemory(
                content: content,
                category: cat,
                sourceApp: "MetaChat",
                confidence: 1.0
            )
            do {
                try mutationService.insert(mem, in: ctx)
                snapshotJSON = encodeSnapshot(["createdMemoryId": mem.id.uuidString])
                ok = true
                summary = "Stored memory: \(content.prefix(80))"
            } catch {
                summary = "Couldn't save the new memory (\(error.localizedDescription))"
            }

        default:
            let r = ExecResult(ok: false, summary: "Unknown tool: \(call.tool)", auditId: nil)
            _ = writeAudit(tool: call.tool, args: call.args, summary: r.summary,
                           success: false, snapshotJSON: nil, chatMessageId: chatMessageId)
            return r
        }

        recordExecution()
        let auditId = writeAudit(
            tool: call.tool,
            args: call.args,
            summary: summary,
            success: ok,
            snapshotJSON: snapshotJSON,
            chatMessageId: chatMessageId
        )
        return ExecResult(ok: ok, summary: summary, auditId: auditId)
    }

    // MARK: - Read-only execute (ITER-017 v3)

    /// Executes a read-only tool (search*) and returns the result as a JSON string
    /// in `summary` so the LLM can parse it from the `tool_result` content.
    /// No rate-limit, no snapshot, no audit row (read-only is safe).
    /// Async because we may call out to the embeddings endpoint for semantic ranking.
    func executeReadOnly(_ call: ToolCall) async -> ExecResult {
        guard Self.isReadOnly(call.tool) else {
            return ExecResult(ok: false, summary: "Not a read-only tool: \(call.tool)", auditId: nil)
        }
        guard modelContainer != nil else {
            return ExecResult(ok: false, summary: "Internal error — no DB", auditId: nil)
        }
        switch call.tool {
        case "searchTasks":       return await searchTasks(call.args)
        case "searchMemories":    return await searchMemories(call.args)
        case "searchConversations": return await searchConversations(call.args)
        case "searchScreenHistory": return await searchScreenHistory(call.args)
        default:
            return ExecResult(ok: false, summary: "Unknown read-only tool", auditId: nil)
        }
    }

    private func searchTasks(_ args: [String: String]) async -> ExecResult {
        guard let container = modelContainer else { return ExecResult(ok: false, summary: "no db", auditId: nil) }
        let query = args["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { return ExecResult(ok: false, summary: "Empty query", auditId: nil) }
        let limit = min(30, max(1, Int(args["limit"] ?? "10") ?? 10))

        let ctx = ModelContext(container)
        let desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed && !$0.completed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let all = (try? ctx.fetch(desc))?.filter { $0.status != "staged" && $0.status != "dismissed" } ?? []

        let ranked = await rankByQuery(items: all, query: query, embedding: { $0.embedding },
                                        textForSubstring: { $0.taskDescription }, limit: limit)
        let payload: [[String: Any]] = ranked.map { t in
            var d: [String: Any] = [
                "id": t.id.uuidString,
                "description": t.taskDescription,
            ]
            if let a = t.assignee, !a.isEmpty { d["assignee"] = a }
            if let due = t.dueAt { d["dueAt"] = ISO8601DateFormatter().string(from: due) }
            return d
        }
        return ExecResult(ok: true, summary: jsonString(["items": payload, "count": payload.count]), auditId: nil)
    }

    private func searchMemories(_ args: [String: String]) async -> ExecResult {
        guard let container = modelContainer else { return ExecResult(ok: false, summary: "no db", auditId: nil) }
        let query = args["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { return ExecResult(ok: false, summary: "Empty query", auditId: nil) }
        let limit = min(30, max(1, Int(args["limit"] ?? "10") ?? 10))

        let ctx = ModelContext(container)
        let desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let all = (try? ctx.fetch(desc)) ?? []
        let ranked = await rankByQuery(items: all, query: query, embedding: { $0.embedding },
                                        textForSubstring: { ($0.headline ?? "") + " " + $0.content },
                                        limit: limit)
        let payload: [[String: Any]] = ranked.map { m in
            var d: [String: Any] = [
                "id": m.id.uuidString,
                "content": m.content,
            ]
            if let h = m.headline, !h.isEmpty { d["headline"] = h }
            return d
        }
        return ExecResult(ok: true, summary: jsonString(["items": payload, "count": payload.count]), auditId: nil)
    }

    private func searchConversations(_ args: [String: String]) async -> ExecResult {
        guard let container = modelContainer else { return ExecResult(ok: false, summary: "no db", auditId: nil) }
        let query = args["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { return ExecResult(ok: false, summary: "Empty query", auditId: nil) }
        let limit = min(15, max(1, Int(args["limit"] ?? "5") ?? 5))

        let ctx = ModelContext(container)
        let desc = FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.title != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let all = (try? ctx.fetch(desc)) ?? []
        let ranked = await rankByQuery(items: all, query: query, embedding: { $0.embedding },
                                        textForSubstring: { ($0.title ?? "") + " " + ($0.overview ?? "") },
                                        limit: limit)
        let payload: [[String: Any]] = ranked.map { c in
            var d: [String: Any] = [
                "id": c.id.uuidString,
                "title": c.title ?? "(untitled)",
                "startedAt": ISO8601DateFormatter().string(from: c.startedAt),
            ]
            if let ov = c.overview, !ov.isEmpty { d["overview"] = ov }
            if let proj = c.primaryProject, !proj.isEmpty { d["project"] = proj }
            return d
        }
        return ExecResult(ok: true, summary: jsonString(["items": payload, "count": payload.count]), auditId: nil)
    }

    /// ITER-053.4 (первый срез) — «спроси свой экран»: searches BOTH layers of
    /// the screen store within a day window. Distilled ScreenObservation rows
    /// answer «что я делал по X»; raw ScreenContext OCR answers «что мне писал
    /// Alex» / «где я видел ту ссылку» (messengers, pages, code the user saw).
    /// Keyword ranking v1 — plugs into semantic automatically once observations
    /// get embeddings (053.4 full).
    private func searchScreenHistory(_ args: [String: String]) async -> ExecResult {
        guard let container = modelContainer else { return ExecResult(ok: false, summary: "no db", auditId: nil) }
        let query = args["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { return ExecResult(ok: false, summary: "Empty query", auditId: nil) }
        let limit = min(20, max(1, Int(args["limit"] ?? "8") ?? 8))
        let days = min(90, max(1, Int(args["days"] ?? "7") ?? 7))
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        // Review fix — LOCAL timezone, not UTC: «что я делал вчера» is a
        // day-boundary question; UTC stamps shift the user's evening into the
        // wrong day and the LLM answers about the wrong date.
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current

        let ownApp = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "MetaWhisp"
        let ctx = ModelContext(container)
        // Distilled timeline — «what was I doing». Own-app rows dropped for the
        // same feedback-loop reason as raw OCR below (review fix — the filter
        // used to cover only one of the two layers).
        let obsDesc = FetchDescriptor<ScreenObservation>(
            predicate: #Predicate { $0.endedAt >= cutoff },
            sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
        )
        let observations = ((try? ctx.fetch(obsDesc)) ?? []).filter {
            !ScreenContextNoiseFilter.isOwnWindow(appName: $0.appName, ownAppName: ownApp)
        }
        let rankedObs = await rankByQuery(
            items: observations, query: query, embedding: { _ in nil },
            textForSubstring: { "\($0.appName) \($0.windowTitle ?? "") \($0.contextSummary) \($0.currentActivity)" },
            limit: limit)

        // Raw OCR — «what did I see / what did people write me». Newest-first,
        // bounded fetch so months of rows can't blow memory; own-app windows
        // are a feedback loop (our answers re-captured as "facts") — dropped.
        var rawDesc = FetchDescriptor<ScreenContext>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        rawDesc.fetchLimit = 2000
        let raws = ((try? ctx.fetch(rawDesc)) ?? []).filter {
            !ScreenContextNoiseFilter.isOwnWindow(appName: $0.appName, ownAppName: ownApp)
        }
        let rankedRaw = await rankByQuery(
            items: raws, query: query, embedding: { _ in nil },
            textForSubstring: { "\($0.appName) \($0.windowTitle) \($0.ocrText)" },
            limit: limit)

        let activities: [[String: Any]] = rankedObs.map { o in
            [
                "when": iso.string(from: o.endedAt),
                "app": o.appName,
                "summary": o.contextSummary,
                "activity": o.currentActivity,
            ]
        }
        let screenTexts: [[String: Any]] = rankedRaw.map { r in
            [
                "when": iso.string(from: r.timestamp),
                "app": r.appName,
                "window": r.windowTitle,
                "snippet": Self.matchSnippet(in: r.ocrText, query: query),
            ]
        }
        return ExecResult(ok: true, summary: jsonString([
            "activities": activities,
            "screen_texts": screenTexts,
            "count": activities.count + screenTexts.count,
            "window_days": days,
        ]), auditId: nil)
    }

    /// Slice ~2×radius chars of OCR around the first query-token hit so the
    /// LLM gets the evidence, not a 4KB wall. Head of text when nothing hits.
    static func matchSnippet(in text: String, query: String, radius: Int = 120) -> String {
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        // Earliest case-insensitive hit across tokens — ranges from `text`
        // itself (indices from a lowercased COPY are not transferable).
        var hit: Range<String.Index>?
        for t in tokens {
            if let r = text.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]),
               hit == nil || r.lowerBound < hit!.lowerBound {
                hit = r
            }
        }
        guard let found = hit else {
            return String(text.prefix(2 * radius)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let start = text.index(found.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(found.lowerBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > text.startIndex { s = "…" + s }
        if end < text.endIndex { s += "…" }
        return s
    }

    /// Generic ranker: try semantic (cosine on embedding) when query embedding is
    /// available, fall back to substring/keyword match otherwise. Substring fallback
    /// is permissive — splits query into tokens and counts matches in the text field.
    private func rankByQuery<T: AnyObject>(items: [T],
                                            query: String,
                                            embedding: (T) -> Data?,
                                            textForSubstring: (T) -> String,
                                            limit: Int) async -> [T] {
        guard !items.isEmpty else { return [] }
        // Try semantic ranking via embeddings (Pro only). Review fix: embed the
        // QUERY only when at least one item actually carries an embedding —
        // otherwise (e.g. screen history, keyword v1) the network call is a
        // guaranteed-wasted ~300ms + Pro cost before the substring fallback.
        if let svc = embeddingService, LicenseService.shared.isPro,
           items.contains(where: { embedding($0) != nil }) {
            if let qVec = try? await svc.embedOne(query) {
                var scored: [(T, Float)] = []
                for item in items {
                    guard let data = embedding(item) else { continue }
                    let vec = EmbeddingService.decode(data)
                    if vec.isEmpty { continue }
                    scored.append((item, EmbeddingService.cosineSimilarity(qVec, vec)))
                }
                if !scored.isEmpty {
                    return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
                }
            }
        }
        // Substring fallback: token overlap count.
        let qTokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !qTokens.isEmpty else { return Array(items.prefix(limit)) }
        let scored = items.map { item -> (T, Int) in
            let text = textForSubstring(item).lowercased()
            let hits = qTokens.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
            return (item, hits)
        }
        return scored.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    private func jsonString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - Undo (ITER-016 v2)

    /// Revert a single audit entry. No-op if already undone, expired, or non-undoable.
    /// Returns a short status string for chat display ("Reverted: …" or error reason).
    func undo(auditId: UUID) -> String {
        guard let container = modelContainer else { return "Cannot undo — no DB" }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<AuditLog>(predicate: #Predicate { $0.id == auditId })
        desc.fetchLimit = 1
        guard let entry = (try? ctx.fetch(desc))?.first else { return "Cannot undo — audit row missing" }
        guard entry.isUndoable else {
            if entry.undone { return "Already undone" }
            if !entry.success { return "Cannot undo a failed action" }
            return "Undo window expired (>\(Int(AuditLog.undoWindowSeconds))s)"
        }
        guard let snapshot = entry.snapshotJSON, let dict = decodeSnapshot(snapshot) else {
            return "Cannot undo — snapshot missing"
        }

        switch entry.tool {
        case "dismissTask":
            guard let idStr = dict["taskId"] as? String, let uuid = UUID(uuidString: idStr),
                  let task = fetchOne(TaskItem.self, id: uuid, in: ctx) else {
                return "Cannot undo — task gone"
            }
            task.isDismissed = (dict["wasIsDismissed"] as? Bool) ?? false
            task.status = (dict["wasStatus"] as? String) ?? "committed"
            task.updatedAt = Date()

        case "completeTask":
            guard let idStr = dict["taskId"] as? String, let uuid = UUID(uuidString: idStr),
                  let task = fetchOne(TaskItem.self, id: uuid, in: ctx) else {
                return "Cannot undo — task gone"
            }
            task.completed = (dict["wasCompleted"] as? Bool) ?? false
            // wasCompletedAt may be NSNull or ISO string.
            if let raw = dict["wasCompletedAt"] as? String {
                task.completedAt = ISO8601DateFormatter().date(from: raw)
            } else {
                task.completedAt = nil
            }
            task.updatedAt = Date()

        case "dismissMemory":
            guard let idStr = dict["memoryId"] as? String, let uuid = UUID(uuidString: idStr),
                  let mem = fetchOne(UserMemory.self, id: uuid, in: ctx) else {
                return "Cannot undo — memory gone"
            }
            mem.isDismissed = (dict["wasIsDismissed"] as? Bool) ?? false
            mem.updatedAt = Date()

        case "updateGoalProgress":
            guard let idStr = dict["goalId"] as? String, let uuid = UUID(uuidString: idStr),
                  let goal = fetchOne(Goal.self, id: uuid, in: ctx) else {
                return "Cannot undo — goal gone"
            }
            if let prev = dict["previousValue"] as? Double {
                goal.currentValue = prev
            } else if let prevNum = dict["previousValue"] as? NSNumber {
                goal.currentValue = prevNum.doubleValue
            }
            goal.updatedAt = Date()

        case "addTask":
            guard let idStr = dict["createdTaskId"] as? String, let uuid = UUID(uuidString: idStr),
                  let task = fetchOne(TaskItem.self, id: uuid, in: ctx) else {
                return "Cannot undo — task gone"
            }
            task.isDismissed = true
            task.status = "dismissed"
            task.updatedAt = Date()

        case "addMemory":
            guard let idStr = dict["createdMemoryId"] as? String, let uuid = UUID(uuidString: idStr),
                  let mem = fetchOne(UserMemory.self, id: uuid, in: ctx) else {
                return "Cannot undo — memory gone"
            }
            mem.isDismissed = true
            mem.updatedAt = Date()

        default:
            return "Cannot undo — unknown tool"
        }

        entry.undone = true
        // SB-2: propagate a save failure instead of falsely reporting "Reverted".
        // (External-surface re-sync after undo — Obsidian/MCP — is SB-3.)
        do {
            try ctx.save()
        } catch {
            return "Couldn't save the undo — nothing was reverted (\(error.localizedDescription))"
        }
        return "Reverted: \(entry.resultSummary)"
    }

    /// Look up the most recent audit row tied to a chat message (for Undo button binding).
    func auditEntry(forChatMessage messageId: UUID) -> AuditLog? {
        guard let container = modelContainer else { return nil }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<AuditLog>(
            predicate: #Predicate { $0.chatMessageId == messageId },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        desc.fetchLimit = 1
        return (try? ctx.fetch(desc))?.first
    }

    // MARK: - Audit + snapshot helpers

    @discardableResult
    private func writeAudit(tool: String, args: [String: String], summary: String,
                            success: Bool, snapshotJSON: String?,
                            chatMessageId: UUID?) -> UUID? {
        guard let container = modelContainer else { return nil }
        let ctx = ModelContext(container)
        let argsJSON = (try? String(data: JSONEncoder().encode(args), encoding: .utf8)) ?? "{}"
        let entry = AuditLog(
            tool: tool,
            argsJSON: argsJSON,
            resultSummary: summary,
            success: success,
            snapshotJSON: snapshotJSON,
            chatMessageId: chatMessageId
        )
        ctx.insert(entry)
        try? ctx.save()
        return entry.id
    }

    private func encodeSnapshot(_ dict: [String: Any]) -> String? {
        // JSONSerialization tolerates the heterogeneous values we pass (Bool, String, Double, NSNull).
        // Replace `Any` NSNull stand-ins with explicit JSONNull when needed.
        let cleaned = dict.mapValues { v -> Any in
            if v is NSNull { return NSNull() }
            return v
        }
        guard let data = try? JSONSerialization.data(withJSONObject: cleaned, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeSnapshot(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // MARK: - Tool schemas (ITER-017 native tool-use)

    /// JSON-schema array describing every tool the chat LLM may call. Sent verbatim
    /// to `/api/pro/chat-with-tools` as the `tools` field. Format matches OpenAI
    /// `function calling` (Groq follows the same convention).
    ///
    /// Keep schemas TIGHT — Groq's `tool_choice: "auto"` decision is sensitive to
    /// description quality. Each `description` answers "when would I call this?"
    /// in plain English so the model picks correctly.
    static let toolSchemas: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "dismissTask",
                "description": "Soft-delete a task from the user's main list. Use when the user explicitly asks to remove / dismiss / forget a task (e.g. \"убери задачу X\", \"delete the X task\").",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "UUID of the task as printed in the <my_tasks> or <waiting_on> blocks. Must come verbatim from context — never invent.",
                        ],
                    ],
                    "required": ["id"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "completeTask",
                "description": "Mark a task as done. Use when user reports completion: \"сделал X\", \"I finished X\", \"mark X as done\".",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Task UUID from context."],
                    ],
                    "required": ["id"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "dismissMemory",
                "description": "Delete a stored fact about the user. Use when user says \"forget that Y\" / \"забудь что Y\".",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Memory UUID from <user_facts> block."],
                    ],
                    "required": ["id"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "updateGoalProgress",
                "description": "Adjust the progress of a tracked goal. boolean goals: delta>=1 → done today, <=-1 → reset. scale (1-10): delta clamps. numeric: delta is the counter change.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Goal UUID from <active_goals> block."],
                        "delta": ["type": "integer", "description": "Signed change to apply. +1 / -1 / +5 / -3 etc."],
                    ],
                    "required": ["id", "delta"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "addTask",
                "description": "Create a new action item on the user's list. Use when user explicitly dictates a to-do (e.g. \"add task: ship deploy\", \"напомни мне ответить Майку\").",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "description": ["type": "string", "description": "≤15 words, starts with verb, no time references (those go in dueAt)."],
                        "dueAt": ["type": "string", "description": "ISO-8601 UTC with Z suffix. Omit or null when no deadline."],
                        "assignee": ["type": "string", "description": "Person owing the user the result (waiting-on). Null for the user's own task."],
                    ],
                    "required": ["description"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "addMemory",
                "description": "Store a durable fact about the user. Use when user explicitly asks to remember something (\"remember that I work at ChatApp\", \"запомни что Y\").",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "content": ["type": "string", "description": "The fact, ≤15 words."],
                        "category": ["type": "string", "enum": ["system", "interesting"], "description": "system = about the user; interesting = wisdom/quote."],
                    ],
                    "required": ["content"],
                ],
            ],
        ],
        // ── ITER-017 v3 — Read-only search tools ─────────────────────────────
        // Auto-executed without user confirm (no mutation, safe). Used by the LLM
        // when it needs to look up an id before calling a mutation tool. Example
        // chain: searchTasks(query="Mike") → dismissTask(id=<found>).
        [
            "type": "function",
            "function": [
                "name": "searchTasks",
                "description": "Find tasks matching a free-text query. Returns top matches with id, description, assignee, dueAt. Use this before calling dismissTask / completeTask when you need to look up the right id and the user didn't quote it directly.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Free-text query (person name, project, action verb, etc.)."],
                        "limit": ["type": "integer", "description": "Max results to return. Default 10, max 30."],
                    ],
                    "required": ["query"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "searchMemories",
                "description": "Find stored user_facts matching a free-text query. Returns top matches with id, headline, content. Use before dismissMemory.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Free-text query."],
                        "limit": ["type": "integer", "description": "Max results. Default 10, max 30."],
                    ],
                    "required": ["query"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "searchConversations",
                "description": "Find past conversations (meetings/dictations) by topic. Returns id, title, overview, startedAt. Use when user references a call without saying its title (e.g. \"тот созвон где мы решили про цены\").",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Free-text query."],
                        "limit": ["type": "integer", "description": "Max results. Default 5, max 15."],
                    ],
                    "required": ["query"],
                ],
            ],
        ],
        // ── ITER-053.4 — screen-history search ────────────────────────────────
        [
            "type": "function",
            "function": [
                "name": "searchScreenHistory",
                "description": "Search what was ON THE USER'S SCREEN: the activity timeline plus raw captured screen text (messages they read, pages, code). Use for \"что я делал по X\", \"что мне писал <человек>\", \"где я видел ту ссылку/цифру\". Returns activities (what the user was doing, with time+app) and screen_texts (verbatim snippets with time+app+window).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Free-text query — topic, person, project, phrase."],
                        "days": ["type": "integer", "description": "How many days back to search. Default 7, max 90."],
                        "limit": ["type": "integer", "description": "Max results per group. Default 8, max 20."],
                    ],
                    "required": ["query"],
                ],
            ],
        ],
    ]

    /// Set of tool names that don't mutate state. Read-only tools auto-execute
    /// without user confirm, bypass rate-limit, and aren't audited (no snapshot
    /// to undo — they only read). Keep this list narrow — when in doubt, treat
    /// as mutation.
    static let readOnlyTools: Set<String> = [
        "searchTasks", "searchMemories", "searchConversations", "searchScreenHistory",
    ]

    static func isReadOnly(_ tool: String) -> Bool {
        readOnlyTools.contains(tool)
    }

    // MARK: - Parser (LLM output → ToolCall)

    /// ITER-017 — Parse the FIRST element from a native `tool_calls` array
    /// (OpenAI / Groq function-calling format). Returns nil if array is empty
    /// or the entry is malformed. Captures native `id` so the multi-step loop
    /// can correlate the matching `tool_result` reply.
    static func parseNativeToolCall(from toolCalls: [[String: Any]]?) -> ToolCall? {
        guard let arr = toolCalls, let first = arr.first else { return nil }
        let id = first["id"] as? String
        guard let function = first["function"] as? [String: Any],
              let name = function["name"] as? String, !name.isEmpty else { return nil }
        // `arguments` is a JSON-encoded STRING in OpenAI/Groq response. Parse it.
        var argMap: [String: String] = [:]
        if let argsStr = function["arguments"] as? String, !argsStr.isEmpty,
           let data = argsStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in obj {
                if let s = v as? String { argMap[k] = s }
                else if let n = v as? NSNumber { argMap[k] = n.stringValue }
                else if v is NSNull { /* skip */ }
                else { argMap[k] = String(describing: v) }
            }
        }
        return ToolCall(id: id, tool: name, args: argMap)
    }

    /// Set of all callable tool names — used by the drift-tolerant parser
    /// fallback below. Keep in sync with `executeTool(_:)` switch arms.
    private static let allKnownTools: Set<String> = [
        "dismissTask", "completeTask", "dismissMemory", "updateGoalProgress",
        "addTask", "addMemory",
        "searchTasks", "searchMemories", "searchConversations", "searchScreenHistory",
    ]

    /// Extract the FIRST `<tool_call>{...}</tool_call>` block from text.
    /// Returns nil when no valid block present — chat then treats the output as plain text.
    /// Tolerant to whitespace + code fences around the JSON. Also tolerant to
    /// the LLM-drift pattern `<toolName>{args}</toolName>` (Cerebras Qwen and
    /// some Groq models emit this instead of the spec'd `<tool_call>` wrapper).
    static func parseToolCall(from text: String) -> ToolCall? {
        // Drift fallback FIRST — if the model used `<searchTasks>{...}</searchTasks>`
        // (etc) format, transform it into a regular ToolCall before the canonical
        // parser would have failed and bubbled raw XML to the UI.
        for tool in allKnownTools {
            let pattern = "<\(tool)>([\\s\\S]*?)</\(tool)>"
            guard let r = text.range(of: pattern, options: .regularExpression) else { continue }
            var payload = String(text[r])
            payload = payload
                .replacingOccurrences(of: "<\(tool)>", with: "")
                .replacingOccurrences(of: "</\(tool)>", with: "")
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = payload.data(using: .utf8),
                  let argsObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            var normArgs: [String: String] = [:]
            for (k, v) in argsObj {
                if let s = v as? String { normArgs[k] = s }
                else if let n = v as? NSNumber { normArgs[k] = n.stringValue }
                else if v is NSNull { /* skip */ }
                else { normArgs[k] = String(describing: v) }
            }
            NSLog("[ChatTools] drift-format tool call detected: <%@> — recovered", tool)
            return ToolCall(id: nil, tool: tool, args: normArgs)
        }

        guard let range = text.range(of: #"<tool_call>([\s\S]*?)</tool_call>"#, options: .regularExpression) else {
            return nil
        }
        var payload = String(text[range])
        payload = payload.replacingOccurrences(of: "<tool_call>", with: "")
                         .replacingOccurrences(of: "</tool_call>", with: "")
                         .replacingOccurrences(of: "```json", with: "")
                         .replacingOccurrences(of: "```", with: "")
                         .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = obj["tool"] as? String, !tool.isEmpty else {
            return nil
        }
        // Normalize args → [String: String]. Accept non-string values (numbers) by casting to string.
        var normArgs: [String: String] = [:]
        if let a = obj["args"] as? [String: Any] {
            for (k, v) in a {
                if let s = v as? String { normArgs[k] = s }
                else if let n = v as? NSNumber { normArgs[k] = n.stringValue }
                else if v is NSNull { /* skip */ }
                else { normArgs[k] = String(describing: v) }
            }
        }
        // Legacy regex path has no native id — multi-step loop disabled for these.
        return ToolCall(id: nil, tool: tool, args: normArgs)
    }

    // MARK: - Internal

    private func fetchOne<T: PersistentModel>(_ type: T.Type, id: UUID, in ctx: ModelContext) -> T? where T: Identifiable {
        // SwiftData predicate requires T.id compare; use runtime filter since
        // AnyPersistentModel's id type varies.
        //
        // 2026-05-29 FIX: removed `fetchLimit = 300`. With >300 rows (a real
        // account had 625 tasks) the target — even one the user can SEE in the
        // <my_tasks> context block — could fall outside the arbitrary, unsorted
        // 300-row window, so dismissTask / completeTask / updateGoalProgress
        // returned "not found" for valid items. That was the user-reported
        // "MetaChat can't delete tasks". Fetch-all + filter is O(n) but n is
        // tiny for a per-tool-call lookup and is now correct at any task count.
        let all = (try? ctx.fetch(FetchDescriptor<T>())) ?? []
        return all.first { ($0.id as? UUID) == id }
    }
}
