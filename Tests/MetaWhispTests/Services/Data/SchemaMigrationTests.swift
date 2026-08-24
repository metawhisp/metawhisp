import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-049 B + ITER-053.4 + ITER-057.2 — schema versioning proofs.
///
/// History: V1 anchored the original 14-model shape. ITER-053.4 added
/// `ScreenObservation.embedding` (V2, froze the pre-embedding observation).
/// ITER-057.2 added `TaskItem.relevanceScore` (V3, froze the pre-score task
/// shape under the V2 namespace). These tests prove an existing user's store
/// survives every stage with data intact.
final class SchemaMigrationTests: XCTestCase {

    private var dir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("schemamig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("MetaWhisp.store")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// THE ship-gate: a store written under V1 (pre-embedding observation,
    /// pre-score task) reopens under the LATEST schema + migration plan with
    /// every row intact and the new columns nil — no wipe, no degraded fallback.
    func testV1StoreMigratesToLatestWithDataIntact() throws {
        var digestIds: [UUID] = []
        // 1. Write a store the OLD way: V1 schema (frozen shapes).
        do {
            let v1Schema = Schema(versionedSchema: MetaWhispSchemaV1.self)
            let cfg = ModelConfiguration(schema: v1Schema, url: storeURL)
            let container = try ModelContainer(for: v1Schema, configurations: [cfg])
            let ctx = ModelContext(container)
            let d1 = PatternDigest(weekStartDate: Date(timeIntervalSince1970: 0), windowDays: 7, conversationsAnalyzed: 3)
            let d2 = PatternDigest(weekStartDate: Date(timeIntervalSince1970: 700_000), windowDays: 7, conversationsAnalyzed: 5)
            ctx.insert(d1); ctx.insert(d2)
            let obs = MetaWhispSchemaV1.ScreenObservation(
                screenContextId: nil, appName: "Safari", windowTitle: "Docs",
                contextSummary: "Reading docs", currentActivity: "Research",
                hasTask: false, startedAt: Date(timeIntervalSince1970: 100),
                endedAt: Date(timeIntervalSince1970: 400))
            ctx.insert(obs)
            let task = MetaWhispSchemaV2.TaskItem(
                taskDescription: "Send Alex the onboarding deck", status: "staged")
            ctx.insert(task)
            try ctx.save()
            digestIds = [d1.id, d2.id].sorted { $0.uuidString < $1.uuidString }
        }

        // 2. Reopen the SAME file under the latest schema + the migration plan.
        let latestSchema = Schema(versionedSchema: MetaWhispSchemaV4.self)
        let cfg2 = ModelConfiguration(schema: latestSchema, url: storeURL)
        let container2 = try ModelContainer(
            for: latestSchema, migrationPlan: MetaWhispMigrationPlan.self, configurations: [cfg2])
        let ctx2 = ModelContext(container2)

        // 3. Rows intact; migrated rows carry nil in the added columns.
        let digests = try ctx2.fetch(FetchDescriptor<PatternDigest>())
        XCTAssertEqual(digests.count, 2, "V1 rows must survive the migration")
        XCTAssertEqual(digests.map(\.id).sorted { $0.uuidString < $1.uuidString }, digestIds)

        let observations = try ctx2.fetch(FetchDescriptor<ScreenObservation>())
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.appName, "Safari")
        XCTAssertNil(observations.first?.embedding, "new column starts nil after lightweight migration")

        let tasks = try ctx2.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.taskDescription, "Send Alex the onboarding deck")
        XCTAssertEqual(tasks.first?.status, "staged")
        XCTAssertNil(tasks.first?.relevanceScore, "new column starts nil after lightweight migration")
    }

    /// ITER-057.2 — the incremental stage on its own: a V2-era store (embedding
    /// present, no relevanceScore) opens under V3 with tasks intact.
    func testV2StoreMigratesToV3WithTasksIntact() throws {
        do {
            let v2Schema = Schema(versionedSchema: MetaWhispSchemaV2.self)
            let cfg = ModelConfiguration(schema: v2Schema, url: storeURL)
            let container = try ModelContainer(for: v2Schema, configurations: [cfg])
            let ctx = ModelContext(container)
            let task = MetaWhispSchemaV2.TaskItem(
                taskDescription: "Reply to Sam about the contract draft", status: "committed")
            ctx.insert(task)
            try ctx.save()
        }

        let latestSchema = Schema(versionedSchema: MetaWhispSchemaV4.self)
        let cfg = ModelConfiguration(schema: latestSchema, url: storeURL)
        let container = try ModelContainer(
            for: latestSchema, migrationPlan: MetaWhispMigrationPlan.self, configurations: [cfg])
        let ctx = ModelContext(container)
        let tasks = try ctx.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.taskDescription, "Reply to Sam about the contract draft")
        XCTAssertNil(tasks.first?.relevanceScore)
    }

    func testFreshStoreCreatesUnderV3() throws {
        let latestSchema = Schema(versionedSchema: MetaWhispSchemaV4.self)
        let cfg = ModelConfiguration(schema: latestSchema, url: storeURL)
        XCTAssertNoThrow(try ModelContainer(
            for: latestSchema, migrationPlan: MetaWhispMigrationPlan.self, configurations: [cfg]))
    }

    /// The frozen V1 observation shape must stay frozen: this pins its fields
    /// so an accidental edit (which would corrupt the migration source) fails.
    func testFrozenV1ObservationShapeIsStable() throws {
        let v1Schema = Schema(versionedSchema: MetaWhispSchemaV1.self)
        let entity = v1Schema.entities.first { $0.name == "ScreenObservation" }
        XCTAssertNotNil(entity)
        let props = Set(entity!.properties.map(\.name))
        XCTAssertFalse(props.contains("embedding"), "V1 is the PRE-embedding shape — never add fields to the frozen copy")
        for expected in ["id", "appName", "contextSummary", "currentActivity", "startedAt", "endedAt", "createdAt"] {
            XCTAssertTrue(props.contains(expected), "frozen V1 lost field \(expected)")
        }
    }

    /// Same for the frozen pre-relevanceScore TaskItem shape referenced by V1+V2.
    func testFrozenV2TaskItemShapeIsStable() throws {
        let v2Schema = Schema(versionedSchema: MetaWhispSchemaV2.self)
        let entity = v2Schema.entities.first { $0.name == "TaskItem" }
        XCTAssertNotNil(entity)
        let props = Set(entity!.properties.map(\.name))
        XCTAssertFalse(props.contains("relevanceScore"), "V2 is the PRE-score shape — never add fields to the frozen copy")
        for expected in ["id", "taskDescription", "completed", "status", "embedding", "assignee", "createdAt"] {
            XCTAssertTrue(props.contains(expected), "frozen V2 lost field \(expected)")
        }
    }

    /// Proof against the REAL store. Skipped unless `MW_REAL_STORE_COPY` points at a
    /// COPY of `~/Library/Application Support/MetaWhisp.store` (+ its WAL sidecars,
    /// copied together). Run manually before shipping:
    ///   MW_REAL_STORE_COPY=/tmp/mw-store-verify/MetaWhisp.store swift test \
    ///     --filter SchemaMigrationTests/testRealStoreCopyOpensUnderLatest
    func testRealStoreCopyOpensUnderLatest() throws {
        guard let path = ProcessInfo.processInfo.environment["MW_REAL_STORE_COPY"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set MW_REAL_STORE_COPY to a copy of the real store to run this proof")
        }
        let url = URL(fileURLWithPath: path)
        let latestSchema = Schema(versionedSchema: MetaWhispSchemaV4.self)
        let cfg = ModelConfiguration(schema: latestSchema, url: url)
        let container = try ModelContainer(
            for: latestSchema, migrationPlan: MetaWhispMigrationPlan.self, configurations: [cfg])
        let ctx = ModelContext(container)
        let memories = try ctx.fetch(FetchDescriptor<UserMemory>()).count
        let tasks = try ctx.fetch(FetchDescriptor<TaskItem>()).count
        let convos = try ctx.fetch(FetchDescriptor<Conversation>()).count
        let history = try ctx.fetch(FetchDescriptor<HistoryItem>()).count
        let observations = try ctx.fetch(FetchDescriptor<ScreenObservation>()).count
        print("[RealStoreVerify] memories=\(memories) tasks=\(tasks) conversations=\(convos) history=\(history) observations=\(observations)")
        XCTAssertGreaterThan(memories + tasks + convos + history, 0,
                             "real store must open under the latest schema with its data intact (lightweight migration)")
    }
}

extension SchemaMigrationTests {

    /// ITER-067 — the store on a real user's disk is V3. It has their
    /// dictations, meetings, tasks and memories in it, and this is the change
    /// that asks it to become V4. A lightweight stage adding one entity should
    /// be safe; "should be" is not a thing to find out from a bug report.
    func test_v3StoreOpensAsV4WithEverythingIntact() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-v3-to-v4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("store.sqlite")

        // A V3 store with the user's real kinds of data in it.
        do {
            let v3 = Schema(versionedSchema: MetaWhispSchemaV3.self)
            let container = try ModelContainer(
                for: v3, configurations: [ModelConfiguration(schema: v3, url: storeURL)])
            let ctx = ModelContext(container)
            ctx.insert(TaskItem(taskDescription: "Send the deck", status: "staged"))
            ctx.insert(UserMemory(content: "Prefers async updates", category: "system",
                                  sourceApp: "Slack", confidence: 0.9))
            ctx.insert(ScreenContext(appName: "Slack", windowTitle: "#launch", ocrText: "hello"))
            try ctx.save()
        }

        // Reopen it the way the shipped app will.
        let latest = Schema(versionedSchema: MetaWhispSchemaV4.self)
        let container = try ModelContainer(
            for: latest, migrationPlan: MetaWhispMigrationPlan.self,
            configurations: [ModelConfiguration(schema: latest, url: storeURL)])
        let ctx = ModelContext(container)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<TaskItem>()).count, 1,
                       "a V3 store must keep its tasks")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<UserMemory>()).count, 1,
                       "a V3 store must keep its memories")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ScreenContext>()).count, 1,
                       "a V3 store must keep its screen history")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ScreenAgentItem>()).count, 0,
                       "the new entity starts empty rather than inventing rows")

        // And the new entity is usable straight away, not merely declared.
        let item = ScreenAgentItem(
            runID: UUID(), headline: "Anna is waiting for the deck",
            body: "", sourceApp: "Slack", sourceWindowTitle: "#launch", capturedAt: Date())
        ctx.insert(item)
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ScreenAgentItem>()).count, 1)
    }
}
