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

    /// Chat gate. ITER-051 F1.5 — a ready local LLM now COUNTS: MetaChat runs
    /// through the text agentic loop (read-only search tools work; mutations
    /// use the same confirm flow). Keep in sync with `ChatService.hasLLMAccess`.
    static func hasForChat(apiKey: String, isPro: Bool, localReady: Bool) -> Bool {
        !apiKey.isEmpty || isPro || localReady
    }
}
