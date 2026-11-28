import SwiftData
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// 2026-11-27 (owner: "fix and recheck everything, compare with the reference trackers") — what the comparison with
/// agent trackers and the independent review found wrong, each pinned: ready means free to pick up, Done is not said
/// while work is open, single dependencies and labels, a stale index is refused, lists are capped and say so, writes
/// answer briefly, In Progress lines say who and since when, one name index, no rename onto a taken name, a project
/// page keeps its project, due dates read as dates.
@MainActor
final class TrackerRoundThreeTests: XCTestCase {

    private var dir: URL!
    private var main: ModelContainer!
    private var tracker: ModelContainer!
    private var service: TrackerService!
    private var aggregator: ProjectAggregator!
    private var acme: String { dir.appendingPathComponent("Code/Acme").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-r3-\(UUID().uuidString)")
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

    @discardableResult
    private func create(_ title: String, _ tweak: (inout TaskCreateInput) -> Void = { _ in }) throws -> String {
        var input = TaskCreateInput(title: title)
        tweak(&input)
        return try service.create(input, folder: acme, client: "Claude Code").summary.id
    }

    @discardableResult
    private func edit(_ id: String, _ tweak: (inout TaskEditInput) -> Void) throws -> TrackerTaskDetail {
        var input = TaskEditInput(id: id)
        tweak(&input)
        return try service.edit(input, folder: acme, client: "Claude Code")
    }

    /// The agent's answer text, as the socket returns it.
    private func call(_ op: String, _ args: [String: JSONValue]) -> String? {
        service.handle(TrackerRequest(op: op, folder: acme, client: "Claude Code", args: args)).text
    }

    // MARK: - ready

    func testReadyIsToDoWithNothingOpenItWaitsOn() throws {
        let a = try create("Taken")
        try edit(a) { $0.status = .inProgress }
        let b = try create("Blocked by a cancelled task")
        let cancelled = try create("Cancelled")
        try edit(b) { $0.dependencies = [cancelled] }
        _ = try service.archive(id: cancelled, folder: acme)
        try create("Free")
        var input = TaskListInput()
        input.ready = true
        let ready = try service.list(input, folder: acme).tasks.map(\.title)
        XCTAssertFalse(ready.contains("Taken"), "In Progress is someone's work already")
        XCTAssertTrue(ready.contains("Blocked by a cancelled task"), "an archived dependency no longer blocks")
        XCTAssertTrue(ready.contains("Free"))
        let view = TrackerFormat.view(try service.view(id: b, folder: acme))
        XCTAssertTrue(view.contains("[To Do, archived]"), view)
    }

    // MARK: - Done while work is open

    func testDoneIsRefusedWhileASubtaskIsOpenAndForceGoesThrough() throws {
        let parent = try create("Parent")
        try create("Step") { $0.parentTaskId = parent }
        XCTAssertThrowsError(try edit(parent) { $0.status = .done }) { error in
            XCTAssertTrue((error as? TrackerFailure)?.message.contains("TASK-1.1 (To Do)") == true, "\(error)")
        }
        let forced = try edit(parent) { $0.status = .done; $0.force = true; $0.commentsAppend = ["Step moved out"] }
        XCTAssertEqual(forced.summary.status, "Done")
    }

    func testDoneIsRefusedWhileADependencyIsOpen() throws {
        let first = try create("First")
        let second = try create("Second") { $0.dependencies = [first] }
        XCTAssertThrowsError(try edit(second) { $0.status = .done })
        try edit(first) { $0.status = .done }
        XCTAssertEqual(try edit(second) { $0.status = .done }.summary.status, "Done")
    }

    // MARK: - one dependency, one label

    func testDependenciesAndLabelsAddAndRemoveOneAtATime() throws {
        let a = try create("A"), b = try create("B"), c = try create("C")
        try edit(c) { $0.dependencies = [a] }
        try edit(c) { $0.addDependencies = [b] }
        XCTAssertEqual(try service.view(id: c, folder: acme).dependsOn.map(\.id), [a, b], "added, the other kept")
        try edit(c) { $0.removeDependencies = [a] }
        XCTAssertEqual(try service.view(id: c, folder: acme).dependsOn.map(\.id), [b])
        try edit(c) { $0.labels = ["web"]; $0.addLabels = ["api"] }
        try edit(c) { $0.addLabels = ["Web", "ios"]; $0.removeLabels = ["API"] }
        XCTAssertEqual(try service.view(id: c, folder: acme).summary.labels, ["web", "ios"])
        // C waits on B; B waiting on C closes a loop.
        XCTAssertThrowsError(try edit(b) { $0.addDependencies = [c] }, "a cycle through an added dependency")
    }

    func testTheCLIsDepFlagAdds() throws {
        guard case .request(_, let args, _) = try TrackerCLI.parse(["task", "edit", "TASK-5", "--dep", "TASK-7"]) else {
            return XCTFail("not a request")
        }
        XCTAssertEqual(args["addDependencies"], .array([.string("TASK-7")]))
        XCTAssertNil(args["dependencies"], "--dep never replaces the other dependencies")
    }

    // MARK: - a stale index

    func testAnEditWithAnOldRevisionIsRefused() throws {
        let id = try create("Criteria") { $0.acceptanceCriteria = ["One", "Two"] }
        let read = try service.view(id: id, folder: acme).summary.revision
        try edit(id) { $0.acceptanceCriteriaRemove = [1] }   // someone else changed it
        XCTAssertThrowsError(try edit(id) { $0.acceptanceCriteriaCheck = [1]; $0.expectedRevision = read }) { error in
            XCTAssertTrue((error as? TrackerFailure)?.message.contains("changed since you read it") == true)
        }
        let now = try service.view(id: id, folder: acme).summary.revision
        XCTAssertEqual(try edit(id) { $0.acceptanceCriteriaCheck = [1]; $0.expectedRevision = now }
                        .acceptanceCriteria.first?.checked, true, "read again, the tick lands")
    }

    // MARK: - what agents read back

    func testAListIsCappedAndSaysSo() throws {
        for i in 1...(TrackerService.listCap + 2) { try create("Task \(i)") }
        guard let text = call("task_list", [:]) else { return XCTFail("no list") }
        XCTAssertTrue(text.contains("Showing \(TrackerService.listCap) of \(TrackerService.listCap + 2)"), text)
        guard let all = call("task_list", ["limit": .int(100)]) else { return XCTFail("no list") }
        XCTAssertFalse(all.contains("Showing"), "asked for more, nothing cut")
    }

    func testAWriteAnswersBriefly() throws {
        let id = try create("Brief") { $0.description = String(repeating: "Long context. ", count: 40) }
        guard let text = call("task_edit", ["id": .string(id), "notesAppend": .array([.string("x")])])
        else { return XCTFail("no answer") }
        XCTAssertTrue(text.hasPrefix("Updated task \(id)."))
        XCTAssertTrue(text.contains("Revision: "))
        XCTAssertFalse(text.contains("Long context."), "the description is not echoed back")
    }

    func testAnInProgressLineSaysWhoAndSince() throws {
        let id = try create("Started") { $0.assignee = ["@claude"] }
        try edit(id) { $0.status = .inProgress }
        let line = TrackerFormat.line(try service.view(id: id, folder: acme).summary)
        XCTAssertTrue(line.contains("(@claude, since "), line)
        XCTAssertFalse(line.contains("waiting on"))
    }

    // MARK: - names and projects

    func testOneNameIndexForTheBoardAndTheProjectsList() throws {
        let ctx = ModelContext(main)
        let older = ProjectAlias(canonicalName: "Acme")
        older.createdAt = Date(timeIntervalSince1970: 1_000)
        older.addAlias("Shared Name")
        let newer = ProjectAlias(canonicalName: "Beta")
        newer.createdAt = Date(timeIntervalSince1970: 2_000)
        newer.addAlias("Shared Name")
        ctx.insert(older)
        ctx.insert(newer)
        let c = Conversation(source: "meeting")
        c.primaryProject = "Shared Name"
        ctx.insert(c)
        let t = TaskItem(taskDescription: "Send it", sourceApp: "meeting")
        t.conversationId = c.id
        ctx.insert(t)
        try ctx.save()
        XCTAssertEqual(service.boardCards(filter: .all, archived: false).first?.projectName, "Acme")
        let listed = Dictionary(uniqueKeysWithValues: aggregator.listProjects(includeSingletons: true)
            .map { ($0.canonicalName, $0.conversationCount) })
        XCTAssertEqual(listed["Acme"], 1, "the conversation counts where its task shows")
        XCTAssertEqual(listed["Beta"], 0)
    }

    func testARenameOntoAnotherProjectsNameIsRefused() throws {
        _ = try service.createProject(name: "Acme")
        _ = try service.createProject(name: "Beta")
        XCTAssertFalse(aggregator.renameCanonical(currentCanonical: "Beta", newName: "acme"))
        XCTAssertTrue(aggregator.renameCanonical(currentCanonical: "Beta", newName: "Gamma"))
    }

    func testEveryProjectIsListedSoTheMenuAndTheListAgree() throws {
        let ctx = ModelContext(main)
        ctx.insert(ProjectAlias(canonicalName: "Quiet"))
        try ctx.save()
        XCTAssertEqual(aggregator.listProjects(includeSingletons: true).map(\.canonicalName), ["Quiet"])
        XCTAssertEqual(service.projectChoices().map(\.name), ["Quiet"])
    }

    func testAProjectPageKeepsItsProjectWhenTheProjectGoes() throws {
        let id = try service.createProject(name: "Acme")
        let previous = TrackerService.shared
        TrackerService.shared = service
        defer { TrackerService.shared = previous }
        let model = TasksWindowModel(filter: .project(id))
        model.reload()
        XCTAssertFalse(model.projectGone)
        _ = aggregator.deleteProject(canonicalName: "Acme")
        model.reload()
        XCTAssertTrue(model.projectGone)
        XCTAssertEqual(model.filter, .project(id), "never switches to every task")
        XCTAssertTrue(model.cards.isEmpty)
    }

    // MARK: - due dates

    func testDueDatesReadAsDatesAndAFinishedTaskIsNeverLate() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let lastWeek = now.addingTimeInterval(-7 * 86_400)
        XCTAssertNotEqual(TaskDue.label(lastWeek, isDay: false, now: now, calendar: cal), "Overdue")
        XCTAssertEqual(TaskDue.tone(lastWeek, isDay: false, done: false, now: now, calendar: cal), .late)
        XCTAssertEqual(TaskDue.tone(lastWeek, isDay: false, done: true, now: now, calendar: cal), .plain)
        XCTAssertEqual(TaskDue.label(now.addingTimeInterval(86_400), isDay: true, now: now, calendar: cal), "Tomorrow")
    }

    func testDatedTasksComeFirstEarliestFirst() {
        func card(_ title: String, due: Date?, created: Double) -> TaskBoard.Card {
            TaskBoard.Card(id: UUID(), title: title, key: nil, projectId: nil, projectName: nil, status: .toDo,
                           archived: false, priority: nil, labels: [], criteriaDone: 0, criteriaCount: 0, dueAt: due,
                           dueIsDay: false, createdAt: Date(timeIntervalSince1970: created), ordinal: nil, source: nil)
        }
        let cards = [card("Undated new", due: nil, created: 3), card("Late", due: Date(timeIntervalSince1970: 10), created: 1),
                     card("Later", due: Date(timeIntervalSince1970: 20), created: 2)]
        XCTAssertEqual(cards.sorted(by: TaskBoard.precedes).map(\.title), ["Late", "Later", "Undated new"])
    }
}
