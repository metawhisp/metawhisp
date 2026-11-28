import SwiftData
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// FEAT-0006 §9 — what the Tasks window shows (board and list) and the actions it takes, through the tracker.
@MainActor
final class TaskBoardTests: XCTestCase {

    private var dir: URL!
    private var main: ModelContainer!
    private var tracker: ModelContainer!
    private var service: TrackerService!
    private var acme: String { dir.appendingPathComponent("Code/Acme").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-board-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        main = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self,
                                  configurations: [ModelConfiguration(schema: schema, url: dir.appendingPathComponent("M.store"))])
        tracker = try TrackerStore.makeContainer(url: dir.appendingPathComponent("T.store"))
        service = TrackerService(main: main, tracker: tracker, mutations: MutationService(runHooks: { _ in }),
                                 home: dir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func voiceTask(_ title: String, status: String = "committed") throws -> UUID {
        let ctx = ModelContext(main)
        let t = TaskItem(taskDescription: title, sourceApp: "microphone", status: status)
        ctx.insert(t)
        try ctx.save()
        return t.id
    }

    private func cards(_ filter: TaskBoard.ProjectFilter = .all, archived: Bool = false) -> [TaskBoard.Card] {
        service.boardCards(filter: filter, archived: archived)
    }

    func testTheBoardHoldsAgentTasksAndPlainTasksButNoDrafts() throws {
        _ = try service.create(TaskCreateInput(title: "Agent task"), folder: acme, client: "Codex")
        _ = try voiceTask("Call the bank")
        _ = try voiceTask("A suggestion", status: "staged")
        let all = cards()
        XCTAssertEqual(Set(all.map(\.title)), ["Agent task", "Call the bank"])
        XCTAssertEqual(all.first { $0.title == "Agent task" }?.key, "TASK-1")
        XCTAssertEqual(all.first { $0.title == "Agent task" }?.projectName, "Acme")
        XCTAssertNil(all.first { $0.title == "Call the bank" }?.key)
        XCTAssertEqual(cards(.none).map(\.title), ["Call the bank"])
        let project = try XCTUnwrap(service.projectChoices().first)
        XCTAssertEqual(cards(.project(project.id)).map(\.title), ["Agent task"])
    }

    func testColumnsFollowTheBoardOrder() throws {
        let a = try voiceTask("A")
        let b = try voiceTask("B")
        _ = try voiceTask("C")
        try service.move(taskId: a, to: .inProgress)
        try service.move(taskId: b, to: .done)
        let columns = TaskBoard.columns(cards())
        XCTAssertEqual(columns.map(\.status), [.toDo, .inProgress, .done])
        XCTAssertEqual(columns.map { $0.cards.map(\.title) }, [["C"], ["A"], ["B"]])
    }

    func testMovingAPlainTaskGivesItARecordAndBack() throws {
        let id = try voiceTask("Plain")
        try service.move(taskId: id, to: .inProgress)
        XCTAssertEqual(cards().first?.status, .inProgress)
        XCTAssertEqual(try ModelContext(tracker).fetch(FetchDescriptor<TaskTrackerRecord>()).count, 1)
        try service.move(taskId: id, to: .done)
        XCTAssertEqual(try ModelContext(main).fetch(FetchDescriptor<TaskItem>()).first?.completed, true)
        try service.move(taskId: id, to: .toDo)
        XCTAssertEqual(cards().first?.status, .toDo, "C22: unticked → To Do")
    }

    func testADraftCannotBeMovedFromTheBoard() throws {
        let id = try voiceTask("Suggested", status: "staged")
        XCTAssertThrowsError(try service.move(taskId: id, to: .done))
        XCTAssertEqual(try ModelContext(main).fetch(FetchDescriptor<TaskItem>()).first?.effectiveStatus, "staged")
    }

    func testArchiveRestoreAndDeleteForeverFromTheWindow() throws {
        let id = try voiceTask("Old")
        try service.archive(taskId: id)
        XCTAssertTrue(cards().isEmpty)
        XCTAssertEqual(cards(archived: true).map(\.title), ["Old"])
        try service.restore(taskId: id)
        XCTAssertEqual(cards().map(\.title), ["Old"])
        XCTAssertThrowsError(try service.deleteForever(taskId: id), "only an archived task")
        try service.archive(taskId: id)
        try service.deleteForever(taskId: id)
        XCTAssertTrue(try ModelContext(main).fetch(FetchDescriptor<TaskItem>()).isEmpty)
        XCTAssertTrue(try ModelContext(tracker).fetch(FetchDescriptor<TaskTrackerRecord>()).isEmpty)
    }

    func testTheJunkArchivedBeforeTheTrackerStaysOutOfTheArchive() throws {
        let ctx = ModelContext(main)
        let junk = TaskItem(taskDescription: "Old junk", sourceApp: "microphone", status: "dismissed")
        junk.isDismissed = true
        ctx.insert(junk)
        try ctx.save()
        XCTAssertTrue(cards(archived: true).isEmpty)
    }

    func testANewTaskByTheUserLandsInThePickedProject() throws {
        let projectId = try service.createProject(name: "Acme")
        let id = try service.createTask(title: "Write the brief", projectId: projectId)
        let card = try XCTUnwrap(cards().first { $0.id == id })
        XCTAssertEqual(card.key, "TASK-1")
        XCTAssertEqual(card.projectName, "Acme")
        XCTAssertEqual(try ModelContext(tracker).fetch(FetchDescriptor<TrackedProject>()).first?.originKind, .user)
        // The agent in the folder of that name finds the same project and the next number.
        XCTAssertEqual(try service.create(TaskCreateInput(title: "Next"), folder: acme, client: "Codex").summary.id, "TASK-2")
        XCTAssertEqual(try service.createTask(title: "No project", projectId: nil).uuidString.isEmpty, false)
        XCTAssertEqual(cards(.none).map(\.title), ["No project"])
    }

    func testCreatingAProjectReusesOneOfTheSameName() throws {
        let ctx = ModelContext(main)
        let existing = ProjectAlias(canonicalName: "Pixel Garden")
        ctx.insert(existing)
        try ctx.save()
        XCTAssertEqual(try service.createProject(name: "pixel-garden"), existing.id)
        XCTAssertEqual(try ModelContext(main).fetch(FetchDescriptor<ProjectAlias>()).count, 1)
        XCTAssertThrowsError(try service.createProject(name: "   "))
    }

    func testMovingATaskToAnotherProjectGivesItThatProjectsNextNumber() throws {
        _ = try service.create(TaskCreateInput(title: "One"), folder: acme, client: nil)
        let other = try service.createProject(name: "Other")
        _ = try service.createTask(title: "Other one", projectId: other)
        let id = try XCTUnwrap(cards().first { $0.title == "One" }?.id)
        try service.setProject(taskId: id, projectId: other)
        XCTAssertEqual(cards(.project(other)).first { $0.id == id }?.key, "TASK-2", "C21")
        try service.setProject(taskId: id, projectId: nil)
        XCTAssertNil(cards().first { $0.id == id }?.key)
    }

    func testTickingACriterionFromTheDetail() throws {
        var input = TaskCreateInput(title: "Login")
        input.acceptanceCriteria = ["Works", "Tested"]
        _ = try service.create(input, folder: acme, client: nil)
        let id = try XCTUnwrap(cards().first?.id)
        try service.toggleCriterion(taskId: id, index: 2, expectedText: "Tested")
        let detail = try XCTUnwrap(service.detail(taskId: id))
        XCTAssertEqual(detail.detail?.acceptanceCriteria.map(\.checked), [false, true])
        XCTAssertEqual(cards().first?.criteriaDone, 1)
    }
}
