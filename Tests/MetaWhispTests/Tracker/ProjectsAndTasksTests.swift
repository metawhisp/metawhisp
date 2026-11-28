import SwiftData
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// FEAT-0006 §9b (owner, 2026-11-26: projects and tasks are one) — a task's project is its record's project, else
/// the project of the conversation it came from; the board, the Projects list and a project's page all read that one
/// rule, and the projects a task can be in are exactly the Projects list.
@MainActor
final class ProjectsAndTasksTests: XCTestCase {

    private var dir: URL!
    private var main: ModelContainer!
    private var tracker: ModelContainer!
    private var service: TrackerService!
    private var aggregator: ProjectAggregator!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("projects-tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        main = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self,
                                  configurations: [ModelConfiguration(schema: schema, url: dir.appendingPathComponent("M.store"))])
        tracker = try TrackerStore.makeContainer(url: dir.appendingPathComponent("T.store"))
        service = TrackerService(main: main, tracker: tracker, mutations: MutationService(runHooks: { _ in }),
                                 home: dir.path)
        aggregator = ProjectAggregator()
        aggregator.configure(modelContainer: main, trackerContainer: tracker)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A project the calls made (not tracked), with one more spelling.
    @discardableResult
    private func project(_ name: String, alias: String? = nil) throws -> UUID {
        let ctx = ModelContext(main)
        let p = ProjectAlias(canonicalName: name)
        if let alias { p.addAlias(alias) }
        ctx.insert(p)
        try ctx.save()
        return p.id
    }

    /// A finished call tagged with `project`, and a task from it.
    @discardableResult
    private func callTask(_ title: String, project: String?) throws -> UUID {
        let ctx = ModelContext(main)
        let c = Conversation(source: "meeting")
        c.status = "completed"
        c.finishedAt = Date()
        c.primaryProject = project
        ctx.insert(c)
        let t = TaskItem(taskDescription: title, sourceApp: "meeting", status: "committed")
        t.conversationId = c.id
        ctx.insert(t)
        try ctx.save()
        return t.id
    }

    func testACallsTaskIsInItsConversationsProjectOnTheBoard() throws {
        let acme = try project("Acme")
        try callTask("Send the deck", project: "Acme")
        let card = try XCTUnwrap(service.boardCards(filter: .all, archived: false).first)
        XCTAssertEqual(card.projectId, acme)
        XCTAssertEqual(card.projectName, "Acme")
        XCTAssertEqual(service.boardCards(filter: .project(acme), archived: false).map(\.title), ["Send the deck"])
        XCTAssertTrue(service.boardCards(filter: .none, archived: false).isEmpty)
    }

    /// C25 — the conversation names the project by another spelling.
    func testAnAliasFindsItsProject() throws {
        let acme = try project("Acme", alias: "Acme Inc")
        try callTask("Send the deck", project: "acme inc")
        XCTAssertEqual(service.boardCards(filter: .all, archived: false).first?.projectId, acme)
    }

    /// C24 — the user (or an agent) put the task in another project: that wins.
    func testTheRecordsProjectWinsOverTheConversations() throws {
        try project("Acme")
        let beta = try service.createProject(name: "Beta")
        let task = try callTask("Send the deck", project: "Acme")
        try service.setProject(taskId: task, projectId: beta)
        let card = try XCTUnwrap(service.boardCards(filter: .all, archived: false).first)
        XCTAssertEqual(card.projectName, "Beta")
        XCTAssertEqual(card.key, "TASK-1", "a task placed in a project has its number there")
    }

    /// C23 — no project anywhere: the task is of no project ("+ add project").
    func testACallWithoutAProjectLeavesTheTaskWithout() throws {
        try project("Acme")
        try callTask("Book a room", project: nil)
        let card = try XCTUnwrap(service.boardCards(filter: .all, archived: false).first)
        XCTAssertNil(card.projectId)
        XCTAssertEqual(service.boardCards(filter: .none, archived: false).map(\.title), ["Book a room"])
    }

    /// P5 — the projects a task can be put in are the Projects list: calls' projects too, not only tracked ones.
    func testTheChoicesAreEveryProject() throws {
        try project("Acme")
        try callTask("Send the deck", project: "Acme")
        _ = try service.createProject(name: "Beta")
        XCTAssertEqual(service.projectChoices().map(\.name), ["Acme", "Beta"])
        XCTAssertEqual(Set(aggregator.listProjects(includeSingletons: true).map(\.canonicalName)), ["Acme", "Beta"])
    }

    /// The Projects list counts a task where the board shows it, once.
    func testTheProjectsListCountsTasksByTheSameRule() throws {
        try project("Acme")
        try callTask("Stays in Acme", project: "Acme")
        let moved = try callTask("Moved to Beta", project: "Acme")
        try callTask("Second call", project: "Acme")
        let beta = try service.createProject(name: "Beta")
        try service.setProject(taskId: moved, projectId: beta)
        let listed = Dictionary(uniqueKeysWithValues: aggregator.listProjects(includeSingletons: true)
            .map { ($0.canonicalName, $0.pendingTaskCount) })
        XCTAssertEqual(listed["Acme"], 2)
        XCTAssertEqual(listed["Beta"], 1)
        XCTAssertEqual(Set(aggregator.details(for: "Acme").tasks.map(\.taskDescription)), ["Stays in Acme", "Second call"])
        XCTAssertEqual(aggregator.details(for: "Beta").tasks.map(\.taskDescription), ["Moved to Beta"])
    }

    /// P4 — a project the user just made, with no conversation yet, is in the list.
    func testANewEmptyProjectIsListed() throws {
        _ = try service.createProject(name: "Gamma")
        XCTAssertEqual(aggregator.listProjects(includeSingletons: true).map(\.canonicalName), ["Gamma"])
    }

    /// §9b — an agent in the project's folder sees the tasks the user sees there, a call's task too, with a number it
    /// can name; the board shows the same number, and the number is given once.
    func testAnAgentSeesACallsTaskOfItsProjectWithANumber() throws {
        try project("Acme")
        let task = try callTask("Send the deck", project: "Acme")
        let folder = dir.appendingPathComponent("Code/Acme").path
        let listed = try service.list(TaskListInput(), folder: folder)
        XCTAssertEqual(listed.project, "Acme")
        XCTAssertEqual(listed.tasks.map(\.title), ["Send the deck"])
        XCTAssertEqual(listed.tasks.map(\.id), ["TASK-1"])
        XCTAssertEqual(try service.list(TaskListInput(), folder: folder).tasks.map(\.id), ["TASK-1"], "numbered once")
        XCTAssertEqual(service.boardCards(filter: .all, archived: false).first { $0.id == task }?.key, "TASK-1")
        XCTAssertEqual(try service.view(id: "TASK-1", folder: folder).summary.title, "Send the deck")
    }

    /// A finished call task is in Done for the agent too; a suggestion (draft) stays the user's and is not shown.
    func testAnAgentSeesDoneCallTasksButNoSuggestions() throws {
        try project("Acme")
        let done = try callTask("Book the venue", project: "Acme")
        let ctx = ModelContext(main)
        let row = try XCTUnwrap(ctx.fetch(FetchDescriptor<TaskItem>()).first { $0.id == done })
        row.completed = true
        let c = Conversation(source: "meeting")
        c.primaryProject = "Acme"
        ctx.insert(c)
        let draft = TaskItem(taskDescription: "A suggestion", sourceApp: "meeting", status: "staged")
        draft.conversationId = c.id
        ctx.insert(draft)
        try ctx.save()
        let listed = try service.list(TaskListInput(), folder: dir.appendingPathComponent("Code/Acme").path)
        XCTAssertEqual(listed.tasks.map(\.title), ["Book the venue"])
        XCTAssertEqual(listed.tasks.first?.status, "Done")
    }

    /// C26 — a task moved into a project that is then deleted goes back to its conversation's project (the delete
    /// dialog says the tasks leave the deleted project, not where they go).
    func testATaskMovedIntoADeletedProjectGoesBackToItsConversations() throws {
        let acme = try project("Acme")
        let task = try callTask("Send the deck", project: "Acme")
        let beta = try service.createProject(name: "Beta")
        try service.setProject(taskId: task, projectId: beta)
        _ = aggregator.deleteProject(canonicalName: "Beta")
        XCTAssertEqual(service.boardCards(filter: .all, archived: false).first?.projectId, acme)
    }

    /// C26 — a deleted project's tasks are of no project again.
    func testADeletedProjectsTasksHaveNoProject() throws {
        try project("Acme")
        try callTask("Send the deck", project: "Acme")
        _ = aggregator.deleteProject(canonicalName: "Acme")
        XCTAssertNil(service.boardCards(filter: .all, archived: false).first?.projectId)
    }
}
