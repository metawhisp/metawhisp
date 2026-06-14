import Foundation

/// UI-only access check for the "smart features need an API key or Pro" reminder
/// bar (ITER-047 Element B).
///
/// This is NOT a replacement for the per-service private `hasLLMAccess` getters
/// scattered across the intelligence services — those differ by policy (some
/// count a ready local LLM, some are cloud/Pro-only). It mirrors only the two
/// gates the reminder bar needs, so each screen's bar reflects that screen's
/// real gate.
enum LLMAccess {
    /// Generic gate — used by Tasks / Memories (and most extraction services):
    /// a cloud API key, Pro, OR a ready local LLM all grant access.
    static func has(apiKey: String, isPro: Bool, localReady: Bool) -> Bool {
        !apiKey.isEmpty || isPro || localReady
    }

    /// Chat gate — a ready local LLM does NOT count (too weak for the tool-call
    /// loop), matching `ChatService.hasLLMAccess`. Only a cloud key or Pro grant
    /// MetaChat access.
    static func hasForChat(apiKey: String, isPro: Bool) -> Bool {
        !apiKey.isEmpty || isPro
    }
}
