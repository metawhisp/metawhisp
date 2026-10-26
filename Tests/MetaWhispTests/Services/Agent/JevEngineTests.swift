import XCTest
@testable import MetaWhisp

/// ITER-076 1.2 — the app asks Jev only through the Pro server, and every call
/// ends in one of five outcomes: answered, unavailable, invalid, timed out or
/// refused. Only an answer that fits the questions asked counts as answered,
/// a late call is told apart from a failed one, and the log holds no text.
final class JevEngineTests: XCTestCase {

    private static let stateText = "SENTINEL-STATE-4d2b"
    private static let questionText = "SENTINEL-QUESTION-8a1f"
    private static let answered = #"{"model":"typesafe/jev-1.13","id":"gen-1","usage":{"input_tokens":40,"output_tokens":4},"answers":{"done":{"type":"noul","noul":0.9}}}"#

    /// What the engine sent and logged. The engine calls it from its own tasks.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [URLRequest] = []
        private var logged: [String] = []

        func record(_ request: URLRequest) { lock.lock(); sent.append(request); lock.unlock() }
        func log(_ line: String) { lock.lock(); logged.append(line); lock.unlock() }
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return sent }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return logged }
    }

    private var questions: JevQuestionSet!

    override func setUpWithError() throws {
        questions = try JevQuestionSet([
            "done": JevQuestion(instructions: Self.questionText, kind: .noul(whenTrue: nil, whenFalse: nil)),
        ])
    }

    private static func reply(_ status: Int, _ body: String, headers: [String: String] = [:]) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: JevEngine.endpoint, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    private func engine(license: String? = "LICENSE-1", recorder: Recorder,
                        licenseDelay: Duration = .zero,
                        reply: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) -> JevEngine {
        JevEngine(licenseKey: {
                      if licenseDelay > .zero { try? await Task.sleep(for: licenseDelay) }
                      return license
                  },
                  send: { request in
                      recorder.record(request)
                      return try await reply(request)
                  },
                  log: { recorder.log($0) })
    }

    private func ask(_ engine: JevEngine, within limit: Duration = .seconds(10)) async -> JevEngine.Outcome {
        await engine.ask(questions, state: ["page": Self.stateText], within: limit)
    }

    // MARK: - Answered

    func testAnAnsweredCallSendsTheLicenseTheStateAndTheQuestionsOnly() async throws {
        let recorder = Recorder()
        let outcome = await ask(engine(recorder: recorder) { _ in Self.reply(200, Self.answered) })
        guard case .answered(let response) = outcome else { return XCTFail("expected an answer, got \(outcome)") }
        XCTAssertEqual(try response.answers.noul(named: "done").value, 0.9)
        XCTAssertEqual(response.usage?.inputTokens, 40)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(request.url, JevEngine.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer LICENSE-1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["state", "questions", "deadline_ms"])
        XCTAssertEqual(body["state"] as? [String: String], ["page": Self.stateText])
        let asked = try XCTUnwrap(body["questions"] as? [String: [String: String]])
        XCTAssertEqual(asked["done"], ["type": "noul", "instructions": Self.questionText])
        let deadline = try XCTUnwrap(body["deadline_ms"] as? Int)
        XCTAssertTrue((9_000...9_250).contains(deadline), "the server is asked to answer before the app stops waiting: \(deadline)")
    }

    /// The same request is always the same bytes: keys are sent sorted,
    /// because Foundation's encoder keeps no order of its own (checked on
    /// 2026-09-27, ITER-076 1.3).
    func testTheBodysKeysAreSorted() async throws {
        let recorder = Recorder()
        _ = await engine(recorder: recorder) { _ in Self.reply(200, Self.answered) }
            .ask(questions, state: ["zeta": "1", "alpha": "2", "mid": "3", "beta": "4", "omega": "5"],
                 within: .seconds(10))
        let body = String(decoding: try XCTUnwrap(recorder.requests.first?.httpBody), as: UTF8.self)
        func order(_ keys: [String]) throws -> [String.Index] {
            try keys.map { try XCTUnwrap(body.range(of: "\"\($0)\"")?.lowerBound, $0) }
        }
        let state = try order(["alpha", "beta", "mid", "omega", "zeta"])
        XCTAssertEqual(state, state.sorted())
        let top = try order(["deadline_ms", "questions", "state"])
        XCTAssertEqual(top, top.sorted())
    }

    func testOnlyTheLicenseOfAProUserIsSent() {
        XCTAssertNil(JevEngine.proKey(isPro: false, key: "LICENSE-1"))
        XCTAssertNil(JevEngine.proKey(isPro: true, key: nil))
        XCTAssertNil(JevEngine.proKey(isPro: true, key: ""))
        XCTAssertEqual(JevEngine.proKey(isPro: true, key: "LICENSE-1"), "LICENSE-1")
    }

    func testAnyTwoHundredIsReadAndOnlyTheAskedAnswersAreKept() async throws {
        let recorder = Recorder()
        let extra = #"{"model":"m","answers":{"done":{"type":"noul","noul":0.9},"other":{"type":"noul","noul":0.1}}}"#
        let outcome = await ask(engine(recorder: recorder) { _ in Self.reply(201, extra) })
        guard case .answered(let response) = outcome else { return XCTFail("expected an answer, got \(outcome)") }
        XCTAssertEqual(response.answers.names, ["done"], "an answer nobody asked for is dropped")
    }

    func testABodyTheServerWouldRefuseIsNeverSent() async {
        let recorder = Recorder()
        let outcome = await engine(recorder: recorder) { _ in Self.reply(200, Self.answered) }
            .ask(questions, state: ["page": String(repeating: "x", count: 140_000)], within: .seconds(10))
        XCTAssertEqual(outcome, .notSent(.invalid))
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testTheServerDeadlineLeavesRoomForTheTripBack() {
        XCTAssertEqual(JevEngine.serverDeadlineMs(for: .seconds(10)), 9_250)
        XCTAssertEqual(JevEngine.serverDeadlineMs(for: .seconds(2)), 1_250)
        XCTAssertEqual(JevEngine.serverDeadlineMs(for: .milliseconds(1_000)), 500)
        XCTAssertEqual(JevEngine.serverDeadlineMs(for: .milliseconds(1)), 1)
    }

    /// A long limit, even an unlimited one, asks for the advice route's full
    /// cap, 120 s, and no more; converting it whole used to trap.
    func testAnUnlimitedLimitAsksForNoMoreThanTheServersCap() {
        XCTAssertEqual(JevEngine.serverDeadlineMs(for: .seconds(Int64.max)), 120_000)
        XCTAssertEqual(JevEngine.serverDeadlineMs(for: .seconds(600)), 120_000)
        XCTAssertEqual(JevEngine.serverDeadlineMs(for: .milliseconds(120_751)), 120_000)
        XCTAssertEqual(JevEngine.serverDeadlineMs(for: .milliseconds(120_750)), 120_000)
        XCTAssertEqual(JevEngine.serverDeadlineMs(for: .seconds(120)), 119_250)
    }

    /// A limit already past, even the most negative one, asks for the least
    /// the server takes; converting it whole used to trap.
    func testANegativeLimitAsksForTheLeast() {
        XCTAssertEqual(JevEngine.serverDeadlineMs(for: .seconds(Int64.min)), 1)
        XCTAssertEqual(JevEngine.serverDeadlineMs(for: .seconds(-5)), 1)
        XCTAssertEqual(JevEngine.serverDeadlineMs(for: .zero), 1)
    }

    // MARK: - Refused

    func testWithoutProNothingIsSent() async {
        let recorder = Recorder()
        let outcome = await ask(engine(license: nil, recorder: recorder) { _ in Self.reply(200, Self.answered) })
        XCTAssertEqual(outcome, .notSent(.refused(.noPro)))
        XCTAssertTrue(recorder.requests.isEmpty)
        let empty = await ask(engine(license: "", recorder: recorder) { _ in Self.reply(200, Self.answered) })
        XCTAssertEqual(empty, .notSent(.refused(.noPro)))
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testTheServersRefusalsAreRefusals() async {
        let recorder = Recorder()
        let license = await ask(engine(recorder: recorder) { _ in Self.reply(401, #"{"error":"Invalid or expired license"}"#) })
        XCTAssertEqual(license, .refused(.noPro))
        let capped = await ask(engine(recorder: recorder) { _ in
            Self.reply(429, #"{"error":"Daily decision limit reached"}"#, headers: ["Retry-After": " 3600 "])
        })
        XCTAssertEqual(capped, .refused(.dailyLimit(retryAfter: .seconds(3600))))
        for header in [[:], ["Retry-After": "-5"], ["Retry-After": "soon"]] {
            let outcome = await ask(engine(recorder: recorder) { _ in Self.reply(429, "{}", headers: header) })
            XCTAssertEqual(outcome, .refused(.dailyLimit(retryAfter: nil)), "\(header)")
        }
    }

    // MARK: - Invalid

    func testABadRequestOrAnAnswerThatDoesNotFitIsInvalid() async {
        let recorder = Recorder()
        let replies: [(Int, String)] = [
            (400, #"{"error":"questions must be an object"}"#),
            (409, #"{"error":"Decision request refused"}"#),
            (413, "<html>Request Entity Too Large</html>"),
            (415, #"{"error":"Decision request refused"}"#),
            (422, #"{"error":"Decision request refused"}"#),
            (200, "not json"),
            (200, #"{"model":"m","answers":{"other":{"type":"noul","noul":0.9}}}"#),
            (200, #"{"model":"m","answers":{"done":{"type":"score","score":1,"probabilities":{"0":0.5,"1":0.5},"confidence":0.5}}}"#),
            (200, #"{"model":"m","answers":{"done":{"type":"noul","noul":7}}}"#),
        ]
        for (status, body) in replies {
            let outcome = await ask(engine(recorder: recorder) { _ in Self.reply(status, body) })
            XCTAssertEqual(outcome, .invalid, "\(status) \(body)")
        }
    }

    // MARK: - Unavailable

    func testTheServiceBeingDownIsUnavailable() async {
        let recorder = Recorder()
        let down = await ask(engine(recorder: recorder) { _ in
            Self.reply(503, #"{"error":"Decisions are unavailable, try again later"}"#, headers: ["Retry-After": "60"])
        })
        XCTAssertEqual(down, .unavailable(retryAfter: .seconds(60)))
        for status in [500, 502, 404, 408, 403] {
            let outcome = await ask(engine(recorder: recorder) { _ in Self.reply(status, "") })
            XCTAssertEqual(outcome, .unavailable(retryAfter: nil), "\(status)")
        }
        let offline = await ask(engine(recorder: recorder) { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(offline, .unavailable(retryAfter: nil))
    }

    /// ITER-076 stage 9d, № 27 — the owner's switch: the server's 503 that
    /// says `X-Agent-Switch: off` is its own refusal, never an outage to wait
    /// out; a 503 that says anything else is still the service down.
    func testTheOwnersSwitchIsItsOwnRefusal() async {
        let recorder = Recorder()
        let off = await ask(engine(recorder: recorder) { _ in
            Self.reply(503, #"{"error":"agent switched off"}"#, headers: ["X-Agent-Switch": "off"])
        })
        XCTAssertEqual(off, .refused(.switchedOff))
        let other = await ask(engine(recorder: recorder) { _ in Self.reply(503, "{}", headers: ["X-Agent-Switch": "on"]) })
        XCTAssertEqual(other, .unavailable(retryAfter: nil))
        XCTAssertEqual(JevEngine.logName(.refused(.switchedOff), cancelled: false), "refused_switched_off")
    }

    // MARK: - Timed out

    /// The server ran out of time: that is a timeout, not an outage.
    func testTheServersOwnTimeoutIsATimeout() async {
        let recorder = Recorder()
        let outcome = await ask(engine(recorder: recorder) { _ in Self.reply(504, #"{"error":"Jev did not answer in time"}"#) })
        XCTAssertEqual(outcome, .timedOut)
    }

    /// The limit counts from the call: a slow license read uses it up too.
    func testTheLimitCountsFromTheCall() async {
        let recorder = Recorder()
        let sent = expectation(description: "late work sends nothing")
        sent.isInverted = true
        let started = Date()
        let outcome = await ask(engine(recorder: recorder, licenseDelay: .seconds(5)) { _ in
            sent.fulfill()
            return Self.reply(200, Self.answered)
        }, within: .milliseconds(200))
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        await fulfillment(of: [sent], timeout: 0.5)
    }

    /// Only a cancelled call that came to nothing is logged as cancelled; an
    /// answer that arrived first is logged as what it was.
    func testTheLogNamesCancelledOnlyWhenNothingCameOfIt() throws {
        let answered = try JSONDecoder().decode(JevResponse.self, from: Data(Self.answered.utf8))
        XCTAssertEqual(JevEngine.logName(.timedOut, cancelled: true), "cancelled")
        XCTAssertEqual(JevEngine.logName(.timedOut, cancelled: false), "timed_out")
        XCTAssertEqual(JevEngine.logName(.answered(answered), cancelled: true), "answered")
        XCTAssertEqual(JevEngine.logName(.refused(.dailyLimit(retryAfter: nil)), cancelled: true), "refused_daily_limit")
        XCTAssertEqual(JevEngine.logName(.notSent(.timedOut), cancelled: true), "cancelled",
                       "a call not sent is logged as what it came to")
    }

    /// The work a call runs under its deadline, begun after Stop, reads no
    /// license: a stopped call never even asks who the user is.
    func testWorkBegunAfterStopReadsNoLicense() async {
        let recorder = Recorder()
        let read = expectation(description: "a stopped call reads no license")
        read.isInverted = true
        let jev = JevEngine(licenseKey: { read.fulfill(); return "LICENSE-1" },
                            send: { request in
                                recorder.record(request)
                                return Self.reply(200, Self.answered)
                            },
                            log: { recorder.log($0) })
        let questions = self.questions!
        let work = Task { () -> JevEngine.Outcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await jev.exchange(questions, state: ["page": Self.stateText],
                                      until: ContinuousClock.now + .seconds(10))
        }
        let outcome = await work.value
        XCTAssertEqual(outcome, .notSent(.timedOut))
        await fulfillment(of: [read], timeout: 0.5)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    /// A cancelled call sends nothing and is logged as cancelled, not as a timeout.
    func testACancelledCallSendsNothingAndSaysSo() async {
        let recorder = Recorder()
        let jev = engine(recorder: recorder) { _ in Self.reply(200, Self.answered) }
        let questions = self.questions!
        let task = Task { () -> JevEngine.Outcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await jev.ask(questions, state: ["page": Self.stateText], within: .seconds(10))
        }
        let outcome = await task.value
        XCTAssertEqual(outcome, .notSent(.timedOut))
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertTrue(recorder.lines.last?.hasPrefix("[Jev] cancelled ") ?? false, recorder.lines.last ?? "no log line")
    }

    /// A late answer is a timeout, not an error, and the caller is not kept
    /// waiting for it.
    func testALateAnswerIsATimeoutAndDoesNotHoldTheCaller() async {
        let recorder = Recorder()
        let started = Date()
        let outcome = await ask(engine(recorder: recorder) { _ in
            try await Task.sleep(for: .seconds(5))
            return Self.reply(200, Self.answered)
        }, within: .milliseconds(200))
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    // MARK: - Log

    func testTheLogHoldsNumbersOnly() async {
        let recorder = Recorder()
        _ = await ask(engine(recorder: recorder) { _ in Self.reply(200, Self.answered) })
        _ = await ask(engine(recorder: recorder) { _ in Self.reply(400, #"{"error":"\#(Self.questionText)"}"#) })
        _ = await ask(engine(license: nil, recorder: recorder) { _ in Self.reply(200, Self.answered) })
        XCTAssertEqual(recorder.lines.count, 3, "one line per call")
        for line in recorder.lines {
            XCTAssertFalse(line.contains(Self.stateText) || line.contains(Self.questionText), line)
            XCTAssertFalse(line.contains("LICENSE-1"), line)
        }
        XCTAssertTrue(recorder.lines[0].hasPrefix("[Jev] answered questions=1 ms="), recorder.lines[0])
    }
}
