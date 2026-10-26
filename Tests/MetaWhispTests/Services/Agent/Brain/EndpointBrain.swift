import Foundation
@testable import MetaWhisp

/// The bench's brain (2026-10-19): any model behind an OpenAI-compatible chat-completions endpoint — the bench's
/// local proxy in front of the owner's model subscriptions — asked as the server would be. Keys stay in the proxy;
/// none comes here. What a call cost is the endpoint's `usage.cost` when it reports one, else nothing: a
/// subscription's call costs the errand nothing.
@MainActor
final class EndpointBrain: Brain {
    let endpoint: URL
    let model: String
    /// Where each call's step state and answer are kept, one JSON line a call: the bench's own trace.
    let trace: URL?
    private(set) var calls = 0

    init(endpoint: URL, model: String, trace: URL? = nil) {
        self.endpoint = endpoint
        self.model = model
        self.trace = trace
    }

    func think(_ messages: [CDPValue], tools: [CDPValue]) async throws -> ProLLMClient.Outcome {
        calls += 1
        var body: [String: CDPValue] = ["model": .string(model), "messages": .array(messages), "max_tokens": 8192]
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            body["tool_choice"] = ServerBrain.forced
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(tools.isEmpty ? "extract" : "step", forHTTPHeaderField: "X-Brain-Purpose")
        request.httpBody = try JSONEncoder().encode(CDPValue.object(body))
        request.timeoutInterval = 180
        let data: Data
        let response: URLResponse
        let began = Date()
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .unavailable(retryAfter: nil)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let outcome = Self.outcome(data, status: status)
        if let trace {
            var line: [String: CDPValue] = ["call": .number(Double(calls)), "status": .number(Double(status)),
                                            "seconds": .number(Date().timeIntervalSince(began)),
                                            "state": messages.last?["content"] ?? .null]
            if case .answered(let answer) = outcome {
                line["text"] = .string(answer.text)
                line["calls"] = .array(answer.toolCalls.map { .string($0.arguments) })
            }
            if let text = try? CDPValue.object(line).encoded() { try? AgentLiveBenchTests.appendLine(text + "\n", to: trace) }
        }
        return outcome
    }

    /// An OpenAI-compatible answer as the brain reads it.
    static func outcome(_ data: Data, status: Int) -> ProLLMClient.Outcome {
        switch status {
        case 200..<300:
            guard let answer = try? CDPValue.decode(String(decoding: data, as: UTF8.self)),
                  let message = answer["choices"]?.array?.first?["message"] else { return .invalid }
            let calls = (message["tool_calls"]?.array ?? []).compactMap { call -> ProLLMClient.ToolCall? in
                guard let name = call["function"]?["name"]?.string else { return nil }
                let arguments = call["function"]?["arguments"]
                return ProLLMClient.ToolCall(id: call["id"]?.string ?? "", name: name,
                                             arguments: arguments?.string ?? ((try? arguments?.encoded()) ?? "{}"))
            }
            let text = message["content"]?.string ?? ""
            guard !text.isEmpty || !calls.isEmpty else { return .invalid }
            let usage = answer["usage"]
            return .answered(.init(text: text, toolCalls: calls,
                                   finishReason: answer["choices"]?.array?.first?["finish_reason"]?.string ?? "stop",
                                   inputTokens: usage?["prompt_tokens"]?.int ?? 0,
                                   outputTokens: usage?["completion_tokens"]?.int ?? 0,
                                   costUSD: usage?["cost"]?.double ?? 0))
        case 429: return .refused(.dailyLimit(retryAfter: nil))
        case 401, 403: return .refused(.noPro)
        case 400..<500: return .invalid
        default: return .unavailable(retryAfter: nil)
        }
    }
}
