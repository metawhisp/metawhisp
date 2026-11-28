import SwiftData
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// FEAT-0006, independent review 2026-11-26 — each finding reproduced first, then fixed.
@MainActor
final class TrackerReviewFixTests: XCTestCase {

    private var dir: URL!
    private var main: ModelContainer!
    private var tracker: ModelContainer!
    private var service: TrackerService!
    private var acme: String { dir.appendingPathComponent("Code/Acme").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-fix-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
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

    // MARK: - P1-1: an index an agent sends can never crash the app

    func testHugeOrInfiniteIndexesAreRefusedNotTrapped() {
        for bad: JSONValue in [.string("inf"), .array([.double(1e19)]), .string("1e300"), .array([.double(.infinity)])] {
            XCTAssertThrowsError(try TrackerArgs.edit(["id": .string("TASK-1"), "acceptanceCriteriaCheck": bad])) {
                XCTAssertEqual(($0 as? TrackerFailure)?.code, .validation)
            }
        }
    }

    // MARK: - P1-3: a criterion ticked from an open sheet after an agent changed the list

    func testTickingACriterionThatIsGoneOrMovedIsRefused() throws {
        var input = TaskCreateInput(title: "Login")
        input.acceptanceCriteria = ["Works", "Tested"]
        _ = try service.create(input, folder: acme, client: nil)
        let id = try XCTUnwrap(service.boardCards(filter: .all, archived: false).first?.id)
        var clear = TaskEditInput(id: "TASK-1")
        clear.acceptanceCriteriaSet = []
        _ = try service.edit(clear, folder: acme, client: nil)
        XCTAssertThrowsError(try service.toggleCriterion(taskId: id, index: 1, expectedText: "Works"), "no trap on an empty list")
        var reset = TaskEditInput(id: "TASK-1")
        reset.acceptanceCriteriaSet = ["Tested", "Works"]
        _ = try service.edit(reset, folder: acme, client: nil)
        XCTAssertThrowsError(try service.toggleCriterion(taskId: id, index: 1, expectedText: "Works"),
                             "the sheet's #1 is now another criterion")
        XCTAssertEqual(try service.view(id: "TASK-1", folder: acme).acceptanceCriteria.map(\.checked), [false, false])
        try service.toggleCriterion(taskId: id, index: 2, expectedText: "Works")
        XCTAssertEqual(try service.view(id: "TASK-1", folder: acme).acceptanceCriteria.map(\.checked), [false, true])
    }

    // MARK: - P2-5: without its tracker store the project passes fail closed

    func testWithoutTheTrackerStoreNoProjectIsPrunedOrMerged() async throws {
        _ = try service.create(TaskCreateInput(title: "a"), folder: acme, client: nil)
        let ctx = ModelContext(main)
        ctx.insert(ProjectAlias(canonicalName: "ACME"))
        try ctx.save()
        let blind = ProjectAggregator()
        blind.configure(modelContainer: main, trackerContainer: nil, trackerRequired: true)
        XCTAssertEqual(blind.pruneOrphanAliases(), 0)
        await blind.mergeAliases()
        XCTAssertEqual(blind.recanonicalizeAll(), 0)
        XCTAssertEqual(try ModelContext(main).fetch(FetchDescriptor<ProjectAlias>()).count, 2, "nothing deleted")
    }

    // MARK: - P2-7: moving a task to another project leaves no link across projects

    func testMovingATaskToAnotherProjectCutsItsLinks() throws {
        _ = try service.create(TaskCreateInput(title: "Base"), folder: acme, client: nil)
        _ = try service.create(TaskCreateInput(title: "Mover") { $0.dependencies = ["TASK-1"] }, folder: acme, client: nil)
        _ = try service.create(TaskCreateInput(title: "Needs mover") { $0.dependencies = ["TASK-2"] }, folder: acme, client: nil)
        _ = try service.create(TaskCreateInput(title: "Child") { $0.parentTaskId = "TASK-2" }, folder: acme, client: nil)
        let other = try service.createProject(name: "Other")
        let mover = try XCTUnwrap(service.boardCards(filter: .all, archived: false).first { $0.title == "Mover" }?.id)
        try service.setProject(taskId: mover, projectId: other)
        var ready = TaskListInput()
        ready.ready = true
        XCTAssertTrue(try service.list(ready, folder: acme).tasks.map(\.title).contains("Needs mover"),
                      "its dependent is no longer blocked by a task it cannot see")
        XCTAssertEqual(try service.view(id: "TASK-3", folder: acme).summary.dependencies, [])
        XCTAssertNil(try service.view(id: "TASK-2.1", folder: acme).summary.parentTaskId, "the child stays, unparented")
        XCTAssertNotNil(try? service.view(id: "TASK-1", folder: acme))
        let moved = try XCTUnwrap(service.detail(taskId: mover)?.detail)
        XCTAssertTrue(moved.summary.dependencies.isEmpty)
    }

    // MARK: - P2-8: two repositories of one folder name are two projects

    func testTwoRepositoriesWithTheSameFolderNameKeepTheirOwnBacklogs() throws {
        let a = dir.appendingPathComponent("a/web"), b = dir.appendingPathComponent("b/web")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        _ = try service.create(TaskCreateInput(title: "A's task"), folder: a.path, client: nil)
        let second = try service.create(TaskCreateInput(title: "B's task"), folder: b.path, client: nil)
        XCTAssertEqual(second.summary.id, "TASK-1", "its own numbering")
        XCTAssertNotEqual(second.summary.project, "web", "told apart by name")
        XCTAssertEqual(try service.list(TaskListInput(), folder: a.path).tasks.map(\.title), ["A's task"])
        XCTAssertEqual(try service.list(TaskListInput(), folder: b.path).tasks.map(\.title), ["B's task"])
    }

    func testARepositoryThatMovedStillFindsItsProjectByName() throws {
        let old = dir.appendingPathComponent("old/web")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        _ = try service.create(TaskCreateInput(title: "Kept"), folder: old.path, client: nil)
        try FileManager.default.removeItem(at: old)
        let moved = dir.appendingPathComponent("new/web")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        XCTAssertEqual(try service.list(TaskListInput(), folder: moved.path).tasks.map(\.title), ["Kept"], "C4")
    }

    // MARK: - P3-10: an over-long criterion is refused, not dropped

    func testAnOverLongCriterionIsRefused() {
        XCTAssertThrowsError(try TrackerArgs.create(["title": .string("x"),
                                                     "acceptanceCriteria": .array([.string(String(repeating: "a", count: 501))])]))
    }

    // MARK: - P3-12: delete removes the links before the task

    func testDeleteLeavesNoDanglingLinkEvenFromTheWindow() throws {
        _ = try service.create(TaskCreateInput(title: "Go"), folder: acme, client: nil)
        _ = try service.create(TaskCreateInput(title: "Needs go") { $0.dependencies = ["TASK-1"] }, folder: acme, client: nil)
        let id = try XCTUnwrap(service.boardCards(filter: .all, archived: false).first { $0.title == "Go" }?.id)
        try service.archive(taskId: id)
        try service.deleteForever(taskId: id)
        XCTAssertEqual(try service.view(id: "TASK-2", folder: acme).summary.dependencies, [])
        XCTAssertNil(try ModelContext(tracker).fetch(FetchDescriptor<TaskTrackerRecord>())
            .first { $0.body.dependencies?.contains(id) == true })
    }

    // MARK: - Round 2, N4: every field of the body is known to the merge

    func testTheMergeKnowsEveryBodyField() throws {
        let fields = Mirror(reflecting: TrackerTaskBody()).children.compactMap(\.label)
        let data = try JSONEncoder().encode(TrackerTaskBody.allKeysFilled)
        let keys = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), Set(fields), "a new field must be named in allKeysFilled, or it is never saved")
    }

    // MARK: - Round 2, N3: an agent's due day is "Today" all day; a timed task still goes overdue

    func testADueDayIsMarkedAsADay() throws {
        _ = try service.create(TaskCreateInput(title: "Dated") { $0.dueDate = "2026-12-01" }, folder: acme, client: nil)
        let card = try XCTUnwrap(service.boardCards(filter: .all, archived: false).first)
        XCTAssertTrue(card.dueIsDay)
        var clear = TaskEditInput(id: "TASK-1")
        clear.dueDate = .clear
        _ = try service.edit(clear, folder: acme, client: nil)
        XCTAssertFalse(try XCTUnwrap(service.boardCards(filter: .all, archived: false).first).dueIsDay)
    }

    // MARK: - P3-13: a body field this build does not know survives its edit

    func testFieldsOfANewerBuildSurviveAnEdit() throws {
        let record = TaskTrackerRecord(taskId: UUID(), projectId: nil, key: nil, body: TrackerTaskBody())
        record.bodyJSON = #"{"description":"x","milestone":"m-1"}"#
        var body = record.body
        body.description = "y"
        body.priority = "high"
        record.body = body
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(record.bodyJSON.utf8)) as? [String: Any])
        XCTAssertEqual(object["milestone"] as? String, "m-1")
        XCTAssertEqual(object["description"] as? String, "y")
        XCTAssertEqual(object["priority"] as? String, "high")
        body.priority = nil
        record.body = body
        XCTAssertNil(record.body.priority, "a cleared known field is cleared")
    }
}

private extension TaskCreateInput {
    init(title: String, _ tweak: (inout TaskCreateInput) -> Void) {
        self.init(title: title)
        tweak(&self)
    }
}
