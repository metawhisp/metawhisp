import XCTest
@testable import MetaWhisp

/// What the brain reads: its instruction, its one tool, and each step's state (browser-use's prompts, MIT).
final class BrainPromptTests: XCTestCase {
    private func element(_ index: Int, _ role: String, _ name: String, text: String = "", href: String? = nil,
                         inputType: String? = nil, heading: String? = nil, context: String? = nil,
                         options: [String]? = nil, checked: Bool? = nil, value: String? = nil,
                         submits: Bool? = nil) -> ObservedElement {
        var e = ObservedElement(index: index, key: index, role: role, name: name, text: text, href: href,
                                inputType: inputType, heading: heading, region: .main, inViewport: true,
                                context: context, formAction: nil, formMethod: nil, formSubmitLabel: nil,
                                options: options, checked: checked, value: value)
        e.submits = submits
        return e
    }

    private func page(_ elements: [ObservedElement], text: String = "Welcome to the shop.",
                      url: String = "https://shop.test/contact") -> ObservedPage {
        ObservedPage(url: url, title: "Contact", truncated: false, flags: .none, elements: elements, text: text)
    }

    /// The instruction names its step budget and keeps the rails' rules a user's agent needs.
    func testTheInstructionNamesItsActionBudgetAndTheRails() {
        let prompt = BrainPrompt.system(maxActions: 5)
        XCTAssertTrue(prompt.contains("a maximum of 5 actions per step"))
        XCTAssertFalse(prompt.contains("{max_actions}"))
        XCTAssertTrue(prompt.contains("Never type passwords, card numbers or one-time codes."))
        XCTAssertTrue(prompt.contains("the app asks the user for a Yes by itself"))
        XCTAssertTrue(prompt.contains("Even when the request says to ask the user before sending, press the send control"))
        XCTAssertTrue(prompt.contains("call recall"))
        XCTAssertTrue(prompt.contains("<pre_done_verification>"))
        XCTAssertFalse(prompt.contains("CAPTCHAs are automatically solved"))
    }

    /// The one tool: AgentOutput, whose action items each name exactly one of the offered actions.
    func testTheToolOffersEveryActionByName() throws {
        let tool = BrainPrompt.tool
        XCTAssertEqual(tool["function"]?["name"]?.string, "AgentOutput")
        let parameters = try XCTUnwrap(tool["function"]?["parameters"])
        XCTAssertEqual(parameters["required"]?.array?.compactMap(\.string),
                       ["evaluation_previous_goal", "memory", "next_goal", "action"])
        let actions = try XCTUnwrap(parameters["properties"]?["action"]?["items"]?["properties"]?.object)
        XCTAssertEqual(Set(actions.keys), ["navigate", "search", "click", "input", "select_dropdown", "scroll",
                                           "send_keys", "go_back", "wait", "find_text", "search_page",
                                           "find_elements", "extract", "recall", "done"])
        XCTAssertEqual(actions["click"]?["required"]?.array?.compactMap(\.string), ["index"])
        XCTAssertEqual(actions["input"]?["required"]?.array?.compactMap(\.string), ["index", "text"])
    }

    /// A table errand's tool: the same AgentOutput, its done also taking the table's columns and rows; the plain
    /// tool's done takes neither, and every other action is the same in both.
    func testATableErrandsDoneTakesColumnsAndRows() throws {
        let actions = { (tool: CDPValue) in tool["function"]?["parameters"]?["properties"]?["action"]?["items"]?["properties"]?.object ?? [:] }
        let plain = try XCTUnwrap(actions(BrainPrompt.tool)["done"])
        XCTAssertNil(plain["properties"]?["rows"])
        XCTAssertNil(plain["properties"]?["columns"])
        let table = try XCTUnwrap(actions(BrainPrompt.tableTool)["done"])
        XCTAssertEqual(table["required"]?.array?.compactMap(\.string), ["text", "rows"])
        XCTAssertEqual(table["properties"]?["rows"]?["items"]?["items"]?["type"]?.string, "string")
        XCTAssertEqual(table["properties"]?["columns"]?["items"]?["type"]?.string, "string")
        XCTAssertEqual(table["properties"]?["text"], plain["properties"]?["text"])
        XCTAssertEqual(actions(BrainPrompt.tableTool).filter { $0.key != "done" }, actions(BrainPrompt.tool).filter { $0.key != "done" })
        XCTAssertFalse(actions(BrainPrompt.tool).isEmpty)
    }

    /// A step's state: the request, the history, the plan, the tabs, every control on its own line with its text
    /// under it, the section headings, new controls starred, the page's text, and the step count.
    func testAStepStateShowsEverythingTheBrainReads() {
        let before = page([element(1, "link", "About us", text: "About us", href: "https://shop.test/about",
                                  heading: "Menu")])
        let now = page([
            element(1, "link", "About us", text: "About us", href: "https://shop.test/about", heading: "Menu"),
            element(2, "textbox", "Email", inputType: "email", heading: "Contact us", value: ""),
            element(3, "combobox", "Size", heading: "Contact us", options: ["Small", "Large"], value: "Small"),
            element(4, "checkbox", "Subscribe", heading: "Contact us", checked: false),
            element(5, "button", "Send", text: "Send", heading: "Contact us", submits: true),
        ])
        var history = BrainHistory()
        history.add(BrainHistory.Step(evaluation: "Opened the shop. Verdict: Success", memory: "On the shop.",
                                      nextGoal: "Open the contact form.", results: ["Clicked [7] link \"Contact\""]))
        var plan = BrainPlan()
        plan.update(items: ["Open the form", "Fill it"], current: 1)
        let state = BrainPrompt.state(goal: "Ask the shop about sizes", history: history, plan: plan,
                                      tabs: [BrainTab(id: "ab12", url: "https://shop.test/contact", title: "Contact",
                                                      current: true)],
                                      page: now, previous: before, readState: ["recall: my email -> sam@acme.test"],
                                      step: 2, maxSteps: 40, today: "2026-10-19")
        let expected = """
        <user_request>
        Ask the shop about sizes
        </user_request>

        <agent_history>
        <step_1>
        Evaluation of Previous Step: Opened the shop. Verdict: Success
        Memory: On the shop.
        Next Goal: Open the contact form.
        Action Results:
        Action 1/1: Clicked [7] link "Contact"
        </step_1>
        </agent_history>

        <agent_state>
        <plan>
        [x] Open the form
        [>] Fill it
        </plan>
        </agent_state>
        <browser_state>
        Current tab: ab12
        Available tabs:
        Tab ab12: https://shop.test/contact - Contact

        Interactive elements:
        ## Menu
        [1]<link href=/about />
        \tAbout us
        ## Contact us
        *[2]<textbox name=Email type=email value="" />
        *[3]<combobox name=Size value="Small" options="Small|Large" />
        *[4]<checkbox name=Subscribe unchecked />
        *[5]<button submits />
        \tSend
        Page text:
        Welcome to the shop.
        [End of page]
        </browser_state>
        <read_state>
        recall: my email -> sam@acme.test
        </read_state>
        <step_info>Step2 maximum:40
        Today:2026-10-19</step_info>

        """
        XCTAssertEqual(state, expected)
    }

    /// A page the observer could not report whole, or whose text was cut, says so: the brain scrolls or searches.
    func testACutPageSaysItWasCut() {
        var cut = page([element(1, "link", "Home", text: "Home", href: "https://shop.test/")], text: "Top part")
        cut = ObservedPage(url: cut.url, title: cut.title, truncated: true, flags: .none, elements: cut.elements,
                           text: cut.text)
        cut.textCut = true
        let state = BrainPrompt.state(goal: "g", history: BrainHistory(), plan: BrainPlan(), tabs: [], page: cut,
                                      previous: nil, readState: [], step: 1, maxSteps: 40, today: "2026-10-19")
        XCTAssertTrue(state.contains("Interactive elements (more on the page than shown: scroll, or use find_elements):"))
        XCTAssertTrue(state.contains("Top part\n[Text cut: scroll, use search_page or extract for the rest]"))
        XCTAssertFalse(state.contains("[End of page]"))
        XCTAssertTrue(state.contains("<agent_history>\n</agent_history>"))
    }

    /// No plan yet: the state says so in the reference's words.
    func testNoPlanYetSaysSo() {
        let state = BrainPrompt.state(goal: "g", history: BrainHistory(), plan: BrainPlan(), tabs: [],
                                      page: page([]), previous: nil, readState: [], step: 1, maxSteps: 40,
                                      today: "2026-10-19")
        XCTAssertTrue(state.contains("<agent_state>\n<plan>\n[empty plan, fill it with plan_update when applicable]\n</plan>"))
        XCTAssertTrue(state.contains("Interactive elements:\nempty page"))
    }

    /// The plan marks every item before the current one done, and keeps a revised plan's new items pending.
    func testThePlanMarksItemsByTheCurrentOne() {
        var plan = BrainPlan()
        plan.update(items: ["a", "b", "c"], current: 0)
        XCTAssertEqual(plan.description, "[>] a\n[ ] b\n[ ] c")
        plan.move(to: 2)
        XCTAssertEqual(plan.description, "[x] a\n[x] b\n[>] c")
        plan.update(items: ["c", "d"], current: nil)
        XCTAssertEqual(plan.description, "[>] c\n[ ] d")
    }

    /// The check is told what the trajectory is: the agent's words to doubt, the app's action results and page
    /// excerpts as facts, a send with the user's Yes as the app's own doing; a detail in neither is unverified, not
    /// made up.
    func testTheCheckIsToldWhatTheAppRecorded() {
        let instruction = BrainJudge.instruction(today: "2026-10-19")
        XCTAssertTrue(instruction.contains("written by the application that runs the agent, not by the agent"))
        XCTAssertTrue(instruction.contains("\"sent with the user's Yes\" in an action result means the application itself asked the user"))
        XCTAssertTrue(instruction.contains("unverified, not made up"))
        XCTAssertTrue(instruction.contains("<final_page> is the page the agent was on when it finished"))
        XCTAssertFalse(instruction.contains("made up content that is not in the page state"))
        var history = BrainHistory()
        history.add(BrainHistory.Step(evaluation: "e", memory: "m", nextGoal: "n", results: ["Clicked Send"]))
        history.notePage(url: "https://a.test/done", title: "Done", text: "Thanks.\nSecond line " + String(repeating: "x", count: 2_000))
        let shown = history.description(forTheCheck: true)
        XCTAssertTrue(shown.contains("Page after the step, as the app read it: https://a.test/done — Done\nThanks. Second line "))
        XCTAssertLessThan(shown.count, 1_000, "the page's first words only")
        XCTAssertFalse(history.description.contains("Page after the step"), "the brain's own history leaves it out")
        XCTAssertTrue(history.compact(limit: 300).contains("Page after the step, as the app read it: https://a.test/done"))
        XCTAssertLessThanOrEqual(history.compact(limit: 300).count, 300)
    }

    /// A long errand's history comes to at most its limit with every step in it, oldest first: forty steps of long
    /// words, and the first step's No is still read (Codex review 3 of 2026-10-19, P2).
    func testALongHistoryKeepsEveryStepWithinItsLimit() {
        var history = BrainHistory()
        let long = String(repeating: "x", count: 3_000)
        history.add(BrainHistory.Step(evaluation: "The user said no to Send. " + long, memory: long, nextGoal: long,
                                      results: ["The user said no", long, long, long, long]))
        for _ in 1..<40 {
            history.add(BrainHistory.Step(evaluation: long, memory: long, nextGoal: long, results: [long, long, long, long, long]))
        }
        let kept = history.compact(limit: 60_000)
        XCTAssertLessThanOrEqual(kept.count, 60_000)
        XCTAssertTrue(kept.hasPrefix("<step_1>\nEvaluation: The user said no to Send."), String(kept.prefix(120)))
        XCTAssertTrue(kept.contains("Result: The user said no\n"))
        XCTAssertTrue(kept.hasSuffix("</step_40>"), String(kept.suffix(120)))
    }
}
