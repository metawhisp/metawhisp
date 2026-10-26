import Foundation

/// Asks the agent's text model through the Pro server (ITER-076 A1, S2): the
/// one client every model call of the agent shares. It also carries a failed
/// errand's report to the Pro server (`report`, ITER-076 I-06b).
///
/// `POST /api/pro/agent` carries the user's Pro license, the messages, a
/// strict JSON schema or tools, and the purpose the call is metered under; the
/// server picks the model (its default arm, the one the owner switches it to,
/// or the arm the call names) and tries its providers itself. Every call ends in one of five
/// outcomes, as `JevEngine`'s do — marked `notSent` when its request never left
/// the Mac — and the caller acts only on `.answered`. The client logs numbers
/// and the purpose only: the messages and the answer hold the user's page and
/// words. JSON values are the codebase's own (`CDPValue`).
struct ProLLMClient: Sendable {
    typealias Send = JevEngine.Send

    /// One call: what it is for, and what the model reads.
    struct Request: Sendable, Equatable {
        enum Purpose: String, Sendable, Codable, CaseIterable {
            case plan, subgoal, fieldText = "field_text", read, verify, recover
        }

        let purpose: Purpose
        let messages: [CDPValue]
        var responseFormat: CDPValue? = nil
        var tools: [CDPValue]? = nil
        var toolChoice: CDPValue? = nil
        var maxTokens: Int? = nil
        /// The server's arm this call names (the route's `provider`), when the
        /// caller chooses one — the brain's; nil leaves the arm to the server.
        var arm: String? = nil
    }

    /// A function the model asked to call, its arguments as the JSON text it wrote.
    struct ToolCall: Sendable, Equatable {
        let id: String
        let name: String
        let arguments: String
    }

    struct Answer: Sendable, Equatable {
        /// The model's text; empty only beside a tool call.
        let text: String
        let toolCalls: [ToolCall]
        let finishReason: String
        let inputTokens: Int
        let outputTokens: Int
        /// What the call cost, when the server knows the model's price.
        let costUSD: Double?

        /// What settles the errand's reservation: nil counts it whole (§8).
        var usage: EngineUsage? { costUSD.map { EngineUsage(costUSD: $0) } }
    }

    enum Refusal: Sendable, Equatable {
        /// No Pro license, or the server did not accept it.
        case noPro
        /// The route's daily ceiling for this license, until the next UTC day.
        case dailyLimit(retryAfter: Duration?)
        /// The owner switched the agent off on the server (ITER-076 stage 9d,
        /// № 27): its 503 with `X-Agent-Switch: off`. No outage — nothing to
        /// wait out or report.
        case switchedOff
    }

    enum Outcome: Sendable, Equatable {
        /// The model's text or its tool calls, never neither.
        case answered(Answer)
        /// The model could not answer now: no network, or the server's 503. Worth asking again later.
        case unavailable(retryAfter: Duration?)
        /// The request or the answer broke the contract. Nothing may be done on it.
        case invalid
        /// Time ran out first: the caller's own limit, or a 504. The agent
        /// route sends no 504 itself: when its `deadline_ms` passes it answers
        /// 503 with Retry-After 60, which reads as `.unavailable`. A caller
        /// that was cancelled also gets this; it checks its own cancellation
        /// before counting a timeout.
        case timedOut
        case refused(Refusal)
        /// Refused here, before the request left the Mac — no license, a
        /// request the server would refuse, or too late to send (ITER-076
        /// stage 8a): what the call came to, and nothing spent on it.
        indirect case notSent(Outcome)
    }

    static let endpoint = URL(string: "https://api.metawhisp.com/api/pro/agent")!
    /// The most the route reads (`AGENT_MAX_BODY_BYTES`); a bigger body is never sent.
    static let maxBodyBytes = 262_144
    /// The most provider tries the route makes for one call, each of which may
    /// be billed: the arm a request or the owner names, once — MiniMax-M3 when
    /// switched on — then Groq up to twice and Cerebras once (the worker's
    /// `handleProAgent` and `runChatCompletionWithin`, `index.js`).
    static let maxTries = 4
    /// Where a failed errand's report goes (ITER-076 I-06b).
    static let reportEndpoint = URL(string: "https://api.metawhisp.com/api/pro/errand-report")!

    /// How a failed errand's report went (ITER-076 I-06b).
    enum ReportDelivery: String, Sendable, Equatable {
        /// The server kept it, or had it already.
        case delivered
        /// The server refused it as it is (400, 413): sent again, it would fail again.
        case refused
        /// Not now: no Pro, the day's limit, the service down, or no network.
        case later
    }

    private let licenseKey: @Sendable () async -> String?
    private let send: Send
    private let log: @Sendable (String) -> Void

    init(licenseKey: @escaping @Sendable () async -> String? = {
             await MainActor.run { JevEngine.proKey(isPro: LicenseService.shared.isPro, key: LicenseService.shared.licenseKey) }
         },
         send: @escaping Send = { try await URLSession.shared.data(for: $0) },
         log: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }) {
        self.licenseKey = licenseKey
        self.send = send
        self.log = log
    }

    /// Asks for one answer to `request`, within `limit` counted from this
    /// call: reading the license counts too.
    func ask(_ request: Request, within limit: Duration) async -> Outcome {
        let clock = ContinuousClock()
        let started = clock.now
        var outcome = Outcome.notSent(.timedOut)
        let answerer = Answerer()
        if !Task.isCancelled {
            // The exchange never throws: every failure is already an outcome,
            // so `nil` from the deadline means late or cancelled, never an error.
            outcome = await Deadline.run(within: limit) { [self] () async -> Outcome in
                await self.exchange(request, until: started + limit, answerer: answerer)
            } ?? .timedOut
        }
        let ms = Int((clock.now - started) / .milliseconds(1))
        let bytes = (try? Self.body(request, deadlineMs: 0).count) ?? 0
        log("[ProLLM] \(Self.logName(outcome, cancelled: Task.isCancelled)) purpose=\(request.purpose.rawValue)"
            + " messages=\(request.messages.count) bytes=\(bytes) ms=\(ms)" + (answerer.by.map { " by=\($0)" } ?? ""))
        return outcome
    }

    /// Who answered a call, for the log: the route's provider and model, so a
    /// user's log says which brain ran an errand (2026-10-20). Written by the
    /// exchange, read once it has returned.
    private final class Answerer: @unchecked Sendable {
        var by: String?
    }

    /// The route's provider and model as its answer names them.
    static func answeredBy(_ data: Data) -> String? {
        struct Signed: Decodable {
            let provider: String?
            let model: String?
        }
        guard let signed = try? JSONDecoder().decode(Signed.self, from: data),
              signed.provider != nil || signed.model != nil else { return nil }
        return "\(signed.provider ?? "?") model=\(signed.model ?? "?")"
    }

    /// Sends a failed errand's report, `body` as `ErrandReporter` built it, with
    /// the user's Pro license (ITER-076 I-06b). Without a Pro license nothing is
    /// sent. The log holds how it went and its size only.
    func report(_ body: Data) async -> ReportDelivery {
        guard let key = await licenseKey(), !key.isEmpty else { return .later }
        var request = URLRequest(url: Self.reportEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15
        var status = 0
        if let (_, response) = try? await send(request) { status = (response as? HTTPURLResponse)?.statusCode ?? 0 }
        let delivery: ReportDelivery = (200..<300).contains(status) ? .delivered
            : [400, 413].contains(status) ? .refused : .later
        log("[ProLLM] errand report \(delivery.rawValue) status=\(status) bytes=\(body.count)")
        return delivery
    }

    /// The work `ask` runs under its deadline. Internal for tests: a test runs
    /// it as a task already stopped. Callers use `ask`: this has no deadline
    /// of its own, no Stop check before it and no log line.
    func exchange(_ ask: Request, until cutoff: ContinuousClock.Instant) async -> Outcome {
        await exchange(ask, until: cutoff, answerer: Answerer())
    }

    private func exchange(_ ask: Request, until cutoff: ContinuousClock.Instant, answerer: Answerer) async -> Outcome {
        // Begun after Stop: not even the license is read.
        guard !Task.isCancelled else { return .notSent(.timedOut) }
        guard let key = await licenseKey(), !key.isEmpty else { return .notSent(.refused(.noPro)) }
        // What the server refuses (a 400) is never sent: no messages, or
        // tools beside a schema — Groq serves structured output without tools.
        guard !ask.messages.isEmpty, ask.tools == nil || ask.responseFormat == nil else { return .notSent(.invalid) }
        let left = cutoff - ContinuousClock.now
        guard let data = try? Self.body(ask, deadlineMs: JevEngine.serverDeadlineMs(for: left)),
              data.count <= Self.maxBodyBytes else { return .notSent(.invalid) }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = max(1, left / .seconds(1))
        // Late work never sends: nobody waits for it, and the prompts would
        // be uploaded for nothing.
        guard !Task.isCancelled, ContinuousClock.now < cutoff else { return .notSent(.timedOut) }
        do {
            let (data, response) = try await send(request)
            let outcome = Self.outcome(for: data, response: response)
            if case .answered = outcome { answerer.by = Self.answeredBy(data) }
            return outcome
        } catch {
            return .unavailable(retryAfter: nil)
        }
    }

    static func outcome(for data: Data, response: URLResponse) -> Outcome {
        guard let http = response as? HTTPURLResponse else { return .unavailable(retryAfter: nil) }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .flatMap { $0 >= 0 ? Duration.seconds($0) : nil }
        switch http.statusCode {
        case 200..<300:
            guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return .invalid }
            let calls = (wire.tool_calls ?? []).map {
                ToolCall(id: $0.id ?? "", name: $0.function.name, arguments: $0.function.arguments)
            }
            guard !wire.text.isEmpty || !calls.isEmpty else { return .invalid }
            return .answered(Answer(text: wire.text, toolCalls: calls, finishReason: wire.finish_reason ?? "stop",
                                    inputTokens: wire.usage?.input_tokens ?? 0,
                                    outputTokens: wire.usage?.output_tokens ?? 0, costUSD: wire.cost_usd))
        case 401:
            return .refused(.noPro)
        // The route's own daily ceiling: a provider's 429 reaches the app as 503.
        case 429:
            return .refused(.dailyLimit(retryAfter: retryAfter))
        case 504:
            return .timedOut
        case 503 where http.value(forHTTPHeaderField: JevEngine.switchHeader) == "off":
            return .refused(.switchedOff)
        // 403, 404 and 408 are the service's: a blocked account, a missing
        // model, a timeout.
        case 400..<500 where ![403, 404, 408].contains(http.statusCode):
            // A request refused as it was, by the server (400) or by a
            // provider whose 4xx it passes on, would fail the same way again.
            return .invalid
        // The server's 502 is the model answering with nothing usable on every
        // try (S3): asking again may work, at once. Its 503 is an outage.
        default:
            return .unavailable(retryAfter: retryAfter)
        }
    }

    /// A cancelled call that came to nothing is logged as cancelled, not as a
    /// timeout; an answer that arrived first is logged as what it was.
    static func logName(_ outcome: Outcome, cancelled: Bool) -> String {
        if cancelled, outcome == .timedOut { return "cancelled" }
        return switch outcome {
        case .notSent(let refused): logName(refused, cancelled: cancelled)
        case .answered: "answered"
        case .unavailable: "unavailable"
        case .invalid: "invalid"
        case .timedOut: "timed_out"
        case .refused(.noPro): "refused_no_pro"
        case .refused(.dailyLimit): "refused_daily_limit"
        case .refused(.switchedOff): "refused_switched_off"
        }
    }

    /// The route's body: the purpose, the messages and what goes with them,
    /// and the server's deadline. Nothing the request does not hold is sent.
    static func body(_ request: Request, deadlineMs: Int) throws -> Data {
        var fields: [String: CDPValue] = [
            "purpose": .string(request.purpose.rawValue),
            "messages": .array(request.messages),
            "deadline_ms": .number(Double(deadlineMs)),
        ]
        if let format = request.responseFormat { fields["response_format"] = format }
        if let tools = request.tools { fields["tools"] = .array(tools) }
        if let choice = request.toolChoice { fields["tool_choice"] = choice }
        if let max = request.maxTokens { fields["max_tokens"] = .number(Double(max)) }
        if let arm = request.arm { fields["provider"] = .string(arm) }
        return try JSONEncoder().encode(CDPValue.object(fields))
    }

    /// The route's answer as it comes over the wire.
    private struct Wire: Decodable {
        struct Call: Decodable {
            struct Function: Decodable {
                let name: String
                let arguments: String
            }

            let id: String?
            let function: Function
        }

        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
        }

        let text: String
        let tool_calls: [Call]?
        let finish_reason: String?
        let usage: Usage?
        let cost_usd: Double?
    }
}
