import SwiftData
import XCTest
@testable import MetaWhisp

/// FEAT-0005 — the extractor's whole pass with the model replaced: what is sent, how the answer is read, and that
/// every result is a draft (I1). The model's own answers are not testable; their parser and the rules are.
@MainActor
final class TaskExtractorSuggestionTests: XCTestCase {

    private var container: ModelContainer!
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    /// A conversation with one part per text, a minute apart, ending ten minutes before `now`.
    private func conversation(_ source: String, _ texts: [String]) throws -> (UUID, [UUID]) {
        let ctx = ModelContext(container)
        let start = now.addingTimeInterval(-600 - Double(texts.count) * 60)
        let conv = Conversation(source: source, startedAt: start)
        ctx.insert(conv)
        var ids: [UUID] = []
        for (i, text) in texts.enumerated() {
            let part = HistoryItem(text: text, language: "en", audioDuration: 5, processingTime: 1)
            part.createdAt = start.addingTimeInterval(Double(i) * 60)
            part.conversationId = conv.id
            part.source = source == "meeting" ? "meeting" : "microphone"
            ctx.insert(part)
            ids.append(part.id)
        }
        try ctx.save()
        return (conv.id, ids)
    }

    private func pass(_ id: UUID, answer: String) async throws -> (prompt: String, run: TaskExtractor.SuggestionRun?) {
        var sent = ""
        let result = try await TaskExtractor().suggest(conversationId: id, in: ModelContext(container),
                                                       route: .byok, now: now) { _, user in
            sent = user
            return answer
        }
        if case .done(let run) = result { return (sent, run) }
        return (sent, nil)
    }

    private func answer(_ items: [[String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["tasks": items])
        return String(decoding: data, as: UTF8.self)
    }

    private func good(_ description: String, kind: String = "mine", evidence: String,
                      assignee: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["description": description, "kind": kind, "evidence": evidence,
                                "due_at": NSNull(), "capture_confidence": 0.9, "ownership_confidence": 0.9,
                                "concrete_deliverable": true, "real_world": true]
        d["assignee"] = assignee ?? NSNull()
        return d
    }

    // MARK: - What is sent

    func testADictationIsSentAsADictation() async throws {
        let (id, _) = try conversation("dictation", ["Remind me to renew the car insurance policy."])
        let (prompt, _) = try await pass(id, answer: #"{"tasks": []}"#)
        XCTAssertTrue(prompt.hasPrefix("SOURCE: dictation"), prompt)
    }

    func testAMeetingIsSentAsACall() async throws {
        let (id, _) = try conversation("meeting", ["Me: Hi.\nThem: I'll send you the deck tonight."])
        let (prompt, _) = try await pass(id, answer: #"{"tasks": []}"#)
        XCTAssertTrue(prompt.hasPrefix("SOURCE: call"), prompt)
    }

    /// K14 — calendar attendees are not handed to the model to name people.
    func testCalendarAttendeesAreNotSent() async throws {
        let (id, _) = try conversation("meeting", ["Me: Hi.\nThem: I'll send you the deck tonight."])
        let ctx = ModelContext(container)
        let conv = try XCTUnwrap(ctx.fetch(FetchDescriptor<Conversation>()).first)
        conv.calendarEventTitle = "Weekly sync with Priya"
        conv.calendarEventStartDate = now.addingTimeInterval(-3_600)
        conv.calendarEventEndDate = now
        conv.calendarAttendeesJSON = #"["Priya", "Omar"]"#
        try ctx.save()
        let (prompt, _) = try await pass(id, answer: #"{"tasks": []}"#)
        XCTAssertFalse(prompt.contains("Priya"))
        XCTAssertFalse(prompt.contains("Omar"))
    }

    /// R3 — a phantom part is not sent, so nothing can cite it.
    func testAPhantomPartIsNotSent() async throws {
        let (id, _) = try conversation("dictation", ["Subtitles by DimaTorzok", "Remind me to renew the car insurance policy."])
        let (prompt, _) = try await pass(id, answer: #"{"tasks": []}"#)
        XCTAssertFalse(prompt.lowercased().contains("dimatorzok"))
        XCTAssertTrue(prompt.contains("--- fragment 1 ---\nRemind me to renew the car insurance policy."))
    }

    // MARK: - What comes back

    func testEveryResultIsADraft() async throws {
        let (id, parts) = try conversation("dictation", ["Morning.", "Remind me to renew the car insurance policy."])
        let (_, run) = try await pass(id, answer: answer([
            good("Renew the car insurance policy", kind: "asked_by_user", evidence: "renew the car insurance policy")]))
        let drafts = try XCTUnwrap(run?.drafts)
        XCTAssertEqual(drafts.count, 1)
        let d = try XCTUnwrap(drafts.first)
        XCTAssertEqual(d.status, "staged")
        XCTAssertFalse(d.isTask)
        XCTAssertNil(d.screenContextId)
        XCTAssertEqual(d.conversationId, id)
        XCTAssertEqual(d.sourceApp, "microphone")
        XCTAssertEqual(d.sourceTranscriptId, parts[1], "the part the evidence was found in")
        XCTAssertNil(d.assignee)
    }

    /// P7 (owner, 2026-11-26) — someone else's promise is not a suggestion for the user.
    func testAPromiseFromSomeoneElseInACallIsNoDraft() async throws {
        let (id, _) = try conversation("meeting", ["Me: Can you share the numbers?\nThem: Sure, Maya here, I'll send the revised budget by Friday."])
        let (_, run) = try await pass(id, answer: answer([
            good("Send the revised budget to me", kind: "waiting_on", evidence: "I'll send the revised budget", assignee: "Maya")]))
        XCTAssertEqual(run?.drafts.count, 0)
        XCTAssertEqual(run?.outcome.dropped.map(\.reason), [.unknownKind])
    }

    func testAnOldShapedAnswerIsReadButGivesNothing() async throws {
        let (id, _) = try conversation("dictation", ["I need to call the dentist about the appointment."])
        let (_, run) = try await pass(id, answer: #"{"tasks": [{"description": "Call the dentist about the appointment", "due_at": null, "assignee": null}]}"#)
        let r = try XCTUnwrap(run, "an old answer is not unparseable")
        XCTAssertTrue(r.drafts.isEmpty)
        XCTAssertEqual(r.outcome.dropped.map(\.reason), [.unknownKind])
    }

    func testGarbageIsUnparseable() async throws {
        let (id, _) = try conversation("dictation", ["I need to call the dentist about the appointment."])
        let result = try await TaskExtractor().suggest(conversationId: id, in: ModelContext(container),
                                                       route: .byok, now: now) { _, _ in "{\"tasks\": [{\"descr" }
        guard case .unparseable = result else { return XCTFail("\(result)") }
    }

    func testATooShortConversationIsNotSent() async throws {
        let (id, _) = try conversation("dictation", ["ok"])
        var called = false
        let result = try await TaskExtractor().suggest(conversationId: id, in: ModelContext(container),
                                                       route: .byok, now: now) { _, _ in called = true; return "" }
        guard case .nothingToSend = result else { return XCTFail("\(result)") }
        XCTAssertFalse(called)
    }

    // MARK: - The store's own rows (R1 / K9)

    func testAnOpenTaskIsNotSuggestedAgain() async throws {
        let ctx = ModelContext(container)
        ctx.insert(TaskItem(taskDescription: "Renew the car insurance policy"))
        try ctx.save()
        let (id, _) = try conversation("dictation", ["Remind me to renew the car insurance policy."])
        let (_, run) = try await pass(id, answer: answer([
            good("Renew the car insurance policy", kind: "asked_by_user", evidence: "renew the car insurance policy")]))
        XCTAssertEqual(run?.drafts.count, 0)
        XCTAssertEqual(run?.outcome.dropped.map(\.reason), [.repeat])
    }

    /// S6 — "Extract now" runs the same conversation again: a draft dropped after it was said stays dropped.
    func testADroppedDraftDoesNotComeBackWhenTheSameTalkIsExtractedAgain() async throws {
        let (id, _) = try conversation("dictation", ["Remind me to renew the car insurance policy."])
        let ctx = ModelContext(container)
        let dropped = TaskItem(taskDescription: "Renew the car insurance policy", conversationId: id, status: "dismissed")
        dropped.isDismissed = true
        dropped.updatedAt = now.addingTimeInterval(-60)   // after the part was said, before this pass
        ctx.insert(dropped)
        try ctx.save()
        let (_, run) = try await pass(id, answer: answer([
            good("Renew the car insurance policy", kind: "asked_by_user", evidence: "renew the car insurance policy")]))
        XCTAssertEqual(run?.drafts.count, 0)
    }

    // MARK: - Parsing

    func testTheParserReadsTheNewFields() throws {
        let raw = #"""
        Here you go: {"tasks": [{"description": "Send the deck", "kind": "waiting_on", "evidence": "I'll send the deck",
        "due_at": "2026-11-27T22:59:00Z", "assignee": " sam ", "capture_confidence": "0.85",
        "ownership_confidence": 1, "concrete_deliverable": "true", "real_world": false}]}
        """#
        let c = try XCTUnwrap(TaskExtractor().parseCandidates(raw)?.first)
        XCTAssertEqual(c.kind, "waiting_on")
        XCTAssertEqual(c.evidence, "I'll send the deck")
        XCTAssertEqual(c.assignee, "Sam")
        XCTAssertEqual(c.captureConfidence, 0.85)
        XCTAssertEqual(c.ownershipConfidence, 1)
        XCTAssertEqual(c.concreteDeliverable, true)
        XCTAssertEqual(c.realWorld, false)
        XCTAssertEqual(c.dueAt, ISO8601DateFormatter().date(from: "2026-11-27T22:59:00Z"))
    }

    func testTheParserKeepsTheNilVersusEmptyContract() {
        XCTAssertNil(TaskExtractor().parseCandidates("[not json at all"))
        XCTAssertEqual(TaskExtractor().parseCandidates(#"{"tasks": []}"#)?.count, 0)
    }

    func testANullOwnerIsNoOwner() throws {
        let c = try XCTUnwrap(TaskExtractor().parseCandidates(#"{"tasks": [{"description": "Call mom", "assignee": "null"}]}"#)?.first)
        XCTAssertNil(c.assignee)
        XCTAssertNil(c.kind)
    }


    /// Shown newest first, at most five: within one pass the model's first item is the newest, so it is shown first.
    func testWithinOnePassTheModelsFirstItemIsTheNewest() async throws {
        let (id, _) = try conversation("dictation", ["Remind me to renew the car insurance policy and to book the dentist appointment."])
        let (_, run) = try await pass(id, answer: answer([
            good("Renew the car insurance policy", kind: "asked_by_user", evidence: "renew the car insurance policy"),
            good("Book the dentist appointment soon", kind: "asked_by_user", evidence: "book the dentist appointment")]))
        let drafts = try XCTUnwrap(run?.drafts)
        XCTAssertEqual(TaskDrafts.visible(drafts, now: now).map(\.taskDescription),
                       ["Renew the car insurance policy", "Book the dentist appointment soon"])
    }

    /// R1 sees every open task, however many there are.
    func testAnOldOpenTaskBlocksARepeatAmongThousands() async throws {
        let ctx = ModelContext(container)
        let oldest = TaskItem(taskDescription: "Renew the car insurance policy")
        oldest.createdAt = now.addingTimeInterval(-400 * 86_400)
        ctx.insert(oldest)
        for i in 0..<2_050 { ctx.insert(TaskItem(taskDescription: "Open task number \(i)")) }
        try ctx.save()
        let (id, _) = try conversation("dictation", ["Remind me to renew the car insurance policy."])
        let (_, run) = try await pass(id, answer: answer([
            good("Renew the car insurance policy", kind: "asked_by_user", evidence: "renew the car insurance policy")]))
        XCTAssertEqual(run?.outcome.dropped.map(\.reason), [.repeat])
    }

    /// The local route's answer budget fits five items of the new shape (about four characters a token).
    func testTheLocalAnswerBudgetFitsFiveItems() throws {
        let item = good("Send the signed contract to Sam before the board meeting", kind: "mine",
                        evidence: "I have to send the signed contract to Sam before the board meeting on Friday")
        let five = answer(Array(repeating: item, count: 5))
        XCTAssertLessThan(five.count / 4, TaskExtractor.localAnswerTokens)
    }
}
