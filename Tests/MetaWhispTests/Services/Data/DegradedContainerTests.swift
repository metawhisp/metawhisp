import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-049 A2 — pins the degraded-fallback container choice.
///
/// REJECTED approach: `ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: false)`.
/// An in-memory store backed by /dev/null cannot LOAD read-only — CoreData returns
/// NSCocoaError 257 and ModelContainer init throws `loadIssueModelContainer`. In
/// HistoryService that throw hits the `fatalError`, i.e. it would CRASH the app
/// instead of dropping into the recovery shell. (Verified 2026-06-14.)
///
/// CHOSEN approach: a WRITABLE in-memory container (constructs fine). Degraded
/// writes are kept harmless WITHOUT a read-only container: A2b stops background
/// jobs (no empty-store external overwrites), the blocking overlay covers the
/// foreground, and HistoryService's own mutators short-circuit on `health`.
final class DegradedContainerTests: XCTestCase {

    private var schema: Schema {
        Schema([
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ])
    }

    func testWritableInMemoryFallbackConstructs() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        XCTAssertNoThrow(try ModelContainer(for: schema, configurations: [config]))
    }

    func testReadOnlyInMemoryConfigCannotLoad() {
        // Documents WHY allowsSave:false is not used for the degraded shell.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, allowsSave: false)
        XCTAssertThrowsError(try ModelContainer(for: schema, configurations: [config]))
    }
}
