import Foundation
import SwiftData

/// Extracts action items from voice transcripts (Omi-aligned).
/// Mirrors `MemoryExtractor` pattern — triggered on each voice transcription ≥20 chars.
///
/// Omi reference: `backend/utils/llm/conversation_processing.py:301` (`extract_action_items`).
/// Prompt adapted from Omi's `instructions_text` (lines 345-540):
/// - Speaker/CalendarMeetingContext sections removed (we have single user, no calendar integration yet).
/// - All filtering rules, explicit patterns, dedup logic, due_at resolution copied verbatim.
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

    /// Omi uses 2-day dedup window for action items.
    private let dedupWindowDays: Int = 2

    func configure(screenContext: ScreenContextService, modelContainer: ModelContainer) {
        self.screenContext = screenContext
        self.modelContainer = modelContainer
    }

    /// Fire-and-forget task extraction triggered by a completed voice transcription.
    /// Mirrors `AdviceService.triggerOnTranscription` / `MemoryExtractor.triggerOnTranscription`.
    func triggerOnTranscription(text: String, source: String, transcriptId: UUID? = nil, conversationId: UUID? = nil) {
        guard settings.tasksEnabled else { return }
        guard text.count >= 20 else { return }
        Task { [weak self] in
            await self?.extract(transcript: text, source: source, transcriptId: transcriptId, conversationId: conversationId)
        }
    }

    /// Run extraction on the most recent transcript in history (manual EXTRACT TASKS NOW button).
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
        guard let latest = (try? ctx.fetch(desc))?.first, latest.displayText.count >= 20 else {
            NSLog("[TaskExtractor] No recent transcript (need ≥20 chars) — skipping")
            return
        }
        await extract(transcript: latest.displayText, source: "manual", transcriptId: latest.id, conversationId: latest.conversationId)
    }

    /// Core extraction — voice transcript → LLM → persist TaskItems.
    private func extract(transcript: String, source: String, transcriptId: UUID?, conversationId: UUID?) async {
        guard !isRunning else { return }
        guard hasLLMAccess else { return }

        isRunning = true
        defer {
            isRunning = false
            lastRun = Date()
        }

        let existing = fetchExistingTasks(sinceDays: dedupWindowDays)
        let prompt = buildPrompt(transcript: transcript, existing: existing)

        do {
            let response: String
            if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                NSLog("[TaskExtractor] Extracting via Pro proxy")
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

            let sourceApp = screenContext?.recentContexts.last?.appName ?? source
            let tasks = parseResponse(response, sourceTranscriptId: transcriptId, sourceApp: sourceApp, conversationId: conversationId)
            guard !tasks.isEmpty else {
                NSLog("[TaskExtractor] No new tasks this cycle")
                return
            }

            if let container = modelContainer {
                let ctx = ModelContext(container)
                for task in tasks {
                    ctx.insert(task)
                }
                try? ctx.save()
                NSLog("[TaskExtractor] ✅ Extracted %d tasks", tasks.count)
            }
        } catch {
            lastError = error.localizedDescription
            NSLog("[TaskExtractor] ❌ Failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Prompt (copied verbatim from Omi, single-user adaptation)

    /// Action item extraction prompt.
    /// Source: `BasedHardware/omi/backend/utils/llm/conversation_processing.py:345-540`.
    /// Adaptations:
    /// - Removed speaker resolution rules (single user dictation).
    /// - Removed CalendarMeetingContext handling (no calendar integration yet).
    /// - Preserved: explicit patterns, dedup rules, workflow, filtering, format, due_at resolution.
    static let systemPrompt = """
    You are an expert action item extractor. Your sole purpose is to identify and extract actionable tasks from the provided content.

    EXPLICIT TASK/REMINDER REQUESTS (HIGHEST PRIORITY)

    When the user uses these patterns, ALWAYS extract the task:
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

    These explicit requests bypass importance/timing filters. If the user explicitly asks for a reminder or task, extract it.

    Examples:
    - "Remind me to buy milk" → Extract "Buy milk"
    - "Don't forget to call your mom" → Extract "Call mom"
    - "Add task pick up dry cleaning" → Extract "Pick up dry cleaning"
    - "Note to self, check tire pressure" → Extract "Check tire pressure"
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
    1. Read the ENTIRE transcript carefully.
    2. Check for EXPLICIT task requests — ALWAYS extract these.
    3. For IMPLICIT tasks, default to extracting NOTHING:
       - Is the user already doing this or about to? SKIP.
       - Would a busy person genuinely forget this? If not OBVIOUS, SKIP.
       - NEVER extract multiple items about the same topic.
       - When in doubt, extract 0 items.
    4. Extract timing information separately into due_at (ISO-8601 UTC with 'Z').
    5. Clean description — remove ALL time references and vague words.
    6. Final check — description must be timeless and specific.

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
    {"tasks": [{"description": "...", "due_at": "2026-04-20T20:59:00Z" or null}]}

    If nothing meets the criteria: {"tasks": []}

    CRITICAL OUTPUT RULE: Respond with ONLY the JSON object. No translation. No explanation. No preamble. No markdown fences.
    """

    private func buildPrompt(transcript: String, existing: [TaskItem]) -> String {
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

        parts.append("Voice transcript to analyze:")
        parts.append("```")
        parts.append(transcript)
        parts.append("```")

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
            return TaskItem(
                taskDescription: json.description,
                dueAt: due,
                sourceTranscriptId: sourceTranscriptId,
                sourceApp: sourceApp,
                conversationId: conversationId
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
