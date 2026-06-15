import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-049 A2 (review fix) — in a degraded session `MutationService.commit` must
/// short-circuit at the owner layer: no save, and crucially NO post-commit hooks
/// (Obsidian re-export, MCP snapshot), since those write external files from the
/// empty in-memory store. Reachable in degraded via the voice-question hotkey,
/// which bypasses the main-window recovery overlay.
@MainActor
final class MutationServiceDegradedTests: XCTestCase {

    override func tearDown() {
        StoreHealthSignal.shared.set(healthy: true)   // restore process-wide global
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([TaskItem.self])
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    func testCommitShortCircuitsInDegraded() throws {
        var saved = false
        var hooksRan = false
        let svc = MutationService(save: { _ in saved = true }, runHooks: { _ in hooksRan = true })
        let ctx = try makeContext()

        StoreHealthSignal.shared.set(healthy: false)
        XCTAssertThrowsError(try svc.commit(.taskSaved(UUID()), in: ctx)) { error in
            XCTAssertTrue(error is MutationError, "should throw MutationError.storeDegraded")
        }
        XCTAssertFalse(saved, "degraded must not save to the volatile store")
        XCTAssertFalse(hooksRan, "degraded must not fire external hooks (Obsidian / MCP snapshot)")
    }

    func testCommitProceedsWhenHealthy() throws {
        var saved = false
        var hooksRan = false
        let svc = MutationService(save: { _ in saved = true }, runHooks: { _ in hooksRan = true })
        let ctx = try makeContext()

        StoreHealthSignal.shared.set(healthy: true)
        XCTAssertNoThrow(try svc.commit(.taskSaved(UUID()), in: ctx))
        XCTAssertTrue(saved, "healthy path must save")
        XCTAssertTrue(hooksRan, "healthy path must run hooks")
    }
}
