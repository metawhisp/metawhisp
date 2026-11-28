import Foundation
import SwiftData

/// Proposes task drafts from a FULL closed Conversation — not per transcript (FEAT-0005).
///
/// Triggered on conversation close (10-min silence for dictation, stop-button for meetings).
/// Runs once over the entire conversation so the model can see items resolved later in the same
/// conversation, keep who must act straight across fragments, and propose repeated intent once.
/// Every result is a draft the user accepts or drops (`TaskDrafts`); nothing is written to the
/// task list here.
///
/// spec://BACKLOG#B1, spec://intelligence/FEAT-0005
@MainActor
final class TaskExtractor: ObservableObject {
    /// ITER-041 — structured JSON action-item extraction on the cheapest tier.
    // 2026-05-31 — bumped mini→medium. The 8B mini model ignored the nuanced
    // EXCLUDE rules (esp. "work commands dictated to an AI/dev" — the #1 noise
    // source) and over-extracted ~100 garbage tasks/day. medium follows the
    // selective criteria far better, matching the other extractors already on it.
    static let llmTier: LLMTier = .medium
    static let llmServiceId: String = "TaskExtractor"
    /// The local route's answer budget. FEAT-0005 items carry nine fields and the spoken words (about a hundred
    /// tokens each); the old three-field items fit in 384, five new ones do not.
    static let localAnswerTokens = 768

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

    /// Core extraction — FEAT-0005: the whole conversation goes to the model once; every item that passes
    /// `TaskCandidateRules` is saved as a draft (`staged`) the user accepts or drops. No notification and no vault
    /// file for a draft (I1, I5).
    private func extractFromConversation(conversationId: UUID) async -> ExtractionOutcome {
        guard hasLLMAccess else { return .retryLater }
        guard let container = modelContainer else { return .retryLater }

        // ITER-081 — the route is chosen once: the prompt is sized for it and
        // sent to it.
        let route = ExtractionRoute.current(localReady: LocalLLMService.shared.isReady,
                                            isPro: LicenseService.shared.isPro,
                                            licenseKey: LicenseService.shared.licenseKey)
        if route == .byok, settings.activeAPIKey.isEmpty {
            NSLog("[TaskExtractor] No API key — skipping")
            return .retryLater
        }

        do {
            let pass = try await suggest(conversationId: conversationId, in: ModelContext(container),
                                         route: route, now: Date()) { system, user in
                try await self.complete(system: system, user: user, route: route)
            }
            switch pass {
            case .nothingToSend:
                return .completed
            case .unparseable(let response):
                // F1.7 — nil = garbage/truncated JSON (routine for local models):
                // keep the conversation queued instead of dequeuing it forever.
                lastError = "LLM returned unparseable JSON — will retry"
                NSLog("[TaskExtractor] ⚠️ Unparseable response for convo %@ (%d chars) — counted as failed attempt", conversationId.uuidString.prefix(8) as CVarArg, response.count)
                return .failedAttempt   // counted — capped at maxFailedAttempts
            case .done(let run):
                let reasons = Dictionary(grouping: run.outcome.dropped, by: \.reason).map { "\($0.key.rawValue)=\($0.value.count)" }.sorted()
                NSLog("[TaskExtractor] Convo %@ (%@): %d item(s) answered, %d kept as drafts, dropped: %@", conversationId.uuidString.prefix(8) as CVarArg, run.source == .call ? "call" : "dictation", run.outcome.kept.count + run.outcome.dropped.count, run.drafts.count, reasons.isEmpty ? "none" : reasons.joined(separator: " "))
                guard !run.drafts.isEmpty else { return .completed }
                // The model call took seconds: the drafts go into a context made now, so nothing read before it
                // is written back (stale-save rule). SB-1: `try`, never `try?` — a lost save keeps it queued.
                let save = ModelContext(container)
                for draft in run.drafts { save.insert(draft) }
                try save.save()
                NSLog("[TaskExtractor] ✅ %d draft(s) saved from conversation %@, %d with due date, %d waiting on someone", run.drafts.count, conversationId.uuidString.prefix(8) as CVarArg, run.drafts.filter { $0.dueAt != nil }.count, run.drafts.filter { !$0.isMyTask }.count)
                // Fire-and-forget embedding for semantic RAG (ITER-008).
                AppDelegate.shared?.embeddingService.embedTasksInBackground(run.drafts, in: save)
                // The after-call card may already be open: its drafts arrive now.
                MeetingRecapState.shared.reloadDrafts(for: conversationId, in: container)
                return .completed
            }
        } catch {
            lastError = error.localizedDescription
            NSLog("[TaskExtractor] ❌ Failed: %@", error.localizedDescription)
            return .failedAttempt   // counted — a conversation that always throws gets dropped after N tries
        }
    }

    /// One pass without the store write: what was sent, what came back, what the rules kept. The model call is
    /// passed in, so the replay and the tests run the exact pipeline the app runs.
    enum SuggestionPass {
        /// Too little text to send (nothing, or under 20 characters after the phantom filter).
        case nothingToSend
        case unparseable(response: String)
        case done(SuggestionRun)
    }

    struct SuggestionRun {
        let source: TaskCandidateRules.Source
        let prompt: String
        let response: String
        let outcome: TaskCandidateRules.Outcome
        /// Not inserted anywhere yet; every one `staged`.
        let drafts: [TaskItem]
    }

    func suggest(conversationId: UUID, in ctx: ModelContext, route: ExtractionRoute, now: Date,
                 complete: (_ system: String, _ user: String) async throws -> String) async throws -> SuggestionPass {
        // AUD-035 — the WHOLE conversation (uncapped, recording order) via the shared, AUD-016-tested helper.
        let items = StructuredGenerator.fetchHistoryItems(conversationId: conversationId, in: ctx)
        // R3 — phantom lines never reach the model, so nothing can cite them.
        let sent: [(item: HistoryItem, text: String)] = items.compactMap { item in
            TaskCandidateRules.sendable(item.displayText).map { (item, $0) }
        }
        let totalChars = sent.reduce(0) { $0 + $1.text.count }
        guard !sent.isEmpty, totalChars >= 20 else {
            NSLog("[TaskExtractor] Skipping convo %@ — %d non-empty fragments, below the 20-char floor", conversationId.uuidString.prefix(8) as CVarArg, sent.count)
            return .nothingToSend
        }

        let source = Self.source(of: conversationId, items: items, in: ctx)
        let existing = fetchExistingTasks(sinceDays: dedupWindowDays, in: ctx, now: now)
        // ITER-025 — REFERENCE_TIME requires the conversation start so the LLM
        // can decide whether to anchor due-date math at started_at (recent) or
        // at current_time (>7d old, e.g. backfill / regenerate paths).
        let startedAt = items.first?.createdAt ?? now
        let prompt = buildPrompt(fragments: sent.map(\.text), existing: existing, startedAt: startedAt,
                                 source: source, route: route, now: now)
        NSLog("[TaskExtractor] Start: convo %@ (%@), %d fragments, %d transcript chars, %d prompt chars, %d dedup refs, route=%@", conversationId.uuidString.prefix(8) as CVarArg, source == .call ? "call" : "dictation", sent.count, totalChars, prompt.count, existing.count, route.name)

        let response = try await complete(Self.systemPrompt, prompt)
        guard let candidates = parseCandidates(response) else { return .unparseable(response: response) }

        let fragments = sent.map { TaskCandidateRules.Fragment(text: $0.text, at: $0.item.recordedAt ?? $0.item.createdAt) }
        // Read after the model call, in a context made now (the rows may have changed meanwhile).
        let since = fragments.map(\.at).min() ?? now
        let rows = Self.repeatRows(since: since, in: ModelContext(ctx.container))
            .compactMap { TaskCandidateRules.existing(from: $0, now: now) }
        // Off the main actor: on a long call the evidence scan takes real time.
        let outcome = await Task.detached(priority: .utility) {
            TaskCandidateRules.apply(candidates, source: source, fragments: fragments, existing: rows, now: now)
        }.value
        let drafts = outcome.kept.enumerated().map { i, kept -> TaskItem in
            let part = sent[kept.fragmentIndex].item
            let draft = TaskItem(taskDescription: kept.candidate.description,
                                 dueAt: kept.candidate.dueAt,
                                 sourceTranscriptId: part.id,
                                 sourceApp: part.source ?? items.last?.source ?? "conversation",
                                 conversationId: conversationId,
                                 status: "staged",
                                 assignee: kept.candidate.assignee)
            // Suggestions show newest first: within one pass the model's first item is the newest (1 ms apart).
            draft.createdAt = now.addingTimeInterval(-Double(i) / 1_000)
            draft.updatedAt = draft.createdAt
            return draft
        }
        return .done(SuggestionRun(source: source, prompt: prompt, response: response,
                                   outcome: outcome, drafts: drafts))
    }

    /// A meeting is a call between people; everything else is one person dictating.
    private static func source(of conversationId: UUID, items: [HistoryItem], in ctx: ModelContext) -> TaskCandidateRules.Source {
        var desc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conversationId })
        desc.fetchLimit = 1
        if let conv = (try? ctx.fetch(desc))?.first { return conv.source == "meeting" ? .call : .dictation }
        return items.contains { $0.source == "meeting" } ? .call : .dictation
    }

    /// R1 / K9 — every row that can absorb a repeat said since `since`: open work (tasks and drafts, any age, no
    /// cap: an old open task must still absorb its repeat) and work that ended after it (done, dropped).
    private static func repeatRows(since: Date, in ctx: ModelContext) -> [TaskItem] {
        var open = FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.completed && !$0.isDismissed })
        var ended = FetchDescriptor<TaskItem>(predicate: #Predicate { ($0.completed || $0.isDismissed) && $0.updatedAt >= since })
        // Only what the lifecycle reads — not the embedding every row carries.
        let fields: [PartialKeyPath<TaskItem>] = [\.taskDescription, \.assignee, \.status, \.isDismissed, \.completed,
                                                  \.completedAt, \.createdAt, \.updatedAt]
        open.propertiesToFetch = fields
        ended.propertiesToFetch = fields
        return ((try? ctx.fetch(open)) ?? []) + ((try? ctx.fetch(ended)) ?? [])
    }

    /// The model call on the chosen route.
    private func complete(system: String, user: String, route: ExtractionRoute) async throws -> String {
        switch route {
        case .local:
            // ITER-039 — local LLM takes priority when loaded.
            return try await LocalLLMService.shared.completeBlocking(
                system: system, user: user,
                maxUserChars: 6000, maxTokens: Self.localAnswerTokens   // F1.2: the input budget stays 6000
            )
        case .pro(let licenseKey):
            return try await callProProxy(system: system, user: user, licenseKey: licenseKey)
        case .byok:
            let provider = LLMProvider(rawValue: settings.llmProvider) ?? .openai
            return try await llm.complete(system: system, user: user, apiKey: settings.activeAPIKey, provider: provider)
        }
    }

    // MARK: - Prompt

    /// FEAT-0005 §3 — the model proposes; `TaskCandidateRules` decides. The prompt says where the text comes from
    /// (a dictation is mostly instructions to AI tools, a call is people talking) and asks, per item, for the kind,
    /// the spoken words it came from and how sure the model is.
    static let systemPrompt = """
    You find follow-ups in one conversation and propose them. Every proposal is only a suggestion: the user decides which ones become tasks. Propose only what a busy person would thank you for. When unsure, propose nothing.

    SOURCE — the first line of the input says which kind of conversation this is.

    SOURCE: dictation — one person, the user, speaking to the computer. Most dictation is the user instructing an AI assistant or a tool (write or fix code, change a website or a design, draft or translate text, research, review), or text dictated into another app (a message, an email, a prompt). That work is being done right now inside the computer: it is NOT a follow-up. From a dictation propose only:
    (a) asked_by_user — the user explicitly asks to be reminded, or to add a task, for later ("remind me to…", "add a task to…", "don't let me forget…", in any language);
    (b) mine — a real-world action the user must do later that involves a person, money or a date (call or meet someone, pay, sign, deliver something to someone) — never work for an AI tool or an app.
    A dictated message to someone ("Sam, please send me the report") is the user's own request to that person: propose nothing for it.

    SOURCE: call — a conversation between people. Each line starts with "Me:" (the user) or "Them:" (the other people; several people may share "Them:"). Propose:
    - mine — something the user committed to do, or a request to the user that the user accepted;
    - asked_by_user — the user (a "Me:" line) explicitly asks to be reminded or to add a task.
    Never propose another person's chores, what another person promised or offered to do for the user, or work agreed between other people: only what the user must do.

    NEVER PROPOSE:
    - a command to an AI assistant to act now ("investigate this", "explain how X works"), unless the user explicitly asks to be reminded later;
    - quoted, read-aloud, hypothetical or example phrases; a "remind me" said by someone else, a TV or a video;
    - status updates ("Sam is testing the build"), observations, ideas, wishes, advice, rhetorical questions, "we should discuss X";
    - small talk ("let's grab coffee sometime") unless a named person and a concrete place or time are agreed;
    - anything reported done, cancelled or changed later in the same conversation (honor the final decision);
    - the same work twice (propose it once), or anything already in EXISTING ACTION ITEMS.

    FIELDS — for every item:
    - description: a self-contained action, 4 to 15 words, starting with a verb, naming the object and the person if there is one ("Send the signed contract to Sam"). Resolve "it" / "that" from the conversation. No time words (they go in due_at). Write it in the language of the conversation.
    - kind: "mine" or "asked_by_user", as defined above.
    - evidence: the exact words from ONE fragment that show this item, at least 3 words, copied character for character in the language they were spoken. Never translate, paraphrase or fix them. For a call, copy the words without the "Me:" / "Them:" label.
    - due_at: ISO-8601 UTC with "Z", or null.
    - capture_confidence: 0 to 1 — how sure you are this is a real follow-up the user would want.
    - ownership_confidence: 0 to 1 — how sure you are that the user is the one who must act.
    - concrete_deliverable: true only when the item names a concrete action and object ("Send the signed contract to Sam"); false for vague ones ("Handle the Sarah thing", "Look into it", "Follow up").
    - real_world: true when the action happens outside this computer session — with a person, money or a date; false for work an AI tool or an app is being told to do.

    DUE DATE:
    - REFERENCE_TIME: if started_at is more than 7 days before the current time, anchor at the current time (a stale conversation being reprocessed); otherwise at started_at. "tomorrow" / "next Monday" resolve relative to REFERENCE_TIME.
    - "today" → REFERENCE_TIME's date, "tomorrow" → the next day, a weekday → its next occurrence, "next week" → +7 days.
    - "morning" → 9:00, "afternoon" → 14:00, "evening" → 18:00, "noon" → 12:00, "end of day" or no time → 23:59, "urgent" / "ASAP" → REFERENCE_TIME + 2 h.
    - Resolve in the user's time zone, then convert to UTC with "Z". No timing words → null.

    EXAMPLES:
    - SOURCE: dictation, "Remind me to renew the car insurance on Monday" → {"description": "Renew the car insurance policy", "kind": "asked_by_user", "evidence": "Remind me to renew the car insurance on Monday", "due_at": "<Monday 23:59 in UTC>", "capture_confidence": 0.95, "ownership_confidence": 0.95, "concrete_deliverable": true, "real_world": true}
    - SOURCE: dictation, "Make the header bigger and fix the pricing cards on mobile" → nothing (instructions to an AI tool).
    - SOURCE: dictation, "Sam, send me the report by Friday please" → nothing (a message the user is sending).
    - SOURCE: call, "Them: I'll send you the deck tonight, it's Priya by the way" → nothing (Priya's promise, not the user's task).
    - SOURCE: call, "Them: Remind me to call the moving company" → nothing (someone else's reminder).

    Propose at most five items, the most important first.

    Return JSON only, no prose, no markdown fences:
    {"tasks": [{"description": "...", "kind": "mine", "evidence": "...", "due_at": null, "capture_confidence": 0.9, "ownership_confidence": 0.9, "concrete_deliverable": true, "real_world": true}]}
    If nothing qualifies: {"tasks": []}
    """

    /// Internal, with the clock and time zone injectable, so
    /// `ExtractorPromptCharacterizationTests` can pin the exact text.
    func buildPrompt(
        fragments: [String],
        existing: [TaskItem],
        startedAt: Date,
        source: TaskCandidateRules.Source,
        route: ExtractionRoute,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        var parts: [String] = []
        let localBudget: Int? = route == .local ? route.unitLimit : nil

        let nowISO = ISO8601DateFormatter().string(from: now)
        let startedISO = ISO8601DateFormatter().string(from: startedAt)
        let tz = timeZone.identifier

        // REFERENCE_TIME hint — surfaces whether the conversation is recent or
        // stale so the LLM can apply the >7-day rule from the system prompt.
        let ageDays = now.timeIntervalSince(startedAt) / 86400
        let referenceHint = ageDays > 7
            ? "REFERENCE_TIME = current_time (conversation is \(Int(ageDays))d old, treat as reprocess)"
            : "REFERENCE_TIME = started_at (recent conversation, anchor due-dates here)"

        // FEAT-0005 — the source first: the rules differ for a dictation and a call.
        parts.append(source == .call ? "SOURCE: call" : "SOURCE: dictation")
        parts.append("Conversation started_at: \(startedISO)")
        parts.append("Current time: \(nowISO)")
        parts.append("Timezone: \(tz)")
        parts.append(referenceHint)
        parts.append("")

        if !existing.isEmpty {
            parts.append("EXISTING ACTION ITEMS FROM PAST \(dedupWindowDays) DAYS (do NOT duplicate):")
            let df = ISO8601DateFormatter()
            // ITER-051 review fix — see MemoryExtractor.buildPrompt: dedup
            // context is capped so it can't starve the transcript. ITER-081 —
            // on every route (the cloud ones were uncapped and then cut from
            // the head), in the units the proxy counts.
            var used = 0, shown = 0
            for t in existing {
                let dueStr = t.dueAt.map { df.string(from: $0) } ?? "no due"
                let status = t.completed ? "completed" : "pending"
                let line = "- \(t.taskDescription) (due: \(dueStr)) [\(status)]"
                if used + line.utf16.count > route.unitLimit * 3 / 10 { break }
                parts.append(line); used += line.utf16.count; shown += 1
            }
            if shown < existing.count { parts.append("(+\(existing.count - shown) more omitted)") }
            parts.append("")
        }

        parts.append(source == .call
            ? "Conversation fragments to analyze (ordered by time; Me: lines are the user, Them: lines are the other people):"
            : "Conversation fragments to analyze (ordered by time, all from the same user):")
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
        // ITER-081 — the cloud routes keep the whole meeting when it fits, and
        // its beginning and end when it does not; the end used to be cut off.
        guard localBudget != nil else {
            return PromptFit.fit(header: parts.joined(separator: "\n"), transcript: fragText,
                                 unitLimit: route.unitLimit)
        }
        parts.append(fragText)

        let combined = parts.joined(separator: "\n")
        if combined.count > 20000 { return String(combined.prefix(20000)) }
        return combined
    }

    // MARK: - Fetch helpers

    /// The prompt's dedup list: what was proposed or added in the last days (the rules check repeats on their own).
    private func fetchExistingTasks(sinceDays: Int, in ctx: ModelContext, now: Date) -> [TaskItem] {
        let cutoff = now.addingTimeInterval(-Double(sinceDays) * 86400)
        var desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed && $0.createdAt >= cutoff },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = 50
        return (try? ctx.fetch(desc)) ?? []
    }

    // MARK: - Response parsing

    /// One item of the answer. Lenient on types (a local model may quote numbers and booleans); strict on the
    /// description, as before. Fields a model leaves out stay nil — `TaskCandidateRules` decides what that means.
    private struct ItemJSON: Decodable {
        let description: String
        let kind: String?
        let evidence: String?
        let dueAt: String?
        let assignee: String?
        let captureConfidence: Double?
        let ownershipConfidence: Double?
        let concreteDeliverable: Bool?
        let realWorld: Bool?

        enum CodingKeys: String, CodingKey {
            case description, kind, evidence, assignee
            case dueAt = "due_at"
            case captureConfidence = "capture_confidence"
            case ownershipConfidence = "ownership_confidence"
            case concreteDeliverable = "concrete_deliverable"
            case realWorld = "real_world"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            description = try c.decode(String.self, forKey: .description)
            kind = Self.string(c, .kind)
            evidence = Self.string(c, .evidence)
            dueAt = Self.string(c, .dueAt)
            assignee = Self.string(c, .assignee)
            captureConfidence = Self.number(c, .captureConfidence)
            ownershipConfidence = Self.number(c, .ownershipConfidence)
            concreteDeliverable = Self.flag(c, .concreteDeliverable)
            realWorld = Self.flag(c, .realWorld)
        }

        private static func string(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
            (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil
        }
        private static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
            if let d = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil { return d }
            return string(c, key).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        private static func flag(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
            if let b = (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil { return b }
            switch string(c, key)?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
    }
    private struct ExtractionResult: Decodable {
        let tasks: [ItemJSON]
    }

    /// ITER-051 F1.7 — `nil` = unparseable LLM output (the caller keeps the
    /// conversation queued); `[]` = valid JSON with nothing to extract. An answer in the old shape (description,
    /// due date, assignee only) still parses; its items carry no kind and the rules drop them.
    /// Internal (not private) so `ExtractorParseOutcomeTests` pins the contract.
    func parseCandidates(_ response: String) -> [TaskCandidateRules.Candidate]? {
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

        return parsed.tasks.map { json in
            var due: Date? = nil
            if let raw = json.dueAt, !raw.isEmpty, raw != "null" {
                due = df.date(from: raw) ?? dfFrac.date(from: raw)
            }
            // ITER-013 — normalize assignee:
            // - empty/whitespace/"null" → nil (MY task)
            // - non-empty → trimmed + capitalized first letter, preserved as-is otherwise
            //   (never transliterated or translated)
            let assignee: String? = {
                guard let raw = json.assignee?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty, raw.lowercased() != "null" else { return nil }
                return raw.prefix(1).uppercased() + raw.dropFirst()
            }()
            return TaskCandidateRules.Candidate(description: json.description, kind: json.kind,
                                                evidence: json.evidence, dueAt: due, assignee: assignee,
                                                captureConfidence: json.captureConfidence,
                                                ownershipConfidence: json.ownershipConfidence,
                                                concreteDeliverable: json.concreteDeliverable,
                                                realWorld: json.realWorld)
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

    /// Internal (not private) so the opt-in replay (`TaskSuggestionReplayTests`) sends exactly what the app sends.
    func callProProxy(system: String, user: String, licenseKey: String) async throws -> String {
        let request = try ExtractionRoute.proAdviceRequest(system: system, user: user, licenseKey: licenseKey,
                                                           tier: Self.llmTier, serviceId: Self.llmServiceId)
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
