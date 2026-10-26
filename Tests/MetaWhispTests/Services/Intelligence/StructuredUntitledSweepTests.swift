import XCTest
import SwiftData
@testable import MetaWhisp

/// ITER-075 step 1 (1.5) — the completed conversations with no title (522 on
/// 2026-09-26: 149 meetings and 373 dictations) are queued for their summary,
/// newest first, once.
@MainActor
final class StructuredUntitledSweepTests: XCTestCase {

    private var folder: URL!
    private var defaults: UserDefaults!
    private let suite = "mw-untitled-sweep-tests"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-untitled-sweep-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: plainFolderURL)
    }

    /// The folder's path as a plain URL: one that also names a file there.
    private var plainFolderURL: URL { URL(fileURLWithPath: folder.path) }

    private func conversation(_ source: String, title: String?, status: String = "completed",
                              discarded: Bool = false, startedAt: Date = Date()) -> Conversation {
        let conv = Conversation(source: source, startedAt: startedAt)
        conv.status = status
        conv.title = title
        conv.discarded = discarded
        return conv
    }

    private func store(_ rows: [Conversation]) throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(for: Schema([HistoryItem.self, Conversation.self]),
                                           configurations: [ModelConfiguration("Test", isStoredInMemoryOnly: true)])
        let ctx = ModelContext(container)
        rows.forEach { ctx.insert($0) }
        try ctx.save()
        return (container, ctx)
    }

    private func generator(_ container: ModelContainer, healthy: Bool = true) -> StructuredGenerator {
        let generator = StructuredGenerator(queueDirectory: folder, isStoreHealthy: { healthy })
        generator.configure(modelContainer: container)
        return generator
    }

    func testUntitledCompletedConversationsAreQueuedOnce() throws {
        let meeting = conversation("meeting", title: nil)
        let dictation = conversation("dictation", title: nil)
        let (container, ctx) = try store([meeting, dictation,
                                          conversation("meeting", title: "Weekly sync"),
                                          conversation("meeting", title: nil, status: "inProgress"),
                                          conversation("meeting", title: nil, discarded: true)])
        let first = generator(container)
        first.enqueueUntitledOnce(defaults: defaults)
        XCTAssertEqual(Set(first.queue.pending), [meeting.id, dictation.id],
                       "completed, kept and untitled: meetings and dictations alike")

        ctx.insert(conversation("meeting", title: nil))
        try ctx.save()
        let later = generator(container)
        later.enqueueUntitledOnce(defaults: defaults)
        XCTAssertEqual(Set(later.queue.pending), [meeting.id, dictation.id], "once: a second sweep adds nothing")
    }

    func testTheNewestConversationsAreQueuedFirst() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let oldest = conversation("meeting", title: nil, startedAt: start)
        let newest = conversation("dictation", title: nil, startedAt: start.addingTimeInterval(7200))
        let middle = conversation("meeting", title: nil, startedAt: start.addingTimeInterval(3600))
        let (container, _) = try store([oldest, newest, middle])
        let sweeper = generator(container)
        sweeper.enqueueUntitledOnce(defaults: defaults)
        XCTAssertEqual(sweeper.queue.pending, [newest.id, middle.id, oldest.id])
    }

    /// A degraded store reads as empty: the sweep waits for a healthy one
    /// instead of using itself up on nothing.
    func testADegradedStoreDoesNotUseUpTheSweep() throws {
        let meeting = conversation("meeting", title: nil)
        let (container, _) = try store([meeting])
        let degraded = generator(container, healthy: false)
        degraded.enqueueUntitledOnce(defaults: defaults)
        XCTAssertEqual(degraded.queue.pending, [])
        let healthy = generator(container)
        healthy.enqueueUntitledOnce(defaults: defaults)
        XCTAssertEqual(healthy.queue.pending, [meeting.id], "the next healthy launch runs the sweep")
    }

    /// A queue that could not be saved does not use up the sweep either: the
    /// next launch sweeps again.
    func testAQueueThatCouldNotBeSavedDoesNotUseUpTheSweep() throws {
        let meeting = conversation("meeting", title: nil)
        let (container, _) = try store([meeting])
        try Data().write(to: plainFolderURL)   // a plain file where the queue's folder should be
        generator(container).enqueueUntitledOnce(defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: StructuredGenerator.untitledSweepKey))
        try FileManager.default.removeItem(at: plainFolderURL)
        let later = generator(container)
        later.enqueueUntitledOnce(defaults: defaults)
        XCTAssertEqual(later.queue.pending, [meeting.id], "the next launch sweeps")
        XCTAssertTrue(defaults.bool(forKey: StructuredGenerator.untitledSweepKey))
    }
}
