import Combine
import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-076 I-05 — one errand end to end, every seam real but the far ends:
/// MetaChat's result ← the errand service ← `AgentRun.factory` ← Jev through
/// `JevDecisionEngine` and `JevEngine`, over a recorded transport ← the
/// agent's hands in a headless Chrome on the fixture pages ← a fixture Sheet.
/// The planner and the writer are the test's. Skipped without Chrome.
@MainActor
final class ErrandEndToEndTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("mw-errand-e2e-\(UUID().uuidString)", isDirectory: true)
    private var watch: AnyCancellable?

    override func tearDown() {
        watch = nil
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private nonisolated static let sites = ["Site One", "Site Two", "Site Three"]

    /// Jev on the fixtures, answering what it is asked: on the results page,
    /// open the first site the errand has not opened yet; on a site, the goal
    /// is met there, and back. Every risk question: reversible, no grant.
    private nonisolated static func jev() -> RecordedJev {
        RecordedJev { asked, _ in
            guard asked.isStep else { return .answers() }
            guard URL(string: asked.pageURL)?.host == "search.test" else {
                return .answers(operation: "BACK", nouls: ["goal_done": 0.95])
            }
            let next = sites.first { !asked.recentLabels.contains($0) }
            return .answers(operation: "CLICK", target: next.flatMap(asked.key(labelled:)))
        }
    }

    func testAnErrandRunsFromMetaChatToChromeAndBack() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let jev = Self.jev()
        let plan = try XCTUnwrap(AgentPlan(
            goal: "Add three competitor sites to a sheet",
            subgoals: [.init(description: "Find a competitor's site", terms: ["voice", "notes"])],
            searches: [URL(string: "https://search.test/?q=voice+notes")!], columns: ["Name", "URL", "What they do"],
            sheetTitle: "Competitors", rowsWanted: 3, emptyCell: "n/a"))
        let service = AgentService(link: FixedLink(world.bridge), keepAwake: KeepAwake(create: { 1 }, release: { _ in }),
                                   store: ErrandRecordStore(directory: folder), notificationCenter: NotificationCenter(),
                                   isPro: { true },
                                   makeRunner: AgentRun.factory(planner: FixedPlanner(plan: plan), engine: jev.engine,
                                                                writer: FakeWriter(), sheet: { _ in FixtureSheet() }),
                                   schedule: { _, _ in }, settings: .allowedForTests)
        let store = try ModelContainer(for: Schema([
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let chat = ChatService()
        chat.configure(modelContainer: store)
        chat.observeErrands(service.events)
        var events: [ErrandEvent] = []
        watch = service.events.sink { events.append($0.event) }

        let admission = service.start(goal: "Add three competitor sites to a sheet", origin: .chat(messageID: UUID()))
        guard case .started = admission else { return XCTFail("\(admission)") }
        let deadline = ContinuousClock.now + .seconds(60)
        while !events.contains(where: { if case .finished = $0 { true } else { false } }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .finished(let outcome)? = events.last else { return XCTFail("no end: \(events)") }

        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.sources.map(\.absoluteString),
                       ["https://site-1.test/", "https://site-2.test/", "https://site-3.test/"])
        XCTAssertEqual(outcome.rows, 3)
        let sheet = try XCTUnwrap(outcome.sheet)
        XCTAssertEqual(events.filter { if case .working = $0 { true } else { false } },
                       (0...3).map { .working(title: "Competitors", done: $0, wanted: 3) })
        XCTAssertTrue(jev.requests.contains { $0.isStep }, "Jev chose the steps")
        XCTAssertTrue(jev.requests.contains { !$0.isStep }, "Jev judged the risk of opening a site")

        let messages = try ModelContext(store).fetch(FetchDescriptor<ChatMessage>())
        XCTAssertEqual(messages.map(\.text), ["""
            Done: 3 rows.

            Sources:
            1. https://site-1.test/
            2. https://site-2.test/
            3. https://site-3.test/

            Sheet: \(sheet.absoluteString)
            """])
        XCTAssertEqual(messages.first?.sender, "ai")

        let tabs = try await world.agentTabCount()
        XCTAssertEqual(tabs, 0, "no tab left open")
        XCTAssertTrue(world.fixtures.blocked.isEmpty, "nothing tried to leave the test pages: \(world.fixtures.blocked)")
    }
}
