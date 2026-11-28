import SwiftData
import XCTest
@testable import MetaWhisp

/// FEAT-0005 §5 — a draft is a suggestion the user accepts or drops, from Tasks or from the after-call card.
/// On the store the app really uses (SQLite on disk) and with two contexts: the window holds its own copy of a row
/// while the card writes, and a save writes back every field of a changed object (2026-11-24 stale-save rule).
@MainActor
final class TaskDraftsTests: XCTestCase {

    private var dir: URL!
    private var container: ModelContainer!
    private let quiet = MutationService(runHooks: { _ in })
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("task-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        let config = ModelConfiguration(schema: schema, url: dir.appendingPathComponent("test.store"))
        container = try ModelContainer(for: schema, configurations: [config])
    }

    override func tearDownWithError() throws {
        container = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func draft(_ description: String, ageDays: Double = 0.5, screen: Bool = false,
                       conversationId: UUID? = nil) throws -> UUID {
        let t = TaskItem(taskDescription: description, sourceApp: "microphone", conversationId: conversationId,
                         screenContextId: screen ? UUID() : nil, status: "staged")
        t.createdAt = now.addingTimeInterval(-ageDays * 86_400)
        t.updatedAt = t.createdAt
        let ctx = ModelContext(container)
        ctx.insert(t)
        try ctx.save()
        return t.id
    }

    private func rows() throws -> [TaskItem] {
        try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
    }

    private func stored(_ id: UUID) throws -> TaskItem {
        try XCTUnwrap(rows().first { $0.id == id })
    }

    // MARK: - Accept

    func testAcceptTurnsTheDraftIntoATaskWithTheSameId() throws {
        let id = try draft("Send the signed contract to Sam")
        XCTAssertEqual(TaskDrafts.accept(id, in: container, now: now, mutations: quiet), .added)
        let row = try stored(id)
        XCTAssertEqual(row.effectiveStatus, "committed")
        XCTAssertTrue(row.isTask)
        XCTAssertFalse(row.completed)
        XCTAssertEqual(row.updatedAt, now)
        XCTAssertEqual(try rows().count, 1, "one row, one task")
    }

    /// K12 — the card and the Tasks list each hold a copy; accepting in both makes one task.
    func testAcceptingFromTheCardAndThenFromTheWindowMakesOneTask() throws {
        let id = try draft("Send the signed contract to Sam")
        let window = ModelContext(container)
        let windowCopy = try XCTUnwrap(window.fetch(FetchDescriptor<TaskItem>()).first)
        XCTAssertEqual(windowCopy.effectiveStatus, "staged")

        XCTAssertEqual(TaskDrafts.accept(id, in: container, now: now, mutations: quiet), .added)      // the card
        XCTAssertEqual(TaskDrafts.accept(id, in: container, now: now, mutations: quiet), .alreadyAdded) // the window
        XCTAssertEqual(try rows().count, 1)
        XCTAssertEqual(try stored(id).effectiveStatus, "committed")
    }

    /// The window's stale copy never decides: a draft dropped on the card stays dropped when ✓ is pressed in Tasks.
    func testAcceptAfterADropElsewhereIsRefusedAndTheDropStays() throws {
        let id = try draft("Send the signed contract to Sam")
        let window = ModelContext(container)
        _ = try window.fetch(FetchDescriptor<TaskItem>())   // the list's copy, read before the drop

        XCTAssertEqual(TaskDrafts.drop(id, in: container, now: now, mutations: quiet), .dropped)
        XCTAssertEqual(TaskDrafts.accept(id, in: container, now: now, mutations: quiet), .dismissed)
        let row = try stored(id)
        XCTAssertTrue(row.isDismissed)
        XCTAssertEqual(row.effectiveStatus, "dismissed")
        XCTAssertFalse(row.isTask)
    }

    /// K11 — a suggestion older than the 7-day window cannot be accepted, even from a card still open.
    func testAcceptingAnExpiredDraftIsRefused() throws {
        let id = try draft("Renew the car insurance policy", ageDays: 7.5)
        XCTAssertEqual(TaskDrafts.accept(id, in: container, now: now, mutations: quiet), .expired)
        XCTAssertEqual(try stored(id).effectiveStatus, "staged", "no expiry writer: the row is left as it was")
    }

    /// The window ends: a draft just inside it is still accepted.
    func testAcceptingADraftInsideTheWindowWorksAnyway() throws {
        let id = try draft("Renew the car insurance policy", ageDays: 6.9)
        XCTAssertEqual(TaskDrafts.accept(id, in: container, now: now, mutations: quiet), .added)
    }

    func testAcceptingAMissingRowSaysGone() {
        XCTAssertEqual(TaskDrafts.accept(UUID(), in: container, now: now, mutations: quiet), .gone)
        XCTAssertEqual(TaskDrafts.drop(UUID(), in: container, now: now, mutations: quiet), .gone)
    }

    // MARK: - Drop

    func testDropHidesTheDraftAndKeepsTheRow() throws {
        let id = try draft("Send the signed contract to Sam")
        XCTAssertEqual(TaskDrafts.drop(id, in: container, now: now, mutations: quiet), .dropped)
        let row = try stored(id)
        XCTAssertTrue(row.isDismissed)
        XCTAssertEqual(row.effectiveStatus, "dismissed")
        XCTAssertEqual(row.updatedAt, now, "the drop time is what K9 compares later mentions with")
    }

    func testDroppingATaskAcceptedElsewhereIsRefused() throws {
        let id = try draft("Send the signed contract to Sam")
        XCTAssertEqual(TaskDrafts.accept(id, in: container, now: now, mutations: quiet), .added)
        XCTAssertEqual(TaskDrafts.drop(id, in: container, now: now, mutations: quiet), .alreadyAdded)
        XCTAssertTrue(try stored(id).isTask)
    }

    // MARK: - What is shown

    /// K10 — at most five, newest first; expired, dropped and done ones are not shown.
    func testAtMostFiveFreshDraftsAreShownNewestFirst() throws {
        for i in 0..<7 { _ = try draft("Draft number \(i) to review", ageDays: 1 + Double(i) * 0.1) }
        _ = try draft("Expired draft to review", ageDays: 8)
        let droppedId = try draft("Dropped draft to review", ageDays: 0.1)
        _ = TaskDrafts.drop(droppedId, in: container, now: now, mutations: quiet)
        let acceptedId = try draft("Accepted draft to review", ageDays: 0.1)
        _ = TaskDrafts.accept(acceptedId, in: container, now: now, mutations: quiet)

        let shown = TaskDrafts.visible(try rows(), now: now)
        XCTAssertEqual(shown.map(\.taskDescription),
                       (0..<5).map { "Draft number \($0) to review" })
    }

    func testOnlyAcceptedRowsAreTasks() {
        XCTAssertTrue(TaskItem(taskDescription: "a").isTask)
        XCTAssertFalse(TaskItem(taskDescription: "b", status: "staged").isTask)
        let legacy = TaskItem(taskDescription: "c")
        legacy.status = nil
        XCTAssertTrue(legacy.isTask, "legacy rows without a status are tasks")
        let dismissed = TaskItem(taskDescription: "d")
        dismissed.isDismissed = true
        XCTAssertFalse(dismissed.isTask)
    }
}
