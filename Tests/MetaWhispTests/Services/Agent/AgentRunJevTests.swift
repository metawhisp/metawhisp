import XCTest
@testable import MetaWhisp

/// ITER-076 1.3b in the loop: what the step and risk answers of Jev's approved
/// questions do — `stuck` (jkudish, B) ends the errand from the third step,
/// `grant` (E) hands the step to the user, and both questions read the
/// errand's own goal and the page.
final class AgentRunJevTests: XCTestCase {

    private static let goal = "Find the details on site twenty-six"

    private func plan(search: String) throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: Self.goal,
                                subgoals: [.init(description: "Read the details", terms: ["details"])],
                                searches: [URL(string: search)!], columns: ["Name", "URL"],
                                sheetTitle: "Details", rowsWanted: 1, emptyCell: "n/a"))
    }

    @MainActor
    private func run(_ engine: ScriptedEngine, on search: String, bridge: WebViewBridge,
                     confirm: @escaping @MainActor @Sendable (ConfirmationRequest) async -> ConfirmationRequest.Answer?
                        = { _ in .no })
        throws -> AgentRun {
        AgentRun(plan: try plan(search: search), errandID: UUID(),
                 collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(), sheet: FixtureSheet(),
                                      confirm: confirm))
    }

    /// B, as jkudish uses it: `stuck` above 0.85 stops the errand, counted from
    /// the third step — the first two steps act whatever it says.
    @MainActor
    func testAStuckAnswerEndsTheErrandFromTheThirdStep() async throws {
        let bridge = WebViewBridge()
        let turn = Counter()
        let engine = ScriptedEngine(choice: { request in
            // Wait and scroll in turn, so no repeat or cycle rule is what ends it.
            let operation: AgentOperation = turn.next() % 2 == 0 ? .wait : .scroll
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == operation }, stuck: 0.95)
        })
        let record = await (try run(engine, on: "https://site-26.test/", bridge: bridge)).run()

        XCTAssertEqual(record.ending, .stuck)
        XCTAssertEqual(record.steps.count, 3)
        XCTAssertEqual(record.steps.prefix(2).map(\.outcome), [.acted, .acted], "the first two steps act")
        XCTAssertNotEqual(record.steps.last?.outcome, .acted, "the third step is not taken")
        XCTAssertEqual(bridge.openTabCount, 0)
    }

    /// A stuck answer at 0.85 — not above it — lets the third step act.
    /// (Wait, scroll, wait: no repeat or A-B-A-B cycle, which end an errand on
    /// their own.)
    @MainActor
    func testAStuckAnswerAtTheLineLetsTheErrandGoOn() async throws {
        let bridge = WebViewBridge()
        let turn = Counter()
        let engine = ScriptedEngine(choice: { request in
            let n = turn.next()
            let operation: AgentOperation = n >= 3 ? .done : (n % 2 == 0 ? .wait : .scroll)
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == operation }, stuck: 0.85)
        })
        let record = await (try run(engine, on: "https://site-26.test/", bridge: bridge)).run()
        XCTAssertEqual(record.ending, .done)
        XCTAssertEqual(record.steps.map(\.outcome), [.acted, .acted, .acted, .acted])
    }

    /// E: a grant answer from 0.20 hands the step to the user, and the control
    /// is never clicked.
    @MainActor
    func testAGrantAnswerHandsTheStepToTheUser() async throws {
        let bridge = WebViewBridge()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        }, grant: { _ in 0.2 })
        let record = await (try run(engine, on: "https://site-26.test/", bridge: bridge)).run()

        XCTAssertEqual(record.ending, .needsUser)
        XCTAssertEqual(record.steps.map(\.outcome), [.handedOver])
        XCTAssertEqual(engine.riskQuestions.count, 1)
        XCTAssertEqual(bridge.openTabCount, 0)
    }

    /// E comes before C (review of A2, P1-3): a control that both grants
    /// access and commits is handed to the user. The Yes/No card, which a
    /// commit alone would get, is never shown, and nothing is clicked.
    @MainActor
    func testAGrantThatAlsoCommitsIsHandedOverNotAskedAbout() async throws {
        let bridge = WebViewBridge()
        let asked = Counter()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        }, irreversible: { _ in 0.9 }, grant: { _ in 0.2 })
        let record = await (try run(engine, on: "https://site-26.test/", bridge: bridge,
                                    confirm: { _ in _ = asked.next(); return .yes })).run()

        XCTAssertEqual(record.ending, .needsUser)
        XCTAssertEqual(record.steps.map(\.outcome), [.handedOver])
        XCTAssertEqual(asked.next(), 0, "the user is not asked to allow a grant")
        XCTAssertEqual(bridge.openTabCount, 0)
    }

    /// A grant answer under 0.20 does not stop the step.
    @MainActor
    func testAGrantAnswerUnderTheLineLetsTheStepAct() async throws {
        let bridge = WebViewBridge()
        let turn = Counter()
        let engine = ScriptedEngine(choice: { request in
            turn.next() == 0
                ? ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
                : ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        }, grant: { _ in 0.19 })
        let record = await (try run(engine, on: "https://site-26.test/", bridge: bridge)).run()
        XCTAssertEqual(record.steps.first?.outcome, .acted)
        XCTAssertEqual(record.ending, .done)
    }

    /// C and E read the errand's own goal, and the page the control is on.
    @MainActor
    func testTheRiskQuestionReadsTheGoalAndThePage() async throws {
        let bridge = WebViewBridge()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        }, grant: { _ in 0.9 })
        _ = await (try run(engine, on: "https://site-26.test/", bridge: bridge)).run()

        let asked = try XCTUnwrap(engine.riskQuestions.first)
        XCTAssertEqual(asked.goal, Self.goal)
        XCTAssertEqual(asked.page.url, "https://site-26.test/")
        XCTAssertEqual(asked.page.title, "Site Twenty-Six")
        XCTAssertEqual(asked.action.target?.name, "Show details")
    }

    /// The step reads the goal, the page, and the last actions with whether
    /// each changed the page, as jev-ultrafast's `recent_actions` does.
    @MainActor
    func testTheStepReadsTheGoalThePageAndTheRecentActions() async throws {
        let bridge = WebViewBridge()
        let seen = Seen()
        let engine = ScriptedEngine(choice: { request in
            seen.add(request)
            return seen.count == 1
                ? ScriptedEngine.pick(request.candidates.first { $0.action.operation == .wait })
                : ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        })
        _ = await (try run(engine, on: "https://site-26.test/", bridge: bridge)).run()

        let requests = seen.all
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].goal, Self.goal)
        XCTAssertEqual(requests[0].page.url, "https://site-26.test/")
        XCTAssertEqual(requests[0].page.title, "Site Twenty-Six")
        XCTAssertTrue(requests[0].recentActions.isEmpty)
        XCTAssertEqual(requests[1].recentActions.count, 1)
        XCTAssertEqual(requests[1].recentActions[0].kind, "wait")
        XCTAssertEqual(requests[1].recentActions[0].pageChanged, false, "waiting changed nothing on the page")
    }

    // MARK: - What each step sees (ITER-076 A3a; review of A2, P1-2, P2-5, P2-10)

    /// Two steps on site 26: `first` picks the first action, the second step
    /// ends the errand. Returns what each step was asked.
    @MainActor
    private func twoSteps(_ first: @escaping @Sendable (ChooseRequest) -> Candidate?,
                          stuck: Double? = nil) async throws -> (requests: [ChooseRequest], record: ErrandRecord) {
        let bridge = WebViewBridge()
        let seen = Seen()
        let engine = ScriptedEngine(choice: { request in
            seen.add(request)
            return seen.count == 1
                ? ScriptedEngine.pick(first(request), stuck: stuck)
                : ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        })
        let record = await (try run(engine, on: "https://site-26.test/", bridge: bridge)).run()
        return (seen.all, record)
    }

    /// jev-ultrafast sends the page's visible text with every step
    /// (`model.py` 110): the step reads it, never an empty page.
    @MainActor
    func testTheStepReadsThePagesText() async throws {
        let (requests, _) = try await twoSteps { $0.candidates.first { $0.action.operation == .wait } }
        XCTAssertTrue(requests[0].page.text.contains("Actions"), requests[0].page.text)
        XCTAssertLessThanOrEqual(requests[0].page.text.count, 6_000)
    }

    /// A scroll that moved the page changed it, as jev-ultrafast's page key
    /// (url, text, actions, scroll) says.
    @MainActor
    func testAScrollThatMovedThePageChangedIt() async throws {
        let (requests, _) = try await twoSteps { $0.candidates.first { $0.action.operation == .scroll } }
        XCTAssertEqual(requests[1].recentActions.map(\.kind), ["scroll"])
        XCTAssertEqual(requests[1].recentActions.first?.pageChanged, true)
    }

    /// A link is recorded as a click, and the page it opened changed it.
    @MainActor
    func testALinkIsRecordedAsAClickThatChangedThePage() async throws {
        let (requests, _) = try await twoSteps { $0.candidates.first { $0.action.target?.name == "Next page" } }
        XCTAssertEqual(requests[1].recentActions.map(\.label), ["Next page"])
        XCTAssertEqual(requests[1].recentActions.map(\.kind), ["click"])
        XCTAssertEqual(requests[1].recentActions.first?.pageChanged, true)
    }

    /// A select is recorded under "Select → Option", as jev-ultrafast labels
    /// its action.
    @MainActor
    func testASelectIsRecordedWithItsOption() async throws {
        let (requests, _) = try await twoSteps {
            $0.candidates.first { $0.action.operation == .select && $0.action.payload == "Yearly" }
        }
        XCTAssertEqual(requests[1].recentActions.map(\.label), ["Billing period → Yearly"])
        XCTAssertEqual(requests[1].recentActions.map(\.kind), ["select"])
    }

    /// An action that did not happen is not recorded: typing, which has no
    /// text to type yet, ends unsupported.
    @MainActor
    func testAnActionThatDidNotHappenIsNotRecorded() async throws {
        let (requests, record) = try await twoSteps { $0.candidates.first { $0.action.operation == .type } }
        XCTAssertNotEqual(record.steps.first?.outcome, .acted)
        XCTAssertTrue(requests[1].recentActions.isEmpty)
    }

    /// DONE is taken before the stuck watcher is read, as the watchers'
    /// source checks it first (`navigate.ts` 790-796).
    @MainActor
    func testDoneWinsOverAStuckAnswer() async throws {
        let bridge = WebViewBridge()
        let turn = Counter()
        let engine = ScriptedEngine(choice: { request in
            let n = turn.next()
            let operation: AgentOperation = n >= 2 ? .done : (n % 2 == 0 ? .wait : .scroll)
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == operation }, stuck: 0.95)
        })
        let record = await (try run(engine, on: "https://site-26.test/", bridge: bridge)).run()
        XCTAssertEqual(record.ending, .done)
    }

    /// The page key holds what jev-ultrafast's does: the address, the text,
    /// each action as it stands (on or off, in view or not) and the scroll
    /// position. Each on its own changes the key; a second look at the same
    /// page does not.
    func testThePageKeyChangesWithEachPartOfWhatAPageShows() {
        let box = ObservedElement(index: 0, role: "checkbox", name: "Remember me", text: "", href: nil,
                                  inputType: "checkbox", heading: nil, region: .main, inViewport: true,
                                  context: nil, formAction: nil, formMethod: nil, formSubmitLabel: nil,
                                  options: nil, checked: false)
        func page(url: String = "https://a.test/", text: String = "Welcome", scrollY: Int = 0,
                  checked: Bool = false, inViewport: Bool = true) -> ObservedPage {
            var element = box
            element = ObservedElement(index: 0, role: element.role, name: element.name, text: element.text,
                                      href: nil, inputType: element.inputType, heading: nil, region: .main,
                                      inViewport: inViewport, context: nil, formAction: nil, formMethod: nil,
                                      formSubmitLabel: nil, options: nil, checked: checked)
            return ObservedPage(url: url, title: "A", truncated: false, flags: .none, elements: [element],
                                text: text, scrollY: scrollY)
        }
        let key = AgentRun.pageKey(of: page())
        XCTAssertEqual(AgentRun.pageKey(of: page()), key)
        XCTAssertNotEqual(AgentRun.pageKey(of: page(url: "https://a.test/next")), key)
        XCTAssertNotEqual(AgentRun.pageKey(of: page(text: "Welcome back")), key)
        XCTAssertNotEqual(AgentRun.pageKey(of: page(scrollY: 400)), key)
        XCTAssertNotEqual(AgentRun.pageKey(of: page(checked: true)), key)
        XCTAssertNotEqual(AgentRun.pageKey(of: page(inViewport: false)), key)
        // Review of A3, round 1: a new title, and an option a server answer
        // added, change it too.
        var titled = page()
        titled = ObservedPage(url: titled.url, title: "A — 2 new", truncated: false, flags: .none,
                              elements: titled.elements, text: titled.text, scrollY: titled.scrollY)
        XCTAssertNotEqual(AgentRun.pageKey(of: titled), key)
        let select = ObservedElement(index: 0, role: "combobox", name: "City", text: "", href: nil, inputType: nil,
                                     heading: nil, region: .main, inViewport: true, context: nil, formAction: nil,
                                     formMethod: nil, formSubmitLabel: nil, options: ["Berlin"], checked: nil)
        var more = select
        more = ObservedElement(index: 0, role: "combobox", name: "City", text: "", href: nil, inputType: nil,
                               heading: nil, region: .main, inViewport: true, context: nil, formAction: nil,
                               formMethod: nil, formSubmitLabel: nil, options: ["Berlin", "Paris"], checked: nil)
        XCTAssertNotEqual(AgentRun.pageKey(of: ObservedPage(url: "https://a.test/", title: "A", truncated: false,
                                                            flags: .none, elements: [select])),
                          AgentRun.pageKey(of: ObservedPage(url: "https://a.test/", title: "A", truncated: false,
                                                            flags: .none, elements: [more])))
    }

    // MARK: - Grants and payments (review of A3, round 1)

    /// E is asked for a step whatever made it need a Yes: a grant behind a
    /// word like "Share", or behind a POST form, is handed to the user and
    /// never asked about.
    @MainActor
    func testAGrantBehindAWordOrAFormThatNeedsAYesIsHandedOver() async throws {
        for name in ["Share with someone", "Save list"] {
            let bridge = WebViewBridge()
            let asked = Counter()
            let engine = ScriptedEngine(choice: { request in
                ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == name })
            }, irreversible: { _ in 0.05 }, grant: { _ in 0.2 })
            let record = await (try run(engine, on: "https://site-99.test/", bridge: bridge,
                                        confirm: { _ in _ = asked.next(); return .yes })).run()
            XCTAssertEqual(record.ending, .needsUser, name)
            XCTAssertEqual(record.steps.map(\.outcome), [.handedOver], name)
            XCTAssertEqual(engine.riskQuestions.count, 1, name)
            XCTAssertEqual(asked.next(), 0, "\(name): the user is not asked to allow a grant")
            XCTAssertEqual(bridge.navigatedURLs, [], "\(name): nothing was clicked")
        }
    }

    /// A step that needs a Yes and grants nothing is still asked about.
    @MainActor
    func testAStepThatNeedsAYesAndGrantsNothingIsAskedAbout() async throws {
        let bridge = WebViewBridge()
        let asked = Counter()
        let turn = Counter()
        let engine = ScriptedEngine(choice: { request in
            turn.next() == 0
                ? ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Share with someone" })
                : ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        }, grant: { _ in 0.0 })
        let record = await (try run(engine, on: "https://site-99.test/", bridge: bridge,
                                    confirm: { _ in _ = asked.next(); return .no })).run()
        XCTAssertEqual(asked.next(), 1, "asked once")
        XCTAssertEqual(record.steps.first?.outcome, .refused)
    }

    /// Owner decision of 2026-10-19: the agent never pays where a card is
    /// asked or shown — handed over once Jev called the step irreversible,
    /// nothing clicked, not even after a Yes — and a button that only says
    /// "Pay" on a page with no card is asked about as any send, and goes with
    /// the Yes. A reversible step on a checkout page still acts.
    @MainActor
    func testTheAgentNeverPaysWhereACardIsAskedOrShown() async throws {
        do {
            let bridge = WebViewBridge()
            let asked = Counter()
            let engine = ScriptedEngine(choice: { request in
                ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Bestellung abschließen" })
            }, irreversible: { _ in 0.9 }, grant: { _ in 0.0 })
            let record = await (try run(engine, on: "https://site-100.test/", bridge: bridge,
                                        confirm: { _ in _ = asked.next(); return .yes })).run()
            XCTAssertEqual(record.ending, .needsUser)
            XCTAssertEqual(record.steps.map(\.outcome), [.handedOver])
            XCTAssertEqual(asked.next(), 0, "never asked")
            XCTAssertEqual(bridge.navigatedURLs, [], "nothing was clicked")
            XCTAssertEqual(engine.riskQuestions.count, 1, "risk questions")
        }
        do {
            let bridge = WebViewBridge()
            let asked = Counter()
            let turn = Counter()
            let engine = ScriptedEngine(choice: { request in
                turn.next() == 0
                    ? ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Pay now" })
                    : ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
            }, irreversible: { _ in 0.9 }, grant: { _ in 0.0 })
            let record = await (try run(engine, on: "https://site-99.test/", bridge: bridge,
                                        confirm: { _ in _ = asked.next(); return .yes })).run()
            XCTAssertEqual(asked.next(), 1, "asked once: its words alone name no payment")
            XCTAssertTrue(bridge.navigatedURLs.contains { $0.path == "/paid" }, "went with the Yes: \(record.eventLines)")
            XCTAssertNotEqual(record.ending, .needsUser)
        }
        let bridge = WebViewBridge()
        let turn = Counter()
        let engine = ScriptedEngine(choice: { request in
            turn.next() == 0
                ? ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Details zeigen" })
                : ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        }, irreversible: { _ in 0.05 }, grant: { _ in 0.0 })
        let record = await (try run(engine, on: "https://site-100.test/", bridge: bridge)).run()
        XCTAssertEqual(record.steps.first?.outcome, .acted, "a reversible step on a checkout page")
    }

    // MARK: - Secret fields (ITER-076 A3b, owner decision 4)

    /// A page that shows a password is not the user's part by itself: the
    /// errand goes on, and a step away from the login form acts.
    @MainActor
    func testAPageWithALoginBoxIsNotHandedOverByItself() async throws {
        let bridge = WebViewBridge()
        let seen = Seen()
        let engine = ScriptedEngine(choice: { request in
            seen.add(request)
            return seen.count == 1
                ? ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Help" })
                : ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        })
        let record = await (try run(engine, on: "https://site-94.test/", bridge: bridge)).run()
        XCTAssertEqual(seen.all.first?.page.url, "https://site-94.test/", "Jev was asked on the page")
        XCTAssertEqual(record.steps.first?.outcome, .acted)
        XCTAssertEqual(record.ending, .done)
    }

    /// A step that would touch the login form is the user's part: handed
    /// over, never asked about, and the form is not sent.
    @MainActor
    func testAStepThatWouldSendASecretIsHandedOver() async throws {
        let bridge = WebViewBridge()
        let asked = Counter()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Sign in" })
        })
        let record = await (try run(engine, on: "https://site-94.test/", bridge: bridge,
                                    confirm: { _ in _ = asked.next(); return .yes })).run()
        XCTAssertEqual(record.ending, .needsUser)
        XCTAssertEqual(record.steps.map(\.outcome), [.handedOver])
        XCTAssertEqual(asked.next(), 0)
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/session" }, "the login form was not sent")
    }

    /// A select that took its option changed the page: its value is part of
    /// what a look sees (review of A2, P1-2).
    @MainActor
    func testASelectThatTookItsOptionChangedThePage() async throws {
        let (requests, _) = try await twoSteps {
            $0.candidates.first { $0.action.operation == .select && $0.action.payload == "Yearly" }
        }
        XCTAssertEqual(requests[1].recentActions.first?.pageChanged, true)
    }

    // MARK: - Review of A3d, round 2 (Codex, I-02)

    /// Without Jev's grant answer (E) a step that is not always reversible is
    /// neither asked about nor taken (P1-6): a failed risk call, or an answer
    /// with no grant in it, is a miss — whatever the lexicon ("Share") or the
    /// structure (a POST form) said. Two misses end the errand.
    @MainActor
    func testWithoutAGrantAnswerAStepIsNeitherAskedNorTaken() async throws {
        for name in ["Share with someone", "Save list"] {
            for fails in [true, false] {
                let bridge = WebViewBridge()
                let asked = Counter()
                let engine = ScriptedEngine(choice: { request in
                    ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == name })
                }, irreversible: { _ in 0.9 }, grant: { _ in nil }, riskFails: { _ in fails })
                let record = await (try run(engine, on: "https://site-99.test/", bridge: bridge,
                                            confirm: { _ in _ = asked.next(); return .yes })).run()
                let label = "\(name), risk call \(fails ? "failed" : "answered without E")"
                XCTAssertEqual(asked.next(), 0, "\(label): never asked")
                XCTAssertEqual(bridge.navigatedURLs, [], "\(label): nothing was clicked")
                XCTAssertEqual(record.steps.map(\.outcome), [.reconsidered, .reconsidered], label)
                XCTAssertEqual(record.ending, .stuck, label)
            }
        }
    }

    /// A checkout that shows what it costs and names a stored method — no
    /// card field, no card digits, no provider's frame — asks no card
    /// details: no payment (owner decision of 2026-10-19). An irreversible
    /// step there is asked about once, and goes with the Yes, the total in
    /// the button's own form or beside it (N3-P1-6). A reversible step on it
    /// still acts.
    @MainActor
    func testACheckoutWithATotalButNoCardIsAskedAndGoesWithTheYes() async throws {
        for (site, path) in [("https://site-107.test/", "/paid"), ("https://site-117.test/", "/bestellen")] {
            let bridge = WebViewBridge()
            let asked = Counter()
            let turn = Counter()
            let engine = ScriptedEngine(choice: { request in
                turn.next() == 0
                    ? ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Bestellung abschließen" })
                    : ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
            }, irreversible: { _ in 0.9 }, grant: { _ in 0.0 })
            let record = await (try run(engine, on: site, bridge: bridge,
                                        confirm: { _ in _ = asked.next(); return .yes })).run()
            XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } }, "\(site): \(record.eventLines)")
            XCTAssertEqual(record.steps.first?.outcome, .confirmed, "\(site): \(record.eventLines)")
            XCTAssertEqual(asked.next(), 1, "\(site): asked once")
            XCTAssertTrue(bridge.navigatedURLs.contains { $0.path == path }, "\(site): went with the Yes")
        }

        let calm = WebViewBridge()
        let turn = Counter()
        let details = ScriptedEngine(choice: { request in
            turn.next() == 0
                ? ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Details zeigen" })
                : ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        }, irreversible: { _ in 0.05 }, grant: { _ in 0.0 })
        let shown = await (try run(details, on: "https://site-107.test/", bridge: calm)).run()
        XCTAssertEqual(shown.steps.first?.outcome, .acted, "a reversible step on a checkout page")
    }

    /// A native submit button that names itself a tab or a box still sends
    /// its form (review of I-02, N4-P1-1): a POST form that shows what it
    /// costs, no card asked — asked about once, sent with the Yes.
    @MainActor
    func testANativeSubmitterSendsItsFormWhateverRoleItNamesItself() async throws {
        for (name, path) in [("Weiter zur Zahlung", "/zahlen-tab"), ("Bestellung bestätigen", "/zahlen-box")] {
            let bridge = WebViewBridge()
            let asked = Counter()
            let turn = Counter()
            let engine = ScriptedEngine(choice: { request in
                turn.next() == 0
                    ? ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == name })
                    : ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
            }, irreversible: { _ in 0.9 }, grant: { _ in 0.0 })
            let record = await (try run(engine, on: "https://site-118.test/", bridge: bridge,
                                        confirm: { _ in _ = asked.next(); return .yes })).run()
            XCTAssertEqual(record.steps.first?.outcome, .confirmed, "\(name): \(record.eventLines)")
            XCTAssertEqual(asked.next(), 1, "\(name): asked once")
            XCTAssertTrue(bridge.navigatedURLs.contains { $0.path == path }, "\(name): sent with the Yes")
        }
    }

    /// Payment words count on the control acted on (N-P2-1): choosing a plan
    /// period, or ticking a box, in a POST form whose button says "Buy" changes
    /// a field — asked about, as any click in a POST form is, and taken
    /// (N3-P2-3); pressing "Buy" is asked about too, and goes with the Yes:
    /// no card is asked (owner decision of 2026-10-19).
    @MainActor
    func testChoosingAPlanAndPressingBuyAreEachAskedAbout() async throws {
        let bridge = WebViewBridge()
        let asked = Counter()
        let turn = Counter()
        let engine = ScriptedEngine(choice: { request in
            switch turn.next() {
            case 0: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .select && $0.action.payload == "Yearly" })
            case 1: ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Gift wrap" })
            case 2: ScriptedEngine.pick(request.candidates.first { $0.action.target?.name.hasPrefix("Buy") == true })
            default: ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
            }
        }, irreversible: { _ in 0.05 }, grant: { _ in 0.0 })
        let record = await (try run(engine, on: "https://site-73.test/", bridge: bridge,
                                    confirm: { _ in _ = asked.next(); return .yes })).run()
        XCTAssertEqual(Array(record.steps.map(\.outcome).prefix(3)), [.confirmed, .confirmed, .confirmed], "\(record.eventLines)")
        XCTAssertEqual(asked.next(), 3, "the choice, the box and the purchase were each asked about")
        XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } }, "\(record.eventLines)")
        XCTAssertTrue(bridge.navigatedURLs.contains { $0.path == "/buy" }, "bought with the Yes")
    }

    /// A button in no form whose handler sends a filled login form is handed
    /// over and the form is not sent; beside an empty login box the page's
    /// own search still works (N-P1-2).
    @MainActor
    func testAButtonOutsideTheFormIsHandedOverOnlyForAFilledPassword() async throws {
        let bridge = WebViewBridge()
        let asked = Counter()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Sign in" })
        }, irreversible: { _ in 0.05 }, grant: { _ in 0.0 })
        let record = await (try run(engine, on: "https://site-103.test/?filled", bridge: bridge,
                                    confirm: { _ in _ = asked.next(); return .yes })).run()
        XCTAssertEqual(record.ending, .needsUser)
        XCTAssertEqual(record.steps.map(\.outcome), [.handedOver])
        XCTAssertEqual(asked.next(), 0)
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/session" }, "the login form was not sent")

        let calm = WebViewBridge()
        let turn = Counter()
        let search = ScriptedEngine(choice: { request in
            turn.next() == 0
                ? ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Search" })
                : ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        }, irreversible: { _ in 0.05 }, grant: { _ in 0.0 })
        let searched = await (try run(search, on: "https://site-103.test/", bridge: calm)).run()
        XCTAssertEqual(searched.steps.first?.outcome, .acted, "the search beside an empty login box works")
        XCTAssertEqual(searched.ending, .done)
    }

    /// A form whose secret sits in a frame of its own origin is the user's
    /// part: handed over, never asked, never sent (P1-5).
    @MainActor
    func testAFormWithASecretInItsFrameIsHandedOver() async throws {
        let bridge = WebViewBridge()
        let asked = Counter()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" })
        }, irreversible: { _ in 0.05 }, grant: { _ in 0.0 })
        let record = await (try run(engine, on: "https://site-102.test/", bridge: bridge,
                                    confirm: { _ in _ = asked.next(); return .yes })).run()
        XCTAssertEqual(record.ending, .needsUser)
        XCTAssertEqual(record.steps.map(\.outcome), [.handedOver])
        XCTAssertEqual(asked.next(), 0)
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/outer" }, "the form was not sent")
    }

    /// A password in a frame of the form that the page showed as text between
    /// two looks is still the user's part (N3-P1-3): handed over, never asked,
    /// never sent.
    @MainActor
    func testAFramesPasswordShownAsTextIsStillHandedOver() async throws {
        let bridge = ShowsThePasswordAfterTheFirstLook()
        let asked = Counter()
        let turn = Counter()
        let engine = ScriptedEngine(choice: { request in
            turn.next() == 0
                ? ScriptedEngine.pick(request.candidates.first { $0.action.operation == .wait })
                : ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Weiter" })
        }, irreversible: { _ in 0.05 }, grant: { _ in 0.0 })
        let record = await AgentRun(plan: try plan(search: "https://site-115.test/"), errandID: UUID(),
                                    collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                         sheet: FixtureSheet(),
                                                         confirm: { _ in _ = asked.next(); return .yes })).run()
        XCTAssertTrue(bridge.shown, "the page showed the password between the looks")
        XCTAssertEqual(record.steps.map(\.outcome), [.acted, .handedOver])
        XCTAssertEqual(record.ending, .needsUser)
        XCTAssertEqual(asked.next(), 0)
        XCTAssertFalse(bridge.inner.navigatedURLs.contains { $0.path == "/outer" }, "the form was not sent")
    }

    /// A total that loads while the question waits is no wall (owner decision
    /// of 2026-10-19: a payment is a page that asks card details): the Yes
    /// stands, and the order goes.
    @MainActor
    func testAnAmountThatLoadsWhileTheYesWaitsIsNoWall() async throws {
        let bridge = WebViewBridge()
        let asked = Counter()
        let turn = Counter()
        let engine = ScriptedEngine(choice: { request in
            turn.next() == 0
                ? ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Bestellung abschließen" })
                : ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        }, irreversible: { _ in 0.9 }, grant: { _ in 0.0 })
        let record = await (try run(engine, on: "https://site-116.test/", bridge: bridge, confirm: { request in
            _ = asked.next()
            _ = try? await bridge.run("document.getElementById('summe').textContent = 'Gesamtsumme: 49,90 €'; ''",
                                      in: request.tab)
            return .yes
        })).run()
        XCTAssertEqual(asked.next(), 1, "asked once")
        XCTAssertEqual(record.steps.first?.outcome, .confirmed, "\(record.eventLines)")
        XCTAssertTrue(bridge.navigatedURLs.contains { $0.path == "/paid" }, "the order went with the Yes")
    }

    /// The address reaches Jev's questions as the address bar shows it — a
    /// key written into it in percent escapes included (owner decision of
    /// 2026-10-03) — and the errand's events hold none of it.
    @MainActor
    func testAnAddressReachesJevAsTheAddressBarShowsIt() async throws {
        let key = FakeSecrets.stripeLiveKey
        let once = key.utf8.map { String(format: "%%%02X", $0) }.joined()
        let twice = once.replacingOccurrences(of: "%", with: "%25")
        let address = "https://site-98.test/files/\(once)/view?q=shoes&ref=\(twice)&\(once)=1&\(once)"
        let bridge = WebViewBridge()
        let seen = Seen()
        let engine = ScriptedEngine(choice: { request in
            seen.add(request)
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done }, goalMet: 0.95)
        })
        let record = await (try run(engine, on: address, bridge: bridge)).run()
        XCTAssertEqual(record.rows.count, 1, "the writer wrote a row")
        let request = try XCTUnwrap(seen.all.first)
        let asked = request.page.url
        // Jev's step and risk questions as they are sent.
        let step = String(decoding: try JSONEncoder().encode(try JevDecisionEngine.step(for: request).state), as: UTF8.self)
        let anyAction = try XCTUnwrap(request.candidates.first { $0.action.target != nil }?.action)
        let risk = String(decoding: try JSONEncoder().encode(
            try JevDecisionEngine.risk(for: anyAction, on: request.page, goal: Self.goal).state), as: UTF8.self)
        XCTAssertEqual(asked, address)
        XCTAssertTrue(step.contains(once), "Jev's step")
        XCTAssertTrue(risk.contains(once), "Jev's risk question")
        for part in ["%73%6B", "%2573", "sk_live", "51H8"] {
            XCTAssertFalse("\(record.eventLines)".contains(part), "events: \(part)")
        }
    }

    /// Only the last ten actions are sent, as jev-ultrafast sends them.
    func testTheRecentActionsKeepTheLastTen() {
        var recent = RecentActions()
        for index in 0..<12 {
            recent.append(RecentAction(label: "Step \(index)", kind: "wait", typed: nil, pageChanged: nil))
        }
        XCTAssertEqual(recent.all.map(\.label), (2..<12).map { "Step \($0)" })
    }

    /// The fixture browser, showing the frame's password as text right after
    /// the first look.
    @MainActor
    private final class ShowsThePasswordAfterTheFirstLook: BrowserBridge {
        let inner = WebViewBridge()
        private(set) var shown = false

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            let result = try await inner.run(javascript, in: tab)
            if !shown, javascript == ObserverScript.source {
                shown = true
                _ = try await inner.run("document.getElementById('show').click(); ''", in: tab)
            }
            return result
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { value += 1; lock.unlock() }
            return value
        }
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [ChooseRequest] = []
        func add(_ request: ChooseRequest) { lock.lock(); requests.append(request); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
        var all: [ChooseRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    }
}
