import Foundation
import SwiftData

/// Generates AI advice/suggestions based on screen context and recent transcriptions.
/// Uses the existing OpenAIService (Pro) or can work with local LLM when available.
@MainActor
final class AdviceService: ObservableObject {
    @Published var latestAdvice: AdviceItem?
    @Published var isGenerating = false
    /// Last error surfaced from a generation attempt (network, HTTP, parse).
    /// UI reads this so button feedback isn't a lie.
    @Published var lastError: String?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private weak var screenContext: ScreenContextService?
    private var modelContainer: ModelContainer?
    /// ITER-022 G3 — memory-weave. When wired, advice prompt includes top-N
    /// memories ranked by cosine similarity to the current screen context.
    /// Lets LLM connect "user opens Stripe" + stored fact "user runs Overchat
    /// which uses Stripe billing" → category-specific advice referencing prior
    /// context. Fallback: most-recent N memories when no embedding available.
    weak var embeddingService: EmbeddingService?

    private var timerTask: Task<Void, Never>?

    func configure(screenContext: ScreenContextService, modelContainer: ModelContainer) {
        self.screenContext = screenContext
        self.modelContainer = modelContainer
    }

    /// Trigger advice after a transcription completes (non-periodic event trigger).
    func triggerOnTranscription(text: String, source: String) {
        guard settings.adviceEnabled, hasLLMAccess else { return }
        guard let contexts = screenContext?.recentContexts, !contexts.isEmpty else { return }

        Task {
            _ = await generateAdvice(extraContext: "Recent transcription (\(source)): \(String(text.prefix(500)))")
        }
    }

    /// True if we can call an LLM: either user has their own API key, or they're Pro (server proxy).
    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty || LicenseService.shared.isPro
    }

    /// Start periodic advice generation.
    func startPeriodicAdvice(interval: TimeInterval = 900) { // 15 min default
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                await self.generateAdvice()
            }
        }
        NSLog("[Advice] ✅ Periodic advice started (interval: %.0fs)", interval)
    }

    func stopPeriodicAdvice() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Generate advice based on current context.
    @discardableResult
    func generateAdvice(extraContext: String? = nil) async -> AdviceItem? {
        guard !isGenerating else { return nil }
        guard hasLLMAccess else {
            NSLog("[Advice] No LLM access — skipping (need API key or Pro)")
            return nil
        }
        guard let contexts = screenContext?.recentContexts, !contexts.isEmpty else {
            NSLog("[Advice] No screen context available")
            return nil
        }

        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        // Build context: screen activity + transcripts + memories + previous advice
        // spec://iterations/ITER-001#architecture.advice-prompt
        // ITER-022 G3 — async because memory ranking can call embeddings endpoint.
        let contextBlock = await buildAdviceUserContext(
            contexts: contexts,
            extraContext: extraContext
        )

        do {
            // ITER-022 G4 — pick prompt based on coach-mode toggle. Read at fire
            // time so toggle changes take effect immediately, not on next launch.
            let prompt = Self.activePrompt
            let mode = settings.adviceCoachMode ? "coach" : "standard"
            let response: String
            if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                NSLog("[Advice] Generating via Pro proxy (mode=%@)", mode)
                response = try await callProProxy(system: prompt, user: contextBlock, licenseKey: licenseKey)
            } else {
                let apiKey = settings.activeAPIKey
                guard !apiKey.isEmpty else {
                    NSLog("[Advice] No API key — skipping")
                    return nil
                }
                let provider = LLMProvider(rawValue: settings.llmProvider) ?? .openai
                NSLog("[Advice] Generating via direct %@ API (mode=%@)", provider.displayName, mode)
                response = try await llm.complete(
                    system: prompt,
                    user: contextBlock,
                    apiKey: apiKey,
                    provider: provider
                )
            }

            // Try parsing as no_advice first — LLM says nothing interesting to advise
            if let noAdviceReason = parseNoAdvice(response) {
                NSLog("[Advice] No advice this cycle (reason: %@)", noAdviceReason)
                return nil
            }

            guard let advice = parseAdviceResponse(response, contexts: contexts) else {
                NSLog("[Advice] ⚠️ Failed to parse LLM response as advice OR no_advice: %@", String(response.prefix(300)))
                return nil
            }

            // Persist
            if let container = modelContainer {
                let ctx = ModelContext(container)
                ctx.insert(advice)
                try? ctx.save()
            }

            latestAdvice = advice
            NotificationService.shared.postAdvice(advice)

            NSLog("[Advice] ✅ Generated (%d chars): %@", advice.content.count, advice.content)
            return advice

        } catch {
            NSLog("[Advice] ❌ Generation failed: %@", error.localizedDescription)
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - System prompt

    /// System prompt: hard cap, bad examples, no_advice escape.
    /// spec://iterations/ITER-001#architecture.advice-prompt
    /// ITER-022 G4 — runtime selector. Returns standard or coach prompt based
    /// on `AppSettings.shared.adviceCoachMode`. Read once at advice-fire time
    /// (not cached) so toggling the setting takes effect immediately.
    static var activePrompt: String {
        AppSettings.shared.adviceCoachMode ? systemPromptCoach : systemPromptStandard
    }

    /// Standard prompt (default). Insight-only. Anti-coach by design.
    static let systemPromptStandard = """
    You find ONE specific, high-value insight the user would NOT figure out on their own. The goal is to IMPRESS the user.

    WHEN TO GIVE ADVICE:
    - User doing something the slow way AND there is a specific shortcut (name it)
    - User about to make a visible mistake (wrong recipient, sensitive info in wrong place, wrong year)
    - Specific lesser-known tool/feature directly solves what they are doing right now
    - Concrete error/misconfiguration on screen they may have missed

    WHEN TO STAY SILENT (return no_advice):
    - Nothing genuinely non-obvious visible
    - Advice would duplicate something in PREVIOUS ADVICE
    - Advice is generic wellness / dev wisdom
    - You are reaching — if you have to stretch, there is no advice

    BAD EXAMPLES (never produce these):
    - "Take a break / Stay hydrated" (we are not a health app)
    - "Consider adding tests" (vague)
    - "Press Cmd+Enter to send the message" (basic shortcut everyone knows)
    - "Having N tasks is overwhelming — try prioritizing" (unsolicited judgment)
    - "Set your first goal to get started" (narrating UI)

    GOOD EXAMPLES (quality bar):
    - "You've scheduled this for 2026 — double-check the year"
    - "Sensitive credentials visible in terminal — mask before sharing"
    - "You stashed changes 2 hours ago — remember to git stash pop"
    - "npm tokens expiring tomorrow — renew via npm token create"
    - "This regex misses Unicode — use \\p{L} instead of [a-zA-Z]"
    - "Replying to group thread, not DM — check the recipient"

    FORMAT: Under 100 characters. Start with the actionable part.

    CATEGORIES — pick the MOST SPECIFIC one that fits. Pick "other" only if truly none apply.
    - "productivity"  — workflow shortcuts, automation, faster-way-to-X tips
    - "communication" — message clarity, recipient checks, tone fixes
    - "learning"      — concepts to look up, techniques, book/article references
    - "health"        — ergonomics, posture, screen-time pattern, credential exposure
                        (NOT generic wellness like "drink water" — those are still banned)
    - "finance"       — bills, subscriptions, expiring tokens, money decisions visible on screen
    - "relationships" — interpersonal cues, family/social context (only when explicit on screen)
    - "focus"         — distraction-pattern observation, NOT prescription
                        (e.g. "Six Slack threads in 5 min — context switching cost")
    - "security"      — sensitive credentials/keys/tokens visible, permission leaks, PII exposure
    - "career"        — interview prep, professional moves, calendar conflict resolution
    - "mental"        — observed cognitive pattern, NOT therapy and NOT mood judgment
                        (e.g. "Three windows open with the same form" → focus, not "anxious")
    - "other"         — only when none of the above fits

    CRITICAL: even with the broader category list, the WHEN-TO-STAY-SILENT rules above
    OVERRIDE category fit. A "health" category does NOT mean you should produce wellness
    nags. The advice itself must still be specific, actionable, and non-obvious.

    MEMORY-WEAVE (USER MEMORIES block):
    - The USER MEMORIES section lists durable facts the user told you previously.
    - Reference a memory ONLY when it MATERIALLY changes the advice. e.g.:
      User memory: "User runs Overchat, an AI ChatGPT wrapper using Stripe billing"
      Current screen: Stripe webhook test mode
      → "Stripe webhook test mode hits Overchat prod Customer table — switch to test customers"
        (memory turned a generic warning into a specific one tied to the user's product)
    - DO NOT shoehorn an irrelevant memory just to mention one. Most advice should
      NOT reference memory. If the connection feels strained, leave the memory out.
    - When you DO reference a memory, integrate it naturally — never quote it
      verbatim with "you said earlier...". Use the fact, not the source.

    CONFIDENCE (only when giving advice):
    - 0.90-1.0: Preventing a clear mistake or revealing a critical shortcut
    - 0.75-0.89: Highly relevant non-obvious tool/feature for current task
    - 0.60-0.74: Useful but user might already know

    Return JSON. Two possible shapes:

    If you have valuable advice:
    {"type": "advice", "content": "under 100 chars", "category": "<one of the 11 above>", "confidence": 0.0-1.0}

    If nothing worth saying:
    {"type": "no_advice", "reason": "short explanation"}
    """

    /// ITER-022 G4 — Coach mode prompt. Switched in via setting `adviceCoachMode`.
    /// Diff vs standard: ENABLES accountability nudges (commitment tracking,
    /// procrastination callouts, goal pressure when active_goals provided).
    /// STILL FORBIDS: generic wellness, mood judgment, therapy tone.
    /// The point is direct/specific accountability, not vague motivation.
    static let systemPromptCoach = """
    You are a direct accountability coach. The user CHOSE this mode (it is opt-in)
    because they want push-back on procrastination and slipping commitments. Be
    specific, blunt, time-aware. NEVER generic motivation.

    WHEN TO PUSH (coach scope):
    - User stated a commitment with a deadline (in transcripts/memories) and time
      is running out → name it specifically
      ("обещал ship X к пятнице — осталось 6 часов, а Twitter открыт 4 раза")
    - Repeated distraction pattern visible across screen activity
      ("Slack открыт 3 раза за 20 мин — context-switch обходится в ~10 мин/раз")
    - Goal slipping (when <active_goals> shows progress at 0 mid-day)
    - Stated intent contradicted by action
      ("утром писал 'фокус на MetaWhisp', сейчас 40 мин в YouTube")

    WHEN TO STAY SILENT (still applies):
    - No specific commitment to anchor advice — vague pressure is just noise
    - You'd be repeating PREVIOUS ADVICE
    - Reasonable break (≤15 min after focused work) — that's healthy, not slacking
    - User is in active recorded meeting / call — DO NOT interrupt with coaching

    BANNED (even in coach mode):
    - Generic wellness ("drink water", "stretch", "take a break", "stay hydrated")
    - Mood judgment ("you seem stressed/anxious/tired")
    - Therapy tone ("how does that make you feel")
    - Unsolicited life advice ("you should consider therapy / a vacation")
    - Vague motivation ("you got this", "stay focused", "keep pushing")
    - Insulting / shaming language

    GOOD COACH EXAMPLES:
    - "Ship X promised by Friday — 6h left, you've checked Twitter 5x in 30 min"
    - "Push-up goal sits at 0/10 — 3pm, half day burned"
    - "3 days no commit on MetaWhisp — break, blocker, or dropped?"
    - "PM said 'focus mode'; opened Telegram 4× in 12 min — quit it for this hour?"
    - "Standup with Pasha at 3pm — calendar prep doc is empty"

    BAD COACH EXAMPLES (would still produce these in coach mode? NO):
    - "Stay focused!"  ← vague
    - "You can do it!" ← motivation no anchor
    - "Take a break, you've earned it" ← unsolicited wellness
    - "Don't be lazy" ← shaming, no specifics

    CATEGORIES — same 11 as standard. Coach mode advice often falls in
    "focus", "productivity", or "career". Use "mental" sparingly — only when
    pattern is observable + actionable, never as therapy.

    CONFIDENCE — same scale as standard.

    Return JSON:
    {"type": "advice", "content": "under 100 chars", "category": "<one of 11>", "confidence": 0.0-1.0}

    OR if nothing concrete to push on:
    {"type": "no_advice", "reason": "short explanation"}
    """

    /// ITER-022 — Whitelisted categories. LLM may emit any of these; anything else
    /// (typo, hallucinated category, missing field) gets normalized to "other" by
    /// the parser. Keeps DB consistent and UI filters meaningful.
    static let validCategories: Set<String> = [
        "productivity", "communication", "learning",
        "health", "finance", "relationships", "focus",
        "security", "career", "mental", "other",
    ]

    /// Build user-content block: screen activity + transcripts + memories + previous advice.
    /// spec://iterations/ITER-001#architecture.advice-prompt
    /// ITER-022 G3 — memories are semantically ranked by cosine similarity to the
    /// current screen context (when embeddings + Pro available). Falls back to
    /// recent-N when no query embedding can be produced.
    private func buildAdviceUserContext(
        contexts: [ScreenContextService.ScreenContextSnapshot],
        extraContext: String?
    ) async -> String {
        var parts: [String] = []

        // USER MEMORIES — semantic ranking (ITER-022 G3) when possible.
        // Query text = most recent screen context's OCR (capped) + extraContext.
        // Top 8 by cosine, threshold 0.45 to drop irrelevant. Falls back to
        // recent-15 when no embedding-service / no Pro / empty embeddings.
        let memories = await fetchMemoriesForAdvice(contexts: contexts, extraContext: extraContext, limit: 8)
        if !memories.isEmpty {
            parts.append("USER MEMORIES (durable facts — weave only when materially relevant):")
            for m in memories {
                parts.append("- \(m.content)")
            }
            parts.append("")
        }

        // PREVIOUS ADVICE — cap 15, truncate each to 80 chars
        let previous = fetchPreviousAdvice(limit: 15)
        if !previous.isEmpty {
            parts.append("PREVIOUS ADVICE (do NOT repeat):")
            for item in previous {
                parts.append("- \"\(String(item.content.prefix(80)))\"")
            }
            parts.append("")
        }

        // CURRENT SCREEN — last 5 contexts with richer OCR (backend cap raised to 32KB).
        // More OCR = better context for LLM to find specific insights .
        let recentContexts = contexts.suffix(5)
        parts.append("CURRENT SCREEN (last \(recentContexts.count) contexts):")
        for ctx in recentContexts {
            let time = ctx.timestamp.formatted(date: .omitted, time: .shortened)
            let preview = String(ctx.ocrText.prefix(400)).replacingOccurrences(of: "\n", with: " ")
            parts.append("[\(time)] \(ctx.appName) — \(ctx.windowTitle)")
            if !preview.isEmpty {
                parts.append("  \(preview)")
            }
        }

        // RECENT TRANSCRIPTS — 3 transcripts, 250 chars each
        if let transcripts = fetchRecentTranscripts(limit: 3), !transcripts.isEmpty {
            parts.append("")
            parts.append("RECENT VOICE INPUT:")
            for t in transcripts {
                parts.append("- \"\(String(t.prefix(250)))\"")
            }
        }

        if let extra = extraContext {
            parts.append("")
            parts.append(String(extra.prefix(500)))
        }

        // Safety cap — well under backend 32KB limit
        let combined = parts.joined(separator: "\n")
        if combined.count > 20000 {
            return String(combined.prefix(20000))
        }
        return combined
    }

    /// Fetch UserMemory records for injection into prompts.
    private func fetchUserMemories(limit: Int) -> [UserMemory] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        return (try? ctx.fetch(desc)) ?? []
    }

    /// ITER-022 G3 — Memory ranking for advice prompts.
    ///
    /// Strategy:
    /// 1. Build a query string from the latest screen context + extraContext.
    /// 2. Embed it via `EmbeddingService` (Pro only). On failure → fall back to
    ///    recent-N (cheap, predictable).
    /// 3. Score each non-dismissed memory by cosine similarity to query.
    ///    Drop those below `minRelevance` threshold (0.45) — random unrelated
    ///    memories are noise and would push LLM toward shoehorning.
    /// 4. Return top-`limit` by score. If all below threshold → empty array
    ///    (better no memories than wrong memories).
    private func fetchMemoriesForAdvice(
        contexts: [ScreenContextService.ScreenContextSnapshot],
        extraContext: String?,
        limit: Int
    ) async -> [UserMemory] {
        // Build query string (≤1500 chars for embedding API).
        var queryParts: [String] = []
        if let extra = extraContext, !extra.isEmpty { queryParts.append(extra) }
        if let last = contexts.last {
            // appName + windowTitle + first ~600 chars OCR — the "what is the user
            // doing right now" signal that should match memory facts about projects/
            // people/tools.
            queryParts.append("\(last.appName) — \(last.windowTitle)")
            queryParts.append(String(last.ocrText.prefix(600)))
        }
        let query = queryParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return fetchUserMemories(limit: limit) }

        // Try semantic ranking via embeddings.
        guard let svc = embeddingService, LicenseService.shared.isPro else {
            return fetchUserMemories(limit: limit)
        }
        guard let qVec = try? await svc.embedOne(String(query.prefix(1500))) else {
            return fetchUserMemories(limit: limit)
        }

        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        let desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate<UserMemory> { !$0.isDismissed && $0.embedding != nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let candidates = (try? ctx.fetch(desc)) ?? []
        guard !candidates.isEmpty else { return fetchUserMemories(limit: limit) }

        let minRelevance: Float = 0.45
        var scored: [(UserMemory, Float)] = []
        for m in candidates {
            guard let data = m.embedding else { continue }
            let v = EmbeddingService.decode(data)
            guard !v.isEmpty else { continue }
            let sim = EmbeddingService.cosineSimilarity(qVec, v)
            if sim >= minRelevance { scored.append((m, sim)) }
        }
        // Better: empty over irrelevant. If nothing crossed threshold, no memory
        // block at all (LLM won't be tempted to shoehorn).
        guard !scored.isEmpty else { return [] }
        let ranked = scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
        NSLog("[Advice] G3 memory-weave: %d/%d memories scored ≥ %.2f, picked top %d",
              scored.count, candidates.count, minRelevance, ranked.count)
        return ranked
    }

    /// Try parsing response as {"type": "no_advice", "reason": "..."}.
    /// Returns reason string if matched, nil otherwise.
    private func parseNoAdvice(_ response: String) -> String? {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { return nil }

        struct NoAdviceJSON: Decodable {
            let type: String
            let reason: String?
        }

        guard let parsed = try? JSONDecoder().decode(NoAdviceJSON.self, from: data) else { return nil }
        guard parsed.type == "no_advice" else { return nil }
        return parsed.reason ?? "no specific reason"
    }

    // MARK: - Pro Proxy

    /// Call MetaWhisp Pro backend for advice generation.
    /// Endpoint: POST https://api.metawhisp.com/api/pro/advice
    /// Auth: Bearer {licenseKey}
    /// Body: { system, user } → Response: { text }
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
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            NSLog("[Advice] PRO ❌ HTTP %d: %@", http.statusCode, String(bodyStr.prefix(200)))
            throw ProcessingError.apiError("Advice proxy: HTTP \(http.statusCode)")
        }

        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    // MARK: - Context fetchers

    /// Fetch last N AdviceItems (newest first) for anti-repetition prompt.
    /// spec://intelligence/FEAT-0003#prompt.anti-repetition
    private func fetchPreviousAdvice(limit: Int) -> [AdviceItem] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<AdviceItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        return (try? ctx.fetch(desc)) ?? []
    }

    /// Fetch last N transcriptions (newest first) for richer context.
    /// spec://intelligence/FEAT-0003#prompt.rich-context
    private func fetchRecentTranscripts(limit: Int) -> [String]? {
        guard let container = modelContainer else { return nil }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<HistoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        let items = (try? ctx.fetch(desc)) ?? []
        return items.map { $0.displayText }
    }

    /// Relative time formatter ("5 min ago", "2 hours ago").
    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }
        if interval < 86400 { return "\(Int(interval / 3600)) hours ago" }
        return "\(Int(interval / 86400)) days ago"
    }

    // MARK: - Private

    private func buildContextSummary(from contexts: [ScreenContextService.ScreenContextSnapshot]) -> String {
        let recent = contexts.suffix(5)
        var parts: [String] = ["Recent activity (last \(recent.count) window changes):"]

        for ctx in recent {
            let timeStr = ctx.timestamp.formatted(date: .omitted, time: .shortened)
            let ocrPreview = String(ctx.ocrText.prefix(200)).replacingOccurrences(of: "\n", with: " ")
            parts.append("[\(timeStr)] \(ctx.appName) — \(ctx.windowTitle)")
            if !ocrPreview.isEmpty {
                parts.append("  Content: \(ocrPreview)")
            }
        }

        return parts.joined(separator: "\n")
    }

    private func parseAdviceResponse(_ response: String, contexts: [ScreenContextService.ScreenContextSnapshot]) -> AdviceItem? {
        // Extract JSON from response (LLM might wrap it in markdown)
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { return nil }

        // New shape: {"type": "advice", "content", "category", "confidence"}
        struct AdviceJSON: Decodable {
            let type: String?
            let content: String
            let category: String
            let reasoning: String?
            let confidence: Double?
        }

        guard let parsed = try? JSONDecoder().decode(AdviceJSON.self, from: data) else {
            return nil
        }

        // If LLM returned "no_advice" wrapped — reject (handled by parseNoAdvice)
        if parsed.type == "no_advice" { return nil }

        // Safety: enforce 120-char cap on our side too (spec C3)
        let truncated = parsed.content.count > 120
            ? String(parsed.content.prefix(120))
            : parsed.content

        // ITER-022 — normalize category: lowercase + whitelist check.
        // LLM occasionally types "Productivity" / "Communications" / new ones.
        // Unknown → "other" so DB stays consistent.
        let normalizedCategory: String = {
            let candidate = parsed.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return Self.validCategories.contains(candidate) ? candidate : "other"
        }()

        return AdviceItem(
            content: truncated,
            category: normalizedCategory,
            reasoning: parsed.reasoning,
            sourceApp: contexts.last?.appName,
            confidence: parsed.confidence ?? 0.5
        )
    }
}
