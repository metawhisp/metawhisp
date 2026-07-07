import XCTest
@testable import MetaWhisp

/// LLM-access reminder bar gate (ITER-047 Element B, updated by ITER-051
/// F1.5). Pins the truth table so the bar shows/hides correctly. Since F1.5
/// the Chat gate matches the generic one: a ready local model unlocks
/// MetaChat via the text agentic loop.
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

    // MARK: - Chat gate (ITER-051 F1.5 — local model included)

    func testChatGateTruthTable() {
        XCTAssertFalse(LLMAccess.hasForChat(apiKey: "", isPro: false, localReady: false))
        XCTAssertTrue(LLMAccess.hasForChat(apiKey: "sk-123", isPro: false, localReady: false))
        XCTAssertTrue(LLMAccess.hasForChat(apiKey: "", isPro: true, localReady: false))
        XCTAssertTrue(LLMAccess.hasForChat(apiKey: "", isPro: false, localReady: true),
                      "F1.5: ready local model unlocks MetaChat (text agentic loop)")
    }
}
