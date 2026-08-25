import Foundation

/// The production door to the vision endpoint.
///
/// Approved by the product owner on 2026-08-25. Server-side this is
/// `/api/pro/vision` on the worker: license-gated, image forwarded and
/// discarded, facts returned with server-issued IDs, and a provider ladder
/// behind it because Groq decommissions models without warning — it has taken
/// this product down that way before.
struct ScreenAgentProVisionTransport: ScreenAgentVisionTransport {

    /// Read at call time, not captured: the key can change or vanish while the
    /// app runs.
    let licenseKey: @MainActor () -> String?

    struct TransportError: Error {}

    func analyze(_ request: ScreenAgentVisionRequest) async throws -> ScreenAgentVisionResponse {
        guard let key = await licenseKey(), !key.isEmpty else { throw TransportError() }

        var urlRequest = URLRequest(url: URL(string: "https://api.metawhisp.com/api/pro/vision")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 30
        urlRequest.httpBody = try JSONEncoder().encode(Payload(
            image_b64: request.jpeg.base64EncodedString(),
            context_id: request.contextID.uuidString,
            generation: request.generation,
            frame_hash: request.frameHash))

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TransportError() }

        let reply = try JSONDecoder().decode(Reply.self, from: data)
        // A missing echo maps to values that can never match — the client's
        // same-frame check rejects instead of trusting silence.
        return ScreenAgentVisionResponse(
            contextID: UUID(uuidString: reply.context_id) ?? UUID(),
            generation: reply.generation ?? -1,
            frameHash: reply.frame_hash ?? "",
            facts: reply.facts.map { .init(evidenceID: $0.id, statement: $0.statement) })
    }

    private struct Payload: Encodable {
        let image_b64: String
        let context_id: String
        let generation: Int
        let frame_hash: String
    }

    private struct Reply: Decodable {
        struct Fact: Decodable {
            let id: String
            let statement: String
        }
        let context_id: String
        let generation: Int?
        let frame_hash: String?
        let facts: [Fact]
    }
}
