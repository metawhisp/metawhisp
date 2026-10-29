import Foundation

/// LLM provider configuration.
enum LLMProvider: String, CaseIterable, Identifiable {
    case openai = "openai"
    case cerebras = "cerebras"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .cerebras: "Cerebras"
        }
    }

    var subtitle: String {
        switch self {
        case .openai: "GPT-4o-mini · reliable · ~1s"
        case .cerebras: "Qwen 3 235B · fast · great multilingual"
        }
    }

    var endpoint: URL {
        switch self {
        case .openai: URL(string: "https://api.openai.com/v1/chat/completions")!
        case .cerebras: URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        }
    }

    var model: String {
        switch self {
        case .openai: "gpt-4o-mini"
        case .cerebras: "qwen-3-235b-a22b-instruct-2507"
        }
    }
}

/// Lightweight OpenAI-compatible Chat Completions client supporting multiple providers.
actor OpenAIService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport

    init(transport: @escaping Transport = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.transport = transport
    }

    struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    struct APIError: Decodable {
        struct ErrorBody: Decodable { let message: String }
        let error: ErrorBody
    }

    /// Send a system+user prompt to the configured LLM provider. Returns the assistant reply.
    func complete(system: String, user: String, apiKey: String, provider: LLMProvider = .openai) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            NSLog("[LLM] ❌ No API key for %@", provider.displayName)
            throw ProcessingError.noAPIKey
        }

        NSLog("[LLM] Sending to %@ (%@): keyLen=%d", provider.displayName, provider.model, key.count)

        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": provider.model,
            "temperature": 0.3,
            "max_tokens": 4096,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = CFAbsoluteTimeGetCurrent()
        let (data, httpResponse) = try await transport(request)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        if let http = httpResponse as? HTTPURLResponse {
            NSLog("[LLM] %@ HTTP %d (%.0fms)", provider.displayName, http.statusCode, elapsed)
            if http.statusCode != 200 {
                let bodyStr = String(data: data, encoding: .utf8) ?? "(unreadable)"
                NSLog("[LLM] ❌ error body: %d chars (content not logged)", bodyStr.count)
                if let apiErr = try? JSONDecoder().decode(APIError.self, from: data) {
                    throw ProcessingError.http(status: Self.status(http.statusCode, message: apiErr.error.message),
                                               message: apiErr.error.message,
                                               retryAfter: ProAdviceClient.retryAfterSeconds(http))
                }
                throw ProcessingError.http(status: http.statusCode, message: "HTTP \(http.statusCode)",
                                           retryAfter: ProAdviceClient.retryAfterSeconds(http))
            }
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.choices.first?.message.content else {
            NSLog("[LLM] ❌ Empty response (no choices)")
            throw ProcessingError.emptyResponse
        }
        NSLog("[LLM] ✅ %@ returned %d chars in %.0fms", provider.displayName, text.count, elapsed)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ITER-075 step 1 (1.5) — OpenAI answers 429 "Request too large for … on
    /// tokens per min" when one request is over the key's per-minute limit.
    /// That request can never go through, so it reads as 413 (too large), not
    /// as a rate limit to wait out.
    static func status(_ status: Int, message: String) -> Int {
        status == 429 && message.localizedCaseInsensitiveContains("request too large") ? 413 : status
    }
}

// MARK: - Errors

enum ProcessingError: LocalizedError {
    case noAPIKey
    case apiError(String)
    /// ITER-075 step 1 (1.5) — a refusal from the service, with its HTTP
    /// status, so a caller can tell an outage from a request that failed.
    case http(status: Int, message: String, retryAfter: TimeInterval? = nil)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey: "API key not set. Add it in Settings."
        case .apiError(let msg): "LLM error: \(msg)"
        case .http(_, let msg, _): "LLM error: \(msg)"
        case .emptyResponse: "Empty response from LLM."
        }
    }
}
