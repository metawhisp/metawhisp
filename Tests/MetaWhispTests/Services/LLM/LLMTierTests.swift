import XCTest
@testable import MetaWhisp

/// Regression guards for `LLMTier` + `LLMRequestBody`.
///
/// Spec: `specs/iterations/ITER-041-llm-tier-routing.md`.
///
/// The worker reads `body.tier` to override the model — mini=8B-instant,
/// medium=gpt-oss-20b, heavy=llama-3.3-70b-versatile. Missing tier means
/// the worker defaults to heavy (back-compat).
///
/// These tests pin:
///   - the `tier` raw values used as wire protocol
///   - that `LLMRequestBody.proAdviceBody` includes / omits tier fields correctly
///   - per-service `llmTier` declarations match the spec table
final class LLMTierTests: XCTestCase {

    // MARK: - Wire protocol

    func test_tierRawValuesMatchWireProtocol() {
        XCTAssertEqual(LLMTier.mini.rawValue, "mini")
        XCTAssertEqual(LLMTier.medium.rawValue, "medium")
        XCTAssertEqual(LLMTier.heavy.rawValue, "heavy")
    }

    // MARK: - Body builder

    /// Back-compat: no tier, no service_id → body has only system + user.
    /// Worker treats missing tier as "heavy" — preserves old behaviour.
    func test_proAdviceBody_backCompat_noTierNoService() {
        let body = LLMRequestBody.proAdviceBody(system: "sys", user: "usr")
        XCTAssertEqual(body["system"] as? String, "sys")
        XCTAssertEqual(body["user"] as? String, "usr")
        XCTAssertNil(body["tier"], "tier must be omitted when nil")
        XCTAssertNil(body["service_id"], "service_id must be omitted when nil")
        XCTAssertEqual(Set(body.keys), ["system", "user"])
    }

    /// New routing: tier set → forwarded as wire field.
    func test_proAdviceBody_includesTierWhenProvided() {
        let body = LLMRequestBody.proAdviceBody(system: "s", user: "u", tier: .mini)
        XCTAssertEqual(body["tier"] as? String, "mini")
    }

    func test_proAdviceBody_includesServiceIdWhenProvided() {
        let body = LLMRequestBody.proAdviceBody(system: "s", user: "u", serviceId: "MemoryExtractor")
        XCTAssertEqual(body["service_id"] as? String, "MemoryExtractor")
    }

    func test_proAdviceBody_includesAllFieldsWhenAllProvided() {
        let body = LLMRequestBody.proAdviceBody(
            system: "s", user: "u",
            tier: .medium, serviceId: "AdviceService"
        )
        XCTAssertEqual(body["tier"] as? String, "medium")
        XCTAssertEqual(body["service_id"] as? String, "AdviceService")
        XCTAssertEqual(body["system"] as? String, "s")
        XCTAssertEqual(body["user"] as? String, "u")
    }

    /// JSONSerialization must produce valid JSON from the body — the worker
    /// will reject malformed payloads with 400.
    func test_proAdviceBody_serializesToValidJSON() throws {
        let body = LLMRequestBody.proAdviceBody(
            system: "s", user: "u", tier: .heavy, serviceId: "ChatService"
        )
        let data = try JSONSerialization.data(withJSONObject: body)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["tier"] as? String, "heavy")
        XCTAssertEqual(decoded?["service_id"] as? String, "ChatService")
    }

    // MARK: - Per-service tier declarations (ITER-041 spec)

    // === Mini tier — SIMPLE structured extraction only ===
    //
    // Original ITER-041 plan put all 4 extractors on mini. Production
    // verification (2026-05-28 17:13-17:15 PID 53369) found that
    // MemoryExtractor + StructuredGenerator emit complex schemas where
    // 8B-instant truncates the JSON. Moved those two to medium; only the
    // simple-schema extractors stay on mini.

    func test_taskExtractor_usesMiniTier() {
        // Simple schema: {tasks: [...]}. Verified working in production.
        XCTAssertEqual(TaskExtractor.llmTier, .mini)
        XCTAssertEqual(TaskExtractor.llmServiceId, "TaskExtractor")
    }

    func test_screenExtractor_usesMediumTier_postProductionFix() {
        // Schema = observations[] + memories[] + tasks[] (most complex in
        // codebase). 8B-instant emitted malformed JSON in PID 24170 logs.
        XCTAssertEqual(ScreenExtractor.llmTier, .medium)
        XCTAssertEqual(ScreenExtractor.llmServiceId, "ScreenExtractor")
    }

    // === Medium tier — complex extraction + user-facing advice / synthesis ===

    /// Complex-schema extraction lifted to medium after 8B-instant
    /// truncated the JSON in production (parse failure 2026-05-28).
    /// Still ~7× cheaper than the historical heavy default.
    func test_memoryExtractor_usesMediumTier_postProductionFix() {
        XCTAssertEqual(MemoryExtractor.llmTier, .medium)
        XCTAssertEqual(MemoryExtractor.llmServiceId, "MemoryExtractor")
    }

    func test_structuredGenerator_usesMediumTier_postProductionFix() {
        XCTAssertEqual(StructuredGenerator.llmTier, .medium)
        XCTAssertEqual(StructuredGenerator.llmServiceId, "StructuredGenerator")
    }

    func test_adviceService_usesMediumTier() {
        XCTAssertEqual(AdviceService.llmTier, .medium)
        XCTAssertEqual(AdviceService.llmServiceId, "AdviceService")
    }

    func test_insightAssistantService_usesMediumTier() {
        XCTAssertEqual(InsightAssistantService.llmTier, .medium)
        XCTAssertEqual(InsightAssistantService.llmServiceId, "InsightAssistantService")
    }

    func test_realtimeScreenReactor_usesMediumTier() {
        XCTAssertEqual(RealtimeScreenReactor.llmTier, .medium)
        XCTAssertEqual(RealtimeScreenReactor.llmServiceId, "RealtimeScreenReactor")
    }

    func test_weeklyPatternDetector_usesMediumTier() {
        XCTAssertEqual(WeeklyPatternDetector.llmTier, .medium)
        XCTAssertEqual(WeeklyPatternDetector.llmServiceId, "WeeklyPatternDetector")
    }

    func test_dailySummaryService_usesMediumTier() {
        XCTAssertEqual(DailySummaryService.llmTier, .medium)
        XCTAssertEqual(DailySummaryService.llmServiceId, "DailySummaryService")
    }

    // === Heavy tier — quality-critical user-facing surfaces ===

    func test_meetingCoachService_usesHeavyTier() {
        XCTAssertEqual(MeetingCoachService.llmTier, .heavy)
        XCTAssertEqual(MeetingCoachService.llmServiceId, "MeetingCoachService")
    }

    func test_chatService_usesHeavyTier() {
        XCTAssertEqual(ChatService.llmTier, .heavy)
        XCTAssertEqual(ChatService.llmServiceId, "ChatService")
    }

    // === Corner case — no service may accidentally claim heavy on an
    // extraction-style task. If you change one of these, double-check the
    // tier table in ITER-041 first. ===

    func test_noExtractionServiceClaimsHeavy() {
        let extractionServices: [LLMTier] = [
            MemoryExtractor.llmTier,
            TaskExtractor.llmTier,
            StructuredGenerator.llmTier,
            ScreenExtractor.llmTier,
        ]
        for tier in extractionServices {
            XCTAssertNotEqual(tier, .heavy, "Extraction services must not run on heavy tier")
        }
    }

    /// Production-evidence-driven test: extractor schemas that emitted
    /// truncated JSON on 8B-instant must NOT be on mini tier.
    func test_complexSchemaExtractors_areAtLeastMedium() {
        XCTAssertEqual(MemoryExtractor.llmTier, .medium,
                       "MemoryExtractor schema is too complex for mini — see WAL 2026-05-28")
        XCTAssertEqual(StructuredGenerator.llmTier, .medium,
                       "StructuredGenerator schema is too complex for mini — see WAL 2026-05-28")
        XCTAssertEqual(ScreenExtractor.llmTier, .medium,
                       "ScreenExtractor 3-array schema is too complex for mini — see WAL 2026-05-28")
    }
}
