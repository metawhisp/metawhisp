import Foundation

/// The contract for asking a vision model about one frame — and the proof that
/// the answer is about that frame.
///
/// The transport is injected. Until the production endpoint ships, tests run
/// against a fake, and nothing here fabricates a network call: the spec's rule
/// is implement the boundary honestly or stop.
protocol ScreenAgentVisionTransport {
    func analyze(_ request: ScreenAgentVisionRequest) async throws -> ScreenAgentVisionResponse
}

struct ScreenAgentVisionRequest {
    let contextID: UUID
    let jpeg: Data
}

struct ScreenAgentVisionResponse {
    /// Echoed by the transport so a late answer can be tied to its question.
    let contextID: UUID
    /// Visible-state facts, each with a runtime-consumable evidence tag.
    /// The transport composes no user-facing prose.
    let facts: [VisualFact]

    struct VisualFact: Equatable {
        let evidenceID: String
        let statement: String
    }
}

@MainActor
final class ScreenAgentVisionClient {

    private let transport: ScreenAgentVisionTransport
    private let cache: ScreenAgentFrameCache

    init(transport: ScreenAgentVisionTransport, cache: ScreenAgentFrameCache) {
        self.transport = transport
        self.cache = cache
    }

    enum Outcome: Equatable {
        case facts([ScreenAgentVisionResponse.VisualFact])
        /// Consent, freshness, or frame availability said no. Silence, not a
        /// text-only guess dressed as vision.
        case notEligible
        /// The screen changed while the model was looking.
        case stale
        case failed
    }

    /// One call per run, and only when everything still holds.
    ///
    /// - Parameter isStillCurrent: re-checked after the await; the user can
    ///   revoke consent or leave the screen while the model works.
    func analyzeCurrentFrame(
        contextID: UUID,
        visualConsentGranted: @escaping @MainActor () -> Bool,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) async -> Outcome {
        guard visualConsentGranted(), isStillCurrent(),
              let frame = cache.take(matching: contextID) else { return .notEligible }

        let response: ScreenAgentVisionResponse
        do {
            response = try await transport.analyze(
                ScreenAgentVisionRequest(contextID: contextID, jpeg: frame.jpeg))
        } catch {
            NSLog("[ScreenAgentVision] transport failed: %@", error.localizedDescription)
            return .failed
        }

        // Same-frame proof, both directions: the answer names the question it
        // is answering, and the world has not moved on meanwhile. Consent is
        // re-checked because revoking it mid-call must discard the result.
        guard response.contextID == contextID,
              visualConsentGranted(), isStillCurrent() else { return .stale }
        return .facts(response.facts)
    }
}
