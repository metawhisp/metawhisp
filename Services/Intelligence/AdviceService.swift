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
        let contextBlock = buildAdviceUserContext(
            contexts: contexts,
            extraContext: extraContext
        )

        do {
            let response: String
            if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                NSLog("[Advice] Generating via Pro proxy")
                response = try await callProProxy(system: Self.systemPrompt, user: contextBlock, licenseKey: licenseKey)
            } else {
                let apiKey = settings.activeAPIKey
                guard !apiKey.isEmpty else {
                    NSLog("[Advice] No API key — skipping")
                    return nil
                }
                let provider = LLMProvider(rawValue: settings.llmProvider) ?? .openai
                NSLog("[Advice] Generating via direct %@ API", provider.displayName)
                response = try await llm.complete(
                    system: Self.systemPrompt,
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
    static let systemPrompt = """
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

    CATEGORIES: "productivity", "communication", "learning", "other"

    CONFIDENCE (only when giving advice):
    - 0.90-1.0: Preventing a clear mistake or revealing a critical shortcut
    - 0.75-0.89: Highly relevant non-obvious tool/feature for current task
    - 0.60-0.74: Useful but user might already know

    Return JSON. Two possible shapes:

    If you have valuable advice:
    {"type": "advice", "content": "under 100 chars", "category": "productivity|communication|learning|other", "confidence": 0.0-1.0}

    If nothing worth saying:
    {"type": "no_advice", "reason": "short explanation"}
    """

    /// Build user-content block: screen activity + transcripts + memories + previous advice.
    /// spec://iterations/ITER-001#architecture.advice-prompt
    private func buildAdviceUserContext(
        contexts: [ScreenContextService.ScreenContextSnapshot],
        extraContext: String?
    ) -> String {
        var parts: [String] = []

        // USER MEMORIES — cap 15 most recent, short bullet
        let memories = fetchUserMemories(limit: 15)
        if !memories.isEmpty {
            parts.append("USER MEMORIES (for personalization):")
            for m in memories {
                parts.append("- \(m.content)")  // dropped category label — saves tokens
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

        return AdviceItem(
            content: truncated,
            category: parsed.category,
            reasoning: parsed.reasoning,
            sourceApp: contexts.last?.appName,
            confidence: parsed.confidence ?? 0.5
        )
    }
}
