import XCTest
@testable import MetaWhisp

/// The brain's loop with a scripted model and scripted hands: what it runs, what the user is asked, when it ends.
@MainActor
final class BrainLoopTests: XCTestCase {
    // MARK: - Fakes

    final class ScriptedBrain: Brain {
        private var replies: [ProLLMClient.Outcome]
        /// What the check answers, in order; with none left, it accepts.
        var verdicts: [ProLLMClient.Outcome]
        private(set) var asked: [[CDPValue]] = []
        /// The tools each step's call offered.
        private(set) var offered: [[CDPValue]] = []

        init(_ replies: [ProLLMClient.Outcome], verdicts: [ProLLMClient.Outcome] = []) {
            self.replies = replies
            self.verdicts = verdicts
        }

        func think(_ messages: [CDPValue], tools: [CDPValue]) async throws -> ProLLMClient.Outcome {
            asked.append(messages)
            // A call with no tool is the check's (or an extract's): its verdict.
            if tools.isEmpty { return verdicts.isEmpty ? .verdict(true) : verdicts.removeFirst() }
            offered.append(tools)
            return replies.isEmpty ? .actions(#"[{"wait": {"seconds": 0}}]"#) : replies.removeFirst()
        }

        /// The step state the n-th call showed, 1-based.
        func state(_ call: Int) -> String { asked[call - 1].last?["content"]?.string ?? "" }
    }

    struct CeilingForTest: Error {}

    final class FakeHands: BrainHands {
        var pages: [ObservedPage]
        var current = 0
        var done: [String] = []
        /// Acting on these indexes moves to the next page — typing into them too.
        var navigating: Set<Int> = []
        /// Every action the hands were given, as given.
        var acts: [AgentAction] = []
        /// The page as the reader reads it.
        var readerText = "Price: $5. Total due: $12."
        /// What acting on a control of this name comes to, when not simply done.
        var verdicts: [String: BrainActed] = [:]
        var enterVerdict = BrainActed(kind: .done)
        /// The host's step ceiling.
        var maxSteps = 40
        private var steps = 0

        init(_ pages: [ObservedPage]) { self.pages = pages }

        func checkpoint() throws {
            if Task.isCancelled { throw CancellationError() }
            if steps >= maxSteps { throw CeilingForTest() }
            steps += 1
        }

        func look() async throws -> (page: ObservedPage, tabs: [BrainTab]) {
            let page = pages[current]
            return (page, [BrainTab(id: "ab12", url: page.url, title: page.title, current: true)])
        }

        func address() async -> String? { pages[current].url }

        private func next() { current = min(current + 1, pages.count - 1) }

        func act(_ action: AgentAction, on page: ObservedPage) async throws -> BrainActed {
            acts.append(action)
            if let name = action.target?.name, let verdict = verdicts[name] {
                if verdict.kind == .done { done.append("\(action.operation.rawValue) \(action.target?.index ?? -1)") }
                return verdict
            }
            switch action.operation {
            case .open where action.target == nil:
                done.append("open \(action.destination ?? "")")
                next()
            case .type, .select:
                done.append("\(action.operation.rawValue) \(action.target?.index ?? -1) \(action.payload ?? "")")
                if let index = action.target?.index, navigating.contains(index) { next() }
            case .back:
                done.append("back")
                next()
            default:
                done.append("\(action.operation.rawValue) \(action.target?.index ?? -1)")
                if let index = action.target?.index, navigating.contains(index) { next() }
            }
            return BrainActed(kind: .done)
        }

        func enter(after field: ObservedElement, typed: String, on page: ObservedPage) async throws -> BrainActed {
            done.append("enter \(field.index) \(typed)")
            return enterVerdict
        }

        func scroll(down: Bool, pages: Double, on page: ObservedPage) async throws { done.append("scroll \(down)") }
        func evaluate(_ script: String) async throws -> String { done.append("evaluate"); return "1 match(es):\n1. ...x..." }
        func pageText() async throws -> String { done.append("read"); return readerText }
    }

    private func element(_ index: Int, _ role: String, _ name: String, href: String? = nil,
                         value: String? = nil) -> ObservedElement {
        ObservedElement(index: index, key: index, role: role, name: name, text: name, href: href, inputType: nil,
                        heading: nil, region: .main, inViewport: true, context: nil, formAction: nil, formMethod: nil,
                        formSubmitLabel: nil, options: nil, checked: nil, value: value)
    }

    private func page(_ url: String, _ elements: [ObservedElement], title: String = "t", text: String = "words") -> ObservedPage {
        ObservedPage(url: url, title: title, truncated: false, flags: .none, elements: elements, text: text)
    }

    private var form: ObservedPage {
        page("https://shop.test/form", [element(1, "textbox", "Name", value: "Hello"), element(2, "button", "Send")])
    }

    private func loop(_ brain: ScriptedBrain, _ hands: FakeHands, recall: [String] = [],
                      kept: @escaping @MainActor (String) -> Void = { _ in }) -> BrainLoop {
        BrainLoop(goal: "Send the form", brain: brain, hands: hands, recall: { _ in recall }, today: "2026-10-19",
                  log: { _ in }, kept: kept)
    }

    // MARK: - Tests

    /// Look, think, act, look again: a link followed, then done, ends the errand with the brain's answer.
    func testAGoalIsDoneStepByStep() async throws {
        let brain = ScriptedBrain([.actions(#"[{"click": {"index": 1}}]"#),
                                   .actions(#"[{"done": {"text": "The price is $5. https://shop.test/item", "success": true}}]"#)])
        let hands = FakeHands([page("https://shop.test/", [element(1, "link", "Item", href: "https://shop.test/item")]),
                               page("https://shop.test/item", [])])
        hands.navigating = [1]
        let outcome = try await loop(brain, hands).run()
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.answer, "The price is $5. https://shop.test/item")
        XCTAssertEqual(outcome.steps, 2)
        XCTAssertEqual(outcome.visited, ["https://shop.test/", "https://shop.test/item"])
        // A link is opened by its own address, as the app's candidates open links.
        XCTAssertEqual(hands.done, ["open 1"])
        XCTAssertTrue(brain.state(2).contains("Action 1/1: Clicked [1] link \"Item\""))
    }

    /// A table errand offers the table's tool on every step and keeps the table its done gives; a plain errand
    /// offers the plain tool and keeps none.
    func testATableErrandOffersTheTableToolAndKeepsTheDonesTable() async throws {
        let done = #"[{"done": {"text": "Two shops.", "success": false, "columns": ["Shop", "Link"], "rows": [["Alpha", "https://a.test"]]}}]"#
        let brain = ScriptedBrain([.actions(#"[{"wait": {"seconds": 0}}]"#), .actions(done)])
        let hands = FakeHands([page("https://shop.test/", [])])
        let outcome = try await BrainLoop(goal: "List shops in a table", brain: brain, hands: hands, recall: { _ in [] },
                                          settings: .init(table: true), today: "2026-10-20", log: { _ in }).run()
        XCTAssertEqual(outcome.table, BrainTable(columns: ["Shop", "Link"], rows: [["Alpha", "https://a.test"]]))
        XCTAssertEqual(brain.offered, [[BrainPrompt.tableTool], [BrainPrompt.tableTool]])
        let plainBrain = ScriptedBrain([.actions(done)])
        let plain = try await loop(plainBrain, FakeHands([page("https://shop.test/", [])])).run()
        XCTAssertEqual(plainBrain.offered, [[BrainPrompt.tool]])
        XCTAssertEqual(plain.table, BrainTable(columns: ["Shop", "Link"], rows: [["Alpha", "https://a.test"]]),
                       "a table the model gives anyway is read; the run writes it only for a table errand")
    }

    /// A send the rails asked about and the user said Yes to went out, and the outcome says so.
    func testASendTheUserSaidYesToIsSent() async throws {
        let brain = ScriptedBrain([.actions(#"[{"input": {"index": 1, "text": "Sam"}}, {"click": {"index": 2}}]"#),
                                   .actions(#"[{"done": {"text": "Sent."}}]"#)])
        let hands = FakeHands([form])
        hands.verdicts["Send"] = BrainActed(kind: .done, asked: "Send the form to shop.test?", sent: true)
        let outcome = try await loop(brain, hands).run()
        XCTAssertEqual(hands.done, ["type 1 Sam", "click 2"])
        XCTAssertEqual(outcome.asked, ["Send the form to shop.test?"])
        XCTAssertEqual(outcome.answersGiven, [true])
        XCTAssertTrue(outcome.sent)
        XCTAssertTrue(brain.state(2).contains("Clicked [2] button \"Send\" (sent with the user's Yes)"))
    }

    /// A No is never pressed, and the brain reads that the user said no.
    func testANoIsNeverPressedAndTheBrainHearsIt() async throws {
        let brain = ScriptedBrain([.actions(#"[{"click": {"index": 2}}]"#),
                                   .actions(#"[{"done": {"text": "Not sent: you said no.", "success": false}}]"#)])
        let hands = FakeHands([form])
        hands.verdicts["Send"] = BrainActed(kind: .userSaidNo, asked: "Send?")
        let outcome = try await loop(brain, hands).run()
        XCTAssertEqual(hands.done, [])
        XCTAssertFalse(outcome.sent)
        XCTAssertEqual(outcome.answersGiven, [false])
        XCTAssertEqual(outcome.ending, .notDone)
        XCTAssertTrue(brain.state(2).contains("Not done: The user said no. Do not try this action again."))
    }

    /// What the rails refuse is not done, and the brain reads why.
    func testARefusedActionIsNotDoneAndTheBrainHearsWhy() async throws {
        let brain = ScriptedBrain([.actions(#"[{"click": {"index": 2}}]"#),
                                   .actions(#"[{"done": {"text": "x", "success": false}}]"#)])
        let hands = FakeHands([form])
        hands.verdicts["Send"] = BrainActed(kind: .notDone, note: "the control is gone from the page.")
        _ = try await loop(brain, hands).run()
        XCTAssertEqual(hands.done, [])
        XCTAssertTrue(brain.state(2).contains("Not done: the control is gone from the page."))
    }

    /// The user's part ends the errand there: the brain is not asked again.
    func testTheUsersPartEndsTheErrand() async throws {
        let brain = ScriptedBrain([.actions(#"[{"click": {"index": 2}}, {"click": {"index": 1}}]"#)])
        let hands = FakeHands([form])
        hands.verdicts["Send"] = BrainActed(kind: .ended, note: "Paying is the user's part.")
        let outcome = try await loop(brain, hands).run()
        XCTAssertEqual(outcome.ending, .handedOver)
        XCTAssertEqual(outcome.answer, "Paying is the user's part.")
        XCTAssertEqual(brain.asked.count, 1)
        XCTAssertEqual(hands.done, [])
    }

    /// The actions after one that changes the page are skipped, as the reference skips them.
    func testActionsAfterAPageChangeAreSkipped() async throws {
        let brain = ScriptedBrain([.actions(#"[{"navigate": {"url": "https://shop.test/b"}}, {"click": {"index": 1}}]"#),
                                   .actions(#"[{"click": {"index": 1}}, {"input": {"index": 2, "text": "x"}}]"#),
                                   .actions(#"[{"done": {"text": "ok"}}]"#)])
        let hands = FakeHands([page("https://shop.test/a", [element(1, "button", "Go")]),
                               page("https://shop.test/b", [element(1, "button", "Next"), element(2, "textbox", "Q")]),
                               page("https://shop.test/c", [])])
        hands.navigating = [1]
        _ = try await loop(brain, hands).run()
        XCTAssertEqual(hands.done, ["open https://shop.test/b", "click 1"])
        XCTAssertTrue(brain.state(2).contains("Action 2/2: Remaining actions skipped: the page changed."))
        XCTAssertTrue(brain.state(3).contains("Remaining actions skipped: the page changed."))
    }

    /// Typing never counts as leaving the page, so the fields after it are filled in the same step.
    func testTypingNeverSkipsTheNextField() async throws {
        let brain = ScriptedBrain([.actions(#"[{"input": {"index": 1, "text": "Sam"}}, {"input": {"index": 3, "text": "x"}}]"#),
                                   .actions(#"[{"done": {"text": "ok"}}]"#)])
        let hands = FakeHands([page("https://shop.test/a", [element(1, "textbox", "Name"), element(3, "textbox", "Q")]),
                               page("https://shop.test/b", [element(1, "textbox", "Name"), element(3, "textbox", "Q")])])
        // Typing into the name moves the address (a page that keeps its form in its address): the next field is
        // still typed in the same step — typing is never a page change.
        hands.navigating = [1]
        _ = try await loop(brain, hands).run()
        XCTAssertEqual(hands.done, ["type 1 Sam", "type 3 x"])
    }

    /// One bad answer is told and asked again; several in a row end the errand as an error.
    func testFailedCallsAreToldThenEndTheErrand() async throws {
        let text = ProLLMClient.Outcome.answered(.init(text: "I will click", toolCalls: [], finishReason: "stop",
                                                       inputTokens: 1, outputTokens: 1, costUSD: 0))
        let retried = ScriptedBrain([text, .actions(#"[{"done": {"text": "ok"}}]"#)])
        let first = try await loop(retried, FakeHands([form])).run()
        XCTAssertEqual(first.ending, .done)
        XCTAssertTrue(retried.state(2).contains("Error: no valid AgentOutput call came back. Call the AgentOutput tool."))
        let broken = ScriptedBrain([.unavailable(retryAfter: nil), .unavailable(retryAfter: nil), .unavailable(retryAfter: nil)])
        let second = try await loop(broken, FakeHands([form])).run()
        XCTAssertEqual(second.ending, .error)
        XCTAssertEqual(second.steps, 3)
    }

    /// The host's ceiling ends the errand by its own error; what the brain kept so far was heard first.
    func testTheHostsCeilingEndsTheErrandAndWhatWasKeptIsHeard() async {
        let brain = ScriptedBrain([.actions(#"[{"scroll": {}}]"#, memory: "Found 3 so far."),
                                   .actions(#"[{"scroll": {}}]"#, memory: "Found 4 so far.")])
        let hands = FakeHands([form])
        hands.maxSteps = 2
        var kept: [String] = []
        do {
            _ = try await loop(brain, hands, kept: { kept.append($0) }).run()
            XCTFail("the ceiling must end the errand")
        } catch {
            XCTAssertTrue(error is CeilingForTest)
        }
        XCTAssertEqual(kept, ["Found 3 so far.", "Found 4 so far."])
    }

    /// Stop ends the errand.
    func testStopEndsTheErrand() async {
        let run = loop(ScriptedBrain([]), FakeHands([form]))
        let task = Task { try await run.run() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Stop must end the errand")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// done beside other actions is not taken: it must stand alone.
    func testDoneBesideOtherActionsIsNotTaken() async throws {
        let brain = ScriptedBrain([.actions(#"[{"scroll": {}}, {"done": {"text": "early"}}]"#),
                                   .actions(#"[{"done": {"text": "ok"}}]"#)])
        let outcome = try await loop(brain, FakeHands([form])).run()
        XCTAssertEqual(outcome.answer, "ok")
        XCTAssertTrue(brain.state(2).contains("Error: done must be the only action of its step."))
    }

    /// recall's details reach the next step, once.
    func testRecalledDetailsReachTheNextStepOnce() async throws {
        let brain = ScriptedBrain([.actions(#"[{"recall": {"question": "my email"}}]"#),
                                   .actions(#"[{"scroll": {}}]"#), .actions(#"[{"done": {"text": "ok"}}]"#)])
        _ = try await loop(brain, FakeHands([form]), recall: ["My email is sam@acme.test"]).run()
        XCTAssertTrue(brain.state(2).contains("<read_state>\nrecall my email: My email is sam@acme.test\n</read_state>"))
        XCTAssertFalse(brain.state(3).contains("<read_state>"))
    }

    /// Enter goes to the hands with the field just typed into and its text; what they say of it is the result.
    func testEnterGoesToTheHandsWithTheFieldTypedInto() async throws {
        let brain = ScriptedBrain([.actions(#"[{"input": {"index": 1, "text": "Sam"}}, {"send_keys": {"keys": "Enter"}}]"#),
                                   .actions(#"[{"done": {"text": "x", "success": false}}]"#)])
        let hands = FakeHands([form])
        hands.enterVerdict = BrainActed(kind: .userSaidNo, asked: "Send the form?")
        let outcome = try await loop(brain, hands).run()
        XCTAssertEqual(hands.done, ["type 1 Sam", "enter 1 Sam"])
        XCTAssertEqual(outcome.asked, ["Send the form?"])
        XCTAssertTrue(brain.state(2).contains("Not done: The user said no."))
    }

    /// Enter with nothing typed, and any other key, is not pressed.
    func testOnlyEnterAfterTypingIsPressed() async throws {
        let brain = ScriptedBrain([.actions(#"[{"send_keys": {"keys": "Enter"}}, {"send_keys": {"keys": "Escape"}}]"#),
                                   .actions(#"[{"done": {"text": "x"}}]"#)])
        let hands = FakeHands([form])
        _ = try await loop(brain, hands).run()
        XCTAssertEqual(hands.done, [])
        XCTAssertTrue(brain.state(2).contains("Not done: type into a field first, then press Enter."))
        XCTAssertTrue(brain.state(2).contains("Not done: only Enter can be pressed, in a field just typed into."))
    }

    /// Typing without clearing adds to what the field holds.
    func testTypingWithoutClearingAddsToTheField() async throws {
        let brain = ScriptedBrain([.actions(#"[{"input": {"index": 1, "text": " world", "clear": false}}]"#),
                                   .actions(#"[{"done": {"text": "x"}}]"#)])
        let hands = FakeHands([form])
        _ = try await loop(brain, hands).run()
        XCTAssertEqual(hands.done, ["type 1 Hello world"])
    }

    /// The same action that failed three times on a page is not run a fourth time there: the brain is told to try
    /// something else.
    func testAnActionThatKeepsFailingIsNotRunAgain() async throws {
        let click = #"[{"click": {"index": 2}}]"#
        let brain = ScriptedBrain([.actions(click), .actions(click), .actions(click), .actions(click),
                                   .actions(#"[{"done": {"text": "x", "success": false}}]"#)])
        let hands = FakeHands([form])
        hands.verdicts["Send"] = BrainActed(kind: .notDone, note: "the control is covered.")
        _ = try await loop(brain, hands).run()
        XCTAssertTrue(brain.state(4).contains("Not done: the control is covered."))
        XCTAssertTrue(brain.state(5).contains("Not done: this exact action already failed 3 times on this page"))
        XCTAssertEqual(hands.acts.count, 3, "the fourth click never reaches the hands")
        XCTAssertEqual(brain.asked.count, 5)
    }

    /// An address the model writes goes to the hands as a link's would — asked about by its words and Jev — never
    /// as a search the app built; a search the app builds is one.
    func testAModelWrittenAddressIsNoPlannedSearch() async throws {
        let brain = ScriptedBrain([.actions(#"[{"navigate": {"url": "https://shop.test/unsubscribe"}}]"#),
                                   .actions(#"[{"search": {"query": "cheap books"}}]"#),
                                   .actions(#"[{"done": {"text": "x", "success": false}}]"#)])
        let hands = FakeHands([form, form, form])
        _ = try await loop(brain, hands).run()
        XCTAssertEqual(hands.acts.map(\.isPlannedSearch), [false, true])
        XCTAssertEqual(hands.acts.first?.destination, "https://shop.test/unsubscribe")
    }

    /// A done that claims success is checked: rejected, the brain hears why and goes on; rejected again, the
    /// errand ends not finished.
    func testADoneTheCheckRejectsEndsNotFinished() async throws {
        let rejected = ProLLMClient.Outcome.answered(.init(text: #"{"reasoning": "r", "verdict": false, "failure_reason": "The user said no to the send.", "impossible_task": false, "reached_captcha": false}"#,
                                                           toolCalls: [], finishReason: "stop", inputTokens: 1,
                                                           outputTokens: 1, costUSD: 0))
        let brain = ScriptedBrain([.actions(#"[{"done": {"text": "Sent!", "success": true}}]"#),
                                   .actions(#"[{"done": {"text": "Sent!", "success": true}}]"#)], verdicts: [rejected, rejected])
        let outcome = try await loop(brain, FakeHands([form])).run()
        XCTAssertEqual(outcome.ending, .notDone)
        XCTAssertTrue(brain.state(3).contains("Error: done was rejected by the check: The user said no to the send."))
    }

    /// A done the check accepts ends the errand done.
    func testADoneTheCheckAcceptsIsDone() async throws {
        let accepted = ProLLMClient.Outcome.answered(.init(text: #"Here: {"verdict": true, "failure_reason": ""}"#,
                                                           toolCalls: [], finishReason: "stop", inputTokens: 1,
                                                           outputTokens: 1, costUSD: 0))
        let brain = ScriptedBrain([.actions(#"[{"done": {"text": "Found it.", "success": true}}]"#)], verdicts: [accepted])
        let outcome = try await loop(brain, FakeHands([form])).run()
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(brain.asked.count, 2)
        XCTAssertTrue(brain.asked[1].first?["content"]?.string?.contains("expert judge") == true)
    }

    /// The check reads every step: a send the user said no to is in what it is shown, however long the errand.
    /// No verdict, asked twice, is no confirmation: the done is rejected.
    func testTheCheckReadsTheNoAndNoVerdictIsNoConfirmation() async throws {
        let noVerdict = ProLLMClient.Outcome.answered(.init(text: "I think it went well.", toolCalls: [],
                                                            finishReason: "stop", inputTokens: 1, outputTokens: 1, costUSD: 0))
        let brain = ScriptedBrain([.actions(#"[{"click": {"index": 2}}]"#),
                                   .actions(#"[{"done": {"text": "Sent!", "success": true}}]"#),
                                   .actions(#"[{"done": {"text": "Sent!", "success": true}}]"#)],
                                  verdicts: [noVerdict, noVerdict, noVerdict, noVerdict])
        let hands = FakeHands([form])
        hands.verdicts["Send"] = BrainActed(kind: .userSaidNo, asked: "Send?")
        let outcome = try await loop(brain, hands).run()
        XCTAssertEqual(outcome.ending, .notDone)
        let judged = brain.asked[2].last?["content"]?.string ?? ""
        XCTAssertTrue(judged.contains("The user said no"), judged)
        XCTAssertTrue(brain.state(5).contains("done was rejected by the check: the check could not confirm the result."))
    }

    /// The check is shown, for each step, the page the app read after it — address, title and first words — as the
    /// app's own evidence of what the brain's words rest on; the brain's own history leaves it out.
    func testTheCheckIsShownThePageTheAppReadAfterEachStep() async throws {
        let next = page("https://shop.test/thanks", [element(1, "link", "Home")], title: "Shop", text: "Thank you for your order, Sam.")
        let brain = ScriptedBrain([.actions(#"[{"click": {"index": 2}}]"#),
                                   .actions(#"[{"done": {"text": "Sent.", "success": true}}]"#)])
        let hands = FakeHands([form, next])
        hands.navigating = [2]
        let outcome = try await loop(brain, hands).run()
        XCTAssertEqual(outcome.ending, .done)
        let judged = brain.asked[2].last?["content"]?.string ?? ""
        XCTAssertTrue(judged.contains("Page after the step, as the app read it: https://shop.test/thanks — Shop\nThank you for your order, Sam."),
                      judged)
        XCTAssertFalse(brain.state(2).contains("Page after the step"), "the brain sees the page itself")
    }

    /// The check is shown the page the agent finished on — the one it called done on — which no step's page holds
    /// when done is the brain's first call: a right answer read off the start page is no empty trajectory.
    func testTheCheckIsShownThePageTheAgentFinishedOn() async throws {
        let brain = ScriptedBrain([.actions(#"[{"done": {"text": "Price: $5.", "success": true}}]"#)])
        let outcome = try await loop(brain, FakeHands([form])).run()
        XCTAssertEqual(outcome.ending, .done)
        let judged = brain.asked[1].last?["content"]?.string ?? ""
        XCTAssertTrue(judged.contains("<final_page>\nPage when the agent finished, as the app read it: https://shop.test/form — t\nwords\n</final_page>"),
                      judged)
    }

    /// An extract's short answer stays in the history for every later step, as the reference keeps it; a long one
    /// is shown once, in the next step's read state.
    func testAShortExtractStaysInTheHistoryALongOneIsShownOnce() async throws {
        func answer(_ text: String) -> ProLLMClient.Outcome {
            .answered(.init(text: text, toolCalls: [], finishReason: "stop", inputTokens: 1, outputTokens: 1, costUSD: 0))
        }
        let long = String(repeating: "y", count: 10_000) + " LONG-END"
        let brain = ScriptedBrain([.actions(#"[{"extract": {"query": "the year it sank"}}]"#),
                                   .actions(#"[{"extract": {"query": "every opening hour"}}]"#),
                                   .actions(#"[{"wait": {"seconds": 0}}]"#),
                                   .actions(#"[{"done": {"text": "x", "success": false}}]"#)],
                                  verdicts: [answer("The museum says it sank in 1628."), answer(long)])
        _ = try await loop(brain, FakeHands([form])).run()
        // Calls: step 1, its extract, step 2, its extract, step 3, step 4.
        XCTAssertTrue(brain.state(5).contains("The museum says it sank in 1628."), brain.state(5))
        XCTAssertTrue(brain.state(6).contains("The museum says it sank in 1628."))
        XCTAssertTrue(brain.state(5).contains("LONG-END"), "a long answer is shown once")
        XCTAssertFalse(brain.state(6).contains("LONG-END"), "and only once")
    }

    /// search_page reads the page as the app's reader reads it, never the page's raw text.
    func testSearchPageReadsTheReadersText() async throws {
        let brain = ScriptedBrain([.actions(#"[{"search_page": {"pattern": "Total due"}}]"#),
                                   .actions(#"[{"done": {"text": "x", "success": false}}]"#)])
        let hands = FakeHands([form])
        _ = try await loop(brain, hands).run()
        XCTAssertEqual(hands.done, ["read"])
        XCTAssertTrue(brain.state(2).contains("1 match(es):\n1. ...Price: $5. Total due: $12...."))
    }

    /// Only the web's addresses open; one without a scheme gets https.
    func testOnlyWebAddressesOpen() {
        XCTAssertNil(BrainLoop.webAddress("javascript:alert(1)"))
        XCTAssertNil(BrainLoop.webAddress("file:///etc/passwd"))
        XCTAssertNil(BrainLoop.webAddress("chrome://settings"))
        XCTAssertEqual(BrainLoop.webAddress("example.com/a"), "https://example.com/a")
        XCTAssertEqual(BrainLoop.webAddress(" http://shop.test/x "), "http://shop.test/x")
    }
}

/// A scripted answer: the AgentOutput call with these arguments.
fileprivate extension ProLLMClient.Outcome {
    static func call(_ arguments: String) -> ProLLMClient.Outcome {
        .answered(.init(text: "", toolCalls: [.init(id: "c", name: "AgentOutput", arguments: arguments)],
                        finishReason: "tool_calls", inputTokens: 100, outputTokens: 20, costUSD: 0.001))
    }

    static func actions(_ list: String, memory: String = "m") -> ProLLMClient.Outcome {
        call(#"{"evaluation_previous_goal": "e", "memory": "\#(memory)", "next_goal": "n", "action": \#(list)}"#)
    }

    /// The check's verdict, as its JSON.
    static func verdict(_ passed: Bool) -> ProLLMClient.Outcome {
        .answered(.init(text: #"{"reasoning": "r", "verdict": \#(passed), "failure_reason": ""}"#, toolCalls: [],
                        finishReason: "stop", inputTokens: 1, outputTokens: 1, costUSD: 0))
    }
}
