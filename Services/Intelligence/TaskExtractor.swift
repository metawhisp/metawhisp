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
    /// ITER-041 — structured JSON action-item extraction on the cheapest tier.
    // 2026-05-31 — bumped mini→medium. The 8B mini model ignored the nuanced
    // EXCLUDE rules (esp. "work commands dictated to an AI/dev" — the #1 noise
    // source) and over-extracted ~100 garbage tasks/day. medium follows the
    // selective criteria far better, matching the other extractors already on it.
    static let llmTier: LLMTier = .medium
    static let llmServiceId: String = "TaskExtractor"

    @Published var isRunning = false
    @Published var lastRun: Date?
    @Published var lastError: String?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?

    /// SB-1 — durable queue of conversations awaiting extraction. Replaces the
    /// silent `guard !isRunning` drop and survives relaunch (startup backfill).
    private let queue = ExtractionQueueStore(filename: "task-extraction-queue.json")

    /// 2-day dedup window for action items.
    private let dedupWindowDays: Int = 2

    // ITER-053.1 — the `screenContext` dependency was dead wiring (stored,
    // never read: extraction runs on transcripts/DB, not the live screen).
    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Fire-and-forget extraction on the whole conversation. Called by ConversationGrouper
    /// after a conversation closes (dictation gap timeout or meeting stop).
    func triggerOnConversationClose(conversationId: UUID) {
        guard settings.tasksEnabled else { return }
        queue.enqueue(conversationId)
        NSLog("[TaskExtractor] Conversation closed → extraction queued (convo %@, %d pending)", conversationId.uuidString.prefix(8) as CVarArg, queue.pending().count)
        Task { [weak self] in await self?.drainQueue() }
    }

    /// SB-1 — startup backfill: process conversations left queued by a previous
    /// session (app quit/crash before extraction finished). Call once after
    /// `configure(...)`.
    func backfillPending() {
        guard settings.tasksEnabled, !queue.pending().isEmpty else { return }
        NSLog("[TaskExtractor] Backfilling %d pending conversation(s)", queue.pending().count)
        Task { [weak self] in await self?.drainQueue() }
    }

    /// SB-1 — serial drain of the durable queue. `isRunning` guards re-entrancy
    /// (a second conversation closing while we work just enqueues; this pass
    /// picks it up — see `ExtractionQueueStore.drain`) and drives the UI status.
    private func drainQueue() async {
        guard !isRunning else { return }
        // ITER-049 A2 — never drain the durable queue against a degraded (empty
        // in-memory) store: it would mark queued conversations .completed and
        // rewrite the queue file, permanently dropping work whose real data is
        // safe in the preserved on-disk store. Stays queued for the next launch.
        guard StoreHealthSignal.shared.isHealthy else { return }
        isRunning = true
        defer { isRunning = false; lastRun = Date() }
        await queue.drain { id in await self.extractFromConversation(conversationId: id) }
        NSLog("[TaskExtractor] Drain finished — %d conversation(s) still pending", queue.pending().count)
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
        queue.enqueue(convId)
        NSLog("[TaskExtractor] Manual EXTRACT NOW (button) → convo %@ queued, %d pending", convId.uuidString.prefix(8) as CVarArg, queue.pending().count)
        await drainQueue()
    }

    /// Core extraction — collect all transcripts for the conversation, send as one block.
    private func extractFromConversation(conversationId: UUID) async -> ExtractionOutcome {
        guard hasLLMAccess else { return .retryLater }

        guard let container = modelContainer else { return .retryLater }
        let ctx = ModelContext(container)

        // AUD-035 — fetch the WHOLE conversation (uncapped, oldest first) via the
        // shared, AUD-016-tested helper. The old inline 100-row cap silently
        // dropped late fragments — exactly where reversals/completions live — so
        // extraction ran on a prefix while the doc above promised full context.
        // (Cloud paths get the full block; the local route still caps at the
        // model's input budget — see the completeBlocking call below.)
        let items = StructuredGenerator.fetchHistoryItems(conversationId: conversationId, in: ctx)
        let fragments = items
            .map { $0.displayText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            if fragments.isEmpty || fragments.reduce(0, { $0 + $1.count }) < 20 { NSLog("[TaskExtractor] Skipping convo %@ — %d non-empty fragments, below the 20-char floor", conversationId.uuidString.prefix(8) as CVarArg, fragments.count) }

        guard !fragments.isEmpty else { return .completed }
        let totalChars = fragments.reduce(0) { $0 + $1.count }
        guard totalChars >= 20 else { return .completed }

        let existing = fetchExistingTasks(sinceDays: dedupWindowDays)
        // ITER-025 — REFERENCE_TIME requires the conversation start so the LLM
        // can decide whether to anchor due-date math at started_at (recent) or
        // at current_time (>7d old, e.g. backfill / regenerate paths).
        let startedAt = items.first?.createdAt ?? Date()
        // ITER-026 — Calendar enrichment: when this conversation was linked to
        // an EKEvent (by `CalendarReaderService.linkConversation`), we surface
        // the event title + scheduled time + attendee names BEFORE the
        // transcript so the LLM can name people correctly in extracted tasks
        // ("Send draft to Maya" instead of "Send draft to him").
        let calendarContext = fetchCalendarContext(conversationId: conversationId, in: ctx)
        let useLocal = LocalLLMService.shared.isReady
        let prompt = buildPrompt(
            fragments: fragments,
            existing: existing,
            startedAt: startedAt,
            calendarContext: calendarContext,
            localBudget: useLocal ? 6000 : nil
        )

        // Use the last fragment's source app if available (proxy for what app user was in most).
        let sourceApp = items.last.flatMap { $0.source } ?? "conversation"
        NSLog("[TaskExtractor] Start: convo %@, %d fragments, %d transcript chars, %d prompt chars, %d dedup refs, calendar=%@, route=%@", conversationId.uuidString.prefix(8) as CVarArg, fragments.count, totalChars, prompt.count, existing.count, calendarContext == nil ? "no" : "yes", useLocal ? "local" : ((LicenseService.shared.isPro && LicenseService.shared.licenseKey?.isEmpty == false) ? "pro" : "byok"))

        do {
            let response: String
            // ITER-039 — local LLM takes priority when loaded.
            if LocalLLMService.shared.isReady {
                NSLog("[TaskExtractor] Extracting via local Phi (convo %@, %d fragments)",
                      conversationId.uuidString.prefix(8) as CVarArg, fragments.count)
                response = try await LocalLLMService.shared.completeBlocking(
                    system: Self.systemPrompt, user: prompt,
                    maxUserChars: 6000, maxTokens: 384   // F1.2 — was default 2000: transcript got cut after dedup context
                )
            } else if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                NSLog("[TaskExtractor] Extracting via Pro proxy (convo %@, %d fragments, %d chars)",
                      conversationId.uuidString.prefix(8) as CVarArg, fragments.count, totalChars)
                response = try await callProProxy(system: Self.systemPrompt, user: prompt, licenseKey: licenseKey)
            } else {
                let apiKey = settings.activeAPIKey
                guard !apiKey.isEmpty else {
                    NSLog("[TaskExtractor] No API key — skipping")
                    return .retryLater
                }
                let provider = LLMProvider(rawValue: settings.llmProvider) ?? .openai
                response = try await llm.complete(
                    system: Self.systemPrompt,
                    user: prompt,
                    apiKey: apiKey,
                    provider: provider
                )
            }

            // F1.7 — nil = garbage/truncated JSON (routine for local models):
            // keep the conversation queued instead of dequeuing it forever.
            guard let tasks = parseResponse(response,
                                            sourceTranscriptId: items.last?.id,
                                            sourceApp: sourceApp,
                                            conversationId: conversationId) else {
                lastError = "LLM returned unparseable JSON — will retry"
                NSLog("[TaskExtractor] ⚠️ Unparseable response for convo %@ (%d chars) — counted as failed attempt", conversationId.uuidString.prefix(8) as CVarArg, response.count)
                return .failedAttempt   // counted — capped at maxFailedAttempts
            }
            guard !tasks.isEmpty else {
                NSLog("[TaskExtractor] No new tasks from conversation %@", conversationId.uuidString.prefix(8) as CVarArg)
                return .completed
            }

            for task in tasks {
                ctx.insert(task)
            }
            // SB-1: a swallowed save (try?) would return .completed and let the
            // queue drop the conversation though nothing persisted — the exact
            // silent loss this iteration fixes. `try` → throw → catch → .retryLater.
            try ctx.save()
            NSLog("[TaskExtractor] Response %d chars → %d task(s) saved, %d with due date, %d delegated", response.count, tasks.count, tasks.filter { $0.dueAt != nil }.count, tasks.filter { !$0.isMyTask }.count)
            NSLog("[TaskExtractor] ✅ Extracted %d tasks from conversation %@",
                  tasks.count, conversationId.uuidString.prefix(8) as CVarArg)

            for task in tasks {
                NotificationService.shared.postNewTask(task, source: "Voice")
            }

            // Fire-and-forget embedding for semantic RAG (ITER-008).
            AppDelegate.shared?.embeddingService.embedTasksInBackground(tasks, in: ctx)

            // ITER-035 v2 — export each new task as markdown in the user's vault.
            if let exporter = AppDelegate.shared?.obsidianExporter {
                let ids = tasks.map { $0.id }
                Task { @MainActor in
                    for id in ids {
                        await exporter.exportTask(id)
                    }
                }
            }
            return .completed
        } catch {
            lastError = error.localizedDescription
            NSLog("[TaskExtractor] ❌ Failed: %@", error.localizedDescription)
            return .failedAttempt   // counted — a conversation that always throws gets dropped after N tries
        }
    }

    // MARK: - Prompt

    /// Action item extraction prompt — on-conversation-close pattern.
    /// Single-user desktop dictation: no speaker labels. Assignee filter done via
    /// linguistic "USER IS SUBJECT" rule.
    static let systemPrompt = """
    You are an expert action item extractor. Your sole purpose is to identify and extract actionable tasks from a voice-dictation conversation.

    CALENDAR MEETING CONTEXT (when present, READ FIRST):

    A `CALENDAR MEETING CONTEXT:` block may precede the transcript. When it appears it lists the meeting Title, Scheduled time range, and Participants pulled from the user's actual calendar event linked to this conversation. You MUST:
    - Use participant names verbatim in extracted tasks. NEVER use "Speaker 0" / "Speaker 1" or vague pronouns ("him") when names are available.
    - Recognise that the conversation involved exactly the listed participants — match transcript voices to those names by content cues. Example: if the meeting is "1-on-1 with Maya" and the user says "I'll send him the draft", extract "Send draft to Maya" — not "Send draft to him".
    - Treat the meeting Title only as situational context — do NOT extract the title itself as a task. Action items must come from the SPEAKERS' words inside the transcript.
    - When ambiguous which named participant a delegated action falls on (e.g. user says "we agreed they'll handle it" but multiple names listed), prefer SKIP over guessing.

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
        - "Я попросил Сэма задеплоить" / "I asked Sam to deploy" → assignee = "Sam"
        - "Мы решили что Сэм подготовит отчёт" (user is in "мы" but Sam does it) → assignee = "Sam"
        - "Сказал Майку прислать драфт" / "Told Mike to send draft" → assignee = "Mike"
        → EXTRACT with assignee = <person name as spoken>

    (C) UNRELATED THIRD PARTY — someone else's action with NO link to user.
        Examples:
        - "У Сэма созвон с Саней в среду" → SKIP (just a fact, not user's concern)
        - "Mike has a meeting with his team" → SKIP
        - "Sam is shipping v2 today" → SKIP (no delegation, no co-commitment)
        → SKIP — do not extract

    Critical rule for (B) vs (C): EXTRACT as waiting-on ONLY when the user's voice
    explicitly delegated the work or the user is part of the deciding party. A bare
    mention of someone else's activity = (C) = SKIP. When ambiguous, prefer SKIP.

    Ambiguous cases — default to SKIP unless explicit:
    - "Созвон с Сэмуй в понедельник" → who calls? SKIP unless "у меня / I have / поставил".
    - "Сэм прислал документы, нужно посмотреть" → who looks is ambiguous → SKIP unless clearly user said "посмотрю / I'll review".
    - "У меня созвон с Сэмуй в понедельник" → "у меня" = user → MY task.
    - "Просил Сэма прислать к среде" → explicit delegation → WAITING-ON, assignee = "Сэм".

    Assignee field formatting:
    - Use the name AS SPOKEN in the transcript (don't normalize "Bob" → "Robert").
    - Capitalize first letter ("Sam" not "sam").
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
    - "Напомни мне проверить трафик ChatApp" → Extract "Проверить трафик ChatApp"

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
    - Conversations where the action is being completed in real-time between participants
    - Back-and-forth clarification or decision-making about something happening right now
    - Requests and responses between people who are together and handling the matter on the spot
    - If the entire conversation is a brief in-person exchange that will be resolved within minutes, extract 0 items
    - **WORK COMMANDS DICTATED TO AN AI / DEVELOPER / TOOL — the #1 noise source, SKIP ALL.**
      This user dictates to DIRECT an AI assistant or developer to build / fix / change / check /
      improve / review software, websites, designs, code, or content. Those imperative commands are
      work being EXECUTED right now by the AI or tool — they are NOT the user's personal to-do list.
      SKIP every such command. Examples to SKIP:
        "make the text larger", "check the website metadata", "read claude.md", "find more tools",
        "fix the layout", "create a plan and show the architecture", "increase the card size",
        "write CLAUDE instead of OPUS", "review and improve the website", "structure the text",
        "make elements more neutral", "transcribe the videos".
      Heuristic: if the action is about producing/modifying software, a website, a design, content,
      or code, and the user is plainly instructing it to be done now, it is a COMMAND, not a task → SKIP.
      Extract one of these ONLY if the user EXPLICITLY frames it as their own reminder/task
      ("remind me", "add task", "don't forget", "напомни", "запиши задачу", "не забудь").

    FORMAT REQUIREMENTS:
    - ≤15 words per description (strict)
    - Start with a verb when possible ("Call", "Send", "Review", "Pay", "Submit")
    - Resolve ALL vague references ("it", "that") using transcript context.
      Example: "planning Jordan's birthday party" + "buy decorations for it" → "Buy decorations for Jordan's birthday party"
    - Remove time refs from description — they go in due_at:
      "buy groceries by tomorrow" → description "Buy groceries", due_at tomorrow 23:59 UTC

    DUE DATE EXTRACTION:
    - All due_at must be FUTURE UTC timestamps with 'Z' suffix. NEVER past.
    - REFERENCE_TIME: If `started_at` is >7 days before `current_time`, use `current_time` as the anchor (we're reprocessing a stale conversation). Otherwise use `started_at`. Phrases like "tomorrow" / "next Monday" resolve relative to REFERENCE_TIME, NOT to whenever the LLM thinks "now" is.
    - Date resolution: "today" → REFERENCE_TIME date, "tomorrow" → next day, weekday → next occurrence, "next week" → +7 days.
    - Time resolution: "morning" → 9AM, "afternoon" → 2PM, "evening" → 6PM, "noon" → 12PM, "end of day" → 23:59, no time → 23:59. "urgent"/"ASAP" → +2h from REFERENCE_TIME.
    - Resolve in user timezone, convert to UTC with 'Z' suffix.
    - If resolved date ends up in the past relative to `current_time`, omit due_at.
    - If no timing clues present, omit due_at entirely.

    Conversation started_at: {started_at}
    Current time: {current_time}
    User timezone: {tz}

    Return JSON:
    {"tasks": [{"description": "...", "due_at": "2026-04-20T20:59:00Z" or null, "assignee": "Sam" or null}]}

    Where:
    - "assignee" = null  → MY TASK (user does it). Class A.
    - "assignee" = "<Name>" → WAITING-ON (named person owes the user). Class B.
    - Class C items must NOT appear in the array at all.

    If nothing meets the criteria: {"tasks": []}

    CRITICAL OUTPUT RULE: Respond with ONLY the JSON object. No translation. No explanation. No preamble. No markdown fences.
    """

    private func buildPrompt(
        fragments: [String],
        existing: [TaskItem],
        startedAt: Date,
        calendarContext: CalendarMeetingContext?,
        localBudget: Int? = nil
    ) -> String {
        var parts: [String] = []

        let now = Date()
        let nowISO = ISO8601DateFormatter().string(from: now)
        let startedISO = ISO8601DateFormatter().string(from: startedAt)
        let tz = TimeZone.current.identifier

        // REFERENCE_TIME hint — surfaces whether the conversation is recent or
        // stale so the LLM can apply the >7-day rule from the system prompt.
        let ageDays = now.timeIntervalSince(startedAt) / 86400
        let referenceHint = ageDays > 7
            ? "REFERENCE_TIME = current_time (conversation is \(Int(ageDays))d old, treat as reprocess)"
            : "REFERENCE_TIME = started_at (recent conversation, anchor due-dates here)"

        parts.append("Conversation started_at: \(startedISO)")
        parts.append("Current time: \(nowISO)")
        parts.append("Timezone: \(tz)")
        parts.append(referenceHint)
        parts.append("")

        // ITER-026 — calendar enrichment block. Lets the LLM ground assignees
        // in real names instead of "Speaker 0" / "him".
        if let cal = calendarContext {
            parts.append("CALENDAR MEETING CONTEXT:")
            parts.append("- Title: \(cal.title)")
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd HH:mm zzz"
            parts.append("- Scheduled: \(df.string(from: cal.startDate)) → \(df.string(from: cal.endDate))")
            if !cal.attendees.isEmpty {
                parts.append("- Participants: \(cal.attendees.joined(separator: ", "))")
            }
            parts.append("")
        }

        if !existing.isEmpty {
            parts.append("EXISTING ACTION ITEMS FROM PAST \(dedupWindowDays) DAYS (do NOT duplicate):")
            let df = ISO8601DateFormatter()
            // ITER-051 review fix — see MemoryExtractor.buildPrompt: with the
            // local model, dedup context is capped so it can't starve the
            // transcript out of the prefix-kept budget.
            if let budget = localBudget {
                var used = 0, shown = 0
                for t in existing {
                    let dueStr = t.dueAt.map { df.string(from: $0) } ?? "no due"
                    let status = t.completed ? "completed" : "pending"
                    let line = "- \(t.taskDescription) (due: \(dueStr)) [\(status)]"
                    if used + line.count > budget * 3 / 10 { break }
                    parts.append(line); used += line.count; shown += 1
                }
                if shown < existing.count { parts.append("(+\(existing.count - shown) more omitted)") }
            } else {
                for t in existing {
                    let dueStr = t.dueAt.map { df.string(from: $0) } ?? "no due"
                    let status = t.completed ? "completed" : "pending"
                    parts.append("- \(t.taskDescription) (due: \(dueStr)) [\(status)]")
                }
            }
            parts.append("")
        }

        parts.append("Conversation fragments to analyze (ordered by time, all from the same user):")
        var fragLines: [String] = []
        for (i, frag) in fragments.enumerated() {
            fragLines.append("--- fragment \(i + 1) ---")
            fragLines.append(frag)
        }
        var fragText = fragLines.joined(separator: "\n")
        if let budget = localBudget {
            let headerChars = parts.joined(separator: "\n").count + 64
            let fragBudget = max(1000, budget - headerChars)
            if fragText.count > fragBudget {
                fragText = String(fragText.prefix(fragBudget * 7 / 10))
                    + "\n[…middle omitted…]\n"
                    + String(fragText.suffix(fragBudget * 3 / 10))
            }
        }
        parts.append(fragText)

        let combined = parts.joined(separator: "\n")
        if combined.count > 20000 { return String(combined.prefix(20000)) }
        return combined
    }

    /// Linked-event metadata pulled from `Conversation.calendarEvent*` fields.
    /// Only present when `CalendarReaderService.linkConversation` matched the
    /// conversation to an EKEvent during ITER-018.
    struct CalendarMeetingContext {
        let title: String
        let startDate: Date
        let endDate: Date
        let attendees: [String]
    }

    private func fetchCalendarContext(conversationId: UUID, in ctx: ModelContext) -> CalendarMeetingContext? {
        var desc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conversationId })
        desc.fetchLimit = 1
        guard let conv = (try? ctx.fetch(desc))?.first else { return nil }
        guard let title = conv.calendarEventTitle?.trimmingCharacters(in: .whitespaces),
              !title.isEmpty,
              let start = conv.calendarEventStartDate,
              let end = conv.calendarEventEndDate else {
            return nil
        }
        let attendees: [String] = {
            guard let raw = conv.calendarAttendeesJSON,
                  let data = raw.data(using: .utf8),
                  let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return names.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }()
        return CalendarMeetingContext(title: title, startDate: start, endDate: end, attendees: attendees)
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

    /// ITER-051 F1.7 — `nil` = unparseable LLM output (the caller keeps the
    /// conversation queued); `[]` = valid JSON with nothing to extract.
    /// Internal (not private) so `ExtractorParseOutcomeTests` pins the contract.
    func parseResponse(_ response: String, sourceTranscriptId: UUID?, sourceApp: String, conversationId: UUID?) -> [TaskItem]? {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONDecoder().decode(ExtractionResult.self, from: data) else {
            NSLog("[TaskExtractor] ⚠️ JSON parse failed — %d chars, starts with %@", extracted.count, extracted.first.map { String($0) } ?? "(empty)")
            return nil
        }

        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        let dfFrac = ISO8601DateFormatter()
        dfFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return parsed.tasks.compactMap { json -> TaskItem? in
            let wordCount = json.description.split(separator: " ").count
            guard wordCount <= 15 else {
                NSLog("[TaskExtractor] ⚠️ rejected task (>15 words, %d chars)", json.description.count)
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
            //   (don't transliterate or translate — "Сэм" stays "Сэм", "Sam" stays "Sam")
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

        let body = LLMRequestBody.proAdviceBody(
            system: system, user: user,
            tier: Self.llmTier, serviceId: Self.llmServiceId
        )
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
        !settings.activeAPIKey.isEmpty
            || LicenseService.shared.isPro
            || LocalLLMService.shared.isReady
    }
}
