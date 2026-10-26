import XCTest
@testable import MetaWhisp

/// ITER-075 step 1 (1.5) — the service turning a run away is no failure of the
/// conversation. No network, no key or a refused one, a missing model, a
/// throttled or unavailable service: the run is "not now", and waits
/// uncounted. The Pro proxy answers 503 for these, within the 25 s the summary
/// asks for, and passes a request it could not run through as 4xx (since
/// 2026-09-26); the summary reads its own 30-s wait running out as 504. A
/// timeout elsewhere, a request refused as it was, or an answer that could not
/// be used is a failure.
final class StructuredServiceErrorTests: XCTestCase {

    func testTheServiceTurningARunAwayIsNotNow() {
        let turnedAway: [Error] = [URLError(.notConnectedToInternet), URLError(.networkConnectionLost),
                                   URLError(.cannotFindHost), ProcessingError.noAPIKey]
        for error in turnedAway {
            XCTAssertTrue(StructuredGenerator.isServiceUnavailable(error), "\(error)")
        }
        for status in [401, 403, 404, 408, 429, 500, 502, 503] {
            XCTAssertTrue(StructuredGenerator.isServiceUnavailable(ProcessingError.http(status: status, message: "x")),
                          "HTTP \(status)")
        }
    }

    func testATimeoutARefusedRequestAndAnUnusableAnswerAreFailures() {
        for status in [400, 413, 422] {
            XCTAssertFalse(StructuredGenerator.isServiceUnavailable(ProcessingError.http(status: status, message: "x")),
                           "HTTP \(status)")
        }
        let failures: [Error] = [URLError(.timedOut),
                                 ProcessingError.apiError("Structured prompt too long for the proxy"),
                                 ProcessingError.emptyResponse,
                                 DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not JSON"))]
        for error in failures {
            XCTAssertFalse(StructuredGenerator.isServiceUnavailable(error), "\(error)")
        }
    }

    /// OpenAI answers 429 when one request is over the key's per-minute limit.
    /// That request can never go through, so it reads as 413, and counts.
    func testOpenAIsRequestTooLargeReadsAsTooLarge() {
        XCTAssertEqual(OpenAIService.status(429, message: "Request too large for gpt-4o-mini in organization org-x "
                                            + "on tokens per min (TPM): Limit 200000, Requested 250000."), 413)
        XCTAssertEqual(OpenAIService.status(429, message: "Rate limit reached for gpt-4o-mini in organization org-x "
                                            + "on requests per min (RPM)."), 429)
        XCTAssertEqual(OpenAIService.status(400, message: "Request too large"), 400)
    }

    /// The summary asks the proxy for an answer within 25 s; no other caller does.
    func testTheAdviceBodyCarriesADeadlineOnlyWhenAsked() {
        XCTAssertEqual(LLMRequestBody.proAdviceBody(system: "s", user: "u", deadlineMs: 25_000)["deadline_ms"] as? Int,
                       25_000)
        XCTAssertNil(LLMRequestBody.proAdviceBody(system: "s", user: "u")["deadline_ms"])
    }

    /// The status travels with the error; what the user reads is unchanged.
    func testARefusalWithAStatusReadsAsBefore() {
        XCTAssertEqual(ProcessingError.http(status: 429, message: "Structured proxy HTTP 429 — slow down").errorDescription,
                       "LLM error: Structured proxy HTTP 429 — slow down")
        XCTAssertEqual(ProcessingError.apiError("HTTP 500").errorDescription, "LLM error: HTTP 500")
    }
}
