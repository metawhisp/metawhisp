import Foundation
import SwiftData

/// ITER-057.2 — hourly LLM re-ranking of staged task candidates («умный порядок»).
///
/// Reference cadences: check every 300s (startup delay 90s), full re-rank when
/// ≥3600s elapsed AND ≥2 staged candidates. The LLM orders the top-30 staged by
/// the user's goals / urgency / actionability; positions land in
/// `TaskItem.relevanceScore` (1 = most important, nil = unranked → sorts last).
/// The promotion loop (ITER-057.1) then promotes by score instead of recency —
/// this is what stops dev-screen junk from beating real commitments.
///
/// Failure policy: LLM down / bad JSON → keep the current order, log, never
/// block promotion.
@MainActor
final class TaskPrioritizationService: ObservableObject {
    static let shared = TaskPrioritizationService()

    /// Reference numbers (ITER-057 §4).
    static let checkInterval: TimeInterval = 300
    static let rerankInterval: TimeInterval = 3600
    static let startupDelay: TimeInterval = 90
    static let minStagedForRerank = 2
    static let stagedLimit = 30

    static let llmTier: LLMTier = .medium
    static let llmServiceId: String = "TaskPrioritization"

    private var modelContainer: ModelContainer?
    private var timer: Timer?
    private(set) var lastRerankAt: Date?
    private var isRunning = false

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Call once at launch. First check after `startupDelay`, then every
    /// `checkInterval`; an actual re-rank only when `shouldRerank` says so.
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in await TaskPrioritizationService.shared.checkAndRerank() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.startupDelay))
            await self.checkAndRerank()
        }
    }

    /// Pure guard, pinned by tests: rerank only when the interval elapsed and
    /// there's something to order.
    nonisolated static func shouldRerank(lastRerankAt: Date?, stagedCount: Int, now: Date) -> Bool {
        guard stagedCount >= minStagedForRerank else { return false }
        guard let last = lastRerankAt else { return true }
        return now.timeIntervalSince(last) >= rerankInterval
    }

    func checkAndRerank(now: Date = Date()) async {
        guard !isRunning else { return }
        guard AppSettings.shared.tasksEnabled else { return }
        guard StoreHealthSignal.shared.isHealthy, let container = modelContainer else { return }
        guard hasLLMAccess else { return }
        isRunning = true
        defer { isRunning = false }

        let ctx = ModelContext(container)
        var stagedDesc = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> {
                $0.status == "staged" && !$0.isDismissed && !$0.completed
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        stagedDesc.fetchLimit = Self.stagedLimit
        let staged = (try? ctx.fetch(stagedDesc)) ?? []
        guard Self.shouldRerank(lastRerankAt: lastRerankAt, stagedCount: staged.count, now: now) else { return }
        // Stamp the ATTEMPT, not only success: a persistently failing LLM/parse
        // must retry hourly, not on every 300s check tick — otherwise a flaky
        // local model turns 1 call/hour into 12 (review finding).
        lastRerankAt = now

        let goals = fetchGoals(in: ctx)
        let completed = fetchDescriptions(in: ctx, completed: true, limit: 10)
        let dismissed = fetchDismissedDescriptions(in: ctx, limit: 10)
        let prompt = Self.buildPrompt(
            goals: goals,
            staged: staged.map { (id: $0.id, description: $0.taskDescription, dueAt: $0.dueAt, createdAt: $0.createdAt) },
            completed: completed,
            dismissed: dismissed
        )

        do {
            let response: String
            if LocalLLMService.shared.isReady {
                response = try await LocalLLMService.shared.completeBlocking(
                    system: Self.systemPrompt, user: prompt,
                    maxUserChars: 6000, maxTokens: 1024)
            } else if LicenseService.shared.isPro, let key = LicenseService.shared.licenseKey {
                response = try await callProProxy(system: Self.systemPrompt, user: prompt, licenseKey: key)
            } else {
                let apiKey = AppSettings.shared.activeAPIKey
                guard !apiKey.isEmpty else { return }
                let provider = LLMProvider(rawValue: AppSettings.shared.llmProvider) ?? .openai
                response = try await OpenAIService().complete(
                    system: Self.systemPrompt, user: prompt, apiKey: apiKey, provider: provider)
            }

            guard let positions = Self.parseRerank(response) else {
                // Response head in the log — the 2026-07-17 gpt-oss incident
                // (model returned chain-of-thought prose instead of JSON) was
                // undebuggable without it.
                NSLog("[TaskPrioritization] ⚠️ Parse failed — keeping current order. Response head: %@",
                      String(response.prefix(200)))
                return
            }
            // Re-fetch: the LLM await took up to 30s — tasks dismissed/completed/
            // hard-deleted meanwhile must not be written back from stale
            // snapshots (review finding). Positions apply only to rows that are
            // still live staged candidates.
            let stagedIds = Set(staged.map(\.id))
            let freshCtx = ModelContext(container)
            let freshDesc = FetchDescriptor<TaskItem>(
                predicate: #Predicate<TaskItem> {
                    $0.status == "staged" && !$0.isDismissed && !$0.completed
                })
            let fresh = ((try? freshCtx.fetch(freshDesc)) ?? []).filter { stagedIds.contains($0.id) }
            let applied = Self.apply(positions: positions, to: fresh)
            guard applied > 0 else {
                NSLog("[TaskPrioritization] ⚠️ No known ids in rerank response — keeping current order")
                return
            }
            do {
                // Bulk internal annotation (ranking metadata, not user-facing
                // content) — a single save + one snapshot instead of 30 per-item
                // MutationService hook storms; Obsidian export doesn't carry
                // relevanceScore, so there's nothing to re-export.
                try freshCtx.save()
                MCPSnapshotService.shared.snapshotNow()
                NSLog("[TaskPrioritization] ✅ Re-ranked %d staged candidates", applied)
            } catch {
                NSLog("[TaskPrioritization] ⚠️ Save failed: %@", error.localizedDescription)
            }
        } catch {
            NSLog("[TaskPrioritization] ⚠️ LLM failed — keeping current order: %@", error.localizedDescription)
        }
    }

    // MARK: - Pure helpers (tested)

    struct RankedPosition: Decodable, Equatable {
        let id: String
        let new_position: Int

        init(id: String, new_position: Int) {
            self.id = id
            self.new_position = new_position
        }
    }
    /// Lossy element wrapper — one malformed entry (string position, missing
    /// key) must not fail the whole rerank (same pattern as ReactionJSON).
    private struct LossyPosition: Decodable {
        let value: RankedPosition?
        init(from decoder: Decoder) throws {
            value = try? RankedPosition(from: decoder)
        }
    }
    private struct RerankJSON: Decodable {
        let reranked: [LossyPosition]
    }

    /// Parse `{"reranked":[{"id":"<uuid>","new_position":1},…]}` from raw LLM text.
    nonisolated static func parseRerank(_ response: String) -> [RankedPosition]? {
        let stripped = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let start = stripped.firstIndex(of: "{"),
              let end = stripped.lastIndex(of: "}"),
              start <= end,
              let data = String(stripped[start...end]).data(using: .utf8)
        else { return nil }
        guard let parsed = try? JSONDecoder().decode(RerankJSON.self, from: data) else { return nil }
        let positions = parsed.reranked.compactMap(\.value)
        return positions.isEmpty ? nil : positions
    }

    /// Write positions into matching tasks. Unknown/duplicate ids are ignored;
    /// returns how many tasks were updated. Field write only — caller saves.
    /// Deliberately does NOT touch `updatedAt`: ranking is internal metadata,
    /// and bumping it would reorder every updatedAt-sorted list (dismissed
    /// negatives, completed context) on each hourly pass (review finding).
    @discardableResult
    static func apply(positions: [RankedPosition], to tasks: [TaskItem]) -> Int {
        let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var applied = 0
        for pos in positions {
            guard let id = UUID(uuidString: pos.id), let task = byId[id],
                  !seen.contains(id), pos.new_position >= 1 else { continue }
            seen.insert(id)
            task.relevanceScore = pos.new_position
            applied += 1
        }
        return applied
    }

    nonisolated static func buildPrompt(
        goals: [String],
        staged: [(id: UUID, description: String, dueAt: Date?, createdAt: Date)],
        completed: [String],
        dismissed: [String]
    ) -> String {
        let df = ISO8601DateFormatter()
        var parts: [String] = []
        if !goals.isEmpty {
            parts.append("USER GOALS:\n" + goals.map { "- \($0)" }.joined(separator: "\n"))
        }
        let stagedLines = staged.map { t -> String in
            let due = t.dueAt.map { " · due \(df.string(from: $0))" } ?? ""
            return "- \(t.id.uuidString) · created \(df.string(from: t.createdAt))\(due) · \(t.description)"
        }
        parts.append("STAGED CANDIDATES (order = newest first):\n" + stagedLines.joined(separator: "\n"))
        if !completed.isEmpty {
            parts.append("RECENTLY COMPLETED (what the user actually acts on):\n"
                + completed.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !dismissed.isEmpty {
            parts.append("RECENTLY DISMISSED (what the user rejects — rank similar ones LAST):\n"
                + dismissed.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    static let systemPrompt = """
    You re-rank the user's staged task candidates (AI-extracted from screen activity,
    not yet reviewed). Produce the order in which they should surface.

    Criteria, in priority order:
    1. The user's goals — tasks advancing a stated goal rank first.
    2. Urgency — explicit due dates, time-sensitive requests.
    3. Actionability — a named person + concrete deliverable beats vague intent.
    4. Real importance — commitments to other people beat self-generated ideas.

    Most AI-extracted candidates are noise. Sink vague, stale, or dismissed-like
    items to the bottom. Use RECENTLY COMPLETED as a signal of what the user values
    and RECENTLY DISMISSED as what they reject.

    Return ONLY JSON, no prose:
    {"reranked":[{"id":"<uuid>","new_position":1}, ...]}
    new_position 1 = most important. Include EVERY listed candidate id exactly once.
    """

    // MARK: - Fetches

    private func fetchGoals(in ctx: ModelContext) -> [String] {
        var desc = FetchDescriptor<Goal>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        desc.fetchLimit = 10
        return ((try? ctx.fetch(desc)) ?? []).map { goal in
            goal.goalDescription.map { "\(goal.title): \($0)" } ?? goal.title
        }
    }

    private func fetchDescriptions(in ctx: ModelContext, completed: Bool, limit: Int) -> [String] {
        var desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { $0.completed == completed && !$0.isDismissed },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        return ((try? ctx.fetch(desc)) ?? []).map { $0.taskDescription }
    }

    private func fetchDismissedDescriptions(in ctx: ModelContext, limit: Int) -> [String] {
        var desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { $0.isDismissed || $0.status == "dismissed" },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        return ((try? ctx.fetch(desc)) ?? []).map { $0.taskDescription }
    }

    private var hasLLMAccess: Bool {
        !AppSettings.shared.activeAPIKey.isEmpty
            || LicenseService.shared.isPro
            || LocalLLMService.shared.isReady
    }

    // MARK: - Pro proxy (same shape as RealtimeScreenReactor / ScreenExtractor)

    private func callProProxy(system: String, user: String, licenseKey: String) async throws -> String {
        let url = URL(string: "https://api.metawhisp.com/api/pro/advice")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body = LLMRequestBody.proAdviceBody(
            system: system, user: user,
            tier: Self.llmTier, serviceId: Self.llmServiceId
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ProcessingError.apiError("TaskPrioritization proxy HTTP \(http.statusCode)")
        }
        struct ProResponse: Decodable { let text: String }
        return try JSONDecoder().decode(ProResponse.self, from: data).text
    }
}
