import XCTest
@testable import MetaWhisp

/// ITER-076 1.3b — the loop asks Jev each step the way jev-ultrafast asks it:
/// the page's elements in the state, one operation choice, one target choice
/// per element operation, and jkudish's two watchers beside them. Only the
/// head of the chosen operation is read back, and only after the answer
/// passes jev-ultrafast's `validate_choice`.
final class JevDecisionEngineTests: XCTestCase {

    private static let goal = "Find the yearly price of ProjectAlpha"

    private func element(_ index: Int, role: String, name: String, href: String? = nil,
                         context: String? = nil, options: [String]? = nil, checked: Bool? = nil,
                         inViewport: Bool = true) -> ObservedElement {
        ObservedElement(index: index, role: role, name: name, text: name, href: href, inputType: nil,
                        heading: nil, region: .main, inViewport: inViewport, context: context,
                        formAction: nil, formMethod: nil, formSubmitLabel: nil, options: options,
                        checked: checked)
    }

    private func action(_ operation: AgentOperation, _ target: ObservedElement? = nil, destination: String? = nil,
                        payload: String? = nil, plannedSearch: Bool = false) -> AgentAction {
        AgentAction(operation: operation, target: target, destination: destination, payload: payload,
                    isPlannedSearch: plannedSearch)
    }

    private lazy var pricing = element(0, role: "link", name: "Pricing", href: "https://alpha.test/pricing")
    private lazy var search = element(1, role: "button", name: "Search")
    private lazy var query = element(2, role: "textbox", name: "Query")
    private lazy var plan = element(3, role: "combobox", name: "Plan", options: ["Monthly", "Yearly"])
    private lazy var remember = element(4, role: "checkbox", name: "Remember me", checked: false)

    /// One page's candidates as the builder makes them: element actions,
    /// then the page-level operations.
    private func candidates(extra: [AgentAction] = []) -> [Candidate] {
        let actions = [
            action(.open, pricing, destination: "https://alpha.test/pricing"),
            action(.click, search),
            action(.type, query),
            action(.select, plan, payload: "Monthly"),
            action(.select, plan, payload: "Yearly"),
            action(.click, remember),
        ] + extra + [action(.scroll), action(.wait), action(.back), action(.done), action(.stuck)]
        return actions.enumerated().map { Candidate(id: "c\($0.offset + 1)", action: $0.element) }
    }

    private func request(_ candidates: [Candidate], recent: [RecentAction] = []) -> ChooseRequest {
        ChooseRequest(candidates: candidates, subgoal: AgentPlan.Subgoal(description: "Pricing", terms: ["price"]),
                      rowsCollected: 0, rowsWanted: 1, goal: Self.goal,
                      page: PageSummary(url: "https://alpha.test/", title: "Alpha", text: "Alpha makes notes"),
                      recentActions: recent)
    }

    private func encoded(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func response(_ answers: String, usage: String = #"{"input_tokens":1000,"output_tokens":20}"#) throws
        -> JevResponse {
        try JSONDecoder().decode(JevResponse.self,
                                 from: Data(#"{"model":"jev-1.13.0","usage":\#(usage),"answers":{\#(answers)}}"#.utf8))
    }

    private static let watchers = #""goal_done":{"type":"noul","noul":0.3},"stuck":{"type":"noul","noul":0.1}"#

    private static func choice(_ chosen: String, _ probabilities: [String: Double], confidence: Double) -> String {
        let pairs = probabilities.sorted { $0.key < $1.key }.map { #""\#($0.key)":\#($0.value)"# }
        return #"{"type":"choice","choice":"\#(chosen)","confidence":\#(confidence),"probabilities":{\#(pairs.joined(separator: ","))}}"#
    }

    private static let operations = ["CLICK", "TYPE_TEXT", "SELECT", "SCROLL_DOWN", "WAIT", "BACK", "DONE", "BLOCKED"]

    private static func operation(_ chosen: String, confidence: Double = 0.9) -> String {
        var probabilities = Dictionary(uniqueKeysWithValues: operations.map { ($0, (1 - 0.93) / 7) })
        probabilities[chosen] = 0.93
        return #""operation":"# + choice(chosen, probabilities, confidence: confidence)
    }

    // MARK: - The question

    /// jev-ultrafast `model.py` `action_space` and `choose`: one element per
    /// node, indexed "1", "2", … in order; a select's options as "i:k"; a link
    /// is clicked; the state holds the page, the elements and the recent
    /// actions; the operation choice offers the element operations, then the
    /// page's controls, then DONE and BLOCKED. The state also holds the task,
    /// which jkudish's two watchers read (`navigate.ts` 766-767; review of A2,
    /// P1-1).
    /// ITER-076 stage 3 (№ 65): Jev sees the whole visible page. A page of
    /// 240 controls, each named as a search result is (about 80 characters),
    /// beside the page's text whole, fits one step's request — and, since
    /// 2026-10-08, as many of them as Jev's context holds (about 185 here),
    /// those on screen first: the whole page is past its 32,000 tokens.
    func testAWholePageOfTwoHundredFortyControlsFitsOneRequest() throws {
        let links = (0..<240).map { index in
            action(.open, element(index, role: "link",
                                  name: "A result about voice notes, meetings and dictation for teams \(index)",
                                  href: "https://site-\(index).test/articles/voice-notes"),
                   destination: "https://site-\(index).test/articles/voice-notes")
        }
        let page = PageSummary(url: "https://search.test/?q=voice+notes", title: "voice notes - Search",
                               text: String(repeating: "voice notes ", count: 500))
        let candidates = (links + [action(.scroll), action(.wait), action(.done), action(.stuck)]).enumerated()
            .map { Candidate(id: "c\($0.offset + 1)", action: $0.element) }
        let step = try JevDecisionEngine.step(for: ChooseRequest(candidates: candidates,
                                                                 subgoal: AgentPlan.Subgoal(description: "Results",
                                                                                            terms: ["voice"]),
                                                                 rowsCollected: 0, rowsWanted: 1, goal: Self.goal,
                                                                 page: page, recentActions: []))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let bytes = try encoder.encode(step.state).count + encoder.encode(step.questions).count + 64
        XCTAssertLessThanOrEqual(bytes, JevEngine.maxBodyBytes, "\(bytes) bytes")
        let offered = try XCTUnwrap(step.targets["CLICK"]?.count)
        XCTAssertGreaterThan(offered, 150, "most of the page")
        XCTAssertLessThan(offered, 240, "as many as Jev's context holds")
    }

    /// 2026-10-08 (live, a news front page): 240 links, each told apart by its
    /// row, came to 80,625 bytes of state and largest question, and Jev
    /// refused the step — past its 32,000-token context. A step holds its
    /// state with its largest question within `maxStatePlusQuestionBytes`, as
    /// a reference browser agent's token budget does: a page with more offers
    /// fewer controls — those on screen first, then from the page's top.
    func testAStepHoldsItsStateAndLargestQuestionWithinJevsContext() throws {
        let row = String(repeating: "123 points by someone 2 hours ago | hide | past | 45 comments ", count: 2)
        let links = (0..<240).map { index in
            action(.click, element(index, role: "link", name: "\(index % 12) minutes ago",
                                   context: "\(index). A story title on the front page " + row,
                                   inViewport: index >= 200))
        }
        let candidates = (links + [action(.scroll), action(.wait), action(.done), action(.stuck)]).enumerated()
            .map { Candidate(id: "c\($0.offset + 1)", action: $0.element) }
        let step = try JevDecisionEngine.step(for: request(candidates))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let largest = try step.questions.questions.values.map { try encoder.encode($0).count }.max() ?? 0
        let bytes = try encoder.encode(step.state).count + largest
        XCTAssertLessThanOrEqual(bytes, JevDecisionEngine.maxStatePlusQuestionBytes, "\(bytes) bytes")
        let offered = Set(try XCTUnwrap(step.targets["CLICK"]).values)
        XCTAssertLessThan(offered.count, 240, "the premise: the whole page does not fit")
        XCTAssertTrue((201...240).allSatisfy { offered.contains("c\($0)") }, "every control on screen is offered")
        XCTAssertTrue(offered.contains("c1"), "then the page's top")
        XCTAssertFalse(offered.contains("c200"), "the last off screen is the first left out")
        XCTAssertEqual(Set(step.controls.keys), ["SCROLL_DOWN", "WAIT", "DONE", "BLOCKED"], "the page's own operations stay")
    }

    func testTheStepIsAskedInJevUltrafastsShape() throws {
        let recent = [RecentAction(label: "Search", kind: "click", typed: nil, pageChanged: true)]
        let step = try JevDecisionEngine.step(for: request(candidates(), recent: recent))

        XCTAssertEqual(Set(step.questions.questions.keys),
                       ["operation", "click_target", "type_text_target", "select_target", "goal_done", "stuck"])
        guard case .choice(let offered) = step.questions["operation"]?.kind else { return XCTFail("no operation") }
        XCTAssertEqual(offered.map(\.name), Self.operations)
        guard case .choice(let clicks) = step.questions["click_target"]?.kind,
              case .choice(let selects) = step.questions["select_target"]?.kind,
              case .choice(let types) = step.questions["type_text_target"]?.kind else { return XCTFail("no targets") }
        XCTAssertEqual(clicks.map(\.name), ["1", "2", "5"])
        XCTAssertEqual(types.map(\.name), ["3"])
        XCTAssertEqual(selects.map(\.name), ["4:1", "4:2"])

        let state = try encoded(step.state)
        XCTAssertEqual(state["task"] as? String, Self.goal, "the watchers ask about the task")
        let page = try XCTUnwrap(state["page"] as? [String: String])
        XCTAssertEqual(page, ["url": "https://alpha.test/", "title": "Alpha", "text": "Alpha makes notes"])
        let elements = try XCTUnwrap(state["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.map { $0["index"] as? String }, ["1", "2", "3", "4", "5"])
        XCTAssertEqual(elements.map { $0["label"] as? String }, ["Pricing", "Search", "Query", "Plan", "Remember me"])
        XCTAssertEqual(elements.map { $0["operations"] as? [String] },
                       [["CLICK"], ["CLICK"], ["TYPE_TEXT"], ["SELECT"], ["CLICK"]])
        XCTAssertEqual(elements[4]["checked"] as? String, "false")
        let options = try XCTUnwrap(elements[3]["options"] as? [[String: String]])
        // jev-ultrafast lists an option under the select's action label,
        // "Select → Option" (`model.py` 76; review of A2, P2-11).
        XCTAssertEqual(options, [["index": "4:1", "label": "Plan → Monthly", "value": "Monthly"],
                                 ["index": "4:2", "label": "Plan → Yearly", "value": "Yearly"]])
        let actions = try XCTUnwrap(state["recent_actions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0]["action"] as? String, "Search")
        XCTAssertEqual(actions[0]["kind"] as? String, "click")
        XCTAssertEqual(actions[0]["page_changed"] as? Bool, true)
        XCTAssertTrue(actions[0].keys.contains("text"), "the typed text is sent as null, as jev-ultrafast sends it")
    }

    /// What each of the last six actions visibly did reaches Jev with it, as a reference browser agent sends its
    /// recent history (`agent.py` `_history`, `policy.py` 340, MIT): older ones go without it, and one
    /// the next look has not told yet goes as null — every key is sent. Jev's rules read it: an action that changed
    /// nothing did nothing. Without it Jev took a link to the page itself, named like the task's, again and again
    /// (qa-practice new tab, 2026-10-16).
    func testTheLastSixActionsReachJevWithWhatEachDid() throws {
        let recent = (1...8).map { RecentAction(label: "Step \($0)", kind: "click", typed: nil, pageChanged: true,
                                                effect: "changed Step \($0) checked: false -> true") }
            + [RecentAction(label: "New tab link", kind: "click", typed: nil, pageChanged: false,
                            effect: "nothing visible changed")]
        let step = try JevDecisionEngine.step(for: request(candidates(), recent: recent))
        let actions = try XCTUnwrap(try encoded(step.state)["recent_actions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 9)
        XCTAssertTrue(actions.allSatisfy { $0.keys.contains("effect") }, "every key, null included")
        XCTAssertEqual(actions.map { $0["effect"] as? String },
                       [nil, nil, nil] + (4...8).map { "changed Step \($0) checked: false -> true" }
                        + ["nothing visible changed"])
        XCTAssertTrue(JevQuestions.nextActionRules.contains(
            #"An action whose effect is "nothing visible changed" did nothing: take another way, not the same action."#))
    }

    /// Owner decision 4: a field's value reaches Jev as jev-ultrafast sends it —
    /// the element's `value` in the state (a select's chosen option), and the
    /// target's `current_value`.
    func testAFieldsValueReachesTheStateAndItsTarget() throws {
        var filled = query
        filled.value = "voice notes"
        var chosen = plan
        chosen.value = "Monthly"
        let candidates = [action(.type, filled), action(.select, chosen, payload: "Yearly"), action(.done), action(.stuck)]
            .enumerated().map { Candidate(id: "c\($0.offset + 1)", action: $0.element) }
        let step = try JevDecisionEngine.step(for: request(candidates))
        let elements = try XCTUnwrap(try encoded(step.state)["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.map { $0["value"] as? String }, ["voice notes", "Monthly"])
        let body = try encoded(JevQuestionSet(step.questions.questions.filter { $0.key == "type_text_target" }))
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        XCTAssertTrue(text.contains(#""current_value":"voice notes""#), text)
    }

    /// A select option's target reads "[i:k] Select → Option", as
    /// jev-ultrafast labels it, so the choice names the option.
    func testASelectOptionIsLabelledWithItsSelect() throws {
        let step = try JevDecisionEngine.step(for: request(candidates()))
        let body = try encoded(JevQuestionSet(step.questions.questions.filter { $0.key == "select_target" }))
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        XCTAssertTrue(text.contains("[4:2] Plan → Yearly"), text)
    }

    /// ITER-076 I-10 (critic P1-9): controls that share a label — "Add to
    /// cart" in three rows — are each described to Jev with their row, or
    /// their section when they sit in none, as data beside the label, in the
    /// target choice and in the state. A control alone with its label is
    /// described as before.
    /// Three "Add to cart" — two in rows, one under a heading alone — and a
    /// control alone with its label.
    private func carts() -> [Candidate] {
        func cart(_ index: Int, context: String?, heading: String?) -> ObservedElement {
            ObservedElement(index: index, role: "button", name: "Add to cart", text: "Add to cart", href: nil,
                            inputType: nil, heading: heading, region: .main, inViewport: true, context: context,
                            formAction: nil, formMethod: nil, formSubmitLabel: nil, options: nil, checked: nil)
        }
        let carts = [cart(0, context: "Blue mug", heading: "Mugs"), cart(1, context: "Green mug", heading: "Mugs"),
                     cart(2, context: nil, heading: "Teapots")]
        let gift = element(3, role: "button", name: "Buy the gift card", context: "Gift card")
        let set = (carts + [gift]).map { action(.click, $0) } + [action(.done), action(.stuck)]
        return set.enumerated().map { Candidate(id: "c\($0.offset + 1)", action: $0.element) }
    }

    /// The owner approved the row context on 2026-10-06 (approval page item
    /// 8): the request that goes out — byte for byte, as the engine sends it —
    /// carries each twin's row under `context`, and a lone label none.
    func testTheStepThatGoesOutCarriesTheRowContextTheOwnerApproved() async throws {
        let jev = RecordedJev { _, _ in .answers(operation: "DONE") }
        _ = try await jev.engine.choose(request(carts()))
        let body = String(decoding: try XCTUnwrap(jev.bodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains("Add to cart"), "the premise: the twins went out")
        XCTAssertTrue(body.contains(#""context""#), body)
        for row in ["Blue mug", "Green mug", "Teapots"] { XCTAssertTrue(body.contains(row), row) }
        XCTAssertFalse(body.contains("Gift card"), "a lone label carries no row")
    }

    /// With the row context on — as it will be once approved.
    func testTargetsThatShareALabelCarryTheirRowAndALoneOneDoesNot() throws {
        let step = try JevDecisionEngine.step(for: request(carts()), rowContext: true)
        guard case .choice(let clicks) = step.questions["click_target"]?.kind else { return XCTFail("no clicks") }
        let described = clicks.map { option -> String? in
            guard case .object(let fields)? = option.description, case .string(let context)? = fields["context"] else {
                return nil
            }
            return context
        }
        XCTAssertEqual(described, ["Blue mug", "Green mug", "Teapots", nil])
        guard case .object(let alone)? = clicks.last?.description else { return XCTFail("no description") }
        XCTAssertEqual(Set(alone.keys), ["element", "current_value", "role"], "a lone label is described as before")
        let elements = try XCTUnwrap(try encoded(step.state)["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.map { $0["context"] as? String }, ["Blue mug", "Green mug", "Teapots", nil])
        XCTAssertEqual(elements.map { $0["label"] as? String }, ["Add to cart", "Add to cart", "Add to cart",
                                                                  "Buy the gift card"], "the labels are unchanged")
    }

    /// 2026-10-15 (the bench's "new tab" page: the menu's "New tab link" leads to the page the tab shows, and Jev
    /// chose it over the link that opened the new page): a link to the page itself is told apart by its context, "a
    /// link to this same page" — it stays offered ("Start over" reloads a form); another link carries none.
    func testALinkToThePageItselfSaysSo() throws {
        let itself = element(0, role: "link", name: "New tab link", href: "https://alpha.test/")
        let other = element(1, role: "link", name: "New page will be opened on a new tab", href: "https://alpha.test/new")
        let candidates = [action(.open, itself, destination: "https://alpha.test/"),
                          action(.open, other, destination: "https://alpha.test/new"), action(.done), action(.stuck)]
            .enumerated().map { Candidate(id: "c\($0.offset + 1)", action: $0.element) }
        let step = try JevDecisionEngine.step(for: request(candidates))
        let elements = try XCTUnwrap(try encoded(step.state)["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.map { $0["context"] as? String }, ["a link to this same page", nil])
        let listed = ErrandModel.recoverRequest(goal: "g", subgoal: nil, actions: candidates.map(\.action),
                                                page: ObservedPage(url: "https://alpha.test/", title: "Alpha",
                                                                   truncated: false, flags: .none, elements: []),
                                                notes: "", steps: [], memory: [], today: "2026-10-15", stillToDo: [],
                                                problem: "p").messages.last?["content"]?.string ?? ""
        XCTAssertTrue(listed.contains(#""label": "New tab link", "role": "link", "href": "a link to this same page"}"#), listed)
        XCTAssertTrue(listed.contains(#""href": "https://alpha.test/new"}"#), listed)
    }

    /// «More» and a planned search have no label in the approved texts:
    /// neither is offered, and nothing else is lost.
    func testMoreAndAPlannedSearchAreNotOffered() throws {
        let extra = [action(.more), action(.open, destination: "https://search.test/?q=alpha", plannedSearch: true)]
        let step = try JevDecisionEngine.step(for: request(candidates(extra: extra)))
        guard case .choice(let clicks) = step.questions["click_target"]?.kind else { return XCTFail("no clicks") }
        XCTAssertEqual(clicks.map(\.name), ["1", "2", "5"])
        guard case .choice(let offered) = step.questions["operation"]?.kind else { return XCTFail("no operation") }
        XCTAssertEqual(offered.map(\.name), Self.operations)
    }

    /// A page with no element to act on still asks the operation, with the
    /// controls and the two ends.
    func testAPageWithOnlyControlsAsksTheOperationAlone() throws {
        let only = [action(.scroll), action(.wait), action(.back), action(.done), action(.stuck)]
            .enumerated().map { Candidate(id: "c\($0.offset + 1)", action: $0.element) }
        let step = try JevDecisionEngine.step(for: request(only))
        XCTAssertEqual(Set(step.questions.questions.keys), ["operation", "goal_done", "stuck"])
    }

    // MARK: - The answer

    /// The chosen operation's target names the candidate, and the step's
    /// confidence is the lower of the operation's and the target's.
    func testAClickPicksItsCandidateAtTheLowerConfidence() throws {
        let set = candidates()
        let step = try JevDecisionEngine.step(for: request(set))
        let answers = Self.operation("CLICK", confidence: 0.9) + ","
            + #""click_target":"# + Self.choice("2", ["1": 0.1, "2": 0.85, "5": 0.05], confidence: 0.7) + ","
            + Self.watchers
        let answer = try JevDecisionEngine.answer(try response(answers), to: step)
        XCTAssertEqual(answer.candidateID, set.first { $0.action.target?.name == "Search" }?.id)
        XCTAssertEqual(answer.confidence, 0.7, accuracy: 1e-9)
        XCTAssertEqual(answer.goalMet ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(answer.stuck ?? -1, 0.1, accuracy: 1e-9)
    }

    /// ITER-076 stage 4a: the answer also carries, for the errand's record,
    /// Jev's own confidences — the operation's and its target's — and how
    /// many targets the chosen operation was offered; a page control has no
    /// target, so neither.
    func testTheAnswerKeepsJevsOwnConfidencesAndHowManyTargetsWereOffered() throws {
        let step = try JevDecisionEngine.step(for: request(candidates()))
        let click = try JevDecisionEngine.answer(try response(Self.operation("CLICK", confidence: 0.9) + ","
            + #""click_target":"# + Self.choice("2", ["1": 0.1, "2": 0.85, "5": 0.05], confidence: 0.7) + ","
            + Self.watchers), to: step)
        XCTAssertEqual(click.operationConfidence ?? -1, 0.9, accuracy: 1e-9)
        XCTAssertEqual(click.targetConfidence ?? -1, 0.7, accuracy: 1e-9)
        XCTAssertEqual(click.targets, 3, "a link, a button and a checkbox are clicked")
        let select = try JevDecisionEngine.answer(try response(Self.operation("SELECT", confidence: 0.8) + ","
            + #""select_target":"# + Self.choice("4:2", ["4:1": 0.1, "4:2": 0.9], confidence: 0.6) + ","
            + Self.watchers), to: step)
        XCTAssertEqual(select.targetConfidence ?? -1, 0.6, accuracy: 1e-9)
        XCTAssertEqual(select.targets, 2, "a select's two options")
        let scroll = try JevDecisionEngine.answer(try response(Self.operation("SCROLL_DOWN", confidence: 0.88) + ","
                                                               + Self.watchers), to: step)
        XCTAssertEqual(scroll.operationConfidence ?? -1, 0.88, accuracy: 1e-9)
        XCTAssertNil(scroll.targetConfidence)
        XCTAssertNil(scroll.targets)
    }

    /// A select's option key picks that option's candidate.
    func testASelectPicksTheOptionsCandidate() throws {
        let set = candidates()
        let step = try JevDecisionEngine.step(for: request(set))
        let answers = Self.operation("SELECT") + ","
            + #""select_target":"# + Self.choice("4:2", ["4:1": 0.1, "4:2": 0.9], confidence: 0.9) + ","
            + Self.watchers
        let answer = try JevDecisionEngine.answer(try response(answers), to: step)
        XCTAssertEqual(answer.candidateID, set.first { $0.action.payload == "Yearly" }?.id)
    }

    /// The page's controls and the two ends map to their own candidates, at
    /// the operation's confidence.
    func testControlsAndEndsPickTheirCandidates() throws {
        let set = candidates()
        let step = try JevDecisionEngine.step(for: request(set))
        let expected: [(String, AgentOperation)] = [("SCROLL_DOWN", .scroll), ("WAIT", .wait), ("BACK", .back),
                                                   ("DONE", .done), ("BLOCKED", .stuck)]
        for (name, operation) in expected {
            let answer = try JevDecisionEngine.answer(try response(Self.operation(name, confidence: 0.88) + ","
                                                                    + Self.watchers), to: step)
            XCTAssertEqual(answer.candidateID, set.first { $0.action.operation == operation }?.id, name)
            XCTAssertEqual(answer.confidence, 0.88, accuracy: 1e-9, name)
        }
    }

    /// jev-ultrafast `validate_choice`: probabilities over exactly the offered
    /// options, each within 0…1, summing to 1 within 0.02, and the choice the
    /// most likely. Anything else is no action.
    func testAnAnswerOutsideValidateChoiceIsNotActedOn() throws {
        let step = try JevDecisionEngine.step(for: request(candidates()))
        let target = { (probabilities: [String: Double], chosen: String) in
            Self.operation("CLICK") + "," + #""click_target":"#
                + Self.choice(chosen, probabilities, confidence: 0.9) + "," + Self.watchers
        }
        let broken = [
            target(["1": 0.1, "2": 0.9], "2"),                    // not every option
            target(["1": 0.05, "2": 0.9, "5": 0.05, "9": 0], "2"), // an option never offered
            target(["1": 0.05, "2": 0.8, "5": 0.05], "2"),         // sums to 0.9
            target(["1": 0.6, "2": 0.35, "5": 0.05], "2"),         // not the most likely
            target(["1": -0.1, "2": 1.05, "5": 0.05], "2"),        // outside 0…1
        ]
        for answers in broken {
            XCTAssertThrowsError(try JevDecisionEngine.answer(try response(answers), to: step), answers)
        }
        // The operation's own distribution is held to the same rule.
        var skewed = Dictionary(uniqueKeysWithValues: Self.operations.map { ($0, 0.0) })
        skewed["CLICK"] = 0.4
        skewed["WAIT"] = 0.6
        let wrongChoice = #""operation":"# + Self.choice("CLICK", skewed, confidence: 0.9) + ","
            + #""click_target":"# + Self.choice("2", ["1": 0.05, "2": 0.9, "5": 0.05], confidence: 0.9) + ","
            + Self.watchers
        XCTAssertThrowsError(try JevDecisionEngine.answer(try response(wrongChoice), to: step))
    }

    /// The heads are speculative (jev-ultrafast `model.py`): only the chosen
    /// operation's target is checked and read.
    func testOnlyTheChosenOperationsTargetIsChecked() throws {
        let set = candidates()
        let step = try JevDecisionEngine.step(for: request(set))
        let answers = Self.operation("CLICK") + ","
            + #""click_target":"# + Self.choice("1", ["1": 0.9, "2": 0.05, "5": 0.05], confidence: 0.9) + ","
            + #""type_text_target":"# + Self.choice("3", ["3": 0.4], confidence: 0.4) + ","
            + Self.watchers
        XCTAssertEqual(try JevDecisionEngine.answer(try response(answers), to: step).candidateID,
                       set.first { $0.action.target?.name == "Pricing" }?.id)
    }

    /// Jev bills input tokens only, at $0.042 a million: the cost the budget
    /// settles comes from the answer's own count.
    func testTheCostComesFromTheInputTokens() throws {
        let step = try JevDecisionEngine.step(for: request(candidates()))
        let answer = try JevDecisionEngine.answer(try response(Self.operation("WAIT") + "," + Self.watchers), to: step)
        XCTAssertEqual(answer.usage?.costUSD ?? -1, 1000 * 0.042 / 1_000_000, accuracy: 1e-12)
        XCTAssertEqual(JevDecisionEngine().worstCaseUSD, 32_000 * 0.042 / 1_000_000, accuracy: 1e-12)
    }

    // MARK: - Risk

    /// C and E read the errand's goal as `task`, the page, and the control; a
    /// select's control names the option it would choose.
    func testTheRiskQuestionsReadTheGoalThePageAndTheChosenOption() throws {
        let select = action(.select, plan, payload: "Yearly")
        let asked = try JevDecisionEngine.risk(for: select,
                                               on: PageSummary(url: "https://alpha.test/", title: "Alpha", text: ""),
                                               goal: Self.goal)
        XCTAssertEqual(Set(asked.questions.questions.keys), ["destructive_0", "grant_0"])
        XCTAssertEqual(asked.state.task, Self.goal)
        XCTAssertEqual(asked.state.page, .init(url: "https://alpha.test/", title: "Alpha"))
        XCTAssertEqual(asked.state.targets.map(\.label), ["Plan → Yearly"])

        let answers = #""destructive_0":{"type":"noul","noul":0.12},"grant_0":{"type":"noul","noul":0.34}"#
        let risk = try JevDecisionEngine.riskAnswer(try response(answers))
        XCTAssertEqual(risk.irreversible ?? -1, 0.12, accuracy: 1e-9)
        XCTAssertEqual(risk.grant ?? -1, 0.34, accuracy: 1e-9)
    }

    // MARK: - The call

    /// Anything but an answer — the server unavailable, a late call, an
    /// invalid answer, no Pro — is a miss: the engine throws and nothing acts.
    func testAnOutcomeOtherThanAnAnswerIsAMiss() async {
        let engine = JevDecisionEngine(jev: JevEngine(licenseKey: { "LICENSE-1" }, send: { _ in
            (Data(), HTTPURLResponse(url: JevEngine.endpoint, statusCode: 503, httpVersion: nil,
                                     headerFields: ["Retry-After": "60"])!)
        }, log: { _ in }))
        do {
            _ = try await engine.choose(request(candidates()))
            XCTFail("an unavailable Jev must not answer")
        } catch {}
        do {
            _ = try await engine.risk(of: action(.click, search),
                                      on: PageSummary(url: "https://alpha.test/", title: "Alpha", text: ""),
                                      goal: Self.goal)
            XCTFail("an unavailable Jev must not answer")
        } catch {}
    }

    /// ITER-076 I-05: a call that gets no answer says what the server said —
    /// no Pro, the day's limit and when it resets, the service down and when
    /// to ask again, its timeout, a request it refused — for both questions.
    func testTheFailureSaysWhatTheServerSaid() async {
        let cases: [(status: Int, retryAfter: String?, failure: JevDecisionEngine.Failure)] = [
            (401, nil, .noPro),
            (429, "3600", .dailyLimit(retryAfter: .seconds(3600))),
            (503, "60", .unavailable(retryAfter: .seconds(60))),
            (504, nil, .timedOut),
            (400, nil, .invalid),
        ]
        for (status, retryAfter, failure) in cases {
            let engine = JevDecisionEngine(jev: JevEngine(licenseKey: { "LICENSE-1" }, send: { _ in
                (Data(), HTTPURLResponse(url: JevEngine.endpoint, statusCode: status, httpVersion: nil,
                                         headerFields: retryAfter.map { ["Retry-After": $0] })!)
            }, log: { _ in }))
            do {
                _ = try await engine.choose(request(candidates()))
                XCTFail("\(status) must not answer")
            } catch {
                XCTAssertEqual(error as? JevDecisionEngine.Failure, failure, "\(status)")
            }
            do {
                _ = try await engine.risk(of: action(.click, search),
                                          on: PageSummary(url: "https://alpha.test/", title: "Alpha", text: ""),
                                          goal: Self.goal)
                XCTFail("\(status) must not answer")
            } catch {
                XCTAssertEqual(error as? JevDecisionEngine.Failure, failure, "\(status)")
            }
        }
    }
}
