import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingAnswerOwnKeyStatusTests: XCTestCase {
    func testOwnKey429PreservesRetryAfter() async throws {
        for body in [Data(#"{"error":{"message":"Rate limited"}}"#.utf8), Data()] {
            let provider = OpenAIService(transport: { request in
                let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 429,
                                               httpVersion: nil, headerFields: ["Retry-After": "17"])!
                return (body, response)
            })
            let route = OwnKeyAnswerRoute(apiKey: { "test-key" }, complete: { system, user, key, chosen in
                try await provider.complete(system: system, user: user, apiKey: key, provider: chosen)
            })

            let reply = try await route.answer(system: "system", user: "question", deadlineMs: 8_000,
                                               stopToken: LiveHintsStopToken())

            XCTAssertEqual(reply.status, 429)
            XCTAssertEqual(reply.retryAfter, 17)
            XCTAssertNil(reply.text)
        }
    }

    func testOwnKeyKeepsEveryHTTPStatusAndDoesNotInventOneForOtherErrors() async throws {
        for status in [400, 429, 503] {
            let route = OwnKeyAnswerRoute(apiKey: { "test-key" }, complete: { _, _, _, _ in
                throw ProcessingError.http(status: status, message: "Provider refused")
            })
            let reply = try await route.answer(system: "system", user: "user", deadlineMs: 8_000,
                                               stopToken: LiveHintsStopToken())
            XCTAssertEqual(reply.status, status)
            XCTAssertNil(reply.text)
        }
        let route = OwnKeyAnswerRoute(apiKey: { "test-key" }, complete: { _, _, _, _ in
            throw URLError(.cannotConnectToHost)
        })
        let reply = try await route.answer(system: "system", user: "user", deadlineMs: 8_000,
                                           stopToken: LiveHintsStopToken())
        XCTAssertEqual(reply.status, 500)
    }

}
