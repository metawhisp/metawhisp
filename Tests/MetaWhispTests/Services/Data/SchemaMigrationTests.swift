import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-049 B + ITER-053.4 — schema versioning proofs.
///
/// History: V1 anchored the original 14-model shape. ITER-053.4 added
/// `ScreenObservation.embedding` — the FIRST real change — so V1 froze the
/// pre-embedding ScreenObservation shape, the live class became V2, and the
/// plan gained a lightweight V1→V2 stage. These tests prove an existing user's
/// store survives that migration with data intact.
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

    /// THE ship-gate: a store written under V1 (pre-embedding ScreenObservation)
    /// reopens under V2 + migration plan with every row intact and the new
    /// column nil — no wipe, no degraded fallback.
    func testV1StoreMigratesToV2WithDataIntact() throws {
        var digestIds: [UUID] = []
        // 1. Write a store the OLD way: V1 schema (frozen observation shape).
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
            try ctx.save()
            digestIds = [d1.id, d2.id].sorted { $0.uuidString < $1.uuidString }
        }

        // 2. Reopen the SAME file under V2 + the migration plan.
        let v2Schema = Schema(versionedSchema: MetaWhispSchemaV2.self)
        let cfg2 = ModelConfiguration(schema: v2Schema, url: storeURL)
        let container2 = try ModelContainer(
            for: v2Schema, migrationPlan: MetaWhispMigrationPlan.self, configurations: [cfg2])
        let ctx2 = ModelContext(container2)

        // 3. Rows intact; migrated observation carries a nil embedding.
        let digests = try ctx2.fetch(FetchDescriptor<PatternDigest>())
        XCTAssertEqual(digests.count, 2, "V1 rows must survive the V2 migration")
        XCTAssertEqual(digests.map(\.id).sorted { $0.uuidString < $1.uuidString }, digestIds)

        let observations = try ctx2.fetch(FetchDescriptor<ScreenObservation>())
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.appName, "Safari")
        XCTAssertEqual(observations.first?.contextSummary, "Reading docs")
        XCTAssertNil(observations.first?.embedding, "new column starts nil after lightweight migration")
    }

    func testFreshStoreCreatesUnderV2() throws {
        let v2Schema = Schema(versionedSchema: MetaWhispSchemaV2.self)
        let cfg = ModelConfiguration(schema: v2Schema, url: storeURL)
        XCTAssertNoThrow(try ModelContainer(
            for: v2Schema, migrationPlan: MetaWhispMigrationPlan.self, configurations: [cfg]))
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

    /// Proof against the REAL store. Skipped unless `MW_REAL_STORE_COPY` points at a
    /// COPY of `~/Library/Application Support/MetaWhisp.store` (+ its WAL sidecars,
    /// copied together). Run manually before shipping:
    ///   MW_REAL_STORE_COPY=/tmp/mw-store-verify/MetaWhisp.store swift test \
    ///     --filter SchemaMigrationTests/testRealStoreCopyOpensUnderV2
    func testRealStoreCopyOpensUnderV2() throws {
        guard let path = ProcessInfo.processInfo.environment["MW_REAL_STORE_COPY"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set MW_REAL_STORE_COPY to a copy of the real store to run this proof")
        }
        let url = URL(fileURLWithPath: path)
        let v2Schema = Schema(versionedSchema: MetaWhispSchemaV2.self)
        let cfg = ModelConfiguration(schema: v2Schema, url: url)
        let container = try ModelContainer(
            for: v2Schema, migrationPlan: MetaWhispMigrationPlan.self, configurations: [cfg])
        let ctx = ModelContext(container)
        let memories = try ctx.fetch(FetchDescriptor<UserMemory>()).count
        let tasks = try ctx.fetch(FetchDescriptor<TaskItem>()).count
        let convos = try ctx.fetch(FetchDescriptor<Conversation>()).count
        let history = try ctx.fetch(FetchDescriptor<HistoryItem>()).count
        let observations = try ctx.fetch(FetchDescriptor<ScreenObservation>()).count
        print("[RealStoreVerify] memories=\(memories) tasks=\(tasks) conversations=\(convos) history=\(history) observations=\(observations)")
        XCTAssertGreaterThan(memories + tasks + convos + history, 0,
                             "real store must open under V2 with its data intact (lightweight migration)")
    }
}
