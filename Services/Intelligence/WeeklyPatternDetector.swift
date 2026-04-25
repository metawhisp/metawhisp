import Foundation
import SwiftData
import UserNotifications

/// Weekly cross-conversation pattern detector (ITER-022 G5).
///
/// Surfaces what no single meeting / dictation can show: themes that repeat
/// across conversations, people that recur, stuck loops (discussed multiple
/// times with no decision extracted), cross-context insights.
///
/// Distinct from:
/// - `DailySummaryService` — single-day recap, ≠ pattern across days
/// - `StructuredGenerator` — single conversation, ≠ cross-conversation
/// - `AdviceService` — opportunistic single insight, ≠ batched weekly digest
///
/// Lifecycle:
/// - Sunday at user-configured hour (default 18:00) → in-process scheduler
///   ticks every 5 min, fires when wall-clock crosses the trigger AND
///   no digest exists for THIS week yet.
/// - Manual `generateNow()` from Insights tab.
/// - Anti-spam: skips if last digest <6 days old (idempotent on overlap).
///
/// spec://iterations/ITER-022-G5-weekly-patterns
@MainActor
final class WeeklyPatternDetector: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?
    @Published var lastGenerationAt: Date?

    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?
    private var timerTask: Task<Void, Never>?

    /// Default analysis window — last 7 days from `now`.
    private let windowDays: Int = 7
    /// Don't fire if a digest exists newer than this.
    private let antiSpamWindowDays: Int = 6
    /// Min conversations to bother running. Below this → skip + write empty digest.
    private let minConversationsToRun: Int = 3

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Scheduler

    func startScheduler() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            await self?.tick()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300)) // 5 min
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
        NSLog("[Pattern] ✅ Scheduler started")
    }

    func stopScheduler() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func tick() async {
        guard settings.weeklyPatternsEnabled else { return }
        let now = Date()
        let cal = Calendar.current
        // Fire only on Sunday (1 in Gregorian Calendar) when wall-clock >= configured hour.
        let weekday = cal.component(.weekday, from: now)
        guard weekday == 1 else { return }
        let hour = cal.component(.hour, from: now)
        guard hour >= max(0, min(23, settings.weeklyPatternsHour)) else { return }
        // Anti-spam: skip if a digest within the last 6 days exists.
        if let last = mostRecentDigest(), Date().timeIntervalSince(last.createdAt) < Double(antiSpamWindowDays * 86400) {
            return
        }
        await generate(postNotification: true)
    }

    // MARK: - Manual + core generation

    @discardableResult
    func generateNow() async -> PatternDigest? {
        await generate(postNotification: false)
    }

    @discardableResult
    private func generate(postNotification: Bool) async -> PatternDigest? {
        guard !isRunning else { return nil }
        guard hasLLMAccess else {
            NSLog("[Pattern] No LLM access — skipping")
            return nil
        }
        guard let container = modelContainer else { return nil }

        isRunning = true
        defer {
            isRunning = false
            lastGenerationAt = Date()
        }

        let ctx = ModelContext(container)
        let now = Date()
        let cal = Calendar.current
        let windowStart = cal.date(byAdding: .day, value: -windowDays, to: cal.startOfDay(for: now)) ?? now

        // ── Gather window data ───────────────────────────────────────────────
        let convs = fetchConversations(ctx: ctx, from: windowStart)
        let memories = fetchMemories(ctx: ctx, from: windowStart)
        let tasks = fetchTasks(ctx: ctx, from: windowStart)

        guard convs.count >= minConversationsToRun else {
            NSLog("[Pattern] Quiet window (%d conv) — writing empty digest", convs.count)
            let empty = PatternDigest(
                weekStartDate: windowStart,
                windowDays: windowDays,
                conversationsAnalyzed: convs.count
            )
            ctx.insert(empty)
            try? ctx.save()
            if postNotification { postQuietWeekNotification() }
            return empty
        }

        guard LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey else {
            NSLog("[Pattern] Non-Pro — skipping (cloud-only)")
            return nil
        }

        // ── Build prompt context ─────────────────────────────────────────────
        let userPrompt = buildPrompt(conversations: convs, memories: memories, tasks: tasks, windowDays: windowDays)

        // ── LLM call ─────────────────────────────────────────────────────────
        let response: String
        do {
            response = try await callProProxy(system: Self.systemPrompt, user: userPrompt, licenseKey: licenseKey)
        } catch {
            lastError = error.localizedDescription
            NSLog("[Pattern] ❌ LLM call failed: %@", error.localizedDescription)
            return nil
        }

        // ── Parse + persist ──────────────────────────────────────────────────
        let parsed = parseResponse(response)
        let digest = PatternDigest(
            weekStartDate: windowStart,
            windowDays: windowDays,
            conversationsAnalyzed: convs.count
        )
        digest.themesJSON     = encodeArray(parsed.themes)
        digest.peopleJSON     = encodeArray(parsed.people)
        digest.stuckLoopsJSON = encodeArray(parsed.stuckLoops)
        digest.insightsJSON   = encodeArray(parsed.insights)
        ctx.insert(digest)
        try? ctx.save()

        NSLog("[Pattern] ✅ Generated: themes=%d people=%d stuck=%d insights=%d (analysed %d conv)",
              parsed.themes.count, parsed.people.count, parsed.stuckLoops.count,
              parsed.insights.count, convs.count)

        if postNotification {
            postRecapNotification(digest: digest)
        }
        return digest
    }

    // MARK: - Prompt

    static let systemPrompt = """
    You analyse a USER's recent conversations + memories + tasks (past N days)
    and surface CROSS-CONVERSATION patterns that are invisible in any single
    meeting. The user reads ONE digest per week — make every line carry weight.

    REQUIRED OUTPUT (return ONLY this JSON, no markdown fences):
    {
      "themes":      ["1-5 strings, recurring topics across ≥3 conversations"],
      "people":      ["1-5 strings, names recurring across multiple convs"],
      "stuck_loops": ["1-3 strings, themes discussed ≥3 times with NO decision extracted"],
      "insights":    ["1-3 strings, cross-context observations the user wouldn't see"]
    }

    THEMES:
    - Topics mentioned in ≥3 distinct conversations.
    - Format: short noun phrase. ≤14 words.
    - GOOD: "Pricing tier discussion (5 convs, no decision)", "DRUGENERATOR launch prep"
    - BAD: "Various meetings about work" (vague), "Discussed a lot" (not a theme)

    PEOPLE:
    - Names appearing in ≥2 conversations. Preserved as spoken (Russian / English).
    - Format: "Pasha (5 convs · co-working on Overchat)" — name + role/context if clear.
    - Skip the user themselves.

    STUCK_LOOPS:
    - Themes that came up ≥3 times AND no decision shows in any conv's overview/decisions.
    - Format: "What was discussed + why it's stuck"
    - GOOD: "Pricing model — debated 4 times, no agreement on free tier"
    - BAD: "Everything is stuck" (lazy)
    - Empty if nothing fits — DON'T pad.

    INSIGHTS:
    - Cross-context observations the user wouldn't see in single conv.
    - GOOD: "Mike appears in 3 different project contexts — possible coordination role?"
            "Same pricing blocker across Overchat AND Atomic Bot — common cause?"
            "5 meetings tagged 'work', 0 decisions — agendas need pre-work"
    - BAD: "User had many meetings" (counting, not insight)
    - Empty if nothing rises.

    GENERAL RULES:
    - Each item ≤14 words, no trailing periods, no leading bullets.
    - Use specific named subjects (people, projects). NEVER "the team" / "the project".
    - Prefer empty array over filler. Empty section simply doesn't render.
    - Respond in the user's content language (mostly ru/en).

    CRITICAL: respond with ONLY the JSON object. No preamble.
    """

    private func buildPrompt(conversations: [Conversation], memories: [UserMemory],
                              tasks: [TaskItem], windowDays: Int) -> String {
        var parts: [String] = []
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        df.locale = Locale(identifier: "en_US_POSIX")
        parts.append("Window: past \(windowDays) days. \(conversations.count) conversations, \(memories.count) memories, \(tasks.count) tasks.")
        parts.append("")

        parts.append("CONVERSATIONS (title · category · project · overview):")
        for c in conversations.prefix(30) {
            let title = c.title ?? "(untitled)"
            let cat = c.category ?? "—"
            let proj = c.primaryProject ?? "—"
            let ov = (c.overview ?? "").prefix(200)
            parts.append("- [\(df.string(from: c.startedAt))] \(title) · \(cat) · proj=\(proj)")
            if !ov.isEmpty { parts.append("    \(ov)") }
            // Include stored decisions if any (tells LLM what's NOT stuck).
            if !c.decisions.isEmpty {
                parts.append("    decisions: \(c.decisions.joined(separator: " | "))")
            }
        }
        parts.append("")

        if !memories.isEmpty {
            parts.append("MEMORIES (durable facts captured):")
            for m in memories.prefix(30) {
                if let h = m.headline, !h.isEmpty {
                    parts.append("- [\(h)] \(m.content.prefix(120))")
                } else {
                    parts.append("- \(m.content.prefix(140))")
                }
            }
            parts.append("")
        }

        if !tasks.isEmpty {
            parts.append("TASKS (open):")
            for t in tasks.prefix(30) {
                let assignee = t.assignee.map { " (waiting on \($0))" } ?? ""
                parts.append("- \(t.taskDescription)\(assignee)")
            }
            parts.append("")
        }

        let combined = parts.joined(separator: "\n")
        return combined.count > 16000 ? String(combined.prefix(16000)) : combined
    }

    // MARK: - Parse

    private struct ParsedDigest {
        let themes: [String]
        let people: [String]
        let stuckLoops: [String]
        let insights: [String]
    }

    private func parseResponse(_ response: String) -> ParsedDigest {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else {
            return ParsedDigest(themes: [], people: [], stuckLoops: [], insights: [])
        }
        struct Raw: Decodable {
            let themes: [String]?
            let people: [String]?
            let stuckLoops: [String]?
            let insights: [String]?
            enum CodingKeys: String, CodingKey {
                case themes, people, insights
                case stuckLoops = "stuck_loops"
            }
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            NSLog("[Pattern] ⚠️ Parse failed — raw response prefix: %@",
                  String(extracted.prefix(200)))
            return ParsedDigest(themes: [], people: [], stuckLoops: [], insights: [])
        }
        let clean: ([String]?) -> [String] = {
            ($0 ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                       .filter { !$0.isEmpty }
        }
        return ParsedDigest(
            themes: clean(raw.themes),
            people: clean(raw.people),
            stuckLoops: clean(raw.stuckLoops),
            insights: clean(raw.insights)
        )
    }

    private func extractJSONObject(from text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let start = stripped.firstIndex(of: "{") else {
            return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var depth = 0
        var inString = false
        var escape = false
        for idx in stripped[start...].indices {
            let ch = stripped[idx]
            if escape { escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(stripped[start...idx]) }
            }
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Notifications

    private func postRecapNotification(digest: PatternDigest) {
        let content = UNMutableNotificationContent()
        content.title = "Weekly patterns ready"
        var lines: [String] = []
        if !digest.themes.isEmpty { lines.append("Themes: \(digest.themes.count)") }
        if !digest.stuckLoops.isEmpty { lines.append("Stuck: \(digest.stuckLoops.count)") }
        if !digest.insights.isEmpty { lines.append("Insights: \(digest.insights.count)") }
        content.body = lines.isEmpty
            ? "Quiet week — patterns recap saved."
            : lines.joined(separator: " · ") + " — open Insights"
        content.sound = .default
        content.userInfo = ["target": "tasks"]  // route via existing handler

        let req = UNNotificationRequest(
            identifier: "com.metawhisp.pattern.\(digest.id.uuidString)",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { err in
            if let err {
                NSLog("[Pattern] ❌ Notification failed: %@", err.localizedDescription)
            }
        }
    }

    private func postQuietWeekNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Quiet week"
        content.body = "Fewer than \(minConversationsToRun) conversations — no patterns to analyse."
        content.sound = nil
        let req = UNNotificationRequest(
            identifier: "com.metawhisp.pattern.quiet.\(UUID().uuidString)",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    // MARK: - Data fetch

    private func fetchConversations(ctx: ModelContext, from: Date) -> [Conversation] {
        var desc = FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.startedAt >= from },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        desc.fetchLimit = 100
        return (try? ctx.fetch(desc)) ?? []
    }

    private func fetchMemories(ctx: ModelContext, from: Date) -> [UserMemory] {
        var desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed && $0.createdAt >= from },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        desc.fetchLimit = 60
        return (try? ctx.fetch(desc)) ?? []
    }

    private func fetchTasks(ctx: ModelContext, from: Date) -> [TaskItem] {
        let desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed && !$0.completed && $0.createdAt >= from },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return ((try? ctx.fetch(desc)) ?? [])
            .filter { $0.status != "staged" && $0.status != "dismissed" }
    }

    private func mostRecentDigest() -> PatternDigest? {
        guard let container = modelContainer else { return nil }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<PatternDigest>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = 1
        return (try? ctx.fetch(desc))?.first
    }

    private func encodeArray(_ items: [String]) -> String? {
        guard !items.isEmpty else { return nil }
        return (try? String(data: JSONEncoder().encode(items), encoding: .utf8))
    }

    // MARK: - Pro proxy

    private func callProProxy(system: String, user: String, licenseKey: String) async throws -> String {
        let url = URL(string: "https://api.metawhisp.com/api/pro/advice")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = ["system": system, "user": user]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Pattern", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty || LicenseService.shared.isPro
    }
}
