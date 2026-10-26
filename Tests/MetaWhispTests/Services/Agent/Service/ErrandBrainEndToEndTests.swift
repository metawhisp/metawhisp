import Combine
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 1 — "find 10 jokes" from start to end, every seam real but
/// the far ends: the errand service ← the app's own run (`AgentRun.answering`)
/// ← Jev through `JevDecisionEngine` and `JevEngine`, scripted over a
/// recorded transport, and the planner, sub-goals, a field's text, the reader
/// and the verifier through `ProLLMClient`, over a recorded model transport ←
/// the fixture browser on a search site and two pages of jokes, six and four.
/// MetaChat's text is what `ChatService` writes for the outcome.
@MainActor
final class ErrandBrainEndToEndTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("mw-brain-e2e-\(UUID().uuidString)", isDirectory: true)
    private var watch: AnyCancellable?

    override func tearDown() {
        watch = nil
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private static let goal = "Find 10 jokes"
    private static let start = URL(string: "https://site-407.test/")!
    private static let sixJokes = URL(string: "https://site-408.test/")!
    private static let fourJokes = URL(string: "https://site-409.test/")!
    private nonisolated static let subgoals = ["Search the web for jokes", "Open a page that lists jokes",
                                               "Open the next page of jokes"]

    /// Jev on the fixtures: on the search page, type in its box, then send
    /// it; on the results, the search is done, and the page of six jokes is
    /// opened; there, the sub-goal is done, or its link to the next page is
    /// followed; on the next page, done. Every risk question: reversible, no
    /// grant.
    private nonisolated static func jev() -> RecordedJev {
        RecordedJev { asked, _ in
            guard asked.isStep else { return .answers() }
            let page = URL(string: asked.pageURL)
            let task = asked.state["task"] as? String ?? ""
            switch (page?.host ?? "", page?.path ?? "") {
            case ("site-407.test", "/search"):
                return task == subgoals[0] ? .answers(operation: "DONE")
                    : .answers(operation: "CLICK", target: asked.key(labelled: "Six jokes"))
            case ("site-407.test", _):
                let typed = ((asked.state["elements"] as? [[String: Any]]) ?? [])
                    .first { $0["label"] as? String == "Search" }?["value"] as? String ?? ""
                return typed.isEmpty ? .answers(operation: "TYPE_TEXT", target: asked.key(labelled: "Search"))
                    : .answers(operation: "CLICK", target: asked.key(labelled: "Search 407"))
            case ("site-408.test", _) where task == subgoals[2]:
                return .answers(operation: "CLICK", target: asked.key(labelled: "Four more jokes"))
            default:
                return .answers(operation: "DONE")
            }
        }
    }

    /// The text model: the plan of one information requirement; the three
    /// sub-goals, then a reply without one; "jokes" for the search box; the
    /// reader of the two pages; and each verdict from `verdict`, by its
    /// number from 0. At sub-goal call `stopAt`, `stop` is called and the
    /// answer comes late.
    private nonisolated static func model(verdict: @escaping @Sendable (Int) -> RecordedModel.Reply,
                                          stopAt: Int? = nil, stop: @escaping @Sendable () -> Void = {}) -> RecordedModel {
        RecordedModel { asked, n in
            switch asked.purpose {
            case "plan": return .text(RecordedModel.plan([("r1", "Find 10 jokes", "information")]))
            case "subgoal":
                let reply: RecordedModel.Reply = n < subgoals.count ? .calls([RecordedModel.goal(subgoals[n])]) : .text("Done.")
                guard n == stopAt else { return reply }
                stop()
                return .after(.seconds(5), reply)
            case "field_text": return .text(#"{"text": "jokes"}"#)
            case "read": return RecordedModel.readsSixThenFour(asked)
            case "verify": return verdict(n)
            default: return .status(400)
            }
        }
    }

    /// The errand service with the app's run, made of the production brain
    /// fed by these transports, on the fixture browser — its Sheet, when one
    /// is asked for, `sheet`.
    private func service(_ model: RecordedModel, _ jev: RecordedJev, bridge: WebViewBridge,
                         sheet: @escaping @MainActor (any BrowserBridge) -> any SheetDestination = { _ in FixtureSheet() })
        -> AgentService {
        AgentService(link: FixedLink(bridge), keepAwake: KeepAwake(create: { 1 }, release: { _ in }),
                     store: ErrandRecordStore(directory: folder), notificationCenter: NotificationCenter(),
                     isPro: { true },
                     makeRunner: AgentRun.answering(client: model.client, engine: jev.engine, startPage: Self.start,
                                                    sheet: sheet),
                     schedule: { _, _ in }, settings: .allowedForTests)
    }

    /// Starts the errand and waits for its end: its id, its outcome, and every
    /// event it showed.
    private func runErrand(_ service: AgentService, output: ErrandOutput = .answer) async throws
        -> (UUID, ErrandOutcome, [ErrandEvent]) {
        var events: [ErrandEvent] = []
        watch = service.events.sink { events.append($0.event) }
        let id = try XCTUnwrap(service.start(goal: Self.goal, origin: .chat(messageID: UUID()), output: output).id)
        let deadline = ContinuousClock.now + .seconds(90)
        while !events.contains(where: { if case .finished = $0 { true } else { false } }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .finished(let outcome)? = events.last else {
            XCTFail("no end: \(events)")
            throw CancellationError()
        }
        return (id, outcome, events)
    }

    /// Each joke with its page's link, in order.
    private static let tenWithLinks = RecordedModel.tenJokes.enumerated().map {
        $0.element + "\n" + ($0.offset < 6 ? sixJokes : fourJokes).absoluteString
    }
    private static let sources = "Sources:\n1. https://site-408.test/\n2. https://site-409.test/"
    /// A done errand's answer (2026-10-15): the reader's claim for r1 in its words with the pages it rests on, then
    /// the ten, each the page's own words with its link.
    private static let stated = (["MODEL-WORDS-ALL\nhttps://site-408.test/\nhttps://site-409.test/"] + tenWithLinks)
        .joined(separator: "\n\n")

    /// № 224: the search is typed and sent without a Yes — as its typing
    /// ends (D4, 2026-10-07) — six jokes are read
    /// on one page and four on the next, the verifier says done — and the
    /// answer holds the ten, each with its page's link; the sources are those
    /// two pages; MetaChat shows them.
    func testFindTenJokesFromTheSearchToTheAnswer() async throws {
        let model = Self.model(verdict: { _ in RecordedModel.verdict(complete: true) })
        let jev = Self.jev()
        let bridge = WebViewBridge()
        let (_, outcome, events) = try await runErrand(service(model, jev, bridge: bridge))

        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.answer, Self.stated)
        XCTAssertEqual(outcome.sources, [Self.sixJokes, Self.fourJokes])
        XCTAssertEqual(ChatService.errandResultText(outcome), Self.stated + "\n\n" + Self.sources)
        XCTAssertFalse(events.contains { if case .needsYes = $0 { true } else { false } }, "no Yes for the search")
        XCTAssertTrue(bridge.navigatedURLs.contains(URL(string: "https://site-407.test/search?q=jokes")!),
                      "\(bridge.navigatedURLs)")
        XCTAssertEqual(model.requests("plan").count, 1)
        XCTAssertEqual(model.requests("field_text").count, 1)
        XCTAssertEqual(model.requests("read").count, 3, "the results, then each page of jokes")
        XCTAssertEqual(model.requests("verify").count, 1, "the verdict decided, once r1 had its claim")
        XCTAssertEqual(model.requests("subgoal").count, 3)
        let verdictAsked = try XCTUnwrap(model.requests("verify").first?.contents.last ?? nil)
        XCTAssertTrue(verdictAsked.contains("""
            ## Steps taken
            - type Search = 'jokes' -> executed (changed Search value: empty -> jokes)
            - click site-407.test -> executed (went to https://site-407.test/search?q=jokes; changed Search value: jokes -> empty; showed 4 controls: Search, Search 407, Six jokes, Four jokes; removed 2 controls: Search, Search 407)
            - click Six jokes -> executed (went to https://site-408.test/; showed 1 control: Four more jokes; removed 4 controls: Search, Search 407, Six jokes, Four jokes)
            - click Four more jokes -> executed (went to https://site-409.test/; removed 1 control: Four more jokes)

            ## Set controls
            []

            ## Where each requirement's facts were read
            - r1: https://site-408.test/, https://site-409.test/

            ## Visited addresses
            - https://site-407.test/
            - https://site-407.test/search?q=jokes
            - https://site-408.test/
            - https://site-409.test/

            ## Page
            https://site-409.test/
            """), verdictAsked)
        XCTAssertTrue(jev.requests.contains { $0.isStep }, "Jev chose the steps")
        XCTAssertEqual(bridge.openTabCount, 0, "no tab left open")
    }

    /// ITER-076 stage 6 (№ 50, 168, 169, 243): "find 10 jokes" asked for in a
    /// table — MetaChat's model said so as it started the errand — puts the
    /// answer into a new Sheet as well: a header, then the ten, each with its
    /// page's link, read back as pasted. MetaChat shows the answer, the
    /// sources, and the Sheet.
    func testATableRequestPutsTheAnswerIntoANewSheet() async throws {
        let fixture = FixtureSheet()
        let model = Self.model(verdict: { _ in RecordedModel.verdict(complete: true) })
        let (_, outcome, _) = try await runErrand(service(model, Self.jev(), bridge: WebViewBridge(),
                                                          sheet: { _ in fixture }), output: .sheet)

        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.answer, Self.stated)
        let sheet = try XCTUnwrap(outcome.sheet)
        let rows = RecordedModel.tenJokes.enumerated().map {
            [$0.element, ($0.offset < 6 ? Self.sixJokes : Self.fourJokes).absoluteString]
        }
        let written = try await fixture.readBack(sheet)
        XCTAssertEqual(written.cells, [["Result", "Source"]] + rows)
        XCTAssertEqual(fixture.title, Self.goal, "named after the user's own words")
        XCTAssertNil(outcome.sheetFailure)
        XCTAssertEqual(ChatService.errandResultText(outcome), Self.stated + "\n\n" + Self.sources + "\n\nSheet: "
                       + sheet.absoluteString)
    }

    /// The same errand without a table asked for: the answer alone, no Sheet.
    func testWithoutATableRequestNoSheetIsMade() async throws {
        let fixture = FixtureSheet()
        let model = Self.model(verdict: { _ in RecordedModel.verdict(complete: true) })
        let (_, outcome, _) = try await runErrand(service(model, Self.jev(), bridge: WebViewBridge(),
                                                          sheet: { _ in fixture }))
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertNil(outcome.sheet)
        XCTAssertNil(fixture.title, "no Sheet was made")
    }

    /// The verifier's verdict decides: told twice that r1 is missing — once r1
    /// has its claim, and when the model stops — the errand ends not
    /// finished, with what it found: the ten, and what else it read.
    func testTheVerifiersNoEndsItNotFinishedWithWhatItFound() async throws {
        let model = Self.model(verdict: { _ in RecordedModel.verdict(complete: false, missing: ["r1"]) })
        let (_, outcome, _) = try await runErrand(service(model, Self.jev(), bridge: WebViewBridge()))

        XCTAssertEqual(outcome.ending, .notFinished)
        XCTAssertEqual(model.requests("verify").count, 2)
        XCTAssertEqual(model.requests("subgoal").count, 6, "three sub-goals, the model's end and two ends rejected")
        let found = (Self.tenWithLinks + ["Six jokes\nhttps://site-408.test/"]).joined(separator: "\n\n")
        XCTAssertEqual(outcome.answer, found)
        XCTAssertEqual(outcome.sources, [Self.sixJokes, Self.fourJokes])
        XCTAssertEqual(ChatService.errandResultText(outcome),
                       ChatService.notFinishedLine + "\n\n" + found + "\n\n" + Self.sources)
    }

    /// Stop in the middle — after the first page of jokes was read, while the
    /// model is asked for the next sub-goal — ends the errand at once, and
    /// MetaChat still gets what was found.
    func testStopInTheMiddleKeepsWhatWasFound() async throws {
        let box = Box<(AgentService, UUID)>()
        let model = Self.model(verdict: { _ in RecordedModel.verdict(complete: true) }, stopAt: 2, stop: {
            Task { @MainActor in
                guard let (service, id) = box.value else { return }
                service.stop(id)
            }
        })
        let service = service(model, Self.jev(), bridge: WebViewBridge())
        var events: [ErrandEvent] = []
        watch = service.events.sink { events.append($0.event) }
        let id = try XCTUnwrap(service.start(goal: Self.goal, origin: .chat(messageID: UUID())).id)
        box.value = (service, id)
        let deadline = ContinuousClock.now + .seconds(90)
        while !events.contains(where: { if case .finished = $0 { true } else { false } }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .finished(let outcome)? = events.last else { return XCTFail("no end: \(events)") }

        XCTAssertEqual(outcome.ending, .stopped)
        let found = (["Six jokes"] + RecordedModel.tenJokes.prefix(6)).map { $0 + "\nhttps://site-408.test/" }
            .joined(separator: "\n\n")
        XCTAssertEqual(outcome.answer, found, "the first page's jokes, read before Stop")
        XCTAssertEqual(outcome.sources, [Self.sixJokes])
        XCTAssertEqual(ChatService.errandResultText(outcome),
                       "Stopped.\n\n" + found + "\n\nSources:\n1. https://site-408.test/")
        XCTAssertEqual(model.requests("verify").count, 0)
    }

    /// ITER-076 stage 2, № 242: the errand's card on the app's own run shows
    /// each state the errand passes through — the browser ready and the plan
    /// made, the work under the user's own words (an answer has no rows to
    /// count), the end in MetaChat's line, the answer kept in MetaChat.
    func testTheCardShowsTheErrandFromItsStartToItsEnd() async throws {
        let service = service(Self.model(verdict: { _ in RecordedModel.verdict(complete: true) }), Self.jev(),
                              bridge: WebViewBridge())
        let stack = ErrandCardStack(schedule: { _, _ in })
        stack.observe(service.events, service: service, openSheet: { _ in }, openResult: { _ in })
        var shown: [String] = []
        let watching = stack.$cards.sink { cards in
            guard let card = cards.first else { return }
            let line = card.label + " | " + card.title
            if shown.last != line { shown.append(line) }
        }
        defer { watching.cancel() }
        let (id, outcome, _) = try await runErrand(service)

        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(shown, ["Planning | Planning the errand", "Working | Find 10 jokes", "Done | Done."])
        let card = try XCTUnwrap(stack.cards.first { $0.id == id })
        XCTAssertEqual(card.body, "The answer is in MetaChat.")
        XCTAssertEqual(card.buttons.map(\.label), ["Open in MetaChat"])
        XCTAssertTrue(card.hasEnded)
    }

    /// ITER-076 stage 2, № 242: Stop pressed on the card, while the model is
    /// asked for the next sub-goal, ends the errand within a second: the card
    /// says so once the service does, nothing more is asked, and what was
    /// found stays in MetaChat.
    func testStopFromTheCardEndsTheErrandWithinASecond() async throws {
        let stack = ErrandCardStack(schedule: { _, _ in })
        let errand = Box<UUID>()
        let pressed = Box<ContinuousClock.Instant>()
        let model = Self.model(verdict: { _ in RecordedModel.verdict(complete: true) }, stopAt: 2, stop: {
            Task { @MainActor in
                guard let id = errand.value else { return }
                pressed.value = .now
                stack.press(.stop, on: id)
            }
        })
        let service = service(model, Self.jev(), bridge: WebViewBridge())
        stack.observe(service.events, service: service, openSheet: { _ in }, openResult: { _ in })
        var ended: ContinuousClock.Instant?
        let watching = stack.$cards.sink { cards in
            if ended == nil, cards.first?.hasEnded == true { ended = .now }
        }
        defer { watching.cancel() }
        let id = try XCTUnwrap(service.start(goal: Self.goal, origin: .chat(messageID: UUID())).id)
        errand.value = id
        let deadline = ContinuousClock.now + .seconds(90)
        while ended == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }

        let when = try XCTUnwrap(pressed.value, "the premise: Stop was pressed on the card")
        let end = try XCTUnwrap(ended, "the card ended")
        XCTAssertLessThan(end - when, .seconds(1), "the errand ended within a second of Stop")
        let asked = model.requests.count
        let card = try XCTUnwrap(stack.cards.first { $0.id == id })
        XCTAssertEqual(card.label, "Stopped")
        XCTAssertEqual(card.title, "Stopped.")
        XCTAssertEqual(card.body, "The answer is in MetaChat.", "what was found before Stop is kept")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.requests.count, asked, "nothing is asked after Stop")
    }

    /// № 43: one factory, so one planner, model and Jev for every errand —
    /// none of them keeps anything of an errand: the next one's plan, first
    /// sub-goal call and first read begin from nothing.
    func testTheBrainsSharedPartsKeepNothingBetweenErrands() async throws {
        let model = RecordedModel { asked, _ in
            switch asked.purpose {
            case "plan": return .text(RecordedModel.plan([("r1", "Find 10 jokes", "information")]))
            case "subgoal": return asked.messages.count == 2 ? .calls([RecordedModel.goal("Read the jokes")]) : .text("Done.")
            case "read": return .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:2"),
                                                                                  requirement: "r1")]))
            case "verify": return RecordedModel.verdict(complete: true)
            default: return .status(400)
            }
        }
        let jev = RecordedJev { asked, _ in asked.isStep ? .answers(operation: "DONE") : .answers() }
        let make = AgentRun.answering(client: model.client, engine: jev.engine,
                                      startPage: URL(string: "https://site-404.test/")!)
        for goal in ["Find 10 jokes", "Find 10 more jokes"] {
            let run = make(ErrandSetup(id: UUID(), goal: goal, bridge: WebViewBridge(), confirm: { _ in nil }))
            let outcome = await run.run(report: { _ in })
            XCTAssertEqual(outcome.ending, .done, goal)
        }
        let plans = model.requests("plan")
        XCTAssertEqual(plans.map { $0.contents.last ?? nil }, ["# Task\nFind 10 jokes", "# Task\nFind 10 more jokes"])
        let firstCalls = model.requests("subgoal").filter { $0.messages.count == 2 }
        XCTAssertEqual(firstCalls.map { $0.contents.last ?? nil }, ["Find 10 jokes", "Find 10 more jokes"],
                       "each errand's conversation begins from its own goal alone")
        let reads = model.requests("read")
        XCTAssertEqual(reads.count, 2)
        for read in reads {
            XCTAssertTrue((read.contents.last ?? nil)?.hasPrefix("# Collected evidence\n\n\n# Capture\n") == true,
                          "nothing collected by another errand")
        }
    }

    /// № 14, 263: the app's service has a run for an errand, so a Pro user
    /// can run one, and no one else can — since U1 (owner, 2026-10-25) with
    /// the Ultra switch on: here it is on; the switch off is the next test.
    /// Pro is read as the app reads it, from the license (its keychain is
    /// empty under XCTest), and the switch from the app's own defaults, both
    /// put back after. A start is tried only on a service behind the same
    /// switch whose browser is the fixture one: never the user's Chrome,
    /// whatever breaks.
    func testTheAppsServiceRunsErrandsForAProUserOnly() async throws {
        let putBack = Self.setTheAppsSwitch(ultra: true)
        defer { putBack() }
        let license = LicenseService.shared
        // Stage 8b (8.5): MetaChat offers an errand with or without Pro; only with Pro can one start.
        license.isPro = true
        XCTAssertTrue(AgentService.shared.canStartErrands, "with Pro and the switch on, the app can run an errand")
        license.isPro = false
        XCTAssertFalse(AgentService.shared.canStartErrands, "without Pro it cannot")

        let model = Self.model(verdict: { _ in RecordedModel.verdict(complete: true) })
        let service = behindTheAppsSwitch(model)
        XCTAssertEqual(service.start(goal: Self.goal, origin: .chat(messageID: UUID())), .refused(.notPro),
                       "without Pro the start is refused")
        XCTAssertTrue(model.requests.isEmpty, "and nothing is asked")
        license.isPro = true
        let id = try XCTUnwrap(service.start(goal: Self.goal, origin: .chat(messageID: UUID())).id, "with Pro it starts")
        service.stop(id)
    }

    /// U1 (owner, 2026-10-25): the browser agent is not part of Pro. With the
    /// Ultra switch off the app's service runs no errand — for a Pro user or
    /// anyone else — and asks nothing of a model; the pair of the test above,
    /// the switch its only difference.
    func testWithTheUltraSwitchOffTheAppsServiceRunsNoErrandEvenForPro() async throws {
        let putBack = Self.setTheAppsSwitch(ultra: false)
        defer { putBack() }
        let license = LicenseService.shared
        for pro in [true, false] {
            license.isPro = pro
            XCTAssertFalse(AgentService.shared.canStartErrands, "the switch off, Pro \(pro): no errand can start")
        }

        let model = Self.model(verdict: { _ in RecordedModel.verdict(complete: true) })
        let service = behindTheAppsSwitch(model)
        license.isPro = true
        XCTAssertEqual(service.start(goal: Self.goal, origin: .chat(messageID: UUID())), .refused(.unavailable),
                       "Pro alone no longer starts an errand")
        license.isPro = false
        XCTAssertEqual(service.start(goal: Self.goal, origin: .chat(messageID: UUID())), .refused(.notPro),
                       "without Pro it is refused as before")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.requests.isEmpty, "nothing is asked")
    }

    /// A service on the fixture browser behind the switch the app's service
    /// reads (`UltraFeatures.isOn`), Pro from the license.
    private func behindTheAppsSwitch(_ model: RecordedModel) -> AgentService {
        AgentService(link: FixedLink(WebViewBridge()), keepAwake: KeepAwake(create: { 1 }, release: { _ in }),
                     store: ErrandRecordStore(directory: folder), notificationCenter: NotificationCenter(),
                     makeRunner: AgentRun.answering(client: model.client, engine: Self.jev().engine, startPage: Self.start),
                     schedule: { _, _ in }, settings: AgentSettings.allowedForTests.gated(by: { UltraFeatures.isOn() }))
    }

    /// Sets the app's Ultra switch and turns the user's own agent switch on —
    /// what the app's service reads — and gives back what puts them, and the
    /// licence's Pro, back as they were.
    private static func setTheAppsSwitch(ultra: Bool) -> @MainActor () -> Void {
        let defaults = UserDefaults.standard
        let savedSwitch = defaults.object(forKey: UltraFeatures.key)
        let settings = AppSettings.shared
        let savedAgentOn = settings.browserAgentOn
        let license = LicenseService.shared
        let savedPro = license.isPro
        defaults.set(ultra, forKey: UltraFeatures.key)
        settings.browserAgentOn = true
        return {
            if let savedSwitch { defaults.set(savedSwitch, forKey: UltraFeatures.key) } else {
                defaults.removeObject(forKey: UltraFeatures.key)
            }
            settings.browserAgentOn = savedAgentOn
            license.isPro = savedPro
        }
    }
}
