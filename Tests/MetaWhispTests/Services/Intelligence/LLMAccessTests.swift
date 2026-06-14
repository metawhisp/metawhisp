import XCTest
@testable import MetaWhisp

/// LLM-access reminder bar gate (ITER-047 Element B). Pins the truth table so
/// the bar shows/hides correctly and the Chat gate stays stricter than the
/// generic one (local LLM does not unlock Chat).
final class LLMAccessTests: XCTestCase {

    // MARK: - Generic gate (Tasks / Memories)

    func testGenericGateBlocksWhenNothingConfigured() {
        XCTAssertFalse(LLMAccess.has(apiKey: "", isPro: false, localReady: false))
    }

    func testGenericGateOpensOnAnySource() {
        XCTAssertTrue(LLMAccess.has(apiKey: "sk-123", isPro: false, localReady: false), "API key grants access")
        XCTAssertTrue(LLMAccess.has(apiKey: "", isPro: true, localReady: false), "Pro grants access")
        XCTAssertTrue(LLMAccess.has(apiKey: "", isPro: false, localReady: true), "ready local LLM grants access")
    }

    // MARK: - Chat gate (stricter — local LLM excluded)

    func testChatGateIgnoresLocalLLM() {
        // A ready local LLM must NOT unlock Chat: only key or Pro.
        XCTAssertFalse(LLMAccess.hasForChat(apiKey: "", isPro: false))
        XCTAssertTrue(LLMAccess.hasForChat(apiKey: "sk-123", isPro: false))
        XCTAssertTrue(LLMAccess.hasForChat(apiKey: "", isPro: true))
    }

    /// The divergence that motivates two functions: same inputs, different
    /// verdicts when only a local LLM is ready.
    func testChatIsStricterThanGenericForLocalOnly() {
        XCTAssertTrue(LLMAccess.has(apiKey: "", isPro: false, localReady: true))
        XCTAssertFalse(LLMAccess.hasForChat(apiKey: "", isPro: false))
    }
}
