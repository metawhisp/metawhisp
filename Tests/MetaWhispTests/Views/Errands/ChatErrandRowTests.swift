import Combine
import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 8b, 8.9 and 8.10 — MetaChat's part of an errand: an errand typed there shows, under the message
/// that asked, its card's own lines and buttons while it runs — from the same card, so the first answer counts, here
/// or in the corner — and never saved into a message, so no model reads it. Its result quotes the user's own words,
/// this session only. The empty MetaChat offers an errand to try only while one can start.
@MainActor
final class ChatErrandRowTests: XCTestCase {

    private static let said = "find 10 jokes online"
    private static let errandCall = ChatService.NativeChatResponse(
        text: "", toolCall: .init(id: "a", tool: "runErrand", args: ["goal": said]), finishReason: "tool_calls")

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    /// MetaChat on `h`'s errand service: its model starts the errand the user asked for, then says it started.
    private func metaChat(_ h: AgentServiceHarness, _ service: AgentService, store: ModelContainer)
        -> (ChatService, ChatToolExecutor) {
        let executor = ChatToolExecutor()
        executor.configure(modelContainer: store)
        executor.canRunErrands = { service.canRunErrands }
        executor.startErrand = { goal, origin, output, _ in service.start(goal: goal, origin: origin, output: output) }
        let chat = ChatService()
        chat.configure(modelContainer: store)
        chat.toolExecutor = executor
        chat.hasLLMAccess = { true }
        chat.proLicenseKey = { "LICENSE-1" }
        chat.observeErrands(service.events)
        var replies: [ChatService.NativeChatResponse] = []
        chat.chatWithTools = { _, _, _, _ in
            if replies.isEmpty {
                replies = [ChatService.NativeChatResponse(text: "Started.", toolCall: nil, finishReason: "stop")]
                return Self.errandCall
            }
            return replies.removeFirst()
        }
        return (chat, executor)
    }

    private func messages(_ store: ModelContainer) throws -> [ChatMessage] {
        try ModelContext(store).fetch(FetchDescriptor<ChatMessage>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    /// A typed errand: MetaChat finds it under the message that asked, shows its card's lines and buttons while it
    /// runs — and saves none of them; a voice errand has its card in the corner only.
    func testATypedErrandShowsItsCardUnderItsMessageAndNothingOfItIsSaved() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let stack = ErrandCardStack(schedule: { _, _ in })
        stack.observe(service.events, service: service, openSheet: { _ in }, openResult: { _ in })
        let store = try container()
        let (chat, executor) = metaChat(h, service, store: store)
        let outcome = await chat.send(Self.said)
        XCTAssertEqual(outcome, .errandStarted)
        let asked = try XCTUnwrap(messages(store).first { $0.sender == "human" })
        await h.until({ !h.updates.isEmpty }, "the errand's first event")
        let errand = try XCTUnwrap(h.updates.first?.id)
        XCTAssertEqual(chat.errands(askedBy: asked.id), [errand])
        await h.until(errand, shows: .connecting(.connected(browser: "Google Chrome")))
        let card = try XCTUnwrap(stack.cards.first { $0.id == errand })
        XCTAssertEqual(ErrandLiveRow.lines(of: card), ["PLANNING", "Chrome · background tab", "Planning the errand"])
        XCTAssertEqual(card.buttons.map(\.label), ["Stop", "Stop all"])
        let saved = try messages(store).map(\.text)
        XCTAssertEqual(saved, [Self.said], "neither the card nor the model's acknowledgement is saved")

        _ = await chat.send("and 5 more", source: .voice(question: UUID()))
        XCTAssertEqual(chat.errands(askedBy: asked.id), [errand], "a voice errand is not under a typed message")
        withExtendedLifetime(executor) {}
    }

    /// Yes in MetaChat and on the card: the first counts, the second does nothing — so does a No after a Yes.
    func testYesInMetaChatAndOnTheCardTheFirstCounts() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let stack = ErrandCardStack(schedule: { _, _ in })
        stack.observe(service.events, service: service, openSheet: { _ in }, openResult: { _ in })
        let id = try XCTUnwrap(service.start(goal: Self.said, origin: .chat(messageID: UUID())).id)
        let found = await h.runner(for: id)
        let run = try XCTUnwrap(found)
        let address = "https://shop.test/cart"
        let request = ConfirmationRequest(action: AgentAction(operation: .open, target: nil, destination: address,
                                                              payload: nil, isPlannedSearch: false),
                                          tab: BrowserTab(windowID: "1", tabID: "7"), pageURL: address, askedAt: .now)
        let question = run.ask(request)
        await h.until(id, shows: .needsYes(request))
        stack.press(.yes, on: id)      // MetaChat's row
        stack.press(.no, on: id)       // the corner card, a moment later
        await h.until({ question.isAnswered }, "the answer")
        XCTAssertEqual(question.answer, .yes, "the first counts")
        XCTAssertFalse(service.answer(id, to: request, .no), "a second answer to the same question does nothing")
    }

    /// The result quotes what the user said — typed or spoken — this session only: the messages keep their own
    /// texts, a relaunched MetaChat and a cleared one quote nothing.
    func testTheResultQuotesTheUsersOwnWordsThisSessionOnly() async throws {
        for source in [ChatService.Source.typed, .voice(question: UUID())] {
            let h = AgentServiceHarness()
            defer { h.cleanUp() }
            h.link.connect()
            let service = h.makeService()
            let store = try container()
            let (chat, executor) = metaChat(h, service, store: store)
            _ = await chat.send(Self.said, source: source)
            await h.until({ !h.updates.isEmpty }, "the errand's first event")
        let errand = try XCTUnwrap(h.updates.first?.id)
            let outcome = ErrandOutcome(ending: .done, answer: "Ten jokes.", sources: [], sheet: nil, rows: 0)
            await h.runner(for: errand)?.finish(outcome)
            await h.until({ chat.resultMessage(of: errand) != nil }, "the result in MetaChat")
            let result = try XCTUnwrap(chat.resultMessage(of: errand))
            XCTAssertEqual(chat.request(ofResult: result), Self.said, "\(source)")
            let saved = try messages(store)
            XCTAssertEqual(saved.first { $0.id == result }?.text, ChatService.errandResultText(outcome),
                           "the result keeps its own text")
            XCTAssertEqual(saved.filter { $0.sender == "human" }.map(\.text), [Self.said])
            XCTAssertNil(chat.request(ofResult: try XCTUnwrap(saved.first { $0.sender == "human" }).id),
                         "only a result quotes")

            let relaunched = ChatService()
            relaunched.configure(modelContainer: store)
            XCTAssertNil(relaunched.request(ofResult: result), "none after a relaunch")
            chat.clearErrandRecords = {}
            chat.clearHistory()
            XCTAssertNil(chat.request(ofResult: result), "none after a clear")
            XCTAssertEqual(chat.errands(askedBy: UUID()), [])
            withExtendedLifetime(executor) {}
        }
    }

    /// The empty MetaChat offers "Find 10 jokes online" under "Try:" only while an errand can start.
    func testTheExampleShowsOnlyWhileAnErrandCanStart() {
        let lines = ["• What did I do today?", "• What are my active tasks?", "• What do I know about <project>?"]
        XCTAssertEqual(ChatView.tryLines(errandCanStart: false), lines)
        XCTAssertEqual(ChatView.tryLines(errandCanStart: true), lines + ["• Find 10 jokes online"])
    }
}
