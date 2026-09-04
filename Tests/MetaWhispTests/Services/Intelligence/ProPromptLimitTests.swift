import XCTest
@testable import MetaWhisp

/// What the app sends to `POST /api/pro/advice`, and what it says when the
/// proxy refuses. On 2026-09-04 an 87-minute meeting (47 178 chars) produced
/// `Couldn't generate the plan: LLM error: Action-plan proxy HTTP 400` — the
/// proxy's own answer, `Prompt too long (47178 chars, max 32000)`, was read
/// and thrown away.
final class ProPromptLimitTests: XCTestCase {

    // MARK: - Nothing leaves the app over the proxy's limit

    func testTheSafeLimitIsUnderWhatTheProxyAccepts() {
        XCTAssertLessThan(LLMRequestBody.safePromptChars, LLMRequestBody.maxPromptChars,
                          "the fold needs room for its own framing")
    }

    /// The structured path sends one prompt and takes one JSON back, so it
    /// caps instead of folding — and the cap must actually fit.
    func testACappedTranscriptFitsTheProxy() {
        let transcript = String(repeating: "a", count: 47_178)   // the meeting that failed
        let capped = StructuredGenerator.headAndTail(transcript, limit: LLMRequestBody.safePromptChars)
        XCTAssertLessThanOrEqual(capped.count, LLMRequestBody.safePromptChars)
        XCTAssertLessThan(capped.count, LLMRequestBody.maxPromptChars, "the proxy would have refused this")
    }

    /// The END of a meeting carries the decisions and the action items; a
    /// head-only cut dropped them.
    func testTheCapKeepsBothEndsOfTheMeeting() {
        let transcript = "OPENING. " + String(repeating: "x", count: 40_000) + " CLOSING DECISION."
        let capped = StructuredGenerator.headAndTail(transcript, limit: 1_000)
        XCTAssertTrue(capped.hasPrefix("OPENING."), "the start is kept")
        XCTAssertTrue(capped.hasSuffix("CLOSING DECISION."), "and so is the end")
        XCTAssertTrue(capped.contains("omitted"), "the gap is admitted, not hidden")
    }

    func testAShortTranscriptIsUntouched() {
        XCTAssertEqual(StructuredGenerator.headAndTail("short one", limit: 1_000), "short one")
    }

    /// Skips accumulate across fold rounds, part counts do not: the note must
    /// never read "3 of 2 sections".
    func testTheSkippedCountNeverExceedsThePartCount() async throws {
        var skipped = 0
        var ofParts = 0
        let long = String(repeating: "word word word. ", count: 4_000)   // ~64 000 chars
        _ = try? await ChunkedCompletion.run(
            system: "S", user: long, chunkChars: 8_000,
            onChunkSkipped: { _, of, _ in skipped += 1; ofParts = max(ofParts, of) }
        ) { _, usr, _ in
            if usr.hasPrefix("word word word. word") { throw NSError(domain: "T", code: 1) }
            return String(usr.prefix(4_000))      // shrinks, so the fold runs several rounds
        }
        XCTAssertGreaterThan(skipped, 0, "the fake transport must have skipped something")
        XCTAssertLessThanOrEqual(skipped, ofParts, "\(skipped) of \(ofParts) would be a lie")
    }

    // MARK: - A refusal says why

    func testTheProxysReasonReachesTheMessage() {
        let body = #"{"error":"Prompt too long (47178 chars, max 32000)"}"#.data(using: .utf8)!
        XCTAssertEqual(StructuredGenerator.proxyReason(body), " — Prompt too long (47178 chars, max 32000)")
    }

    func testANonJSONBodyIsStillShown() {
        let reason = StructuredGenerator.proxyReason(Data("upstream timed out".utf8))
        XCTAssertEqual(reason, " — upstream timed out")
    }

    func testAnEmptyBodyAddsNothing() {
        XCTAssertEqual(StructuredGenerator.proxyReason(Data()), "")
    }
}
