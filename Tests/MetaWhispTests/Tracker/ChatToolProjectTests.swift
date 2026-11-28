import SwiftData
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// FEAT-0006 §5.3 (D7) — MetaChat puts a task into one of the user's projects by its name; it never makes a
/// project up; it creates one only on the user's explicit word, asking first when a similar one exists.
@MainActor
final class ChatToolProjectTests: XCTestCase {

    private var dir: URL!
    private var main: ModelContainer!
    private var tracker: ModelContainer!
    private var service: TrackerService!
    private var executor: ChatToolExecutor!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        main = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self,
                                  configurations: [ModelConfiguration(schema: schema, url: dir.appendingPathComponent("M.store"))])
        tracker = try TrackerStore.makeContainer(url: dir.appendingPathComponent("T.store"))
        let mutations = MutationService(runHooks: { _ in })
        service = TrackerService(main: main, tracker: tracker, mutations: mutations, home: dir.path)
        executor = ChatToolExecutor()
        executor.configure(modelContainer: main)
        executor.mutationService = mutations
        let s = service!
        executor.tracker = { s }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func call(_ tool: String, _ args: [String: String]) -> ChatToolExecutor.ToolCall {
        ChatToolExecutor.ToolCall(id: nil, tool: tool, args: args)
    }

    func testATaskGoesIntoTheNamedProject() throws {
        let acme = try service.createProject(name: "Acme")
        guard case .success(let preview) = executor.validate(call("addTask", ["description": "Ship the page", "project": "acme"]))
        else { return XCTFail() }
        XCTAssertTrue(preview.contains("Acme"), preview)
        let r = executor.execute(call("addTask", ["description": "Ship the page", "project": "acme"]))
        XCTAssertTrue(r.ok, r.summary)
        XCTAssertTrue(r.summary.contains("Acme"), r.summary)
        let card = try XCTUnwrap(service.boardCards(filter: .project(acme), archived: false).first)
        XCTAssertEqual(card.title, "Ship the page")
        XCTAssertEqual(card.key, "TASK-1")
    }

    func testAnUnknownProjectNameIsNotMadeUp() throws {
        let r = executor.execute(call("addTask", ["description": "Call the bank", "project": "Nowhere Inc"]))
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.summary.contains("no project"), r.summary)
        XCTAssertTrue(try ModelContext(main).fetch(FetchDescriptor<ProjectAlias>()).isEmpty, "no project invented")
        XCTAssertEqual(service.boardCards(filter: .none, archived: false).map(\.title), ["Call the bank"])
    }

    func testCreatingAProjectOfAnExistingNameUsesIt() throws {
        let acme = try service.createProject(name: "Pixel Garden")
        guard case .success(let preview) = executor.validate(call("createProject", ["name": "pixel-garden"])) else {
            return XCTFail()
        }
        XCTAssertTrue(preview.contains("already"), preview)
        XCTAssertTrue(executor.execute(call("createProject", ["name": "pixel-garden"])).ok)
        XCTAssertEqual(try ModelContext(main).fetch(FetchDescriptor<ProjectAlias>()).map(\.id), [acme])
    }

    func testASimilarProjectMeansAskingFirst() throws {
        _ = try service.createProject(name: "NovaDesk")
        guard case .failure(let error) = executor.validate(call("createProject", ["name": "Nova Desking"])) else {
            return XCTFail("a similar name must be asked about")
        }
        XCTAssertTrue("\(error)".contains("NovaDesk"), "\(error)")
        let r = executor.execute(call("createProject", ["name": "Nova Desking", "newAnyway": "true"]))
        XCTAssertTrue(r.ok, r.summary)
        XCTAssertEqual(service.projectChoices().map(\.name).sorted(), ["Nova Desking", "NovaDesk"])
        XCTAssertEqual(try ModelContext(tracker).fetch(FetchDescriptor<TrackedProject>())
            .first { $0.projectId != service.projectChoices().first { $0.name == "NovaDesk" }?.id }?.originKind, .chat)
    }

    func testFindProjectReadsTheUsersProjects() async throws {
        _ = try service.createProject(name: "Acme")
        _ = try service.createProject(name: "Acme Billing")
        let r = await executor.executeReadOnly(call("findProject", ["name": "acme"]))
        XCTAssertTrue(r.ok)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.summary.utf8)) as? [String: Any])
        XCTAssertEqual(json["exact"] as? String, "Acme")
        XCTAssertEqual(json["similar"] as? [String], ["Acme Billing"])
    }

    func testSimilarityIsAboutTheSameNameNotAnyOverlap() {
        XCTAssertTrue(ProjectNaming.isSimilar("NovaDesk", "Nova Desking"))
        XCTAssertTrue(ProjectNaming.isSimilar("Brightloom", "Brightloom.io"))
        XCTAssertTrue(ProjectNaming.isSimilar("Acme", "Acmee"))
        XCTAssertFalse(ProjectNaming.isSimilar("Acme", "Acme"), "the same name is a match, not a similar one")
        XCTAssertFalse(ProjectNaming.isSimilar("Web", "Website Redesign"), "too short to count")
        XCTAssertFalse(ProjectNaming.isSimilar("Atomic Mail", "Overview"))
    }
}
