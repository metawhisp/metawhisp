import Foundation
import SwiftData

/// Extracts structured facts about the user from a FULL closed Conversation — not per-transcript.
///
/// Triggered on conversation close (dictation 10-min gap or meeting stop). Runs once
/// over all HistoryItems of the conversation so the LLM can:
/// - See conversation-wide context (not fragments in isolation)
/// - Apply USER-IS-SUBJECT filter (skip memories about third parties)
/// - Dedup repeated mentions of the same fact across fragments
///
/// spec://iterations/ITER-001#architecture.extractor
@MainActor
final class MemoryExtractor: ObservableObject {
    /// ITER-041 — memory extraction schema is complex enough
    /// (kind+text+confidence+evidence) that 8B-instant truncated the JSON
    /// in production (2026-05-28 17:15: `{"memories": [` cutoff). Moved to
    /// medium tier (gpt-oss-20b on Groq, $0.075/$0.30). Still ~7× cheaper
    /// than heavy. TaskExtractor with simpler schema stays on mini.
    static let llmTier: LLMTier = .medium
    static let llmServiceId: String = "MemoryExtractor"

    @Published var isRunning = false
    @Published var lastRun: Date?
    @Published var lastError: String?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?

    /// SB-1 — durable queue of conversations awaiting extraction. Replaces the
    /// silent `guard !isRunning` drop and survives relaunch (startup backfill).
    private let queue = ExtractionQueueStore(filename: "memory-extraction-queue.json")

    /// Min confidence for accepting a memory.
    private let minConfidence: Double = 0.7

    /// Max memories to insert per extraction.
    private let maxPerExtraction: Int = 2

    // ITER-053.1 — the `screenContext` dependency was dead wiring (stored,
    // never read: extraction runs on transcripts/DB, not the live screen).
    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Fire-and-forget extraction on the whole conversation. Called by ConversationGrouper
    /// after a conversation closes.
    func triggerOnConversationClose(conversationId: UUID) {
    NSLog("[MemoryExtractor] Conversation %@ closed — memories %@, queue depth %d", conversationId.uuidString.prefix(8) as CVarArg, settings.memoriesEnabled ? "on" : "off", queue.pending().count)
        guard settings.memoriesEnabled else { return }
        queue.enqueue(conversationId)
        Task { [weak self] in await self?.drainQueue() }
    }

    /// SB-1 — startup backfill: process conversations left queued by a previous
    /// session (app quit/crash before extraction finished). Call once after
    /// `configure(...)`.
    func backfillPending() {
        guard settings.memoriesEnabled, !queue.pending().isEmpty else { return }
        NSLog("[MemoryExtractor] Backfilling %d pending conversation(s)", queue.pending().count)
        Task { [weak self] in await self?.drainQueue() }
    }

    /// SB-1 — serial drain of the durable queue. `isRunning` guards re-entrancy
    /// (a second conversation closing while we work just enqueues; this pass
    /// picks it up — see `ExtractionQueueStore.drain`) and drives the UI status.
    private func drainQueue() async {
    NSLog("[MemoryExtractor] Drain requested — %d pending, running=%@, store=%@", queue.pending().count, isRunning ? "yes" : "no", StoreHealthSignal.shared.isHealthy ? "ok" : "degraded")
        guard !isRunning else { return }
        // ITER-049 A2 — never drain the durable queue against a degraded (empty
        // in-memory) store: it would mark queued conversations .completed and
        // rewrite the queue file, permanently dropping work whose real data is
        // safe in the preserved on-disk store. Stays queued for the next launch.
        guard StoreHealthSignal.shared.isHealthy else { return }
        isRunning = true
        defer { isRunning = false; lastRun = Date() }
        await queue.drain { id in await self.extractFromConversation(conversationId: id) }
        NSLog("[MemoryExtractor] Drain done — %d still pending", queue.pending().count)
    }

    /// Manual EXTRACT NOW button. Uses the most recent HistoryItem's conversation.
    func extractOnce() async {
        guard hasLLMAccess else {
            NSLog("[MemoryExtractor] No LLM access — skipping")
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
            NSLog("[MemoryExtractor] No recent conversation — skipping")
            return
        }
        queue.enqueue(convId)
        await drainQueue()
    }

    /// Core extraction — collect all transcripts for the conversation, send as one block.
    private func extractFromConversation(conversationId: UUID) async -> ExtractionOutcome {
    if !hasLLMAccess { NSLog("[MemoryExtractor] Convo %@ stays queued — no LLM access (no API key, not Pro, local model not loaded)", conversationId.uuidString.prefix(8) as CVarArg) }
        let llmStartedAt = Date()
        guard hasLLMAccess else { return .retryLater }

        guard let container = modelContainer else { return .retryLater }
        let ctx = ModelContext(container)

        // AUD-035 — fetch the WHOLE conversation (uncapped, oldest first) via the
        // shared, AUD-016-tested helper; the old inline 100-row cap silently
        // dropped late fragments, so extraction ran on a prefix. (Cloud paths get
        // the full block; the local route still caps at the model's input budget.)
        let items = StructuredGenerator.fetchHistoryItems(conversationId: conversationId, in: ctx)
        let fragments = items
            .map { $0.displayText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !fragments.isEmpty else { return .completed }
        let totalChars = fragments.reduce(0) { $0 + $1.count }
        if totalChars < 20 { NSLog("[MemoryExtractor] Convo %@ dequeued without extraction — %d fragments, %d chars (below the 20-char floor)", conversationId.uuidString.prefix(8) as CVarArg, fragments.count, totalChars) }
        guard totalChars >= 20 else { return .completed }

        let existing = fetchExistingMemories()
        let useLocal = LocalLLMService.shared.isReady
        let prompt = buildPrompt(fragments: fragments, existing: existing,
                                 localBudget: useLocal ? 6000 : nil)

        let sourceApp = items.last.flatMap { $0.source } ?? "conversation"
        let windowTitle: String? = nil  // on-close extraction has no real-time window context

        do {
            let response: String
            // ITER-039 — local LLM takes priority when loaded.
            if LocalLLMService.shared.isReady {
                NSLog("[MemoryExtractor] Extracting via local Phi (convo %@, %d fragments)",
                      conversationId.uuidString.prefix(8) as CVarArg, fragments.count)
                response = try await LocalLLMService.shared.completeBlocking(
                    system: Self.systemPrompt, user: prompt,
                    maxUserChars: 6000, maxTokens: 384   // F1.2 — was default 2000: transcript got cut after dedup context
                )
            } else if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                NSLog("[MemoryExtractor] Extracting via Pro proxy (convo %@, %d fragments, %d chars)",
                      conversationId.uuidString.prefix(8) as CVarArg, fragments.count, totalChars)
                response = try await callProProxy(system: Self.systemPrompt, user: prompt, licenseKey: licenseKey)
            } else {
                let apiKey = settings.activeAPIKey
                guard !apiKey.isEmpty else {
                    NSLog("[MemoryExtractor] No API key — skipping")
                    return .retryLater
                }
                let provider = LLMProvider(rawValue: settings.llmProvider) ?? .openai
                NSLog("[MemoryExtractor] Extracting via %@ API key (convo %@, %d fragments, %d chars)", provider.displayName, conversationId.uuidString.prefix(8) as CVarArg, fragments.count, totalChars)
                response = try await llm.complete(
                    system: Self.systemPrompt,
                    user: prompt,
                    apiKey: apiKey,
                    provider: provider
                )
            }

            // F1.7 — nil = garbage/truncated JSON (routine for local models):
            NSLog("[MemoryExtractor] LLM returned %d chars in %.1fs (convo %@)", response.count, Date().timeIntervalSince(llmStartedAt), conversationId.uuidString.prefix(8) as CVarArg)
            // keep the conversation queued instead of dequeuing it forever.
            guard let memories = parseResponse(response, sourceApp: sourceApp, windowTitle: windowTitle, conversationId: conversationId) else {
                lastError = "LLM returned unparseable JSON — will retry"
                return .failedAttempt   // counted — capped at maxFailedAttempts
            }
            guard !memories.isEmpty else {
                NSLog("[MemoryExtractor] No new memories from conversation %@", conversationId.uuidString.prefix(8) as CVarArg)
                return .completed
            }

            // Saying it out loud IS the confirmation: when a fact matches a
            // proposal the screen made earlier, confirm that row instead of
            // inserting a second copy of the same sentence.
            var pending = Self.pendingProposals(in: ctx)
            var insertedMemories: [UserMemory] = []
            var confirmedCount = 0
            for mem in memories where mem.confidence >= minConfidence {
                let text = mem.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if let idx = pending.firstIndex(where: {
                    $0.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(text) == .orderedSame
                }) {
                    let proposal = pending.remove(at: idx)
                    Self.confirm(proposal)   // saved with `ctx` below, not in a throwaway context
                    confirmedCount += 1
                    continue
                }
                ctx.insert(mem)
                insertedMemories.append(mem)
                if insertedMemories.count >= maxPerExtraction { break }
            }
            if confirmedCount > 0 {
                NSLog("[MemoryExtractor] %d screen proposals confirmed by the user saying them",
                      confirmedCount)
            }
            // SB-1: a swallowed save (try?) would return .completed and let the
            // queue drop the conversation though nothing persisted — the exact
            // silent loss this iteration fixes. `try` → throw → catch → .retryLater.
            try ctx.save()
            NSLog("[MemoryExtractor] Convo %@ — %d of %d candidates below confidence %.2f, insert cap %d", conversationId.uuidString.prefix(8) as CVarArg, memories.filter { $0.confidence < minConfidence }.count, memories.count, minConfidence, maxPerExtraction)
            NSLog("[MemoryExtractor] ✅ Extracted %d memories (inserted: %d) from conversation %@",
                  memories.count, insertedMemories.count, conversationId.uuidString.prefix(8) as CVarArg)

            // Fire-and-forget embedding for semantic RAG (ITER-008).
            AppDelegate.shared?.embeddingService.embedMemoriesInBackground(insertedMemories, in: ctx)

            // ITER-035 v2 — export each new memory to the Obsidian vault.
            // Fire-and-forget; exporter handles all gates (sync enabled, vault
            // path valid) and silently no-ops otherwise.
            if let exporter = AppDelegate.shared?.obsidianExporter {
                let ids = insertedMemories.map { $0.id }
                Task { @MainActor in
                    for id in ids {
                        await exporter.exportMemory(id)
                    }
                }
            }
            return .completed
        } catch {
            lastError = error.localizedDescription
            NSLog("[MemoryExtractor] ❌ Failed: %@", error.localizedDescription)
            return .failedAttempt   // counted — a conversation that always throws gets dropped after N tries
        }
    }

    // MARK: - Prompt

    /// Memory extraction prompt — on-conversation-close pattern.
    /// Input is a full conversation (multiple dictation fragments). Max 2 memories per extraction.
    /// Single-user desktop dictation: assignee check via linguistic USER-IS-SUBJECT rule.
    /// spec://iterations/ITER-001#architecture.extractor + ITER-024 (re-aligned with reference 2026-04-26)
    static let systemPrompt = """
    You are an expert memory curator. Extract high-quality, genuinely valuable memories from a full dictation conversation while filtering out trivial, mundane, or uninteresting content.

    CRITICAL CONTEXT:
    - You receive a FULL conversation composed of multiple dictation fragments ordered by time.
    - All fragments are from the SAME single User (no other speakers).
    - You are extracting memories about the User and people they directly mention.
    - Never use generic labels — when a name is spoken, use the name.

    IDENTITY RULES (CRITICAL):
    - Never invent family members without EXPLICIT evidence ("This is my daughter Jordan", "My son's name is...").
    - Recognize nicknames — don't create new people. Common nicknames ("Buddy", "Junior") are likely existing family.
    - Verify name spellings against existing memories before creating new entries (e.g. "Arman" when "Armaan" already exists → SAME person).
    - If uncertain about a person's identity, DO NOT extract the memory.

    CONVERSATION-WIDE CONTEXT:
    Treat the fragments as one thought stream:
    - If a later fragment CONTRADICTS or UPDATES an earlier one → prefer the later version.
    - If the same fact appears in multiple fragments → extract AT MOST ONCE.
    - If the User says something hypothetical/exploratory early on and walks it back later → do not extract.

    USER-IS-SUBJECT CHECK:
    Only extract memories where the USER is the subject, or someone directly in the User's network:
    - "Я живу в Берлине" / "I'm the CTO at Acme" → about User → EXTRACT.
    - "Мой друг Сэм живёт в Берлине" → Сэм in User's network with relationship → can EXTRACT.
    - "Сэм живёт в Берлине" (no relationship context) → about a third party → SKIP.
    - "В компании X ввели политику" (generic commentary) → not User-specific → SKIP.
    Do NOT extract memories about unrelated people or abstract entities.

    WORKFLOW (apply in order):
    1. FIRST: Read the ENTIRE conversation to understand context and identify who is speaking.
    2. SECOND: Identify actual names of people mentioned (use these instead of "Speaker X" / "someone").
    3. THIRD: Apply the CATEGORIZATION TEST below to every potential memory.
    4. FOURTH: Filter through STRICT QUALITY CRITERIA + NEVER-EXTRACT rules.
    5. FIFTH: Run LOGIC CHECK (sanity) and the BEFORE YOU OUTPUT double-check.

    THE CATEGORIZATION TEST (apply to EVERY potential memory):
    Q1: "Is this wisdom/advice FROM someone else that User can learn from?"
        → YES: INTERESTING memory. Format "Source: actionable insight" (e.g., "Rockwell: talk to paying customers, 30% will be real usecase").
        → NO: go to Q2.
    Q2: "Is this a fact ABOUT User — their opinions, projects, network, decisions?"
        → YES: SYSTEM memory. Start with "User".
        → NO: DO NOT extract.

    INTERESTING requires EXTERNAL source with attribution. User's own realization → SYSTEM, not INTERESTING.

    INCLUDE (SYSTEM) — facts worth storing:
    - User's own opinions, realizations, and discoveries ("User discovered productive hours are 5-7am")
    - User's preferences with reasoning ("User prefers Swift strict concurrency over legacy patterns")
    - Named projects/products User builds ("User builds MetaWhisp, a macOS voice-to-text app")
    - Named people in User's network with relationship ("User's cofounder Araf handles backend")
    - Concrete plans, decisions, commitments ("User decided to integrate Stripe billing")
    - Domain expertise or role ("User is CTO at Acme")
    - Skills via specific use case (NOT a tool list):
        ✅ "User uses Python for data analysis automation"
        ❌ "User knows programming"

    INCLUDE (INTERESTING) — only with attribution:
    ✅ "Paul Graham: startups should do things that don't scale"
    ✅ "Jamie (CTO): 90% of bugs come from async race conditions"
    ✅ "Rockwell: talk to paying customers, 30% will be real usecase"
    ✅ "YC advice: find competitors of your most successful customers"

    NEVER EXTRACT (Absolute Rules — restored 8-category list):
    1. NEWS & ANNOUNCEMENTS — product releases, acquisitions, feature launches, company news.
       ❌ "Company X acquired startup Y" / "OpenAI released a new model" / "Apple announced…"
    2. GENERAL KNOWLEDGE — science facts, geography, statistics not about User.
       ❌ "Light travels at 186,000 miles per second" / "Certain plants are toxic to pets"
    3. PRODUCT DOCUMENTATION — how features work, technical specs, capabilities.
       ❌ "Feature X enables automated workflows" / "The API can process documents"
    4. CUSTOMER / COMPANY FACTS — unless User directly involved with specific outcome.
       ❌ "Acme Corp is evaluating new software" / "BigCo delayed their rollout"
    5. INTERNAL METRICS — survey rates, deal sizes, percentages, team statistics.
       ❌ "Team survey response rate is 83%" / "Average deal size is $30K"
    6. ORG RESTRUCTURING — team moves, role changes, temporary assignments.
       ❌ "User is merging teams" / "The marketing team is moving to…"
    7. COLLEAGUE FACTS WITHOUT RELATIONSHIP — must state how they relate to User.
       ❌ "Alex is a senior engineer at the company" (no relationship)
       ✅ "Alex reports to User and leads the backend team" (relationship stated)
    8. GENERIC RELATIONSHIPS — "Has a friend named X" without meaningful context.
       ❌ "User has a friend named Mike"
       ✅ "Mike is User's running partner training for marathons"

    Plus the trivial-preferences / generic-activities classics:
    - "Likes coffee" / "Enjoys reading" / "Prefers blue"
    - "Went to the gym" / "Had lunch with a friend" / "Watched a movie"
    - "Attended a meeting" / "Worked on a project" (without specifics)

    TEMPORAL BAN — NEVER use "Thursday", "tomorrow", "next week", "January 15th". Memories must be TIMELESS.
    If transcript mentions scheduled events, extract the relationship/role context, NOT the time.
    ✅ "Mike Johnson is head of enterprise sales"
    ❌ "Client meeting on Thursday at 2pm"

    BANNED LANGUAGE — DO NOT USE:
    - Hedging: "likely", "possibly", "seems to", "appears to", "may be", "might", "probably".
    - Filler phrases: "indicating a…", "suggesting a…", "reflecting a…", "showcasing", "demonstrating a…".
    - Transient verbs: "is working on", "is building", "is developing", "is testing", "is focusing on".
    - Org-change verbs: "is merging", "is reorganizing", "is restructuring", "plans to", "considering".
    If you find yourself using these — the memory is too uncertain or transient. DO NOT extract.

    DEDUPLICATION (CRITICAL):
    - You are given existing memories. SCAN THEM ALL.
    - FORBIDDEN to extract a memory semantically redundant with an existing one.
      "Likes coffee" vs "Enjoys drinking coffee" → REJECT (redundant).
    - EXCEPTION: if new memory CONTRADICTS or UPDATES existing, EXTRACT IT.
      Existing "Works at Google" + transcript says "Left Google, joined OpenAI" → EXTRACT.

    CONSOLIDATION CHECK (before creating a new memory):
    1. Does a memory about this topic / person already exist?
    2. If YES: is the new info significant enough to warrant a separate memory, or would it fragment the topic?
    3. PREFER fewer, richer memories over many fragments. If existing already covers AWS hosting + AWS deploys, do NOT add "User uses AWS Lambda".

    LOGIC CHECK (Sanity Test):
    Before extracting, verify the fact is logically possible:
    - Age math: don't claim 40 years experience for someone who appears to be ~40 years old.
    - Family consistency: don't create children that contradict existing family structure.
    - Location consistency: don't claim multiple contradictory home locations.
    - Career consistency: don't claim conflicting job titles or employers simultaneously.
    If a fact seems mathematically impossible or contradicts existing memories — DO NOT extract.

    BEFORE YOU OUTPUT — MANDATORY DOUBLE-CHECK:
    Reject any memory matching these patterns:
    - "User expressed [feeling] about X" → DELETE
    - "User discussed X" or "talked about Y" → DELETE
    - "User mentioned that [obvious fact]" → DELETE
    - "User thinks/believes/feels X" → DELETE
    - "User is working on / is building / is focusing on X" → DELETE (transient)
    - "User has a friend named X" without relationship context → DELETE

    FORMAT: Each memory ≤ 15 words. Start SYSTEM facts with "User". Start INTERESTING with "Source:".

    OUTPUT LIMITS (MAXIMUMS, not targets):
    - AT MOST 2 memories total per extraction (most transcripts should yield 0-1).
    - Many transcripts will yield 0 memories — NORMAL AND EXPECTED.
    - Better to return [] than to include low-quality memories.
    - DEFAULT TO EMPTY LIST.

    ENRICHMENT FIELDS (REQUIRED for every memory):
    - `headline`: ≤5 word display label. Subject-led. Examples:
        content "User builds ChatApp, an AI ChatGPT wrapper" → headline "ChatApp product"
        content "User's cofounder Araf handles backend" → headline "Araf cofounder backend"
        content "User decided to integrate Stripe billing" → headline "Stripe billing decision"
    - `reasoning`: 1 sentence WHY this is being stored. Cite the source moment.
        Examples:
        "Mentioned as primary product when describing current work."
        "Stated as a Q2 decision during marketing strategy discussion."
        "Named as a recurring 1-on-1 contact in standup notes."
    - `tags`: 1-3 short tags from {work, personal, network, decision, preference, role, project, tool, learning, health, finance}.

    STRUCTURED-EXTRACTION FIELDS (added 2026-04-28 — fix for noisy ASR fragments
    leaking into MetaChat answers about specific people/projects). When a memory
    is clearly ABOUT a specific entity, ALSO populate these so MetaChat surfaces
    a clean line instead of quoting raw transcript:
    - `kind`: one of "person" / "project" / "decision" / "preference" / "fact"
    - `subject`: canonical name of the entity (full name for person, name for
      project). Omit for kind="fact".
    - `characterization`: ≤15-word ASR-NOISE-FREE one-liner describing the
      subject. NO direct quoting of transcript fragments — paraphrase. Examples:
        · person  Sam Smith     → "community building partner"
        · person  Alex                → "backend engineer at Acme"
        · project MetaWhisp           → "macOS voice-to-text + AI assistant app"
        · decision (no subject)       → omit subject, use content for the decision

    Return JSON:
    {"memories": [{
      "content": "...",
      "headline": "≤5 words",
      "reasoning": "why we are storing this, cite the source moment",
      "category": "system|interesting",
      "confidence": 0.0-1.0,
      "tags": ["tag1", "tag2"],
      "kind": "person|project|decision|preference|fact",
      "subject": "Canonical Name",
      "characterization": "clean one-liner ≤15 words"
    }]}

    `kind`/`subject`/`characterization` are OPTIONAL — omit if uncertain.

    If nothing passes: {"memories": []}

    CRITICAL OUTPUT RULE: Respond with ONLY the JSON object. No translation of the transcript. No explanation. No preamble like "Since the transcript is in Russian...". No markdown fences. Just the raw JSON.
    """

    /// `localBudget` (ITER-051 review fix): the dedup block comes FIRST in
    /// the prompt, so with the local model's prefix-keep cap an uncapped
    /// existing-memories list starved the transcript to zero — the model
    /// extracted from dedup context alone. When set, existing gets ≤30% of
    /// the budget and the transcript owns the rest (head+tail).
    /// The whole prompt's ceiling. The Pro proxy refuses more than 32 000
    /// (`LLMRequestBody.maxPromptChars`); this stays well under it.
    private let maxPromptChars = 20_000

    private func buildPrompt(fragments: [String], existing: [UserMemory], localBudget: Int? = nil) -> String {
        var parts: [String] = []

        // The known-facts block keeps its share on EVERY path. It used to be
        // written uncapped whenever `localBudget` was nil — both cloud routes
        // — and the finished prompt was then cut from the head at 20 000
        // characters, which could leave the transcript out of its own
        // extraction entirely (audit, 2026-09-06, P1).
        if !existing.isEmpty {
            parts.append("Existing memories you already know about User (DO NOT repeat or duplicate):")
            let share = MemoryPromptBudget.split(total: localBudget ?? maxPromptChars).existing
            parts.append(contentsOf: MemoryPromptBudget.fit(existing: existing.map { "- \($0.content)" },
                                                            into: share))
            parts.append("")
        }

        parts.append("Conversation fragments to analyze (ordered by time, all from the same User):")
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
        if combined.count > maxPromptChars { return String(combined.prefix(maxPromptChars)) }
        return combined
    }

    // MARK: - Fetch helpers

    /// Confirmed memories only — this list tells the model "you already know
    /// this, do not repeat it". A pending screen proposal is NOT known: if it
    /// were in here, the user saying the same thing out loud would be
    /// suppressed as a duplicate while the proposal sat unconfirmed, and the
    /// assistant would keep forgetting something it had been told twice
    /// (Codex).
    private func fetchExistingMemories(limit: Int = 1000) -> [UserMemory] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed && !$0.needsReview },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        return (try? ctx.fetch(desc)) ?? []
    }

    /// Pending screen proposals, for the confirm-by-saying-it path.
    /// Proposals waiting for the user, read INTO THE CALLER'S CONTEXT.
    ///
    /// This used to make its own `ModelContext`, so confirming a proposal —
    /// clearing `needsReview` — happened on objects belonging to a context
    /// nobody saved. The confirmation vanished, and the memory was skipped
    /// from that extraction as well, so the fact was lost twice (audit,
    /// 2026-09-06, P1).
    static func pendingProposals(in ctx: ModelContext, limit: Int = 500) -> [UserMemory] {
        var desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed && $0.needsReview },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        return (try? ctx.fetch(desc)) ?? []
    }

    /// The user said it out loud, so it is no longer a proposal. The caller
    /// saves the context this object belongs to.
    static func confirm(_ proposal: UserMemory) {
        proposal.needsReview = false
        proposal.updatedAt = Date()
    }


    // MARK: - Response parsing

    private struct MemoryJSON: Decodable {
        let content: String
        let category: String
        let confidence: Double
        let headline: String?
        let reasoning: String?
        let tags: [String]?
        // Structured-extraction fields (2026-04-28). When LLM identifies that
        // a memory is ABOUT a specific entity, these clean it up so MetaChat
        // can answer "who is X" without quoting noisy raw transcripts.
        let kind: String?            // "person" | "project" | "decision" | "preference" | "fact"
        let subject: String?         // canonical name of the entity (for person / project)
        let characterization: String? // ≤15-word ASR-noise-free description
    }
    private struct ExtractionResult: Decodable {
        let memories: [MemoryJSON]
    }

    /// ITER-051 F1.7 — `nil` = unparseable LLM output (the caller keeps the
    /// conversation queued); `[]` = valid JSON with nothing to extract.
    /// Internal (not private) so `ExtractorParseOutcomeTests` pins the contract.
    func parseResponse(_ response: String, sourceApp: String, windowTitle: String?, conversationId: UUID?) -> [UserMemory]? {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONDecoder().decode(ExtractionResult.self, from: data) else {
            NSLog("[MemoryExtractor] ⚠️ JSON parse failed — %d chars, starts with %@", extracted.count, extracted.first.map { String($0) } ?? "(empty)")
            return nil
        }

        return parsed.memories.compactMap { json -> UserMemory? in
            let wordCount = json.content.split(separator: " ").count
            guard wordCount <= 15 else {
                NSLog("[MemoryExtractor] ⚠️ rejected memory — %d words, %d chars", wordCount, json.content.count)
                return nil
            }
            guard ["system", "interesting"].contains(json.category) else {
                NSLog("[MemoryExtractor] ⚠️ rejected memory — bad category '%@' (%d chars)", json.category, json.content.count)
                return nil
            }
            let mem = UserMemory(
                content: json.content,
                category: json.category,
                sourceApp: sourceApp,
                confidence: json.confidence,
                windowTitle: windowTitle,
                contextSummary: nil,
                conversationId: conversationId
            )
            // Enrichment fields (ITER-010). Trim + validate optional values.
            mem.headline = json.headline?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            mem.reasoning = json.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if let tags = json.tags, !tags.isEmpty {
                mem.tagsCSV = tags
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
                    .joined(separator: ",")
                    .nilIfEmpty
            }
            // Structured fields (2026-04-28) — only persist if LLM produced
            // a known kind. Anything else falls back to plain content+category.
            if let k = json.kind?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
               ["person", "project", "decision", "preference", "fact"].contains(k) {
                mem.kind = k
            }
            mem.subject = json.subject?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            mem.characterization = json.characterization?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return mem
        }
    }

    /// Extract the first balanced JSON object from a string that may have leading/trailing prose.
    /// Handles cases like: "Since the transcript is in Russian... {\"memories\": [...]} ."
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
                if depth == 0 {
                    return String(stripped[start...idx])
                }
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
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { NSLog("[MemoryExtractor] Pro proxy refused — HTTP %d (%@), %d-byte body", http.statusCode, http.statusCode == 401 || http.statusCode == 403 ? "license rejected" : (http.statusCode == 429 ? "rate limited" : (http.statusCode >= 500 ? "proxy or model error" : "bad request")), data.count) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ProcessingError.apiError("Memory proxy HTTP \(http.statusCode)")
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

private extension String {
    /// Helper — return nil instead of empty string so SwiftData stores NULL.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
