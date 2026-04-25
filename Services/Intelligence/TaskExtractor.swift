import Foundation
import SwiftData

/// Extracts action items from a FULL closed Conversation — not per-transcript.
///
/// Triggered on conversation close (10-min silence for dictation, stop-button for meetings).
/// Runs once over the entire conversation (all HistoryItems concatenated) so the LLM can:
/// - See tasks resolved later in the same conversation → don't extract ("надо ответить" + "ответил")
/// - Apply USER-IS-SUBJECT filter across multi-fragment speech
/// - Avoid duplicates from fragmented dictation of the same topic
///
/// spec://BACKLOG#B1
@MainActor
final class TaskExtractor: ObservableObject {
    @Published var isRunning = false
    @Published var lastRun: Date?
    @Published var lastError: String?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private weak var screenContext: ScreenContextService?
    private var modelContainer: ModelContainer?

    /// 2-day dedup window for action items.
    private let dedupWindowDays: Int = 2

    func configure(screenContext: ScreenContextService, modelContainer: ModelContainer) {
        self.screenContext = screenContext
        self.modelContainer = modelContainer
    }

    /// Fire-and-forget extraction on the whole conversation. Called by ConversationGrouper
    /// after a conversation closes (dictation gap timeout or meeting stop).
    func triggerOnConversationClose(conversationId: UUID) {
        guard settings.tasksEnabled else { return }
        Task { [weak self] in
            await self?.extractFromConversation(conversationId: conversationId)
        }
    }

    /// Manual EXTRACT TASKS NOW button. Picks the most recent HistoryItem's conversation
    /// (whether closed or still in-progress) and extracts across its full fragment set.
    func extractOnce() async {
        guard hasLLMAccess else {
            NSLog("[TaskExtractor] No LLM access — skipping")
            return
        }
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<HistoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = 1
        guard let latest = (try? ctx.fetch(desc))?.first,
              let convId = latest.conversationId else {
            NSLog("[TaskExtractor] No recent conversation — skipping")
            return
        }
        await extractFromConversation(conversationId: convId)
    }

    /// Core extraction — collect all transcripts for the conversation, send as one block.
    private func extractFromConversation(conversationId: UUID) async {
        guard !isRunning else { return }
        guard hasLLMAccess else { return }

        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)

        // Fetch all HistoryItems belonging to this conversation, oldest first.
        var desc = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        desc.fetchLimit = 100
        let items = (try? ctx.fetch(desc)) ?? []
        let fragments = items
            .map { $0.displayText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !fragments.isEmpty else { return }
        let totalChars = fragments.reduce(0) { $0 + $1.count }
        guard totalChars >= 20 else { return }

        isRunning = true
        defer {
            isRunning = false
            lastRun = Date()
        }

        let existing = fetchExistingTasks(sinceDays: dedupWindowDays)
        let prompt = buildPrompt(fragments: fragments, existing: existing)

        // Use the last fragment's source app if available (proxy for what app user was in most).
        let sourceApp = items.last.flatMap { $0.source } ?? "conversation"

        do {
            let response: String
            if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                NSLog("[TaskExtractor] Extracting via Pro proxy (convo %@, %d fragments, %d chars)",
                      conversationId.uuidString.prefix(8) as CVarArg, fragments.count, totalChars)
                response = try await callProProxy(system: Self.systemPrompt, user: prompt, licenseKey: licenseKey)
            } else {
                let apiKey = settings.activeAPIKey
                guard !apiKey.isEmpty else {
                    NSLog("[TaskExtractor] No API key — skipping")
                    return
                }
                let provider = LLMProvider(rawValue: settings.llmProvider) ?? .openai
                response = try await llm.complete(
                    system: Self.systemPrompt,
                    user: prompt,
                    apiKey: apiKey,
                    provider: provider
                )
            }

            let tasks = parseResponse(response,
                                      sourceTranscriptId: items.last?.id,
                                      sourceApp: sourceApp,
                                      conversationId: conversationId)
            guard !tasks.isEmpty else {
                NSLog("[TaskExtractor] No new tasks from conversation %@", conversationId.uuidString.prefix(8) as CVarArg)
                return
            }

            for task in tasks {
                ctx.insert(task)
            }
            try? ctx.save()
            NSLog("[TaskExtractor] ✅ Extracted %d tasks from conversation %@",
                  tasks.count, conversationId.uuidString.prefix(8) as CVarArg)

            for task in tasks {
                NotificationService.shared.postNewTask(task, source: "Voice")
            }

            // Fire-and-forget embedding for semantic RAG (ITER-008).
            AppDelegate.shared?.embeddingService.embedTasksInBackground(tasks, in: ctx)
        } catch {
            lastError = error.localizedDescription
            NSLog("[TaskExtractor] ❌ Failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Prompt

    /// Action item extraction prompt — on-conversation-close pattern.
    /// Single-user desktop dictation: no speaker labels. Assignee filter done via
    /// linguistic "USER IS SUBJECT" rule.
    static let systemPrompt = """
    You are an expert action item extractor. Your sole purpose is to identify and extract actionable tasks from a voice-dictation conversation.

    CONVERSATION-WIDE CONTEXT (READ CAREFULLY):

    You receive a FULL conversation composed of multiple dictation fragments, ordered by time. Treat the fragments as ONE thought stream from the same single user:
    - If a task mentioned in an EARLIER fragment is reported as DONE in a LATER fragment → DO NOT EXTRACT.
      Example: Fragment 1 "надо ответить Майку" + Fragment 3 "ответил Майку" → SKIP (resolved).
    - If the user CHANGES THEIR MIND between fragments → honor the final decision.
      Example: Fragment 1 "завтра позвоню клиенту" + Fragment 2 "не буду звонить" → SKIP.
    - If the same intent is repeated in different words across fragments → extract AT MOST ONCE.
    - Only extract tasks that survive the FULL conversation.

    OWNERSHIP CLASSIFICATION (APPLY BEFORE EXTRACTION):

    This is a single-user dictation. The user is SPEAKING. Each action item belongs
    to one of three classes — handle each differently:

    (A) MY TASK — the USER themselves will do it.
        Examples: "Мне надо ответить Майку" / "I need to call Mike" / "I'll ship the deploy"
        → EXTRACT with assignee = null

    (B) WAITING-ON — the user explicitly DELEGATED to someone OR co-committed
        with someone where the OTHER person is the executor.
        Examples:
        - "Я попросил Васю задеплоить" / "I asked Vasya to deploy" → assignee = "Vasya"
        - "Мы решили что Паша подготовит отчёт" (user is in "мы" but Pasha does it) → assignee = "Pasha"
        - "Сказал Майку прислать драфт" / "Told Mike to send draft" → assignee = "Mike"
        → EXTRACT with assignee = <person name as spoken>

    (C) UNRELATED THIRD PARTY — someone else's action with NO link to user.
        Examples:
        - "У Паши созвон с Саней в среду" → SKIP (just a fact, not user's concern)
        - "Mike has a meeting with his team" → SKIP
        - "Pasha is shipping v2 today" → SKIP (no delegation, no co-commitment)
        → SKIP — do not extract

    Critical rule for (B) vs (C): EXTRACT as waiting-on ONLY when the user's voice
    explicitly delegated the work or the user is part of the deciding party. A bare
    mention of someone else's activity = (C) = SKIP. When ambiguous, prefer SKIP.

    Ambiguous cases — default to SKIP unless explicit:
    - "Созвон с Пашей в понедельник" → who calls? SKIP unless "у меня / I have / поставил".
    - "Паша прислал документы, нужно посмотреть" → who looks is ambiguous → SKIP unless clearly user said "посмотрю / I'll review".
    - "У меня созвон с Пашей в понедельник" → "у меня" = user → MY task.
    - "Просил Пашу прислать к среде" → explicit delegation → WAITING-ON, assignee = "Паша".

    Assignee field formatting:
    - Use the name AS SPOKEN in the transcript (don't normalize "Паша" → "Pavel").
    - Capitalize first letter ("Vasya" not "vasya").
    - Multi-person: pick the primary executor (the one who actually does it). If truly
      shared between two people, pick the first named.
    - Generic terms ("the team", "кто-то", "someone") → use "Team" or skip if vague.

    EXPLICIT TASK/REMINDER REQUESTS (HIGHEST PRIORITY — BYPASSES USER-IS-SUBJECT):

    When the user uses these patterns, ALWAYS extract (even for third parties — the user is asking to be reminded):
    - "Remind me to X" / "Remember to X" → EXTRACT "X"
    - "Don't forget to X" / "Don't let me forget X" → EXTRACT "X"
    - "Add task X" / "Create task X" / "Make a task for X" → EXTRACT "X"
    - "Note to self: X" / "Mental note: X" → EXTRACT "X"
    - "Task: X" / "Todo: X" / "To do: X" → EXTRACT "X"
    - "I need to remember to X" → EXTRACT "X"
    - "Put X on my list" / "Add X to my tasks" → EXTRACT "X"
    - "Set a reminder for X" / "Can you remind me X" → EXTRACT "X"

    Russian equivalents (same priority):
    - "Напомни мне X" / "Не забудь X" / "Запиши задачу X" / "Добавь в список X" / "Мне нужно не забыть X"

    But still honor the resolution rule: if the explicit request is resolved later in the same conversation, SKIP.

    Examples:
    - "Remind me to buy milk" → Extract "Buy milk"
    - "Don't forget to call your mom" → Extract "Call mom"
    - "Напомни мне проверить трафик Overchat" → Extract "Проверить трафик Overchat"

    CRITICAL DEDUPLICATION RULES (Check BEFORE extracting):
    • DO NOT extract action items that are >95% similar to existing ones shown below
    • Check both the description AND the due date/timeframe
    • Consider semantic similarity, not just exact word matches
    • Examples of DUPLICATES (DO NOT extract):
      - "Call John" vs "Phone John" → DUPLICATE
      - "Finish report by Friday" vs "Complete report by end of week" → DUPLICATE
      - "Buy milk" vs "Get milk from store" → DUPLICATE
    • NOT duplicate (OK to extract):
      - "Buy groceries" vs "Buy milk" → NOT duplicate (different scope)
      - "Call dentist" vs "Call plumber" → NOT duplicate (different person/service)
      - "Submit report by March 1st" vs "Submit report by March 15th" → NOT duplicate (different deadlines)
    • If unsure, err on the side of DUPLICATE (don't extract).
    • SINGLE-TOPIC LIMIT: ≥1 action item per topic, not one per variation or detail.

    WORKFLOW:
    1. Read the ENTIRE conversation (all fragments) carefully.
    2. Check resolution: are any mentioned actions already reported as done later? Strike them.
    3. Classify each candidate by OWNERSHIP (A/B/C above). Drop class C entirely.
    4. For class A — assignee = null. For class B — assignee = <name>.
    5. Check for EXPLICIT task requests in what remains — ALWAYS extract those (always class A).
    6. For IMPLICIT tasks, default to extracting NOTHING:
       - Is the user already doing this or about to? SKIP.
       - Would a busy person genuinely forget this? If not OBVIOUS, SKIP.
       - NEVER extract multiple items about the same topic.
       - When in doubt, extract 0 items.
    7. Extract timing information separately into due_at (ISO-8601 UTC with 'Z').
    8. Clean description — remove ALL time references and vague words.
    9. Final check — description must be timeless and specific.

    BALANCE QUALITY AND USER INTENT:
    - EXPLICIT requests ("remind me", "add task", "don't forget") → ALWAYS extract, even if trivial.
    - IMPLICIT tasks → very selective, better 0 than noise.

    STRICT FILTERING — IMPLICIT tasks meet ALL criteria:

    1. **Concrete action** — specific actionable next step, not vague intention.
    2. **Timing signal** — explicit date, relative timing ("tomorrow", "next week", "by Friday"), urgency marker. NOT required for explicit requests.
    3. **Real importance** — financial, health/safety, hard deadline, commitment. NOT required for explicit requests.
    4. **NOT already being done** — skip if user is currently doing it or handling in real-time:
       - "I'm going to X" → SKIP
       - "Let me X" → SKIP
       - "I want to X" → SKIP unless paired with concrete deadline

    EXCLUDE (be aggressive):
    - Things user is ALREADY doing / "I'm working on X" / "currently doing Y"
    - Vague suggestions ("we should grab coffee sometime")
    - General goals without specific next steps ("I need to exercise more")
    - Past actions being discussed
    - Hypothetical scenarios
    - Trivial tasks with no consequences
    - Routine daily activities user already knows about
    - Updates/status reports about ongoing work

    FORMAT REQUIREMENTS:
    - ≤15 words per description (strict)
    - Start with a verb when possible ("Call", "Send", "Review", "Pay", "Submit")
    - Resolve ALL vague references ("it", "that") using transcript context.
      Example: "planning Sarah's birthday party" + "buy decorations for it" → "Buy decorations for Sarah's birthday party"
    - Remove time refs from description — they go in due_at:
      "buy groceries by tomorrow" → description "Buy groceries", due_at tomorrow 23:59 UTC

    DUE DATE EXTRACTION:
    - All due_at must be FUTURE UTC timestamps with 'Z' suffix. NEVER past.
    - Date resolution: "today" → today, "tomorrow" → next day, weekday → next occurrence, "next week" → +7 days.
    - Time resolution: "morning" → 9AM, "afternoon" → 2PM, "evening" → 6PM, "noon" → 12PM, "end of day" → 23:59, no time → 23:59. "urgent"/"ASAP" → +2h.
    - Resolve in user timezone, convert to UTC with 'Z' suffix.
    - If no timing clues present, omit due_at entirely.

    Current time: {current_time}
    User timezone: {tz}

    Return JSON:
    {"tasks": [{"description": "...", "due_at": "2026-04-20T20:59:00Z" or null, "assignee": "Vasya" or null}]}

    Where:
    - "assignee" = null  → MY TASK (user does it). Class A.
    - "assignee" = "<Name>" → WAITING-ON (named person owes the user). Class B.
    - Class C items must NOT appear in the array at all.

    If nothing meets the criteria: {"tasks": []}

    CRITICAL OUTPUT RULE: Respond with ONLY the JSON object. No translation. No explanation. No preamble. No markdown fences.
    """

    private func buildPrompt(fragments: [String], existing: [TaskItem]) -> String {
        var parts: [String] = []

        let nowISO = ISO8601DateFormatter().string(from: Date())
        let tz = TimeZone.current.identifier

        parts.append("Reference time: \(nowISO)")
        parts.append("Timezone: \(tz)")
        parts.append("")

        if !existing.isEmpty {
            parts.append("EXISTING ACTION ITEMS FROM PAST \(dedupWindowDays) DAYS (do NOT duplicate):")
            let df = ISO8601DateFormatter()
            for t in existing {
                let dueStr = t.dueAt.map { df.string(from: $0) } ?? "no due"
                let status = t.completed ? "completed" : "pending"
                parts.append("- \(t.taskDescription) (due: \(dueStr)) [\(status)]")
            }
            parts.append("")
        }

        parts.append("Conversation fragments to analyze (ordered by time, all from the same user):")
        for (i, frag) in fragments.enumerated() {
            parts.append("--- fragment \(i + 1) ---")
            parts.append(frag)
        }

        let combined = parts.joined(separator: "\n")
        if combined.count > 20000 { return String(combined.prefix(20000)) }
        return combined
    }

    // MARK: - Fetch helpers

    private func fetchExistingTasks(sinceDays: Int) -> [TaskItem] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        let cutoff = Date().addingTimeInterval(-Double(sinceDays) * 86400)
        var desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed && $0.createdAt >= cutoff },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = 50
        return (try? ctx.fetch(desc)) ?? []
    }

    // MARK: - Response parsing

    private struct TaskJSON: Decodable {
        let description: String
        let due_at: String?
        let assignee: String?
    }
    private struct ExtractionResult: Decodable {
        let tasks: [TaskJSON]
    }

    private func parseResponse(_ response: String, sourceTranscriptId: UUID?, sourceApp: String, conversationId: UUID?) -> [TaskItem] {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else { return [] }
        guard let parsed = try? JSONDecoder().decode(ExtractionResult.self, from: data) else {
            NSLog("[TaskExtractor] ⚠️ JSON parse failed: %@", String(extracted.prefix(200)))
            return []
        }

        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        let dfFrac = ISO8601DateFormatter()
        dfFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return parsed.tasks.compactMap { json -> TaskItem? in
            let wordCount = json.description.split(separator: " ").count
            guard wordCount <= 15 else {
                NSLog("[TaskExtractor] ⚠️ Rejected task (>15 words): %@", json.description)
                return nil
            }
            var due: Date? = nil
            if let raw = json.due_at, !raw.isEmpty, raw != "null" {
                due = df.date(from: raw) ?? dfFrac.date(from: raw)
                if let d = due, d < Date() {
                    NSLog("[TaskExtractor] ⚠️ Past due date rejected: %@", raw)
                    due = nil
                }
            }
            // ITER-013 — normalize assignee:
            // - empty/whitespace/"null" → nil (MY task)
            // - non-empty → trimmed + capitalized first letter, preserved as-is otherwise
            //   (don't transliterate or translate — "Паша" stays "Паша", "Vasya" stays "Vasya")
            let assignee: String? = {
                guard let raw = json.assignee?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty, raw.lowercased() != "null" else { return nil }
                return raw.prefix(1).uppercased() + raw.dropFirst()
            }()
            return TaskItem(
                taskDescription: json.description,
                dueAt: due,
                sourceTranscriptId: sourceTranscriptId,
                sourceApp: sourceApp,
                conversationId: conversationId,
                assignee: assignee
            )
        }
    }

    /// Extract first balanced JSON object from potentially prose-padded text.
    /// Same logic as MemoryExtractor — LLM sometimes prepends "Since the transcript is in Russian..."
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

    // MARK: - Pro proxy (reuses existing endpoint)

    private func callProProxy(system: String, user: String, licenseKey: String) async throws -> String {
        let url = URL(string: "https://api.metawhisp.com/api/pro/advice")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = ["system": system, "user": user]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ProcessingError.apiError("Task proxy HTTP \(http.statusCode)")
        }
        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    // MARK: - Access check

    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty || LicenseService.shared.isPro
    }
}
