import SwiftData
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// Owner 2026-11-27 ("yes, all four", then "yes, do it"): edit a task in its window; In Progress is taken by one agent
/// session; agents read a task's moves; a project can be archived. Each pinned here.
@MainActor
final class TrackerFourAdditionsTests: XCTestCase {

    private var dir: URL!
    private var main: ModelContainer!
    private var tracker: ModelContainer!
    private var service: TrackerService!
    private var aggregator: ProjectAggregator!
    private var acme: String { dir.appendingPathComponent("Code/Acme").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-four-\(UUID().uuidString)")
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

    private func callTask(_ title: String, due: Date? = nil) throws -> UUID {
        let ctx = ModelContext(main)
        let t = TaskItem(taskDescription: title, dueAt: due, sourceApp: "meeting")
        ctx.insert(t)
        try ctx.save()
        return t.id
    }

    private func card(_ id: UUID) -> TaskBoard.Card? {
        service.boardCards(filter: .all, archived: false).first { $0.id == id }
    }

    // MARK: - 1. Edit in the task window

    func testTheWindowEditsTitleDueDateAndPriority() throws {
        let id = try callTask("Cal the bank", due: Date(timeIntervalSince1970: 1_790_000_000))
        try service.editFromApp(taskId: id, title: "  Call the bank  ")
        XCTAssertEqual(card(id)?.title, "Call the bank")
        try service.editFromApp(taskId: id, due: .day("2026-12-24"))
        XCTAssertEqual(card(id)?.dueAt, TrackerService.dueDate("2026-12-24").map { TaskDue.localDay($0) })
        XCTAssertEqual(card(id)?.dueIsDay, true, "a picked day reads as that day all day long")
        try service.editFromApp(taskId: id, priority: .set(.high))
        XCTAssertEqual(card(id)?.priority, .high)
        try service.editFromApp(taskId: id, due: .clear, priority: .set(nil))
        XCTAssertNil(card(id)?.dueAt)
        XCTAssertNil(card(id)?.priority)
        XCTAssertThrowsError(try service.editFromApp(taskId: id, title: "   "), "a task keeps a title")
    }

    /// The day the user picks is that calendar day where they are, stored the way an agent's day is.
    func testAPickedDateIsThatDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        let lateEvening = cal.date(from: DateComponents(year: 2026, month: 12, day: 24, hour: 23, minute: 30))!
        XCTAssertEqual(TaskDue.dayString(lateEvening, calendar: cal), "2026-12-24")
    }

    // MARK: - 2. In Progress is taken by one agent session

    private func agentCreate(_ title: String) throws -> String {
        try service.create(TaskCreateInput(title: title), folder: acme, client: "Claude Code", session: "one").summary.id
    }

    private func move(_ id: String, _ status: TrackerStatus, session: String, client: String = "Claude Code") throws {
        var e = TaskEditInput(id: id)
        e.status = status
        _ = try service.edit(e, folder: acme, client: client, session: session)
    }

    func testAnotherSessionCannotTakeOrMoveATakenTask() throws {
        let id = try agentCreate("Shared work")
        try move(id, .inProgress, session: "one")
        try move(id, .inProgress, session: "one")   // the same session again: fine
        XCTAssertThrowsError(try move(id, .inProgress, session: "two")) { error in
            let text = (error as? TrackerFailure)?.message ?? ""
            XCTAssertTrue(text.contains("already In Progress with Claude Code"), text)
            XCTAssertTrue(text.contains("move it back to To Do"), text)
        }
        XCTAssertThrowsError(try move(id, .toDo, session: "two"), "nor frees it")
        XCTAssertThrowsError(try service.archive(id: id, folder: acme, client: "Codex", session: "three"))
        var notes = TaskEditInput(id: id)
        notes.commentsAppend = ["Found a related bug"]
        XCTAssertNoThrow(try service.edit(notes, folder: acme, client: "Codex", session: "three"),
                         "a comment from another agent is fine")
        let line = TrackerFormat.line(try service.view(id: id, folder: acme).summary)
        XCTAssertTrue(line.contains("(Claude Code, since "), line)
    }

    /// The release: the user moves it back to To Do, and any agent can take it.
    func testTheUserFreesItByMovingItBack() throws {
        let id = try agentCreate("Left behind")
        try move(id, .inProgress, session: "one")
        let taskId = try XCTUnwrap(service.boardCards(filter: .all, archived: false).first?.id)
        try service.move(taskId: taskId, to: .toDo)
        XCTAssertNoThrow(try move(id, .inProgress, session: "two"))
    }

    /// Done ends the hold too.
    func testDoneFreesIt() throws {
        let id = try agentCreate("Finished")
        try move(id, .inProgress, session: "one")
        try move(id, .done, session: "one")
        try move(id, .toDo, session: "two")
        XCTAssertNoThrow(try move(id, .inProgress, session: "two"))
    }

    /// Without a session (the command line), the agent's name stands in.
    func testWithoutSessionsTheAgentsNameDecides() throws {
        let id = try agentCreate("CLI work")
        var e = TaskEditInput(id: id)
        e.status = .inProgress
        _ = try service.edit(e, folder: acme, client: "Codex", session: nil)
        XCTAssertNoThrow(try service.edit(e, folder: acme, client: "Codex", session: nil))
        XCTAssertThrowsError(try service.edit(e, folder: acme, client: "Claude Code", session: nil))
    }

    /// Which agent session runs a command, from what the agent hands it; Codex first, as one started from Claude Code
    /// inherits Claude's variables too.
    func testTheAgentsSessionComesFromItsEnvironment() {
        XCTAssertEqual(AgentCaller.from(environment: ["CLAUDE_CODE_SESSION_ID": "c1"]),
                       AgentCaller(client: "Claude Code", session: "c1"))
        XCTAssertEqual(AgentCaller.from(environment: ["CODEX_SESSION_ID": "x1"]), AgentCaller(client: "Codex", session: "x1"))
        XCTAssertEqual(AgentCaller.from(environment: ["CODEX_THREAD_ID": "x2"]), AgentCaller(client: "Codex", session: "x2"))
        XCTAssertEqual(AgentCaller.from(environment: ["CLAUDE_CODE_SESSION_ID": "c1", "CODEX_SESSION_ID": "x1"]),
                       AgentCaller(client: "Codex", session: "x1"))
        XCTAssertNil(AgentCaller.from(environment: [:]), "a person in a terminal")
        XCTAssertNil(AgentCaller.from(environment: ["CLAUDE_CODE_SESSION_ID": "  "]))
    }

    /// An MCP server an agent started is that agent session, the same one its commands carry; else its own.
    func testAnMCPServerTakesItsAgentsSession() {
        let given = MCPSession(cwd: "/tmp", pinned: true, resolveRoot: { $0 }, session: "c1", call: { _ in .success("") })
        XCTAssertEqual(given.session, "c1")
        let own = MCPSession(cwd: "/tmp", pinned: true, resolveRoot: { $0 }, call: { _ in .success("") })
        XCTAssertFalse(own.session.isEmpty)
    }

    /// One MCP server process is one session: its requests say so.
    func testTheMCPServerSendsItsSession() throws {
        var sent: [TrackerRequest] = []
        let session = MCPSession(cwd: acme, pinned: true, resolveRoot: { $0 }) { request in
            sent.append(request)
            return .success("ok")
        }
        _ = session.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}"#)
        _ = session.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_list","arguments":{}}}"#)
        XCTAssertEqual(sent.last?.session, session.session)
        XCTAssertNotNil(sent.last?.session)
    }

    // MARK: - 3. Agents read a task's moves

    /// The user dragging a Done card back is a rejection; the next agent reads it in the task's history.
    func testAnAgentReadsWhoMovedItAndWhen() throws {
        let id = try agentCreate("Ship it")
        try move(id, .inProgress, session: "one")
        try move(id, .done, session: "one")
        let taskId = try XCTUnwrap(service.boardCards(filter: .all, archived: false).first?.id)
        try service.move(taskId: taskId, to: .toDo)
        try service.archive(taskId: taskId)
        try service.restore(taskId: taskId)
        let history = try service.view(id: id, folder: acme).history
        XCTAssertEqual(history.map { "\($0.by ?? "?"): \($0.from ?? "-") > \($0.to)" }, [
            "Claude Code: - > To Do",
            "Claude Code: To Do > In Progress",
            "Claude Code: In Progress > Done",
            "user: Done > To Do",
            "user: To Do > Archived",
            "user: Archived > To Do",
        ])
        let text = TrackerFormat.view(try service.view(id: id, folder: acme))
        XCTAssertTrue(text.contains("History:"), text)
        XCTAssertTrue(text.contains("user · Done → To Do"), text)
    }

    /// The history keeps the last moves, not every move forever.
    func testTheHistoryIsCapped() {
        var body = TrackerTaskBody()
        for i in 0..<(TrackerEvent.kept + 10) {
            body.recordMove(from: i % 2 == 0 ? "To Do" : "In Progress", to: i % 2 == 0 ? "In Progress" : "To Do",
                            by: "user", at: Date(timeIntervalSince1970: Double(i)))
        }
        XCTAssertEqual(body.events?.count, TrackerEvent.kept)
        XCTAssertEqual(body.events?.first?.at, Date(timeIntervalSince1970: 10), "the oldest went")
    }

    /// Nothing about it in the app: the task window shows no history (Q3).
    func testTheAppShowsNoHistory() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized
        let sheet = try String(contentsOf: root.appendingPathComponent("Views/Windows/TasksBoardViews.swift"), encoding: .utf8)
        XCTAssertFalse(sheet.contains(".history"))
    }

    // MARK: - 4. Archive a project

    private func callProject(_ name: String, task title: String) throws -> UUID {
        let ctx = ModelContext(main)
        let p = ProjectAlias(canonicalName: name)
        ctx.insert(p)
        let c = Conversation(source: "meeting")
        c.primaryProject = name
        ctx.insert(c)
        let t = TaskItem(taskDescription: title, sourceApp: "meeting")
        t.conversationId = c.id
        ctx.insert(t)
        try ctx.save()
        return p.id
    }

    func testAnArchivedProjectLeavesTheGridAndThePickersButNotItsTasks() throws {
        let old = try callProject("Old Thing", task: "Close the account")
        _ = try service.createProject(name: "Live")
        try service.archiveProject(old)
        XCTAssertEqual(aggregator.listProjects(includeSingletons: true).map(\.canonicalName), ["Live"])
        XCTAssertEqual(aggregator.listProjects(includeSingletons: true, archived: true).map(\.canonicalName), ["Old Thing"])
        XCTAssertEqual(service.projectChoices().map(\.name), ["Live"], "+ add project and New task skip it")
        XCTAssertEqual(service.boardCards(filter: .all, archived: false).first?.projectName, "Old Thing",
                       "its task stays in Tasks with its name")
        XCTAssertNil(aggregator.existingCanonical(for: "Old Thing"), "a new call does not land in it")
        try service.restoreProject(old)
        XCTAssertEqual(Set(aggregator.listProjects(includeSingletons: true).map(\.canonicalName)), ["Live", "Old Thing"])
        XCTAssertEqual(aggregator.existingCanonical(for: "old thing"), "Old Thing")
    }

    /// An agent writing in its folder brings it back.
    func testAnAgentWritingInItsFolderBringsItBack() throws {
        _ = try agentCreate("First")
        let acmeId = try XCTUnwrap(service.projectChoices().first { $0.name == "Acme" }?.id)
        try service.archiveProject(acmeId)
        XCTAssertFalse(service.projectChoices().contains { $0.id == acmeId })
        XCTAssertNoThrow(try service.list(TaskListInput(), folder: acme), "reading does not bring it back")
        XCTAssertTrue(service.archivedProjectIds().contains(acmeId))
        _ = try agentCreate("Second")
        XCTAssertFalse(service.archivedProjectIds().contains(acmeId))
    }

    /// The user putting a task in it brings it back too.
    func testATaskPutInItBringsItBack() throws {
        let old = try callProject("Old Thing", task: "Close the account")
        try service.archiveProject(old)
        _ = try service.createTask(title: "One more", projectId: old)
        XCTAssertFalse(service.archivedProjectIds().contains(old))
    }

    /// A tracker store written by the build before (schema V1) opens with V2 and keeps everything.
    func testAVersionOneStoreOpensAndKeepsItsTasks() throws {
        let url = dir.appendingPathComponent("Old.store")
        do {
            let schema = Schema(versionedSchema: TrackerSchemaV1.self)
            let v1 = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let ctx = ModelContext(v1)
            ctx.insert(TaskTrackerRecord(taskId: UUID(), projectId: UUID(), key: "TASK-1", body: TrackerTaskBody(), now: Date()))
            try ctx.save()
        }
        let v2 = try TrackerStore.makeContainer(url: url)
        let ctx = ModelContext(v2)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<TaskTrackerRecord>()).map(\.key), ["TASK-1"])
        ctx.insert(ArchivedProject(projectId: UUID(), archivedAt: Date()))
        XCTAssertNoThrow(try ctx.save())
    }
}
