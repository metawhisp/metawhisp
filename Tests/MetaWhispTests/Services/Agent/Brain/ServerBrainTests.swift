import XCTest
@testable import MetaWhisp

/// The brain through the Pro server: a step's call is made to call the AgentOutput tool; an extract's or the check's
/// call offers no tool.
@MainActor
final class ServerBrainTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [URLRequest] = []
        func record(_ request: URLRequest) { lock.lock(); sent.append(request); lock.unlock() }
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return sent }
    }

    private static let answered = #"{"text":"ok","tool_calls":null,"finish_reason":"stop","usage":{"input_tokens":10,"output_tokens":2},"cost_usd":0.0,"provider":"groq","model":"openai/gpt-oss-120b"}"#

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request?.httpBody)) as? [String: Any])
    }

    func testAStepCallForcesTheAgentOutputToolAndAnExtractOffersNone() async throws {
        let recorder = Recorder()
        let client = ProLLMClient(licenseKey: { "LICENSE-1" }, send: { request in
            recorder.record(request)
            return (Data(Self.answered.utf8),
                    HTTPURLResponse(url: ProLLMClient.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, log: { _ in })
        let brain = ServerBrain(client: client)
        _ = try await brain.think([["role": "user", "content": "step"]], tools: [BrainPrompt.tool])
        _ = try await brain.think([["role": "user", "content": "extract"]], tools: [])
        XCTAssertEqual(recorder.requests.count, 2)
        let step = try body(recorder.requests.first)
        let choice = try XCTUnwrap(step["tool_choice"] as? [String: Any])
        XCTAssertEqual(choice["type"] as? String, "function")
        XCTAssertEqual((choice["function"] as? [String: Any])?["name"] as? String, "AgentOutput")
        XCTAssertEqual((step["tools"] as? [Any])?.count, 1)
        let extract = try body(recorder.requests.last)
        XCTAssertNil(extract["tool_choice"])
        XCTAssertNil(extract["tools"])
    }

    /// The JSON-schema keywords the Pro server's agent route takes in a tool's parameters — `agentSchemaOk` and
    /// `AGENT_SCHEMA_PLAIN` in the worker's index.js, read 2026-10-20 — and how deep it reads (`AGENT_SCHEMA_DEPTH`).
    /// Any other keyword makes the route refuse the call with a 400.
    private static let routeKeywords: Set<String> = [
        "description", "title", "format", "pattern", "$ref", "const", "enum", "type",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minItems", "maxItems", "minLength", "maxLength",
        "properties", "$defs", "items", "additionalProperties", "anyOf", "required",
    ]
    private static let routeDepth = 24

    /// Every place in `schema` the route would refuse: a keyword it does not take, or a level past its depth.
    private func refusedByTheRoute(_ schema: CDPValue, at path: String, depth: Int = 0) -> [String] {
        guard let object = schema.object, depth <= Self.routeDepth else { return [path] }
        var refused: [String] = []
        for (keyword, value) in object {
            guard Self.routeKeywords.contains(keyword) else { refused.append("\(path).\(keyword)"); continue }
            switch keyword {
            case "properties", "$defs":
                for (name, inner) in value.object ?? [:] {
                    refused += refusedByTheRoute(inner, at: "\(path).\(keyword).\(name)", depth: depth + 1)
                }
            case "items":
                refused += refusedByTheRoute(value, at: "\(path).items", depth: depth + 1)
            case "additionalProperties" where value.bool == nil:
                refused += refusedByTheRoute(value, at: "\(path).additionalProperties", depth: depth + 1)
            case "anyOf":
                for (place, inner) in (value.array ?? []).enumerated() {
                    refused += refusedByTheRoute(inner, at: "\(path).anyOf[\(place)]", depth: depth + 1)
                }
            default:
                break
            }
        }
        return refused.sorted()
    }

    /// The brain's one tool goes through the Pro server on every step, so it holds only the schema the route takes
    /// (2026-10-20: `minProperties`/`maxProperties` made the route refuse every step — the bench, which reached
    /// the models directly, never met the route). With METAWHISP_DUMP_BRAIN_BODY set, the exact body of a step is
    /// written there, for the worker's own check in node.
    func testTheBrainsToolHoldsOnlyTheSchemaTheServerTakes() throws {
        for tool in [BrainPrompt.tool, BrainPrompt.tableTool] {
            let parameters = try XCTUnwrap(tool["function"]?["parameters"])
            XCTAssertEqual(refusedByTheRoute(parameters, at: "parameters"), [])
        }
        if let path = ProcessInfo.processInfo.environment["METAWHISP_DUMP_BRAIN_BODY"] {
            let messages: [CDPValue] = [
                ["role": "system", "content": .string(BrainPrompt.system(maxActions: 3))],
                ["role": "user", "content": "<user_request>\nOpen the pricing page.\n</user_request>"],
            ]
            for (tool, file) in [(BrainPrompt.tool, path), (BrainPrompt.tableTool, path + ".table")] {
                let request = ProLLMClient.Request(purpose: .subgoal, messages: messages, tools: [tool],
                                                   toolChoice: ServerBrain.forced, arm: ServerBrain.productArm)
                try ProLLMClient.body(request, deadlineMs: 89_000).write(to: URL(fileURLWithPath: file))
            }
        }
    }

    /// The brain made for the product names its arm on every call — the route's `provider` — and one made for none
    /// leaves the arm to the server (owner, 2026-10-20: the product's brain runs on our own providers, Groq then
    /// Cerebras; never OpenRouter; owner, 2026-10-21: MiniMax for every user, Groq its fallback).
    func testABrainMadeForAnArmNamesItOnEveryCallAndOneMadeForNoneLeavesItToTheServer() async throws {
        let recorder = Recorder()
        let client = ProLLMClient(licenseKey: { "LICENSE-1" }, send: { request in
            recorder.record(request)
            return (Data(Self.answered.utf8),
                    HTTPURLResponse(url: ProLLMClient.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, log: { _ in })
        let product = ServerBrain(client: client, arm: ServerBrain.productArm)
        _ = try await product.think([["role": "user", "content": "step"]], tools: [BrainPrompt.tool])
        _ = try await product.think([["role": "user", "content": "extract"]], tools: [])
        let plain = ServerBrain(client: client)
        _ = try await plain.think([["role": "user", "content": "step"]], tools: [BrainPrompt.tool])
        XCTAssertEqual(recorder.requests.count, 3)
        XCTAssertEqual(try body(recorder.requests[0])["provider"] as? String, "minimax")
        XCTAssertEqual(try body(recorder.requests[1])["provider"] as? String, "minimax")
        XCTAssertNil(try body(recorder.requests[2])["provider"])
        XCTAssertEqual(ServerBrain.productArm, "minimax")
    }
}
