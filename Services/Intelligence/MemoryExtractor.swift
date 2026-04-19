import Foundation
import SwiftData

/// Extracts structured facts about the user from voice transcripts (Omi-aligned).
/// Triggered on each completed voice transcription (≥20 chars) — same pattern as AdviceService.
/// Screen context is NOT input — Omi reference uses voice conversations, not screen OCR (garbage in → garbage out).
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

    /// Min confidence for accepting a memory (Omi default 0.7).
    private let minConfidence: Double = 0.7

    /// Max memories to insert per extraction (Omi caps at 2 per conversation).
    private let maxPerExtraction: Int = 2

    func configure(screenContext: ScreenContextService, modelContainer: ModelContainer) {
        self.screenContext = screenContext
        self.modelContainer = modelContainer
    }

    /// Fire-and-forget memory extraction triggered by a completed voice transcription.
    /// Mirrors AdviceService.triggerOnTranscription — runs async, respects `memoriesEnabled` toggle.
    func triggerOnTranscription(text: String, source: String, conversationId: UUID? = nil) {
        guard settings.memoriesEnabled else { return }
        guard text.count >= 20 else { return }
        Task { [weak self] in
            await self?.extract(transcript: text, source: source, conversationId: conversationId)
        }
    }

    /// Run one extraction cycle on the most recent transcript in history (EXTRACT NOW button).
    func extractOnce() async {
        guard hasLLMAccess else {
            NSLog("[MemoryExtractor] No LLM access — skipping")
            return
        }
        let recent = fetchRecentTranscripts(limit: 1)
        guard let latest = recent.first, latest.count >= 20 else {
            NSLog("[MemoryExtractor] No recent transcript (need ≥20 chars) — skipping")
            return
        }
        await extract(transcript: latest, source: "manual", conversationId: nil)
    }

    /// Core extraction — voice transcript → LLM → persist up to 2 memories.
    private func extract(transcript: String, source: String, conversationId: UUID?) async {
        guard !isRunning else { return }
        guard hasLLMAccess else { return }

        isRunning = true
        defer {
            isRunning = false
            lastRun = Date()
        }

        let existing = fetchExistingMemories()
        let prompt = buildPrompt(transcript: transcript, existing: existing)

        do {
            let response: String
            if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                NSLog("[MemoryExtractor] Extracting via Pro proxy")
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

            let sourceApp = screenContext?.recentContexts.last?.appName ?? source
            let windowTitle = screenContext?.recentContexts.last?.windowTitle
            let memories = parseResponse(response, sourceApp: sourceApp, windowTitle: windowTitle, conversationId: conversationId)
            guard !memories.isEmpty else {
                NSLog("[MemoryExtractor] No new memories this cycle")
                return
            }

            // Persist only high-confidence, cap at maxPerExtraction (Omi caps at 2).
            if let container = modelContainer {
                let ctx = ModelContext(container)
                var insertedCount = 0
                for mem in memories where mem.confidence >= minConfidence {
                    ctx.insert(mem)
                    insertedCount += 1
                    if insertedCount >= maxPerExtraction { break }
                }
                try? ctx.save()
                NSLog("[MemoryExtractor] ✅ Extracted %d memories (inserted: %d)", memories.count, insertedCount)
            }
        } catch {
            lastError = error.localizedDescription
            NSLog("[MemoryExtractor] ❌ Failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Prompt

    /// Omi-aligned memory extraction prompt. Adapted from BasedHardware/omi backend/utils/prompts.py:12.
    /// Input is a voice transcript (not screen OCR). Max 2 memories per extraction. 15 words each.
    /// spec://iterations/ITER-001#architecture.extractor
    static let systemPrompt = """
    You are an expert memory curator. Extract high-quality, genuinely valuable memories from a voice transcript while filtering out trivial, mundane, or uninteresting content.

    CRITICAL CONTEXT:
    - You are extracting memories about the User (who dictated this transcript).
    - Focus on information about the User and people they directly mention.
    - Never use generic labels — when a name is spoken, use the name.

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
    - Concrete plans, decisions, commitments ("User decided to integrate Omi open-source API")
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

    Return JSON:
    {"memories": [{"content": "...", "category": "system|interesting", "confidence": 0.0-1.0}]}

    If nothing passes: {"memories": []}

    CRITICAL OUTPUT RULE: Respond with ONLY the JSON object. No translation of the transcript. No explanation. No preamble like "Since the transcript is in Russian...". No markdown fences. Just the raw JSON.
    """

    private func buildPrompt(transcript: String, existing: [UserMemory]) -> String {
        var parts: [String] = []

        // Existing memories passed ALL (not windowed) — Omi passes up to 1000 for robust dedup.
        // UserMemory corpus is small (< 100 typical), no budget concern.
        if !existing.isEmpty {
            parts.append("Existing memories you already know about User (DO NOT repeat or duplicate):")
            for m in existing {
                parts.append("- \(m.content)")
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

    /// All non-dismissed memories (Omi passes the full corpus up to 1000 for robust semantic dedup).
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

    private func fetchRecentTranscripts(limit: Int) -> [String] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<HistoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        let items = (try? ctx.fetch(desc)) ?? []
        return items.map { $0.displayText }
    }

    // MARK: - Response parsing

    private struct MemoryJSON: Decodable {
        let content: String
        let category: String
        let confidence: Double
    }
    private struct ExtractionResult: Decodable {
        let memories: [MemoryJSON]
    }

    private func parseResponse(_ response: String, sourceApp: String, windowTitle: String?, conversationId: UUID?) -> [UserMemory] {
        // LLM sometimes prepends prose ("Since the transcript is in Russian, I'll translate first...")
        // before the JSON despite prompt rules. Extract the JSON substring instead of trusting the full response.
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
            return UserMemory(
                content: json.content,
                category: json.category,
                sourceApp: sourceApp,
                confidence: json.confidence,
                windowTitle: windowTitle,
                contextSummary: nil,
                conversationId: conversationId
            )
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
