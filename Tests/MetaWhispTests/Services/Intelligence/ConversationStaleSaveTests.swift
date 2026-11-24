import SwiftData
import XCTest
@testable import MetaWhisp

/// 2026-11-24, on the owner's Mac with 1.4.6: 65 meetings an earlier version left "in progress" were rewritten
/// every ten minutes for hours — 1,533 model calls in 4.5 h, one meeting 25 times — and none was ever completed.
/// The store showed why: the settling sweep marked a meeting completed, and a second later the conversation's
/// embedding was saved from the generator's context, which still held the meeting as it was before — in progress,
/// no end — and wrote it back.
///
/// On the store the app really uses (SQLite on disk), not an in-memory one.
@MainActor
final class ConversationStaleSaveTests: XCTestCase {

    private var dir: URL!
    private var container: ModelContainer!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("stale-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        let config = ModelConfiguration(schema: schema, url: dir.appendingPathComponent("test.store"))
        container = try ModelContainer(for: schema, configurations: [config])
    }

    override func tearDownWithError() throws {
        container = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func stored(_ id: UUID) throws -> Conversation {
        var desc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        desc.fetchLimit = 1
        return try XCTUnwrap(ModelContext(container).fetch(desc).first)
    }

    /// A meeting left in progress, with one part.
    private func stuckMeeting() throws -> UUID {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let meeting = Conversation(source: "meeting", startedAt: start)
        meeting.updatedAt = start.addingTimeInterval(900)
        let part = HistoryItem(text: "the part", language: "en", audioDuration: 60, processingTime: 1)
        part.createdAt = start.addingTimeInterval(900)
        part.conversationId = meeting.id
        let ctx = ModelContext(container)
        ctx.insert(meeting)
        ctx.insert(part)
        try ctx.save()
        return meeting.id
    }

    /// The order on the owner's Mac: the rewrite saves the summary, the sweep completes the meeting, then the
    /// embedding of the rewritten summary lands.
    func testAnEmbeddingThatLandsAfterTheMeetingWasCompletedLeavesItCompleted() async throws {
        let id = try stuckMeeting()
        let grouper = ConversationGrouper()
        grouper.configure(modelContainer: container)

        // The rewrite, in the generator's own context.
        let generator = ModelContext(container)
        var desc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        desc.fetchLimit = 1
        let rewritten = try XCTUnwrap(generator.fetch(desc).first)
        rewritten.title = "Rewritten title"
        rewritten.updatedAt = Date()
        try generator.save()

        grouper.rewriteEnded(id, result: .done)
        XCTAssertEqual(try stored(id).status, "completed")

        // The embedding of that summary, a second later.
        EmbeddingService.saveEmbedding([0.25, 0.5], ofConversation: id, in: container)

        let after = try stored(id)
        XCTAssertEqual(after.status, "completed", "the embedding must not reopen a completed meeting")
        XCTAssertNotNil(after.finishedAt, "nor erase its end")
        XCTAssertEqual(after.title, "Rewritten title")
        XCTAssertNotNil(after.embedding, "the embedding itself is kept")
    }

    /// A conversation removed before its embedding came back: nothing is written, nothing breaks.
    func testAnEmbeddingForAConversationThatIsGoneWritesNothing() throws {
        EmbeddingService.saveEmbedding([0.25], ofConversation: UUID(), in: container)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Conversation>()).isEmpty)
    }

    /// Every embedding — new tasks and memories, the launch backfill — is written through one door. A task ticked
    /// done while its embedding was on the way stays done.
    func testATaskTickedDoneWhileItsEmbeddingWasOnTheWayStaysDone() throws {
        let extractor = ModelContext(container)
        let task = TaskItem(taskDescription: "Send the contract")
        extractor.insert(task)
        try extractor.save()
        let rowId = task.persistentModelID

        let user = ModelContext(container)
        let ticked = try XCTUnwrap(user.fetch(FetchDescriptor<TaskItem>()).first)
        ticked.completed = true
        ticked.completedAt = Date()
        try user.save()

        let written = EmbeddingService.saveEmbeddings([(rowId, [0.5, 0.25])], in: container) { (row: TaskItem, data) in
            row.embedding = data
        }

        XCTAssertEqual(written, 1)
        let after = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        XCTAssertTrue(after.completed, "the embedding must not undo the tick")
        XCTAssertNotNil(after.completedAt)
        XCTAssertNotNil(after.embedding)
    }

    /// A row deleted while its embedding was on the way gets none, and the others in the batch still do.
    func testARowDeletedWhileItsEmbeddingWasOnTheWayIsSkipped() throws {
        let ctx = ModelContext(container)
        let kept = TaskItem(taskDescription: "kept")
        let gone = TaskItem(taskDescription: "gone")
        ctx.insert(kept)
        ctx.insert(gone)
        try ctx.save()
        let ids = [kept.persistentModelID, gone.persistentModelID]
        let other = ModelContext(container)
        try other.delete(model: TaskItem.self, where: #Predicate { $0.taskDescription == "gone" })
        try other.save()

        let written = EmbeddingService.saveEmbeddings([(ids[0], [0.5]), (ids[1], [0.25])], in: container) {
            (row: TaskItem, data) in row.embedding = data
        }

        XCTAssertEqual(written, 1)
        let rows = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.map(\.taskDescription), ["kept"])
        XCTAssertNotNil(rows.first?.embedding)
    }
}

/// The launch pass that retries placeholder summaries ("Quick note", "(empty)") takes only completed conversations:
/// a meeting still settling, or left in progress, is the settling sweep's — the pass rewrote such a meeting a second
/// time and, saving its copy after the wait, reopened it (review of the 2026-11-24 fix).
@MainActor
final class PlaceholderBackfillSelectionTests: XCTestCase {

    func testOnlyCompletedConversationsNotYetTriedAreTaken() throws {
        let container = try ModelContainer(for: Schema(versionedSchema: MetaWhispSchemaV10.self),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        func conversation(_ status: String, title: String = "Quick note", tried: Bool = false,
                          discarded: Bool = false) -> UUID {
            let conv = Conversation(source: "meeting", startedAt: Date())
            conv.status = status
            conv.title = title
            conv.structuredBackfillAttempted = tried
            conv.discarded = discarded
            ctx.insert(conv)
            return conv.id
        }
        let due = conversation("completed")
        let emptyOverview = conversation("completed", title: "Real title")
        _ = conversation("inProgress")
        _ = conversation("settling")
        _ = conversation("processing")
        _ = conversation("completed", tried: true)
        _ = conversation("completed", discarded: true)
        _ = conversation("completed", title: "Real title")
        try ctx.save()
        let withEmpty = try XCTUnwrap(ctx.fetch(FetchDescriptor<Conversation>()).first { $0.id == emptyOverview })
        withEmpty.overview = "(empty)"
        try ctx.save()

        XCTAssertEqual(Set(StructuredGenerator.placeholderCandidates(in: ModelContext(container))), [due, emptyOverview])
    }
}
