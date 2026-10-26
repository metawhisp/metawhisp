import Foundation
@testable import MetaWhisp

/// The agent's text model as the Pro server answers it, recorded (ITER-076
/// brain): every request is kept byte for byte, and each is answered from a
/// script by its purpose and its number among that purpose's requests, from
/// 0. Nothing reaches the network.
final class RecordedModel: @unchecked Sendable {
    /// One request: its purpose, its body and its messages.
    struct Asked: @unchecked Sendable {
        let purpose: String
        let body: [String: Any]

        var messages: [[String: Any]] { body["messages"] as? [[String: Any]] ?? [] }
        /// Each message's content, as the model reads it.
        var contents: [String?] { messages.map { $0["content"] as? String } }
    }

    /// How the server answers one request.
    indirect enum Reply {
        case status(Int, retryAfter: String? = nil)
        /// The owner's switch on the server is off (ITER-076 stage 9d, № 27).
        case switchedOff
        /// The model's text alone.
        case text(String)
        /// Tool calls, each `browser_do` with these arguments, with an id of
        /// its own; and the model's text beside them.
        case calls([String], text: String = "")
        /// That answer, this late.
        case after(Duration, Reply)
    }

    private let lock = NSLock()
    private var asked: [Asked] = []
    private var sent: [Data] = []
    private var counts: [String: Int] = [:]
    private let script: @Sendable (Asked, Int) -> Reply
    /// What each answer says it cost; nil, as the server says it when a try's
    /// cost is not known: the run then counts the call's whole worst case.
    private let costUSD: Double?

    init(costUSD: Double? = 0.0002, _ script: @escaping @Sendable (Asked, Int) -> Reply) {
        self.costUSD = costUSD
        self.script = script
    }

    var requests: [Asked] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    /// Every request's body, byte for byte, as it went out.
    var bodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func requests(_ purpose: String) -> [Asked] { requests.filter { $0.purpose == purpose } }

    /// The most each request that went out may cost, in order (ITER-076
    /// stage 10b): four provider tries — the arm the owner may switch on once,
    /// Groq twice, Cerebras once — each reading the body that went out, its
    /// deadline written as 0 (no model reads it), with 1,024 tokens of chat
    /// template, and writing the request's cap or the route's 4,096, at
    /// MiniMax-M3's $0.30 in and $1.20 out per million.
    var worstCases: [Double] { bodies.map(Self.worstCase) }

    static func worstCase(of body: Data) -> Double {
        let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let deadline = fields["deadline_ms"] as? Int ?? 0
        let bytes = body.count - String(deadline).count + 1
        let output = fields["max_tokens"] as? Int ?? 4_096
        return 4 * (Double(bytes + 1_024) * 0.30 + Double(output) * 1.20) / 1_000_000
    }

    /// What each call of the text model on `record` cost as the run counted
    /// it, in order — the plan's first, unless `plan` is false.
    static func costs(on record: ErrandRecord, plan: Bool = true) -> [Double] {
        record.events.compactMap { event -> Double? in
            switch event {
            case .plan(_, _, let cost): return plan ? cost : nil
            case .model(_, _, _, let cost): return cost
            default: return nil
            }
        }
    }

    /// The client, with a test license.
    var client: ProLLMClient {
        ProLLMClient(licenseKey: { "LICENSE-1" }, send: { try await self.send($0) }, log: { _ in })
    }

    var model: ErrandModel { ErrandModel(client: client) }
    var planner: TextPlanner { TextPlanner(client: client) }

    private func keep(_ one: Asked, _ data: Data) -> Int {
        lock.lock()
        defer { lock.unlock() }
        asked.append(one)
        sent.append(data)
        let number = counts[one.purpose, default: 0]
        counts[one.purpose] = number + 1
        return number
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let data = request.httpBody ?? Data()
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let one = Asked(purpose: body["purpose"] as? String ?? "", body: body)
        var reply = script(one, keep(one, data))
        while case .after(let delay, let later) = reply {
            try await Task.sleep(for: delay)
            reply = later
        }
        let answer: [String: Any]
        switch reply {
        case .after:
            fatalError("unwrapped above")
        case .status(let code, let retryAfter):
            return (Data(), HTTPURLResponse(url: ProLLMClient.endpoint, statusCode: code, httpVersion: nil,
                                            headerFields: retryAfter.map { ["Retry-After": $0] })!)
        case .switchedOff:
            return (Data(#"{"error":"agent switched off"}"#.utf8),
                    HTTPURLResponse(url: ProLLMClient.endpoint, statusCode: 503, httpVersion: nil,
                                    headerFields: ["X-Agent-Switch": "off"])!)
        case .text(let text):
            answer = ["text": text, "tool_calls": NSNull(), "finish_reason": "stop"]
        case .calls(let arguments, let text):
            let calls = arguments.enumerated().map { index, arguments -> [String: Any] in
                ["id": "call_\(index + 1)", "type": "function",
                 "function": ["name": ErrandModel.tool, "arguments": arguments]]
            }
            answer = ["text": text, "tool_calls": calls, "finish_reason": "tool_calls"]
        }
        var whole = answer
        whole["usage"] = ["input_tokens": 1_000, "output_tokens": 50]
        whole["cost_usd"] = costUSD ?? NSNull()
        whole["provider"] = "groq"
        whole["model"] = "openai/gpt-oss-120b"
        return (try JSONSerialization.data(withJSONObject: whole),
                HTTPURLResponse(url: ProLLMClient.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    /// The arguments of a call that names `goal`.
    static func goal(_ goal: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["goal": goal]), as: UTF8.self)
    }

    /// A plan's answer, as the strict schema writes it.
    static func plan(_ requirements: [(id: String, text: String, kind: String)], answer: Bool = true) -> String {
        let listed = requirements.map { ["id": $0.id, "text": $0.text, "kind": $0.kind] }
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["requirements": listed,
                                                                             "answer_expected": answer]),
                      as: UTF8.self)
    }

    /// A reader's answer, as the strict schema writes it.
    static func reading(_ claims: [[String: Any]], answered: Bool = false) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["claims": claims, "answered": answered]),
               as: UTF8.self)
    }

    /// One claim of a reader's answer: the run of blocks it cites, or none,
    /// what it draws on, its records, its words and its requirement.
    static func claim(cite: (String, String)?, drawsOn: [String] = [], records: [(String, String)] = [],
                      text: String = "", requirement: String? = nil) -> [String: Any] {
        let run = { (cite: (String, String)) -> [String: Any] in ["first": cite.0, "last": cite.1] }
        return ["cite": cite.map(run) ?? NSNull(), "draws_on": drawsOn, "records": records.map(run), "text": text,
                "requirement_id": requirement ?? NSNull()]
    }

    /// The ten jokes asked for, in order: six on `site-408`, four on
    /// `site-409` (ITER-076 stage 1).
    static let tenJokes = [
        "Joke 1: The baker quit because he could not make enough dough.",
        "Joke 2: The broom was late because it overswept.",
        "Joke 3: The cookie saw a doctor because it felt crummy.",
        "Joke 4: The stadium got hot because all the fans left.",
        "Joke 5: The hungry clock went back for seconds.",
        "Joke 6: The duck paid with its bill.",
        "Joke 7: The magnet felt drawn to the fridge.",
        "Joke 8: The bank teller was full of interest.",
        "Joke 9: The orange stopped rolling because it ran out of juice.",
        "Joke 10: The bee got married because it found its honey.",
    ]

    /// The reader of those two pages, as the approved text asks it to read:
    /// on `site-408`, a claim for its heading and one for each of its six
    /// jokes, none with the requirement's id — none answers it whole; on
    /// `site-409`, one claim for r1 that records its four jokes and draws on
    /// the six by their numbers — one number twice, one record twice; any
    /// other page, no claim.
    static func readsSixThenFour(_ asked: Asked) -> Reply {
        let content = asked.contents.last.flatMap { $0 } ?? ""
        if content.contains("URL: https://site-408.test/") {
            return .text(reading((1...7).map { claim(cite: ("main/:\($0)", "main/:\($0)"), text: "MODEL-WORDS-\($0)") }))
        }
        if content.contains("URL: https://site-409.test/") {
            return .text(reading([claim(cite: nil, drawsOn: ["2", "3", "4", "5", "6", "7", "2"],
                                        records: [("main/:2", "main/:2"), ("main/:3", "main/:3"), ("main/:4", "main/:4"),
                                                  ("main/:5", "main/:5"), ("main/:2", "main/:2")],
                                        text: "MODEL-WORDS-ALL", requirement: "r1")], answered: true))
        }
        return .text(reading([]))
    }

    /// A verifier's answer, as its strict schema writes it.
    static func verdict(complete: Bool, missing: [String] = [], ungrounded: [String] = []) -> Reply {
        .text(String(decoding: try! JSONSerialization.data(withJSONObject: ["missing": missing, "ungrounded": ungrounded,
                                                                            "complete": complete]), as: UTF8.self))
    }
}
