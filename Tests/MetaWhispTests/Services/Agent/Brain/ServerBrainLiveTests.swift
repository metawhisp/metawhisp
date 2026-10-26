import XCTest
@testable import MetaWhisp

/// The product's brain through the real Pro server (2026-10-20): one step call on the product's arm comes back as
/// the AgentOutput tool call, answered by the arm the app named and priced — the proof, on this Mac, that a user's
/// errand thinks on our own providers, MiniMax or Groq. One call, a few thousand tokens, on the owner's licence as
/// the live bench reads it.
/// Runs only with METAWHISP_LIVE_SERVER=1: it needs the network, the server and a licence, and the regression gate
/// must not.
@MainActor
final class ServerBrainLiveTests: XCTestCase {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [String] = []
        func add(_ line: String) { lock.lock(); kept.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return kept }
    }

    func testTheProductArmAnswersAStepWithTheAgentOutputTool() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["METAWHISP_LIVE_SERVER"] == "1",
                          "set METAWHISP_LIVE_SERVER=1 to call the real server")
        let (key, status) = BenchLicence.read()
        guard let key else { throw XCTSkip("no Pro licence in the keychain (status \(status))") }
        let lines = Lines()
        let client = ProLLMClient(licenseKey: { key }, log: { lines.add($0) })
        let brain = ServerBrain(client: client, arm: ServerBrain.productArm)
        let state = """
        <user_request>Open the pricing page.</user_request>
        <browser_state>
        Current url: https://example.test/
        Interactive elements:
        [1]<a href="/pricing">Pricing</a>
        [2]<a href="/about">About</a>
        </browser_state>
        <step_info>Step 1 of 10</step_info>
        """
        let messages: [CDPValue] = [
            ["role": "system", "content": .string(BrainPrompt.system(maxActions: 3))],
            ["role": "user", "content": .string(state)],
        ]
        let outcome = try await brain.think(messages, tools: [BrainPrompt.tool])
        guard case .answered(let answer) = outcome else { return XCTFail("the server did not answer: \(outcome)") }
        XCTAssertEqual(answer.toolCalls.first?.name, "AgentOutput", answer.text)
        XCTAssertNotNil(answer.costUSD, "the server prices the product's arm")
        let line = try XCTUnwrap(lines.all.first { $0.hasPrefix("[ProLLM] answered") })
        XCTAssertTrue(line.contains(" by=minimax ") || line.contains(" by=groq "), line)
    }
}
