import XCTest
@testable import MetaWhisp

/// Regression guards for `GateClient`.
///
/// `/api/pro/gate` is the 2-stage filter introduced by ITER-041 Phase C.
/// Cheap mini-tier relevance check; only on pass do we fire the expensive
/// medium/heavy generate.
///
/// These tests pin the PURE-FUNCTION parts:
///   - request body shape (wire protocol)
///   - threshold decision (`shouldFire`) including fail-open edge cases
///   - purpose raw values
final class GateClientTests: XCTestCase {

    // MARK: - Purpose enum

    func test_gatePurpose_rawValuesAreStable() {
        XCTAssertEqual(GatePurpose.proactive.rawValue, "proactive")
        XCTAssertEqual(GatePurpose.advice.rawValue, "advice")
        XCTAssertEqual(GatePurpose.reactor.rawValue, "reactor")
        XCTAssertEqual(GatePurpose.meetingCoach.rawValue, "meeting_coach")
    }

    // MARK: - Request body builder

    func test_buildRequest_includesAllFields() {
        let req = GateClient.buildRequest(
            context: "Some context",
            purpose: .proactive,
            recentTopics: ["topic1", "topic2"],
            serviceId: "InsightAssistantService"
        )
        XCTAssertEqual(req.context, "Some context")
        XCTAssertEqual(req.purpose, "proactive")
        XCTAssertEqual(req.recent_topics, ["topic1", "topic2"])
        XCTAssertEqual(req.service_id, "InsightAssistantService")
    }

    func test_buildRequest_serializesToJSON() throws {
        let req = GateClient.buildRequest(
            context: "c", purpose: .advice,
            recentTopics: ["t"], serviceId: "S"
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["context"] as? String, "c")
        XCTAssertEqual(decoded?["purpose"] as? String, "advice")
        XCTAssertEqual(decoded?["recent_topics"] as? [String], ["t"])
        XCTAssertEqual(decoded?["service_id"] as? String, "S")
    }

    // MARK: - shouldFire threshold logic

    /// Score above threshold → fire.
    func test_shouldFire_scoreAboveThreshold_fires() {
        XCTAssertTrue(GateClient.shouldFire(score: 0.85, threshold: 0.65))
    }

    /// Score exactly at threshold → fire (>= is the spec).
    func test_shouldFire_scoreAtBoundary_fires() {
        XCTAssertTrue(GateClient.shouldFire(score: 0.65, threshold: 0.65))
    }

    /// Score just below threshold → skip.
    func test_shouldFire_scoreBelowThreshold_skips() {
        XCTAssertFalse(GateClient.shouldFire(score: 0.64, threshold: 0.65))
    }

    /// Score = 0 → skip.
    func test_shouldFire_zeroScore_skips() {
        XCTAssertFalse(GateClient.shouldFire(score: 0.0, threshold: 0.65))
    }

    /// Score = 1.0 → fire (maximum confidence).
    func test_shouldFire_maxScore_fires() {
        XCTAssertTrue(GateClient.shouldFire(score: 1.0, threshold: 0.65))
    }

    /// FAIL-OPEN: NaN score (gate parse error, network blip) → fire.
    /// Rationale: better to surface a possibly-irrelevant advice than to
    /// silently drop a real signal because the cheap gate misbehaved.
    func test_shouldFire_nanScore_failsOpen() {
        XCTAssertTrue(GateClient.shouldFire(score: .nan, threshold: 0.65))
    }

    /// Custom threshold — user might tune it lower for more advice.
    func test_shouldFire_customThreshold_appliesCorrectly() {
        XCTAssertTrue(GateClient.shouldFire(score: 0.5, threshold: 0.4))
        XCTAssertFalse(GateClient.shouldFire(score: 0.5, threshold: 0.6))
    }

    // MARK: - GateResponse decoding (wire contract)

    func test_gateResponse_decodesValidJSON() throws {
        let json = #"{"is_relevant": true, "score": 0.78, "reasoning": "Specific commitment"}"#
        let resp = try JSONDecoder().decode(GateResponse.self, from: Data(json.utf8))
        XCTAssertTrue(resp.is_relevant)
        XCTAssertEqual(resp.score, 0.78, accuracy: 0.0001)
        XCTAssertEqual(resp.reasoning, "Specific commitment")
    }

    /// Default threshold per ITER-041 spec.
    func test_defaultThreshold_matchesSpec() {
        XCTAssertEqual(GateClient.defaultThreshold, 0.65)
    }
}
