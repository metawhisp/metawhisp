import XCTest
@testable import MetaWhisp

/// The bounded look into the user's own store.
///
/// The investigator could already search screen history; what it could not do
/// was connect the screen to what the product knows about the user — an open
/// task, a saved requirement — and anything it claimed from memory was silenced
/// as ungrounded because the evidence allowlist never saw the source. One
/// search per kind per run, and what comes back becomes citable evidence.
@MainActor
final class ScreenAgentRetrievalTests: XCTestCase {

    private func turn(_ tool: String, _ args: [String: Any] = [:]) -> InsightInvestigator.ModelTurn {
        .init(text: "", toolName: tool, toolArgs: args, toolArgsRaw: "{}", toolCallId: "c1")
    }

    /// One task search per run. The second is refused, not silently absorbed.
    func testTheSecondTaskSearchIsRefused() async {
        var calls = 0
        var scripted: [InsightInvestigator.ModelTurn] = [
            turn("search_screen_history", ["text_contains": "deck"]),
            turn("get_screen_text", ["id": 0]),
            turn("search_tasks", ["query": "deck"]),
            turn("search_tasks", ["query": "deck again"]),
            turn("no_advice", [:]),
        ]
        let outcome = await InsightInvestigator.run(
            snapshots: [.init(time: Date(), app: "Slack", window: "#launch",
                              ocr: "Anna: send the deck by 16:00")],
            userPrompt: "test",
            transport: { _, _ in scripted.removeFirst() },
            searchTasks: { _ in calls += 1; return "1 task: Send the deck to Anna" },
            searchMemories: { _ in XCTFail("never asked"); return "" })
        XCTAssertEqual(calls, 1, "the budget is one task search per run")
        guard case .none = outcome else { return XCTFail("scripted run ends in no_advice") }
    }

    /// What retrieval returned rides back with the advice, so the director can
    /// treat it as citable evidence.
    func testRetrievedRecordsRideBackWithTheAdvice() async {
        var scripted: [InsightInvestigator.ModelTurn] = [
            turn("search_screen_history", ["text_contains": "pricing"]),
            turn("get_screen_text", ["id": 0]),
            turn("search_memories", ["query": "SSO requirement"]),
            turn("provide_advice", ["advice": "This $49 plan has no SSO — you required SSO under $50",
                                    "headline": "Plan at $49 lacks SSO you required",
                                    "confidence": 0.9, "source_app": "Safari"]),
        ]
        let outcome = await InsightInvestigator.run(
            snapshots: [.init(time: Date(), app: "Safari", window: "Pricing",
                              ocr: "Team plan $49/mo — SSO available on Enterprise")],
            userPrompt: "test",
            transport: { _, _ in scripted.removeFirst() },
            searchTasks: { _ in "" },
            searchMemories: { _ in "requirement: SSO mandatory, budget under $50/mo" })
        guard case .advice(_, let retrieved) = outcome else {
            return XCTFail("scripted run ends in advice")
        }
        XCTAssertEqual(retrieved.count, 1)
        XCTAssertTrue(retrieved[0].text.contains("SSO mandatory"))
    }

    /// The end-to-end point: a claim naming the stored requirement is grounded
    /// once the retrieved record is in evidence — and silenced without it.
    func testARetrievedRequirementGroundsTheClaim() {
        let screen = "Team plan $49/mo — SSO available on Enterprise only"
        let requirement = InsightInvestigator.RetrievedRef(
            id: "m0", text: "requirement: SSO mandatory, budget under $50/mo")

        let (with, idsWith) = ScreenAgentCandidateAdapter.evidence(
            contextID: UUID(), ocrText: screen, retrieved: [requirement])
        var candidate = ScreenAgentCandidateAdapter.candidate(
            from: ExtractedInsight(
                body: "You required SSO under $50 — this $49 plan has SSO only on Enterprise",
                headline: "Plan at $49 lacks the SSO you required",
                reasoning: nil, category: "other", sourceApp: "Safari", confidence: 0.9),
            citing: idsWith)
        guard case .item = ScreenAgentDirector.decide(
            candidates: [candidate], evidence: with, screenText: screen, recentHeadlines: [])
        else { return XCTFail("with the requirement in evidence, the claim is grounded") }

        // Without retrieval the same claim must fail: "$50" exists nowhere.
        let (without, idsWithout) = ScreenAgentCandidateAdapter.evidence(
            contextID: UUID(), ocrText: screen)
        candidate.citedEvidenceIDs = idsWithout
        XCTAssertEqual(
            ScreenAgentDirector.decide(candidates: [candidate], evidence: without,
                                       screenText: screen, recentHeadlines: []),
            .silence(.ungrounded),
            "a claim citing a requirement nobody retrieved is an invented requirement")
    }
}
