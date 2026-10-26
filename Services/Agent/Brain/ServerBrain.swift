import Foundation

/// The brain through the Pro server (owner decision of 2026-10-19): the agent route's own model, asked with the
/// step's messages and the AgentOutput tool under the sub-goal purpose — the route's one purpose that takes tools —
/// until the route has a purpose of its own. A step's call must be the tool's: the model is made to call it (a
/// step answered in words is a step lost; blind run 1019b, 2026-10-19); an extract's or the check's call has no
/// tool.
@MainActor
final class ServerBrain: Brain {
    /// The server's arm the product's errands think on (owner, 2026-10-21: MiniMax for every user): MiniMax-M3.1-Flash,
    /// then Groq's gpt-oss-120b when it fails — our own providers, never OpenRouter. Measured on the blind set of 20
    /// errands, 2026-10-20/21: MiniMax 17 to 18 done, the groq arm 2 (Groq could not keep the forced AgentOutput call).
    nonisolated static let productArm = "minimax"

    private let client: ProLLMClient
    /// The server's arm every call names; nil leaves it to the server.
    private let arm: String?

    init(client: ProLLMClient = ProLLMClient(), arm: String? = nil) {
        self.client = client
        self.arm = arm
    }

    /// The one tool a step offers, made the call: OpenAI's forced function choice.
    static let forced: CDPValue = ["type": "function", "function": ["name": "AgentOutput"]]

    func think(_ messages: [CDPValue], tools: [CDPValue]) async throws -> ProLLMClient.Outcome {
        await client.ask(ProLLMClient.Request(purpose: .subgoal, messages: messages, tools: tools.isEmpty ? nil : tools,
                                              toolChoice: tools.isEmpty ? nil : Self.forced, arm: arm),
                         within: AgentRun.brainDeadline)
    }
}
