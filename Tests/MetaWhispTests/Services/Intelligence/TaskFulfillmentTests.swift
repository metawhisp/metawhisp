import XCTest
@testable import MetaWhisp

/// ITER-057.5 — fulfillment detection pure logic.
final class TaskFulfillmentTests: XCTestCase {

    private func ref(_ desc: String) -> TaskFulfillment.OpenTaskRef {
        .init(id: UUID(), description: desc)
    }

    // MARK: - relatedTasks pre-filter

    func test_related_taskSharingTwoTokensWithOCR_included() {
        let task = ref("Написать Сергею Петровичу про отчёт")
        let ocr = "Чат с Сергею Петровичу\nПривет! Как дела?"
        XCTAssertEqual(TaskFulfillment.relatedTasks(ocr: ocr, tasks: [task]), [task])
    }

    func test_related_unrelatedTask_excluded() {
        let task = ref("Pay Stripe invoice for March")
        let ocr = "Telegram — Аня\nпривет, скинь фотки с выходных"
        XCTAssertTrue(TaskFulfillment.relatedTasks(ocr: ocr, tasks: [task]).isEmpty)
    }

    func test_related_singleSharedToken_notEnough() {
        let task = ref("Send Alex quarterly report")
        let ocr = "Some window mentioning Alex once"
        XCTAssertTrue(TaskFulfillment.relatedTasks(ocr: ocr, tasks: [task]).isEmpty)
    }

    func test_related_respectsLimitAndOrder() {
        let tasks = (0..<15).map { ref("Send Alex report part\($0) today") }
        let ocr = "Mail — send Alex report drafts"
        let related = TaskFulfillment.relatedTasks(ocr: ocr, tasks: tasks)
        XCTAssertEqual(related.count, TaskFulfillment.maxTasksPerCall)
        XCTAssertEqual(related.first, tasks.first, "input order (newest-first) preserved")
    }

    func test_related_emptyOCR_returnsNothing() {
        XCTAssertTrue(TaskFulfillment.relatedTasks(ocr: "", tasks: [ref("Send Alex report today")]).isEmpty)
    }

    // MARK: - promptSection

    func test_promptSection_emptyTasks_emptyString() {
        XCTAssertEqual(TaskFulfillment.promptSection(for: []), "")
    }

    func test_promptSection_listsIdAndDescription() {
        let task = ref("Reply to Sam about the contract")
        let section = TaskFulfillment.promptSection(for: [task])
        XCTAssertTrue(section.contains(task.id.uuidString))
        XCTAssertTrue(section.contains("Reply to Sam about the contract"))
    }

    // MARK: - confirmedIds gating

    /// OCR that actually contains the evidence the claims below cite.
    private let chatOCR = """
    Telegram — Sam
    Sam: any news on the contract?
    You: contract signed and sent, check your inbox
    """

    func test_confirmed_validIdWithEvidenceFromOCR_accepted() {
        let task = ref("Reply to Sam about the contract")
        let claims = [TaskFulfillment.FulfilledJSON(
            id: task.id.uuidString,
            evidence: "You: contract signed and sent, check your inbox")]
        XCTAssertEqual(TaskFulfillment.confirmedIds(claims, sent: [task], ocr: chatOCR), [task.id])
    }

    func test_confirmed_evidenceNotInOCR_rejected() {
        // The P1 review finding: a hallucinated/echoed "evidence" string that
        // does not occur on the actual screen must never close a task.
        let task = ref("Reply to Sam about the contract")
        let claims = [TaskFulfillment.FulfilledJSON(
            id: task.id.uuidString,
            evidence: "Reply to Sam about the contract")]   // prompt echo, not on screen
        XCTAssertTrue(TaskFulfillment.confirmedIds(claims, sent: [task], ocr: chatOCR).isEmpty)
    }

    func test_confirmed_evidenceSurvivesWhitespaceAndCaseNoise() {
        let task = ref("Reply to Sam about the contract")
        let claims = [TaskFulfillment.FulfilledJSON(
            id: task.id.uuidString,
            evidence: "you: CONTRACT signed   and sent, check your inbox")]
        XCTAssertEqual(TaskFulfillment.confirmedIds(claims, sent: [task], ocr: chatOCR), [task.id])
    }

    func test_confirmed_unknownId_rejected() {
        let task = ref("Reply to Sam about the contract")
        let claims = [TaskFulfillment.FulfilledJSON(
            id: UUID().uuidString,
            evidence: "You: contract signed and sent, check your inbox")]
        XCTAssertTrue(TaskFulfillment.confirmedIds(claims, sent: [task], ocr: chatOCR).isEmpty,
                      "LLM-invented ids must never complete anything")
    }

    func test_confirmed_shortEvidence_rejected() {
        let task = ref("Reply to Sam about the contract")
        let claims = [TaskFulfillment.FulfilledJSON(id: task.id.uuidString, evidence: "done")]
        XCTAssertTrue(TaskFulfillment.confirmedIds(claims, sent: [task], ocr: chatOCR).isEmpty)
    }

    func test_confirmed_nilOrGarbageEntries_rejected() {
        let task = ref("Reply to Sam about the contract")
        let claims = [
            TaskFulfillment.FulfilledJSON(id: task.id.uuidString, evidence: nil),
            TaskFulfillment.FulfilledJSON(id: "not-a-uuid", evidence: "long enough evidence string here"),
            TaskFulfillment.FulfilledJSON(id: nil, evidence: "long enough evidence string here"),
        ]
        XCTAssertTrue(TaskFulfillment.confirmedIds(claims, sent: [task], ocr: chatOCR).isEmpty)
        XCTAssertTrue(TaskFulfillment.confirmedIds(nil, sent: [task], ocr: chatOCR).isEmpty)
    }

    func test_confirmed_duplicateClaims_deduplicated() {
        let task = ref("Reply to Sam about the contract")
        let claim = TaskFulfillment.FulfilledJSON(
            id: task.id.uuidString,
            evidence: "You: contract signed and sent, check your inbox")
        XCTAssertEqual(TaskFulfillment.confirmedIds([claim, claim], sent: [task], ocr: chatOCR), [task.id])
    }

    // MARK: - ReactionJSON lossy decode (review finding: one bad entry must not
    // kill the whole parse)

    func test_reaction_decodesWithoutFulfilledField() {
        let json = #"{"hasTask": false, "relevance": 10, "evidence": ""}"#
        let parsed = RealtimeScreenReactor.parseReaction(json)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.hasTask, false)
        XCTAssertNil(parsed?.fulfilled)
    }

    func test_reaction_malformedFulfilledEntry_doesNotKillParse() {
        let good = UUID().uuidString
        let json = """
        {"hasTask": true, "description": "Reply to Sam about the contract draft",
         "relevance": 90, "evidence": "Sam: can you reply about the contract?",
         "fulfilled": [{"id": 3}, "garbage", {"id": "\(good)", "evidence": "You: contract signed and sent, all done"}]}
        """
        let parsed = RealtimeScreenReactor.parseReaction(json)
        XCTAssertNotNil(parsed, "malformed fulfilled entries must not fail the whole decode")
        XCTAssertEqual(parsed?.hasTask, true)
        XCTAssertEqual(parsed?.fulfilled?.compactMap(\.id), [good],
                       "the valid entry survives, garbage entries are dropped")
    }

    func test_reaction_fulfilledNonArray_toleratedAsNil() {
        let json = #"{"hasTask": false, "fulfilled": "nothing"}"#
        let parsed = RealtimeScreenReactor.parseReaction(json)
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.fulfilled)
    }
}
