import SwiftData
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// FEAT-0006 §9b P7 (owner, 2026-11-26: such tasks are not wanted) — the open "waiting on <person>" tasks a user has
/// go to Archive once, at the first launch of the build that stops making them; suggestions of that kind are dropped.
@MainActor
final class WaitingOnCleanupTests: XCTestCase {

    private var dir: URL!
    private var main: ModelContainer!
    private var service: TrackerService!
    private var defaults: UserDefaults!
    private let suite = "waiting-on-cleanup-tests"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("waiting-on-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        main = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self,
                                  configurations: [ModelConfiguration(schema: schema, url: dir.appendingPathComponent("M.store"))])
        let tracker = try TrackerStore.makeContainer(url: dir.appendingPathComponent("T.store"))
        service = TrackerService(main: main, tracker: tracker, mutations: MutationService(runHooks: { _ in }),
                                 home: dir.path)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        StoreHealthSignal.shared.set(healthy: true)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func task(_ title: String, assignee: String?, status: String = "committed", done: Bool = false) throws -> UUID {
        let ctx = ModelContext(main)
        let t = TaskItem(taskDescription: title, sourceApp: "meeting", status: status, assignee: assignee)
        t.completed = done
        ctx.insert(t)
        try ctx.save()
        return t.id
    }

    private func onBoard() -> Set<String> { Set(service.boardCards(filter: .all, archived: false).map(\.title)) }
    private func archived() -> Set<String> { Set(service.boardCards(filter: .all, archived: true).map(\.title)) }

    func testOpenWaitingOnTasksGoToArchiveAndNothingElseMoves() throws {
        try task("Send the revised budget", assignee: "Maya")
        try task("Call the bank", assignee: nil)
        try task("Share the deck", assignee: "Sam", done: true)
        try task("Wait for the contract", assignee: "  ")
        XCTAssertEqual(try WaitingOnCleanup.runOnce(service: service, defaults: defaults), 1)
        XCTAssertEqual(archived(), ["Send the revised budget"], "restorable from Archive")
        XCTAssertEqual(onBoard(), ["Call the bank", "Share the deck", "Wait for the contract"])
    }

    func testAWaitingOnSuggestionIsDropped() throws {
        try task("Send the slides", assignee: "Al", status: "staged")
        try task("Book a room", assignee: nil, status: "staged")
        try WaitingOnCleanup.runOnce(service: service, defaults: defaults)
        let visible = TaskDrafts.visible(try ModelContext(main).fetch(FetchDescriptor<TaskItem>())).map(\.taskDescription)
        XCTAssertEqual(visible, ["Book a room"])
    }

    /// C27 — once: a task the user restores afterwards stays where they put it.
    func testItRunsOnceAndARestoredTaskStaysRestored() throws {
        let id = try task("Send the revised budget", assignee: "Maya")
        XCTAssertEqual(try WaitingOnCleanup.runOnce(service: service, defaults: defaults), 1)
        try service.restore(taskId: id)
        XCTAssertEqual(try WaitingOnCleanup.runOnce(service: service, defaults: defaults), 0)
        XCTAssertEqual(onBoard(), ["Send the revised budget"])
    }

    /// A store refusing writes: not marked done, so the next launch tries again ...
    func testAStoreThatRefusesWritesIsTriedAgainAtTheNextLaunch() throws {
        try task("Send the revised budget", assignee: "Maya")
        StoreHealthSignal.shared.set(healthy: false)
        XCTAssertThrowsError(try WaitingOnCleanup.runOnce(service: service, defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: WaitingOnCleanup.doneKey))
        StoreHealthSignal.shared.set(healthy: true)
        XCTAssertEqual(try WaitingOnCleanup.runOnce(service: service, defaults: defaults), 1)
    }

    /// ... but not forever: after the third refused launch it gives up (every gate needs a ceiling).
    func testItGivesUpAfterThreeRefusedLaunches() throws {
        try task("Send the revised budget", assignee: "Maya")
        StoreHealthSignal.shared.set(healthy: false)
        for _ in 0..<WaitingOnCleanup.maxAttempts {
            XCTAssertThrowsError(try WaitingOnCleanup.runOnce(service: service, defaults: defaults))
        }
        XCTAssertTrue(defaults.bool(forKey: WaitingOnCleanup.doneKey))
        StoreHealthSignal.shared.set(healthy: true)
        XCTAssertEqual(try WaitingOnCleanup.runOnce(service: service, defaults: defaults), 0, "not tried a fourth time")
    }
}
