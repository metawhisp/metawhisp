import SwiftData
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// FEAT-0006 §3, §5, §6 — the tracker's operations on real on-disk stores (the main store and `Tracker.store`), each
/// call in fresh contexts, as the socket and the Tasks window use them.
@MainActor
final class TrackerServiceTests: XCTestCase {

    private var dir: URL!
    private var main: ModelContainer!
    private var tracker: ModelContainer!
    private var service: TrackerService!
    private var clock = Date(timeIntervalSince1970: 1_795_000_000)
    private var acme: String { dir.appendingPathComponent("Code/Acme").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        let cfg = ModelConfiguration(schema: schema, url: dir.appendingPathComponent("Main.store"))
        main = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self, configurations: [cfg])
        tracker = try TrackerStore.makeContainer(url: dir.appendingPathComponent("Tracker.store"))
        service = makeService()
    }

    override func tearDownWithError() throws {
        StoreHealthSignal.shared.set(healthy: true)
        service = nil
        main = nil
        tracker = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeService() -> TrackerService {
        TrackerService(main: main, tracker: tracker, mutations: MutationService(runHooks: { _ in }),
                       home: dir.path, now: { [unowned self] in self.clock })
    }

    private func create(_ title: String, in folder: String? = nil,
                        _ tweak: (inout TaskCreateInput) -> Void = { _ in }) throws -> TrackerTaskDetail {
        var input = TaskCreateInput(title: title)
        tweak(&input)
        return try service.create(input, folder: folder ?? acme, client: "Claude Code")
    }

    private func edit(_ id: String, _ tweak: (inout TaskEditInput) -> Void) throws -> TrackerTaskDetail {
        var input = TaskEditInput(id: id)
        tweak(&input)
        return try service.edit(input, folder: acme, client: "Claude Code")
    }

    private func tasks() throws -> [TaskItem] { try ModelContext(main).fetch(FetchDescriptor<TaskItem>()) }
    private func aliases() throws -> [ProjectAlias] { try ModelContext(main).fetch(FetchDescriptor<ProjectAlias>()) }
    private func tracked() throws -> [TrackedProject] { try ModelContext(tracker).fetch(FetchDescriptor<TrackedProject>()) }
    private func records() throws -> [TaskTrackerRecord] {
        try ModelContext(tracker).fetch(FetchDescriptor<TaskTrackerRecord>())
    }

    private func failure(_ body: () throws -> Void) -> TrackerFailure? {
        do { try body(); return nil } catch let f as TrackerFailure { return f } catch { return nil }
    }

    // MARK: - S1: tasks land in the folder's project

    func testTheFirstTaskFromAFolderMakesItsProjectAndTask1() throws {
        let t = try create("Add search")
        XCTAssertEqual(t.summary.id, "TASK-1")
        XCTAssertEqual(t.summary.status, "To Do")
        XCTAssertEqual(t.summary.project, "Acme")
        XCTAssertEqual(try aliases().map(\.canonicalName), ["Acme"])
        let project = try XCTUnwrap(try tracked().first)
        XCTAssertEqual(project.folders, [acme])
        XCTAssertEqual(project.originKind, .agent)
        let task = try XCTUnwrap(try tasks().first)
        XCTAssertEqual(task.taskDescription, "Add search")
        XCTAssertEqual(task.effectiveStatus, "committed", "an agent's task is a task, never a draft")
        XCTAssertEqual(task.sourceApp, "Claude Code")
    }

    func testASecondSessionInTheSameFolderListsTheTasks() throws {
        _ = try create("One")
        _ = try create("Two")
        service = makeService()
        let listed = try service.list(TaskListInput(), folder: acme)
        XCTAssertEqual(listed.project, "Acme")
        XCTAssertEqual(listed.tasks.map(\.id), ["TASK-1", "TASK-2"])
        XCTAssertEqual(try aliases().count, 1, "one project, not one per task")
    }

    func testAnExistingProjectIsTakenByNameAndBecomesReal() throws {
        let ctx = ModelContext(main)
        let existing = ProjectAlias(canonicalName: "Pixel Garden")
        ctx.insert(existing)
        try ctx.save()
        let t = try create("Fix upload", in: dir.appendingPathComponent("Code/pixel-gar_den").path)
        XCTAssertEqual(t.summary.project, "Pixel Garden")
        XCTAssertEqual(try aliases().count, 1, "no second project")
        XCTAssertEqual(try tracked().first?.projectId, existing.id)
    }

    func testAnAliasNameMatchesToo() throws {
        let ctx = ModelContext(main)
        let existing = ProjectAlias(canonicalName: "NovaDesk")
        existing.addAlias("Nova Desk Studio")
        ctx.insert(existing)
        try ctx.save()
        let t = try create("Ship", in: dir.appendingPathComponent("Code/nova-desk-studio").path)
        XCTAssertEqual(t.summary.project, "NovaDesk")
    }

    func testARememberedFolderOutranksTheNameAndCoversItsSubfolders() throws {
        _ = try create("One")
        let ctx = ModelContext(main)
        let row = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ProjectAlias>()).first)
        row.canonicalName = "Renamed by the user"
        try ctx.save()
        let other = ProjectAlias(canonicalName: "Acme")
        ctx.insert(other)
        try ctx.save()
        let t = try create("Two", in: acme + "/Sources/App")
        XCTAssertEqual(t.summary.project, "Renamed by the user", "the folder link holds after a rename (C5)")
        XCTAssertEqual(t.summary.id, "TASK-2")
    }

    func testReadingFromAnUnknownFolderCreatesNothing() throws {
        let listed = try service.list(TaskListInput(), folder: dir.appendingPathComponent("Code/Nothing").path)
        XCTAssertNil(listed.project)
        XCTAssertTrue(listed.tasks.isEmpty)
        XCTAssertTrue(try aliases().isEmpty)
        XCTAssertTrue(try tracked().isEmpty)
    }

    func testTheHomeFolderCannotBeAProject() throws {
        let f = failure { _ = try create("x", in: dir.path) }
        XCTAssertEqual(f?.code, .noProject)
        XCTAssertTrue(try tasks().isEmpty)
        XCTAssertTrue(try aliases().isEmpty)
    }

    // MARK: - S2: To Do → In Progress → Done

    func testMovesBetweenColumnsWriteTheTaskAndTheRecord() throws {
        _ = try create("Build it")
        var t = try edit("TASK-1") { $0.status = .inProgress }
        XCTAssertEqual(t.summary.status, "In Progress")
        XCTAssertNotNil(try records().first?.startedAt)
        XCTAssertEqual(try tasks().first?.completed, false)
        t = try edit("task-01") { $0.status = .done }
        XCTAssertEqual(t.summary.status, "Done")
        XCTAssertEqual(try tasks().first?.completed, true)
        XCTAssertNotNil(try tasks().first?.completedAt)
        t = try edit("TASK-1") { $0.status = .toDo }
        XCTAssertEqual(t.summary.status, "To Do")
        XCTAssertEqual(try tasks().first?.completed, false)
        XCTAssertNil(try records().first?.startedAt)
    }

    func testATaskCreatedInProgressOrDoneStartsThere() throws {
        XCTAssertEqual(try create("a") { $0.status = .inProgress }.summary.status, "In Progress")
        XCTAssertEqual(try create("b") { $0.status = .done }.summary.status, "Done")
        XCTAssertEqual(try tasks().filter(\.completed).count, 1)
    }

    func testDraftStatusIsRefusedThroughTheWire() throws {
        let reply = service.handle(TrackerRequest(op: "task_create", folder: acme, client: "Codex",
                                                  args: ["title": .string("x"), "status": .string("Draft")]))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.code, .validation)
        XCTAssertTrue(reply.message?.contains("Drafts") == true, reply.message ?? "")
        XCTAssertTrue(try tasks().isEmpty)
    }

    func testADraftIsInvisibleAndUntouchableForAgents() throws {
        _ = try create("Real")
        let ctx = ModelContext(main)
        let draft = TaskItem(taskDescription: "Suggested after a call", sourceApp: "meeting", status: "staged")
        ctx.insert(draft)
        try ctx.save()
        // Even a draft that somehow carries a record of this project stays out.
        let projectId = try XCTUnwrap(try tracked().first?.projectId)
        let tctx = ModelContext(tracker)
        tctx.insert(TaskTrackerRecord(taskId: draft.id, projectId: projectId, key: "9", body: TrackerTaskBody()))
        try tctx.save()
        XCTAssertEqual(try service.list(TaskListInput(), folder: acme).tasks.map(\.id), ["TASK-1"])
        var search = TaskSearchInput()
        search.query = "call"
        XCTAssertTrue(try service.search(search, folder: acme).tasks.isEmpty)
        XCTAssertEqual(failure { _ = try edit("TASK-9") { $0.title = "mine now" } }?.code, .taskNotFound)
        XCTAssertEqual(try ModelContext(main).fetch(FetchDescriptor<TaskItem>()).first { $0.id == draft.id }?
            .taskDescription, "Suggested after a call")
    }

    // MARK: - Archive, restore, delete (I4)

    func testArchiveHidesTheTaskAndRestoreBringsBackItsColumn() throws {
        _ = try create("Old idea")
        _ = try edit("TASK-1") { $0.status = .inProgress }
        // The agent that has it In Progress puts it away (another agent could not: Q2).
        let archived = try service.archive(id: "TASK-1", folder: acme, client: "Claude Code")
        XCTAssertTrue(archived.summary.archived)
        XCTAssertTrue(try service.list(TaskListInput(), folder: acme).tasks.isEmpty)
        let task = try XCTUnwrap(try tasks().first)
        XCTAssertTrue(task.isDismissed)
        XCTAssertEqual(task.effectiveStatus, "dismissed", "hidden everywhere tasks show")
        var search = TaskSearchInput()
        search.query = "idea"
        XCTAssertEqual(try service.search(search, folder: acme).tasks.map(\.archived), [true])
        XCTAssertEqual(failure { _ = try edit("TASK-1") { $0.title = "x" } }?.message.contains("restore"), true)
        let restored = try service.restore(id: "TASK-1", folder: acme)
        XCTAssertEqual(restored.summary.status, "In Progress")
        XCTAssertFalse(restored.summary.archived)
        XCTAssertEqual(try tasks().first?.isTask, true)
    }

    /// A tracker task hidden by any other path (the Tasks window's old ✗) is archived for the agent, never gone.
    func testATrackerTaskDismissedElsewhereCountsAsArchived() throws {
        _ = try create("Dropped in the app")
        let ctx = ModelContext(main)
        let task = try XCTUnwrap(try ctx.fetch(FetchDescriptor<TaskItem>()).first)
        task.isDismissed = true
        task.status = "dismissed"
        try ctx.save()
        XCTAssertTrue(try service.list(TaskListInput(), folder: acme).tasks.isEmpty)
        var search = TaskSearchInput()
        search.query = "dropped"
        XCTAssertEqual(try service.search(search, folder: acme).tasks.map(\.archived), [true])
        XCTAssertEqual(try service.restore(id: "TASK-1", folder: acme).summary.status, "To Do")
        XCTAssertEqual(failure { _ = try service.restore(id: "TASK-1", folder: acme) }?.code, .validation,
                       "restoring a task on the board is refused")
    }

    func testDeleteNeedsTheArchiveAndTheUsersYes() throws {
        _ = try create("Keep")
        _ = try create("Go") { $0.dependencies = ["TASK-1"] }
        _ = try create("Needs go") { $0.dependencies = ["TASK-2"] }
        XCTAssertEqual(failure { _ = try service.delete(TaskDeleteInput(id: "TASK-2", userConfirmed: true),
                                                         folder: acme) }?.message.contains("archive"), true)
        _ = try service.archive(id: "TASK-2", folder: acme)
        XCTAssertEqual(failure { _ = try service.delete(TaskDeleteInput(id: "TASK-2", userConfirmed: false),
                                                         folder: acme) }?.code, .validation)
        let message = try service.delete(TaskDeleteInput(id: "TASK-2", userConfirmed: true), folder: acme)
        XCTAssertTrue(message.contains("TASK-3"), "names the task whose link it removed: \(message)")
        XCTAssertEqual(try tasks().count, 2)
        XCTAssertEqual(try records().count, 2)
        XCTAssertEqual(try service.view(id: "TASK-3", folder: acme).summary.dependencies, [])
    }

    func testATaskWithSubtasksCannotBeDeleted() throws {
        _ = try create("Parent")
        _ = try create("Child") { $0.parentTaskId = "TASK-1" }
        _ = try service.archive(id: "TASK-1", folder: acme)
        let f = failure { _ = try service.delete(TaskDeleteInput(id: "TASK-1", userConfirmed: true), folder: acme) }
        XCTAssertEqual(f?.code, .validation)
        XCTAssertTrue(f?.message.contains("TASK-1.1") == true, f?.message ?? "")
    }

    // MARK: - Keys, subtasks, dependencies

    func testSubtasksTakeTheirParentsNumber() throws {
        _ = try create("Parent")
        XCTAssertEqual(try create("A") { $0.parentTaskId = "TASK-1" }.summary.id, "TASK-1.1")
        XCTAssertEqual(try create("B") { $0.parentTaskId = "1" }.summary.id, "TASK-1.2")
        XCTAssertEqual(try create("Next").summary.id, "TASK-2")
        let parent = try service.view(id: "TASK-1", folder: acme)
        XCTAssertEqual(parent.subtasks.map(\.id), ["TASK-1.1", "TASK-1.2"])
        XCTAssertEqual(failure { _ = try create("x") { $0.parentTaskId = "TASK-7" } }?.code, .validation)
    }

    func testArchivedNumbersAreNeverReused() throws {
        _ = try create("One")
        _ = try create("Two")
        _ = try service.archive(id: "TASK-2", folder: acme)
        XCTAssertEqual(try create("Three").summary.id, "TASK-3")
    }

    func testDependenciesMustExistMustNotBeSelfAndMustNotLoop() throws {
        _ = try create("A")
        _ = try create("B") { $0.dependencies = ["TASK-1"] }
        XCTAssertTrue(failure { _ = try create("C") { $0.dependencies = ["TASK-8", "TASK-9"] } }?
            .message.contains("TASK-8, TASK-9") == true)
        XCTAssertTrue(failure { _ = try edit("TASK-1") { $0.dependencies = ["TASK-1"] } }?
            .message.contains("itself") == true)
        let loop = failure { _ = try edit("TASK-1") { $0.dependencies = ["TASK-2"] } }
        XCTAssertEqual(loop?.message.contains("TASK-1 -> TASK-2 -> TASK-1"), true, loop?.message ?? "")
    }

    func testReadyMeansEveryDependencyIsDone() throws {
        _ = try create("A")
        _ = try create("B") { $0.dependencies = ["TASK-1"] }
        var ready = TaskListInput()
        ready.ready = true
        XCTAssertEqual(try service.list(ready, folder: acme).tasks.map(\.id), ["TASK-1"])
        _ = try edit("TASK-1") { $0.status = .done }
        XCTAssertEqual(try service.list(ready, folder: acme).tasks.map(\.id), ["TASK-2"])
    }

    // MARK: - Edits

    func testCriteriaEditsApplyInOrderAndAFailedEditWritesNothing() throws {
        _ = try create("Login") { $0.acceptanceCriteria = ["Works", "Tested"] }
        var t = try edit("TASK-1") { $0.acceptanceCriteriaCheck = [1] }
        XCTAssertEqual(t.acceptanceCriteria.map(\.checked), [true, false])
        t = try edit("TASK-1") { $0.acceptanceCriteriaSet = ["Tested", "Works", "Documented"] }
        XCTAssertEqual(t.acceptanceCriteria.map(\.text), ["Tested", "Works", "Documented"])
        XCTAssertEqual(t.acceptanceCriteria.map(\.checked), [false, true, false], "the tick follows its text")
        let f = failure { _ = try edit("TASK-1") { $0.title = "Changed"; $0.acceptanceCriteriaRemove = [7] } }
        XCTAssertEqual(f?.message, "Item #7 not found. Available indexes: #1-#3.")
        XCTAssertEqual(try tasks().first?.taskDescription, "Login", "nothing of a refused edit is written")
    }

    func testPlanNotesAndSummaryClearThenSetThenAppend() throws {
        _ = try create("Work")
        var t = try edit("TASK-1") { $0.planSet = "Step one" }
        t = try edit("TASK-1") { $0.planAppend = ["Step two"] }
        XCTAssertEqual(t.implementationPlan, "Step one\n\nStep two")
        t = try edit("TASK-1") { $0.planClear = true; $0.planAppend = ["Fresh"] }
        XCTAssertEqual(t.implementationPlan, "Fresh")
        t = try edit("TASK-1") { $0.notesAppend = ["Found the cause"]; $0.finalSummary = "Fixed" }
        XCTAssertEqual(t.implementationNotes, "Found the cause")
        XCTAssertEqual(t.finalSummary, "Fixed")
        t = try edit("TASK-1") { $0.commentsAppend = ["Looks good"]; $0.commentAuthor = "@sam" }
        XCTAssertEqual(t.comments.map(\.body), ["Looks good"])
        XCTAssertEqual(t.comments.first?.author, "@sam")
    }

    func testUnknownFieldsAreRefused() {
        let reply = service.handle(TrackerRequest(op: "task_create", folder: acme, client: nil,
                                                  args: ["title": .string("x"), "milestone": .string("m-1")]))
        XCTAssertEqual(reply.code, .validation)
        XCTAssertEqual(reply.message, "Unknown field 'milestone' is not allowed.")
    }

    func testAKeyOfAnotherProjectIsNotFoundHere() throws {
        _ = try create("Elsewhere", in: dir.appendingPathComponent("Code/Other").path)
        _ = try create("Here")
        _ = try create("Here too")
        XCTAssertEqual(try service.view(id: "TASK-2", folder: acme).summary.title, "Here too")
        XCTAssertEqual(failure { _ = try service.view(id: "TASK-3", folder: acme) }?.code, .taskNotFound)
    }

    // MARK: - List and search

    func testListFiltersByLabelsAssigneeAndLimit() throws {
        _ = try create("A") { $0.labels = ["web", "auth"]; $0.assignee = ["@claude"] }
        _ = try create("B") { $0.labels = ["web"] }
        _ = try create("C")
        var l = TaskListInput()
        l.labels = ["WEB", "auth"]
        XCTAssertEqual(try service.list(l, folder: acme).tasks.map(\.id), ["TASK-1"])
        l = TaskListInput()
        l.unassigned = true
        XCTAssertEqual(try service.list(l, folder: acme).tasks.map(\.id), ["TASK-2", "TASK-3"])
        l = TaskListInput()
        l.assignee = "@CLAUDE"
        XCTAssertEqual(try service.list(l, folder: acme).tasks.map(\.id), ["TASK-1"])
        l = TaskListInput()
        l.limit = 2
        XCTAssertEqual(try service.list(l, folder: acme).tasks.count, 2)
    }

    func testSearchPutsTitleHitsFirst() throws {
        _ = try create("Page layout") { $0.description = "The login form overlaps" }
        _ = try create("Fix login")
        var s = TaskSearchInput()
        s.query = "login"
        XCTAssertEqual(try service.search(s, folder: acme).tasks.map(\.id), ["TASK-2", "TASK-1"])
    }

    func testTheWireFormatsAListForTheAgent() throws {
        _ = try create("Plan") { $0.priority = .high }
        let reply = service.handle(TrackerRequest(op: "task_list", folder: acme, client: "Codex", args: [:]))
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.text, "Project: Acme\n\nTo Do:\n  [HIGH] TASK-1 - Plan")
        XCTAssertNotNil(reply.data)
    }

    // MARK: - One writer, fresh reads (I1, I5)

    func testAnEditKeepsWhatAnotherWriterSavedMeanwhile() throws {
        _ = try create("Shared")
        let other = ModelContext(main)
        let row = try XCTUnwrap(try other.fetch(FetchDescriptor<TaskItem>()).first)
        row.dueAt = Date(timeIntervalSince1970: 1_800_000_000)
        try other.save()
        _ = try edit("TASK-1") { $0.title = "Shared, renamed" }
        let saved = try XCTUnwrap(try tasks().first)
        XCTAssertEqual(saved.taskDescription, "Shared, renamed")
        XCTAssertEqual(saved.dueAt, Date(timeIntervalSince1970: 1_800_000_000), "no stale copy written back")
    }

    func testADegradedStoreRefusesWrites() throws {
        StoreHealthSignal.shared.set(healthy: false)
        XCTAssertEqual(failure { _ = try create("x") }?.code, .internalError)
        StoreHealthSignal.shared.set(healthy: true)
        XCTAssertTrue(try tasks().isEmpty)
        XCTAssertTrue(try aliases().isEmpty, "no project either")
    }
}
