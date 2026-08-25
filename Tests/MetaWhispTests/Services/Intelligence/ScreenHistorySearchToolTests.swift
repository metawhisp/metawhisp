import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-053.4 (первый срез) — chat-tool `searchScreenHistory`: «спроси, что
/// я делал и что мне писали». Searches BOTH the distilled activity timeline
/// (ScreenObservation) and the raw screen text (ScreenContext OCR — messages
/// the user read, pages, code) within a day window.
@MainActor
final class ScreenHistorySearchToolTests: XCTestCase {

    /// ITER-069 — the tool now refuses to read stored OCR when the master
    /// toggle is off, so these behavioral tests must run with it on, the way a
    /// user who has screen history at all has it.
    private var priorToggle = false

    override func setUp() async throws {
        try await super.setUp()
        priorToggle = await MainActor.run { AppSettings.shared.screenContextEnabled }
        await MainActor.run { AppSettings.shared.screenContextEnabled = true }
    }

    override func tearDown() async throws {
        let restore = priorToggle
        await MainActor.run { AppSettings.shared.screenContextEnabled = restore }
        try await super.tearDown()
    }

    func test_search_masterOffBlocksStoredOCR() async throws {
        await MainActor.run { AppSettings.shared.screenContextEnabled = false }
        let (executor, _) = try await MainActor.run { try makeExecutor() }
        let result = await executor.executeReadOnly(
            .init(id: nil, tool: "searchScreenHistory", args: ["query": "anything"]))
        XCTAssertFalse(result.ok,
                       "off must mean the stored text too, not just future captures")
        XCTAssertTrue(result.summary.contains("turned off"))
    }


    private func makeExecutor() throws -> (ChatToolExecutor, ModelContext) {
        let schema = Schema([
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ])
        let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [cfg])
        let executor = ChatToolExecutor()
        executor.configure(modelContainer: container)
        return (executor, ModelContext(container))
    }

    private func insertRaw(_ ctx: ModelContext, app: String, title: String, ocr: String, ageDays: Double = 0.5) {
        let row = ScreenContext(appName: app, windowTitle: title, ocrText: ocr)
        row.timestamp = Date(timeIntervalSinceNow: -ageDays * 86_400)
        ctx.insert(row)
    }

    private func insertObservation(_ ctx: ModelContext, app: String, summary: String, activity: String, ageDays: Double = 0.5) {
        let end = Date(timeIntervalSinceNow: -ageDays * 86_400)
        ctx.insert(ScreenObservation(
            screenContextId: nil, appName: app, windowTitle: nil,
            contextSummary: summary, currentActivity: activity, hasTask: false,
            startedAt: end.addingTimeInterval(-300), endedAt: end))
    }

    /// Registered end-to-end: advertised in schemas, marked read-only, executed.
    func test_tool_isAdvertisedAndReadOnly() {
        XCTAssertTrue(ChatToolExecutor.readOnlyTools.contains("searchScreenHistory"))
        let names = ChatToolExecutor.toolSchemas.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertTrue(names.contains("searchScreenHistory"))
    }

    /// «Что мне писал <человек>» — the answer lives in raw OCR of a messenger.
    func test_search_findsMessageInRawOCR() async throws {
        let (executor, ctx) = try makeExecutor()
        insertRaw(ctx, app: "Telegram", title: "Alex",
                  ocr: "Alex: пришли пожалуйста договор по ProjectAlpha до пятницы")
        insertRaw(ctx, app: "Safari", title: "News", ocr: "weather is sunny today")
        try ctx.save()

        let call = ChatToolExecutor.ToolCall(id: nil, tool: "searchScreenHistory",
                                             args: ["query": "договор ProjectAlpha"])
        let result = await executor.executeReadOnly(call)

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.summary.contains("Telegram"), "must surface the messenger hit: \(result.summary)")
        XCTAssertTrue(result.summary.contains("договор"), "snippet must contain the matched text")
        XCTAssertFalse(result.summary.contains("sunny"), "unrelated rows must not match")
    }

    /// «Что я делал по <теме>» — the answer lives in the distilled timeline.
    func test_search_findsActivityInObservations() async throws {
        let (executor, ctx) = try makeExecutor()
        insertObservation(ctx, app: "Xcode",
                          summary: "User debugging the payment webhook retries",
                          activity: "Fixing webhook bug")
        insertObservation(ctx, app: "Spotify", summary: "Listening to music", activity: "Music")
        try ctx.save()

        let call = ChatToolExecutor.ToolCall(id: nil, tool: "searchScreenHistory",
                                             args: ["query": "webhook"])
        let result = await executor.executeReadOnly(call)

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.summary.contains("Xcode"))
        XCTAssertFalse(result.summary.contains("Spotify"))
    }

    /// The day window is honoured — old rows don't pollute «this week» answers.
    func test_search_respectsDayWindow() async throws {
        let (executor, ctx) = try makeExecutor()
        insertRaw(ctx, app: "Mail", title: "Inbox", ocr: "invoice from vendor", ageDays: 40)
        try ctx.save()

        let recent = await executor.executeReadOnly(.init(id: nil, tool: "searchScreenHistory",
                                                          args: ["query": "invoice", "days": "7"]))
        XCTAssertTrue(recent.ok)
        XCTAssertTrue(recent.summary.contains("\"count\":0") || recent.summary.contains("\"count\": 0"),
                      "40-day-old row must not match a 7-day window: \(recent.summary)")

        let wide = await executor.executeReadOnly(.init(id: nil, tool: "searchScreenHistory",
                                                        args: ["query": "invoice", "days": "60"]))
        XCTAssertTrue(wide.summary.contains("Mail"), "60-day window must find it: \(wide.summary)")
    }

    /// Own-app windows are a feedback loop (our chat answers re-captured as
    /// «facts on screen») — they never surface in results, in EITHER layer
    /// (review fix: the filter used to cover raw OCR only, not activities).
    func test_search_dropsOwnAppWindows() async throws {
        let (executor, ctx) = try makeExecutor()
        let ownApp = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "MetaWhisp"
        insertRaw(ctx, app: ownApp, title: "Chat", ocr: "договор по ProjectAlpha обсуждение")
        insertObservation(ctx, app: ownApp,
                          summary: "User reading ProjectAlpha договор answer in chat",
                          activity: "Chatting")
        try ctx.save()

        let result = await executor.executeReadOnly(.init(id: nil, tool: "searchScreenHistory",
                                                          args: ["query": "договор ProjectAlpha"]))
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.summary.contains("\"count\":0") || result.summary.contains("\"count\": 0"),
                      "own-app OCR must be filtered: \(result.summary)")
    }

    /// The local text-loop must be able to PARSE the new tool tag — the tool
    /// exists on both transports (regression: search tools were Pro-only once).
    func test_localTextLoop_parsesScreenHistoryTag() {
        let text = #"<searchScreenHistory>{"query": "webhook", "days": 7}</searchScreenHistory>"#
        let call = ChatToolExecutor.parseToolCall(from: text)
        XCTAssertNotNil(call)
        XCTAssertEqual(call?.tool, "searchScreenHistory")
        XCTAssertEqual(call?.args["query"], "webhook")
        XCTAssertEqual(call?.args["days"], "7")
    }

    /// And the display sanitizer strips the raw tag so XML never reaches the UI.
    func test_stripToolCallXML_removesScreenHistoryTag() {
        let text = #"Смотрю. <searchScreenHistory>{"query": "webhook"}</searchScreenHistory>"#
        XCTAssertEqual(ChatService.stripToolCallXML(text), "Смотрю.")
    }
}
