import SwiftData
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// FEAT-0006 §3 — the tracker's own store file, beside the main store.
final class TrackerStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRecordsAndProjectsSurviveReopeningTheFile() throws {
        let url = dir.appendingPathComponent("Tracker.store")
        let taskId = UUID(), projectId = UUID()
        do {
            let container = try TrackerStore.makeContainer(url: url)
            let ctx = ModelContext(container)
            var body = TrackerTaskBody()
            body.description = "Why it matters"
            body.priority = "high"
            body.acceptanceCriteria = [ChecklistItem(text: "Works", checked: true)]
            body.dependencies = [UUID()]
            let record = TaskTrackerRecord(taskId: taskId, projectId: projectId, key: "3", body: body)
            record.startedAt = Date(timeIntervalSince1970: 1_000)
            ctx.insert(record)
            let project = TrackedProject(projectId: projectId, origin: .agent, folders: ["/a/Acme"])
            ctx.insert(project)
            try ctx.save()
        }
        let container = try TrackerStore.makeContainer(url: url)
        let ctx = ModelContext(container)
        let record = try XCTUnwrap(try ctx.fetch(FetchDescriptor<TaskTrackerRecord>()).first)
        XCTAssertEqual(record.taskId, taskId)
        XCTAssertEqual(record.key, "3")
        XCTAssertEqual(record.startedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(record.body.description, "Why it matters")
        XCTAssertEqual(record.body.acceptanceCriteria, [ChecklistItem(text: "Works", checked: true)])
        let project = try XCTUnwrap(try ctx.fetch(FetchDescriptor<TrackedProject>()).first)
        XCTAssertEqual(project.folders, ["/a/Acme"])
        XCTAssertEqual(project.originKind, .agent)
    }

    func testABodyFromANewerBuildWithUnknownFieldsStillReads() throws {
        let record = TaskTrackerRecord(taskId: UUID(), projectId: nil, key: nil, body: TrackerTaskBody())
        record.bodyJSON = #"{"description":"x","milestone":"m-1","futureField":[1,2]}"#
        XCTAssertEqual(record.body.description, "x")
        record.bodyJSON = "not json"
        XCTAssertEqual(record.body, TrackerTaskBody(), "a broken body reads as empty, never crashes")
    }

    /// The main store keeps its shape: no new main schema version (FEAT-0006 §3 — a new version would block
    /// test builds and rollbacks).
    func testTheMainStoreSchemaIsUnchanged() {
        XCTAssertEqual(MetaWhispMigrationPlan.schemas.count, 10)
        let names = Set(Schema(versionedSchema: MetaWhispSchemaV10.self).entities.map(\.name))
        XCTAssertFalse(names.contains("TaskTrackerRecord"))
        XCTAssertFalse(names.contains("TrackedProject"))
    }
}
