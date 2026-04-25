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
    @Published var isRunning = false
    @Published var lastRun: Date?
    @Published var lastError: String?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private weak var screenContext: ScreenContextService?
    private var modelContainer: ModelContainer?

    /// Min confidence for accepting a memory.
    private let minConfidence: Double = 0.7

    /// Max memories to insert per extraction.
    private let maxPerExtraction: Int = 2

    func configure(screenContext: ScreenContextService, modelContainer: ModelContainer) {
        self.screenContext = screenContext
        self.modelContainer = modelContainer
    }

    /// Fire-and-forget extraction on the whole conversation. Called by ConversationGrouper
    /// after a conversation closes.
    func triggerOnConversationClose(conversationId: UUID) {
        guard settings.memoriesEnabled else { return }
        Task { [weak self] in
            await self?.extractFromConversation(conversationId: conversationId)
        }
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
        await extractFromConversation(conversationId: convId)
    }

    /// Core extraction — collect all transcripts for the conversation, send as one block.
    private func extractFromConversation(conversationId: UUID) async {
        guard !isRunning else { return }
        guard hasLLMAccess else { return }

        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)

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

        let existing = fetchExistingMemories()
        let prompt = buildPrompt(fragments: fragments, existing: existing)

        let sourceApp = items.last.flatMap { $0.source } ?? "conversation"
        let windowTitle: String? = nil  // on-close extraction has no real-time window context

        do {
            let response: String
            if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                NSLog("[MemoryExtractor] Extracting via Pro proxy (convo %@, %d fragments, %d chars)",
                      conversationId.uuidString.prefix(8) as CVarArg, fragments.count, totalChars)
                response = try await callProProxy(system: Self.systemPrompt, user: prompt, licenseKey: licenseKey)
            } else {
                let apiKey = settings.activeAPIKey
                guard !apiKey.isEmpty else {
                    NSLog("[MemoryExtractor] No API key — skipping")
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

            let memories = parseResponse(response, sourceApp: sourceApp, windowTitle: windowTitle, conversationId: conversationId)
            guard !memories.isEmpty else {
                NSLog("[MemoryExtractor] No new memories from conversation %@", conversationId.uuidString.prefix(8) as CVarArg)
                return
            }

            var insertedMemories: [UserMemory] = []
            for mem in memories where mem.confidence >= minConfidence {
                ctx.insert(mem)
                insertedMemories.append(mem)
                if insertedMemories.count >= maxPerExtraction { break }
            }
            try? ctx.save()
            NSLog("[MemoryExtractor] ✅ Extracted %d memories (inserted: %d) from conversation %@",
                  memories.count, insertedMemories.count, conversationId.uuidString.prefix(8) as CVarArg)

            // Fire-and-forget embedding for semantic RAG (ITER-008).
            AppDelegate.shared?.embeddingService.embedMemoriesInBackground(insertedMemories, in: ctx)
        } catch {
            lastError = error.localizedDescription
            NSLog("[MemoryExtractor] ❌ Failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Prompt

    /// Memory extraction prompt — on-conversation-close pattern.
    /// Input is a full conversation (multiple dictation fragments). Max 2 memories per extraction.
    /// Single-user desktop dictation: assignee check via linguistic USER-IS-SUBJECT rule.
    /// spec://iterations/ITER-001#architecture.extractor
    static let systemPrompt = """
    You are an expert memory curator. Extract high-quality, genuinely valuable memories from a full dictation conversation while filtering out trivial, mundane, or uninteresting content.

    CRITICAL CONTEXT:
    - You receive a FULL conversation composed of multiple dictation fragments ordered by time.
    - All fragments are from the SAME single User (no other speakers).
    - You are extracting memories about the User and people they directly mention.
    - Never use generic labels — when a name is spoken, use the name.

    CONVERSATION-WIDE CONTEXT:
    Treat the fragments as one thought stream:
    - If a later fragment CONTRADICTS or UPDATES an earlier one → prefer the later version.
    - If the same fact appears in multiple fragments → extract AT MOST ONCE.
    - If the User says something hypothetical/exploratory early on and walks it back later → do not extract.

    USER-IS-SUBJECT CHECK:
    Only extract memories where the USER is the subject, or someone directly in the User's network:
    - "Я живу в Берлине" / "I'm the CTO at Acme" → about User → EXTRACT.
    - "Мой друг Паша живёт в Берлине" → Паша in User's network with relationship → can EXTRACT.
    - "Паша живёт в Берлине" (no relationship context) → about a third party → SKIP.
    - "В компании X ввели политику" (generic commentary) → not User-specific → SKIP.
    Do NOT extract memories about unrelated people or abstract entities.

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

    INCLUDE (INTERESTING) — only with attribution:
    - "Paul Graham: startups should do things that don't scale"
    - "Jamie (CTO): 90% of bugs come from async race conditions"

    STRICT EXCLUSION — DO NOT extract:
    - Trivial preferences ("likes coffee", "enjoys reading")
    - Generic activities ("had a meeting", "went to gym")
    - Common knowledge ("exercise is good for health")
    - Vague statements ("had an interesting conversation", "learned something new")
    - Anything visible in UI/app names without context
    - Facts about unrelated people just mentioned ("Sarah is a marine biologist" — only extract if she's in User's network with relationship)

    TEMPORAL BAN — NEVER use "Thursday", "tomorrow", "next week", "January 15th". Memories must be TIMELESS.
    If transcript mentions scheduled events, extract the relationship/role context, NOT the time.

    TRANSIENT VERB BAN — DO NOT USE:
    "is working on", "is building", "is developing", "is testing", "is focusing on", "is merging", "plans to"
    These become stale. Use concrete completed facts or durable decisions instead.

    HEDGING BAN — DO NOT USE: "likely", "possibly", "seems to", "appears to", "may be", "might", "probably".
    If you need to hedge, the memory is too uncertain — DO NOT extract.

    DEDUPLICATION (CRITICAL):
    - You are given existing memories. SCAN THEM ALL.
    - FORBIDDEN to extract a memory semantically redundant with an existing one.
      "Likes coffee" vs "Enjoys drinking coffee" → REJECT (redundant)
    - EXCEPTION: if new memory CONTRADICTS or UPDATES existing, EXTRACT IT.
      Existing "Works at Google" + transcript says "Left Google, joined OpenAI" → EXTRACT.

    BEFORE YOU OUTPUT — MANDATORY DOUBLE-CHECK:
    Reject any memory matching these patterns:
    - "User expressed [feeling] about X" → DELETE
    - "User discussed X" or "talked about Y" → DELETE
    - "User mentioned that [obvious fact]" → DELETE
    - "User thinks/believes/feels X" → DELETE

    FORMAT: Each memory ≤ 15 words. Start SYSTEM facts with "User". Start INTERESTING with "Source:".

    OUTPUT LIMITS (MAXIMUMS, not targets):
    - AT MOST 2 memories total per extraction (most transcripts should yield 0-1).
    - Many transcripts will yield 0 memories — NORMAL AND EXPECTED.
    - Better to return [] than to include low-quality memories.
    - DEFAULT TO EMPTY LIST.

    ENRICHMENT FIELDS (REQUIRED for every memory):
    - `headline`: ≤6 word display label. Subject-led. Examples:
        content "User builds Overchat, an AI ChatGPT wrapper" → headline "Overchat product"
        content "User's cofounder Araf handles backend" → headline "Araf — cofounder, backend"
        content "User decided to integrate Stripe billing" → headline "Stripe billing decision"
    - `reasoning`: 1 sentence WHY this is being stored. Cite the source moment.
        Examples:
        "Mentioned as primary product when describing current work."
        "Stated as a Q2 decision during marketing strategy discussion."
        "Named as a recurring 1-on-1 contact in standup notes."
    - `tags`: 1-3 short tags from {work, personal, network, decision, preference, role, project, tool, learning, health, finance}.

    Return JSON:
    {"memories": [{
      "content": "...",
      "headline": "≤6 words",
      "reasoning": "why we are storing this, cite the source moment",
      "category": "system|interesting",
      "confidence": 0.0-1.0,
      "tags": ["tag1", "tag2"]
    }]}

    If nothing passes: {"memories": []}

    CRITICAL OUTPUT RULE: Respond with ONLY the JSON object. No translation of the transcript. No explanation. No preamble like "Since the transcript is in Russian...". No markdown fences. Just the raw JSON.
    """

    private func buildPrompt(fragments: [String], existing: [UserMemory]) -> String {
        var parts: [String] = []

        // Existing memories passed ALL (not windowed) — up to 1000 for robust dedup.
        if !existing.isEmpty {
            parts.append("Existing memories you already know about User (DO NOT repeat or duplicate):")
            for m in existing {
                parts.append("- \(m.content)")
            }
            parts.append("")
        }

        parts.append("Conversation fragments to analyze (ordered by time, all from the same User):")
        for (i, frag) in fragments.enumerated() {
            parts.append("--- fragment \(i + 1) ---")
            parts.append(frag)
        }

        let combined = parts.joined(separator: "\n")
        if combined.count > 20000 { return String(combined.prefix(20000)) }
        return combined
    }

    // MARK: - Fetch helpers

    /// All non-dismissed memories.
    private func fetchExistingMemories(limit: Int = 1000) -> [UserMemory] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        return (try? ctx.fetch(desc)) ?? []
    }

    // MARK: - Response parsing

    private struct MemoryJSON: Decodable {
        let content: String
        let category: String
        let confidence: Double
        let headline: String?
        let reasoning: String?
        let tags: [String]?
    }
    private struct ExtractionResult: Decodable {
        let memories: [MemoryJSON]
    }

    private func parseResponse(_ response: String, sourceApp: String, windowTitle: String?, conversationId: UUID?) -> [UserMemory] {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else { return [] }
        guard let parsed = try? JSONDecoder().decode(ExtractionResult.self, from: data) else {
            NSLog("[MemoryExtractor] ⚠️ JSON parse failed: %@", String(extracted.prefix(200)))
            return []
        }

        return parsed.memories.compactMap { json -> UserMemory? in
            let wordCount = json.content.split(separator: " ").count
            guard wordCount <= 15 else {
                NSLog("[MemoryExtractor] ⚠️ Rejected memory (>15 words, %d): %@", wordCount, json.content)
                return nil
            }
            guard ["system", "interesting"].contains(json.category) else {
                NSLog("[MemoryExtractor] ⚠️ Rejected memory (bad category '%@'): %@", json.category, json.content)
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

        let body: [String: Any] = ["system": system, "user": user]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ProcessingError.apiError("Memory proxy HTTP \(http.statusCode)")
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

private extension String {
    /// Helper — return nil instead of empty string so SwiftData stores NULL.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
