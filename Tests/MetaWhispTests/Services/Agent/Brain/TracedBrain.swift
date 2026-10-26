import Foundation
@testable import MetaWhisp

/// A brain whose every call — the step's state and its answer — is kept in the bench's trace, one JSON line a call,
/// as `EndpointBrain` keeps its own (2026-10-21: a product-path run left no record of what the brain saw, and a
/// blind errand that wandered for 39 steps could not be read).
final class TracedBrain: Brain, @unchecked Sendable {
    private let inner: any Brain
    private let trace: URL
    private let lock = NSLock()
    private var calls = 0

    init(_ inner: any Brain, trace: URL) {
        self.inner = inner
        self.trace = trace
    }

    func think(_ messages: [CDPValue], tools: [CDPValue]) async throws -> ProLLMClient.Outcome {
        let call: Int = lock.withLock { calls += 1; return calls }
        let began = Date()
        let outcome = try await inner.think(messages, tools: tools)
        var line: [String: CDPValue] = ["call": .number(Double(call)), "seconds": .number(Date().timeIntervalSince(began)),
                                        "state": messages.last?["content"] ?? .null]
        if case .answered(let answer) = outcome {
            line["text"] = .string(answer.text)
            line["calls"] = .array(answer.toolCalls.map { .string($0.arguments) })
        } else {
            line["outcome"] = .string(String(describing: outcome))
        }
        if let text = try? CDPValue.object(line).encoded() { try? AgentLiveBenchTests.appendLine(text + "\n", to: trace) }
        return outcome
    }
}
