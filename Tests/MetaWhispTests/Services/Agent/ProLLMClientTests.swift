import XCTest
@testable import MetaWhisp

/// ITER-076 A1, moved to S2's route — the agent reaches its text model through
/// one client over the Pro server's `POST /api/pro/agent`: messages, a strict
/// JSON schema or tools, and the purpose the call is metered under. Every call
/// ends in one of five outcomes: answered, unavailable, invalid, timed out or
/// refused.
final class ProLLMClientTests: XCTestCase {

    private static let systemText = "SENTINEL-SYSTEM-5c3e"
    private static let userText = "SENTINEL-USER-9b7d"
    private static let answerText = "SENTINEL-ANSWER-2f6a"
    private static let answered = #"{"text":"SENTINEL-ANSWER-2f6a","tool_calls":null,"finish_reason":"stop","usage":{"input_tokens":1000,"output_tokens":200},"cost_usd":0.00027,"provider":"groq","model":"openai/gpt-oss-120b"}"#
    private static let answer = ProLLMClient.Answer(text: answerText, toolCalls: [], finishReason: "stop",
                                                   inputTokens: 1000, outputTokens: 200, costUSD: 0.00027)
    private static let schema: CDPValue = .object([
        "type": .string("json_schema"),
        "json_schema": .object(["name": .string("Plan"), "strict": .bool(true),
                                "schema": .object(["type": .string("object")])]),
    ])
    private static func messages(system: String = systemText, user: String = userText) -> [CDPValue] {
        [.object(["role": .string("system"), "content": .string(system)]),
         .object(["role": .string("user"), "content": .string(user)])]
    }
    private static let request = ProLLMClient.Request(purpose: .plan, messages: messages(), responseFormat: schema)

    /// What the client sent and logged. The client calls it from its own tasks.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [URLRequest] = []
        private var logged: [String] = []

        func record(_ request: URLRequest) { lock.lock(); sent.append(request); lock.unlock() }
        func log(_ line: String) { lock.lock(); logged.append(line); lock.unlock() }
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return sent }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return logged }
    }

    private static func reply(_ status: Int, _ body: String, headers: [String: String] = [:]) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: ProLLMClient.endpoint, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    private func client(license: @escaping @Sendable () async -> String? = { "LICENSE-1" }, recorder: Recorder,
                        reply: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) -> ProLLMClient {
        ProLLMClient(licenseKey: license,
                     send: { request in
                         recorder.record(request)
                         return try await reply(request)
                     },
                     log: { recorder.log($0) })
    }

    private func complete(_ client: ProLLMClient, _ request: ProLLMClient.Request = ProLLMClientTests.request,
                          within limit: Duration = .seconds(10)) async -> ProLLMClient.Outcome {
        await client.ask(request, within: limit)
    }

    private func body(_ recorder: Recorder) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorder.requests.first?.httpBody)) as? [String: Any])
    }

    // MARK: - Answered

    func testAnAnsweredCallSendsTheLicenseAndExactlyTheAgentBody() async throws {
        let recorder = Recorder()
        let outcome = await complete(client(recorder: recorder) { _ in Self.reply(200, Self.answered) })
        XCTAssertEqual(outcome, .answered(Self.answer))

        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.metawhisp.com/api/pro/agent")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer LICENSE-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let sent = try body(recorder)
        let deadline = try XCTUnwrap(sent["deadline_ms"] as? Int)
        XCTAssertTrue((9_000...9_250).contains(deadline), "the server is asked to answer before the app stops waiting: \(deadline)")
        XCTAssertEqual(Set(sent.keys), ["purpose", "messages", "response_format", "deadline_ms"])
        XCTAssertEqual(sent["purpose"] as? String, "plan")
        let messages = try XCTUnwrap(sent["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "system", "content": Self.systemText], ["role": "user", "content": Self.userText]])
        let format = try XCTUnwrap(sent["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(request.timeoutInterval, 10, accuracy: 0.5, "the transport gives up no later than the caller")
    }

    /// A call that names a server arm sends it as the route's `provider` — one that names none sends no such field
    /// (the exact body above) — and the log says who answered: the route's provider and its model (2026-10-20: the
    /// proof, on a user's Mac, of which brain ran an errand).
    func testACallNamingAnArmSendsItAndTheLogSaysWhoAnswered() async throws {
        let recorder = Recorder()
        var request = Self.request
        request.arm = "groq"
        let outcome = await complete(client(recorder: recorder) { _ in Self.reply(200, Self.answered) }, request)
        XCTAssertEqual(outcome, .answered(Self.answer))
        let sent = try body(recorder)
        XCTAssertEqual(sent["provider"] as? String, "groq")
        XCTAssertEqual(Set(sent.keys), ["purpose", "messages", "response_format", "deadline_ms", "provider"])
        let line = try XCTUnwrap(recorder.lines.first { $0.hasPrefix("[ProLLM] answered") })
        XCTAssertTrue(line.contains(" by=groq model=openai/gpt-oss-120b"), line)
    }

    /// A tool as the server's route takes it (`agentTools` in the worker):
    /// a function with a name, a description and a parameters schema made of
    /// the keywords the route accepts. The worker refuses a tool without
    /// `parameters` with a 400 (review of A3d, round 2, N-P2-3); this test
    /// pins the shape the client sends.
    private static let tool: CDPValue = .object([
        "type": .string("function"),
        "function": .object([
            "name": .string("browser_do"),
            "description": .string("d"),
            "parameters": .object([
                "type": .string("object"),
                "properties": .object(["goal": .object(["type": .string("string")])]),
                "required": .array([.string("goal")]),
                "additionalProperties": .bool(false),
            ]),
        ]),
    ])

    /// A call with tools sends them and its tool choice, and a tool call with
    /// no text is an answer.
    func testAToolCallIsSentAndAnsweredWithoutText() async throws {
        let recorder = Recorder()
        let tool = Self.tool
        let reply = #"{"text":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"browser_do","arguments":"{\"goal\":\"Open the pricing page\"}"}}],"finish_reason":"tool_calls","usage":{"input_tokens":10,"output_tokens":5},"cost_usd":null,"provider":"groq","model":"openai/gpt-oss-120b"}"#
        let request = ProLLMClient.Request(purpose: .subgoal, messages: Self.messages(), tools: [tool],
                                           toolChoice: .string("auto"))
        let outcome = await complete(client(recorder: recorder) { _ in Self.reply(200, reply) }, request)
        XCTAssertEqual(outcome, .answered(.init(text: "", toolCalls: [.init(id: "call_1", name: "browser_do",
                                                                           arguments: #"{"goal":"Open the pricing page"}"#)],
                                                finishReason: "tool_calls", inputTokens: 10, outputTokens: 5,
                                                costUSD: nil)))
        let sent = try body(recorder)
        XCTAssertEqual(sent["purpose"] as? String, "subgoal")
        XCTAssertEqual((sent["tools"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(sent["tool_choice"] as? String, "auto")
        XCTAssertNil(sent["response_format"])
        // The tool goes out whole, in the shape the route takes.
        let function = try XCTUnwrap((sent["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
        XCTAssertEqual((sent["tools"] as? [[String: Any]])?.first?["type"] as? String, "function")
        XCTAssertEqual(function["name"] as? String, "browser_do")
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any], "the route refuses a tool without parameters")
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertEqual(parameters["required"] as? [String], ["goal"])
        XCTAssertEqual(Set(parameters.keys), ["type", "properties", "required", "additionalProperties"],
                       "only keywords the route takes")
    }

    /// The cost the server reports settles the errand's budget; with none,
    /// there is no usage, and the budget counts the reservation whole.
    func testTheReportedCostIsTheAnswersUsage() {
        XCTAssertEqual(Self.answer.usage, EngineUsage(costUSD: 0.00027))
        let unpriced = ProLLMClient.Answer(text: "x", toolCalls: [], finishReason: "stop", inputTokens: 1,
                                           outputTokens: 1, costUSD: nil)
        XCTAssertNil(unpriced.usage)
    }

    /// The server is asked to answer within what is left of the limit once
    /// the license is read, not within the whole limit.
    func testTheServersDeadlineIsWhatIsLeftAfterTheLicenseRead() async throws {
        let recorder = Recorder()
        let slowLicense: @Sendable () async -> String? = {
            try? await Task.sleep(for: .milliseconds(500))
            return "LICENSE-1"
        }
        _ = await complete(client(license: slowLicense, recorder: recorder) { _ in Self.reply(200, Self.answered) },
                           within: .seconds(3))
        let deadline = try XCTUnwrap(try body(recorder)["deadline_ms"] as? Int)
        XCTAssertTrue((1_000...1_800).contains(deadline), "3 s less the 0.5 s read, less the trip back: \(deadline)")
    }

    /// A short limit has no room for the 750 ms trip back: the server gets
    /// half of what is left.
    func testAShortLimitGivesTheServerHalfOfIt() async throws {
        let recorder = Recorder()
        _ = await complete(client(recorder: recorder) { _ in Self.reply(200, Self.answered) }, within: .seconds(1))
        let deadline = try XCTUnwrap(try body(recorder)["deadline_ms"] as? Int)
        XCTAssertTrue((450...500).contains(deadline), "half of what is left of 1 s: \(deadline)")
    }

    /// An unlimited limit is no crash: the call is answered, and the server is
    /// asked for its full cap, 120 s.
    func testAnUnlimitedLimitAsksTheServerForItsCap() async throws {
        let recorder = Recorder()
        let outcome = await complete(client(recorder: recorder) { _ in Self.reply(200, Self.answered) },
                                     within: .seconds(Int64.max))
        XCTAssertEqual(outcome, .answered(Self.answer))
        XCTAssertEqual(try body(recorder)["deadline_ms"] as? Int, 120_000)
    }

    /// A limit already past is a timeout: nothing is sent, and nothing traps.
    func testANegativeLimitIsATimeoutAndSendsNothing() async {
        let recorder = Recorder()
        let outcome = await complete(client(recorder: recorder) { _ in Self.reply(200, Self.answered) },
                                     within: .seconds(Int64.min))
        XCTAssertEqual(outcome, .timedOut)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testAnyTwoHundredWithATextIsAnAnswer() async {
        let recorder = Recorder()
        let outcome = await complete(client(recorder: recorder) { _ in Self.reply(201, #"{"text":"ok"}"#) })
        XCTAssertEqual(outcome, .answered(.init(text: "ok", toolCalls: [], finishReason: "stop", inputTokens: 0,
                                                outputTokens: 0, costUSD: nil)))
    }

    // MARK: - What the server would refuse

    /// The server reads at most `ProLLMClient.maxBodyBytes`: a bigger body is
    /// never sent.
    func testABodyOverTheServersLimitIsInvalidAndNeverSent() async {
        let recorder = Recorder()
        let long = String(repeating: "x", count: ProLLMClient.maxBodyBytes)
        let outcome = await complete(client(recorder: recorder) { _ in Self.reply(200, Self.answered) },
                                     .init(purpose: .read, messages: Self.messages(user: long)))
        XCTAssertEqual(outcome, .notSent(.invalid))
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    /// No messages, or tools together with a schema, the server refuses (a
    /// 400): neither is ever sent.
    func testWhatTheServerRefusesIsInvalidAndNeverSent() async {
        let recorder = Recorder()
        let tool: CDPValue = .object(["type": .string("function")])
        for request in [ProLLMClient.Request(purpose: .plan, messages: []),
                        ProLLMClient.Request(purpose: .subgoal, messages: Self.messages(), responseFormat: Self.schema,
                                             tools: [tool])] {
            let outcome = await complete(client(recorder: recorder) { _ in Self.reply(200, Self.answered) }, request)
            XCTAssertEqual(outcome, .notSent(.invalid))
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    // MARK: - Refused

    func testWithoutProNothingIsSent() async {
        let recorder = Recorder()
        for license in [nil, ""] as [String?] {
            let outcome = await complete(client(license: { license }, recorder: recorder) { _ in
                Self.reply(200, Self.answered)
            })
            XCTAssertEqual(outcome, .notSent(.refused(.noPro)), String(describing: license))
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testTheServersRefusalOfTheLicenseIsNoPro() async {
        let outcome = await complete(client(recorder: Recorder()) { _ in
            Self.reply(401, #"{"error":"Invalid or expired license"}"#)
        })
        XCTAssertEqual(outcome, .refused(.noPro))
    }

    /// The route's daily ceiling (429) is a refusal until the next day, with
    /// the server's Retry-After.
    func testTheDailyLimitIsARefusalWithItsRetryAfter() async {
        let outcome = await complete(client(recorder: Recorder()) { _ in
            Self.reply(429, #"{"error":"Daily agent limit reached"}"#, headers: ["Retry-After": "3600"])
        })
        XCTAssertEqual(outcome, .refused(.dailyLimit(retryAfter: .seconds(3600))))
    }

    // MARK: - Invalid

    /// A request refused as it was, by the server (400) or by a provider whose
    /// 4xx it passes on (a 422 too), would fail the same way again, whatever
    /// the body says. A 2xx without a text broke the contract.
    func testARequestRefusedAsItWasOrAnAnswerWithoutTextIsInvalid() async {
        let recorder = Recorder()
        let replies: [(Int, String)] = [
            (400, #"{"error":"Unknown purpose"}"#),
            (409, Self.answered),
            (413, "<html>Request Entity Too Large</html>"),
            (415, #"{"error":"Agent request refused"}"#),
            (422, #"{"error":"Agent request refused","details":{"groq":"refused"}}"#),
            (200, "not json"),
            (200, "{}"),
            (200, #"{"text":""}"#),
            (200, #"{"text":"","tool_calls":[]}"#),
            (200, #"{"text":5}"#),
        ]
        for (status, body) in replies {
            let outcome = await complete(client(recorder: recorder) { _ in Self.reply(status, body) })
            XCTAssertEqual(outcome, .invalid, "\(status) \(body)")
        }
    }

    // MARK: - Unavailable

    func testTheServiceBeingDownIsUnavailable() async {
        let recorder = Recorder()
        let down = await complete(client(recorder: recorder) { _ in
            Self.reply(503, #"{"error":"Agent model unavailable"}"#, headers: ["Retry-After": "60"])
        })
        XCTAssertEqual(down, .unavailable(retryAfter: .seconds(60)))
        // The server's 502 (S3): the model gave nothing usable on every try;
        // asking again may work, at once.
        let unusable = await complete(client(recorder: recorder) { _ in
            Self.reply(502, #"{"error":"The model gave no usable answer","details":{"groq":"generation"}}"#)
        })
        XCTAssertEqual(unusable, .unavailable(retryAfter: nil))
        // As JevEngine and the server read them: a blocked account, a missing
        // model and a timeout are the service's, not the request's.
        for status in [500, 502, 403, 404, 408] {
            let outcome = await complete(client(recorder: recorder) { _ in Self.reply(status, Self.answered) })
            XCTAssertEqual(outcome, .unavailable(retryAfter: nil), "\(status)")
        }
        let offline = await complete(client(recorder: recorder) { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(offline, .unavailable(retryAfter: nil))
        let notHTTP = await complete(client(recorder: recorder) { _ in
            (Data(Self.answered.utf8),
             URLResponse(url: ProLLMClient.endpoint, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        })
        XCTAssertEqual(notHTTP, .unavailable(retryAfter: nil))
    }

    /// ITER-076 stage 9d, № 27 — the owner's switch: the server's 503 that
    /// says `X-Agent-Switch: off` is its own refusal, never an outage to wait
    /// out; a 503 that says anything else is still the service down.
    func testTheOwnersSwitchIsItsOwnRefusal() async {
        let recorder = Recorder()
        let off = await complete(client(recorder: recorder) { _ in
            Self.reply(503, #"{"error":"agent switched off"}"#, headers: ["X-Agent-Switch": "off"])
        })
        XCTAssertEqual(off, .refused(.switchedOff))
        let other = await complete(client(recorder: recorder) { _ in
            Self.reply(503, "{}", headers: ["X-Agent-Switch": "on"])
        })
        XCTAssertEqual(other, .unavailable(retryAfter: nil))
        XCTAssertEqual(ProLLMClient.logName(.refused(.switchedOff), cancelled: false), "refused_switched_off")
    }

    func testARetryAfterThatIsMissingNegativeOrNotANumberIsNone() async {
        let recorder = Recorder()
        let padded = await complete(client(recorder: recorder) { _ in
            Self.reply(503, "{}", headers: ["Retry-After": " 120 "])
        })
        XCTAssertEqual(padded, .unavailable(retryAfter: .seconds(120)))
        for header in [[:], ["Retry-After": "-5"], ["Retry-After": "soon"]] {
            let outcome = await complete(client(recorder: recorder) { _ in Self.reply(503, "{}", headers: header) })
            XCTAssertEqual(outcome, .unavailable(retryAfter: nil), "\(header)")
        }
    }

    // MARK: - Timed out

    /// The server ran out of time: that is a timeout, not an outage.
    func testTheServersOwnTimeoutIsATimeout() async {
        let outcome = await complete(client(recorder: Recorder()) { _ in
            Self.reply(504, #"{"error":"Gateway Timeout"}"#)
        })
        XCTAssertEqual(outcome, .timedOut)
    }

    /// A late answer is a timeout, the caller is not kept waiting for it, and
    /// the call in flight is cancelled.
    func testALateAnswerIsATimeoutAndItsSendIsCancelled() async {
        let recorder = Recorder()
        let dropped = expectation(description: "the late call is cancelled")
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await complete(client(recorder: recorder) { _ in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                dropped.fulfill()
                throw error
            }
            return Self.reply(200, Self.answered)
        }, within: .milliseconds(200))
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(clock.now - started, .seconds(2))
        await fulfillment(of: [dropped], timeout: 2)
    }

    /// The limit counts from the call: a license read slower than the limit
    /// uses it all, and nothing is sent even when that read ignores
    /// cancellation and ends late.
    func testALicenseReadSlowerThanTheLimitSendsNothing() async {
        let recorder = Recorder()
        let sent = expectation(description: "late work sends nothing")
        sent.isInverted = true
        let slowLicense: @Sendable () async -> String? = {
            await withCheckedContinuation { (read: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { read.resume() }
            }
            return "LICENSE-1"
        }
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await complete(client(license: slowLicense, recorder: recorder) { _ in
            sent.fulfill()
            return Self.reply(200, Self.answered)
        }, within: .milliseconds(200))
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(clock.now - started, .milliseconds(900), "the caller does not wait for the read")
        await fulfillment(of: [sent], timeout: 1.5)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    // MARK: - Stop

    /// Stop before the call: nothing starts, not even the license read, so
    /// nothing is sent; and the log says cancelled.
    func testACallStoppedBeforeItStartsSendsNothingAndSaysSo() async {
        let recorder = Recorder()
        let read = expectation(description: "a stopped call reads no license")
        read.isInverted = true
        let llm = client(license: { read.fulfill(); return "LICENSE-1" }, recorder: recorder) { _ in
            Self.reply(200, Self.answered)
        }
        let task = Task { () -> ProLLMClient.Outcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await llm.ask(Self.request, within: .seconds(10))
        }
        let outcome = await task.value
        XCTAssertEqual(outcome, .notSent(.timedOut))
        await fulfillment(of: [read], timeout: 0.5)
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertTrue(recorder.lines.last?.hasPrefix("[ProLLM] cancelled ") ?? false, recorder.lines.last ?? "no log line")
    }

    /// Holds a license read until Stop has returned, as a call that reaches
    /// its send guard just after Stop.
    private final class StopGate: @unchecked Sendable {
        private let lock = NSLock()
        private var reading = false
        private var stopped = false

        func markReading() { lock.lock(); reading = true; lock.unlock() }
        var isReading: Bool { lock.lock(); defer { lock.unlock() }; return reading }
        func markStopped() { lock.lock(); stopped = true; lock.unlock() }
        var hasStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

        /// At most 2 s, so a broken run cannot hold a thread.
        func waitForStop() {
            let end = Date().addingTimeInterval(2)
            while !hasStopped, Date() < end {}
        }
    }

    /// Once Stop has returned, the call is cancelled, so a send guard reached
    /// after it never lets the send start. Run many times: this was a race.
    func testAStopThatHasReturnedNeverLetsTheSendStart() async {
        let recorder = Recorder()
        let runs = 500
        for _ in 0..<runs {
            let gate = StopGate()
            let llm = client(license: {
                gate.markReading()
                gate.waitForStop()
                return "LICENSE-1"
            }, recorder: recorder) { _ in Self.reply(200, Self.answered) }
            let task = Task {
                await llm.ask(Self.request, within: .seconds(30))
            }
            let end = ContinuousClock.now + .seconds(2)
            while !gate.isReading, ContinuousClock.now < end { await Task.yield() }
            guard gate.isReading else { return XCTFail("the license was never read") }
            // Stop is pressed on the main thread, as the app's Stop button is.
            await MainActor.run {
                task.cancel()
                gate.markStopped()
            }
            _ = await task.value
        }
        // Every call has left its license read by now; give their guards a moment.
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(recorder.requests.count, 0, "sends that started after Stop returned, of \(runs) runs")
    }

    /// The work a call runs under its deadline, begun after Stop, reads no
    /// license: a stopped call never even asks who the user is.
    func testWorkBegunAfterStopReadsNoLicense() async {
        let recorder = Recorder()
        let read = expectation(description: "a stopped call reads no license")
        read.isInverted = true
        let llm = client(license: { read.fulfill(); return "LICENSE-1" }, recorder: recorder) { _ in
            Self.reply(200, Self.answered)
        }
        let work = Task { () -> ProLLMClient.Outcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await llm.exchange(Self.request, until: ContinuousClock.now + .seconds(10))
        }
        let outcome = await work.value
        XCTAssertEqual(outcome, .notSent(.timedOut))
        await fulfillment(of: [read], timeout: 0.5)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    /// Stop during the call: the caller is back at once, the call in flight
    /// is cancelled, and the log says cancelled.
    func testACallStoppedInFlightEndsAtOnceAndSaysSo() async {
        let recorder = Recorder()
        let inFlight = expectation(description: "the call went out")
        let dropped = expectation(description: "the call in flight is cancelled")
        let llm = client(recorder: recorder) { _ in
            inFlight.fulfill()
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                dropped.fulfill()
                throw error
            }
            return Self.reply(200, Self.answered)
        }
        let task = Task {
            await llm.ask(Self.request, within: .seconds(10))
        }
        await fulfillment(of: [inFlight], timeout: 2)
        let clock = ContinuousClock()
        let stopped = clock.now
        task.cancel()
        let outcome = await task.value
        XCTAssertLessThan(clock.now - stopped, .seconds(1), "the caller is back at once")
        XCTAssertEqual(outcome, .timedOut)
        await fulfillment(of: [dropped], timeout: 2)
        XCTAssertTrue(recorder.lines.last?.hasPrefix("[ProLLM] cancelled ") ?? false, recorder.lines.last ?? "no log line")
    }

    // MARK: - Log

    func testTheLogHoldsNumbersOnly() async {
        let recorder = Recorder()
        _ = await complete(client(recorder: recorder) { _ in Self.reply(200, Self.answered) })
        // An upstream can echo the prompts back inside its error.
        _ = await complete(client(recorder: recorder) { _ in
            Self.reply(400, #"{"error":"\#(Self.userText)","details":{"groq":"\#(Self.systemText)"}}"#)
        })
        _ = await complete(client(license: { nil }, recorder: recorder) { _ in Self.reply(200, Self.answered) })
        let lines = recorder.lines
        XCTAssertEqual(lines.count, 3, "one line per call")
        for line in lines {
            for text in [Self.systemText, Self.userText, Self.answerText, "LICENSE-1"] {
                XCTAssertFalse(line.contains(text), line)
            }
        }
        guard lines.count == 3 else { return }
        XCTAssertTrue(lines[0].hasPrefix("[ProLLM] answered purpose=plan messages=2 bytes="), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("[ProLLM] invalid purpose=plan "), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("[ProLLM] refused_no_pro purpose=plan "), lines[2])
    }

    /// Only a cancelled call that came to nothing is logged as cancelled; an
    /// answer that arrived first is logged as what it was.
    func testTheLogNamesCancelledOnlyWhenNothingCameOfIt() {
        XCTAssertEqual(ProLLMClient.logName(.timedOut, cancelled: true), "cancelled")
        XCTAssertEqual(ProLLMClient.logName(.timedOut, cancelled: false), "timed_out")
        XCTAssertEqual(ProLLMClient.logName(.answered(Self.answer), cancelled: true), "answered")
        XCTAssertEqual(ProLLMClient.logName(.refused(.dailyLimit(retryAfter: nil)), cancelled: false),
                       "refused_daily_limit")
        XCTAssertEqual(ProLLMClient.logName(.unavailable(retryAfter: nil), cancelled: false), "unavailable")
        XCTAssertEqual(ProLLMClient.logName(.invalid, cancelled: false), "invalid")
        XCTAssertEqual(ProLLMClient.logName(.refused(.noPro), cancelled: true), "refused_no_pro")
        XCTAssertEqual(ProLLMClient.logName(.notSent(.refused(.noPro)), cancelled: false), "refused_no_pro",
                       "a call not sent is logged as what it came to")
    }
}
