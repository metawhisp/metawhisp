import Foundation
import SwiftData

/// Generates Structured (title/overview/category/emoji) for a closed Conversation.
/// Mirrors `get_transcript_structure` (`backend/utils/llm/conversation_processing.py:588`).
/// Fired by ConversationGrouper.close(). Fire-and-forget async.
/// Adaptations:
/// - Removed speaker/CalendarMeetingContext handling (single-user desktop).
/// - Removed photos parameter (no wearable camera).
/// - Removed Calendar Events extraction (belongs to Phase 7 calendar integration).
/// - Kept: title (Title Case ≤10 words), overview, emoji (specific vivid), category (33 values).
/// spec://BACKLOG#C1.2
@MainActor
final class StructuredGenerator: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?

    /// Set by AppDelegate after both services exist. Used to embed the conversation
    /// once title/overview are populated so semantic MetaChat retrieval can find it
    /// via cosine similarity (not just substring match).
    /// spec://iterations/ITER-011-conversation-embeddings
    weak var embeddingService: EmbeddingService?

    /// Set by AppDelegate. Used to canonicalize the LLM-generated project label
    /// against existing aliases (or insert a new one) right after structured-gen
    /// completes, so the Projects view sees the cluster on first render.
    /// spec://iterations/ITER-014-project-clustering
    weak var projectAggregator: ProjectAggregator?

    /// Set by AppDelegate. After a meeting/dictation closes we ask the calendar
    /// reader to find a matching EKEvent in the time neighborhood and snapshot
    /// its identifier + title + attendees onto the Conversation. Lets MetaChat
    /// answer "о чём говорили на standup в среду?" by event lookup.
    /// spec://iterations/ITER-018-calendar-cross-ref
    weak var calendarReader: CalendarReaderService?

    /// Minimum transcript character count to bother the LLM. Short chats get title="Quick note".
    private let minTranscriptChars = 40

    /// ITER-021 — periodic backfill (catches conversations stuck on "Quick note" /
    /// "(empty)" between app launches). Default 30 min — frequent enough that a
    /// user opening a 2h-old meeting sees the right title, rare enough to not
    /// thrash the proxy. Cancelled in deinit-equivalent via `stopPeriodicBackfill`.
    private var periodicBackfillTask: Task<Void, Never>?
    private let periodicBackfillInterval: TimeInterval = 1800  // 30 min

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// ITER-021 — Encode `[String]` to JSON for the new structured summary fields.
    /// Returns nil for empty/nil input so the UI can distinguish "not extracted"
    /// from "explicitly empty".
    static func encodeStringArray(_ items: [String]?) -> String? {
        guard let items, !items.isEmpty else { return nil }
        let cleaned = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return (try? String(data: JSONEncoder().encode(cleaned), encoding: .utf8))
    }

    /// Helper shared by the main path + retry path.
    private func fetchHistoryItems(conversationId: UUID, in ctx: ModelContext) -> [HistoryItem] {
        var desc = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        desc.fetchLimit = 200
        return (try? ctx.fetch(desc)) ?? []
    }

    /// Backfill — retries generation for conversations stuck on placeholder fields.
    /// ITER-021: extended query — was `title == "Quick note"`, now also catches
    /// `overview == "(empty)"` (these are conversations where transcript existed
    /// but generation failed silently — exactly the bug the user hit on
    /// 2026-04-25 13:33: 3611 chars transcript + Quick note + empty overview).
    /// Run on launch AND periodically (see startPeriodicBackfill).
    func backfillPlaceholders() async {
        guard hasLLMAccess else { return }
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        // Match conversations where StructuredGenerator clearly hadn't run successfully:
        // - title is the "Quick note" placeholder, OR
        // - overview is the "(empty)" placeholder (LLM call failed but title written).
        var desc = FetchDescriptor<Conversation>(
            predicate: #Predicate {
                !$0.discarded
                && ($0.title == "Quick note" || $0.overview == "(empty)")
            }
        )
        desc.fetchLimit = 100
        let placeholders = (try? ctx.fetch(desc)) ?? []
        guard !placeholders.isEmpty else { return }
        NSLog("[StructuredGenerator] Backfilling %d placeholder conversations", placeholders.count)
        for conv in placeholders {
            // Only retry if there's actually a real transcript available.
            let items = fetchHistoryItems(conversationId: conv.id, in: ctx)
            let transcript = items.map { $0.displayText }.joined(separator: "\n")
            guard transcript.count >= minTranscriptChars else { continue }
            // Reset title/overview so generate() re-runs through the LLM path.
            conv.title = nil
            conv.overview = nil
            conv.category = nil
            conv.emoji = nil
            try? ctx.save()
            await generate(conversationId: conv.id)
        }
    }

    /// ITER-021 — Periodic backfill loop. Catches conversations that close while
    /// the proxy is briefly down: the launch backfill misses them (since they
    /// finish AFTER launch), and without periodic re-check they stay broken
    /// forever. 30-min cadence is rare enough to not load the proxy, frequent
    /// enough that a returning user sees titles update within minutes.
    func startPeriodicBackfill() {
        periodicBackfillTask?.cancel()
        periodicBackfillTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.periodicBackfillInterval ?? 1800))
                guard let self, !Task.isCancelled else { return }
                await self.backfillPlaceholders()
            }
        }
        NSLog("[StructuredGenerator] ✅ Periodic backfill armed (every %.0fs)", periodicBackfillInterval)
    }

    /// Cancel the periodic backfill (used on teardown / settings toggle off).
    func stopPeriodicBackfill() {
        periodicBackfillTask?.cancel()
        periodicBackfillTask = nil
    }

    /// ITER-021 — Public manual retry for the UI "Regenerate" button.
    /// Forces re-generation regardless of placeholder state. Used when the
    /// user looks at a meeting and the LLM previously chose a bad title /
    /// missed structured sections. Internally clears existing fields then
    /// calls the standard `generate(conversationId:)` path.
    func regenerate(conversationId: UUID) async {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conversationId })
        desc.fetchLimit = 1
        guard let conv = try? ctx.fetch(desc).first else { return }
        // Reset structured fields so generate() takes the full LLM path.
        conv.title = nil
        conv.overview = nil
        conv.category = nil
        conv.emoji = nil
        conv.primaryProject = nil
        conv.topicsJSON = nil
        conv.decisionsJSON = nil
        conv.actionItemsJSON = nil
        conv.participantsJSON = nil
        conv.keyQuotesJSON = nil
        conv.nextStepsJSON = nil
        try? ctx.save()
        await generate(conversationId: conversationId)
    }

    /// Generate title/overview/category/emoji for a conversation by id.
    /// Fire-and-forget — background task, writes result back to the Conversation record.
    func generate(conversationId: UUID) async {
        guard !isRunning else { return }
        guard hasLLMAccess else {
            NSLog("[StructuredGenerator] No LLM access — skipping")
            return
        }
        guard let container = modelContainer else { return }

        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conversationId })
        descriptor.fetchLimit = 1
        guard let conv = try? ctx.fetch(descriptor).first else {
            NSLog("[StructuredGenerator] Conversation %@ not found", conversationId.uuidString.prefix(8) as CVarArg)
            return
        }

        // Skip if already generated (idempotent) — BUT allow re-generation when
        // the existing title is a placeholder ("Quick note") and a real transcript
        // has since landed. This recovers from the previous race condition where
        // StructuredGenerator fired before the HistoryItem was persisted.
        let isPlaceholder = (conv.title == "Quick note")
        if conv.title != nil && conv.overview != nil && !isPlaceholder {
            return
        }

        // Fetch linked HistoryItems.
        let items = fetchHistoryItems(conversationId: conversationId, in: ctx)
        var transcript = items.map { $0.displayText }.joined(separator: "\n")

        // Retry once if transcript is empty — could still be mid-commit for meeting path.
        if transcript.isEmpty {
            try? await Task.sleep(for: .seconds(2))
            let ctx2 = ModelContext(container)
            let retryItems = fetchHistoryItems(conversationId: conversationId, in: ctx2)
            transcript = retryItems.map { $0.displayText }.joined(separator: "\n")
            if !transcript.isEmpty {
                NSLog("[StructuredGenerator] Transcript appeared on retry (%d chars)", transcript.count)
            }
        }

        guard transcript.count >= minTranscriptChars else {
            // Too short — give a placeholder so UI has something to show.
            conv.title = "Quick note"
            conv.overview = transcript.isEmpty ? "(empty)" : String(transcript.prefix(80))
            conv.category = "other"
            conv.emoji = "bubble.left"  // SF Symbol, monochrome
            conv.updatedAt = Date()
            try? ctx.save()
            NSLog("[StructuredGenerator] Short transcript (%d chars) — placeholder title", transcript.count)
            return
        }

        isRunning = true
        defer { isRunning = false }

        let startedAt = conv.startedAt
        let userPrompt = buildPrompt(transcript: transcript, startedAt: startedAt)

        do {
            let response: String
            if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                response = try await callProProxy(system: Self.systemPrompt, user: userPrompt, licenseKey: licenseKey)
            } else {
                let apiKey = settings.activeAPIKey
                guard !apiKey.isEmpty else {
                    NSLog("[StructuredGenerator] No API key — skipping")
                    return
                }
                let provider = LLMProvider(rawValue: settings.llmProvider) ?? .openai
                response = try await llm.complete(
                    system: Self.systemPrompt,
                    user: userPrompt,
                    apiKey: apiKey,
                    provider: provider
                )
            }

            guard let parsed = parseResponse(response) else {
                NSLog("[StructuredGenerator] ⚠️ Parse failed for conv %@", conversationId.uuidString.prefix(8) as CVarArg)
                return
            }

            conv.title = parsed.title
            conv.overview = parsed.overview
            conv.category = parsed.category
            conv.emoji = validateSFSymbol(parsed.icon)
            // ITER-014 — write project + topics (canonical name resolved later
            // by ProjectAggregator; we store the raw LLM value for audit trail).
            if let rawProject = parsed.project?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawProject.isEmpty, rawProject.lowercased() != "null" {
                conv.primaryProject = rawProject
            } else {
                conv.primaryProject = nil
            }
            if let topics = parsed.topics, !topics.isEmpty {
                let cleaned = topics
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
                if !cleaned.isEmpty {
                    conv.topicsJSON = (try? String(data: JSONEncoder().encode(cleaned), encoding: .utf8))
                }
            }
            // ITER-021 — structured meeting summary sections.
            // Encode as JSON `[String]` for SwiftData (flat schema). Empty arrays
            // → store nil so UI can distinguish "not extracted yet" vs "empty".
            conv.decisionsJSON    = Self.encodeStringArray(parsed.decisions)
            conv.actionItemsJSON  = Self.encodeStringArray(parsed.actionItems)
            conv.participantsJSON = Self.encodeStringArray(parsed.participants)
            conv.keyQuotesJSON    = Self.encodeStringArray(parsed.keyQuotes)
            conv.nextStepsJSON    = Self.encodeStringArray(parsed.nextSteps)
            conv.updatedAt = Date()
            try? ctx.save()
            NSLog("[StructuredGenerator] ✅ [%@] (%@) project=%@ topics=%d: %@",
                  conv.emoji ?? "?",
                  parsed.category,
                  conv.primaryProject ?? "—",
                  parsed.topics?.count ?? 0,
                  parsed.title)

            // Embed the now-finalized conversation so MetaChat can semantically retrieve
            // it later. Fire-and-forget; nil embedding falls back to recency ordering.
            if let embeddingService {
                let source = EmbeddingService.buildConversationEmbeddingSource(for: conv, in: ctx)
                if !source.isEmpty {
                    embeddingService.embedConversationInBackground(conv, sourceText: source, in: ctx)
                }
            }

            // ITER-014 — eagerly seed the ProjectAlias row so this conversation's
            // project shows up in the Projects view immediately (rather than only
            // after the next listProjects() call would lazily resolve it).
            if let raw = conv.primaryProject?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty, let projectAggregator {
                _ = projectAggregator.resolveCanonical(raw)
            }

            // ITER-018 — try to link this conversation to a matching EKEvent.
            // Fire-and-forget; non-meeting dictations rarely match a calendar event
            // but the linker will simply find no candidate and exit cheaply.
            if let calendarReader {
                Task { @MainActor [weak calendarReader] in
                    await calendarReader?.linkConversation(conv.id)
                }
            }
        } catch {
            lastError = error.localizedDescription
            NSLog("[StructuredGenerator] ❌ Failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Prompt

    static let systemPrompt = """
    You are an expert content analyzer. Your task is to analyze the provided voice transcript and provide structure and clarity.

    For the TITLE: Write a clear, compelling headline (≤10 words) that captures the central topic and outcome. Use Title Case, avoid filler words, include a key noun + verb where possible (e.g., "Team Finalizes Q2 Budget" or "Debugging Memory Extraction Pipeline").

    For the OVERVIEW: Condense the content into a 1-3 sentence summary with the main topics, making sure to capture the key points and important details. Be specific — mention project names, people, concrete actions.

    For the ICON: Select a SINGLE SF Symbol name (Apple's monochrome icon library) that vividly reflects the core subject. DO NOT output Unicode emoji — our app uses monochrome SF Symbols only. Choose a specific symbol over a generic one.

    Valid SF Symbol examples (pick one of these or another valid SF Symbol name):
    - "lightbulb" (new idea), "sparkles" (insight), "bubble.left" (discussion)
    - "chart.bar" (analytics), "chart.line.uptrend.xyaxis" (growth), "dollarsign.circle" (finance)
    - "ant" (bug), "hammer" (fix), "wrench.and.screwdriver" (maintenance)
    - "briefcase" (work), "building.columns" (business), "person.2" (social)
    - "book" (learning), "graduationcap" (education), "newspaper" (news)
    - "heart" (health/romance), "brain" (psychology), "leaf" (environment)
    - "airplane" (travel), "house" (home/real estate), "car" (transportation)
    - "pencil" (writing), "doc.text" (documents), "terminal" (code)
    - "calendar" (scheduling), "clock" (time), "bell" (notification)
    - "questionmark.circle" (question), "exclamationmark.triangle" (warning), "checkmark.circle" (done)
    - "target" (goal), "flag" (milestone), "star" (important)
    - "music.note" (music), "figure.run" (sports), "fork.knife" (food)
    - Fallback: "circle" if nothing specific fits.

    For the CATEGORY: Classify the content into EXACTLY ONE of these categories:
    personal, education, health, finance, legal, philosophy, spiritual, science, entrepreneurship, parenting, romantic, travel, inspiration, technology, business, social, work, sports, politics, literature, history, architecture, music, weather, news, entertainment, psychology, real, design, family, economics, environment, other

    For the PROJECT: Extract the PRIMARY product/project/codename this conversation is about.
    - GOOD: "Overchat", "MetaWhisp", "Atomic Bot", "Q2 Roadmap", "Migration to Postgres"
    - BAD: "work" (too generic — that's category), "discussion", "the team", "my company"
    - This is the most CONCRETE recurring entity — a specific product or initiative the user
      is building, planning, or operating. Not the employer / department / category.
    - If the conversation is personal, social, or doesn't center on a specific project → null.
    - If multiple projects mentioned → pick the one most discussed (≥60% of the talk).

    For the TOPICS: 0-3 short sub-topic tags (not full sentences). Lowercase, single word
    or short noun phrase each. Examples: ["pricing", "infra"], ["hiring", "interview"],
    ["api design"]. Empty array OK if nothing specific.

    ── ITER-021 STRUCTURED SUMMARY ──
    For the next 5 fields, extract from the transcript ONLY explicit, evidenced
    content. Empty array `[]` is BETTER than fabricated filler. Anti-hallucination
    rules apply identically to all 5 — never invent.

    DECISIONS — concrete choices/commitments made during the talk.
    - 0-5 items, each ≤14 words.
    - Format: action-led, past/perfective tense.
    - GOOD: ["Switch to Stripe for billing", "Drop legacy admin panel"]
    - BAD: ["Discussed pricing"] (discussion ≠ decision), ["Maybe move to Postgres"] (uncertain → SKIP).

    ACTION ITEMS — explicit commitments to do something AFTER this conversation.
    - 0-5 items, each ≤14 words.
    - Format: imperative verb + object.
    - GOOD: ["Send Q2 roadmap to Pasha by Friday", "Review SEO report"]
    - BAD: ["Will think about it"] (vague intent → SKIP).
    - These are HISTORY for the recap view, NOT actionable tasks. The Tasks tab
      gets populated separately by a different extractor — don't worry about overlap.

    PARTICIPANTS — people NAMED in the transcript besides the speaker.
    - 0-10 items. Names AS SPOKEN ("Pasha" stays Pasha, "Майк" stays Майк).
    - Skip generic terms ("the team", "кто-то").
    - Skip the speaker themselves (they're implicit).

    KEY QUOTES — verbatim memorable lines worth re-reading.
    - 0-3 items, each ≤25 words.
    - Quote DIRECTLY from the transcript — exact wording.
    - Pick lines that capture insight, decision, or vivid framing.
    - Skip filler/greetings. If nothing memorable → empty.

    NEXT STEPS — forward-looking agenda items for a future conversation.
    - 0-3 items, each ≤14 words.
    - Format: topic phrase, NOT actions.
    - GOOD: ["Pricing tier breakdown", "Feedback from beta users"]
    - BAD: ["Send invite"] (that's an action item, not a next-meeting topic).

    Respond in the SAME LANGUAGE as the transcript.

    Return JSON:
    {"title": "...", "overview": "...", "icon": "sf.symbol.name", "category": "...",
     "project": "Overchat" or null, "topics": ["pricing", "infra"],
     "decisions": [], "action_items": [], "participants": [], "key_quotes": [], "next_steps": []}

    CRITICAL OUTPUT RULE: Respond with ONLY the JSON object. No translation. No explanation. No preamble. No markdown fences. The "icon" value MUST be a valid SF Symbol name (lowercase with dots), NOT a Unicode emoji character.
    """

    private func buildPrompt(transcript: String, startedAt: Date) -> String {
        let isoFormatter = ISO8601DateFormatter()
        let started = isoFormatter.string(from: startedAt)
        return """
        Started at: \(started)

        Transcript:
        ```
        \(transcript)
        ```
        """
    }

    // MARK: - Parse

    private struct StructuredJSON: Decodable {
        let title: String
        let overview: String
        let icon: String          // SF Symbol name — see system prompt
        let category: String
        // ITER-014 — optional: LLM may omit on older prompts.
        let project: String?
        let topics: [String]?
        // ITER-021 — structured meeting summary sections. All optional so
        // legacy prompts / partial failures degrade gracefully.
        let decisions: [String]?
        let actionItems: [String]?
        let participants: [String]?
        let keyQuotes: [String]?
        let nextSteps: [String]?

        // Tolerate LLM occasionally emitting "emoji" key despite our rules.
        enum CodingKeys: String, CodingKey {
            case title, overview, icon, category
            case emoji  // legacy key fallback
            case project, topics
            case decisions
            case actionItems = "action_items"
            case participants
            case keyQuotes = "key_quotes"
            case nextSteps = "next_steps"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            overview = try c.decode(String.self, forKey: .overview)
            category = try c.decode(String.self, forKey: .category)
            if let icon = try? c.decode(String.self, forKey: .icon) {
                self.icon = icon
            } else if let legacyEmoji = try? c.decode(String.self, forKey: .emoji) {
                self.icon = legacyEmoji  // best-effort; will render empty if Unicode
            } else {
                self.icon = "circle"
            }
            // Project/topics are optional so old prompts / graceful downgrade still parse.
            project = try? c.decode(String.self, forKey: .project)
            topics = try? c.decode([String].self, forKey: .topics)
            // ITER-021 — structured summary sections (all optional).
            decisions = try? c.decode([String].self, forKey: .decisions)
            actionItems = try? c.decode([String].self, forKey: .actionItems)
            participants = try? c.decode([String].self, forKey: .participants)
            keyQuotes = try? c.decode([String].self, forKey: .keyQuotes)
            nextSteps = try? c.decode([String].self, forKey: .nextSteps)
        }
    }

    private func parseResponse(_ response: String) -> StructuredJSON? {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StructuredJSON.self, from: data)
    }

    /// Extract first balanced JSON object from prose-padded text. Same as other extractors.
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

    // MARK: - Pro proxy

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
            throw ProcessingError.apiError("Structured proxy HTTP \(http.statusCode)")
        }
        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty || LicenseService.shared.isPro
    }

    /// Ensure the LLM-supplied icon is an SF Symbol string, not a Unicode emoji.
    /// SwiftUI's `Image(systemName:)` silently renders empty if the name is wrong, so
    /// we catch obvious emoji (non-ASCII) early and fall back to a neutral default.
    private func validateSFSymbol(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Heuristic: SF Symbol names are ASCII lowercase + dots + digits. Emoji chars are non-ASCII.
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "."))
        if !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return trimmed
        }
        NSLog("[StructuredGenerator] ⚠️ Icon '%@' not a valid SF Symbol name, falling back", trimmed)
        return "bubble.left"  // neutral default
    }
}
