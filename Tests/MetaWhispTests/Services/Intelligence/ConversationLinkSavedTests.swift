import XCTest
import SwiftData
@testable import MetaWhisp

/// ITER-075 step 1 (1.5) — the link from a history item to its conversation is
/// saved where it is written. The item lives in its caller's context, and a
/// fresh context — an extractor's, a moment after the close — read no link
/// until that context saved on its own: a meeting's memories and tasks could
/// be lost.
@MainActor
final class ConversationLinkSavedTests: XCTestCase {

    func testTheLinkIsSavedWhereItIsWritten() throws {
        let container = try ModelContainer(for: Schema([HistoryItem.self, Conversation.self]),
                                           configurations: [ModelConfiguration("Test", isStoredInMemoryOnly: true)])
        let callersContext = ModelContext(container)
        let item = HistoryItem(text: "Send the draft by Friday", language: "en", audioDuration: 3, processingTime: 1)
        callersContext.insert(item)
        try callersContext.save()
        item.source = "dictation"   // set after the save, as the callers do

        let grouper = ConversationGrouper()
        grouper.configure(modelContainer: container)
        let conversation = try XCTUnwrap(grouper.assign(historyItem: item))

        let freshContext = ModelContext(container)
        let stored = try freshContext.fetch(FetchDescriptor<HistoryItem>()).first { $0.id == item.id }
        XCTAssertEqual(stored?.conversationId, conversation.id, "a fresh context must read the link")
        XCTAssertEqual(stored?.source, "dictation", "and what the caller set before it")
    }
}
