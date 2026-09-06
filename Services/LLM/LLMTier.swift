import Foundation

/// Model tier for `/api/pro/advice`, `/api/pro/process`, `/api/pro/chat-with-tools`.
///
/// The CF Worker (`metawhisp-api`) reads `body.tier` and routes to a
/// per-tier model on Groq (primary) and Cerebras (fallback):
///
/// | Tier   | Groq                          | Cerebras       | $/1M in/out  |
/// |--------|-------------------------------|----------------|--------------|
/// | mini   | llama-3.1-8b-instant          | llama-3.1-8b   | $0.05/$0.08  |
/// | medium | openai/gpt-oss-20b            | gpt-oss-120b   | $0.075/$0.30 |
/// | heavy  | llama-3.3-70b-versatile       | llama-3.3-70b  | $0.59/$0.79  |
///
/// Missing `tier` on the wire = the worker uses the historical default
/// `llama-3.3-70b-versatile`. Back-compat for clients that don't yet send
/// the field.
///
/// Per-service tier declarations live as `static let llmTier` on each
/// service that calls the Pro proxy. Spec: `specs/iterations/ITER-041`.
enum LLMTier: String, Codable, Equatable {
    case mini
    case medium
    case heavy
}

/// Builders for the JSON bodies forwarded to the Pro proxy. Pure
/// functions — tested in `LLMTierTests`.
enum LLMRequestBody {
    /// What `POST /api/pro/advice` accepts in ONE prompt. The proxy rejects
    /// anything longer with HTTP 400 (`Prompt too long (… chars, max 32000)`)
    /// — an 87-minute meeting is 47 000 characters, so a caller that sends a
    /// whole transcript gets no answer at all (2026-09-04). Callers chunk
    /// (`ChunkedCompletion`) or cap against this.
    static let maxPromptChars = 32_000
    /// What a caller should actually put in one prompt: the limit less room
    /// for the joining and framing the fold adds around it.
    static let safePromptChars = 30_000

    /// What a refused request actually said. The proxy answers
    /// `{"error": "…"}` on every failure it can name; that sentence is the
    /// reason a log line owes the reader. The RAW body is never logged — an
    /// upstream can echo the prompt back inside it, and this log is a durable
    /// file (audit, 2026-09-06).
    static func proxyReason(_ data: Data) -> String {
        struct ProxyError: Decodable { let error: String }
        if let decoded = try? JSONDecoder().decode(ProxyError.self, from: data), !decoded.error.isEmpty {
            return String(decoded.error.prefix(200))
        }
        return "\(data.count)-byte body, not JSON (content not logged)"
    }

    /// Body for `POST /api/pro/advice`. Optional `tier` + `serviceId` are
    /// the new ITER-041 fields; both default to nil so callers that haven't
    /// migrated yet keep producing the original 2-field body shape.
    static func proAdviceBody(
        system: String,
        user: String,
        tier: LLMTier? = nil,
        serviceId: String? = nil
    ) -> [String: Any] {
        var body: [String: Any] = ["system": system, "user": user]
        if let tier { body["tier"] = tier.rawValue }
        if let serviceId { body["service_id"] = serviceId }
        return body
    }
}
