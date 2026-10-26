import AppKit
import Combine
import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-076 I-05 — the errand service with the run the app will use: made by
/// `AgentRun.factory`, on the fixture pages. What a run collected is kept
/// when the service ends it, whatever ends it.
@MainActor
final class AgentServiceRunTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("mw-agent-service-run-\(UUID().uuidString)", isDirectory: true)
    private var watch: AnyCancellable?

    override func tearDown() {
        watch = nil
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func plan() throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: "Add three competitor sites to a sheet",
                                subgoals: [.init(description: "Find a competitor's site", terms: ["voice", "notes"])],
                                searches: [URL(string: "https://search.test/?q=voice+notes")!],
                                columns: ["Name", "URL", "What they do"], sheetTitle: "Competitors", rowsWanted: 3,
                                emptyCell: "n/a"))
    }

    private func service(on bridge: any BrowserBridge, plan: AgentPlan? = nil,
                         engine: any DecisionEngine = ScriptedEngine.collectSites(),
                         sheet: (any SheetDestination)? = nil, planner: (any ErrandPlanner)? = nil,
                         stopLimit: Duration = AgentRun.stopLimit, log: LogLines? = nil,
                         center: NotificationCenter = NotificationCenter(),
                         reporter: ErrandReporter? = nil) throws -> AgentService {
        let made = sheet ?? FixtureSheet()
        let factory = AgentRun.factory(planner: try planner ?? FixedPlanner(plan: plan ?? self.plan()), engine: engine,
                                       writer: FakeWriter(), sheet: { _ in made }, stopLimit: stopLimit)
        let runs = Runs()
        let lines = log ?? LogLines()
        let service = AgentService(link: FixedLink(bridge), keepAwake: KeepAwake(create: { 1 }, release: { _ in }),
                                   store: ErrandRecordStore(directory: folder), notificationCenter: center,
                                   isPro: { true },
                                   makeRunner: { setup in
                                       let run = ReturnWatch(factory(setup))
                                       runs.all.append(run)
                                       return run
                                   },
                                   schedule: { _, _ in }, log: lines.sink, reporter: reporter, settings: .allowedForTests)
        self.lines = lines
        self.runs = runs
        return service
    }

    /// The runs the service made, each watched for its return.
    @MainActor
    private final class Runs {
        var all: [ReturnWatch] = []
    }

    private var runs = Runs()
    /// What the service and its runs said in the log.
    private var lines = LogLines()

    private func saved(_ id: UUID) -> ErrandRecordStore.Saved? {
        let file = ErrandRecordStore(directory: folder).fileURL(for: id)
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ErrandRecordStore.Saved.self, from: $0) }
    }

    private func until(_ condition: () -> Bool, _ what: String) async {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Stop after two rows: the errand's end lists both, with their sources,
    /// and its saved record keeps them.
    func testStopAfterTwoRowsKeepsBothRowsAndTheirSources() async throws {
        let bridge = WebViewBridge()
        let service = try service(on: bridge)
        var finished: ErrandOutcome?
        var progress: [ErrandEvent] = []
        watch = service.events.sink { update in
            switch update.event {
            case .working(_, let done, _):
                progress.append(update.event)
                if done == 2 { service.stop(update.id) }
            case .finished(let outcome):
                finished = outcome
            default:
                break
            }
        }
        let id = try XCTUnwrap(service.start(goal: "Add three competitor sites to a sheet",
                                             origin: .chat(messageID: UUID())).id)
        await until({ finished != nil }, "the errand's end")
        let outcome = try XCTUnwrap(finished)
        XCTAssertEqual(progress, (0...2).map { .working(title: "Competitors", done: $0, wanted: 3) })
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(outcome.sources.map(\.host), ["site-1.test", "site-2.test"])
        XCTAssertEqual(outcome.rows, 2)

        // The run returns once it has closed its tab; its final record goes
        // over the one saved at Stop, and keeps the two rows.
        await until({ bridge.openTabCount == 0 && !bridge.openedURLs.isEmpty }, "the run's own end")
        try await Task.sleep(for: .milliseconds(200))
        let file = ErrandRecordStore(directory: folder).fileURL(for: id)
        let saved = try JSONDecoder().decode(ErrandRecordStore.Saved.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.record.rows.map(\.source.host), ["site-1.test", "site-2.test"])
        XCTAssertEqual(saved.outcome.ending, .stopped)
        // ITER-076 I-06a: the log's last line under each number is the final
        // record's event — the ending the service saved at Stop included.
        XCTAssertEqual(saved.record.events.last?.shape, "ending stopped rows=2")
        XCTAssertEqual(lines.events(of: id), saved.record.eventLines)
        XCTAssertTrue(lines.lines(of: id).contains("stop: the user"))
    }

    // MARK: - ITER-076 I-06a: every event on record and in the log

    /// An errand end to end — the service, the factory's run, Jev over its
    /// recorded transport, the fixture pages: it plans, waits once for the
    /// service, takes a step, misses a read, takes its last step and ends
    /// done. Its saved record lists those events in order, the log said each
    /// one — the same line, in the same order — and the service said its
    /// start; nothing of the page or the goal is in either.
    func testAnErrandsEventsAreOnItsSavedRecordAndInTheLogInOrder() async throws {
        let plan = try XCTUnwrap(AgentPlan(goal: "Find the yearly plan for Sam",
                                           subgoals: [.init(description: "Find the yearly plan", terms: ["yearly"])],
                                           searches: [URL(string: "https://site-26.test/")!], columns: ["Plan"],
                                           sheetTitle: "Plans", rowsWanted: 1, emptyCell: "n/a"))
        let jev = RecordedJev { _, number in
            switch number {
            case 0: .status(503, retryAfter: "1")
            case 1: .answers(operation: "SCROLL_DOWN")
            default: .answers(operation: "DONE")
            }
        }
        let lines = LogLines()
        let service = try service(on: FailsOneLook(number: 2), plan: plan, engine: jev.engine, log: lines)
        var finished: ErrandOutcome?
        watch = service.events.sink { update in
            if case .finished(let outcome) = update.event { finished = outcome }
        }
        let id = try XCTUnwrap(service.start(goal: "Find the yearly plan for Sam", origin: .chat(messageID: UUID())).id)
        await until({ finished != nil }, "the errand's end")
        XCTAssertEqual(finished?.ending, .done)

        let record = try XCTUnwrap(saved(id)?.record)
        XCTAssertEqual(record.events.map(\.shape), ["plan ok", "wait answered", "step scroll acted", "miss read",
                                                    "step none reconsidered", "step done acted", "ending done rows=0"])
        guard case .serviceWait(let seconds, _)? = record.events.dropFirst().first else { return XCTFail() }
        XCTAssertEqual(seconds, 1, "as long as the service asked")
        XCTAssertEqual(lines.numbered(of: id), record.eventLines, "one line per event, in order, as the record says it")
        XCTAssertEqual(lines.lines(of: id).first, "started")

        let said = (lines.all + [String(decoding: try JSONEncoder().encode(record.events), as: UTF8.self)])
            .joined(separator: "\n")
        let fixtures = ["Sam", "yearly", "Yearly", "Site Twenty-Six", "Actions", "Show details", "Search the docs",
                        "Billing period", "Monthly", "Next page", "Delete", "Confirm payment", "Pay $10",
                        "Notes editor", "old notes", "/next"]
        for fixture in fixtures { XCTAssertFalse(said.contains(fixture), fixture) }
    }

    // MARK: - I-06a review

    /// P2-1: a step taken back after Stop — the service saved the errand at
    /// Stop, then the run found nothing went out — leaves one ending: under
    /// each number the log's last line is the saved record's event, exactly.
    func testAStepTakenBackAfterStopLeavesOneEndingOnRecordAndInTheLog() async throws {
        let plan = try XCTUnwrap(AgentPlan(goal: "Show the details",
                                           subgoals: [.init(description: "Show the details", terms: ["details"])],
                                           searches: [URL(string: "https://site-26.test/")!], columns: ["Name"],
                                           sheetTitle: "Details", rowsWanted: 1, emptyCell: "n/a"))
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        })
        let bridge = StopsBeforeTheAct()
        let lines = LogLines()
        let service = try service(on: bridge, plan: plan, engine: engine, log: lines)
        let errand = Box<UUID>()
        bridge.stop = { if let id = errand.value { service.stop(id) } }
        errand.value = service.start(goal: "Show the details", origin: .chat(messageID: UUID())).id
        let id = try XCTUnwrap(errand.value)
        await until({ runs.all.first?.returned == true }, "the run's return")

        let record = try XCTUnwrap(saved(id)?.record)
        XCTAssertEqual(record.events.map(\.shape), ["plan ok", "taken back", "ending stopped rows=0"])
        XCTAssertTrue(record.steps.isEmpty, "nothing went out")
        XCTAssertEqual(lines.events(of: id), record.eventLines, "the log's last word under each number")
        XCTAssertEqual(lines.events(of: id).filter { $0.contains(" ending ") }.count, 1, "one ending")
    }

    /// P2-4: Stop, the Mac's sleep and the app's quit while a question is
    /// open each close it as stopped — on record and in the log, one
    /// question, its closing, one ending — and the action is never taken.
    /// Round 2: closed in the record the service saves at once — the app may
    /// exit right after a quit — and not closed again when the run returns.
    func testStopSleepAndQuitWhileAQuestionIsOpenCloseItAsStopped() async throws {
        let plan = try XCTUnwrap(AgentPlan(goal: "Send the message",
                                           subgoals: [.init(description: "Send the message", terms: ["message"])],
                                           searches: [URL(string: "https://site-7.test/")!], columns: ["Name"],
                                           sheetTitle: "Message", rowsWanted: 1, emptyCell: "n/a"))
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" })
        })
        let ways: [(String, @MainActor (AgentService, UUID, NotificationCenter) -> Void)] = [
            ("stop", { service, id, _ in service.stop(id) }),
            ("sleep", { _, _, center in center.post(name: NSWorkspace.willSleepNotification, object: nil) }),
            ("quit", { service, _, _ in service.appWillQuit() }),
        ]
        for (way, end) in ways {
            let bridge = WebViewBridge()
            let lines = LogLines()
            let center = NotificationCenter()
            let service = try service(on: bridge, plan: plan, engine: engine, log: lines, center: center)
            var asked = false
            watch = service.events.sink { update in
                if case .needsYes = update.event { asked = true }
            }
            let id = try XCTUnwrap(service.start(goal: "Send the message", origin: .chat(messageID: UUID())).id)
            await until({ asked }, "\(way): the question")
            end(service, id, center)
            let atOnce = try XCTUnwrap(saved(id)?.record, way)
            XCTAssertEqual(atOnce.events.map(\.shape),
                           ["plan ok", "question click button", "answer stopped", "ending stopped rows=0"],
                           "\(way): saved at once, the question closed")
            await until({ runs.all.first?.returned == true }, "\(way): the run's return")

            let record = try XCTUnwrap(saved(id)?.record, way)
            XCTAssertEqual(record.events.map(\.shape),
                           ["plan ok", "question click button", "answer stopped", "ending stopped rows=0"],
                           "\(way): closed once")
            XCTAssertEqual(lines.events(of: id), record.eventLines, way)
            XCTAssertEqual(lines.numbered(of: id).filter { $0.contains(" answer ") }.count, 1, "\(way): said once")
            XCTAssertTrue(record.steps.isEmpty, "\(way): no step")
            XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/send-message" }, "\(way): never taken")
        }
    }

    /// ITER-076 stage 9d, № 27 — the owner's switch end to end: the app's
    /// run hears it on Jev's route, the errand ends stopped — no wait, no
    /// second try — no report goes to MetaWhisp, and the service keeps
    /// errands off.
    func testTheOwnersSwitchEndsTheErrandUnreportedAndKeepsErrandsOff() async throws {
        let jev = RecordedJev { _, _ in .switchedOff }
        let reports = ErrandReporter(client: ProLLMClient(licenseKey: { "LICENSE-1" },
                                                          send: { _ in throw URLError(.notConnectedToInternet) },
                                                          log: { _ in }),
                                     directory: folder.appendingPathComponent("Reports"), appVersion: "1.3.37")
        let service = try service(on: WebViewBridge(), engine: jev.engine, reporter: reports)
        var finished: ErrandOutcome?
        watch = service.events.sink { update in
            if case .finished(let outcome) = update.event { finished = outcome }
        }
        _ = service.start(goal: "Add three competitor sites to a sheet", origin: .chat(messageID: UUID()))
        await until({ finished != nil }, "the errand's end")
        XCTAssertEqual(finished?.ending, .stopped)
        XCTAssertEqual(jev.requests.count, 1)
        XCTAssertTrue(reports.waiting.isEmpty, "no report")
        XCTAssertFalse(service.canRunErrands, "errands stay off")
    }

    /// ITER-076 stage 9d, № 23, verified: the Mac's "going to sleep" stops the
    /// errand and saves it before the notice returns, but its tab is closed
    /// only after — by the run, once the main actor runs again. Nothing holds
    /// the sleep for that, so the tab can be left open across the sleep: the
    /// next connection closes it (`ChromeStrayTabLiveTests`).
    func testTheErrandsTabIsStillOpenWhenTheSleepNoticeReturns() async throws {
        let plan = try XCTUnwrap(AgentPlan(goal: "Send the message",
                                           subgoals: [.init(description: "Send the message", terms: ["message"])],
                                           searches: [URL(string: "https://site-7.test/")!], columns: ["Name"],
                                           sheetTitle: "Message", rowsWanted: 1, emptyCell: "n/a"))
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" })
        })
        let bridge = WebViewBridge()
        let center = NotificationCenter()
        let service = try service(on: bridge, plan: plan, engine: engine, center: center)
        var asked = false
        watch = service.events.sink { update in
            if case .needsYes = update.event { asked = true }
        }
        let id = try XCTUnwrap(service.start(goal: "Send the message", origin: .chat(messageID: UUID())).id)
        await until({ asked }, "the errand at work in its tab")
        XCTAssertEqual(bridge.openTabCount, 1)

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(saved(id)?.record.ending, .stopped, "stopped and saved before the notice returned")
        XCTAssertEqual(bridge.openTabCount, 1, "its tab is not closed by then")
        await until({ bridge.openTabCount == 0 }, "the run closing its tab once it runs again")
    }

    /// I-06a review round 2: a read of the page that Stop cuts after it went
    /// out — the bridge says interrupted, as Chrome does — is Stop, never a
    /// miss: a look at the page and a read while the page settles.
    func testAReadStopCutsShortIsNoMiss() async throws {
        let plan = try XCTUnwrap(AgentPlan(goal: "Show the details",
                                           subgoals: [.init(description: "Show the details", terms: ["details"])],
                                           searches: [URL(string: "https://site-26.test/")!], columns: ["Name"],
                                           sheetTitle: "Details", rowsWanted: 1, emptyCell: "n/a"))
        for read in [InterruptsARead.Read.look, .settle] {
            let bridge = InterruptsARead(read)
            let lines = LogLines()
            let service = try service(on: bridge, plan: plan, engine: ScriptedEngine.collectSites(), log: lines)
            var finished: ErrandOutcome?
            watch = service.events.sink { update in
                if case .finished(let outcome) = update.event { finished = outcome }
            }
            let errand = Box<UUID>()
            bridge.stop = { if let id = errand.value { service.stop(id) } }
            errand.value = service.start(goal: "Show the details", origin: .chat(messageID: UUID())).id
            let id = try XCTUnwrap(errand.value)
            await until({ runs.all.first?.returned == true }, "\(read): the run's return")

            XCTAssertTrue(bridge.interrupted, "\(read)")
            XCTAssertEqual(finished?.ending, .stopped, "\(read)")
            let record = try XCTUnwrap(saved(id)?.record, "\(read)")
            XCTAssertEqual(record.events.map(\.shape), ["plan ok", "ending stopped rows=0"], "\(read): no miss")
            XCTAssertEqual(lines.events(of: id), record.eventLines, "\(read)")
        }
    }

    /// The fixture browser, where Stop comes while a read is out — the first
    /// look at the page, or the first check of whether it loads — and the
    /// bridge then says the read was interrupted, as Chrome does once a
    /// request went out.
    @MainActor
    private final class InterruptsARead: BrowserBridge {
        enum Read { case look, settle }

        let inner = WebViewBridge()
        private let read: Read
        var stop: (@MainActor () -> Void)?
        private(set) var interrupted = false

        init(_ read: Read) { self.read = read }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func isLoading(_ tab: BrowserTab) async throws -> Bool {
            if read == .settle, !interrupted { try interrupt() }
            return try await inner.isLoading(tab)
        }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if read == .look, !interrupted, javascript == ObserverScript.source { try interrupt() }
            return try await inner.run(javascript, in: tab)
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }

        private func interrupt() throws {
            interrupted = true
            stop?()
            throw BrowserBridgeError.interrupted
        }
    }

    /// The fixture browser, where the `number`-th look at the page fails as
    /// a script that threw.
    @MainActor
    private final class FailsOneLook: BrowserBridge {
        let inner = WebViewBridge()
        private let number: Int
        private var looks = 0

        init(number: Int) { self.number = number }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if javascript == ObserverScript.source {
                looks += 1
                if looks == number { throw BrowserBridgeError.scriptFailed(code: -3) }
            }
            return try await inner.run(javascript, in: tab)
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    // MARK: - Review round 1

    /// P1-1: Stop while an act's reply is on its way — the script reached the
    /// page — keeps the act in the record the service saves at Stop and in
    /// the final one, and its postcondition is still checked.
    func testAnActStoppedAfterItWasSentIsKeptAndChecked() async throws {
        let plan = try XCTUnwrap(AgentPlan(goal: "Show the details",
                                           subgoals: [.init(description: "Show the details", terms: ["details"])],
                                           searches: [URL(string: "https://site-26.test/")!], columns: ["Name"],
                                           sheetTitle: "Details", rowsWanted: 1, emptyCell: "n/a"))
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" }
                ?? request.candidates.first { $0.action.operation == .done })
        })
        let bridge = InterruptsTheAct()
        let service = try service(on: bridge, plan: plan, engine: engine)
        let errand = Box<UUID>()
        let atStop = Box<ErrandRecord>()
        bridge.onAct = {
            guard let id = errand.value else { return }
            service.stop(id)
            atStop.value = self.saved(id)?.record
        }
        errand.value = service.start(goal: "Show the details", origin: .chat(messageID: UUID())).id
        let id = try XCTUnwrap(errand.value)
        await until({ runs.all.first?.returned == true }, "the run's return")

        let stopped = try XCTUnwrap(atStop.value)
        XCTAssertEqual(stopped.steps.last?.operation, "click", "the act was on its way: recorded at Stop")
        let final = try XCTUnwrap(saved(id)?.record)
        XCTAssertEqual(final.steps.last?.operation, "click")
        XCTAssertEqual(final.steps.last?.outcome, .acted, "its postcondition saw the details change")
        XCTAssertGreaterThan(bridge.looksAfterTheAct, 0, "the page was read again to check it")
    }

    /// P2-1: Stop while the rows are pasted: the Sheet was made, so the end
    /// the service publishes, and the record it saves, carry its address.
    func testStopDuringThePasteKeepsTheSheetsAddress() async throws {
        let sheet = PasteHook()
        let service = try service(on: WebViewBridge(), sheet: sheet)
        var finished: ErrandOutcome?
        watch = service.events.sink { update in
            if case .finished(let outcome) = update.event { finished = outcome }
        }
        let errand = Box<UUID>()
        let atStop = Box<ErrandRecord>()
        sheet.onPaste = {
            guard let id = errand.value else { return }
            service.stop(id)
            atStop.value = self.saved(id)?.record
        }
        errand.value = service.start(goal: "Add three competitor sites to a sheet", origin: .chat(messageID: UUID())).id
        await until({ finished != nil }, "the errand's end")
        let made = try XCTUnwrap(sheet.made)
        XCTAssertEqual(finished?.ending, .stopped)
        XCTAssertEqual(finished?.sheet, made, "the end MetaChat gets links the Sheet")
        XCTAssertEqual(atStop.value?.sheet, made, "and so does the record saved at Stop")
        XCTAssertEqual(atStop.value?.sheetWrite, .created, "made; the paste had not returned")
    }

    /// The fixture browser, where the first act's reply is lost to Stop: the
    /// script reaches the page, then `onAct` presses Stop, and the bridge
    /// says the call was interrupted. It counts the looks after that.
    @MainActor
    private final class InterruptsTheAct: BrowserBridge {
        let inner = WebViewBridge()
        var onAct: (@MainActor () -> Void)?
        private var interrupted = false
        private(set) var looksAfterTheAct = 0

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if interrupted, javascript == ObserverScript.source { looksAfterTheAct += 1 }
            // An act's lookup made alone before it is not the act (ITER-076
            // I-09, round 5).
            guard !interrupted, javascript.contains("const expected"), !javascript.contains(#""operation":"found""#) else {
                return try await inner.run(javascript, in: tab)
            }
            interrupted = true
            onAct?()
            _ = try await inner.run(javascript, in: tab)
            throw BrowserBridgeError.interrupted
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// A fixture Sheet that calls `onPaste` once the rows are in it.
    @MainActor
    private final class PasteHook: SheetDestination {
        private let inner = FixtureSheet()
        var onPaste: (@MainActor () -> Void)?
        private(set) var made: URL?

        func create(title: String, made receipt: @escaping @MainActor (URL) -> Void) async throws -> URL {
            let address = try await inner.create(title: title, made: receipt)
            made = address
            return address
        }

        func paste(_ text: String, into sheet: URL) async throws {
            try await inner.paste(text, into: sheet)
            onPaste?()
        }

        func readBack(_ sheet: URL) async throws -> SheetReadBack { try await inner.readBack(sheet) }
    }

    // MARK: - Review round 2

    /// MetaChat instances the tests keep alive while they listen.
    private var chats: [ChatService] = []

    /// MetaChat on an in-memory store, hearing `service`'s errands.
    private func chat(hearing service: AgentService) throws -> (ChatService, ModelContainer) {
        let store = try ModelContainer(for: Schema([
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let chat = ChatService()
        chat.configure(modelContainer: store)
        chat.observeErrands(service.events)
        chats.append(chat)
        return (chat, store)
    }

    private func messages(in store: ModelContainer) throws -> [String] {
        try ModelContext(store).fetch(FetchDescriptor<ChatMessage>()).map(\.text)
    }

    /// P2-1: the Sheet exists once `create` says so, before it returns: Stop
    /// right after that — `create` returning only past Stop's limit — still
    /// ends the errand with the Sheet, in what the service saves at once and
    /// in MetaChat's result.
    func testASheetMadeBeforeStopIsInTheResultAtOnce() async throws {
        let sheet = CreateHook(receiptFirst: true, returnsAfter: .milliseconds(1_200))
        let service = try service(on: WebViewBridge(), sheet: sheet, stopLimit: .milliseconds(300))
        let (_, store) = try chat(hearing: service)
        let errand = Box<UUID>()
        let atStop = Box<ErrandRecordStore.Saved>()
        sheet.inCreate = {
            guard let id = errand.value else { return }
            service.stop(id)
            atStop.value = self.saved(id)
        }
        errand.value = service.start(goal: "Add three competitor sites to a sheet", origin: .chat(messageID: UUID())).id
        let id = try XCTUnwrap(errand.value)
        await until({ sheet.returned }, "create's return")
        let made = try XCTUnwrap(sheet.made)
        XCTAssertEqual(atStop.value?.outcome.sheet, made, "the outcome saved at Stop links the Sheet")
        XCTAssertEqual(atStop.value?.record.sheet, made)
        XCTAssertEqual(saved(id)?.outcome.sheet, made, "and nothing later drops it")
        XCTAssertEqual(try messages(in: store), ["Stopped.\n\nSources:\n1. https://site-1.test/\n2. https://site-2.test/"
                                                   + "\n3. https://site-3.test/\n\nSheet: \(made.absoluteString)"])
    }

    /// P2-1: a Sheet that comes into being only after Stop's limit — its
    /// receipt that late — is still added to what the service kept and to
    /// MetaChat's one result for the errand.
    func testASheetWhoseReceiptComesAfterStopsLimitIsReconciled() async throws {
        let sheet = CreateHook(receiptFirst: false, returnsAfter: .milliseconds(1_200))
        let service = try service(on: WebViewBridge(), sheet: sheet, stopLimit: .milliseconds(300))
        let (_, store) = try chat(hearing: service)
        var events: [ErrandEvent] = []
        watch = service.events.sink { events.append($0.event) }
        let errand = Box<UUID>()
        sheet.inCreate = {
            if let id = errand.value { service.stop(id) }
        }
        errand.value = service.start(goal: "Add three competitor sites to a sheet", origin: .chat(messageID: UUID())).id
        let id = try XCTUnwrap(errand.value)
        await until({ runs.all.first?.returned == true }, "the run's return, at Stop's limit")
        XCTAssertNil(sheet.made, "the Sheet did not exist yet")
        XCTAssertNil(saved(id)?.outcome.sheet)
        await until({ sheet.returned }, "create's return")
        let made = try XCTUnwrap(sheet.made)
        XCTAssertEqual(saved(id)?.outcome.sheet, made, "the late Sheet is added to the outcome kept")
        XCTAssertEqual(saved(id)?.record.sheet, made)
        XCTAssertEqual(saved(id)?.outcome.ending, .stopped)
        guard case .finished(let first)? = events.first(where: { if case .finished = $0 { true } else { false } }),
              case .amended(let amended)? = events.last else { return XCTFail("\(events)") }
        XCTAssertNil(first.sheet)
        XCTAssertEqual(amended.sheet, made)
        XCTAssertEqual(try messages(in: store).count, 1, "one result for the errand, updated")
        XCTAssertTrue(try messages(in: store).first?.hasSuffix("Sheet: \(made.absoluteString)") == true)
    }

    /// P2-1: a Sheet whose receipt comes after Stop but before the run
    /// returns is not dropped by the run's last save.
    func testASheetWhoseReceiptComesBeforeTheRunReturnsIsKept() async throws {
        let sheet = CreateHook(receiptFirst: false, returnsAfter: .milliseconds(300))
        let service = try service(on: WebViewBridge(), sheet: sheet, stopLimit: .seconds(5))
        let errand = Box<UUID>()
        sheet.inCreate = {
            if let id = errand.value { service.stop(id) }
        }
        errand.value = service.start(goal: "Add three competitor sites to a sheet", origin: .chat(messageID: UUID())).id
        let id = try XCTUnwrap(errand.value)
        await until({ runs.all.first?.returned == true }, "the run's return, after the receipt")
        let made = try XCTUnwrap(sheet.made)
        XCTAssertEqual(saved(id)?.outcome.sheet, made, "the run's last save keeps the Sheet")
        XCTAssertEqual(saved(id)?.record.sheet, made)
    }

    /// P2-6: quit while the plan is asked for — its answer not in — keeps the
    /// plan's reserved worst case in the record the service saves at once.
    func testQuitWhileThePlanIsAskedKeepsItsReservedSpend() async throws {
        let planner = WaitingPlanner(plan: try plan())
        let service = try service(on: WebViewBridge(), planner: planner)
        let id = try XCTUnwrap(service.start(goal: "Add three competitor sites to a sheet",
                                             origin: .chat(messageID: UUID())).id)
        await until({ planner.asked }, "the plan's request")
        service.appWillQuit()
        let atQuit = try XCTUnwrap(saved(id), "saved at quit")
        XCTAssertEqual(atQuit.record.spentUSD ?? -1, 0.02, accuracy: 1e-9, "the plan's request is out: its worst case")
        XCTAssertEqual(atQuit.outcome.ending, .stopped)
    }

    /// A planner that costs $0.02 at worst, says when it is asked, and never
    /// answers.
    private final class WaitingPlanner: ErrandPlanner, @unchecked Sendable {
        func worstCaseUSD(goal: String) -> Double { 0.02 }
        private let planned: AgentPlan
        private let lock = NSLock()
        private var wasAsked = false

        init(plan: AgentPlan) { planned = plan }

        var asked: Bool {
            lock.lock()
            defer { lock.unlock() }
            return wasAsked
        }

        func plan(goal: String) async throws -> AgentPlan {
            mark()
            try await Task.sleep(for: .seconds(60))
            return planned
        }

        private func mark() {
            lock.lock()
            wasAsked = true
            lock.unlock()
        }
    }

    /// A fixture Sheet whose `create` calls `inCreate` and returns only after
    /// `returnsAfter`, deaf to Stop. The Sheet exists — its receipt goes out —
    /// before `inCreate` when `receiptFirst`, otherwise only right before
    /// `create` returns.
    @MainActor
    private final class CreateHook: SheetDestination {
        private let inner = FixtureSheet()
        private let receiptFirst: Bool
        private let returnsAfter: Duration
        var inCreate: (@MainActor () -> Void)?
        private(set) var made: URL?
        private(set) var returned = false

        init(receiptFirst: Bool, returnsAfter: Duration) {
            self.receiptFirst = receiptFirst
            self.returnsAfter = returnsAfter
        }

        func create(title: String, made receipt: @escaping @MainActor (URL) -> Void) async throws -> URL {
            var address: URL?
            if receiptFirst {
                address = try await inner.create(title: title, made: receipt)
                made = address
            }
            inCreate?()
            let seconds = Double(returnsAfter.components.seconds) + Double(returnsAfter.components.attoseconds) / 1e18
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { continuation.resume() }
            }
            if address == nil {
                address = try await inner.create(title: title, made: receipt)
                made = address
            }
            returned = true
            return try XCTUnwrap(address)
        }

        func paste(_ text: String, into sheet: URL) async throws { try await inner.paste(text, into: sheet) }
        func readBack(_ sheet: URL) async throws -> SheetReadBack { try await inner.readBack(sheet) }
    }
}
