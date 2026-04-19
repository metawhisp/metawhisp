import Foundation
import SwiftData

/// Chat with RAG over user's memories + recent transcripts + tasks.
/// System prompt adapted from Omi `_get_qa_rag_prompt` (`backend/utils/llm/chat.py:303`).
/// MVP: no streaming, no files, no voice — just text in / text out.
///
/// spec://BACKLOG#B2
@MainActor
final class ChatService: ObservableObject {
    @Published var isSending = false
    @Published var lastError: String?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Send a user message, call LLM, persist both messages.
    func send(_ userText: String) async {
        guard !isSending else { return }
        guard hasLLMAccess else {
            lastError = "Нет доступа к LLM (нужен Pro или API key)"
            return
        }
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true
        lastError = nil
        defer { isSending = false }

        // Persist user message first — UI queries will pick it up immediately.
        let userMsg = ChatMessage(sender: "human", text: trimmed)
        if let container = modelContainer {
            let ctx = ModelContext(container)
            ctx.insert(userMsg)
            try? ctx.save()
        }

        // Build context + RAG prompt.
        let history = fetchChatHistory(limit: 20)
        let memories = fetchMemoriesAsString()
        let recentTranscripts = fetchRecentTranscripts(limit: 10)
        let pendingTasks = fetchPendingTasks()

        let userPrompt = buildUserPrompt(
            question: trimmed,
            memories: memories,
            transcripts: recentTranscripts,
            tasks: pendingTasks,
            history: history
        )

        do {
            let response: String
            if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                NSLog("[ChatService] Sending via Pro proxy")
                response = try await callProProxy(system: Self.systemPrompt, user: userPrompt, licenseKey: licenseKey)
            } else {
                let apiKey = settings.activeAPIKey
                guard !apiKey.isEmpty else {
                    lastError = "No API key"
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

            let aiText = response.trimmingCharacters(in: .whitespacesAndNewlines)
            let aiMsg = ChatMessage(sender: "ai", text: aiText)
            if let container = modelContainer {
                let ctx = ModelContext(container)
                ctx.insert(aiMsg)
                try? ctx.save()
            }
            NSLog("[ChatService] ✅ Got response (%d chars)", aiText.count)
        } catch {
            lastError = error.localizedDescription
            NSLog("[ChatService] ❌ Failed: %@", error.localizedDescription)
            let errMsg = ChatMessage(sender: "ai", text: "", errorText: error.localizedDescription)
            if let container = modelContainer {
                let ctx = ModelContext(container)
                ctx.insert(errMsg)
                try? ctx.save()
            }
        }
    }

    /// Clear all chat history (soft — actually deletes).
    func clearHistory() {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        try? ctx.delete(model: ChatMessage.self)
        try? ctx.save()
    }

    // MARK: - System prompt (adapted from Omi _get_qa_rag_prompt)

    /// Source: `BasedHardware/omi/backend/utils/llm/chat.py:303`.
    /// Adaptations:
    /// - Removed plugin/app personality injection (single assistant).
    /// - Removed citation blocks (no vector search, no ranked retrieval).
    /// - Removed reports template (out of MVP scope).
    /// - Kept core <task>, <instructions>, <memories>, <user_facts>, <previous_messages>, <question_timezone>.
    static let systemPrompt = """
    <assistant_role>
    You are an assistant for question-answering tasks about the user's own activity, memories, and tasks.
    </assistant_role>

    <task>
    Write an accurate, concise, and personalized answer to the <question> using the provided context.
    Context includes: the user's stored <user_facts>, their <recent_voice_transcripts>, their <pending_tasks>, and the <previous_messages> in this chat thread.
    </task>

    <instructions>
    - Refine the <question> based on the last <previous_messages> before answering.
    - DO NOT use the AI's own prior messages as factual references — only user-provided content counts.
    - It is EXTREMELY IMPORTANT to answer directly. No padding. No "based on the available memories" phrasing.
    - If you don't know, say so honestly. Don't fabricate.
    - If <recent_voice_transcripts> and <user_facts> are empty, answer from general knowledge — but clarify you have no personal context.
    - Use <question_timezone> and <current_datetime_utc> for time references.
    - Respond in the same language the user asked in.
    </instructions>

    <current_datetime_utc>
    {{CURRENT_UTC}}
    </current_datetime_utc>

    <question_timezone>
    {{USER_TZ}}
    </question_timezone>
    """

    // MARK: - Prompt builder

    private func buildUserPrompt(
        question: String,
        memories: String,
        transcripts: [String],
        tasks: [String],
        history: [ChatMessage]
    ) -> String {
        var parts: [String] = []

        parts.append("<user_facts>")
        parts.append(memories.isEmpty ? "(none stored)" : memories)
        parts.append("</user_facts>")

        parts.append("")
        parts.append("<recent_voice_transcripts>")
        if transcripts.isEmpty {
            parts.append("(none)")
        } else {
            for (i, t) in transcripts.enumerated() {
                parts.append("[\(i + 1)] \(t)")
            }
        }
        parts.append("</recent_voice_transcripts>")

        parts.append("")
        parts.append("<pending_tasks>")
        if tasks.isEmpty {
            parts.append("(none)")
        } else {
            for t in tasks {
                parts.append("- \(t)")
            }
        }
        parts.append("</pending_tasks>")

        parts.append("")
        parts.append("<previous_messages>")
        if history.isEmpty {
            parts.append("(new conversation)")
        } else {
            for m in history {
                let who = m.sender == "human" ? "User" : "Assistant"
                parts.append("\(who): \(m.text)")
            }
        }
        parts.append("</previous_messages>")

        parts.append("")
        parts.append("<question>")
        parts.append(question)
        parts.append("</question>")

        let combined = parts.joined(separator: "\n")
        if combined.count > 24000 { return String(combined.prefix(24000)) }
        return combined
    }

    // MARK: - Retrieval

    /// All non-dismissed memories joined as bullet list.
    private func fetchMemoriesAsString() -> String {
        guard let container = modelContainer else { return "" }
        let ctx = ModelContext(container)
        let desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let items = (try? ctx.fetch(desc)) ?? []
        return items.map { "- \($0.content)" }.joined(separator: "\n")
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

    private func fetchPendingTasks() -> [String] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        let desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed && !$0.completed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let items = (try? ctx.fetch(desc)) ?? []
        return items.map { $0.taskDescription }
    }

    /// Last N chat messages (oldest first for prompt readability).
    private func fetchChatHistory(limit: Int) -> [ChatMessage] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        let items = (try? ctx.fetch(desc)) ?? []
        return items.reversed()
    }

    // MARK: - Pro proxy

    private func callProProxy(system: String, user: String, licenseKey: String) async throws -> String {
        // Substitute template tokens in system prompt.
        let utc = ISO8601DateFormatter().string(from: Date())
        let tz = TimeZone.current.identifier
        let resolvedSystem = system
            .replacingOccurrences(of: "{{CURRENT_UTC}}", with: utc)
            .replacingOccurrences(of: "{{USER_TZ}}", with: tz)

        let url = URL(string: "https://api.metawhisp.com/api/pro/advice")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = ["system": resolvedSystem, "user": user]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw ProcessingError.apiError("Chat proxy HTTP \(http.statusCode): \(String(bodyStr.prefix(200)))")
        }
        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty || LicenseService.shared.isPro
    }
}
