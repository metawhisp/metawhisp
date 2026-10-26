import Combine
import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-076 I-11 — an errand card's [Open in MetaChat] brings MetaChat to the
/// errand's own result message: MetaChat finds it by the errand.
@MainActor
final class ErrandResultMessageTests: XCTestCase {

    private func container() throws -> ModelContainer {
        let schema = Schema([
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    func testTheResultOfAnErrandIsFoundByItsErrand() throws {
        let store = try container()
        let chat = ChatService()
        chat.configure(modelContainer: store)
        let updates = PassthroughSubject<ErrandUpdate, Never>()
        chat.observeErrands(updates.eraseToAnyPublisher())
        let (first, second) = (UUID(), UUID())
        for id in [first, second] {
            updates.send(ErrandUpdate(id: id, origin: .chat(messageID: UUID()), event: .finished(ErrandOutcome(
                ending: .done, answer: nil, sources: [], sheet: nil, rows: id == first ? 1 : 2))))
        }
        let messages = try ModelContext(store).fetch(FetchDescriptor<ChatMessage>())
        let firstMessage = messages.first { $0.text == "Done: 1 rows." }
        let secondMessage = messages.first { $0.text == "Done: 2 rows." }
        XCTAssertNotNil(firstMessage)
        XCTAssertEqual(chat.resultMessage(of: first), firstMessage?.id)
        XCTAssertEqual(chat.resultMessage(of: second), secondMessage?.id)
        XCTAssertNil(chat.resultMessage(of: UUID()), "an errand with no result in MetaChat has no message")
    }
}
