import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingAnswerStreamTransportTests: XCTestCase {
    func testProPostsStreamingBodyAndStopsAtDoneWithoutReadingTrailingEvents() async throws {
        let lines = StreamLineFake(lines: [
            ": keep-alive", "", "data: {\"delta\":\"First \"}",
            "data: {\"delta\":\"answer\"}", "data: {\"done\":true,\"provider\":\"provider\",\"model\":\"model\"}",
            "data: {\"delta\":\"late\"}", "data: {\"done\":true}"
        ])
        let requests = StreamRequestRecorder()
        let client = pro(lines, requests: requests)
        let events = await collect(client.stream(system: "system", user: "question", deadlineMs: 6_000,
                                                stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
        XCTAssertEqual(events, [.delta("First "), .delta("answer"), end(200)])
        XCTAssertEqual(lines.readCount, 5)
        XCTAssertEqual(lines.cancelCount, 1)
        let request = try XCTUnwrap(requests.requests.first)
        let body = try body(request)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["deadline_ms"] as? Int, 6_000)
        XCTAssertEqual(body["tier"] as? String, "heavy")
        XCTAssertEqual(body["service_id"] as? String, "MeetingCoachService")
        XCTAssertEqual(body["system"] as? String, "system")
        XCTAssertEqual(body["user"] as? String, "question")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-license")
    }

    func testProErrorAndMissingTerminalEachEndOnceWith500() async {
        for raw in [
            ["data: {\"delta\":\"**Valid partial.**\"}", "data: {\"error\":\"stream_failed\"}", "data: {\"done\":true}"],
            ["data: {\"delta\":\"**Valid partial.**\"}"]
        ] {
            let lines = StreamLineFake(lines: raw)
            let events = await collect(pro(lines).stream(system: "s", user: "u", deadlineMs: 6_000,
                                                        stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
            XCTAssertEqual(events, [.delta("**Valid partial.**"), end(500)])
        }
    }

    func testProJSONReplyAndPrecommitStatusesPreserveTheirMapping() async {
        let success = StreamLineFake(lines: ["{\"text\":\"Whole answer\"}"], contentType: "application/json")
        let successEvents = await collect(pro(success).stream(system: "s", user: "u", deadlineMs: 6_000,
                                                              stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
        XCTAssertEqual(successEvents, [.delta("Whole answer"), end(200)])
        for status in [401, 413, 422, 429, 503] {
            let lines = StreamLineFake(lines: ["{\"error\":\"private error\"}"], status: status,
                                       contentType: "application/json", retryAfter: "45")
            let events = await collect(pro(lines).stream(system: "s", user: "u", deadlineMs: 6_000,
                                                        stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
            XCTAssertEqual(events, [end(status, retryAfter: 45)])
            XCTAssertEqual(lines.readCount, 0)
        }
    }

    func testProInjectedBufferedTransportRemainsFakeAndCallDoesNotSetStream() async throws {
        let requests = StreamRequestRecorder()
        let client = ProAdviceClient(licenseKey: { "test-license" }, transport: { request in
            requests.append(request)
            return (Data("{\"text\":\"Buffered answer\"}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!)
        })
        let reply = try await client.call(system: "s", user: "u", deadlineMs: 6_000)
        XCTAssertEqual(reply.text, "Buffered answer")
        let events = await collect(client.stream(system: "s", user: "u", deadlineMs: 6_000,
                                                stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
        XCTAssertEqual(events, [.delta("Buffered answer"), end(200)])
        XCTAssertNil(try body(requests.requests[0])["stream"])
        XCTAssertEqual(try body(requests.requests[1])["stream"] as? Bool, true)
    }

    func testProInvalidSuccessfulJSONKeepsTheNonstreamStatusWithoutADelta() async throws {
        for raw in ["{}", "malformed JSON", "{\"text\":3}"] {
            let client = ProAdviceClient(licenseKey: { "test-license" }, transport: { request in
                (Data(raw.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json"])!)
            })
            let reply = try await client.call(system: "s", user: "u", deadlineMs: 6_000)
            let events = await collect(client.stream(system: "s", user: "u", deadlineMs: 6_000,
                                                    stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
            XCTAssertEqual(reply.status, 200)
            XCTAssertNil(reply.text)
            XCTAssertEqual(events, [end(reply.status)], raw)
        }
    }

    func testOwnKeyMalformedSuccessfulJSONStillFailsWith500() async {
        for raw in ["{}", "malformed JSON"] {
            let lines = StreamLineFake(lines: [raw], contentType: "application/json")
            let route = OwnKeyAnswerRoute(apiKey: { "key" }, provider: { .openai }, lineTransport: { _ in lines.response() })
            let events = await collect(route.stream(system: "s", user: "u", deadlineMs: 6_000,
                                                   stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
            XCTAssertEqual(events, [end(500)], raw)
        }
    }

    func testOwnKeyPreservesProviderRequestAndReadsContentUntilDone() async throws {
        let lines = StreamLineFake(lines: [
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"Answer\"}}]}",
            "data: [DONE]", "data: {\"choices\":[{\"delta\":{\"content\":\"late\"}}]}"
        ])
        let requests = StreamRequestRecorder()
        let route = OwnKeyAnswerRoute(apiKey: { "test-key" }, provider: { .cerebras }, lineTransport: { request in
            requests.append(request)
            return lines.response()
        })
        let events = await collect(route.stream(system: "separate system", user: "separate user", deadlineMs: 6_000,
                                               stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
        XCTAssertEqual(events, [.delta("Answer"), end(200)])
        XCTAssertEqual(lines.readCount, 3)
        let request = try XCTUnwrap(requests.requests.first)
        let value = try body(request)
        XCTAssertEqual(request.url, LLMProvider.cerebras.endpoint)
        XCTAssertEqual(value["model"] as? String, LLMProvider.cerebras.model)
        XCTAssertEqual(value["stream"] as? Bool, true)
        XCTAssertEqual(value["messages"] as? [[String: String]], [
            ["role": "system", "content": "separate system"], ["role": "user", "content": "separate user"]
        ])
    }

    func testOwnKey429EndsBeforeReadingAndKeepsRetryAfter() async {
        let lines = StreamLineFake(lines: ["private body"], status: 429, retryAfter: "12")
        let route = OwnKeyAnswerRoute(apiKey: { "key" }, provider: { .openai }, lineTransport: { _ in lines.response() })
        let events = await collect(route.stream(system: "s", user: "u", deadlineMs: 6_000,
                                               stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
        XCTAssertEqual(events, [end(429, retryAfter: 12)])
        XCTAssertEqual(lines.readCount, 0)
    }

    func testOwnKeyJSONFallbackAndMissingTerminal() async {
        let json = StreamLineFake(lines: ["{\"choices\":[{\"message\":{\"content\":\"Whole answer\"}}]}"], contentType: "application/json")
        let route = OwnKeyAnswerRoute(apiKey: { "key" }, provider: { .openai }, lineTransport: { _ in json.response() })
        let jsonEvents = await collect(route.stream(system: "s", user: "u", deadlineMs: 6_000,
                                                    stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
        XCTAssertEqual(jsonEvents, [.delta("Whole answer"), end(200)])
        let missing = StreamLineFake(lines: ["data: {\"choices\":[{\"delta\":{\"content\":\"Partial\"}}]}"])
        let unfinished = OwnKeyAnswerRoute(apiKey: { "key" }, provider: { .openai }, lineTransport: { _ in missing.response() })
        let missingEvents = await collect(unfinished.stream(system: "s", user: "u", deadlineMs: 6_000,
                                                            stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
        XCTAssertEqual(missingEvents, [.delta("Partial"), end(500)])
    }

    func testLocalIsOneWholeDeltaAndRetainsSeparateSystemAndUser() async {
        let seen = StreamRequestRecorder()
        let route = LocalAnswerRoute(isReady: { true }, complete: { system, user, limit in
            var request = URLRequest(url: URL(string: "https://invalid.test")!)
            request.httpBody = try JSONSerialization.data(withJSONObject: ["system": system, "user": user, "limit": limit])
            seen.append(request)
            return "Whole local answer"
        })
        let events = await collect(route.stream(system: "local system", user: "local user", deadlineMs: 6_000,
                                               stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
        XCTAssertEqual(events, [.delta("Whole local answer"), end(200, text: "Whole local answer")])
        XCTAssertEqual(try? body(seen.requests[0])["system"] as? String, "local system")
        XCTAssertEqual(try? body(seen.requests[0])["user"] as? String, "local user")
    }

    func testInjectedOwnKeyCompletionStaysFakeWhenCardUsesStream() async {
        let route = OwnKeyAnswerRoute(apiKey: { "key" }, provider: { .openai }, complete: { _, _, _, _ in "Whole fake answer" })
        let events = await collect(route.stream(system: "s", user: "u", deadlineMs: 6_000,
                                               stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
        XCTAssertEqual(events, [.delta("Whole fake answer"), end(200, text: "Whole fake answer")])
    }

    func testWholeTextRoutesWaitForTheCardDeadlineAndCancelTheirCompletion() async {
        for local in [true, false] {
            let probe = StreamCompletionProbe()
            let route: MeetingAnswerRoute
            if local {
                route = LocalAnswerRoute(isReady: { true }, complete: { _, _, _ in try await probe.complete() })
            } else {
                route = OwnKeyAnswerRoute(apiKey: { "key" }, provider: { .openai },
                                          complete: { _, _, _, _ in try await probe.complete() })
            }
            let deadline = StreamDeadlineGate()
            let source = route.stream(system: "s", user: "u", deadlineMs: 1,
                                      stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle())
            let bounded = MeetingAnswerStreamReader.bounded(source, deadlineMs: 1, sleep: { _ in try await deadline.wait() })
            let task = Task { () -> Bool in
                for await event in bounded {
                    if case .deadline = event { return true }
                }
                return false
            }
            await waitUntil { probe.started }
            // A nested completion timer would finish early and orphan its worker.
            try? await Task.sleep(for: .milliseconds(20))
            deadline.fire()
            let reachedCardDeadline = await task.value
            XCTAssertTrue(reachedCardDeadline, "The card deadline must own whole-text completion")
            await waitUntil { probe.cancelled }
            XCTAssertTrue(probe.cancelled)
        }
    }

    func testInjectedOwnKeyStreamPreservesProvider429() async {
        let route: MeetingAnswerRoute = OwnKeyAnswerRoute(apiKey: { "key" }, provider: { .openai }, complete: { _, _, _, _ in
            throw ProcessingError.http(status: 429, message: "Rate limited")
        })
        let events = await collect(route.stream(system: "s", user: "u", deadlineMs: 6_000,
                                               stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
        XCTAssertEqual(events, [end(429)])
    }

    func testStopAndHandleCancellationPreventAnyTransportStart() async {
        for stopSession in [true, false] {
            let token = LiveHintsStopToken()
            let handle = LiveHintsRequestHandle()
            if stopSession { token.stop() } else { handle.cancel() }
            let requests = StreamRequestRecorder()
            let events = await collect(pro(StreamLineFake(lines: []), requests: requests)
                .stream(system: "s", user: "u", deadlineMs: 6_000, stopToken: token, handle: handle))
            XCTAssertEqual(events, [end(499)])
            XCTAssertTrue(requests.requests.isEmpty)
        }
    }

    func testStopAndHandleCancellationMidReadCancelTransportAndNeverReadAgain() async {
        for stopSession in [true, false] {
            let token = LiveHintsStopToken()
            let handle = LiveHintsRequestHandle()
            let lines = StreamLineFake(lines: ["data: {\"delta\":\"First\"}", "data: {\"delta\":\"late\"}", "data: {\"done\":true}"])
            lines.beforeRead = { index in
                if index == 1 { try await Task.sleep(for: .seconds(30)) }
            }
            let task = Task { await collect(pro(lines).stream(system: "s", user: "u", deadlineMs: 6_000,
                                                             stopToken: token, handle: handle)) }
            await waitUntil { lines.readCount == 2 }
            if stopSession { token.stop() } else { handle.cancel() }
            let events = await task.value
            XCTAssertEqual(events, [.delta("First"), end(499)])
            XCTAssertEqual(lines.readCount, 2)
            XCTAssertEqual(lines.cancelCount, 1)
        }
    }

    func testConsumerCancellationCancelsUnderlyingReadWithoutAnotherRead() async {
        let lines = StreamLineFake(lines: ["data: {\"delta\":\"First\"}", "data: {\"done\":true}"])
        lines.beforeRead = { _ in try await Task.sleep(for: .seconds(30)) }
        let stream = pro(lines).stream(system: "s", user: "u", deadlineMs: 6_000,
                                       stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle())
        let task = Task { await collect(stream) }
        await waitUntil { lines.readCount == 1 }
        task.cancel()
        _ = await task.value
        await waitUntil { lines.cancelCount == 1 }
        XCTAssertEqual(lines.readCount, 1)
        XCTAssertEqual(lines.cancelCount, 1)
    }

    func testReadExceptionAfterContentEndsWith500() async {
        let lines = StreamLineFake(lines: ["data: {\"delta\":\"Partial\"}", "data: {\"done\":true}"])
        lines.beforeRead = { index in if index == 1 { throw URLError(.networkConnectionLost) } }
        let events = await collect(pro(lines).stream(system: "s", user: "u", deadlineMs: 6_000,
                                                    stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
        XCTAssertEqual(events, [.delta("Partial"), end(500)])
        XCTAssertEqual(lines.cancelCount, 1)
    }

    func testTransportTimeoutBeforeHeadersEndsWith408() async {
        let transport: MeetingAnswerLineTransport = { _ in throw URLError(.timedOut) }
        let client = ProAdviceClient(licenseKey: { "test-license" },
                                     transport: { _ in throw URLError(.unsupportedURL) },
                                     lineTransport: transport)
        let routes: [MeetingAnswerRoute] = [
            ProAnswerRoute(client: client),
            OwnKeyAnswerRoute(apiKey: { "key" }, provider: { .openai }, lineTransport: transport)
        ]
        for route in routes {
            let events = await collect(route.stream(system: "s", user: "u", deadlineMs: 6_000,
                                                   stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
            XCTAssertEqual(events, [end(408)], route.routeName)
        }
    }

    func testReadTimeoutAfterContentEndsWith408() async {
        for ownKey in [false, true] {
            let partial = ownKey
                ? "data: {\"choices\":[{\"delta\":{\"content\":\"Partial\"}}]}"
                : "data: {\"delta\":\"Partial\"}"
            let lines = StreamLineFake(lines: [partial, "data: [DONE]"])
            lines.beforeRead = { index in if index == 1 { throw URLError(.timedOut) } }
            let route: MeetingAnswerRoute = ownKey
                ? OwnKeyAnswerRoute(apiKey: { "key" }, provider: { .openai }, lineTransport: { _ in lines.response() })
                : ProAnswerRoute(client: pro(lines))
            let events = await collect(route.stream(system: "s", user: "u", deadlineMs: 6_000,
                                                   stopToken: LiveHintsStopToken(), handle: LiveHintsRequestHandle()))
            XCTAssertEqual(events, [.delta("Partial"), end(408)], route.routeName)
            XCTAssertEqual(lines.readCount, 2)
            XCTAssertEqual(lines.cancelCount, 1)
        }
    }

    private func pro(_ lines: StreamLineFake, requests: StreamRequestRecorder = StreamRequestRecorder()) -> ProAdviceClient {
        ProAdviceClient(licenseKey: { "test-license" }, transport: { _ in throw URLError(.unsupportedURL) },
                        lineTransport: { request in requests.append(request); return lines.response() })
    }

    private func collect(_ stream: AsyncStream<MeetingAnswerStreamEvent>) async -> [MeetingAnswerStreamEvent] {
        var events: [MeetingAnswerStreamEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func end(_ status: Int, retryAfter: TimeInterval? = nil, text: String? = nil) -> MeetingAnswerStreamEvent {
        .end(.init(status: status, retryAfter: retryAfter, text: text))
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("The fake transport did not reach the expected state")
    }
}

private final class StreamRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    func append(_ request: URLRequest) { lock.withLock { recorded.append(request) } }
}

private final class StreamLineFake: @unchecked Sendable {
    private let lock = NSLock()
    private let lines: [String]
    private let status: Int
    private let contentType: String
    private let retryAfter: String?
    private var reads = 0
    private var cancels = 0
    var beforeRead: @Sendable (Int) async throws -> Void = { _ in }
    var readCount: Int { lock.withLock { reads } }
    var cancelCount: Int { lock.withLock { cancels } }

    init(lines: [String], status: Int = 200, contentType: String = "text/event-stream", retryAfter: String? = nil) {
        self.lines = lines
        self.status = status
        self.contentType = contentType
        self.retryAfter = retryAfter
    }

    func response() -> MeetingAnswerLineResponse {
        var headers = ["Content-Type": contentType]
        headers["Retry-After"] = retryAfter
        return MeetingAnswerLineResponse(response: HTTPURLResponse(url: URL(string: "https://invalid.test")!,
                                                                   statusCode: status, httpVersion: nil, headerFields: headers)!,
                                         nextLine: { [self] in
            let index = lock.withLock { let next = reads; reads += 1; return next }
            try await beforeRead(index)
            return index < lines.count ? lines[index] : nil
        }, cancel: { [self] in lock.withLock { cancels += 1 } })
    }
}

private final class StreamCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didCancel = false
    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func complete() async throws -> String {
        lock.withLock { didStart = true }
        do {
            try await Task.sleep(for: .seconds(30))
            return "Late completion"
        } catch {
            lock.withLock { didCancel = Task.isCancelled }
            throw error
        }
    }
}

@MainActor
private final class StreamDeadlineGate {
    private var continuation: AsyncStream<Void>.Continuation?
    func wait() async throws {
        let stream = AsyncStream<Void> { continuation = $0 }
        for await _ in stream { break }
        try Task.checkCancellation()
    }
    func fire() { continuation?.yield(()); continuation?.finish() }
}
