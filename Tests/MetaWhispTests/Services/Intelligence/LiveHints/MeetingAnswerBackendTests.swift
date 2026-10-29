import XCTest
@testable import MetaWhisp

/// The routes to the model (T11).
///
/// Pro first, then the user's own key, and the local model only when neither
/// cloud route exists. Every route is behind a protocol, so the tests never
/// reach the network.
@MainActor
final class MeetingAnswerBackendTests: XCTestCase {

    // MARK: - The Pro route

    /// The Pro call carries the heavy tier, the service id and the deadline.
    func testTheProCallCarriesTheHeavyTierTheServiceIdAndTheDeadline() async throws {
        let transport = FakeProTransport(statusCode: 200, headers: [:])
        let client = ProAdviceClient(licenseKey: { "a-license-key" },
                                     transport: { request in
                                         transport.requests.append(request)
                                         return transport.answer()
                                     })

        let reply = try await client.call(system: "the system", user: "the user", deadlineMs: 6_000)

        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.text, "**The answer.**")

        let request = try XCTUnwrap(transport.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["tier"] as? String, "heavy")
        XCTAssertEqual(body["service_id"] as? String, "MeetingCoachService")
        XCTAssertEqual(body["deadline_ms"] as? Int, 6_000)
        XCTAssertEqual(body["system"] as? String, "the system")
        XCTAssertEqual(body["user"] as? String, "the user")

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer a-license-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.url?.absoluteString, "https://api.metawhisp.com/api/pro/advice")
    }

    /// The Pro call keeps the status and the Retry-After of the answer.
    func testTheProCallKeepsTheStatusAndTheRetryAfter() async throws {
        let transport = FakeProTransport(statusCode: 503, headers: ["Retry-After": "45"])
        let client = ProAdviceClient(licenseKey: { "a-license-key" },
                                     transport: { request in
                                         transport.requests.append(request)
                                         return transport.answer()
                                     })

        let reply = try await client.call(system: "the system", user: "the user", deadlineMs: 8_000)

        XCTAssertEqual(reply.status, 503)
        XCTAssertEqual(reply.retryAfter, 45)
        XCTAssertNil(reply.text)
    }

    /// A 401 on the Pro route gives the sign-in line.
    func testA401OnTheProRouteGivesTheSignInLine() async {
        let harness = makeAnswerHarness()
        harness.pro.replies = [MeetingAnswerReply(status: 401, retryAfter: nil, text: nil)]
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.shortcutPressed()
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.status, MeetingAnswerStatus.signInAgain)
    }

    // MARK: - The user's own key

    /// A Pro refusal is the answer of the request: the own key is not tried
    /// behind it, so the backoff is not hidden (§3.4).
    func testAProRefusalDoesNotFallThroughToTheOwnKey() async {
        let harness = makeAnswerHarness()
        harness.ownKey.isAvailable = true
        harness.pro.replies = [MeetingAnswerReply(status: 503, retryAfter: 60, text: nil)]

        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.ownKey.requests.count, 0,
                       "the own key was tried behind the Pro route's refusal")
        XCTAssertNotNil(harness.service.automaticPausedUntil,
                        "the refusal did not pause the automatic answers")
    }

    /// The own key answers when the Pro route cannot be used at all: only
    /// "no route" moves the request to the next backend (§3.4).
    func testTheOwnKeyAnswersWhenTheProRouteCannotBeUsed() async {
        let harness = makeAnswerHarness()
        harness.pro.isAvailable = false
        harness.ownKey.isAvailable = true

        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.pro.requests.count, 0, "the Pro route was asked although it cannot be used")
        XCTAssertEqual(harness.ownKey.requests.count, 1, "the own key did not answer")
    }

    /// The own key goes through the OpenAI service, which refuses an empty key
    /// before it reaches the network.
    func testTheOwnKeyGoesThroughTheOpenAIService() async {
        do {
            _ = try await OwnKeyAnswerRoute.liveCompletion(system: "the system",
                                                           user: "the user",
                                                           apiKey: "",
                                                           provider: .openai)
            XCTFail("the live completion took an empty key")
        } catch {
            // The service refused the key; no request was made.
        }
    }

    /// The own key runs under a deadline, and a reply that comes too late is
    /// dropped.
    func testTheOwnKeyRunsUnderADeadline() async throws {
        let route = OwnKeyAnswerRoute(apiKey: { "a-key" },
                                      provider: { .openai },
                                      complete: { _, _, _, _ in
                                          try await Task.sleep(nanoseconds: 300_000_000)
                                          return "**Too late.**"
                                      })

        let reply = try await route.answer(system: "the system", user: "the user", deadlineMs: 50, stopToken: LiveHintsStopToken())

        XCTAssertEqual(reply.status, 408)
        XCTAssertNil(reply.text)
    }

    /// The own key route takes the provider the settings name.
    func testTheOwnKeyRouteTakesTheProviderAndTheKey() async throws {
        let seen = SeenBox<String>()
        let route = OwnKeyAnswerRoute(apiKey: { "a-key" },
                                      provider: { .cerebras },
                                      complete: { _, _, key, provider in
                                          seen.append("\(key)|\(provider.rawValue)")
                                          return "**The answer.**"
                                      })

        let reply = try await route.answer(system: "the system", user: "the user", deadlineMs: 6_000, stopToken: LiveHintsStopToken())

        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(seen.values, ["a-key|cerebras"])
    }

    // MARK: - The local model

    /// The local model is used only when neither cloud route exists, and it
    /// gets its own cap on the user message.
    func testTheLocalModelIsUsedOnlyWithNoCloudRoute() async {
        let recorded = SeenBox<Int>()
        let local = LocalAnswerRoute(isReady: { true },
                                     complete: { _, _, maxUserChars in
                                         recorded.append(maxUserChars)
                                         return "**The local answer.**"
                                     })

        // A cloud route exists: the local one stays out of it.
        let withCloud = makeAnswerHarness()
        withCloud.routes.local = local
        await appendThemLine(withCloud.transcript, text: "shall we ship on Friday?", from: 0)
        await withCloud.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await withCloud.waitForRequests(1)
        await withCloud.waitUntilIdle()

        XCTAssertTrue(recorded.values.isEmpty, "the local model was used although a cloud route exists")

        // No cloud route: the local one answers.
        let alone = makeAnswerHarness()
        alone.routes.pro = nil
        alone.routes.ownKey = nil
        alone.routes.local = local
        await appendThemLine(alone.transcript, text: "shall we ship on Friday?", from: 0)
        await alone.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await alone.waitUntil { recorded.values.count >= 1 }
        await alone.waitUntilIdle()

        XCTAssertEqual(recorded.values, [6_000], "the local model did not get its own cap")
    }

    /// With no route at all the status says so, and nobody is called.
    func testWithNoRouteAtAllTheStatusSaysSo() async {
        let harness = makeAnswerHarness()
        harness.routes.pro = nil
        harness.routes.ownKey = nil
        harness.routes.local = nil
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.shortcutPressed()
        await harness.settle()

        XCTAssertEqual(harness.service.status, MeetingAnswerStatus.noRoute)
        XCTAssertEqual(harness.requestCount, 0, "a model was called although there is no route")
    }
}
