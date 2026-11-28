import SwiftData
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// FEAT-0006 §5.4 — the automatic project passes leave the projects agents and the user made real alone (I6).
@MainActor
final class ProjectAggregatorTrackedTests: XCTestCase {

    private var dir: URL!
    private var main: ModelContainer!
    private var tracker: ModelContainer!
    private var aggregator: ProjectAggregator!
    private var service: TrackerService!
    private var acme: String { dir.appendingPathComponent("Code/Acme").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-agg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        let cfg = ModelConfiguration(schema: schema, url: dir.appendingPathComponent("Main.store"))
        main = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self, configurations: [cfg])
        tracker = try TrackerStore.makeContainer(url: dir.appendingPathComponent("Tracker.store"))
        aggregator = ProjectAggregator()
        aggregator.configure(modelContainer: main, trackerContainer: tracker)
        service = TrackerService(main: main, tracker: tracker, mutations: MutationService(runHooks: { _ in }),
                                 home: dir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func aliases() throws -> [ProjectAlias] { try ModelContext(main).fetch(FetchDescriptor<ProjectAlias>()) }

    private func addConversation(project: String) throws {
        let ctx = ModelContext(main)
        let c = Conversation(source: "meeting")
        c.status = "completed"
        c.finishedAt = Date()
        c.primaryProject = project
        ctx.insert(c)
        try ctx.save()
    }

    func testAnAgentsProjectWithoutConversationsIsNotPruned() throws {
        _ = try service.create(TaskCreateInput(title: "First"), folder: acme, client: "Codex")
        let ctx = ModelContext(main)
        ctx.insert(ProjectAlias(canonicalName: "Leftover"))
        try ctx.save()
        XCTAssertEqual(aggregator.pruneOrphanAliases(), 1, "the automatic leftover goes")
        XCTAssertEqual(try aliases().map(\.canonicalName), ["Acme"])
    }

    func testATrackedProjectSurvivesAMergeWithABiggerAutomaticOne() async throws {
        _ = try service.create(TaskCreateInput(title: "First"), folder: dir.appendingPathComponent("Code/chatapp").path,
                               client: "Claude Code")
        let ctx = ModelContext(main)
        let auto = ProjectAlias(canonicalName: "ChatApp")
        auto.addAlias("CHATAPP")
        auto.addAlias("ChatApp.")
        ctx.insert(auto)
        try ctx.save()
        await aggregator.mergeAliases()
        let left = try aliases()
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.canonicalName, "chatapp", "the tracked row and its name survive")
        XCTAssertTrue(left.first?.aliases.contains("ChatApp.") == true, "it took the other's aliases")
        let listed = try service.list(TaskListInput(), folder: dir.appendingPathComponent("Code/chatapp").path)
        XCTAssertEqual(listed.tasks.map(\.id), ["TASK-1"], "its tasks keep their project")
    }

    func testTwoTrackedProjectsAreNeverMerged() async throws {
        _ = try service.create(TaskCreateInput(title: "a"), folder: dir.appendingPathComponent("Code/chatapp").path,
                               client: nil)
        _ = try service.create(TaskCreateInput(title: "b"), folder: dir.appendingPathComponent("Other/ChatApp.").path,
                               client: nil)
        XCTAssertEqual(try aliases().count, 1, "the second folder matched the first project by name")
        let ctx = ModelContext(main)
        ctx.insert(ProjectAlias(canonicalName: "CHATAPP"))
        try ctx.save()
        let tctx = ModelContext(tracker)
        let extra = try XCTUnwrap(try aliases().first { $0.canonicalName == "CHATAPP" })
        tctx.insert(TrackedProject(projectId: extra.id, origin: .user, folders: []))
        try tctx.save()
        await aggregator.mergeAliases()
        XCTAssertEqual(try aliases().count, 2)
    }

    func testATrackedProjectIsNotRenamedToItsMostUsedVariant() throws {
        _ = try service.create(TaskCreateInput(title: "a"), folder: acme, client: nil)
        let ctx = ModelContext(main)
        let row = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ProjectAlias>()).first)
        row.addAlias("Acme Corp")
        try ctx.save()
        try addConversation(project: "Acme Corp")
        try addConversation(project: "Acme Corp")
        XCTAssertEqual(aggregator.recanonicalizeAll(), 0)
        XCTAssertEqual(try aliases().first?.canonicalName, "Acme")
    }

    func testTrackedProjectsAreListedWithTheirTasks() throws {
        _ = try service.create(TaskCreateInput(title: "a"), folder: acme, client: nil)
        var done = TaskCreateInput(title: "b")
        done.status = .done
        _ = try service.create(done, folder: acme, client: nil)
        let listed = aggregator.listProjects()
        let acmeRow = try XCTUnwrap(listed.first { $0.canonicalName == "Acme" }, "no conversations, still listed")
        XCTAssertEqual(acmeRow.pendingTaskCount, 1)
        XCTAssertEqual(acmeRow.completedTaskCount, 1)
        XCTAssertEqual(aggregator.details(for: "Acme").tasks.count, 2)
    }

    func testDeletingAProjectKeepsItsTasksWithoutAProject() throws {
        _ = try service.create(TaskCreateInput(title: "Keep me"), folder: acme, client: nil)
        aggregator.deleteProject(canonicalName: "Acme", ledgerURL: dir.appendingPathComponent("ledger.json"))
        XCTAssertTrue(try aliases().isEmpty)
        XCTAssertTrue(try ModelContext(tracker).fetch(FetchDescriptor<TrackedProject>()).isEmpty)
        let record = try XCTUnwrap(try ModelContext(tracker).fetch(FetchDescriptor<TaskTrackerRecord>()).first)
        XCTAssertNil(record.projectId)
        XCTAssertNil(record.key)
        XCTAssertEqual(try ModelContext(main).fetch(FetchDescriptor<TaskItem>()).map(\.taskDescription), ["Keep me"])
    }
}
