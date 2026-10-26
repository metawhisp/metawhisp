import XCTest
@testable import MetaWhisp

/// A live probe, never in the gate: how MetaChat's model answers an errand
/// request — a native call, a call written as text, or no call — under the
/// rules each transport sends, with MetaChat's own tools, to the live Pro
/// server as the app sends them (2026-10-06: under the text rules 8 of 9
/// calls came as text, under the Pro proxy's 9 of 9 native). Runs only with
/// METAWHISP_CHAT_PROBE=1 and the licence in METAWHISP_BENCH_LICENCE, which is
/// never printed or written; METAWHISP_PROBE_QUESTIONS may name a file of
/// questions, one a line.
@MainActor
final class ChatErrandFormatProbeTests: XCTestCase {
    func testHowTheModelCallsAnErrand() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["METAWHISP_CHAT_PROBE"] == "1",
              let key = env["METAWHISP_BENCH_LICENCE"], !key.isEmpty else {
            throw XCTSkip("live probe: METAWHISP_CHAT_PROBE=1 and a licence")
        }
        let out = env["METAWHISP_PROBE_OUT"] ?? NSTemporaryDirectory()
        let questions = try env["METAWHISP_PROBE_QUESTIONS"].map {
            try String(contentsOfFile: $0, encoding: .utf8).split(separator: "\n").map(String.init)
        } ?? ["Look up the search results for the keyword AI image generator.",
              "find 10 jokes in the browser",
              "collect 10 MetaWhisp competitors into a table"]
        let tools = ChatToolExecutor.toolSchemas(canRunErrands: true)
        let variants = [("text-rules", ChatService.systemPrompt(canRunErrands: true)),
                        ("pro-rules", ChatService.nativeSystemPrompt(canRunErrands: true))]
        var lines = ["variant\trun\tquestion\tnative\ttext_envelope\tprovider\tmodel\ttext"]
        for (name, system) in variants {
            for question in questions {
                for run in 1...3 {
                    lines.append("\(name)\t\(run)\t\(question.prefix(28))\t"
                                 + (try await ask(system: system, question: question, tools: tools, key: key)))
                }
            }
        }
        try lines.joined(separator: "\n").write(toFile: out + "/chat-probe.tsv", atomically: true, encoding: .utf8)
    }

    /// One request exactly as `ChatService.callProChatWithTools` builds it.
    private func ask(system: String, question: String, tools: [[String: Any]], key: String) async throws -> String {
        let resolved = system
            .replacingOccurrences(of: "{{CURRENT_UTC}}", with: ISO8601DateFormatter().string(from: Date()))
            .replacingOccurrences(of: "{{USER_TZ}}", with: TimeZone.current.identifier)
        let prompt = ["<response_language>Russian</response_language>", "", "<question>", question, "</question>",
                      "", "--- CONTEXT BELOW ---", "", "<question>", question, "</question>"].joined(separator: "\n")
        var request = URLRequest(url: URL(string: "https://api.metawhisp.com/api/pro/chat-with-tools")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let body: [String: Any] = [
            "system": resolved,
            "messages": [["role": "user", "content": prompt]],
            "tools": tools,
            "tier": ChatService.llmTier.rawValue,
            "service_id": "ChatService.toolCall",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "HTTP \(status)\t-\t-\t-\t-"
        }
        let text = (obj["text"] as? String) ?? ""
        let native = ChatToolExecutor.parseNativeToolCall(from: obj["tool_calls"] as? [[String: Any]])?.tool ?? "-"
        let envelope = ChatToolExecutor.parseToolCall(from: text)?.tool
            ?? (text.contains("<tool_call>") || text.contains("<runErrand>") ? "refused" : "-")
        let shown = text.replacingOccurrences(of: "\n", with: " ").prefix(90)
        return "\(native)\t\(envelope)\t\(obj["provider"] as? String ?? "?")\t\(obj["model_used"] as? String ?? "?")\t\(shown)"
    }
}
