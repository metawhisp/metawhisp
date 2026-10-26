import XCTest
@testable import MetaWhisp

/// The brain's errand through the run's own rails and hands, on a fixture page (Codex review of 2026-10-19): a
/// field's edit goes without a Yes only under the send hold, a send's Yes is bound to the form's values, and an
/// address the model writes is asked about as a link is.
@MainActor
final class AgentRunBrainModeTests: XCTestCase {
    /// A brain that answers each step from its state: the n-th script gets the step's state text and returns the
    /// action list; after the scripts, it is done (success=false: no check is asked).
    final class StateBrain: Brain {
        private var scripts: [(String) -> String]
        private(set) var states: [String] = []
        /// The tools each step's call offered.
        private(set) var offered: [[CDPValue]] = []

        init(_ scripts: [(String) -> String]) { self.scripts = scripts }

        func think(_ messages: [CDPValue], tools: [CDPValue]) async throws -> ProLLMClient.Outcome {
            let state = messages.last?["content"]?.string ?? ""
            states.append(state)
            offered.append(tools)
            let actions = scripts.isEmpty ? #"[{"done": {"text": "stop", "success": false}}]"# : scripts.removeFirst()(state)
            let arguments = #"{"evaluation_previous_goal": "e", "memory": "m", "next_goal": "n", "action": \#(actions)}"#
            return .answered(.init(text: "", toolCalls: [.init(id: "c", name: "AgentOutput", arguments: arguments)],
                                   finishReason: "tool_calls", inputTokens: 10, outputTokens: 10, costUSD: 0))
        }
    }

    /// The index the step's state gives the control named `name`: on its own line, by its name or its words.
    static func index(of name: String, in state: String) -> Int {
        let lines = state.components(separatedBy: "\n")
        for (place, line) in lines.enumerated() {
            guard let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]"), open < close,
                  let number = Int(line[line.index(after: open)..<close]) else { continue }
            let words = place + 1 < lines.count ? lines[place + 1].trimmingCharacters(in: .whitespaces) : ""
            if line.contains("name=\(name)") || words == name { return number }
        }
        return -1
    }

    /// The fixture browser that keeps its tab open when the run closes it, and says whether it held the tab's sends.
    final class Browser: BrowserBridge {
        let inner = WebViewBridge()
        private(set) var tab: BrowserTab?
        var canHold = true
        private(set) var holds: [Bool] = []
        /// Run once in the page right before the first script of a press: what the page did after the look.
        var beforePress: String?
        /// Thrown, one by one, by the next reads of the page instead of reading it.
        var readErrors: [Error] = []
        /// Run once in the page right before the `at`-th script that chooses in a list (2026-10-21).
        var beforeChoice: (at: Int, change: String)?
        private var choices = 0
        /// The act each Yes the run gave the tab was for, in order; nil takes it back (`BrowserBridge.approve`).
        private(set) var approvals: [ApprovedAct?] = []
        /// The address a window the page asks for at the next click goes to, as Chrome's bridge reports the windows
        /// a page opened on the agent's click (`windowsOpened`); the WebKit browser opens none.
        var windowOnClick: String?
        private var opened: [String] = []

        func openTab(_ url: URL) async throws -> BrowserTab {
            let opened = try await inner.openTab(url)
            tab = opened
            return opened
        }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws {}
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if javascript == ObserverScript.source, !readErrors.isEmpty { throw readErrors.removeFirst() }
            if let window = windowOnClick, javascript.contains(#""operation":"click""#) {
                windowOnClick = nil
                opened.append(window)
            }
            if let change = beforePress, javascript.contains(#""operation":"found""#) || javascript.contains(#""operation":"click""#) {
                beforePress = nil
                _ = try await inner.run(change, in: tab)
            }
            if javascript.contains(#""operation":"select""#) {
                choices += 1
                if let hook = beforeChoice, hook.at == choices {
                    beforeChoice = nil
                    _ = try await inner.run(hook.change, in: tab)
                }
            }
            return try await inner.run(javascript, in: tab)
        }
        func approve(_ act: ApprovedAct?, in tab: BrowserTab) { approvals.append(act) }
        func windowsOpened(in tab: BrowserTab) -> [String] {
            defer { opened = [] }
            return opened
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
        func events(in tab: BrowserTab) -> [BrowserEvent] { inner.events(in: tab) }
        func history(of tab: BrowserTab) async throws -> BrowserHistory { try await inner.history(of: tab) }
        func goBack(to entry: Int, in tab: BrowserTab) async throws { try await inner.goBack(to: entry, in: tab) }
        func holdSends(_ held: Bool, in tab: BrowserTab) async -> Bool {
            guard canHold else { return false }
            holds.append(held)
            return await inner.holdSends(held, in: tab)
        }
        func letNavigate(to address: String, in tab: BrowserTab) { inner.letNavigate(to: address, in: tab) }

        func read(_ script: String) async throws -> String { try await inner.run(script, in: try XCTUnwrap(tab)) }
    }

    final class Questions {
        var asked: [ConfirmationRequest] = []
        /// What the page showed as each question was asked, when a test reads it.
        var shown: [String] = []
    }

    private func run(_ brain: StateBrain, browser: Browser, questions: Questions, site: Int = 487, query: String = "",
                     irreversible: Double = 0.9, sheet: (any SheetDestination)? = nil, output: ErrandOutput = .answer,
                     answer: @escaping @MainActor (ConfirmationRequest) async -> ConfirmationRequest.Answer) throws -> AgentRun {
        var parts = AgentRun.Collaborators(bridge: browser, engine: ScriptedEngine(choice: { _ in
            ChooseAnswer(candidateID: "", confidence: 0, goalMet: nil, usage: nil)
        }, irreversible: { _ in irreversible }), writer: nil, sheet: sheet, confirm: { request in
            questions.asked.append(request)
            return await answer(request)
        }, log: { _ in })
        parts.brain = brain
        parts.output = output
        let plan = try XCTUnwrap(AgentPlan(goal: "Book a pick-up", requirements: [.init(id: "r1", text: "Book", kind: .action)],
                                           answerExpected: false))
        return AgentRun(goal: "Book a pick-up at https://site-\(site).test/\(query) for Sam Taylor, cash on delivery",
                        planner: FixedPlanner(plan: plan), errandID: UUID(), collaborators: parts,
                        startPage: URL(string: "https://site-\(site).test/\(query)")!)
    }

    private static let fill: (String) -> String = { state in
        #"[{"input": {"index": \#(index(of: "Full name", in: state)), "text": "Sam Taylor"}}, "#
            + #"{"select_dropdown": {"index": \#(index(of: "Payment method", in: state)), "text": "cash on delivery"}}]"#
    }

    /// A brain errand the user asked a table of offers the table's tool and writes the brain's table to a new Sheet,
    /// its columns then its rows, titled by the request; asked for an answer, it offers the plain tool and makes no
    /// Sheet (2026-10-20: the brain had no Sheet at all).
    func testABrainErrandAskedForATableWritesItsTableToTheSheet() async throws {
        let done: (String) -> String = { _ in
            #"[{"done": {"text": "Two pick-up slots.", "success": false, "columns": ["Slot", "Link"], "#
                + #""rows": [["Monday 9:00", "https://site-487.test/"], ["Tuesday 14:00", "https://site-487.test/"]]}}]"#
        }
        let sheet = FixtureSheet()
        let brain = StateBrain([done])
        let tabled = try run(brain, browser: Browser(), questions: Questions(), sheet: sheet, output: .sheet) { _ in .no }
        let outcome = await tabled.run(report: { _ in })
        let address = try XCTUnwrap(outcome.sheet, "\(tabled.record.eventLines)")
        let cells = try await sheet.readBack(address).cells
        XCTAssertEqual(cells, [["Slot", "Link"], ["Monday 9:00", "https://site-487.test/"],
                               ["Tuesday 14:00", "https://site-487.test/"]])
        XCTAssertEqual(sheet.title, "Book a pick-up at https://site-487.test/ for Sam Taylor, cash on delivery")
        XCTAssertNil(outcome.sheetFailure)
        XCTAssertEqual(brain.offered.first, [BrainPrompt.tableTool])

        let untouched = FixtureSheet()
        let plainBrain = StateBrain([done])
        let answered = try run(plainBrain, browser: Browser(), questions: Questions(), sheet: untouched) { _ in .no }
        let plain = await answered.run(report: { _ in })
        XCTAssertNil(plain.sheet)
        XCTAssertNil(untouched.title, "asked for an answer, no Sheet is made")
        XCTAssertEqual(plainBrain.offered.first, [BrainPrompt.tool])
    }

    /// Under the send hold, a field's edit Jev calls reversible goes without a Yes — the payment-method list too:
    /// the tab's sends are held before the first edit, and nothing is asked.
    func testUnderTheHoldAFieldsEditGoesWithoutAYes() async throws {
        let browser = Browser()
        let questions = Questions()
        let run = try run(StateBrain([Self.fill]), browser: browser, questions: questions, irreversible: 0.05) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 0, "\(run.record.eventLines)")
        XCTAssertEqual(browser.holds.first, true, "the sends are held before the first edit")
        let name = try await browser.read("document.getElementById('name').value")
        let method = try await browser.read("document.getElementById('method').value")
        XCTAssertEqual(name, "Sam Taylor")
        XCTAssertEqual(method, "cash on delivery")
        XCTAssertNotEqual(run.record.ending, .needsUser, "a held choice of payment method is no payment")
    }

    /// An edit Jev calls irreversible — a box whose change may do something, by its words — is asked about, held or
    /// not: a No leaves it untouched.
    func testAnEditJevCallsIrreversibleIsAskedAbout() async throws {
        let browser = Browser()
        let questions = Questions()
        let typeName: (String) -> String = { state in
            #"[{"input": {"index": \#(Self.index(of: "Full name", in: state)), "text": "Sam Taylor"}}]"#
        }
        let run = try run(StateBrain([typeName]), browser: browser, questions: questions, irreversible: 0.9) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        let name = try await browser.read("document.getElementById('name').value")
        XCTAssertEqual(name, "")
    }

    /// Without the hold, a field's edit is asked about as any act: a No leaves it untouched.
    func testWithoutTheHoldAFieldsEditIsAskedAbout() async throws {
        let browser = Browser()
        browser.canHold = false
        let questions = Questions()
        let typeName: (String) -> String = { state in
            #"[{"input": {"index": \#(Self.index(of: "Full name", in: state)), "text": "Sam Taylor"}}]"#
        }
        let run = try run(StateBrain([typeName]), browser: browser, questions: questions) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        let name = try await browser.read("document.getElementById('name').value")
        XCTAssertEqual(name, "")
    }

    /// The send's Yes is bound to the form's values: one changed while the question waited voids it, and nothing
    /// is sent.
    func testASendsYesIsBoundToTheFormsValues() async throws {
        let browser = Browser()
        let questions = Questions()
        let send: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Send", in: state))}}]"# }
        let run = try run(StateBrain([Self.fill, send]), browser: browser, questions: questions, irreversible: 0.05) { request in
            if request.action.target?.name == "Send" {
                _ = try? await browser.read("document.getElementById('name').value = 'Eve'; 'ok'")
            }
            return .yes
        }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/book" }, "a Yes given for other values sends nothing")
    }

    /// A value changed after the Yes, right before the press: the press checks the values again and sends nothing.
    func testAValueChangedAtThePressVoidsTheSend() async throws {
        let browser = Browser()
        let questions = Questions()
        let send: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Send", in: state))}}]"# }
        let run = try run(StateBrain([Self.fill, send]), browser: browser, questions: questions, irreversible: 0.05) { request in
            if request.action.target?.name == "Send" {
                browser.beforePress = "document.getElementById('name').value = 'Eve'; 'ok'"
            }
            return .yes
        }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/book" }, "\(run.record.eventLines)")
    }

    /// A press of no form — a button beside the form that submits it by script — is bound to every field of the
    /// page: a field changed while the question waited voids the Yes.
    func testAFormlessSendIsBoundToEveryField() async throws {
        let browser = Browser()
        let questions = Questions()
        let fill: (String) -> String = { state in
            #"[{"input": {"index": \#(Self.index(of: "Recipient", in: state)), "text": "Alice"}}]"#
        }
        let send: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Send gift", in: state))}}]"# }
        let run = try run(StateBrain([fill, send]), browser: browser, questions: questions, site: 490, irreversible: 0.05) { request in
            if request.action.target?.name == "Send gift" {
                _ = try? await browser.read("document.getElementById('to').value = 'Bob'; 'ok'")
            }
            return .yes
        }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/gift" }, "\(run.record.eventLines)")
    }

    /// A press beside the form in one box — its group the box's, not the form's — submits the form by script: it
    /// is bound to every field of the page as a press of no form is, and a field changed while the question waited
    /// voids the Yes (Codex review 3 of 2026-10-19, P1).
    func testASendInTheFormsBoxIsBoundToEveryField() async throws {
        let browser = Browser()
        let questions = Questions()
        let send: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Send gift", in: state))}}]"# }
        let run = try run(StateBrain([Self.fillGift, send]), browser: browser, questions: questions, site: 491,
                          irreversible: 0.05) { request in
            if request.action.target?.name == "Send gift" {
                _ = try? await browser.read("document.getElementById('to').value = 'Bob'; 'ok'")
            }
            return .yes
        }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/gift" }, "\(run.record.eventLines)")
    }

    /// The same press with the values as they were asked goes, and the form is sent once.
    func testASendInTheFormsBoxGoesWithTheValuesAsAsked() async throws {
        let browser = Browser()
        let questions = Questions()
        let send: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Send gift", in: state))}}]"# }
        let run = try run(StateBrain([Self.fillGift, send]), browser: browser, questions: questions, site: 491,
                          irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertTrue(browser.inner.navigatedURLs.contains { $0.path == "/gift" }, "\(run.record.eventLines)")
    }

    private static let fillGift: (String) -> String = { state in
        #"[{"input": {"index": \#(index(of: "Recipient", in: state)), "text": "Alice"}}, "#
            + #"{"input": {"index": \#(index(of: "Message", in: state)), "text": "Happy birthday"}}]"#
    }

    /// With the values as they were asked, the Yes sends the form once.
    func testASendsYesSendsTheFormAsAsked() async throws {
        let browser = Browser()
        let questions = Questions()
        let send: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Send", in: state))}}]"# }
        let run = try run(StateBrain([Self.fill, send]), browser: browser, questions: questions, irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        // The form went: the held sends were released for the approved press, and the page sent its POST.
        XCTAssertTrue(browser.inner.navigatedURLs.contains { $0.path == "/book" }, "\(run.record.eventLines)")
    }

    private static let typeUser: (String) -> String = { state in
        #"[{"input": {"index": \#(index(of: "Username", in: state)), "text": "Sam"}}]"#
    }

    /// A blind errand's practice form (2026-10-20, b02): its first field, the user name, was handed over as a sign-in
    /// because the form held an empty password. An empty password sends no secret (owner decision 4, 2026-09-29): the
    /// user name goes in under the hold with nothing asked, and the password stays empty.
    func testAUserNameInAFormWithAnEmptyPasswordIsTyped() async throws {
        let browser = Browser()
        let questions = Questions()
        let run = try run(StateBrain([Self.typeUser]), browser: browser, questions: questions, site: 497,
                          irreversible: 0.05) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertFalse(run.record.events.contains(.handover(.signIn, host: "site-497.test")), "\(run.record.eventLines)")
        XCTAssertEqual(questions.asked.count, 0, "\(run.record.eventLines)")
        let user = try await browser.read("document.getElementById('username').value")
        XCTAssertEqual(user, "Sam", "\(run.record.eventLines)")
        let password = try await browser.read("document.getElementById('password').value")
        XCTAssertEqual(password, "")
        XCTAssertNotEqual(run.record.ending, .needsUser)
    }

    /// The form's submit is asked about as any form's send, and goes with the Yes — its password empty.
    func testTheSubmitOfAFormWithAnEmptyPasswordAsksTheYesAndGoesWithIt() async throws {
        let browser = Browser()
        let questions = Questions()
        let send: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "submit", in: state))}}]"# }
        let run = try run(StateBrain([Self.typeUser, send]), browser: browser, questions: questions, site: 497,
                          irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertEqual(questions.asked.first?.action.target?.name, "submit")
        XCTAssertTrue(browser.inner.navigatedURLs.contains { $0.path == "/submit" }, "\(run.record.eventLines)")
    }

    /// The same form with its password typed in could send it: the user name is the user's part, a sign-in handed
    /// over at the first field, and nothing is typed.
    func testAUserNameInAFormWithAFilledPasswordIsTheUsersPart() async throws {
        let browser = Browser()
        let questions = Questions()
        let run = try run(StateBrain([Self.typeUser]), browser: browser, questions: questions, site: 497,
                          query: "?filled", irreversible: 0.05) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertTrue(run.record.events.contains(.handover(.signIn, host: "site-497.test")), "\(run.record.eventLines)")
        XCTAssertEqual(run.record.ending, .needsUser)
        let user = try await browser.read("document.getElementById('username').value")
        XCTAssertEqual(user, "")
    }

    /// A real sign-in (2026-10-21): the e-mail goes in with nothing asked, and Sign in, with the password the form
    /// needs empty — by its autocomplete (current-password) or `required` — is the user's sign-in, handed over at the
    /// press before any Yes. Nothing is sent.
    func testASignInFormsEmailIsTypedAndItsSignInIsTheUsersPart() async throws {
        let email: (String) -> String = { state in
            #"[{"input": {"index": \#(Self.index(of: "Email", in: state)), "text": "sam@example.test"}}]"#
        }
        let press: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Sign in", in: state))}}]"# }
        for query in ["", "?required"] {
            let browser = Browser()
            let questions = Questions()
            let run = try run(StateBrain([email, press]), browser: browser, questions: questions, site: 499, query: query,
                              irreversible: 0.05) { _ in .yes }
            _ = await run.run(report: { _ in })
            XCTAssertTrue(run.record.events.contains(.handover(.signIn, host: "site-499.test")),
                          "\(query): \(run.record.eventLines)")
            XCTAssertTrue(run.record.eventLines.contains { $0.contains("op=click") && $0.contains("outcome=handedOver") },
                          "\(query): at the press: \(run.record.eventLines)")
            XCTAssertEqual(questions.asked.count, 0, "\(query): no Yes asked")
            let typed = try await browser.read("document.getElementById('email').value")
            XCTAssertEqual(typed, "sam@example.test", "\(query): the e-mail is the errand's")
            XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/session" }, "\(query): nothing sent")
        }
    }

    /// A registration whose new password is empty (`autocomplete=new-password`): the name goes in, and Create account
    /// is the user's sign-in, handed over before any Yes. Nothing is sent.
    func testARegistrationsCreateAccountWithItsNewPasswordEmptyIsTheUsersPart() async throws {
        let browser = Browser()
        let questions = Questions()
        let name: (String) -> String = { state in
            #"[{"input": {"index": \#(Self.index(of: "Full name", in: state)), "text": "Sam Taylor"}}]"#
        }
        let create: (String) -> String = { state in
            #"[{"click": {"index": \#(Self.index(of: "Create account", in: state))}}]"#
        }
        let run = try run(StateBrain([name, create]), browser: browser, questions: questions, site: 499, query: "?new",
                          irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertTrue(run.record.events.contains(.handover(.signIn, host: "site-499.test")), "\(run.record.eventLines)")
        XCTAssertEqual(questions.asked.count, 0, "\(run.record.eventLines)")
        let typed = try await browser.read("document.getElementById('name').value")
        XCTAssertEqual(typed, "Sam Taylor")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/register" }, "\(run.record.eventLines)")
    }

    /// The practice form's send was asked about — its password optional — and the form came to need that password
    /// while the Yes waited (`required` since the question): on the page the Yes came on the press is the user's
    /// sign-in, and nothing is sent.
    func testAPasswordTheFormCameToNeedWhileTheYesWaitedIsTheUsersSignIn() async throws {
        let browser = Browser()
        let questions = Questions()
        let send: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "submit", in: state))}}]"# }
        let run = try run(StateBrain([Self.typeUser, send]), browser: browser, questions: questions, site: 497,
                          irreversible: 0.05) { request in
            if request.action.target?.name == "submit" {
                _ = try? await browser.read("document.getElementById('password').required = true; 'ok'")
            }
            return .yes
        }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertTrue(run.record.events.contains(.handover(.signIn, host: "site-497.test")), "\(run.record.eventLines)")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/submit" }, "\(run.record.eventLines)")
    }

    /// A page of the archive's that sends the browser on to its sign-on, a consent page by its address: the address
    /// the errand opens carries no OAuth request, the one it lands on does.
    private static let consent = "https://site-540.test/timeline"

    /// A consent page the errand's own way reached (2026-10-21, blind b16: a site's timeline sent the browser on to
    /// its single sign-on, whose address carries an OAuth request, and the errand ended there, handed to the user
    /// before the brain saw the page): the brain is shown the page and may go elsewhere — the errand goes on, nothing
    /// on the page is done, nothing is handed to the user.
    func testAConsentPageTheErrandsWayReachedIsShownAndLeftAndTheErrandGoesOn() async throws {
        let browser = Browser()
        let questions = Questions()
        let brain = StateBrain([{ _ in #"[{"navigate": {"url": "\#(Self.consent)"}}]"# },
                                { _ in #"[{"navigate": {"url": "https://site-487.test/"}}]"# }])
        let run = try run(brain, browser: browser, questions: questions, irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertFalse(run.record.events.contains(.handover(.grant, host: "site-540.test")), "\(run.record.eventLines)")
        XCTAssertNotEqual(run.record.ending, .needsUser, "\(run.record.eventLines)")
        XCTAssertTrue(brain.states.count >= 3 && Self.index(of: "Allow", in: brain.states[1]) >= 0,
                      "the brain was shown the page: \(brain.states.dropFirst().first?.suffix(600) ?? "")")
        XCTAssertEqual(browser.inner.navigatedURLs.last?.host, "site-487.test", "and left it")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/approve" || $0.path == "/deny" })
    }

    /// On a consent page, an address of its own site the brain opens — its approval, read off the page — is the
    /// user's part as its controls are (Codex review of 2026-10-21, P1-4): handed over, and nothing is approved.
    func testOpeningAConsentPagesOwnAddressIsTheUsersPart() async throws {
        let browser = Browser()
        let questions = Questions()
        let brain = StateBrain([{ _ in #"[{"navigate": {"url": "\#(Self.consent)"}}]"# },
                                { _ in #"[{"navigate": {"url": "https://site-540.test/approve?accept=1"}}]"# }])
        let run = try run(brain, browser: browser, questions: questions, irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertTrue(run.record.events.contains(.handover(.grant, host: "site-540.test")), "\(run.record.eventLines)")
        XCTAssertEqual(run.record.ending, .needsUser, "\(run.record.eventLines)")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/approve" }, "\(run.record.eventLines)")
    }

    /// On a consent page, an address of a host under the consent's own — its approval kept on a subdomain — is the
    /// user's part too (Codex review 2 of 2026-10-21, P1-1).
    func testOpeningAnAddressUnderTheConsentsHostIsTheUsersPart() async throws {
        let browser = Browser()
        let questions = Questions()
        let brain = StateBrain([{ _ in #"[{"navigate": {"url": "\#(Self.consent)"}}]"# },
                                { _ in #"[{"navigate": {"url": "https://finish.site-540.test/continue?decision=yes"}}]"# }])
        let run = try run(brain, browser: browser, questions: questions, irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertTrue(run.record.events.contains(.handover(.grant, host: "site-540.test")), "\(run.record.eventLines)")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/continue" }, "\(run.record.eventLines)")
    }

    /// A window the page opens at a field's click — an edit under the hold — is not followed: following it is a
    /// navigation the hold never sees, and typing's own click follows none (Codex review of 10d923e..41c4983, P1-1).
    /// Nothing is asked and nothing goes to the window's address.
    func testAWindowAFieldsClickOpensIsNotFollowed() async throws {
        let browser = Browser()
        let questions = Questions()
        browser.windowOnClick = "https://site-545.test/send?name=Sam"
        let click: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Name", in: state))}}]"# }
        let run = try run(StateBrain([click]), browser: browser, questions: questions, site: 545, irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 0, "\(run.record.eventLines)")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/send" }, "\(run.record.eventLines)")
    }

    /// Its pair: a window the page opens at a press that is no edit — a button beside the form, Jev calls reversible —
    /// is followed in the tab, as before.
    func testAWindowAPressOpensIsFollowed() async throws {
        let browser = Browser()
        let questions = Questions()
        browser.windowOnClick = "https://site-545.test/next"
        let press: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Next page", in: state))}}]"# }
        let run = try run(StateBrain([press]), browser: browser, questions: questions, site: 545, irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertTrue(browser.inner.navigatedURLs.contains { $0.path == "/next" }, "\(run.record.eventLines)")
    }

    /// A click on a field is an edit (2026-10-21, blind b03): clicking the form's Full name, then typing in it, asks
    /// nothing under the hold — the form's Send is the one Yes.
    func testAClickOnAFieldThenTypingAsksNothingAndTheSendIsTheOneYes() async throws {
        let browser = Browser()
        let questions = Questions()
        let open: (String) -> String = { state in
            #"[{"click": {"index": \#(Self.index(of: "Full name", in: state))}}, "#
                + #"{"input": {"index": \#(Self.index(of: "Full name", in: state)), "text": "Sam Taylor"}}]"#
        }
        let send: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Send", in: state))}}]"# }
        var typed: String?
        let run = try run(StateBrain([open, send]), browser: browser, questions: questions, irreversible: 0.05) { _ in
            typed = try? await browser.read("document.getElementById('name').value")
            return .yes
        }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.map { $0.action.target?.name }, ["Send"], "\(run.record.eventLines)")
        XCTAssertEqual(typed, "Sam Taylor", "the field held the words as the Send was asked")
        XCTAssertTrue(browser.inner.navigatedURLs.contains { $0.path == "/book" }, "\(run.record.eventLines)")
    }

    /// Its pair (ITER-076 2.1): an act on a control of a consent page — a Continue whose words name no grant — is the
    /// user's part, handed over at the act before any Yes, and nothing is pressed.
    func testAnActOnAConsentPageIsTheUsersPartWhateverItsWords() async throws {
        let browser = Browser()
        let questions = Questions()
        let press: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Continue", in: state))}}]"# }
        let brain = StateBrain([{ _ in #"[{"navigate": {"url": "\#(Self.consent)"}}]"# }, press])
        let run = try run(brain, browser: browser, questions: questions, irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertTrue(run.record.events.contains(.handover(.grant, host: "site-540.test")), "\(run.record.eventLines)")
        XCTAssertEqual(run.record.ending, .needsUser, "\(run.record.eventLines)")
        XCTAssertEqual(questions.asked.count, 0, "\(run.record.eventLines)")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/approve" }, "\(run.record.eventLines)")
    }

    /// find_elements, run in a page, returns no secret: no password, no field drawn as dots, no digits of a
    /// one-time-code box, not even read through spans inside it — and the page's plain words.
    func testFindElementsReturnsNoSecretFromAPage() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-489.test/")!)
        for _ in 0..<30 { if try await !bridge.isLoading(tab) { break }; try await Task.sleep(for: .milliseconds(100)) }
        var everything = ""
        for selector in ["input", "[autocomplete] span", "div", "span", "main", "body", "p.note"] {
            everything += try await bridge.run(BrainScripts.findElements(selector: selector, attributes: ["value", "name", "id"],
                                                                         maxResults: 50, includeText: true), in: tab) + "\n"
        }
        for secret in ["hunter2-pass", "masked-pin-4411", "902716", "9</", ">9<"] {
            XCTAssertFalse(everything.contains(secret), secret)
        }
        XCTAssertFalse(everything.replacingOccurrences(of: " ", with: "").contains("902716"))
        // The code's digits one by one: each span inside the box is reported as not read, and no element's words
        // begin with a digit (Codex review 3 of 2026-10-19, P2).
        let spans = try await bridge.run(BrainScripts.findElements(selector: "[autocomplete] span", attributes: nil,
                                                                   maxResults: 50, includeText: true), in: tab)
        XCTAssertEqual(spans.components(separatedBy: "not read]").count - 1, 6, spans)
        XCTAssertNil(everything.range(of: #"<[a-z]+>\s+\d"#, options: .regularExpression), everything)
        XCTAssertTrue(everything.contains("Plain words anyone reads."), everything)
        XCTAssertTrue(everything.contains(#"name="user""#), everything)
    }

    /// A price that loaded after the look, met at the press, is no wall (owner decision of 2026-10-19: a payment is a
    /// page that asks card details): the press goes once, a reversible one with nothing asked.
    func testAPriceMetAtThePressIsNoWall() async throws {
        let browser = Browser()
        browser.beforePress = "document.getElementById('price').textContent = '$25.00'; 'ok'"
        let questions = Questions()
        let add: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Add to cart", in: state))}}]"# }
        let brain = StateBrain([add])
        let run = try run(brain, browser: browser, questions: questions, site: 488, irreversible: 0.05) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 0, "\(run.record.eventLines)")
        let added = try await browser.read("String(window.added || 0)")
        XCTAssertEqual(added, "1", "\(run.record.eventLines)")
        XCTAssertNotEqual(run.record.ending, .needsUser)
    }

    /// A page that answers an act with an alert alone took the act: Demoblaze's Add to cart shows "Product added." and
    /// nothing else, and read as not taken it was pressed again and again (2026-10-21, blind b14: the cart filled with
    /// repeats and the errand ran out of steps).
    func testAnActThePageAnswersWithAnAlertAloneTookEffect() async throws {
        let browser = Browser()
        let questions = Questions()
        let add: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Add to cart", in: state))}}]"# }
        let brain = StateBrain([add])
        let run = try run(brain, browser: browser, questions: questions, site: 513, irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        let added = try await browser.read("String(window.added || 0)")
        XCTAssertEqual(added, "1", "\(run.record.eventLines)")
        XCTAssertTrue(run.record.events.contains(.dialog(.alert, accepted: true)), "\(run.record.eventLines)")
        XCTAssertGreaterThanOrEqual(brain.states.count, 2)
        XCTAssertFalse(brain.states[1].contains("did not show that it took effect"),
                       "the brain hears the add as taken: \(brain.states[1].prefix(600))")
    }

    /// A form's Submit that the page answers with a box over it — "Thanks for submitting the form", the address the
    /// same — took effect (2026-10-21, blind b03: DemoQA's thanks box, outside the form's region, was read as nothing,
    /// and the send the user said Yes to went on record as failed).
    func testASendThePageAnswersWithABoxOverItTookEffect() async throws {
        let browser = Browser()
        let questions = Questions()
        let send: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Submit", in: state))}}]"# }
        let run = try run(StateBrain([send]), browser: browser, questions: questions, site: 542, irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.map { $0.action.target?.name }, ["Submit"], "\(run.record.eventLines)")
        XCTAssertTrue(run.record.eventLines.contains { $0.contains("op=click") && $0.contains("outcome=confirmed") },
                      "\(run.record.eventLines)")
        XCTAssertFalse(run.record.eventLines.contains { $0.contains("op=click") && $0.contains("outcome=failed") },
                       "\(run.record.eventLines)")
    }

    /// A send the page answered only with a box over it took effect, and it is still never sent again on that page:
    /// a box is the page's answer, not the proof it landed (Codex review 2 of 2026-10-21, P1-3). The second press asks
    /// nothing and sends nothing.
    func testASendAnsweredOnlyByABoxIsNotSentAgainOnThatPage() async throws {
        let browser = Browser()
        let questions = Questions()
        let send: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Submit", in: state))}}]"# }
        let run = try run(StateBrain([send, send]), browser: browser, questions: questions, site: 542,
                          irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertEqual(run.record.eventLines.filter { $0.contains("op=click") && $0.contains("outcome=confirmed") }.count, 1,
                       "\(run.record.eventLines)")
    }

    /// A Send inside a box that opens a second box beside it — "Sending…" — and leaves the first as it was: the page's
    /// answer, not the proof it landed (Codex review 3 of 2026-10-21, P1-2). The second press asks nothing and sends
    /// nothing.
    func testASendInABoxAnsweredByABoxBesideItIsNotSentAgain() async throws {
        let browser = Browser()
        let questions = Questions()
        let send: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Send", in: state))}}]"# }
        let run = try run(StateBrain([send, send]), browser: browser, questions: questions, site: 544,
                          irreversible: 0.05) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
    }

    /// A box that was over the page from the start and gains a control at the press is no answer of the page's to it
    /// (Codex review 2 of 2026-10-21, P1-3): the press did not show that it took effect.
    func testABoxThatWasThereGainingAControlIsNoAnswer() async throws {
        let browser = Browser()
        let questions = Questions()
        let check: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Check", in: state))}}]"# }
        let run = try run(StateBrain([check]), browser: browser, questions: questions, site: 542, query: "?shown&grow",
                          irreversible: 0.9) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertTrue(run.record.eventLines.contains { $0.contains("op=click") && $0.contains("outcome=failed") },
                      "\(run.record.eventLines)")
    }

    /// Its pair: a press the page answers with nothing — no box, no change — still did not show that it took effect.
    func testAPressThePageAnswersWithNothingDidNotTakeEffect() async throws {
        let browser = Browser()
        let questions = Questions()
        let check: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Check", in: state))}}]"# }
        let run = try run(StateBrain([check]), browser: browser, questions: questions, site: 542, irreversible: 0.9) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertTrue(run.record.eventLines.contains { $0.contains("op=click") && $0.contains("outcome=failed") },
                      "\(run.record.eventLines)")
    }

    /// A page that did not load or answer is the brain's to hear; Stop and a browser gone end the errand.
    func testAPagesTroubleIsHeardAndTheErrandsEndIsNot() {
        XCTAssertNotNil(AgentRun.pageTrouble(BrowserBridgeError.timedOut))
        XCTAssertNotNil(AgentRun.pageTrouble(BrowserBridgeError.scriptFailed(code: 1)))
        XCTAssertNotNil(AgentRun.pageTrouble(ObservationError.tooLarge))
        XCTAssertNil(AgentRun.pageTrouble(CancellationError()))
        XCTAssertNil(AgentRun.pageTrouble(BrowserBridgeError.connectionLost))
        XCTAssertNil(AgentRun.pageTrouble(BrowserBridgeError.tabNotFound))
    }

    /// A page that cannot be read is read again once: a browser gone at that second read ends the errand, and the
    /// brain is not asked on an empty page (Codex review 3 of 2026-10-19, P2).
    func testABrowserGoneAtTheSecondReadEndsTheErrand() async throws {
        let browser = Browser()
        let wait: (String) -> String = { _ in
            browser.readErrors = [BrowserBridgeError.timedOut, BrowserBridgeError.connectionLost]
            return #"[{"wait": {"seconds": 0}}]"#
        }
        let brain = StateBrain([wait])
        let run = try run(brain, browser: browser, questions: Questions()) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(brain.states.count, 1, "\(run.record.eventLines)")
    }

    /// A page still unreadable at the second read, the browser there, is an empty page the brain can leave.
    func testAPageUnreadableTwiceIsAnEmptyPageForTheBrain() async throws {
        let browser = Browser()
        let wait: (String) -> String = { _ in
            browser.readErrors = [BrowserBridgeError.timedOut, BrowserBridgeError.timedOut]
            return #"[{"wait": {"seconds": 0}}]"#
        }
        let brain = StateBrain([wait])
        let run = try run(brain, browser: browser, questions: Questions()) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(brain.states.count, 2, "\(run.record.eventLines)")
        XCTAssertTrue(brain.states.last?.contains("This page could not be read.") == true, brain.states.last ?? "")
    }

    /// A cookie window's least consent, the brain's choice, asks no Yes — as the step's own dismiss: it is clicked
    /// once, nothing asked, though Jev would call it irreversible (owner default 3.1).
    func testACookieWindowsLeastConsentAsksNoYes() async throws {
        let browser = Browser()
        let questions = Questions()
        let decline: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Decline all", in: state))}}]"# }
        let run = try run(StateBrain([decline]), browser: browser, questions: questions, site: 492) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 0, "\(run.record.eventLines)")
        let declined = try await browser.read("String(window.declined || 0)")
        XCTAssertEqual(declined, "1", "\(run.record.eventLines)")
    }

    /// Once on a page: a window still there after its least consent was clicked is decided as any control — the
    /// second click is asked about, and a No leaves it unclicked.
    func testALeastConsentClickedAgainOnThePageIsAskedAbout() async throws {
        let browser = Browser()
        let questions = Questions()
        let decline: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Decline all", in: state))}}]"# }
        let run = try run(StateBrain([decline, decline]), browser: browser, questions: questions, site: 492) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        let declined = try await browser.read("String(window.declined || 0)")
        XCTAssertEqual(declined, "1", "\(run.record.eventLines)")
    }

    /// A cookie bar fixed to the viewport with no dialog role is the page's cookie window by its words and its
    /// links: its least consent goes with no Yes, and the sticky header beside it — a cookie policy link, a Log in —
    /// is no window at all (2026-10-19: a site's bottom bar asked a Yes on every brain).
    func testACookieBarFixedToTheViewportIsTheCookieWindow() async throws {
        let browser = Browser()
        let questions = Questions()
        let decline: (String) -> String = { state in
            #"[{"click": {"index": \#(Self.index(of: "Accept only essential cookies", in: state))}}]"#
        }
        let run = try run(StateBrain([decline]), browser: browser, questions: questions, site: 494) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 0, "\(run.record.eventLines)")
        let declined = try await browser.read("String(window.declined || 0)")
        let accepted = try await browser.read("String(window.accepted || 0)")
        XCTAssertEqual(declined, "1", "\(run.record.eventLines)")
        XCTAssertEqual(accepted, "0")
        let read = try ObservedPage.decode(try await browser.read(ObserverScript.source))
        let least = try XCTUnwrap(read.elements.first { $0.name == "Accept only essential cookies" })
        XCTAssertEqual(least.region, .dialog)
        XCTAssertTrue((least.dialogText ?? "").contains("We use cookies"), "\(least)")
        let login = try XCTUnwrap(read.elements.first { $0.name == "Log in" })
        XCTAssertNotEqual(login.region, .dialog, "a sticky header is no window")
        XCTAssertNil(login.dialogText)
    }

    /// A cookie bar fixed to the viewport that offers only its accept blocks nothing: the brain's errand goes on past
    /// it — never the user's part — and its accept, when the brain goes for it, is decided as any control: asked
    /// about, and a No leaves it unclicked (2026-10-19: an app's "Got it" bar ended an errand as the user's part).
    func testACookieBarThatOffersOnlyItsAcceptIsReadPastAndItsAcceptIsAskedAbout() async throws {
        let browser = Browser()
        let questions = Questions()
        let compare: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Compare plans", in: state))}}]"# }
        let past = try run(StateBrain([compare]), browser: browser, questions: questions, site: 496, irreversible: 0.05) { _ in .no }
        _ = await past.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 0, "\(past.record.eventLines)")
        XCTAssertNotEqual(past.record.ending, .needsUser, "read past: \(past.record.eventLines)")
        let compared = try await browser.read("String(window.compared || 0)")
        XCTAssertEqual(compared, "1", "\(past.record.eventLines)")

        let second = Browser()
        let asked = Questions()
        let accept: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Got it", in: state))}}]"# }
        let going = try run(StateBrain([accept]), browser: second, questions: asked, site: 496, irreversible: 0.9) { _ in .no }
        _ = await going.run(report: { _ in })
        XCTAssertEqual(asked.asked.count, 1, "its accept is asked about as any control: \(going.record.eventLines)")
        XCTAssertNotEqual(going.record.ending, .needsUser, "\(going.record.eventLines)")
        let gotIt = try await second.read("String(window.gotIt || 0)")
        XCTAssertEqual(gotIt, "0", "a No leaves it unclicked")
    }

    /// A site's search with two submit buttons that carry no value is a pure GET search still: the button pressed
    /// changes nothing of the query, and the brain's own words go with no Yes (2026-10-19: a park service's header
    /// search asked a Yes).
    func testASiteSearchWithTwoSubmitButtonsIsStillASearch() async throws {
        let browser = Browser()
        let questions = Questions()
        let search: (String) -> String = { state in
            #"[{"input": {"index": \#(Self.index(of: "Search text", in: state)), "text": "first flight"}}, "#
                + #"{"click": {"index": \#(Self.index(of: "This park", in: state))}}]"#
        }
        let run = try run(StateBrain([search]), browser: browser, questions: questions, site: 495, irreversible: 0.05) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 0, "\(run.record.eventLines)")
        XCTAssertTrue(browser.inner.navigatedURLs.contains {
            $0.absoluteString == "https://site-495.test/search/?query=first+flight&sitelimit=&affiliate=acme"
        }, "\(browser.inner.navigatedURLs) \(run.record.eventLines)")
    }

    /// A pure site search whose box holds the brain's own words: its button sends the search by the address its
    /// form builds, and nothing is asked (D4, as the step keeps it).
    func testASiteSearchWithTheBrainsWordsAsksNoYes() async throws {
        let browser = Browser()
        let questions = Questions()
        let search: (String) -> String = { state in
            #"[{"input": {"index": \#(Self.index(of: "Query", in: state)), "text": "first flight"}}, "#
                + #"{"click": {"index": \#(Self.index(of: "Search", in: state))}}]"#
        }
        // Jev calls the typing reversible, as a real Jev does for words in a search box; the button's press asks no
        // Jev at all.
        let run = try run(StateBrain([search]), browser: browser, questions: questions, site: 493, irreversible: 0.05) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 0, "\(run.record.eventLines)")
        XCTAssertTrue(browser.inner.navigatedURLs.contains { $0.path == "/search" && ($0.query ?? "").contains("q=first") },
                      "\(browser.inner.navigatedURLs) \(run.record.eventLines)")
    }

    /// Words the page put in the box are not the brain's: its button is decided as any send — asked about, and a No
    /// sends nothing.
    func testASiteSearchWithThePagesWordsIsAskedAbout() async throws {
        let browser = Browser()
        let questions = Questions()
        let search: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Search", in: state))}}]"# }
        let run = try run(StateBrain([search]), browser: browser, questions: questions, site: 493, query: "?filled") { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/search" }, "\(browser.inner.navigatedURLs)")
    }

    // MARK: - A choice in a list (2026-10-21)

    /// The brain's choice of `option` in the list named `name`.
    private static func choose(_ name: String, _ option: String) -> (String) -> String {
        { state in #"[{"select_dropdown": {"index": \#(index(of: name, in: state)), "text": "\#(option)"}}]"# }
    }

    /// A list in no form whose change only sorts the page by its script — a shop's "Order by" (2026-10-21,
    /// bstackdemo: Jev called the sort 0.02, the word "Order" in its name asked it about as a send, a No left the list
    /// unsorted): chosen under the send hold with nothing asked, and the list is sorted. An edit's risk is Jev's alone.
    func testAChoiceInNoFormThatSortsByScriptAsksNothing() async throws {
        let browser = Browser()
        let questions = Questions()
        let run = try run(StateBrain([Self.choose("Order by", "Lowest to highest")]), browser: browser,
                          questions: questions, site: 530, irreversible: 0.02) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 0, "\(run.record.eventLines)")
        XCTAssertEqual(browser.holds.first, true, "the sends are held before the choice")
        let order = try await browser.read("Array.from(document.querySelectorAll('#list li')).map((li) => li.dataset.price).join(',')")
        XCTAssertEqual(order, "199,499,899", "\(run.record.eventLines)")
        XCTAssertTrue(browser.inner.heldURLs.isEmpty, "the sort sent nothing")
        XCTAssertNotEqual(run.record.ending, .needsUser, "\(run.record.eventLines)")
    }

    /// A list whose change posts its form — an ASP.NET postback beside the form's own Search button (2026-10-21,
    /// quotes.toscrape: the held post ended the errand): the choice goes under the hold, its post is held back, and
    /// the list is put back — that change's post held too. Then the choice is asked about once, as a send, the list
    /// shown as it was; with the Yes it is made again under the act's permit, and the page's form goes out once, with
    /// the author chosen.
    func testAChoiceWhosePostIsHeldIsPutBackAskedOnceAndSentOnceWithTheYes() async throws {
        let browser = Browser()
        let questions = Questions()
        let brain = StateBrain([Self.choose("Author", "Sam Lee")])
        let run = try run(brain, browser: browser, questions: questions, site: 531, irreversible: 0.02) { _ in
            questions.shown.append((try? await browser.read("document.getElementById('author').value")) ?? "unread")
            return .yes
        }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertEqual(questions.asked.first?.action.operation, .select)
        XCTAssertEqual(questions.asked.first?.action.payload, "Sam Lee")
        XCTAssertEqual(questions.shown, [""], "asked with the list put back to the choice it held")
        XCTAssertEqual(browser.inner.heldURLs.filter { $0.path == "/search" }.count, 2,
                       "the choice's post and the put back's, both held: \(run.record.eventLines)")
        XCTAssertEqual(browser.inner.sentForms.count, 1, "sent once: \(browser.inner.sentForms)")
        XCTAssertTrue(browser.inner.sentForms.first?.body.contains("author=Sam+Lee") == true, "\(browser.inner.sentForms)")
        XCTAssertTrue(browser.approvals.contains { $0?.words.first == "Author" }, "made again under the act's permit")
        XCTAssertGreaterThanOrEqual(brain.states.count, 2)
        let heard = brain.states.dropFirst().first ?? ""
        XCTAssertTrue(heard.contains("sent with the user's Yes"), String(heard.prefix(800)))
        XCTAssertNotEqual(run.record.ending, .needsUser, "\(run.record.eventLines)")
    }

    /// A No to that choice sends nothing: the list stays as it was put back, the brain hears the No, and the errand
    /// goes on — the same choice asked for again on the page is refused there, nothing held, nothing asked.
    func testANoToAChoiceWhosePostIsHeldSendsNothingAndTheErrandGoesOn() async throws {
        let browser = Browser()
        let questions = Questions()
        let brain = StateBrain([Self.choose("Author", "Sam Lee"), Self.choose("Author", "Sam Lee")])
        let run = try run(brain, browser: browser, questions: questions, site: 531, irreversible: 0.02) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertTrue(browser.inner.sentForms.isEmpty, "\(browser.inner.sentForms)")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/search" })
        XCTAssertEqual(browser.inner.heldURLs.filter { $0.path == "/search" }.count, 2, "\(run.record.eventLines)")
        let author = try await browser.read("document.getElementById('author').value")
        XCTAssertEqual(author, "", "the list is put back to the choice it held")
        XCTAssertGreaterThanOrEqual(brain.states.count, 3)
        let heard = brain.states.dropFirst().first ?? "", again = brain.states.dropFirst(2).first ?? ""
        XCTAssertTrue(heard.contains("The user said no"), String(heard.prefix(800)))
        XCTAssertTrue(again.contains("already said no"), String(again.prefix(800)))
        XCTAssertNotEqual(run.record.ending, .needsUser, "the errand goes on: \(run.record.eventLines)")
    }

    /// A list in no form whose change opens the sorted page by its address — the page's own GET, held: put back, asked
    /// about once as a send, and with the Yes the sorted page is opened once.
    func testAChoiceWhoseAddressIsHeldIsPutBackAskedOnceAndOpenedOnceWithTheYes() async throws {
        let browser = Browser()
        let questions = Questions()
        let run = try run(StateBrain([Self.choose("Sort by", "Cheapest")]), browser: browser, questions: questions,
                          site: 532, irreversible: 0.02) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertEqual(browser.inner.heldURLs.map(\.absoluteString),
                       ["https://site-532.test/books?sort=cheap", "https://site-532.test/books?sort=new"],
                       "the choice's address and the put back's, both held")
        XCTAssertEqual(browser.inner.navigatedURLs.filter { $0.path == "/books" }.map(\.absoluteString),
                       ["https://site-532.test/books?sort=cheap"], "opened once, as chosen: \(run.record.eventLines)")
        XCTAssertNotEqual(run.record.ending, .needsUser, "\(run.record.eventLines)")
    }

    /// A No there opens nothing, and the list stays as it was put back.
    func testANoToAChoiceWhoseAddressIsHeldOpensNothing() async throws {
        let browser = Browser()
        let questions = Questions()
        let run = try run(StateBrain([Self.choose("Sort by", "Cheapest")]), browser: browser, questions: questions,
                          site: 532, irreversible: 0.02) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/books" }, "\(browser.inner.navigatedURLs)")
        let sort = try await browser.read("document.getElementById('sort').value")
        XCTAssertEqual(sort, "new", "the list is put back to the choice it held")
        XCTAssertNotEqual(run.record.ending, .needsUser, "\(run.record.eventLines)")
    }

    /// The choice's Yes is bound as a press of no form is, to every field of the page as it was asked: a field changed
    /// right before the choice is made again voids it at the act, and nothing goes out.
    func testAChoicesYesIsBoundToEveryFieldAsAsked() async throws {
        let browser = Browser()
        browser.beforeChoice = (3, "document.getElementById('keyword').value = 'changed'; 'ok'")
        let questions = Questions()
        let brain = StateBrain([Self.choose("Author", "Sam Lee")])
        let run = try run(brain, browser: browser, questions: questions, site: 531, irreversible: 0.02) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertNil(browser.beforeChoice, "the field changed right before the choice was made again")
        XCTAssertTrue(browser.inner.sentForms.isEmpty, "a Yes given for other values sends nothing: \(browser.inner.sentForms)")
        XCTAssertGreaterThanOrEqual(brain.states.count, 2)
        let heard = brain.states.dropFirst().first ?? ""
        XCTAssertTrue(heard.contains("changed before it went"), String(heard.prefix(800)))
    }

    /// A list of several choices whose change posts its form cannot be put back by choosing again: the held post leaves
    /// the form to the user, as any held-back edit — nothing asked, nothing sent.
    func testAListOfSeveralChoicesWhosePostIsHeldIsTheUsersToFinish() async throws {
        let browser = Browser()
        let questions = Questions()
        let run = try run(StateBrain([Self.choose("Tags", "life")]), browser: browser, questions: questions,
                          site: 533, irreversible: 0.02) { _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 0, "\(run.record.eventLines)")
        XCTAssertTrue(browser.inner.sentForms.isEmpty, "\(browser.inner.sentForms)")
        XCTAssertEqual(run.record.ending, .needsUser, "\(run.record.eventLines)")
        XCTAssertEqual(run.record.form?.kind, .notSent)
    }

    /// The form's own Search button beside that list is pressed as any send, as before: asked once, bound to the
    /// form's values — one changed while the question waited voids the Yes — and with the values as asked, sent once.
    func testTheSearchButtonBesideAPostingListIsPressedAsBefore() async throws {
        let press: (String) -> String = { state in #"[{"click": {"index": \#(Self.index(of: "Search", in: state))}}]"# }
        for changed in [false, true] {
            let browser = Browser()
            let questions = Questions()
            let run = try run(StateBrain([press]), browser: browser, questions: questions, site: 531,
                              irreversible: 0.02) { _ in
                if changed { _ = try? await browser.read("document.getElementById('keyword').value = 'Eve'; 'ok'") }
                return .yes
            }
            _ = await run.run(report: { _ in })
            XCTAssertEqual(questions.asked.count, 1, "\(changed): \(run.record.eventLines)")
            XCTAssertEqual(questions.asked.first?.action.operation, .click)
            XCTAssertEqual(browser.inner.sentForms.count, changed ? 0 : 1, "\(changed): \(browser.inner.sentForms)")
        }
    }

    /// An address the model writes is asked about as a link is: one that unsubscribes is not opened on a No.
    func testAnAddressTheModelWritesIsAskedAbout() async throws {
        let browser = Browser()
        let questions = Questions()
        let go: (String) -> String = { _ in #"[{"navigate": {"url": "https://site-487.test/unsubscribe"}}]"# }
        let run = try run(StateBrain([go]), browser: browser, questions: questions) { _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.map { $0.action.destination }, ["https://site-487.test/unsubscribe"],
                       "\(run.record.eventLines)")
        XCTAssertFalse(browser.inner.navigatedURLs.contains { $0.path == "/unsubscribe" })
    }
}
