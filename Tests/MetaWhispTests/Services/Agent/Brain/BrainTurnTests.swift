import XCTest
@testable import MetaWhisp

/// One step's answer as the brain writes it: the AgentOutput tool's arguments (browser-use, MIT).
final class BrainTurnTests: XCTestCase {
    /// Every field and every action comes through, in the order written.
    func testATurnReadsItsFieldsAndItsActionsInOrder() throws {
        let arguments = #"""
        {"thinking": "The form is open.", "evaluation_previous_goal": "Opened the form. Verdict: Success",
         "memory": "On the contact form.", "next_goal": "Fill the name and send.",
         "current_plan_item": 1, "plan_update": ["Open the form", "Fill it", "Send it"],
         "action": [{"input": {"index": 4, "text": "Sam Taylor"}},
                    {"select_dropdown": {"index": 6, "text": "Large"}},
                    {"click": {"index": 9}}]}
        """#
        let turn = try XCTUnwrap(BrainTurn(arguments: arguments))
        XCTAssertEqual(turn.thinking, "The form is open.")
        XCTAssertEqual(turn.evaluation, "Opened the form. Verdict: Success")
        XCTAssertEqual(turn.memory, "On the contact form.")
        XCTAssertEqual(turn.nextGoal, "Fill the name and send.")
        XCTAssertEqual(turn.currentPlanItem, 1)
        XCTAssertEqual(turn.planUpdate, ["Open the form", "Fill it", "Send it"])
        XCTAssertEqual(turn.actions, [.input(index: 4, text: "Sam Taylor", clear: true),
                                      .selectDropdown(index: 6, text: "Large"), .click(index: 9)])
    }

    /// A parameter left out takes the reference's default.
    func testALeftOutParameterTakesItsDefault() throws {
        let arguments = #"""
        {"evaluation_previous_goal": "", "memory": "", "next_goal": "",
         "action": [{"navigate": {"url": "https://example.com"}}, {"scroll": {}}, {"search": {"query": "cats"}},
                    {"wait": {}}, {"done": {"text": "Found it."}}]}
        """#
        let turn = try XCTUnwrap(BrainTurn(arguments: arguments))
        XCTAssertEqual(turn.actions, [.navigate(url: "https://example.com", newTab: false),
                                      .scroll(down: true, pages: 1, index: nil), .search(query: "cats", engine: "duckduckgo"),
                                      .wait(seconds: 3), .done(text: "Found it.", success: true)])
    }

    /// Every action the brain is offered reads back.
    func testEveryOfferedActionReadsBack() throws {
        let arguments = #"""
        {"evaluation_previous_goal": "", "memory": "", "next_goal": "",
         "action": [{"go_back": {}}, {"switch": {"tab_id": "ab12"}}, {"close": {"tab_id": "cd34"}},
                    {"send_keys": {"keys": "Enter"}}, {"find_text": {"text": "Pricing"}},
                    {"search_page": {"pattern": "\\$\\d+", "regex": true}},
                    {"find_elements": {"selector": "table tr", "attributes": ["href"]}},
                    {"extract": {"query": "every price", "start_from_char": 100}},
                    {"recall": {"question": "my email"}},
                    {"input": {"index": 2, "text": "more", "clear": false}},
                    {"scroll": {"down": false, "pages": 0.5, "index": 7}}]}
        """#
        let turn = try XCTUnwrap(BrainTurn(arguments: arguments))
        XCTAssertEqual(turn.actions, [
            .goBack, .switchTab(id: "ab12"), .closeTab(id: "cd34"), .sendKeys("Enter"), .findText("Pricing"),
            .searchPage(pattern: #"\$\d+"#, regex: true, caseSensitive: false, contextChars: 150, maxResults: 25),
            .findElements(selector: "table tr", attributes: ["href"], maxResults: 50, includeText: true),
            .extract(query: "every price", startFromChar: 100), .recall(question: "my email"),
            .input(index: 2, text: "more", clear: false), .scroll(down: false, pages: 0.5, index: 7),
        ])
    }

    /// A search names its engine — DuckDuckGo unless Bing or Brave is asked for — and builds its address from the
    /// query alone.
    func testASearchNamesItsEngine() throws {
        let turn = try XCTUnwrap(BrainTurn(arguments: #"""
        {"memory": "", "action": [{"search": {"query": "a b", "engine": "Bing"}}, {"search": {"query": "c", "engine": "google"}},
                                  {"search": {"query": "d", "engine": "brave"}}]}
        """#))
        XCTAssertEqual(turn.actions, [.search(query: "a b", engine: "bing"), .search(query: "c", engine: "duckduckgo"),
                                      .search(query: "d", engine: "brave")])
        XCTAssertEqual(BrainLoop.searchAddress("a b&c", engine: "bing"), "https://www.bing.com/search?q=a%20b%26c")
        XCTAssertEqual(BrainLoop.searchAddress("x", engine: "brave"), "https://search.brave.com/search?q=x")
        XCTAssertEqual(BrainLoop.searchAddress("x", engine: "duckduckgo"), "https://duckduckgo.com/?q=x")
    }

    /// An index written as a number in quotes is that number: some models quote every value. The indexes 1 and 0
    /// stay numbers — Swift would cast them to true and false.
    func testAnIndexInQuotesIsThatIndex() throws {
        let turn = try XCTUnwrap(BrainTurn(arguments: #"""
        {"memory": "", "action": [{"click": {"index": "12"}}, {"click": {"index": 1}}, {"input": {"index": 0, "text": "a"}},
                                  {"scroll": {"down": 1}}]}
        """#))
        XCTAssertEqual(turn.actions, [.click(index: 12), .click(index: 1), .input(index: 0, text: "a", clear: true),
                                      .scroll(down: true, pages: 1, index: nil)])
    }

    /// An action not offered, an item with two names, or one missing what it needs is kept as not understood —
    /// its result tells the brain so — never dropped and never guessed.
    func testAnActionNotUnderstoodIsKeptAsSuch() throws {
        let arguments = #"""
        {"memory": "", "action": [{"fly": {"to": "moon"}}, {"click": {"index": 1}, "input": {"index": 2, "text": "x"}},
                                  {"click": {}}, {"input": {"index": 3}}]}
        """#
        let turn = try XCTUnwrap(BrainTurn(arguments: arguments))
        XCTAssertEqual(turn.actions, [.notUnderstood("fly"), .notUnderstood("click, input"), .notUnderstood("click"),
                                      .notUnderstood("input")])
    }

    /// An item written flat — the action's name under "action", "type" or "name" with its parameters beside it, or no
    /// name at all — is read by the name it gives, else by the parameters that name one action alone: an index with a
    /// text is an input, an index alone a click (GLM-5.3 and Kimi K3 wrote every one of these on 2026-10-19, and lost
    /// steps to "not an action I can run"). A name given that names no action is not understood — never guessed from
    /// the parameters beside it — and so are parameters that fit no action.
    func testAnItemWrittenFlatIsReadByItsNameOrItsShape() throws {
        let arguments = #"""
        {"memory": "", "action": [{"index": 3, "text": "x", "type": "input"}, {"index": 4, "type": "click"},
                                  {"action": "input", "clear": false, "index": 5, "text": "y"}, {"action": "click", "index": 6},
                                  {"name": "scroll", "down": false}, {"index": 7, "text": "z"}, {"index": 8},
                                  {"type": "text", "index": 9, "text": "w"}, {"type": "fly", "index": 10}, {"text": "alone"},
                                  {"query": "stray", "search": {"engine": "bing", "query": "first flight"}},
                                  {"engine": "duckduckgo", "query": "q", "action": "search"}]}
        """#
        let turn = try XCTUnwrap(BrainTurn(arguments: arguments))
        XCTAssertEqual(turn.actions, [.input(index: 3, text: "x", clear: true), .click(index: 4),
                                      .input(index: 5, text: "y", clear: false), .click(index: 6),
                                      .scroll(down: false, pages: 1, index: nil), .input(index: 7, text: "z", clear: true),
                                      .click(index: 8), .notUnderstood("index, text, type"),
                                      .notUnderstood("index, type"), .notUnderstood("text"),
                                      .search(query: "first flight", engine: "bing"), .search(query: "q", engine: "duckduckgo")])
    }

    /// A table errand's done gives its table: columns and rows, every cell as text — a number as written — and no
    /// table when it gives no row; a done without one is read as before.
    func testADoneReadsItsTableEveryCellAsText() throws {
        let head = #""evaluation_previous_goal": "e", "memory": "m", "next_goal": "n""#
        let table = try XCTUnwrap(BrainTurn(arguments: "{\(head), \"action\": " + #"[{"done": {"text": "Two shops.", "success": true, "columns": ["Shop", "Rating", "Link"], "rows": [["Alpha", 4.5, "https://a.test"], ["Beta", 3, null], []]}}]}"#))
        XCTAssertEqual(table.actions, [.done(text: "Two shops.", success: true,
                                             table: BrainTable(columns: ["Shop", "Rating", "Link"],
                                                               rows: [["Alpha", "4.5", "https://a.test"], ["Beta", "3", ""]]))])
        let plain = try XCTUnwrap(BrainTurn(arguments: "{\(head), \"action\": " + #"[{"done": {"text": "Found it."}}]}"#))
        XCTAssertEqual(plain.actions, [.done(text: "Found it.", success: true)])
        let none = try XCTUnwrap(BrainTurn(arguments: "{\(head), \"action\": " + #"[{"done": {"text": "None.", "success": false, "columns": ["Shop"], "rows": "none"}}]}"#))
        XCTAssertEqual(none.actions, [.done(text: "None.", success: false)])
    }

    /// Arguments that are not a JSON object with an action list are no turn.
    func testArgumentsWithoutAnActionListAreNoTurn() {
        XCTAssertNil(BrainTurn(arguments: "not json"))
        XCTAssertNil(BrainTurn(arguments: #"["click"]"#))
        XCTAssertNil(BrainTurn(arguments: #"{"memory": "x"}"#))
        XCTAssertNil(BrainTurn(arguments: #"{"memory": "x", "action": []}"#))
    }

    /// The action list may come as JSON text inside the arguments: some models write it so.
    func testAnActionListWrittenAsTextIsRead() throws {
        let turn = try XCTUnwrap(BrainTurn(arguments: #"{"memory": "", "action": "[{\"click\": {\"index\": 5}}]"}"#))
        XCTAssertEqual(turn.actions, [.click(index: 5)])
    }

    /// A page-changing action ends the step's list: what comes after it is skipped, as the reference does.
    func testPageChangingActionsAreKnown() {
        XCTAssertTrue(BrainAction.navigate(url: "https://a.test", newTab: false).changesPage)
        XCTAssertTrue(BrainAction.search(query: "x", engine: "duckduckgo").changesPage)
        XCTAssertTrue(BrainAction.goBack.changesPage)
        XCTAssertTrue(BrainAction.switchTab(id: "ab12").changesPage)
        XCTAssertFalse(BrainAction.input(index: 1, text: "x", clear: true).changesPage)
        XCTAssertFalse(BrainAction.click(index: 1).changesPage)
    }
}
