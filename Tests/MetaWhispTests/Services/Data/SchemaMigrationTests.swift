import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-049 B — proves the V1 VersionedSchema + migrationPlan is a NO-OP for an
/// existing store: a store written by the OLD bare `Schema([...models])` reopens
/// under V1 with its data intact (no migration wipe, ids/counts preserved). If V1
/// diverged from the current model shape, SwiftData would attempt a migration with
/// no stage and this test would throw or lose rows.
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

    /// The exact bare schema the live store was created with before ITER-049 B.
    private var bareSchema: Schema {
        Schema([
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ])
    }

    func testStoreWrittenWithBareSchemaOpensUnderV1WithDataIntact() throws {
        // 1. Write a store the OLD way (bare schema, no migration plan) + seed rows.
        var savedIds: [UUID] = []
        do {
            let cfg = ModelConfiguration(schema: bareSchema, url: storeURL)
            let container = try ModelContainer(for: bareSchema, configurations: [cfg])
            let ctx = ModelContext(container)
            let d1 = PatternDigest(weekStartDate: Date(timeIntervalSince1970: 0), windowDays: 7, conversationsAnalyzed: 3)
            let d2 = PatternDigest(weekStartDate: Date(timeIntervalSince1970: 700_000), windowDays: 7, conversationsAnalyzed: 5)
            ctx.insert(d1); ctx.insert(d2)
            try ctx.save()
            savedIds = [d1.id, d2.id].sorted { $0.uuidString < $1.uuidString }
        }

        // 2. Reopen the SAME file under V1 + migrationPlan.
        let v1Schema = Schema(versionedSchema: MetaWhispSchemaV1.self)
        let cfg2 = ModelConfiguration(schema: v1Schema, url: storeURL)
        let container2 = try ModelContainer(
            for: v1Schema, migrationPlan: MetaWhispMigrationPlan.self, configurations: [cfg2])
        let ctx2 = ModelContext(container2)
        let digests = try ctx2.fetch(FetchDescriptor<PatternDigest>())

        // 3. Rows intact — no migration wipe.
        XCTAssertEqual(digests.count, 2, "rows written by the bare schema must survive opening under V1")
        XCTAssertEqual(digests.map(\.id).sorted { $0.uuidString < $1.uuidString }, savedIds)
        XCTAssertEqual(Set(digests.map(\.conversationsAnalyzed)), [3, 5])
    }

    func testFreshStoreCreatesUnderV1() throws {
        let v1Schema = Schema(versionedSchema: MetaWhispSchemaV1.self)
        let cfg = ModelConfiguration(schema: v1Schema, url: storeURL)
        XCTAssertNoThrow(try ModelContainer(
            for: v1Schema, migrationPlan: MetaWhispMigrationPlan.self, configurations: [cfg]))
    }

    /// Proof against the REAL store. Skipped unless `MW_REAL_STORE_COPY` points at a
    /// COPY of `~/Library/Application Support/MetaWhisp.store` (+ its WAL sidecars,
    /// copied together). Run manually before shipping:
    ///   MW_REAL_STORE_COPY=/tmp/mw-store-verify/MetaWhisp.store swift test \
    ///     --filter SchemaMigrationTests/testRealStoreCopyOpensUnderV1
    func testRealStoreCopyOpensUnderV1() throws {
        guard let path = ProcessInfo.processInfo.environment["MW_REAL_STORE_COPY"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set MW_REAL_STORE_COPY to a copy of the real store to run this proof")
        }
        let url = URL(fileURLWithPath: path)
        let v1Schema = Schema(versionedSchema: MetaWhispSchemaV1.self)
        let cfg = ModelConfiguration(schema: v1Schema, url: url)
        let container = try ModelContainer(
            for: v1Schema, migrationPlan: MetaWhispMigrationPlan.self, configurations: [cfg])
        let ctx = ModelContext(container)
        let memories = try ctx.fetch(FetchDescriptor<UserMemory>()).count
        let tasks = try ctx.fetch(FetchDescriptor<TaskItem>()).count
        let convos = try ctx.fetch(FetchDescriptor<Conversation>()).count
        let history = try ctx.fetch(FetchDescriptor<HistoryItem>()).count
        print("[RealStoreVerify] memories=\(memories) tasks=\(tasks) conversations=\(convos) history=\(history)")
        XCTAssertGreaterThan(memories + tasks + convos + history, 0,
                             "real store must open under V1 with its data intact (no migration)")
    }
}
