import XCTest
@testable import MetaWhisp

/// Level 3 (ITER-074 §12.1): whole errands on the fixture pages, through the
/// production loop, with a scripted engine, a fake writer and a fixture
/// sheet. Every run checks the outcomes the Definition of Done asks for, not
/// just "no crash".
final class AgentRunTests: XCTestCase {

    private func plan(search: String, rows: Int = 3) throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: "Add three competitor sites to a sheet",
                                subgoals: [.init(description: "Find a competitor's site", terms: ["voice", "notes"])],
                                searches: [URL(string: search)!], columns: ["Name", "URL", "What they do"],
                                sheetTitle: "Competitors", rowsWanted: rows, emptyCell: "n/a"))
    }

    @MainActor
    private final class Answers {
        var asked: [ConfirmationRequest] = []
    }

    // MARK: - J1 end to end

    @MainActor
    func testJ1CollectsTheSitesIntoANewSheet() async throws {
        let bridge = WebViewBridge()
        let sheet = FixtureSheet()
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }))
        let record = await run.run()

        XCTAssertEqual(record.ending, .done)
        XCTAssertEqual(record.rows.map { $0.source.host }, ["site-1.test", "site-2.test", "site-3.test"],
                       "every row keeps its source")
        XCTAssertEqual(sheet.title, "Competitors")
        let written = try await sheet.readBack(try XCTUnwrap(record.sheet))
        XCTAssertFalse(written.holdsFormula)
        XCTAssertTrue(SheetCells.readBackMatches(expected: record.rows.map(\.cells), displayed: written.cells,
                                                 empty: "n/a"))
        XCTAssertLessThanOrEqual(record.steps.count, AgentBudget.maxSteps, "within the step ceiling")
        XCTAssertTrue(record.steps.allSatisfy { $0.engine == "scripted" }, "every step picked by the engine")
        let log = String(decoding: try JSONEncoder().encode(record.steps), as: UTF8.self)
        for pageWords in ["Site One", "Record a thought", "voice notes app", "Dictation"] {
            XCTAssertFalse(log.contains(pageWords), "no page text in the step log: \(pageWords)")
        }
        XCTAssertEqual(bridge.openTabCount, 0, "no tab left open")
    }

    // MARK: - Irreversible actions

    /// Every irreversible action waits for the user's yes; a no cancels it
    /// and the form is never sent (§7.1, US-4).
    @MainActor
    func testAnIrreversibleActionWaitsForAYesAndANoCancelsIt() async throws {
        let bridge = WebViewBridge()
        let answers = Answers()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" })
        })
        let run = AgentRun(plan: try plan(search: "https://site-7.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { request in
                                                    answers.asked.append(request)
                                                    return .no
                                                }))
        let record = await run.run()

        XCTAssertFalse(answers.asked.isEmpty, "the user was asked")
        XCTAssertTrue(answers.asked.allSatisfy {
            $0.action.target?.name == "Continue" && $0.action.target?.formAction == "https://site-7.test/send-message"
        }, "about that exact action")
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/send-message" }, "the form was never sent")
        XCTAssertTrue(record.steps.contains { $0.outcome == .refused })
        XCTAssertEqual(record.ending, .stuck, "asking again and again for the same thing ends as stuck")
        XCTAssertNil(record.sheet, "nothing collected, no sheet")
        XCTAssertEqual(bridge.openTabCount, 0)
    }

    /// Silence is a No (§7.1): a question nobody answers ends at its window,
    /// and the errand goes on without the action — it never hangs.
    @MainActor
    func testSilenceEndsTheQuestionAtItsWindow() async throws {
        let bridge = WebViewBridge()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" })
        })
        let run = AgentRun(plan: try plan(search: "https://site-7.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in
                                                    try? await Task.sleep(for: .seconds(3))
                                                    return .yes
                                                }),
                           answerWindow: .milliseconds(200))
        let clock = ContinuousClock()
        let started = clock.now
        let record = await run.run()
        XCTAssertLessThan(clock.now - started, .seconds(20), "the errand did not wait for an answer that never came")
        XCTAssertTrue(record.steps.contains { $0.outcome == .refused })
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/send-message" }, "a late yes counts for nothing")
    }

    // MARK: - Walls

    /// Signing in is the user's part (§7.2, §11). Since owner decision 4 the
    /// page itself does not stop the errand; any step on its login form does:
    /// it is handed over and nothing is typed or sent.
    @MainActor
    func testALoginFormHandsTheErrandToTheUser() async throws {
        let bridge = WebViewBridge()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target != nil })
        })
        let run = AgentRun(plan: try plan(search: "https://site-5.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertEqual(record.ending, .needsUser)
        XCTAssertEqual(record.steps.map(\.outcome), [.handedOver], "the step on the login form was not taken")
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/session" })
        XCTAssertEqual(bridge.openTabCount, 0)
    }

    /// A secret field that appears between the choice and the act stops the
    /// act, and the errand is handed to the user at once (ITER-076 2.2, S3).
    @MainActor
    func testASecretFieldThatAppearsAtTheActHandsTheErrandToTheUser() async throws {
        let bridge = SecretFieldAtTheAct()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        })
        let run = AgentRun(plan: try plan(search: "https://site-26.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertEqual(record.ending, .needsUser)
        XCTAssertEqual(record.steps.map(\.outcome), [.handedOver], "the act was refused and nothing else was tried")
        XCTAssertEqual(bridge.revealText, "Show details", "nothing was clicked")
        XCTAssertEqual(bridge.inner.openTabCount, 0)
    }

    /// Review of 3.1, round 2: an act the bridge refused because the errand
    /// stopped reached nothing, and is not recorded as sent.
    @MainActor
    func testAnActRefusedForStopIsNotRecordedAsSent() async throws {
        let bridge = StopsAtTheAct()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        })
        let run = AgentRun(plan: try plan(search: "https://site-26.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertFalse(record.steps.contains { $0.operation == "click" }, "\(record.steps.map(\.outcome))")
    }

    // MARK: - Fields (ITER-076 2.3)

    /// Review of 2.3: a select's postcondition is checked in the page, even
    /// when the page rewrites its own address on the change, and the option
    /// the errand chose and saw held is not offered again on that page — the
    /// loop goes on instead of choosing it until it is stuck.
    @MainActor
    func testAChosenOptionIsCheckedInThePageAndNotOfferedAgain() async throws {
        let bridge = WebViewBridge()
        let run = AgentRun(plan: try plan(search: "https://site-67.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: Self.priceOrDone(), writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertEqual(record.steps.map(\.operation), ["select", "done"])
        XCTAssertEqual(record.steps.map(\.outcome), [.acted, .acted], "the option held, though the address changed")
        XCTAssertEqual(record.ending, .done)
        XCTAssertEqual(bridge.openTabCount, 0)
    }

    /// An engine that picks "Price" whenever it is offered, and is done
    /// otherwise.
    private static func priceOrDone() -> ScriptedEngine {
        ScriptedEngine(choice: { request in
            let price = request.candidates.first { $0.action.operation == .select && $0.action.payload == "Price" }
            return ScriptedEngine.pick(price ?? request.candidates.first { $0.action.operation == .done })
        })
    }

    /// An engine that picks "Price" whenever it is offered, opens the page's
    /// "See the list again" once when it is not — the same page, loaded anew
    /// — and is done after that.
    private final class PriceThenReopen: @unchecked Sendable {
        var reopened = 0
        var engine: ScriptedEngine {
            ScriptedEngine(choice: { request in
                if let price = request.candidates.first(where: {
                    $0.action.operation == .select && $0.action.payload == "Price"
                }) {
                    return ScriptedEngine.pick(price)
                }
                if self.reopened == 0,
                   let again = request.candidates.first(where: { $0.action.target?.name == "See the list again" }) {
                    self.reopened += 1
                    return ScriptedEngine.pick(again)
                }
                return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
            })
        }
    }

    /// Review of 2.3, round 2: a select whose change loads a new document that
    /// shows the chosen option is checked once the page has landed, and the
    /// option is still not offered again.
    @MainActor
    func testAChosenOptionIsNotOfferedAgainAfterTheSelectReloadsThePage() async throws {
        let bridge = WebViewBridge()
        let run = AgentRun(plan: try plan(search: "https://site-72.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: Self.priceOrDone(), writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertEqual(record.steps.map(\.operation), ["select", "done"])
        XCTAssertEqual(record.steps.map(\.outcome), [.acted, .acted], "the option held on the page the select loaded")
        XCTAssertEqual(bridge.openTabCount, 0)
    }

    /// Review of 2.3b: the usual sort form — a GET form with no action that
    /// sends itself when the select changes — lands on an address with a new
    /// query. The form still goes to the same place, so the select is still
    /// the same field: its choice held and is not offered again.
    @MainActor
    func testAChosenOptionInAFormThatSendsItselfIsNotOfferedAgain() async throws {
        let bridge = WebViewBridge()
        let run = AgentRun(plan: try plan(search: "https://site-76.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: Self.priceOrDone(), writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertEqual(record.steps.map(\.operation), ["select", "done"])
        XCTAssertEqual(record.steps.map(\.outcome), [.acted, .acted])
        XCTAssertEqual(bridge.openTabCount, 0)
    }

    /// Review of 2.3, round 2: a remembered choice is checked again on every
    /// step. Once the tab shows a page where the select shows another option,
    /// that option is offered again. The page is loaded anew by its own link
    /// (no plan's search is offered since ITER-076 stage 3).
    @MainActor
    func testAChosenOptionIsOfferedAgainOnceThePageShowsAnother() async throws {
        let bridge = WebViewBridge()
        let plan = try plan(search: "https://site-67.test/")
        let run = AgentRun(plan: plan, errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: PriceThenReopen().engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertEqual(record.steps.map(\.operation), ["select", "open", "select", "done"])
        XCTAssertEqual(record.ending, .done)
    }

    /// Review of 2.3, round 2: when the page itself sets the select back on the
    /// same document, the remembered choice no longer holds, and the option is
    /// offered again.
    @MainActor
    func testAChosenOptionThePageSetBackIsOfferedAgain() async throws {
        let bridge = SetsTheSelectBack()
        let run = AgentRun(plan: try plan(search: "https://site-67.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: Self.priceOrDone(), writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertEqual(record.steps.map(\.operation), ["select", "select", "done"])
        XCTAssertEqual(bridge.inner.openTabCount, 0)
    }

    // MARK: - Back (ITER-076 2.2, S1)

    /// Which step of the errand a scripted engine is asked about.
    private final class StepCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    /// ITER-076 I-10 (critic 22): BACK goes back in the tab's own history.
    /// The first page has no entry to go back to, so BACK is not offered
    /// there; once the tab moved on, it is.
    @MainActor
    func testBackIsOfferedOnlyOnceTheTabHasAnEntryToGoBackTo() async throws {
        let bridge = WebViewBridge()
        let requests = Requests()
        let steps = StepCount()
        let engine = ScriptedEngine(choice: { request in
            _ = requests.add(request)
            return switch steps.next() {
            case 1: ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Next page" })
            default: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
            }
        })
        let run = AgentRun(plan: try plan(search: "https://site-26.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertEqual(record.steps.map(\.operation), ["open", "done"], "\(record.eventLines)")
        XCTAssertEqual(requests.all.count, 2)
        XCTAssertFalse(requests.all[0].candidates.contains { $0.action.operation == .back }, "the first page")
        XCTAssertTrue(requests.all[1].candidates.contains { $0.action.operation == .back }, "the next page")
    }

    /// Back opens only an address the loop opened itself: one a page set with
    /// `history.replaceState` is never sent.
    @MainActor
    func testBackNeverOpensAnAddressThePageSetItself() async throws {
        let bridge = WebViewBridge()
        let steps = StepCount()
        let engine = ScriptedEngine(choice: { request in
            switch steps.next() {
            case 1: ScriptedEngine.pick(request.candidates.first { $0.action.destination == "https://site-58.test/" })
            case 2: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .back })
            default: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
            }
        })
        let run = AgentRun(plan: try plan(search: "https://site-57.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/delete-account" }, "the planted address is never sent")
        XCTAssertEqual(bridge.navigatedURLs, [URL(string: "https://site-58.test/")!, URL(string: "https://site-57.test/")!],
                       "back went to the address the loop opened")
        XCTAssertEqual(record.ending, .done)
        XCTAssertEqual(bridge.openTabCount, 0)
    }

    /// Back never sends an approved address again: a second GET would do what
    /// the user said yes to once, a second time.
    @MainActor
    func testBackNeverRepeatsAnApprovedOpen() async throws {
        let bridge = WebViewBridge()
        let steps = StepCount()
        let answers = Answers()
        let engine = ScriptedEngine(choice: { request in
            switch steps.next() {
            case 1: ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Delete now" })
            case 2: ScriptedEngine.pick(request.candidates.first { $0.action.destination == "https://site-58.test/" })
            case 3: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .back })
            default: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
            }
        })
        let run = AgentRun(plan: try plan(search: "https://site-59.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { request in
                                                    answers.asked.append(request)
                                                    return .yes
                                                }))
        let record = await run.run()
        let buy = URL(string: "https://site-60.test/buy?item=1")!
        XCTAssertEqual(answers.asked.count, 1, "the delete was asked about once")
        XCTAssertEqual(bridge.navigatedURLs.filter { $0 == buy }.count, 1, "the approved open was sent once")
        XCTAssertEqual(bridge.navigatedURLs.last, URL(string: "https://site-59.test/"), "back skipped the approved page")
        XCTAssertEqual(record.ending, .done)
        XCTAssertEqual(bridge.openTabCount, 0)
    }

    /// After a click takes the tab somewhere the loop did not open, back
    /// returns to the page the loop opened — here the start.
    @MainActor
    func testBackAfterAClickReturnsToThePageTheLoopOpened() async throws {
        let bridge = WebViewBridge()
        let steps = StepCount()
        let engine = ScriptedEngine(choice: { request in
            switch steps.next() {
            case 1: ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Open the list" })
            case 2: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .back })
            default: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
            }
        })
        let run = AgentRun(plan: try plan(search: "https://site-61.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertEqual(bridge.navigatedURLs, [URL(string: "https://site-58.test/")!, URL(string: "https://site-61.test/")!])
        XCTAssertEqual(record.ending, .done)
    }

    /// An address the user approved once is never opened again by back, even
    /// when a plain link led to it later.
    @MainActor
    func testBackSkipsAnAddressApprovedOnceEvenIfAPlainLinkLedThereLater() async throws {
        let bridge = WebViewBridge()
        let steps = StepCount()
        let engine = ScriptedEngine(choice: { request in
            switch steps.next() {
            case 1: ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Delete again" })
            case 2, 5: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .back })
            case 3: ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Product" })
            case 4: ScriptedEngine.pick(request.candidates.first { $0.action.destination == "https://site-58.test/" })
            default: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
            }
        })
        let run = AgentRun(plan: try plan(search: "https://site-62.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .yes }))
        let record = await run.run()
        let item = URL(string: "https://site-60.test/item?id=1")!
        XCTAssertEqual(bridge.navigatedURLs.filter { $0 == item }.count, 2,
                       "opened once with a Yes and once by a plain link, never by back")
        XCTAssertEqual(bridge.navigatedURLs.last, URL(string: "https://site-62.test/"))
        XCTAssertEqual(record.ending, .done)
    }

    /// A fragment never reaches the server: an approved address with one
    /// added is still that address, and back never opens it.
    @MainActor
    func testBackSkipsAnApprovedAddressReachedAgainWithAFragment() async throws {
        let bridge = WebViewBridge()
        let steps = StepCount()
        let engine = ScriptedEngine(choice: { request in
            switch steps.next() {
            case 1: ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Delete again" })
            case 2, 5: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .back })
            case 3: ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Reviews" })
            case 4: ScriptedEngine.pick(request.candidates.first { $0.action.destination == "https://site-58.test/" })
            default: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
            }
        })
        let run = AgentRun(plan: try plan(search: "https://site-65.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .yes }))
        let record = await run.run()
        let item = bridge.navigatedURLs.filter { $0.host == "site-60.test" && $0.query == "id=2" }
        XCTAssertEqual(item.count, 2, "once with a Yes and once by the plain link, never by back")
        XCTAssertEqual(bridge.navigatedURLs.last, URL(string: "https://site-65.test/"))
        XCTAssertEqual(record.ending, .done)
    }

    /// Opening the page the tab is already on adds no visit, so back still
    /// leaves the page instead of loading it again.
    @MainActor
    func testOpeningTheSamePageTwiceStillLetsBackLeaveIt() async throws {
        let bridge = WebViewBridge()
        let steps = StepCount()
        let engine = ScriptedEngine(choice: { request in
            switch steps.next() {
            case 1: ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Next" })
            case 2: ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "This page" })
            case 3: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .back })
            default: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
            }
        })
        let run = AgentRun(plan: try plan(search: "https://site-64.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        let this = URL(string: "https://site-63.test/")!
        XCTAssertEqual(bridge.navigatedURLs, [this, this, URL(string: "https://site-64.test/")!])
        XCTAssertEqual(record.ending, .done)
    }

    // MARK: - Grants

    /// A grant is never asked about and never taken: it is handed to the user
    /// (§7.2).
    @MainActor
    func testAGrantIsHandedToTheUserNotAskedAbout() async throws {
        let bridge = WebViewBridge()
        let answers = Answers()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Allow access" })
        })
        let run = AgentRun(plan: try plan(search: "https://site-29.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { request in
                                                    answers.asked.append(request)
                                                    return .yes
                                                }))
        let record = await run.run()
        XCTAssertEqual(record.ending, .needsUser)
        XCTAssertTrue(answers.asked.isEmpty, "a grant is not asked about")
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/granted" }, "nothing was granted")
        XCTAssertEqual(record.steps.last?.outcome, .handedOver)
    }

    // MARK: - Any language (ITER-076 2.1)

    /// Sending a form needs a Yes in any language, even when Jev calls it
    /// safe; a No means the form is never sent.
    @MainActor
    func testSendingAFormInAnyLanguageWaitsForAYesWhateverJevSays() async throws {
        // A native submit button, and a script button that sends the form itself.
        for name in ["Supprimer le compte", "Konto löschen"] {
            let bridge = WebViewBridge()
            let answers = Answers()
            let engine = ScriptedEngine(choice: { request in
                ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == name })
            }, irreversible: { _ in 0.05 })
            let run = AgentRun(plan: try plan(search: "https://site-52.test/"), errandID: UUID(),
                               collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                    sheet: FixtureSheet(), confirm: { request in
                                                        answers.asked.append(request)
                                                        return .no
                                                    }))
            _ = await run.run()
            XCTAssertFalse(answers.asked.isEmpty, "the user was asked: \(name)")
            XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/account/close" }, "the form was never sent: \(name)")
        }
    }

    /// A form carrying an OAuth request is a grant in any language: handed to
    /// the user, never asked about, never sent.
    @MainActor
    func testAnOAuthFormInAnyLanguageIsHandedToTheUser() async throws {
        let bridge = WebViewBridge()
        let answers = Answers()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Autoriser l'accès" })
        })
        let run = AgentRun(plan: try plan(search: "https://site-53.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { request in
                                                    answers.asked.append(request)
                                                    return .yes
                                                }))
        let record = await run.run()
        XCTAssertEqual(record.ending, .needsUser)
        XCTAssertTrue(answers.asked.isEmpty, "a grant is not asked about")
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/oauth/decision" }, "nothing was granted")
        XCTAssertEqual(record.steps.last?.outcome, .handedOver)
    }

    /// A consent page reached by its address (an OAuth request in the page's
    /// own URL) is the user's part before any step.
    @MainActor
    func testAConsentPageReachedByAddressIsTheUsers() async throws {
        let bridge = WebViewBridge()
        let engine = ScriptedEngine(choice: { request in ScriptedEngine.pick(request.candidates.first) })
        let run = AgentRun(plan: try plan(search: "https://site-54.test/consent?client_id=app-42&redirect_uri=https%3A%2F%2Fapp-42.test%2Fcb"),
                           errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .yes }))
        let record = await run.run()
        XCTAssertEqual(record.ending, .needsUser)
        XCTAssertTrue(record.steps.isEmpty, "no step was taken on a consent page")
    }

    // MARK: - Stop (§7.4)

    /// Stop before the run starts: nothing is opened and nothing is written.
    @MainActor
    func testStopBeforeTheFirstStepDoesNothing() async throws {
        let bridge = WebViewBridge()
        let sheet = FixtureSheet()
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }))
        run.stop()
        let record = await run.run()
        XCTAssertEqual(record.ending, .stopped)
        XCTAssertTrue(bridge.openedURLs.isEmpty)
        XCTAssertNil(sheet.title)
    }

    /// Stop pressed during the very last await before an action is sent: the
    /// action is not sent.
    @MainActor
    func testStopRightBeforeAnActionSendsNothing() async throws {
        let button = StopButton()
        let bridge = StopAtFirstMarker(button: button)
        let sheet = FixtureSheet()
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }))
        button.run = run
        let record = await run.run()
        XCTAssertEqual(record.ending, .stopped)
        XCTAssertFalse(bridge.sentAfterStop.contains { $0.contains("location.assign") }, "no action was sent after Stop")
        XCTAssertFalse(bridge.inner.navigatedURLs.contains { $0.host == "site-1.test" }, "nothing was opened after Stop")
        XCTAssertNil(sheet.title)
        XCTAssertEqual(bridge.inner.openTabCount, 0)
    }

    /// Stop ends an open question at once — it does not wait for the answer.
    @MainActor
    func testStopDuringAQuestionEndsTheErrandAtOnce() async throws {
        let bridge = WebViewBridge()
        let button = StopButton()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" })
        })
        let run = AgentRun(plan: try plan(search: "https://site-7.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in
                                                    button.press()
                                                    try? await Task.sleep(for: .seconds(60))
                                                    return .yes
                                                }))
        button.run = run
        let clock = ContinuousClock()
        let started = clock.now
        let record = await run.run()
        XCTAssertEqual(record.ending, .stopped)
        XCTAssertLessThan(clock.now - started, .seconds(10), "Stop ended the question at once")
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/send-message" })
    }

    /// Stop while the Sheet is being made: nothing is pasted. The Sheet was
    /// made all the same, so the record keeps its address (review of I-05,
    /// P2-1: a Sheet that exists is never lost), marked as made only.
    @MainActor
    func testStopBeforeThePasteWritesNothing() async throws {
        let bridge = WebViewBridge()
        let button = StopButton()
        let sheet = StoppingSheet(button: button)
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }))
        button.run = run
        let record = await run.run()
        XCTAssertEqual(record.ending, .stopped)
        XCTAssertEqual(sheet.pastes, 0)
        XCTAssertNotNil(record.sheet, "the Sheet was made before Stop: its address is kept")
        XCTAssertEqual(record.sheetWrite, .created, "and nothing was pasted into it")
        XCTAssertEqual(record.rows.count, 3, "what was collected is kept")
    }

    /// Stop during the paste: the errand ends as stopped at once — nothing is
    /// read back — and the record keeps the Sheet the rows went into.
    @MainActor
    func testStopDuringThePasteEndsTheErrandAsStopped() async throws {
        let bridge = WebViewBridge()
        let button = StopButton()
        let sheet = StoppingSheet(button: button, pressDuring: .paste)
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }))
        button.run = run
        let record = await run.run()
        XCTAssertEqual(record.ending, .stopped)
        XCTAssertNotNil(record.sheet, "the paste happened, so the record keeps the Sheet")
        XCTAssertEqual(sheet.readBacks, 0, "nothing more is done after Stop")
    }

    /// An action that reached the page is recorded even when Stop comes right
    /// after it, and its postcondition is still checked (§7.4).
    @MainActor
    func testAnActionThatReachedThePageIsRecordedEvenIfStopFollows() async throws {
        let button = StopButton()
        let bridge = StopAfterAnAction(button: button)
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        })
        let run = AgentRun(plan: try plan(search: "https://site-26.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        button.run = run
        let record = await run.run()
        XCTAssertEqual(record.ending, .stopped)
        XCTAssertEqual(record.steps.last?.operation, "click", "the click that reached the page is recorded")
        XCTAssertEqual(record.steps.last?.outcome, .acted, "its postcondition was checked, and held")
    }

    /// An action whose reply is lost after it reached the page is still
    /// recorded, and its postcondition decides how it went (§6.5, §7.4).
    @MainActor
    func testAnActionWhoseReplyIsLostIsStillRecordedAndChecked() async throws {
        let bridge = LoseTheFirstActionReply()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        })
        let run = AgentRun(plan: try plan(search: "https://site-26.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        let click = try XCTUnwrap(record.steps.first { $0.operation == "click" }, "the click is recorded")
        XCTAssertEqual(click.outcome, .acted, "the page shows the click happened")
        XCTAssertEqual(bridge.inner.openTabCount, 0)
    }

    // MARK: - Ceilings (§8)

    /// Whatever the pauses, the errand ends at its expiry: a Yes that comes
    /// after it is not acted on.
    @MainActor
    func testAYesAfterTheExpiryIsNotActedOn() async throws {
        let bridge = WebViewBridge()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" })
        })
        let limits = AgentBudget.Limits(steps: 40, activeSeconds: 600, spendMicros: 500_000, expiry: .seconds(1))
        let run = AgentRun(plan: try plan(search: "https://site-7.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in
                                                    try? await Task.sleep(for: .milliseconds(1_500))
                                                    return .yes
                                                }),
                           limits: limits)
        let record = await run.run()
        XCTAssertEqual(record.ending, .ceiling)
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/send-message" }, "a Yes after the expiry counts for nothing")
    }

    /// At a ceiling the errand stops: what was collected is kept, and goes
    /// into the Sheet (owner default 6.1, ITER-076 stage 6 — before it, no
    /// Sheet was made at a ceiling).
    @MainActor
    func testAtACeilingWhatWasCollectedIsWritten() async throws {
        let bridge = WebViewBridge()
        let sheet = FixtureSheet()
        let limits = AgentBudget.Limits(steps: 2, activeSeconds: 600, spendMicros: 500_000, expiry: .seconds(1_800))
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }),
                           limits: limits)
        let record = await run.run()
        XCTAssertEqual(record.ending, .ceiling)
        XCTAssertEqual(record.rows.count, 1, "what was collected is kept")
        XCTAssertEqual(sheet.title, "Competitors", "a Sheet at a ceiling")
        let written = try await sheet.readBack(try XCTUnwrap(record.sheet))
        XCTAssertEqual(written.cells, record.rows.map(\.cells), "with what was collected")
        XCTAssertEqual(record.sheetWrite, .verified)
    }

    /// An errand that finishes on its last allowed step still finishes: that
    /// step's Choose, its row and the Sheet all happen. Seven steps: site
    /// three's cookie window is rejected in a step of its own (ITER-076 stage
    /// 3).
    @MainActor
    func testTheLastAllowedStepStillFinishesTheErrand() async throws {
        let bridge = WebViewBridge()
        let sheet = FixtureSheet()
        let limits = AgentBudget.Limits(steps: 7, activeSeconds: 600, spendMicros: 500_000, expiry: .seconds(1_800))
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }),
                           limits: limits)
        let record = await run.run()
        XCTAssertEqual(record.ending, .done)
        XCTAssertEqual(record.rows.count, 3)
        XCTAssertEqual(sheet.title, "Competitors")
    }

    /// No paid call starts after the expiry, and a call's deadline never runs
    /// past it (review round 12).
    @MainActor
    func testNoPaidCallStartsAfterTheExpiry() async throws {
        let bridge = WebViewBridge()
        let engine = SlowCountingEngine()
        let limits = AgentBudget.Limits(steps: 40, activeSeconds: 600, spendMicros: 500_000, expiry: .seconds(1))
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }),
                           limits: limits)
        let record = await run.run()
        XCTAssertEqual(record.ending, .ceiling)
        XCTAssertEqual(engine.calls, 1, "the only paid call was the one begun before the expiry")
    }

    // MARK: - The settle (ITER-076 I-07; Codex review of I-07)

    /// A run on `start` whose engine is done at its first look, and how long
    /// it took: the start page's settle, and little else.
    @MainActor
    private func doneAtOnce(on start: String, bridge: any BrowserBridge) async throws -> (ErrandRecord, Duration) {
        let engine = ScriptedEngine(choice: { ScriptedEngine.pick($0.candidates.first { $0.action.operation == .done }) })
        let run = AgentRun(plan: try plan(search: start, rows: 1), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let began = ContinuousClock.now
        let record = await run.run()
        return (record, ContinuousClock.now - began)
    }

    /// 2026-10-08 (live, a practice site's dynamic loading): a click starts a
    /// loader whose page shows its text 2.5 s later — past the act's settle,
    /// which gives up on a loader at 1.5 s. The next look waits on the loader
    /// first, as a reference browser agent's capture does: Jev is shown the
    /// text, never "Loading...".
    @MainActor
    func testTheLookAfterAClickWaitsForItsLoaderToGo() async throws {
        let seen = PagesSeen()
        let engine = ScriptedEngine(choice: { request in
            seen.add(request.page.text)
            if seen.count == 1, let start = request.candidates.first(where: { $0.action.target?.name == "Start" }) {
                return ScriptedEngine.pick(start)
            }
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        })
        let run = AgentRun(plan: try plan(search: "https://site-473.test/", rows: 1), errandID: UUID(),
                           collaborators: .init(bridge: WebViewBridge(), engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertEqual(record.steps.first?.operation, "click", "\(record.eventLines)")
        let after = try XCTUnwrap(seen.all.dropFirst().first, "\(record.eventLines)")
        XCTAssertTrue(after.contains("Hello World!"), after)
        XCTAssertFalse(after.contains("Loading..."), after)
    }

    /// The page texts a scripted engine was shown, in order.
    private final class PagesSeen: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func add(_ text: String) { lock.withLock { texts.append(text) } }
        var count: Int { lock.withLock { texts.count } }
        var all: [String] { lock.withLock { texts } }
    }

    /// P2-5: a hidden page — it gives one sample a read — with a spinner that
    /// never stops is read after the spinner's 1.5 s, owned by the whole
    /// settle, not after the whole 5 s — and, since 2026-10-08, after the 3 s
    /// the step's look waits on a loader (`ObserverScript.captureLoading`).
    @MainActor
    func testAHiddenPagesEndlessSpinnerIsWaitedOnForItsTwoBudgetsOnly() async throws {
        let (record, took) = try await doneAtOnce(on: "https://site-123.test/", bridge: WebViewBridge())
        XCTAssertEqual(record.ending, .done)
        XCTAssertGreaterThan(took, .milliseconds(4_300), "the spinner was waited on: the settle's and the look's")
        XCTAssertLessThan(took, .milliseconds(6_500), "for 1.5 s and 3 s, not 5 s and 3 s")
    }

    /// P2-4: a read the page's navigation broke near the end of the wait, and
    /// a next one whose answer stalls: the wait still ends at its own limit,
    /// not at the stalled call's. The read of where the page ended then gets
    /// its own short time, and answers: the start page is read as it is, and
    /// no miss is on record (review of I-07 round 3: a read never made is no
    /// failed read).
    @MainActor
    func testAStalledReadNearTheEndOfTheWaitDoesNotStretchIt() async throws {
        let (record, took) = try await doneAtOnce(on: "https://site-1.test/", bridge: StallsTheQuietReads())
        XCTAssertEqual(record.ending, .done, "read as it is: \(record.eventLines)")
        XCTAssertFalse(record.events.contains { $0.shape == "miss settle" }, "\(record.eventLines)")
        XCTAssertGreaterThan(took, .milliseconds(4_400))
        XCTAssertLessThan(took, .milliseconds(7_000), "the wait's own 5 s, not 4.5 s and then 5 s more")
    }

    /// P2-4 (Codex review of I-07, round 2): the page is never quiet, so the
    /// wait runs its whole 5 s; then the read of where the page ended stalls.
    /// Every call of the settle ends by the quiet budget, that read included:
    /// the settle ends with it, not 8 s later. The start page must end on a
    /// web page, and where it ended could not be read: a settle miss (round
    /// 3, P2-1), never a landing taken on trust.
    @MainActor
    func testAStalledReadOfWhereThePageEndedEndsWithTheSettlesBudget() async throws {
        let (record, took) = try await doneAtOnce(on: "https://site-1.test/", bridge: StallsTheFinalPageRead())
        XCTAssertEqual(record.ending, .failed)
        XCTAssertEqual(record.failure, .neverSettled)
        XCTAssertEqual(record.events.map(\.shape).suffix(2), ["miss settle", "ending failed neverSettled rows=0"])
        XCTAssertGreaterThan(took, .milliseconds(4_400))
        XCTAssertLessThan(took, .milliseconds(7_000), "the quiet budget, not the budget and a stalled read")
    }

    /// Round 3, P2-1, its other side: a settle that need not end anywhere —
    /// after a click — whose read of where the page ended stalls reads the
    /// page as it is. The click is acted, and no miss is on record.
    @MainActor
    func testAStalledReadOfWhereThePageEndedAfterAClickReadsThePageAsItIs() async throws {
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.recentActions.isEmpty
                ? request.candidates.first { $0.action.target?.name == "Show details" }
                : request.candidates.first { $0.action.operation == .done })
        })
        let bridge = StallsTheFinalPageRead(afterTheAct: true)
        let run = AgentRun(plan: try plan(search: "https://site-26.test/", rows: 1), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let began = ContinuousClock.now
        let record = await run.run()
        let took = ContinuousClock.now - began
        XCTAssertTrue(bridge.stalled, "the premise: the read of where the page ended stalled")
        XCTAssertEqual(record.steps.first { $0.operation == "click" }?.outcome, .acted, "\(record.eventLines)")
        XCTAssertFalse(record.events.contains { $0.shape == "miss settle" }, "\(record.eventLines)")
        XCTAssertEqual(record.ending, .done)
        // About 6 s; a stalled read that held the settle would make it 13 s or more. 10 s keeps that line
        // with room for a loaded Mac (it took 8.9 s in one full run).
        XCTAssertLessThan(took, .milliseconds(10_000), "the quiet budget, not the budget and a stalled read")
    }

    /// Round 3, P2-1: the open lands on its site; once the page has gone
    /// quiet, it is read to have moved to another site, whose page then loads
    /// for the rest of the settle's budget. Where it was last read is not
    /// where it must end: the step failed, a settle miss on record, within
    /// the budget, and the open is not sent again.
    @MainActor
    func testAnOpenWhosePageMovedToAnotherSiteAndKeepsLoadingFails() async throws {
        let bridge = MovesAfterTheOpenAndKeepsLoading(to: "https://site-99.test/")
        let (record, took) = try await openNextPage(on: bridge)
        XCTAssertTrue(bridge.moved, "the premise: the page was read to have moved")
        XCTAssertEqual(record.steps.first { $0.operation == "open" }?.outcome, .failed, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains { $0.shape == "miss settle" }, "\(record.eventLines)")
        XCTAssertLessThan(took, .milliseconds(10_000), "the settle's own budget, not a stalled 8 s read on top")
        XCTAssertEqual(bridge.inner.navigatedURLs.filter { $0.path == "/next" }.count, 1, "opened once")
    }

    /// Review of I-07 round 3: the page was read to have moved on its own
    /// site, then every later read of where it is stalls. Where it was read
    /// last is no longer known — an old reading is not taken for the end: the
    /// step failed, a settle miss on record, within the budget.
    @MainActor
    func testAnOpenWhosePageCannotBeReadAgainAfterItMovedFails() async throws {
        let bridge = MovesAfterTheOpenAndKeepsLoading(to: "https://site-26.test/later", thenStalls: true)
        let (record, took) = try await openNextPage(on: bridge)
        XCTAssertTrue(bridge.moved, "the premise: the page was read to have moved")
        XCTAssertTrue(bridge.stalledAfterTheMove, "the premise: a later read of where it is stalled")
        XCTAssertEqual(record.steps.first { $0.operation == "open" }?.outcome, .failed, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains { $0.shape == "miss settle" }, "\(record.eventLines)")
        XCTAssertLessThan(took, .milliseconds(10_000), "the settle's own budget, not a stalled 8 s read on top")
    }

    /// Its other side: moved on its own site, and loading to the end of the
    /// budget, the page was last read where it must end — read as it is: the
    /// open is acted, and no miss is on record.
    @MainActor
    func testAnOpenWhosePageMovedOnItsOwnSiteAndKeepsLoadingIsReadAsItIs() async throws {
        let bridge = MovesAfterTheOpenAndKeepsLoading(to: "https://site-26.test/later")
        let (record, took) = try await openNextPage(on: bridge)
        XCTAssertTrue(bridge.moved, "the premise: the page was read to have moved")
        XCTAssertEqual(record.steps.first { $0.operation == "open" }?.outcome, .acted, "\(record.eventLines)")
        XCTAssertFalse(record.events.contains { $0.shape == "miss settle" }, "\(record.eventLines)")
        XCTAssertLessThan(took, .milliseconds(10_000), "the settle's own budget, not a stalled 8 s read on top")
    }

    /// A run on site-26 that opens "Next page", then is done; and how long it
    /// took.
    @MainActor
    private func openNextPage(on bridge: any BrowserBridge) async throws -> (ErrandRecord, Duration) {
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.recentActions.isEmpty
                ? request.candidates.first { $0.action.operation == .open && $0.action.target?.name == "Next page" }
                : request.candidates.first { $0.action.operation == .done })
        })
        let run = AgentRun(plan: try plan(search: "https://site-26.test/", rows: 1), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let began = ContinuousClock.now
        let record = await run.run()
        return (record, ContinuousClock.now - began)
    }

    /// The fixture browser, whose page after an open goes quiet at once, and
    /// is then read to be at `address`, a new document still loading for as
    /// long as it is asked.
    @MainActor
    private final class MovesAfterTheOpenAndKeepsLoading: BrowserBridge {
        let inner = WebViewBridge()
        private let address: String
        private let thenStalls: Bool
        private var opened = false
        private var waited = false
        private(set) var moved = false
        private(set) var stalledAfterTheMove = false

        init(to address: String, thenStalls: Bool = false) {
            self.address = address
            self.thenStalls = thenStalls
        }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func isLoading(_ tab: BrowserTab) async throws -> Bool {
            if moved { return true }
            return try await inner.isLoading(tab)
        }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if javascript.contains("\"operation\":\"open\"") { opened = true }
            if javascript.contains("performance.timeOrigin"), waited || moved {
                if moved, thenStalls {
                    // Every read after the first one past the move is lost on its way.
                    stalledAfterTheMove = true
                    try await Task.sleep(for: .seconds(8))
                    throw BrowserBridgeError.timedOut
                }
                moved = true
                return address + "\n1"
            }
            return try await inner.run(javascript, in: tab)
        }

        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            guard opened else { return try await inner.runAwaiting(javascript, in: tab) }
            waited = true
            return #"{"stable":true}"#
        }
    }

    /// The fixture browser, whose page is never quiet — from its first act on,
    /// with `afterTheAct` — and whose first read of where the page is after a
    /// wait then stalls for 8 s, as a call lost on its way does.
    @MainActor
    private final class StallsTheFinalPageRead: BrowserBridge {
        let inner = WebViewBridge()
        private let afterTheAct: Bool
        private var acted = false
        private var waited = false
        private(set) var stalled = false

        init(afterTheAct: Bool = false) { self.afterTheAct = afterTheAct }

        private var armed: Bool { !afterTheAct || acted }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if javascript.contains("const expected") { acted = true }
            if waited, !stalled, javascript.contains("performance.timeOrigin") {
                stalled = true
                try await Task.sleep(for: .seconds(8))
            }
            return try await inner.run(javascript, in: tab)
        }

        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            guard armed else { return try await inner.runAwaiting(javascript, in: tab) }
            waited = true
            return #"{"stable":false}"#
        }
    }

    /// Review of I-07 round 3: a start page that is ready only after 12 s and
    /// never goes quiet. Its quiet budget ends early enough for the wait's
    /// last reply and the read of where the page ended, each in its own short
    /// time, within the page's 15 s: the page is read as it is, not failed.
    @MainActor
    func testAStartPageReadyLateAndNeverQuietIsReadWithinThePagesDeadline() async throws {
        let (record, took) = try await doneAtOnce(on: "https://site-1.test/", bridge: ReadyLateAndNeverQuiet())
        XCTAssertEqual(record.ending, .done, "read as it is: \(record.eventLines)")
        XCTAssertFalse(record.events.contains { $0.shape == "miss settle" }, "\(record.eventLines)")
        XCTAssertGreaterThan(took, .milliseconds(12_000), "the premise: ready late")
        XCTAssertLessThan(took, .milliseconds(16_500), "within the page's deadline")
    }

    /// The fixture browser, whose page is loading for its first 12 s and then
    /// never quiet.
    @MainActor
    private final class ReadyLateAndNeverQuiet: BrowserBridge {
        let inner = WebViewBridge()
        private var openedAt: ContinuousClock.Instant?

        func openTab(_ url: URL) async throws -> BrowserTab {
            openedAt = .now
            return try await inner.openTab(url)
        }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String { try await inner.run(javascript, in: tab) }

        func isLoading(_ tab: BrowserTab) async throws -> Bool {
            if let openedAt, ContinuousClock.now - openedAt < .seconds(12) { return true }
            return try await inner.isLoading(tab)
        }

        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await Task.sleep(for: .milliseconds(100))
            return #"{"stable":false}"#
        }
    }

    /// The fixture browser, whose first wait for the page to go quiet breaks
    /// after 4.5 s, as a navigation breaks it, and whose next one stalls for
    /// 5 s, as a call lost on its way does, before it times out.
    @MainActor
    private final class StallsTheQuietReads: BrowserBridge {
        let inner = WebViewBridge()
        private var reads = 0

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String { try await inner.run(javascript, in: tab) }

        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            reads += 1
            try await Task.sleep(for: reads == 1 ? .milliseconds(4_500) : .seconds(5))
            throw reads == 1 ? BrowserBridgeError.scriptFailed(code: -32000) : BrowserBridgeError.timedOut
        }
    }

    // MARK: - Helpers

    /// Lets a test's bridge, question or sheet press Stop on the run it is
    /// part of.
    @MainActor
    private final class StopButton {
        var run: AgentRun?
        func press() { run?.stop() }
    }

    /// The fixture browser, pressing Stop the first time the run reads the
    /// page's marker after it has observed a page — the last await before an
    /// action is sent.
    @MainActor
    private final class StopAtFirstMarker: BrowserBridge {
        let inner = WebViewBridge()
        private let button: StopButton
        private var observed = false
        private var pressed = false
        /// Every script sent after Stop was pressed.
        private(set) var sentAfterStop: [String] = []

        init(button: StopButton) { self.button = button }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if pressed { sentAfterStop.append(javascript) }
            let result = try await inner.run(javascript, in: tab)
            if javascript == ObserverScript.source { observed = true }
            if observed, !pressed, javascript.contains("performance.timeOrigin") {
                pressed = true
                button.press()
            }
            return result
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if pressed { sentAfterStop.append(javascript) }
            return try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// A fixture sheet that presses Stop while it is being created, or while
    /// the rows are being pasted.
    @MainActor
    private final class StoppingSheet: SheetDestination {
        enum Moment { case create, paste }

        private let inner = FixtureSheet()
        private let button: StopButton
        private let moment: Moment
        private(set) var pastes = 0
        private(set) var readBacks = 0

        init(button: StopButton, pressDuring moment: Moment = .create) {
            self.button = button
            self.moment = moment
        }

        func create(title: String, made: @escaping @MainActor (URL) -> Void) async throws -> URL {
            if moment == .create { button.press() }
            return try await inner.create(title: title, made: made)
        }

        func paste(_ text: String, into sheet: URL) async throws {
            pastes += 1
            try await inner.paste(text, into: sheet)
            if moment == .paste { button.press() }
        }

        func readBack(_ sheet: URL) async throws -> SheetReadBack {
            readBacks += 1
            return try await inner.readBack(sheet)
        }
    }

    /// The fixture browser, pressing Stop right after an action script has
    /// reached the page.
    @MainActor
    private final class StopAfterAnAction: BrowserBridge {
        let inner = WebViewBridge()
        private let button: StopButton
        private var pressed = false

        init(button: StopButton) { self.button = button }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            let result = try await inner.run(javascript, in: tab)
            // An act's lookup made alone before it is not the act (ITER-076
            // I-09, round 5).
            if !pressed, javascript.contains("const expected"), !javascript.contains(#""operation":"found""#) {
                pressed = true
                button.press()
            }
            return result
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// The fixture browser, adding a password field to the page right before
    /// the first action script runs, and reading the chosen button back
    /// after it.
    @MainActor
    private final class SecretFieldAtTheAct: BrowserBridge {
        let inner = WebViewBridge()
        private var added = false
        private(set) var revealText: String?

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            guard !added, javascript.contains("const expected") else { return try await inner.run(javascript, in: tab) }
            added = true
            let field = "document.querySelector('main').insertAdjacentHTML('beforeend', '<input type=password aria-label=Code>'); ''"
            _ = try await inner.run(field, in: tab)
            let result = try await inner.run(javascript, in: tab)
            revealText = try await inner.run("document.getElementById('reveal').textContent", in: tab)
            return result
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// The fixture browser, where the act is refused as a stopped caller's is.
    @MainActor
    private final class StopsAtTheAct: BrowserBridge {
        let inner = WebViewBridge()

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if javascript.contains("\"operation\":\"click\"") { throw CancellationError() }
            return try await inner.run(javascript, in: tab)
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// The fixture browser, where the page sets the sort select back to its
    /// first option right after the first check that the chosen one held.
    @MainActor
    private final class SetsTheSelectBack: BrowserBridge {
        let inner = WebViewBridge()
        private var setBack = false

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            let result = try await inner.run(javascript, in: tab)
            if !setBack, javascript.contains("\"operation\":\"holds\"") {
                setBack = true
                _ = try await inner.run("document.getElementById('sort').selectedIndex = 0; ''", in: tab)
            }
            return result
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// The fixture browser, losing the reply of the first action script: the
    /// page acts, and the bridge answers with a timeout.
    @MainActor
    private final class LoseTheFirstActionReply: BrowserBridge {
        let inner = WebViewBridge()
        private var lost = false

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            let result = try await inner.run(javascript, in: tab)
            // An act's lookup made alone before it is not the act (ITER-076
            // I-09, round 5).
            if !lost, javascript.contains("const expected"), !javascript.contains(#""operation":"found""#) {
                lost = true
                throw BrowserBridgeError.timedOut
            }
            return result
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// A decision engine that takes 1.2 s to choose — longer than the errand's
    /// time — and counts every paid call it gets.
    private final class SlowCountingEngine: DecisionEngine, @unchecked Sendable {
        let name = "scripted"
        let worstCaseUSD = 0.001
        private let lock = NSLock()
        private var count = 0

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        private func counted() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func choose(_ request: ChooseRequest) async throws -> ChooseAnswer {
            counted()
            try await Task.sleep(for: .milliseconds(1_200))
            return ScriptedEngine.pick(request.candidates.first { $0.action.destination == "https://site-1.test/" })
        }

        func risk(of action: AgentAction, on page: PageSummary, goal: String) async throws -> RiskAnswer {
            counted()
            return RiskAnswer(irreversible: 0.05, usage: nil)
        }
    }
}
