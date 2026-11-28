import SwiftData
import XCTest
@testable import MetaWhisp

/// FEAT-0005 §6 — the after-call card offers the call's drafts with ✓ / ✗; what it accepts is the same row the
/// Tasks list shows (one task, K12), and a draft that landed after the card opened still reaches it.
@MainActor
final class MeetingRecapDraftsTests: XCTestCase {

    private var dir: URL!
    private var container: ModelContainer!
    private let quiet = MutationService(runHooks: { _ in })
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private let call = UUID()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("recap-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        let config = ModelConfiguration(schema: schema, url: dir.appendingPathComponent("test.store"))
        container = try ModelContainer(for: schema, configurations: [config])
    }

    override func tearDownWithError() throws {
        container = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func row(_ description: String, status: String, conversation: UUID? = nil, ageDays: Double = 0.01,
                     assignee: String? = nil) throws -> UUID {
        let t = TaskItem(taskDescription: description, sourceApp: "meeting", conversationId: conversation ?? call,
                         status: status, assignee: assignee)
        t.createdAt = now.addingTimeInterval(-ageDays * 86_400)
        let ctx = ModelContext(container)
        ctx.insert(t)
        try ctx.save()
        return t.id
    }

    private func present() {
        let split = MeetingRecapState.tasks(for: call, in: ModelContext(container), now: now)
        MeetingRecapState.shared.present(.init(
            conversationId: call, emoji: nil, title: "Call", overview: "", durationSec: 600, language: nil,
            calendarEventTitle: nil, participants: [], decisions: [], nextSteps: [],
            actionItems: split.actionItems, drafts: split.drafts, memories: [], transcript: ""))
    }

    private var payload: MeetingRecapState.Payload? { MeetingRecapState.shared.payload }

    func testTheCardSplitsTheCallsTasksFromItsDrafts() throws {
        try row("Send the pricing sheet to the client", status: "committed")
        try row("Book the venue for the offsite", status: "staged", assignee: "Maya")
        try row("Draft from another call", status: "staged", conversation: UUID())
        try row("Expired draft of this call", status: "staged", ageDays: 8)
        let split = MeetingRecapState.tasks(for: call, in: ModelContext(container), now: now)
        XCTAssertEqual(split.actionItems.map(\.description), ["Send the pricing sheet to the client"])
        XCTAssertEqual(split.drafts.map(\.description), ["Book the venue for the offsite"])
        XCTAssertEqual(split.drafts.first?.assignee, "Maya")
    }

    func testAcceptOnTheCardMovesTheDraftToTheActionItems() throws {
        let id = try row("Book the venue for the offsite", status: "staged")
        present()
        MeetingRecapState.shared.acceptDraft(id, in: container, now: now, mutations: quiet)
        XCTAssertEqual(payload?.drafts.count, 0)
        XCTAssertEqual(payload?.actionItems.map(\.id), [id])
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.status, "committed")
    }

    func testDropOnTheCardRemovesTheDraft() throws {
        let id = try row("Book the venue for the offsite", status: "staged")
        present()
        MeetingRecapState.shared.dropDraft(id, in: container, now: now, mutations: quiet)
        XCTAssertEqual(payload?.drafts.count, 0)
        XCTAssertEqual(payload?.actionItems.count, 0)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.isDismissed, true)
    }

    /// K11 — the card stayed open past the window: ✓ is refused and the row leaves the card.
    func testAnExpiredDraftOnAnOpenCardIsNotAdded() throws {
        let id = try row("Book the venue for the offsite", status: "staged", ageDays: 6.99)
        present()
        MeetingRecapState.shared.acceptDraft(id, in: container, now: now.addingTimeInterval(86_400), mutations: quiet)
        XCTAssertEqual(payload?.drafts.count, 0)
        XCTAssertEqual(payload?.actionItems.count, 0)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.status, "staged")
    }

    /// Accepted in Tasks while the card is open: ✓ on the card adds nothing new and shows it added.
    func testADraftAcceptedElsewhereShowsAsAdded() throws {
        let id = try row("Book the venue for the offsite", status: "staged")
        present()
        XCTAssertEqual(TaskDrafts.accept(id, in: container, now: now, mutations: quiet), .added)
        MeetingRecapState.shared.acceptDraft(id, in: container, now: now, mutations: quiet)
        XCTAssertEqual(payload?.actionItems.map(\.id), [id])
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).count, 1)
    }

    /// The extraction can finish after the card opened: its drafts reach the open card of that call only.
    func testDraftsThatLandAfterTheCardOpenedReachIt() throws {
        present()
        XCTAssertEqual(payload?.drafts.count, 0)
        try row("Book the venue for the offsite", status: "staged")
        MeetingRecapState.shared.reloadDrafts(for: UUID(), in: container, now: now)
        XCTAssertEqual(payload?.drafts.count, 0, "another call's extraction does not touch this card")
        MeetingRecapState.shared.reloadDrafts(for: call, in: container, now: now)
        XCTAssertEqual(payload?.drafts.map(\.description), ["Book the venue for the offsite"])
    }


    /// K10 on the card: after one of five is handled, the sixth comes in.
    func testTheCardRefillsAfterADraftIsHandled() throws {
        var ids: [UUID] = []
        for i in 0..<6 { ids.append(try row("Draft number \(i) of the call", status: "staged", ageDays: 0.01 + Double(i) * 0.001)) }
        present()
        XCTAssertEqual(payload?.drafts.count, 5)
        MeetingRecapState.shared.acceptDraft(ids[0], in: container, now: now, mutations: quiet)
        XCTAssertEqual(payload?.drafts.count, 5, "the sixth one comes in")
        XCTAssertTrue(payload?.drafts.contains { $0.id == ids[5] } ?? false)
        XCTAssertEqual(payload?.actionItems.map(\.id), [ids[0]])
    }

    /// Accepted in Tasks, then the extraction reloads the card: the row is shown added, not lost.
    func testAReloadShowsADraftAcceptedElsewhereAsAdded() throws {
        let id = try row("Book the venue for the offsite", status: "staged")
        present()
        XCTAssertEqual(TaskDrafts.accept(id, in: container, now: now, mutations: quiet), .added)
        MeetingRecapState.shared.reloadDrafts(for: call, in: container, now: now)
        XCTAssertEqual(payload?.drafts.count, 0)
        XCTAssertEqual(payload?.actionItems.map(\.id), [id])
    }
}
