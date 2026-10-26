import AppKit
import Combine
import Security
import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 3C — the live bench: the trial errands on real sites,
/// through the app's own service and run, against the live Pro server, in the
/// test Chrome profile — measured. It runs only with METAWHISP_BENCH=1, never
/// in the gate, and writes into the folder METAWHISP_BENCH_OUT names: the
/// browser's facts (`s3c-facts.json`), each errand's record by kinds and
/// numbers (`s3c-<n>.json`) and a line per errand (`s3-measures.md`).
///
/// The service is built as `AgentService.shared` is — `AgentRun.answering`,
/// Jev through `/api/pro/decisions`, the brain through `/api/pro/agent`, the
/// failed errands' reporter — but for two things a test process cannot have
/// as the app has them. The link: the app's own `ChromeLink`, looking in a
/// folder of the bench whose only browser profile is the test profile, so it
/// never reaches the user's own Chrome. The licence: read from the app's
/// keychain item with every keychain prompt off (under XCTest the app's
/// keychain is an empty one), and never printed, logged or written. Every
/// call to the server is seen on its way back for its numbers alone. Every Yes
/// the agent asks is answered No; a pause — the user's part — is shown, then
/// stopped; an errand still running at ten minutes is stopped.
@MainActor
final class AgentLiveBenchTests: XCTestCase {
    /// The trial errands, fixed before the run: find 10 jokes in the browser;
    /// what time the Louvre opens today; find 3 free courses on Swift.
    static let goals = [
        "\u{043D}\u{0430}\u{0439}\u{0434}\u{0438} \u{0432} \u{0431}\u{0440}\u{0430}\u{0443}\u{0437}\u{0435}\u{0440}\u{0435} 10 \u{043F}\u{0440}\u{0438}\u{043A}\u{043E}\u{043B}\u{043E}\u{0432}",
        "\u{0432}\u{043E} \u{0441}\u{043A}\u{043E}\u{043B}\u{044C}\u{043A}\u{043E} \u{0441}\u{0435}\u{0433}\u{043E}\u{0434}\u{043D}\u{044F} \u{043E}\u{0442}\u{043A}\u{0440}\u{044B}\u{0432}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F} \u{041B}\u{0443}\u{0432}\u{0440}",
        "\u{043D}\u{0430}\u{0439}\u{0434}\u{0438} 3 \u{0431}\u{0435}\u{0441}\u{043F}\u{043B}\u{0430}\u{0442}\u{043D}\u{044B}\u{0445} \u{043A}\u{0443}\u{0440}\u{0441}\u{0430} \u{043F}\u{043E} Swift",
    ]
    static let errandLimit: Duration = .seconds(600)

    /// The errands the bench runs: METAWHISP_BENCH_GOALS, one a line — a table asked for among them (ITER-076
    /// stage 6, № 243) — else the trial errands.
    static func goals(in environment: [String: String]) -> [String] {
        let given = (environment["METAWHISP_BENCH_GOALS"] ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return given.isEmpty ? goals : given
    }

    /// № 243: the errands may be given one a line, each trimmed, blank lines aside; none given — the trial errands.
    func testTheBenchsErrandsMayBeGivenOneALine() {
        XCTAssertEqual(Self.goals(in: [:]), Self.goals)
        XCTAssertEqual(Self.goals(in: ["METAWHISP_BENCH_GOALS": "collect 10 MetaWhisp competitors into a table\n\n"
                                                                + "  put 5 soup recipes into a sheet \n"]),
                       ["collect 10 MetaWhisp competitors into a table", "put 5 soup recipes into a sheet"])
        XCTAssertEqual(Self.goals(in: ["METAWHISP_BENCH_GOALS": " \n "]), Self.goals, "nothing given: the trial errands")
    }

    /// № 243: what became of the errand's Sheet is in the bench's record, its line and its summary — how far its
    /// rows got (made, pasted, read back as pasted) and how it failed — and nothing when none was asked for.
    func testTheBenchKeepsWhatBecameOfTheSheet() {
        func measure(_ write: ErrandRecord.SheetWrite?, _ failure: ErrandOutcome.SheetFailure?) -> BenchMeasure {
            var record = ErrandRecord(errandID: UUID(), goal: "collect 10 MetaWhisp competitors")
            record.sheet = write.map { _ in URL(string: "https://docs.google.com/spreadsheets/d/SHEET-1/edit")! }
            record.sheetWrite = write
            let outcome = ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: record.sheet, rows: 0,
                                        sheetFailure: failure)
            let saved = ErrandRecordStore.Saved(version: ErrandRecordStore.Saved.currentVersion,
                                                origin: .chat(messageID: UUID()), record: record, outcome: outcome)
            return BenchMeasure(number: 1, goal: record.goal, errand: BenchErrand(), saved: saved, calls: [],
                                tabsLeft: 0)
        }
        let verified = measure(.verified, nil)
        XCTAssertEqual(verified.record.sheet, "verified")
        XCTAssertNil(verified.record.sheetFailure)
        XCTAssertTrue(verified.summary.contains(" sheet=verified "), verified.summary)
        XCTAssertTrue(verified.line.contains(" | verified | "), verified.line)
        let mismatch = measure(.pasted, .mismatch)
        XCTAssertEqual(mismatch.record.sheet, "pasted")
        XCTAssertEqual(mismatch.record.sheetFailure, "mismatch")
        XCTAssertTrue(mismatch.summary.contains(" sheet=pasted/mismatch "), mismatch.summary)
        let signIn = measure(nil, .signIn)
        XCTAssertNil(signIn.record.sheet)
        XCTAssertEqual(signIn.record.sheetFailure, "signIn")
        XCTAssertTrue(signIn.line.contains(" | none/signIn | "), signIn.line)
        let none = measure(nil, nil)
        XCTAssertTrue(none.summary.contains(" sheet=none "), none.summary)
        XCTAssertTrue(none.line.contains(" | none | "), none.line)
    }

    /// The bench may start each errand as the voice island does (2026-10-07, a critic's finding: the bench only
    /// typed): METAWHISP_BENCH_VIA_CHAT=voice hands the goal to MetaChat as a transcribed spoken question; =1 types
    /// it into MetaChat; anything else lets the service start it. The record keeps the origin's kind, never its id.
    func testTheBenchMayStartEachErrandAsTheVoiceIslandDoes() {
        XCTAssertEqual(Self.start(in: [:]), .service)
        XCTAssertEqual(Self.start(in: ["METAWHISP_BENCH_VIA_CHAT": "1"]), .typed)
        XCTAssertEqual(Self.start(in: ["METAWHISP_BENCH_VIA_CHAT": "voice"]), .voice)
        XCTAssertEqual(Self.start(in: ["METAWHISP_BENCH_VIA_CHAT": "0"]), .service)
        func measure(_ origin: ErrandOrigin?) -> BenchMeasure {
            let record = ErrandRecord(errandID: UUID(), goal: "find 10 jokes in the browser")
            let outcome = ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0, sheetFailure: nil)
            let saved = origin.map { ErrandRecordStore.Saved(version: ErrandRecordStore.Saved.currentVersion,
                                                              origin: $0, record: record, outcome: outcome) }
            return BenchMeasure(number: 1, goal: record.goal, errand: BenchErrand(), saved: saved, calls: [],
                                tabsLeft: 0)
        }
        let question = UUID()
        XCTAssertEqual(measure(.voice(questionID: question)).record.origin, "voice")
        XCTAssertEqual(measure(.chat(messageID: question)).record.origin, "chat")
        XCTAssertNil(measure(nil).record.origin, "no record kept: no origin")
        XCTAssertTrue(measure(.voice(questionID: question)).summary.contains(" origin=voice"),
                      measure(.voice(questionID: question)).summary)
        let encoded = String(decoding: (try? JSONEncoder().encode(measure(.voice(questionID: question)).record)) ?? Data(),
                             as: UTF8.self)
        XCTAssertFalse(encoded.contains(question.uuidString), "the question's id stays out of the record")
    }

    /// Each errand's line names the models that answered its agent calls, as each answer named itself (2026-10-07,
    /// a critic's finding: an arm the server could not serve was answered by another model, and the line showed
    /// only the arm asked) — with their count, and a call no model answered as such. Jev's calls are not counted.
    func testTheBenchsLineNamesTheModelsThatAnswered() {
        func call(_ route: String, _ purpose: String?, _ status: Int, _ provider: String?, _ model: String?)
            -> BenchTap.Call {
            BenchTap.Call(route: route, purpose: purpose, status: status, ms: 10, usd: 0.001, inputTokens: 100,
                          outputTokens: 10, toolCalls: nil, provider: provider, model: model)
        }
        let calls = [call("agent", "plan", 200, "groq", "openai/gpt-oss-120b"),
                     call("decisions", nil, 200, "typesafe", "jev-1.13.0"),
                     call("agent", "read", 200, "openrouter", "google/gemini-3.8-flash"),
                     call("agent", "read", 200, "openrouter", "google/gemini-3.8-flash"),
                     call("agent", "verify", -1, nil, nil)]
        let measure = BenchMeasure(number: 1, goal: "find 10 jokes in the browser", errand: BenchErrand(), saved: nil,
                                   calls: calls, tabsLeft: 0)
        let served = "groq:openai/gpt-oss-120b 1 · no answer 1 · openrouter:google/gemini-3.8-flash 2"
        XCTAssertTrue(measure.line.contains(" | \(served) | "), measure.line)
        XCTAssertTrue(measure.summary.contains(" served=[\(served)]"), measure.summary)
        XCTAssertFalse(measure.line.contains("jev-1.13.0"), "Jev is no model arm")
        let columns = { (row: String) in row.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|",
                                                                                                    omittingEmptySubsequences: false).count }
        let header = BenchMeasure.header.split(separator: "\n").map(String.init)
        XCTAssertTrue(header[0].contains(" | model calls by purpose | served by | "), header[0])
        XCTAssertEqual(columns(header[0]), columns(header[1]), "the separator has a cell for every column")
        XCTAssertEqual(columns(measure.line), columns(header[0]), "the line has a cell for every column")
    }

    func testTheTrialErrandsOnTheTestChrome() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["METAWHISP_BENCH"] == "1" else {
            throw XCTSkip("the live bench runs only with METAWHISP_BENCH=1")
        }
        let out = URL(fileURLWithPath: try XCTUnwrap(environment["METAWHISP_BENCH_OUT"],
                                                     "METAWHISP_BENCH_OUT names the folder the bench writes to"),
                      isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let chrome = try await BenchChrome.launch()
        do {
            try await bench(on: chrome, out: out)
        } catch {
            await chrome.close()
            throw error
        }
        await chrome.close()
        XCTAssertTrue(chrome.process.isTerminated, "the bench closes the Chrome it started")
    }

    private func bench(on chrome: BenchChrome, out: URL) async throws {
        let eyes = CDPConnection(url: chrome.endpoint.webSocketURL)
        try await eyes.open(allowLimit: .seconds(10))
        let link = ChromeLink(applicationSupport: chrome.root)
        let facts = await Self.facts(of: chrome, eyes: eyes, link: link)
        try Self.write(facts, to: out.appendingPathComponent("s3c-facts.json"))
        print("[Bench] facts: \(facts.summary)")
        let measures = out.appendingPathComponent("s3-measures.md")
        let start = Self.start(in: ProcessInfo.processInfo.environment)
        Self.append("\n### Bench run \(Date().formatted(.iso8601)) — \(facts.chrome), screen locked: "
                    + "\(facts.screenLocked), model arm: "
                    + "\(ProcessInfo.processInfo.environment["METAWHISP_BENCH_ARM"].flatMap { $0.isEmpty ? nil : $0 } ?? "the server's")"
                    + ", start: \(Self.startPage.host() ?? "?"), errands started: \(start.rawValue)"
                    + "\n\n" + BenchMeasure.header, to: measures)

        let (licence, status) = BenchLicence.read()
        guard let licence else {
            Self.append("\nStopped before the errands: the licence is not readable by the bench (keychain status "
                        + "\(status)).\n", to: measures)
            XCTFail("the licence is not readable by the bench: keychain status \(status)")
            await eyes.close()
            return
        }
        let tap = BenchTap(arm: ProcessInfo.processInfo.environment["METAWHISP_BENCH_ARM"])
        let key: @Sendable () async -> String? = { licence }
        let client = ProLLMClient(licenseKey: key, send: tap.send)
        let engine = JevDecisionEngine(jev: JevEngine(licenseKey: key, send: tap.send))
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("metawhisp-bench-\(UUID().uuidString)", isDirectory: true)
        let store = ErrandRecordStore(directory: work.appendingPathComponent("Agent", isDirectory: true))
        let reporter = ErrandReporter(client: client, directory: work.appendingPathComponent("Reports", isDirectory: true),
                                      appVersion: "0")
        // METAWHISP_BENCH_BRAIN=<proxy model id> (2026-10-19): the brain's runs — one model decides every step —
        // asked through METAWHISP_BENCH_BRAIN_URL, the details a form asks for the bench's persona's, never the
        // owner's.
        let brainModel = ProcessInfo.processInfo.environment["METAWHISP_BENCH_BRAIN"].flatMap { $0.isEmpty ? nil : $0 }
        let brainURL = URL(string: ProcessInfo.processInfo.environment["METAWHISP_BENCH_BRAIN_URL"]
                           ?? "http://127.0.0.1:8787/v1/chat/completions")!
        // METAWHISP_BENCH_BRAIN=server (2026-10-20): the product's own path — the brain on the Pro server's product
        // arm, as `AgentService.shared` runs it — asked with the bench's licence; `server:<arm>` names another arm.
        let makeRunner = brainModel.map { model in
            AgentRun.thinking(brain: { () -> any Brain in
                                  let trace = out.appendingPathComponent("brain-trace.jsonl")
                                  if model == "server" {
                                      return TracedBrain(ServerBrain(client: client, arm: ServerBrain.productArm), trace: trace)
                                  }
                                  if model.hasPrefix("server:") {
                                      return TracedBrain(ServerBrain(client: client, arm: String(model.dropFirst("server:".count))),
                                                         trace: trace)
                                  }
                                  return EndpointBrain(endpoint: brainURL, model: model,
                                                       trace: out.appendingPathComponent("brain-trace.jsonl"))
                              },
                              engine: engine,
                              startPage: Self.startPage, facts: { BenchPersona.facts })
        } ?? AgentRun.answering(client: client, engine: engine, startPage: Self.startPage)
        let service = AgentService(link: link, keepAwake: KeepAwake(), store: store, isPro: { true },
                                   makeRunner: makeRunner, reporter: reporter, settings: .allowedForTests)
        print("[Bench] the errands' own records (answers included) are kept in \(work.path)")
        let chat = start == .service ? nil : try Self.metaChat(on: service, licence: licence)

        // Each route that broke while the bench went on, failed at its end (Codex review, P2-6).
        var brokenRoutes: [String] = []
        defer { if !brokenRoutes.isEmpty { XCTFail("routes broke on the way: " + brokenRoutes.joined(separator: "; ")) } }
        for (index, goal) in Self.goals(in: ProcessInfo.processInfo.environment).enumerated() {
            let number = index + 1
            let mark = tap.calls.count
            let tabsBefore = await Self.pages(eyes)
            // Each errand starts as a fresh visitor of the sites its task names (2026-10-21, blind b15: the test
            // profile's cart held eight books from earlier runs, and the total the errand read was theirs too).
            await Self.clearSites(BenchTasks.yesHosts(for: goal, in: ProcessInfo.processInfo.environment), eyes)
            let errand = try await run(goal, on: service, chrome: chrome, via: chat, spoken: start == .voice)
            await reporter.sendWaiting()
            let calls = Array(tap.calls.dropFirst(mark))
            let saved = store.load(id: errand.id)
            if let question = errand.question {
                XCTAssertEqual(saved?.origin, .voice(questionID: question),
                               "errand \(number) belongs to the spoken question that started it")
            }
            let measure = BenchMeasure(number: number, goal: goal, errand: errand, saved: saved, calls: calls,
                                       tabsLeft: await Self.pages(eyes) - tabsBefore)
            try Self.appendLine(BenchResult(goal: goal, errand: errand, saved: saved?.record).line,
                                to: out.appendingPathComponent("brain-results.jsonl"))
            try Self.write(measure.record, to: out.appendingPathComponent("s3c-\(number).json"))
            Self.append(measure.line, to: measures)
            print("[Bench] errand \(number): \(measure.summary)")
            if let broken = measure.brokenRoute {
                // METAWHISP_BENCH_KEEP_GOING=1: said, and the next errand runs (2026-10-15: one read without its cost
                // stopped a 34-errand run at 18).
                guard ProcessInfo.processInfo.environment["METAWHISP_BENCH_KEEP_GOING"] == "1" else {
                    XCTFail("errand \(number): \(broken) — the bench stops")
                    break
                }
                print("[Bench] errand \(number): \(broken) — going on")
                brokenRoutes.append("errand \(number): \(broken)")
            }
        }
        await eyes.close()
    }

    /// One errand, from its start to its end: every Yes it asks answered No,
    /// a pause shown and then stopped, and a Stop at ten minutes.
    private func run(_ goal: String, on service: AgentService, chrome: BenchChrome,
                     via chat: MetaChat? = nil, spoken: Bool = false) async throws -> BenchErrand {
        let errand = BenchErrand()
        let yesHosts = BenchTasks.yesHosts(for: goal, in: ProcessInfo.processInfo.environment)
        let watch = service.events.sink { update in
            if errand.seenID == nil { errand.seenID = update.id }
            switch update.event {
            case .needsYes(let request):
                errand.yesAsked.append(request.action.operation.rawValue)
                // METAWHISP_BENCH_YES_HOSTS: the test sites whose questions the bench answers Yes, as the manual plan
                // says for them (2026-10-15: the plan presses Yes for the quotes-search form); every other one No.
                let host = URL(string: request.pageURL)?.host() ?? ""
                // The host itself, or it with or without "www." — never another subdomain (Codex review of 2026-10-19).
                let yes = yesHosts.contains { host == $0 || host == "www." + $0 || "www." + host == $0 }
                errand.questions.append("\(request.action.operation.rawValue) \"\(request.action.target?.name ?? request.action.destination ?? "")\" on \(host)")
                errand.yesGiven.append(yes)
                service.answer(update.id, to: request, yes ? .yes : .no)
            case .paused(let pause):
                errand.pauses.append(pause.handover.kind.rawValue)
                Task { @MainActor in
                    let before = BenchFront.now()
                    let shown = service.showTab(update.id)
                    try? await Task.sleep(for: .seconds(2))
                    errand.showTab = BenchFront.Shown(asked: shown, before: before, after: BenchFront.now(),
                                                      chrome: chrome.process.processIdentifier)
                    errand.stoppedByBench = errand.stoppedByBench ?? "paused for the user's part"
                    service.stop(update.id)
                }
            case .needsUser(let handover):
                errand.handOvers.append(handover.kind.rawValue)
            case .finished(let outcome):
                errand.outcome = outcome
            default:
                break
            }
        }
        defer { watch.cancel() }
        let began = ContinuousClock.now
        let id: UUID
        if let chat {
            // As the user's errand starts: the goal sent to MetaChat — its rules, its tools, the live Pro chat —
            // which calls runErrand on this service. Spoken: as the voice island sends a transcribed question,
            // under the island's id for it — with no screen captured, as the bench never sends the screen.
            var source = ChatService.Source.typed
            if spoken {
                let question = UUID()
                errand.question = question
                source = .voice(question: question)
            }
            let reply = await chat.service.send(goal, source: source)
            print("[Bench] MetaChat answered \(reply) before the errand: \(chat.replies().map(\.count)) chars")
            guard let started = errand.seenID else {
                XCTFail("MetaChat started no errand")
                throw CancellationError()
            }
            id = started
        } else {
            guard case .started(let started) = service.start(goal: goal, origin: .chat(messageID: UUID())) else {
                XCTFail("the service did not start the errand")
                throw CancellationError()
            }
            id = started
        }
        errand.id = id
        let limit = Task { @MainActor in
            try? await Task.sleep(for: Self.errandLimit)
            guard !Task.isCancelled, errand.outcome == nil else { return }
            errand.stoppedByBench = "ten minutes"
            service.stop(id)
        }
        while errand.outcome == nil { try await Task.sleep(for: .milliseconds(200)) }
        limit.cancel()
        errand.seconds = Double((ContinuousClock.now - began) / .milliseconds(1)) / 1000
        // A stopped run saves its final record within Stop's limit.
        if errand.outcome?.ending == .stopped { try await Task.sleep(for: AgentRun.stopLimit + .seconds(1)) }
        if let chat {
            // The errand's result is MetaChat's next message.
            let result = chat.service.resultMessage(of: id) != nil
            print("[Bench] via MetaChat: the result message \(result ? "is" : "is NOT") in MetaChat")
            XCTAssertTrue(result, "the errand's result reached MetaChat")
        }
        return errand
    }

    /// How each errand starts: METAWHISP_BENCH_VIA_CHAT=1 — typed into MetaChat, as the user's typed errand does;
    /// =voice — handed to MetaChat as the voice island hands it a spoken question once transcribed
    /// (`TranscriptionCoordinator`'s answerer); anything else — started by the service.
    enum Start: String { case service, typed, voice }

    static func start(in environment: [String: String]) -> Start {
        switch environment["METAWHISP_BENCH_VIA_CHAT"] {
        case "1": .typed
        case "voice": .voice
        default: .service
        }
    }

    /// MetaChat on `service`, as the app wires it, with an empty store of its own and the bench's licence.
    final class MetaChat {
        let service: ChatService
        let store: ModelContainer
        let executor: ChatToolExecutor
        init(service: ChatService, store: ModelContainer, executor: ChatToolExecutor) {
            (self.service, self.store, self.executor) = (service, store, executor)
        }
        /// MetaChat's own answers so far, oldest first.
        @MainActor func replies() -> [String] {
            ((try? ModelContext(store).fetch(FetchDescriptor<ChatMessage>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
                .filter { $0.sender == "ai" }.map(\.text)
        }
    }

    static func metaChat(on service: AgentService, licence: String) throws -> MetaChat {
        let store = try ModelContainer(for: Schema([
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let executor = ChatToolExecutor()
        executor.configure(modelContainer: store)
        executor.canRunErrands = { service.canRunErrands }
        executor.startErrand = { goal, origin, output, _ in service.start(goal: goal, origin: origin, output: output) }
        let chat = ChatService()
        chat.configure(modelContainer: store)
        chat.toolExecutor = executor
        chat.hasLLMAccess = { true }
        chat.proLicenseKey = { licence }
        chat.observeErrands(service.events)
        return MetaChat(service: chat, store: store, executor: executor)
    }

    // MARK: - The facts (№ 132, 227)

    private static func facts(of chrome: BenchChrome, eyes: CDPConnection, link: ChromeLink) async -> BenchFacts {
        let version = try? await eyes.send("Browser.getVersion")
        var names: [String: Set<String>] = [:]
        for cookie in (try? await eyes.send("Storage.getCookies"))?["cookies"]?.array ?? [] {
            // Names only: a cookie's value never leaves this loop.
            guard let domain = cookie["domain"]?.string, let name = cookie["name"]?.string else { continue }
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard host == "google.com" || host.hasSuffix(".google.com") || host.hasPrefix("google.")
                    || host.contains(".google.") else { continue }
            names[domain, default: []].insert(name)
        }
        return BenchFacts(chrome: version?["product"]?.string ?? "unknown", portOpened: true,
                          screenLocked: BenchFront.screenLocked(),
                          googleCookieNames: names.mapValues { $0.sorted() },
                          showTab: BenchChrome.headless ? nil : await showTab(link: link, chrome: chrome))
    }

    /// Show tab as the card's button does it — the bridge's `show`, which
    /// fronts the agent's tab and brings the browser forward — on a tab the
    /// agent opened at its start page.
    private static func showTab(link: ChromeLink, chrome: BenchChrome) async -> BenchFront.Shown? {
        guard let bridge = await link.errandBridge(), let tab = try? await bridge.openTab(Self.startPage) else {
            return nil
        }
        try? await Task.sleep(for: .seconds(3))
        let before = BenchFront.now()
        await bridge.show(tab)
        try? await Task.sleep(for: .seconds(2))
        let shown = BenchFront.Shown(asked: true, before: before, after: BenchFront.now(),
                                     chrome: chrome.process.processIdentifier)
        try? await bridge.closeTab(tab)
        return shown
    }

    /// What the test profile keeps of each of `hosts` — storage, caches, cookies — cleared, as before a first visit.
    /// Cookies are a domain's, not an origin's: each one of a host, or of a domain above it, is set to have expired
    /// (2026-10-21: `Storage.clearDataForOrigin` left demowebshop's customer cookie, and its cart). One that could not
    /// be cleared is said in the run's log: its errand may start with what earlier runs left (Codex review of
    /// 2026-10-21, P2).
    private static func clearSites(_ hosts: [String], _ eyes: CDPConnection) async {
        guard !hosts.isEmpty else { return }
        for host in hosts {
            for scheme in ["https", "http"] {
                do {
                    _ = try await eyes.send("Storage.clearDataForOrigin",
                                            params: ["origin": .string("\(scheme)://\(host)"), "storageTypes": "all"])
                } catch {
                    print("[Bench] the site data of \(scheme)://\(host) was not cleared: \(error)")
                }
            }
        }
        do {
            let cookies = try await eyes.send("Storage.getCookies")["cookies"]?.array ?? []
            let expired: [CDPValue] = cookies.compactMap { cookie in
                guard var fields = cookie.object, let domain = cookie["domain"]?.string else { return nil }
                let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
                guard hosts.contains(where: { $0 == bare || $0.hasSuffix("." + bare) }) else { return nil }
                fields["expires"] = .number(1)
                return .object(fields.filter { ["name", "value", "domain", "path", "secure", "httpOnly", "sameSite",
                                                "expires"].contains($0.key) })
            }
            if !expired.isEmpty { _ = try await eyes.send("Storage.setCookies", params: ["cookies": .array(expired)]) }
            print("[Bench] cookies cleared for \(hosts.joined(separator: ", ")): \(expired.count)")
        } catch {
            print("[Bench] the cookies of \(hosts.joined(separator: ", ")) were not cleared: \(error)")
        }
    }

    /// The browser's page targets: the agent's tabs come and go with its errands.
    private static func pages(_ eyes: CDPConnection) async -> Int {
        ((try? await eyes.send("Target.getTargets"))?["targetInfos"]?.array ?? [])
            .filter { $0["type"]?.string == "page" }.count
    }

    private static func write(_ value: some Encodable, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: file, options: .atomic)
    }

    private static func append(_ text: String, to file: URL) {
        let data = Data(text.utf8)
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try? data.write(to: file)
            return
        }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}

/// The test Chrome profile in a visible window with remote debugging on — never
/// the user's own Chrome or profile — and a folder for `ChromeLink` whose only
/// browser profile is it. Started by the app's own launcher, `AgentChrome`
/// (ITER-076 stage 4b) — through LaunchServices, as the agent's own window
/// is. It ends with the bench; the profile is never removed.
@MainActor
final class BenchChrome {
    static let profile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MetaWhisp-AgentTest/chrome-profile", isDirectory: true)

    let process: any StartedChrome
    let endpoint: DevToolsEndpoint
    /// `ChromeLink`'s Application Support: `Google/Chrome` in it is the test profile.
    let root: URL

    private init(process: any StartedChrome, endpoint: DevToolsEndpoint, root: URL) {
        self.process = process
        self.endpoint = endpoint
        self.root = root
    }

    /// METAWHISP_BENCH_HEADLESS=1: the bench's Chrome shows nothing on screen.
    static var headless: Bool { ProcessInfo.processInfo.environment["METAWHISP_BENCH_HEADLESS"] == "1" }

    static func launch() async throws -> BenchChrome {
        let fm = FileManager.default
        try XCTSkipUnless(AgentChrome.installed() != nil, "needs Google Chrome")
        guard fm.fileExists(atPath: profile.path) else { throw BenchStop("the test Chrome profile is not there") }
        guard !ChromeLink.isRunning(profile: profile) else { throw BenchStop("a Chrome already runs the test profile") }
        let root = fm.temporaryDirectory.appendingPathComponent("metawhisp-bench-link-\(UUID().uuidString)",
                                                               isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("Google", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Google/Chrome"), withDestinationURL: profile)
        // In a window, and ending with the bench: a bench cut short leaves no
        // browser behind. The port is the one this start opened. With
        // METAWHISP_BENCH_HEADLESS=1 nothing of it shows on screen — a child
        // process of the run, headless — so the bench runs while the owner
        // works at the Mac (2026-10-15).
        let chrome = headless ? AgentChrome(root: root, headless: true, launch: .childProcess, endsWith: getpid())
            : AgentChrome(root: root, endsWith: getpid())
        do {
            let endpoint = try await chrome.start()
            guard let process = chrome.started else { throw AgentChrome.StartFailure.noPort }
            return BenchChrome(process: process, endpoint: endpoint, root: root)
        } catch {
            if let started = chrome.started { kill(started.processIdentifier, SIGTERM) }
            unlink(root.appendingPathComponent("Google/Chrome").path)
            rmdir(root.appendingPathComponent("Google").path)
            rmdir(root.path)
            throw BenchStop("the remote-debugging port did not open on the test profile: \(error)")
        }
    }

    /// Closes this Chrome as a user would — `Browser.close` — and ends it if it
    /// does not go. The link's folder goes: its link to the profile alone,
    /// never what it points to.
    func close() async {
        if !process.isTerminated {
            let connection = CDPConnection(url: endpoint.webSocketURL)
            if (try? await connection.open(allowLimit: .seconds(5))) != nil {
                _ = try? await connection.send("Browser.close", timeout: .seconds(5))
            }
            await connection.close()
        }
        for (wait, end) in [(15.0, false), (10.0, true)] {
            if end, !process.isTerminated { kill(process.processIdentifier, SIGTERM) }
            let deadline = Date().addingTimeInterval(wait)
            while !process.isTerminated, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        }
        unlink(root.appendingPathComponent("Google/Chrome").path)
        rmdir(root.appendingPathComponent("Google").path)
        rmdir(root.path)
    }
}

struct BenchStop: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The licence as the app keeps it: the production app's keychain item
/// (`LicenseService`'s account), read with every keychain prompt off, so a
/// read that would need the owner's Allow fails at once with its status
/// instead of waiting on a hidden prompt (ITER-053.1). The value is never
/// printed, logged or written.
extension AgentLiveBenchTests {
    /// Where the bench's errands start: METAWHISP_BENCH_START (a web address) when set — another search engine
    /// while Google asks this Mac for a CAPTCHA (2026-10-06) — else the app's own start page.
    static var startPage: URL {
        ProcessInfo.processInfo.environment["METAWHISP_BENCH_START"].flatMap(URL.init(string:))
            .flatMap { DiaScript.isOpenable($0) ? $0 : nil } ?? AgentRun.startPage
    }
}

enum BenchLicence {
    static func read() -> (key: String?, status: OSStatus) {
        // The owner's own run (`work/bench-run.sh`): `security` reads the item
        // under his eyes — its prompt, if any, is his — and hands it to this
        // process alone through the environment.
        if let given = ProcessInfo.processInfo.environment["METAWHISP_BENCH_LICENCE"], !given.isEmpty {
            return (given, errSecSuccess)
        }
        typealias SetAllowed = @convention(c) (UInt8) -> OSStatus
        // `SecKeychainSetUserInteractionAllowed`: exported by Security, gone from its headers.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainSetUserInteractionAllowed") else {
            return (nil, errSecUnimplemented)
        }
        let setAllowed = unsafeBitCast(symbol, to: SetAllowed.self)
        _ = setAllowed(0)
        defer { _ = setAllowed(1) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppIdentity(bundleIdentifier: AppIdentity.productionBundleID).keychainService,
            kSecAttrAccount as String: "com.metawhisp.licenseKey",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        let key = (out as? Data).flatMap { String(data: $0, encoding: .utf8) }
        return (key?.isEmpty == false ? key : nil, status)
    }
}

/// Every call the bench's service makes to the Pro server, seen on its way
/// back for its numbers and kinds alone — never a prompt, a page or an answer.
final class BenchTap: @unchecked Sendable {
    struct Call: Encodable {
        /// `agent`, `decisions` or `errand-report`.
        let route: String
        let purpose: String?
        /// The HTTP status; -1 when no answer came.
        let status: Int
        let ms: Int
        /// The agent route's `cost_usd` — nil when it gave none — or Jev's
        /// input tokens at Jev's price, as the app counts them.
        let usd: Double?
        let inputTokens: Int?
        let outputTokens: Int?
        let toolCalls: Int?
        let provider: String?
        let model: String?
    }

    private let lock = NSLock()
    private var kept: [Call] = []
    var calls: [Call] { lock.withLock { kept } }
    /// The agent route's model arm the bench names (`groq`, `minimax`,
    /// `gemini`), or nil: the server's own (2026-10-06, the brains compared).
    let arm: String?

    init(arm: String? = nil) {
        self.arm = arm.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `request`, naming the bench's arm when it goes to the agent route.
    private func armed(_ request: URLRequest) -> URLRequest {
        guard let arm, request.url?.lastPathComponent == "agent", let data = request.httpBody,
              var body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return request }
        body["provider"] = arm
        var named = request
        named.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return named
    }

    /// The app's own send, seen.
    var send: JevEngine.Send {
        { [self] request in
            let began = ContinuousClock.now
            let route = request.url?.lastPathComponent ?? ""
            let purpose = request.httpBody.flatMap { try? CDPValue.decode(String(decoding: $0, as: UTF8.self)) }?["purpose"]?.string
            let ms = { Int((ContinuousClock.now - began) / .milliseconds(1)) }
            do {
                let (data, response) = try await URLSession.shared.data(for: armed(request))
                trace(armed(request), data)
                let body = try? CDPValue.decode(String(decoding: data, as: UTF8.self))
                let input = body?["usage"]?["input_tokens"]?.int
                let usd = route == "decisions" ? input.map { Double($0) * JevDecisionEngine.usdPerInputToken }
                    : body?["cost_usd"]?.double
                note(Call(route: route, purpose: purpose, status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                          ms: ms(), usd: usd, inputTokens: input, outputTokens: body?["usage"]?["output_tokens"]?.int,
                          toolCalls: body?["tool_calls"]?.array?.count, provider: body?["provider"]?.string,
                          model: body?["model"]?.string))
                return (data, response)
            } catch {
                note(Call(route: route, purpose: purpose, status: -1, ms: ms(), usd: nil, inputTokens: nil,
                          outputTokens: nil, toolCalls: nil, provider: nil, model: nil))
                throw error
            }
        }
    }

    private func note(_ call: Call) { lock.withLock { kept.append(call) } }

    /// METAWHISP_BENCH_TRACE: a local file each request and its answer go to whole, one JSON line each, to read a
    /// run after it — what the model named and what Jev chose (2026-10-07). Off unless named; never in a record.
    private static let traceFile: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["METAWHISP_BENCH_TRACE"], !path.isEmpty else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    private func trace(_ request: URLRequest, _ data: Data?) {
        guard let file = Self.traceFile else { return }
        let line: [String: Any] = [
            "route": request.url?.lastPathComponent ?? "",
            "request": request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull(),
            "answer": data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull(),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: line) else { return }
        lock.withLock {
            file.write(json)
            file.write(Data("\n".utf8))
        }
    }
}

/// What the bench saw of one errand beside its record.
@MainActor
final class BenchErrand {
    var id = UUID()
    /// The first errand the service spoke of: the one MetaChat started.
    var seenID: UUID?
    /// The voice island's id for the spoken question that started it, when it was spoken.
    var question: UUID?
    var outcome: ErrandOutcome?
    var seconds = 0.0
    /// The operation of each Yes asked — each answered No.
    var yesAsked: [String] = []
    /// Each Yes question as the bench saw it, and what the bench answered (2026-10-19).
    var questions: [String] = []
    var yesGiven: [Bool] = []
    /// The kind of each pause, and of each hand-over that ended it.
    var pauses: [String] = []
    var handOvers: [String] = []
    var showTab: BenchFront.Shown?
    var stoppedByBench: String?
}

/// The app in front of the user's, as Launch Services says, and whether the
/// screen is locked.
enum BenchFront {
    struct App: Encodable {
        let pid: Int32?
        let bundleID: String?
    }

    struct Shown: Encodable {
        /// Whether the service took the Show tab.
        let asked: Bool
        let before: App
        let after: App
        let chromeInFrontAfter: Bool

        init(asked: Bool, before: App, after: App, chrome: Int32) {
            self.asked = asked
            self.before = before
            self.after = after
            chromeInFrontAfter = after.pid == chrome
        }
    }

    static func now() -> App {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/usr/bin/lsappinfo info -only pid -only bundleid \"$(/usr/bin/lsappinfo front)\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return App(pid: nil, bundleID: nil) }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        var fields: [String: String] = [:]
        for line in String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.replacingOccurrences(of: "\"", with: "") }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return App(pid: fields["pid"].flatMap { Int32($0) }, bundleID: fields["CFBundleIdentifier"])
    }

    static func screenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

struct BenchFacts: Encodable {
    let chrome: String
    let portOpened: Bool
    let screenLocked: Bool
    /// By cookie domain: names only, never a value.
    let googleCookieNames: [String: [String]]
    let showTab: BenchFront.Shown?

    var summary: String {
        let names = googleCookieNames.keys.sorted().map { domain in
            domain + ": " + (googleCookieNames[domain] ?? []).joined(separator: ",")
        }
        var shown = "no tab"
        if let showTab {
            shown = "front " + (showTab.before.bundleID ?? "?") + " -> " + (showTab.after.bundleID ?? "?")
                + ", chrome in front " + String(showTab.chromeInFrontAfter)
        }
        return chrome + "; port opened; screen locked " + String(screenLocked) + "; google cookies ["
            + names.joined(separator: "; ") + "]; show tab: " + shown
    }
}

/// One errand's numbers: its record for `s3c-<n>.json` — kinds and numbers,
/// no page text, no typed value — and its line for `s3-measures.md`.
@MainActor
struct BenchMeasure {
    struct Record: Encodable {
        let errand: Int
        /// Where the errand was asked for, by its kind alone — `chat` or `voice` — or nil: no record was kept.
        let origin: String?
        let ending: String
        let failure: String?
        let notRun: String?
        let seconds: Double
        let answerItems: Int
        let answerItemsWithLink: Int
        /// How far the Sheet's rows got — `created`, `pasted`, `verified` (read back as pasted) — or nil: no
        /// Sheet was made (ITER-076 stage 6, № 243).
        let sheet: String?
        /// How the Sheet the user asked for failed, when it did.
        let sheetFailure: String?
        let sources: Int
        let steps: Int
        let tabsLeft: Int
        let yesAsked: [String]
        let pauses: [String]
        let handOvers: [String]
        let showTab: BenchFront.Shown?
        let stoppedByBench: String?
        let spentUSD: Double?
        let calls: [BenchTap.Call]
        /// The record as a failed errand's report carries it.
        let report: CDPValue?
        /// Each read of a page, as the record keeps it: what ended it, the
        /// lines the page gave and what the read met (ITER-076 stage 4a).
        let reads: [ErrandRecord.Event.Read]
        /// Each step's own numbers: Jev's confidences and the targets offered.
        let stepNumbers: [BenchStep]
    }

    /// A step by its kinds and numbers alone — no fingerprint (stage 4a).
    struct BenchStep: Encodable {
        let op: String
        let role: String?
        let outcome: String
        let confidence: Double?
        let operationConfidence: Double?
        let targetConfidence: Double?
        let targets: Int?
    }

    static let header = "| # | goal | ending | answer items | sheet | steps | Jev calls | model calls by purpose "
        + "| served by | reads | seconds | dollars | first failure |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
    static let purposes = ProLLMClient.Request.Purpose.allCases.map(\.rawValue)

    let record: Record
    let line: String
    let summary: String
    /// A model route that broke its contract — no `cost_usd`, or a request the
    /// server refused — which stops the bench.
    let brokenRoute: String?

    init(number: Int, goal: String, errand: BenchErrand, saved: ErrandRecordStore.Saved?, calls: [BenchTap.Call],
         tabsLeft: Int) {
        let outcome = saved?.outcome ?? errand.outcome
        let kept = saved?.record
        // The answer's items, as the record gives them: the facts that answer
        // a requirement — and, short of done, every fact read — each once.
        let answering = (kept?.facts ?? []).filter { outcome?.ending != .done || !$0.requirements.isEmpty }
        var shown: Set<[String]> = []
        let items = answering.filter { shown.insert([$0.quote, $0.url]).inserted }
        let model = calls.filter { $0.route == "agent" }
        let jev = calls.filter { $0.route == "decisions" }
        let byPurpose = Self.purposes.compactMap { purpose -> String? in
            let these = model.filter { $0.purpose == purpose }
            guard !these.isEmpty else { return nil }
            let failed = these.filter { !(200..<300).contains($0.status) }.map { "\($0.status)" }
            return "\(purpose) \(these.count)" + (failed.isEmpty ? "" : " (\(failed.joined(separator: ",")))")
        }
        // The models that answered the agent calls, as each answer named itself — the arm the bench asked for may
        // be answered by another (2026-10-07) — each with its count; a call no model answered, as such.
        let served = Dictionary(model.map { call -> (String, Int) in
            let named = [call.provider, call.model].compactMap { $0 }.joined(separator: ":")
            return (named.isEmpty ? "no answer" : named, 1)
        }, uniquingKeysWith: +)
        let servedBy = served.keys.sorted().map { "\($0) \(served[$0] ?? 0)" }.joined(separator: " · ")
        let modelUSD = model.compactMap(\.usd).reduce(0, +)
        let jevUSD = jev.compactMap(\.usd).reduce(0, +)
        let nulls = model.filter { (200..<300).contains($0.status) && $0.usd == nil }
        let refused = calls.first { [400, 401, 413, 429].contains($0.status) }
        let miss = kept?.events.first { if case .pageMiss = $0 { true } else { false } }
        let failed = calls.first { !(200..<300).contains($0.status) }
        var firstFailure = "—"
        if let failure = outcome?.failure {
            firstFailure = "failure " + failure.rawValue
        } else if let failed {
            firstFailure = failed.route + " " + (failed.purpose ?? "") + " status " + String(failed.status)
        } else if let miss {
            firstFailure = miss.line
        } else if let why = errand.stoppedByBench {
            firstFailure = "stopped by the bench: " + why
        }
        var dollars = String(format: "$%.4f (model $%.4f, Jev $%.4f)", modelUSD + jevUSD, modelUSD, jevUSD)
        if !nulls.isEmpty { dollars += "; cost_usd null on \(nulls.count) of \(model.count)" }
        if let spent = kept?.spentUSD { dollars += String(format: "; record $%.4f", spent) }
        let ending = outcome?.ending.rawValue ?? "none"
        let reads = model.filter { $0.purpose == "read" }.count
        let steps = kept?.steps.count ?? 0
        let linked = items.filter { URL(string: $0.url)?.scheme?.hasPrefix("http") == true }.count
        // What became of the Sheet the user asked for (ITER-076 stage 6, № 243): how far its rows got, and how
        // it failed.
        let sheet = kept?.sheetWrite?.rawValue
        let sheetFailure = outcome?.sheetFailure?.rawValue
        let sheetCell = (sheet ?? "none") + (sheetFailure.map { "/" + $0 } ?? "")
        let report = kept.map { ErrandReporter.report(of: $0, appVersion: "0") }
        let readsKept = (kept?.events ?? []).compactMap { if case .read(let read) = $0 { read } else { nil } }
        let stepNumbers = (kept?.steps ?? []).map {
            BenchStep(op: $0.operation, role: $0.targetRole, outcome: $0.outcome.rawValue, confidence: $0.confidence,
                      operationConfidence: $0.operationConfidence, targetConfidence: $0.targetConfidence,
                      targets: $0.targets)
        }
        let origin: String? = saved.map { if case .voice = $0.origin { "voice" } else { "chat" } }
        record = Record(errand: number, origin: origin, ending: ending, failure: outcome?.failure?.rawValue,
                        notRun: outcome?.notRun?.rawValue, seconds: errand.seconds, answerItems: items.count,
                        answerItemsWithLink: linked, sheet: sheet, sheetFailure: sheetFailure,
                        sources: outcome?.sources.count ?? 0, steps: steps,
                        tabsLeft: tabsLeft, yesAsked: errand.yesAsked, pauses: errand.pauses,
                        handOvers: errand.handOvers, showTab: errand.showTab, stoppedByBench: errand.stoppedByBench,
                        spentUSD: kept?.spentUSD, calls: calls, report: report, reads: readsKept,
                        stepNumbers: stepNumbers)
        let purposes = byPurpose.joined(separator: " · ")
        let seconds = String(format: "%.1f", errand.seconds)
        let cells: [String] = ["\(number)", goal, ending, "\(items.count)", sheetCell, "\(steps)", "\(jev.count)",
                               purposes, servedBy, "\(reads)", seconds, dollars, firstFailure]
        line = "| " + cells.joined(separator: " | ") + " |\n"
        let counts = "ending=\(ending) items=\(items.count) linked=\(linked) sources=\(record.sources) steps=\(steps)"
            + " sheet=\(sheetCell) origin=\(origin ?? "none")"
        let spend = " jev=\(jev.count) model=[\(purposes)] served=[\(servedBy)] reads=\(reads) s=\(seconds) \(dollars)"
        let seen = " yes=\(errand.yesAsked.count) pauses=\(errand.pauses) tabsLeft=\(tabsLeft) first=\(firstFailure)"
        // How each read of a page ended, with the lines it gave (stage 4a).
        let readEnds = readsKept.map { $0.end.rawValue + ($0.blocks.map { ":\($0)" } ?? "") }.joined(separator: ",")
        summary = counts + spend + seen + " readEnds=[\(readEnds)]"
        brokenRoute = nulls.first.map { "cost_usd did not come back on \($0.purpose ?? "a call")" }
            ?? refused.map { "the server refused \($0.route) \($0.purpose ?? "") with \($0.status)" }
    }
}
