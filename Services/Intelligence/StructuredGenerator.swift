import Foundation
import SwiftData

/// Generates Structured (title/overview/category/emoji) for a closed Conversation.
/// Mirrors Omi's `get_transcript_structure` (`backend/utils/llm/conversation_processing.py:588`).
///
/// Fired by ConversationGrouper.close(). Fire-and-forget async.
///
/// Adaptations (from Omi copy):
/// - Removed speaker/CalendarMeetingContext handling (single-user desktop).
/// - Removed photos parameter (no wearable camera).
/// - Removed Calendar Events extraction (belongs to Phase 7 calendar integration).
/// - Kept: title (Title Case ≤10 words), overview, emoji (specific vivid), category (33 Omi values).
///
/// spec://BACKLOG#C1.2
@MainActor
final class StructuredGenerator: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?

    /// Minimum transcript character count to bother the LLM. Short chats get title="Quick note".
    private let minTranscriptChars = 40

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
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

        // Skip if already generated (idempotent).
        if conv.title != nil && conv.overview != nil {
            return
        }

        // Fetch linked HistoryItems.
        var histDesc = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        histDesc.fetchLimit = 200
        let items = (try? ctx.fetch(histDesc)) ?? []
        let transcript = items.map { $0.displayText }.joined(separator: "\n")

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
            conv.updatedAt = Date()
            try? ctx.save()
            NSLog("[StructuredGenerator] ✅ [%@] (%@): %@",
                  conv.emoji ?? "?",
                  parsed.category,
                  parsed.title)
        } catch {
            lastError = error.localizedDescription
            NSLog("[StructuredGenerator] ❌ Failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Prompt (copied from Omi, single-user simplification)

    /// Source: `BasedHardware/omi/backend/utils/llm/conversation_processing.py:605-647`.
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

    Respond in the SAME LANGUAGE as the transcript.

    Return JSON:
    {"title": "...", "overview": "...", "icon": "sf.symbol.name", "category": "..."}

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

        // Tolerate LLM occasionally emitting "emoji" key despite our rules.
        enum CodingKeys: String, CodingKey {
            case title, overview, icon, category
            case emoji  // legacy key fallback
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
