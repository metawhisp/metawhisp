import CryptoKit
import XCTest
@testable import MetaWhisp

/// ITER-076 brain, step 1 — the agent's text model: the texts the owner
/// approved on 2026-09-30, each call carrying its own byte for byte and no
/// other text; the plan's strict schema and its checks; the sub-goal tool and
/// its results; a field's text.
final class ErrandModelTests: XCTestCase {

    private func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The approved texts

    /// Each text is the approved one: the pins are the SHA-256 of each text as
    /// the approval file `brain-texts-approved.txt` (sha256 077e83ea…) holds
    /// it — texts 1 to 4 and text 3's one parameter — which equal their sources
    /// byte for byte. A changed text fails here: it needs the owner first.
    func testEveryModelTextIsTheApprovedOne() {
        let approved = "changed without the owner's approval"
        XCTAssertEqual(sha(ModelTexts.untrusted), "160edba547c9ed205779be8ec853380bb09e4e4eb68eb094e22efcffd33e2475", approved)
        XCTAssertEqual(sha(ModelTexts.planner), "682727490128d37f98130aecd0069f246bea69b984b897fcf7a5ceb722c8e68e", approved)
        XCTAssertEqual(sha(ModelTexts.browserDo), "135c6fc81c4e8352e2cc6b3f49efd7fc5e2792a04a782dae2a54457f031cf050", approved)
        XCTAssertEqual(sha(ModelTexts.browserDoGoal), "97ebcf074119b5af1c49c7c374ff5fb972596d2c7f4b461636e003af3dae4eb3", approved)
        XCTAssertEqual(sha(ModelTexts.fieldText), "c717122103c0755b97ca9df2aa9c49ea2e90ad95f8796045adb8d6445a8e5b80", approved)
    }

    /// ITER-076 stage 7 — text 16, the field writer with the user's details,
    /// is the one the owner approved on 2026-10-06 (approval page v3, item
    /// 16): one line, byte for byte as the page shows it. A changed text
    /// fails here: it needs the owner first.
    func testTheFormFieldWriterIsTheTextTheOwnerApproved() {
        XCTAssertEqual(sha(ModelTexts.formFieldText), "05a536786a45a07a1a06d8512b0fe9b3fbd96fe0dda5a021dca7d98e9a942c0f",
                       "changed without the owner's approval")
        XCTAssertFalse(ModelTexts.formFieldText.contains("\n"), "one line, as approved")
        XCTAssertTrue(ModelTexts.formFieldText.hasPrefix("Return a JSON object with exactly one key, text:"))
        XCTAssertTrue(ModelTexts.formFieldText.hasSuffix(#"Otherwise return {"text": "the field value"}."#))
    }

    // MARK: - The plan

    /// The goal as the user gave it, spaces, an invisible mark and a long
    /// number included: nothing in it is changed or hidden (owner decision of
    /// 2026-10-03).
    private static let goal = "Find  10 jokes\u{200B} and card 4111 1111 1111 1111"

    /// The planner's own schema without `count_records`: field names, kinds
    /// and the two requirement kinds — no title, no description.
    private static let planSchema: CDPValue = .object([
        "type": .string("object"),
        "properties": .object([
            "requirements": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "minLength": .number(1)]),
                        "text": .object(["type": .string("string"), "minLength": .number(1)]),
                        "kind": .object(["type": .string("string"),
                                         "enum": .array([.string("action"), .string("information")])]),
                    ]),
                    "required": .array([.string("id"), .string("text"), .string("kind")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "answer_expected": .object(["type": .string("boolean")]),
        ]),
        "required": .array([.string("requirements"), .string("answer_expected")]),
        "additionalProperties": .bool(false),
    ])

    /// One call (G1): the purpose `plan`, text 2 as the system message, the
    /// user's words after `# Task` as the user message, and the strict schema
    /// — no tools, no other message.
    func testThePlanIsAskedOnceWithTheApprovedTextTheTaskAndTheStrictSchema() async throws {
        let model = RecordedModel { _, _ in .text(RecordedModel.plan([("r1", "Find 10 jokes", "information")])) }
        _ = try await model.planner.plan(goal: Self.goal)

        XCTAssertEqual(model.requests.count, 1, "one call, no repair")
        let asked = try XCTUnwrap(model.requests.first)
        XCTAssertEqual(asked.purpose, "plan")
        XCTAssertEqual(asked.messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(asked.contents, [ModelTexts.planner, "# Task\n" + Self.goal], "the goal as the user wrote it")
        XCTAssertNil(asked.body["tools"])
        let format = try XCTUnwrap(asked.body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["name"] as? String, "Plan")
        XCTAssertEqual(schema["strict"] as? Bool, true)
        XCTAssertEqual(Set(schema.keys), ["name", "strict", "schema"])
        XCTAssertEqual(TextPlanner.request(goal: Self.goal).responseFormat?["json_schema"]?["schema"], Self.planSchema)
    }

    /// An answer is the plan: its requirements in order, whether the user
    /// expects an answer, and what it cost; it asks for no rows.
    func testAPlanAnswerBecomesTheRequirementsAndWhetherAnAnswerIsExpected() async throws {
        let model = RecordedModel { _, _ in
            .text(RecordedModel.plan([("r1", "Find 10 jokes", "information"), ("r2", "Open the first joke", "action")],
                                     answer: false))
        }
        let plan = try await model.planner.plan(goal: Self.goal)
        XCTAssertEqual(plan.goal, Self.goal)
        XCTAssertEqual(plan.requirements, [.init(id: "r1", text: "Find 10 jokes", kind: .information),
                                           .init(id: "r2", text: "Open the first joke", kind: .action)])
        XCTAssertFalse(plan.answerExpected)
        XCTAssertFalse(plan.asksForRows)
        XCTAssertEqual(plan.usage, EngineUsage(costUSD: 0.0002))
    }

    /// An answer that fails the schema, names no requirement or repeats an id
    /// is no plan — `invalidAnswer`, which the errand ends as planFailed — and
    /// the model is not asked again (no repair call).
    func testAPlanAnswerThatFailsTheSchemaOrTheChecksIsNoPlanAndIsNotAskedAgain() async throws {
        let bad: [(String, String)] = [
            ("repeated id", RecordedModel.plan([("r1", "Find jokes", "information"), ("r1", "Open one", "action")])),
            ("no requirement", RecordedModel.plan([])),
            ("not JSON", "Here is the plan: r1"),
            ("a key the schema does not have", #"{"requirements":[{"id":"r1","text":"Find jokes","kind":"information"}],"answer_expected":true,"count_records":false}"#),
            ("a requirement key it does not have", #"{"requirements":[{"id":"r1","text":"Find jokes","kind":"information","why":"x"}],"answer_expected":true}"#),
            ("a kind it does not have", RecordedModel.plan([("r1", "Find jokes", "fact")])),
            ("an empty id", RecordedModel.plan([("", "Find jokes", "information")])),
            ("an empty text", RecordedModel.plan([("r1", "", "information")])),
            ("answer_expected not a boolean", #"{"requirements":[{"id":"r1","text":"Find jokes","kind":"information"}],"answer_expected":1}"#),
            ("answer_expected missing", #"{"requirements":[{"id":"r1","text":"Find jokes","kind":"information"}]}"#),
            ("requirements not a list", #"{"requirements":{"id":"r1"},"answer_expected":true}"#),
        ]
        for (what, text) in bad {
            let model = RecordedModel { _, _ in .text(text) }
            do {
                _ = try await model.planner.plan(goal: Self.goal)
                XCTFail("\(what): a plan")
            } catch {
                XCTAssertEqual(error as? JevDecisionEngine.Failure, .invalidAnswer, what)
            }
            XCTAssertEqual(model.requests.count, 1, "\(what): asked once")
        }
    }

    /// What the server says instead of an answer is the failure every service
    /// of the agent is read by (I-05), so the errand ends honestly.
    func testWhatTheServerSaysInsteadOfAPlanIsItsFailure() async throws {
        let cases: [(Int, JevDecisionEngine.Failure)] = [
            (401, .noPro), (429, .dailyLimit(retryAfter: .seconds(60))), (503, .unavailable(retryAfter: .seconds(60))),
            (504, .timedOut), (400, .invalid),
        ]
        for (status, failure) in cases {
            let model = RecordedModel { _, _ in .status(status, retryAfter: "60") }
            do {
                _ = try await model.planner.plan(goal: Self.goal)
                XCTFail("\(status): a plan")
            } catch {
                XCTAssertEqual(error as? JevDecisionEngine.Failure, failure, "\(status)")
            }
        }
    }

    // MARK: - The sub-goal tool

    /// The tool as the route takes it: `browser_do`, text 3 as its
    /// description, and its one parameter `goal` described by text 3's own
    /// line — nothing else.
    private static let tool: CDPValue = .object([
        "type": .string("function"),
        "function": .object([
            "name": .string("browser_do"),
            "description": .string(ModelTexts.browserDo),
            "parameters": .object([
                "type": .string("object"),
                "properties": .object(["goal": .object(["type": .string("string"),
                                                        "description": .string(ModelTexts.browserDoGoal)])]),
                "required": .array([.string("goal")]),
                "additionalProperties": .bool(false),
            ]),
        ]),
    ])

    /// G3: the conversation is text 1, then the user's goal; then, for each
    /// sub-goal, the model's reply with its calls and one code-made result per
    /// call, under the call's id. The tool is offered every time, and the
    /// model may answer without it, the first call too: a provider failed the
    /// first call that required it (ITER-076 stage 4c, F4).
    func testTheSubgoalCallIsTheTrustLineTheGoalAndTheBrowserDoTool() throws {
        let first = ErrandModel.subgoalRequest(goal: Self.goal, turns: [])
        XCTAssertEqual(first.purpose, .subgoal)
        XCTAssertEqual(first.messages, [.object(["role": .string("system"), "content": .string(ModelTexts.untrusted)]),
                                        .object(["role": .string("user"), "content": .string(Self.goal)])])
        XCTAssertEqual(first.tools, [Self.tool])
        XCTAssertEqual(first.toolChoice, .string("auto"))
        let sent = try XCTUnwrap(try CDPValue.decode(String(decoding: try ProLLMClient.body(first, deadlineMs: 1_000),
                                                            as: UTF8.self)).object)
        XCTAssertEqual(sent["tool_choice"], .string("auto"), "on the wire as the server takes it")
        XCTAssertNil(first.responseFormat)
        XCTAssertNil(first.maxTokens)

        let reply = ProLLMClient.Answer(text: "", toolCalls: [.init(id: "call_1", name: "browser_do", arguments: #"{"goal":"Search the web for jokes"}"#),
                                                              .init(id: "call_2", name: "browser_do", arguments: #"{"goal":"Open a page"}"#)],
                                        finishReason: "tool_calls", inputTokens: 1, outputTokens: 1, costUSD: nil)
        let second = ErrandModel.subgoalRequest(goal: Self.goal, turns: [.init(reply: reply, results: ["R1", "R2"])])
        XCTAssertEqual(second.toolChoice, .string("auto"), "a sub-goal ran: the model may stop")
        XCTAssertEqual(Array(second.messages.dropFirst(2)), [
            .object(["role": .string("assistant"), "content": .null, "tool_calls": .array([
                .object(["id": .string("call_1"), "type": .string("function"),
                         "function": .object(["name": .string("browser_do"), "arguments": .string(#"{"goal":"Search the web for jokes"}"#)])]),
                .object(["id": .string("call_2"), "type": .string("function"),
                         "function": .object(["name": .string("browser_do"), "arguments": .string(#"{"goal":"Open a page"}"#)])]),
            ])]),
            .object(["role": .string("tool"), "tool_call_id": .string("call_1"), "content": .string("R1")]),
            .object(["role": .string("tool"), "tool_call_id": .string("call_2"), "content": .string("R2")]),
        ])
        // A reply's own words go back with its calls.
        let said = ProLLMClient.Answer(text: "Searching.", toolCalls: reply.toolCalls, finishReason: "tool_calls",
                                       inputTokens: 1, outputTokens: 1, costUSD: nil)
        let third = ErrandModel.subgoalRequest(goal: Self.goal, turns: [.init(reply: said, results: ["R1", "R2"])])
        XCTAssertEqual(third.messages.dropFirst(2).first?["content"], .string("Searching."))
    }

    /// A call's goal is its one parameter, a text with something in it; a
    /// call without one is not run.
    func testACallsGoalIsItsOneParameter() {
        func call(_ arguments: String, name: String = "browser_do") -> ProLLMClient.ToolCall {
            .init(id: "call_1", name: name, arguments: arguments)
        }
        XCTAssertEqual(ErrandModel.goal(of: call(#"{"goal":"Open the Pull requests tab"}"#)), "Open the Pull requests tab")
        XCTAssertNil(ErrandModel.goal(of: call(#"{"goal":"   "}"#)))
        XCTAssertNil(ErrandModel.goal(of: call(#"{"goal":7}"#)))
        XCTAssertNil(ErrandModel.goal(of: call(#"{}"#)))
        XCTAssertNil(ErrandModel.goal(of: call("not json")))
        XCTAssertNil(ErrandModel.goal(of: call(#"{"goal":"Open it"}"#, name: "browser_check")))
    }

    /// ITER-076 stage 4c (F4): the run's own call of the tool, when the
    /// model's first reply named no sub-goal, is the tool by its name with the
    /// user's own goal as its one parameter, under the id the run gives it —
    /// no other words. Its goal reads back as any call's does.
    func testTheRunsOwnCallIsTheToolWithTheUsersGoalAsItsOneParameter() {
        let goal = #"Find "jokes" \ here"#
        let call = ErrandModel.call(goal: goal, id: "call_own")
        XCTAssertEqual(call, ProLLMClient.ToolCall(id: "call_own", name: "browser_do",
                                                   arguments: #"{"goal": "Find \"jokes\" \\ here"}"#))
        XCTAssertEqual(ErrandModel.goal(of: call), goal)
    }

    private func page(text: String = "Short page text") -> ObservedPage {
        ObservedPage(url: "https://www.google.com/search?q=jokes", title: "jokes - Search", truncated: false,
                     flags: .none, elements: [], text: text)
    }

    /// A call's result as the approval page lays it out: status, address,
    /// title, the actions, the page's first 600 characters — when done, only
    /// while something is still to find — and what is still to find. Done and
    /// shown no page, the model could not see what the page offered next: it
    /// answered a list a click would load from its own memory (2026-10-16).
    func testAToolResultIsLaidOutAsTheApprovalPageShowsIt() {
        XCTAssertEqual(ErrandModel.result(.done, page: page(), actions: ["click Search", "type into Search"],
                                          stillToFind: ["Find 10 jokes"]),
                       #"{"status": "done", "url": "https://www.google.com/search?q=jokes", "title": "jokes - Search", "actions": ["click Search", "type into Search"], "page_text": "Short page text", "still_to_find": ["Find 10 jokes"]}"#)
        XCTAssertEqual(ErrandModel.result(.done, page: page(), actions: ["click Search"], stillToFind: []),
                       #"{"status": "done", "url": "https://www.google.com/search?q=jokes", "title": "jokes - Search", "actions": ["click Search"], "still_to_find": []}"#,
                       "nothing still to find: no page to plan by")
        let long = String(repeating: "a", count: 590) + "\"quoted\"\nline"
        XCTAssertEqual(ErrandModel.result(.stuck, page: page(text: long), actions: [], stillToFind: []),
                       #"{"status": "stuck", "url": "https://www.google.com/search?q=jokes", "title": "jokes - Search", "actions": [], "page_text": ""#
                       + String(repeating: "a", count: 590) + #"\"quoted\"\nl", "still_to_find": []}"#,
                       "600 characters, escaped as JSON")
        for status in [ErrandModel.Status.blocked, .maxActions] {
            XCTAssertTrue(ErrandModel.result(status, page: page(), actions: [], stillToFind: [])
                .contains(#""page_text": "Short page text""#), status.rawValue)
        }
        XCTAssertEqual(ErrandModel.Status.maxActions.rawValue, "max_actions")
    }

    // MARK: - A field's text

    /// A field's text is asked as strict output (ITER-076 stage 10a, item 5):
    /// text 4's one key, a text or null, under the name a reference browser
    /// agent gives its field-text answer — no description, so no new words. A
    /// provider asked without it wrapped the JSON in a code fence (Gemini
    /// 3.5 Flash Lite, 2 answers of 4 on the bench of 2026-10-07), and nothing
    /// was typed.
    private static let fieldTextFormat: CDPValue = .object([
        "type": .string("json_schema"),
        "json_schema": .object([
            "name": .string("_FieldText"),
            "strict": .bool(true),
            "schema": .object([
                "type": .string("object"),
                "properties": .object(["text": .object(["anyOf": .array([.object(["type": .string("string")]),
                                                                          .object(["type": .string("null")])])])]),
                "required": .array([.string("text")]),
                "additionalProperties": .bool(false),
            ]),
        ]),
    ])

    /// Text 4 as the system message; as the user message, the input laid out
    /// as the approval page shows it: the goal, the field's label, role and
    /// value, the page's title and text, and the last six actions with what
    /// each typed — for the strict output of text 4's answer.
    func testAFieldsTextIsAskedWithTheApprovedTextAndItsInputLayout() {
        let field = ObservedElement(index: 3, role: "combobox", name: "Search", text: "", href: nil, inputType: "text",
                                    heading: nil, region: .main, inViewport: true, context: nil, formAction: nil,
                                    formMethod: nil, formSubmitLabel: nil, options: nil, checked: nil, value: "jo")
        let recent = (1...7).map { RecentAction(label: "Control \($0)", kind: "click", typed: nil, pageChanged: true) }
            + [RecentAction(label: "Search", kind: "fill", typed: "cats \"and\" dogs", pageChanged: false)]
        let request = ErrandModel.fieldTextRequest(goal: "Find 10 jokes", field: field, page: page(), recent: recent)
        XCTAssertEqual(request.purpose, .fieldText)
        XCTAssertEqual(request.maxTokens, 1_024)
        XCTAssertEqual(request.responseFormat, Self.fieldTextFormat)
        XCTAssertNil(request.tools)
        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.messages.first, .object(["role": .string("system"), "content": .string(ModelTexts.fieldText)]))
        XCTAssertEqual(request.messages.dropFirst().first, .object(["role": .string("user"), "content": .string(
            #"{"goal": "Find 10 jokes", "field": {"label": "Search", "role": "combobox", "value": "jo"}, "page": {"title": "jokes - Search", "text": "Short page text"}, "recent_actions": [{"action": "Control 3", "text": null}, {"action": "Control 4", "text": null}, {"action": "Control 5", "text": null}, {"action": "Control 6", "text": null}, {"action": "Control 7", "text": null}, {"action": "Search", "text": "cats \"and\" dogs"}]}"#)]))
    }

    /// ITER-076 stage 7, decision 7.6 — a form's field is written by text 16:
    /// text 4's input with one more key, the user's details, after the goal;
    /// the field carries its input type, which text 16 names. The same
    /// purpose, cap, strict output and answer as text 4's call.
    func testAFormFieldIsAskedWithTextSixteenAndTextFoursInputPlusTheDetails() {
        let field = ObservedElement(index: 2, role: "textbox", name: "Company", text: "", href: nil, inputType: "text",
                                    heading: nil, region: .main, inViewport: true, context: nil, formAction: nil,
                                    formMethod: nil, formSubmitLabel: nil, options: nil, checked: nil, value: "")
        let recent = [RecentAction(label: "Request a demo", kind: "click", typed: nil, pageChanged: true)]
        let request = ErrandModel.formFieldTextRequest(goal: "Request a demo on site four forty",
                                                       details: ["My name is Sam Example", "I work at AcmeCorp",
                                                                 "sam@example.test"],
                                                       field: field, page: page(), recent: recent)
        XCTAssertEqual(request.purpose, .fieldText)
        XCTAssertEqual(request.maxTokens, 1_024)
        XCTAssertEqual(request.responseFormat, Self.fieldTextFormat)
        XCTAssertNil(request.tools)
        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.messages.first,
                       .object(["role": .string("system"), "content": .string(ModelTexts.formFieldText)]))
        XCTAssertEqual(request.messages.dropFirst().first, .object(["role": .string("user"), "content": .string(
            #"{"goal": "Request a demo on site four forty", "details": ["My name is Sam Example", "I work at AcmeCorp", "sam@example.test"], "field": {"label": "Company", "role": "textbox", "input_type": "text", "value": ""}, "page": {"title": "jokes - Search", "text": "Short page text"}, "recent_actions": [{"action": "Request a demo", "text": null}]}"#)]))
        // A field that is no input — a text area — has no input type.
        let area = ObservedElement(index: 3, role: "textbox", name: "Message", text: "", href: nil, inputType: nil,
                                   heading: nil, region: .main, inViewport: true, context: nil, formAction: nil,
                                   formMethod: nil, formSubmitLabel: nil, options: nil, checked: nil, value: "")
        let written = ErrandModel.formFieldTextRequest(goal: "g", details: [], field: area, page: page(), recent: [])
        XCTAssertEqual(written.messages.dropFirst().first, .object(["role": .string("user"), "content": .string(
            #"{"goal": "g", "details": [], "field": {"label": "Message", "role": "textbox", "input_type": null, "value": ""}, "page": {"title": "jokes - Search", "text": "Short page text"}, "recent_actions": []}"#)]))
    }

    /// The answer is exactly `{"text": …}`: a text of 1 to 2,000 characters is
    /// typed; `{"text": null}` types nothing; anything else is no answer, and
    /// types nothing either.
    func testAFieldTextAnswerIsTheTextOrNothing() {
        XCTAssertEqual(ErrandModel.text(of: #"{"text": "funny jokes"}"#).text, "funny jokes")
        XCTAssertTrue(ErrandModel.text(of: #"{"text": "funny jokes"}"#).valid)
        let none = ErrandModel.text(of: #"{"text": null}"#)
        XCTAssertNil(none.text)
        XCTAssertTrue(none.valid)
        for bad in [#"{"text": ""}"#, #"{"text": 5}"#, #"{"text": "a", "why": "b"}"#, #"{}"#, "funny jokes",
                    "```json\n{\"text\": \"a\"}\n```", #"{"text": ""# + String(repeating: "a", count: 2_001) + #""}"#] {
            let read = ErrandModel.text(of: bad)
            XCTAssertNil(read.text, bad)
            XCTAssertFalse(read.valid, bad)
        }
        XCTAssertNotNil(ErrandModel.text(of: #"{"text": ""# + String(repeating: "a", count: 2_000) + #""}"#).text)
    }

    // MARK: - Reading the page (step 2)

    /// Text 5 and its schema's five descriptions are the approved ones: the
    /// SHA-256 of each as the approval file holds it, which equal their
    /// sources byte for byte. A changed one fails here: it needs the owner.
    func testTheReaderTextAndItsSchemasWordsAreTheApprovedOnes() {
        let approved = "changed without the owner's approval"
        // 2026-10-15: with the reference's Lists over several pages section (the owner: the result counts, not the
        // texts) — the pins still catch a change made without meaning to.
        XCTAssertEqual(sha(ModelTexts.reader), "27d0301fcacedef6778b8c959b87337deaa3520b8f6fc32685747277a32bdd55", approved)
        XCTAssertEqual(sha(ModelTexts.readerContinuesRequirement), "5af50cd48f37cea08fbeccd904e8d962de166c1e30ba20255dad34e51941a4d3", approved)
        XCTAssertEqual(sha(ModelTexts.readerContinuesExpands), "0ca4b145ac677512cb426933c09c083906897ff0366bcfa5b4790165afa9e3aa", approved)
        XCTAssertEqual(sha(ModelTexts.readerContinuesRecords), "707cea10d76831a2f5704ed5f1400709216e7ae24b17b6ff5f0745f41378d852", approved)
        XCTAssertEqual(sha(ModelTexts.readerFirst), "87713e2c8a4b8c2d98bd16d22d0af1ec1877c33cdf4e92baf69621f0da542491", approved)
        XCTAssertEqual(sha(ModelTexts.readerLast), "c7df3f254166c0c47f6296a7ebfc84b6e64c7bf72acbd89eda7039c3a5d42c6b", approved)
        XCTAssertEqual(sha(ModelTexts.readerCite), "022076386b3809b3e1ca043f433963380670f6a4646b3829e9be9f70d6e443be", approved)
        XCTAssertEqual(sha(ModelTexts.readerDrawsOn), "c223dc9e0e1aba6c640e5d8d0eb7309bdb58d2dbd13b8e6d00b60a3c282f330b", approved)
        XCTAssertEqual(sha(ModelTexts.readerRecords), "e8f484b48672ead05916c2f4c08b322965bcf66a2840a17d3ae8fe7e6253f5e9", approved)
    }

    /// A run of source blocks, as the schema names one.
    private static let cite: CDPValue = .object([
        "type": .string("object"),
        "properties": .object([
            "first": .object(["type": .string("string"), "description": .string(ModelTexts.readerFirst)]),
            "last": .object(["type": .string("string"), "description": .string(ModelTexts.readerLast)]),
        ]),
        "required": .array([.string("first"), .string("last")]),
        "additionalProperties": .bool(false),
    ])

    /// The reader's own schema without `orders_list`, `tallies` and
    /// `continues`: its fields, their kinds and the approved descriptions — no
    /// title, no other word.
    private static let readSchema: CDPValue = .object([
        "type": .string("object"),
        "properties": .object([
            "claims": .object(["type": .string("array"), "items": .object([
                "type": .string("object"),
                "properties": .object([
                    "cite": .object(["anyOf": .array([cite, .object(["type": .string("null")])]),
                                     "description": .string(ModelTexts.readerCite)]),
                    "draws_on": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                         "description": .string(ModelTexts.readerDrawsOn)]),
                    "records": .object(["type": .string("array"), "items": cite,
                                        "description": .string(ModelTexts.readerRecords)]),
                    "text": .object(["type": .string("string")]),
                    "requirement_id": .object(["anyOf": .array([.object(["type": .string("string")]),
                                                                 .object(["type": .string("null")])])]),
                ]),
                "required": .array(["cite", "draws_on", "records", "text", "requirement_id"].map(CDPValue.string)),
                "additionalProperties": .bool(false),
            ])]),
            "answered": .object(["type": .string("boolean")]),
            // 2026-10-15: the lists the reader saw go on past its capture.
            "continues": .object(["type": .string("array"), "items": .object([
                "type": .string("object"),
                "properties": .object([
                    "requirement_id": .object(["type": .string("string"),
                                               "description": .string(ModelTexts.readerContinuesRequirement)]),
                    "expands": .object(["anyOf": .array([.object(["type": .string("string")]),
                                                         .object(["type": .string("null")])]),
                                        "description": .string(ModelTexts.readerContinuesExpands)]),
                    "records": .object(["type": .string("array"), "items": cite,
                                        "description": .string(ModelTexts.readerContinuesRecords)]),
                ]),
                "required": .array(["requirement_id", "expands", "records"].map(CDPValue.string)),
                "additionalProperties": .bool(false),
            ])]),
        ]),
        "required": .array([.string("claims"), .string("answered"), .string("continues")]),
        "additionalProperties": .bool(false),
    ])

    private static let wanted: [AgentPlan.Requirement] = [.init(id: "r1", text: "Find 10 jokes", kind: .information),
                                                          .init(id: "r3", text: "Find the author", kind: .information)]

    /// One read (G7): text 5 as the system message; as the user message, the
    /// layout the approval page shows — the facts collected so far, the page's
    /// shown address and the frames it cannot read, this chunk's blocks each
    /// as `[label] (kind) words`, the user's goal with the requirements still
    /// to evidence, and their ids — for the strict schema, with room for the
    /// reader's answer.
    func testAReadIsTheApprovedTextAndThePageLaidOutAsTheApprovalPageShowsIt() throws {
        let capture = ErrandModel.Capture(url: "https://site-404.test/", frames: 2, blocks: [])
        let chunk: [ErrandModel.Block] = [.init(label: "main/:1", kind: "heading", text: "Ten jokes"),
                                          .init(label: "main/:2", kind: "list_item", text: #"Joke "one""#),
                                          .init(label: "main/:3", kind: "paragraph", text: "More")]
        // A quote no requirement rests on is `requirements=-`, as a reference
        // browser agent renders a fact without one (`memory.py` 316, MIT);
        // two requirements are listed in order, by commas.
        let evidence: [ErrandRecord.Fact] = [
            .init(requirements: ["r1"], quote: "Joke \"zero\"\nline", source: "main/:12", url: "https://site-404.test/a"),
            .init(requirements: ["r1", "r3"], quote: "Who is there?", source: "main/:5", url: "https://site-404.test/b"),
            .init(requirements: [], quote: "Knock knock.", source: "main/:4", url: "https://site-404.test/b"),
        ]
        let request = ErrandModel.readRequest(goal: Self.goal, wanted: Self.wanted, evidence: evidence, capture: capture,
                                              chunk: chunk, index: 1, total: 3)
        XCTAssertEqual(request.purpose, .read)
        XCTAssertEqual(request.maxTokens, 8_000)
        XCTAssertNil(request.tools)
        XCTAssertNil(request.toolChoice)
        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.messages.first, .object(["role": .string("system"), "content": .string(ModelTexts.reader)]))
        let expected = [
            "# Collected evidence",
            #"[1] "Joke \"zero\"\nline" requirements=r1 source="main/:12" url="https://site-404.test/a" quote="Joke \"zero\"\nline""#,
            #"[2] "Who is there?" requirements=r1,r3 source="main/:5" url="https://site-404.test/b" quote="Who is there?""#,
            #"[3] "Knock knock." requirements=- source="main/:4" url="https://site-404.test/b" quote="Knock knock.""#,
            "",
            "# Capture",
            "URL: https://site-404.test/",
            "Inaccessible frames: 2",
            "",
            "# Source blocks (chunk 2 of 3)",
            "[main/:1] (heading) Ten jokes",
            #"[main/:2] (list_item) Joke "one""#,
            "[main/:3] (paragraph) More",
            "",
            "# Question",
            Self.goal,
            "",
            "Requirements still to evidence:",
            "- Find 10 jokes",
            "- Find the author",
            "",
            "# Requirement ids",
            "r1, r3",
        ].joined(separator: "\n")
        XCTAssertEqual(request.messages.dropFirst().first, .object(["role": .string("user"), "content": .string(expected)]))
        let format = try XCTUnwrap(request.responseFormat)
        XCTAssertEqual(format["type"], .string("json_schema"))
        XCTAssertEqual(format["json_schema"]?["name"], .string("_ReadResponse"))
        XCTAssertEqual(format["json_schema"]?["strict"], .bool(true))
        XCTAssertEqual(format["json_schema"]?.object.map { Set($0.keys) }, ["name", "strict", "schema"])
        XCTAssertEqual(format["json_schema"]?["schema"], Self.readSchema)

        // Nothing collected yet: the section is there, empty.
        let first = ErrandModel.readRequest(goal: "g", wanted: [Self.wanted[0]], evidence: [], capture: capture,
                                            chunk: chunk, index: 0, total: 1)
        let content = try XCTUnwrap(first.messages.last?["content"]?.string)
        XCTAssertTrue(content.hasPrefix("# Collected evidence\n\n\n# Capture\nURL: https://site-404.test/\n"), content)
        XCTAssertTrue(content.contains("\n# Source blocks (chunk 1 of 1)\n"), content)
        XCTAssertTrue(content.hasSuffix("\n# Question\ng\n\nRequirements still to evidence:\n- Find 10 jokes\n\n# Requirement ids\nr1"),
                      content)
    }

    /// The blocks a reader is shown in one call.
    private static let shown: [ErrandModel.Block] = [
        .init(label: "main/:4", kind: "heading", text: "Ten jokes"),
        .init(label: "main/:5", kind: "list_item", text: "Joke 1: its days were numbered."),
        .init(label: "main/:6", kind: "list_item", text: "Joke 2: it was two tired."),
        .init(label: "main/:7", kind: "paragraph", text: "By Sam"),
    ]
    private static let page = "https://site-404.test/"

    private static func claim(_ cite: (String, String)?, drawsOn: [String] = [], records: [(String, String)] = [],
                              requirement: String? = "r1", text: String = "") -> ErrandModel.Claim {
        ErrandModel.Claim(cite: cite.map { ErrandModel.Cite(first: $0.0, last: $0.1) }, drawsOn: drawsOn,
                          records: records.map { ErrandModel.Cite(first: $0.0, last: $0.1) }, requirement: requirement,
                          text: text)
    }

    private static func evidence(_ claims: [ErrandModel.Claim], kept: [ErrandRecord.Fact] = [],
                                 asked: Set<String> = ["r1", "r3"]) -> [ErrandRecord.Fact] {
        ErrandModel.evidence(after: claims, shown: shown, url: page, kept: kept, asked: asked)
    }

    /// A claim's quote is the page's own words: code copies the run of blocks
    /// it cites, first to last, each on its line — never the words the model
    /// wrote — with the label it begins at and the page's shown address.
    func testCodeCopiesEachClaimsQuoteFromTheBlocksItCites() throws {
        let answer = #"{"claims": [{"cite": {"first": "main/:5", "last": "main/:6"}, "draws_on": [], "records": [], "text": "MODEL-WORDS-1 two jokes", "requirement_id": "r1"}, {"cite": {"first": "main/:7", "last": "main/:7"}, "draws_on": [], "records": [], "text": "MODEL-WORDS-2", "requirement_id": "r3"}], "answered": true}"#
        let claims = try XCTUnwrap(ErrandModel.claims(of: answer))
        let facts = ErrandModel.evidence(after: claims, shown: Self.shown, url: Self.page, kept: [], asked: ["r1", "r3"])
        XCTAssertEqual(facts, [
            .init(requirements: ["r1"], quote: "Joke 1: its days were numbered.\nJoke 2: it was two tired.",
                  source: "main/:5", url: Self.page),
            .init(requirements: ["r3"], quote: "By Sam", source: "main/:7", url: Self.page),
        ])
        let kept = String(decoding: try JSONEncoder().encode(facts), as: UTF8.self)
        XCTAssertFalse(kept.contains("MODEL-WORDS"), "the model's words are never kept")
    }

    /// A cite to a block the reader was not shown in this call — or not a
    /// block at all, or a run backwards — drops its claim; so does a record
    /// that is not a run of shown blocks. The other claims stand.
    func testACiteToABlockTheReaderWasNotShownDropsItsClaim() {
        let facts = Self.evidence([
            Self.claim(("main/:3", "main/:5")),
            Self.claim(("main/:5", "main/:8")),
            Self.claim(("main/:6", "main/:5")),
            Self.claim(("1", "1")),
            Self.claim(("main/:5", "main/:5"), records: [("main/:9", "main/:9")]),
            Self.claim(nil, records: [("main/:6", "main/:6"), ("main/:2", "main/:2")]),
            Self.claim(("main/:7", "main/:7")),
        ])
        XCTAssertEqual(facts, [.init(requirements: ["r1"], quote: "By Sam", source: "main/:7", url: Self.page)])
    }

    /// A claim rests on what it cites, its records and what it draws on — an
    /// earlier claim of the reply, or evidence collected before by its number.
    /// Every claim that rests on something keeps its quotes as evidence, each
    /// quote of a page once, numbered after what was collected; one that names
    /// a requirement asked adds it to each quote it rests on. A claim naming
    /// no requirement asked, or none, is context; one that rests on nothing is
    /// dropped (ITER-076 stage 1, № 34).
    func testAClaimRestsOnWhatItCitesItsRecordsAndWhatItDrawsOn() {
        let earlier: [ErrandRecord.Fact] = [
            .init(requirements: ["r1"], quote: "Earlier joke", source: "main/:2", url: "https://a.test/"),
            .init(requirements: ["r3"], quote: "Earlier author", source: "main/:3", url: "https://b.test/"),
        ]
        let facts = Self.evidence([
            Self.claim(("main/:5", "main/:5"), requirement: nil),
            Self.claim(("main/:6", "main/:6"), requirement: nil),
            Self.claim(nil, drawsOn: ["claim:0", "claim:1", "claim:7", "1", "2", "9", "e1"]),
            Self.claim(nil, records: [("main/:7", "main/:7")], requirement: "r3"),
            Self.claim(nil, drawsOn: ["claim:9", "claim:4"]),
            Self.claim(("main/:4", "main/:4"), requirement: "r9"),
            Self.claim(nil, drawsOn: ["claim:5"], requirement: "r3"),
            Self.claim(("main/:5", "main/:5")),
        ], kept: earlier)
        XCTAssertEqual(facts, [
            .init(requirements: ["r1"], quote: "Earlier joke", source: "main/:2", url: "https://a.test/"),
            .init(requirements: ["r1", "r3"], quote: "Earlier author", source: "main/:3", url: "https://b.test/"),
            .init(requirements: ["r1"], quote: "Joke 1: its days were numbered.", source: "main/:5", url: Self.page),
            .init(requirements: ["r1"], quote: "Joke 2: it was two tired.", source: "main/:6", url: Self.page),
            .init(requirements: ["r3"], quote: "By Sam", source: "main/:7", url: Self.page),
            .init(requirements: ["r3"], quote: "Ten jokes", source: "main/:4", url: Self.page),
        ])
    }

    /// Six of ten jokes on one page, four on another (ITER-076 stage 1, № 34).
    /// The first read gives no claim the requirement's id — none answers it
    /// whole — and every one is kept as numbered evidence, shown to the next
    /// read as `requirements=-`. The second read's one claim for r1 records
    /// its page's four and draws on the six by their numbers: all ten answer
    /// r1. A repeat — a number drawn on twice, a record cited twice, the same
    /// words of the same page read again under another label — is one entry;
    /// the heading no claim for r1 draws on stays context.
    func testClaimsWithoutARequirementAreKeptAsEvidenceALaterClaimDrawsOn() {
        let first: [ErrandModel.Block] = [.init(label: "main/:1", kind: "heading", text: "Six jokes")]
            + (1...6).map { ErrandModel.Block(label: "main/:\($0 + 1)", kind: "list_item", text: "Joke \($0)") }
        let second: [ErrandModel.Block] = [.init(label: "main/:1", kind: "heading", text: "Four jokes")]
            + (7...10).map { ErrandModel.Block(label: "main/:\($0 - 5)", kind: "list_item", text: "Joke \($0)") }
        let a = "https://a.test/", b = "https://b.test/"
        let read = ErrandModel.evidence(after: (1...7).map { Self.claim(("main/:\($0)", "main/:\($0)"), requirement: nil) },
                                        shown: first, url: a, kept: [], asked: ["r1"])
        XCTAssertEqual(read.map(\.quote), ["Six jokes"] + (1...6).map { "Joke \($0)" })
        XCTAssertEqual(read.map(\.requirements), Array(repeating: [], count: 7), "none answers r1 whole")
        XCTAssertEqual(ErrandModel.notes(read).components(separatedBy: "\n").first,
                       #"[1] "Six jokes" requirements=- source="main/:1" url="https://a.test/" quote="Six jokes""#)

        let all = ErrandModel.evidence(after: [Self.claim(nil, drawsOn: ["2", "3", "4", "5", "6", "7", "2"],
                                                          records: [("main/:2", "main/:2"), ("main/:3", "main/:3"),
                                                                    ("main/:4", "main/:4"), ("main/:5", "main/:5"),
                                                                    ("main/:2", "main/:2")])],
                                       shown: second, url: b, kept: read, asked: ["r1"])
        XCTAssertEqual(all.filter { $0.requirements == ["r1"] }.map(\.quote), (1...10).map { "Joke \($0)" })
        XCTAssertEqual(all.count, 11, "a repeat is one entry")
        XCTAssertEqual(all.first, read.first, "the heading stays context")

        // The first page read again, its lines labeled anew: nothing new.
        let shifted = [ErrandModel.Block(label: "main/:1", kind: "paragraph", text: "Ad")]
            + first.map { ErrandModel.Block(label: "main/:\(Int($0.label.dropFirst(6))! + 1)", kind: $0.kind, text: $0.text) }
        XCTAssertEqual(ErrandModel.evidence(after: [Self.claim(("main/:3", "main/:3"), requirement: nil)], shown: shifted,
                                            url: a, kept: all, asked: []), all)
    }

    /// The same words at two places of one page are two facts (2026-10-12, a table's Due column: "$50.00" in two rows
    /// was kept once, so anything counted from the facts lost a row). The page read again with its lines labeled
    /// anew still adds nothing. The answer's text still gives each quote of a page once, as designed.
    func testTheSameWordsAtTwoPlacesOfAPageAreTwoFacts() {
        let table: [ErrandModel.Block] = [
            .init(label: "main/:46", kind: "cell", text: "$50.00"), .init(label: "main/:52", kind: "cell", text: "$51.00"),
            .init(label: "main/:58", kind: "cell", text: "$100.00"), .init(label: "main/:64", kind: "cell", text: "$50.00"),
        ]
        let facts = ErrandModel.evidence(after: table.map { Self.claim(($0.label, $0.label)) }, shown: table,
                                         url: Self.page, kept: [], asked: ["r1"])
        XCTAssertEqual(facts.map(\.quote), ["$50.00", "$51.00", "$100.00", "$50.00"])
        XCTAssertEqual(facts.map(\.source), ["main/:46", "main/:52", "main/:58", "main/:64"])

        let shifted = [ErrandModel.Block(label: "main/:1", kind: "paragraph", text: "Ad")]
            + table.map { ErrandModel.Block(label: "main/:\(Int($0.label.dropFirst(6))! + 1)", kind: $0.kind, text: $0.text) }
        let again = ErrandModel.evidence(after: shifted.dropFirst().map { Self.claim(($0.label, $0.label)) },
                                         shown: shifted, url: Self.page, kept: facts, asked: ["r1"])
        XCTAssertEqual(again, facts, "read again, nothing new")

    }

    /// 2026-10-15 (the owner: the result counts, not the texts; the bench's "The total amount due across all rows in
    /// the second table is $251.00" was the reader's, and the answer kept only the four quotes): the reader's words
    /// are kept beside the page's, never in their place. Each claim that rests on something is a statement — its
    /// words, the requirement it answers whole when it named one asked, and the facts it rests on by their place —
    /// as a reference browser agent keeps each claim as a fact with its text and basis (`retrieval.py` 351-374,
    /// MIT). The facts stay the page's quotes. A claim dropped keeps no statement; the same statement read again is
    /// kept once.
    func testTheReadersWordsAreKeptBesideTheQuotesTheyRestOn() throws {
        let answer = #"{"claims": [{"cite": {"first": "main/:4", "last": "main/:4"}, "draws_on": [], "records": [], "text": "The list is titled Ten jokes.", "requirement_id": null}, {"cite": null, "draws_on": ["claim:0"], "records": [{"first": "main/:5", "last": "main/:5"}, {"first": "main/:6", "last": "main/:6"}], "text": "There are two jokes.", "requirement_id": "r1"}, {"cite": {"first": "main/:9", "last": "main/:9"}, "draws_on": [], "records": [], "text": "DROPPED", "requirement_id": "r1"}, {"cite": {"first": "main/:7", "last": "main/:7"}, "draws_on": [], "records": [], "text": "Sam wrote them.", "requirement_id": "r9"}], "answered": true}"#
        let claims = try XCTUnwrap(ErrandModel.claims(of: answer))
        XCTAssertEqual(claims.map(\.text), ["The list is titled Ten jokes.", "There are two jokes.", "DROPPED", "Sam wrote them."])
        let read = ErrandModel.read(after: claims, shown: Self.shown, url: Self.page, kept: [], said: [], asked: ["r1"])
        XCTAssertEqual(read.facts.map(\.quote), ["Ten jokes", "Joke 1: its days were numbered.", "Joke 2: it was two tired.",
                                                "By Sam"])
        XCTAssertEqual(read.facts.map(\.requirements), [["r1"], ["r1"], ["r1"], []])
        XCTAssertEqual(read.statements, [
            .init(requirement: nil, text: "The list is titled Ten jokes.", basis: [0]),
            .init(requirement: "r1", text: "There are two jokes.", basis: [0, 1, 2]),
            .init(requirement: nil, text: "Sam wrote them.", basis: [3]),
        ])
        XCTAssertEqual(ErrandModel.evidence(after: claims, shown: Self.shown, url: Self.page, kept: [], asked: ["r1"]),
                       read.facts, "the facts are what they were")
        let again = ErrandModel.read(after: claims, shown: Self.shown, url: Self.page, kept: read.facts,
                                     said: read.statements, asked: ["r1"])
        XCTAssertEqual(again.facts, read.facts)
        XCTAssertEqual(again.statements, read.statements, "read again, kept once")
    }

    /// 2026-10-15 bench (the Travel shelf): the reader named the compared books' blocks in draws_on, where the
    /// numbers of collected evidence go, and code dropped them — the winner rested on its own row alone and the
    /// verifier said missing. A name in draws_on of a block shown in this read is one of the claim's records: code
    /// copies its quote. A name of a block not shown still drops the claim, as a record's does.
    func testABlockNamedInDrawsOnIsARecordOfTheClaim() {
        let read = ErrandModel.read(after: [Self.claim(("main/:5", "main/:5"), drawsOn: ["main/:6", "main/:7"],
                                                       text: "Joke 1 is the longest.")],
                                    shown: Self.shown, url: Self.page, kept: [], said: [], asked: ["r1"])
        XCTAssertEqual(read.facts.map(\.quote), ["Joke 1: its days were numbered.", "Joke 2: it was two tired.", "By Sam"])
        XCTAssertEqual(read.statements, [.init(requirement: "r1", text: "Joke 1 is the longest.", basis: [0, 1, 2])])
        let unseen = ErrandModel.read(after: [Self.claim(("main/:5", "main/:5"), drawsOn: ["main/:66"])], shown: Self.shown,
                                      url: Self.page, kept: [], said: [], asked: ["r1"])
        XCTAssertEqual(unseen.facts, [], "a block it was not shown drops the claim")
        XCTAssertEqual(unseen.statements, [])
    }

    /// The notes — the reader's collected evidence and the verifier's — show each statement after the facts,
    /// numbered on from them: its words, its requirement or `-`, and the numbers of the facts it rests on. A later
    /// read draws on a statement by that number: the facts beneath it.
    func testTheNotesShowEachStatementAndALaterReadDrawsOnItByItsNumber() {
        let first = ErrandModel.read(after: [Self.claim(nil, records: [("main/:5", "main/:5"), ("main/:6", "main/:6")],
                                                        requirement: nil, text: "Page one holds two jokes.")],
                                     shown: Self.shown, url: Self.page, kept: [], said: [], asked: ["r1"])
        XCTAssertEqual(ErrandModel.notes(first.facts, first.statements).components(separatedBy: "\n"), [
            #"[1] "Joke 1: its days were numbered." requirements=- source="main/:5" url="https://site-404.test/" quote="Joke 1: its days were numbered.""#,
            #"[2] "Joke 2: it was two tired." requirements=- source="main/:6" url="https://site-404.test/" quote="Joke 2: it was two tired.""#,
            #"[3] "Page one holds two jokes." requirements=- basis=[1, 2]"#,
        ])
        let second: [ErrandModel.Block] = [.init(label: "main/:1", kind: "list_item", text: "Joke 3")]
        let all = ErrandModel.read(after: [Self.claim(nil, drawsOn: ["3"], records: [("main/:1", "main/:1")],
                                                      text: "There are three jokes.")],
                                   shown: second, url: "https://b.test/", kept: first.facts, said: first.statements,
                                   asked: ["r1"])
        XCTAssertEqual(all.facts.map(\.requirements), [["r1"], ["r1"], ["r1"]])
        XCTAssertEqual(all.statements.last, .init(requirement: "r1", text: "There are three jokes.", basis: [0, 1, 2]))
    }

    /// 2026-10-15: a reader's answer says which lists go on past its capture — each with its requirement, the
    /// control that shows the rest or none, and its records — and their records are kept as the page's own words,
    /// answering no requirement yet; a record of a block not shown is none. An answer without continues has none;
    /// one whose continues is not the schema's shape is no answer.
    func testAReaderAnswerSaysWhichListsGoOnAndTheirRecordsAreKept() throws {
        let answer = #"{"claims": [], "answered": false, "continues": [{"requirement_id": "r1", "expands": "Next", "records": [{"first": "main/:5", "last": "main/:5"}, {"first": "main/:6", "last": "main/:6"}, {"first": "main/:99", "last": "main/:99"}]}, {"requirement_id": "r3", "expands": null, "records": []}]}"#
        let continues = try XCTUnwrap(ErrandModel.continuations(of: answer))
        XCTAssertEqual(continues, [
            .init(requirement: "r1", expands: "Next", records: [.init(first: "main/:5", last: "main/:5"),
                                                                 .init(first: "main/:6", last: "main/:6"),
                                                                 .init(first: "main/:99", last: "main/:99")]),
            .init(requirement: "r3", expands: nil, records: []),
        ])
        XCTAssertNotNil(ErrandModel.claims(of: answer))
        let read = ErrandModel.read(after: [], continues: continues, shown: Self.shown, url: Self.page, kept: [], said: [],
                                    asked: ["r1", "r3"])
        XCTAssertEqual(read.facts.map(\.quote), ["Joke 1: its days were numbered.", "Joke 2: it was two tired."])
        XCTAssertEqual(read.facts.map(\.requirements), [[], []], "no requirement answered yet")
        XCTAssertEqual(ErrandModel.continuations(of: #"{"claims": [], "answered": true}"#), [])
        XCTAssertNil(ErrandModel.claims(of: #"{"claims": [], "answered": true, "continues": [{"requirement_id": 1}]}"#))
    }

    /// Codex review, P1-2: the same statement read again is kept once, at its latest place — "$101", "$100", then
    /// "$101" again leaves "$101" the last word for its requirement.
    func testAStatementReadAgainMovesToItsLatestPlace() {
        let claims = ["Total $101.", "Total $100.", "Total $101."].map {
            Self.claim(("main/:5", "main/:6"), text: $0)
        }
        let read = ErrandModel.read(after: claims, shown: Self.shown, url: Self.page, kept: [], said: [], asked: ["r1"])
        XCTAssertEqual(read.statements.map(\.text), ["Total $100.", "Total $101."])
        XCTAssertEqual(read.statements.last { $0.requirement == "r1" }?.text, "Total $101.")
    }

    /// Codex review, P1-3: a verdict's key is the whole of what it was asked — every step and visited address, not
    /// their counts: a run that went on to another page and came back is asked again.
    func testAVerdictsKeyIsTheWholeOfWhatItWasAsked() throws {
        let page = ObservedPage(url: "https://site-404.test/", title: "Jokes", truncated: false, flags: .none, elements: [],
                                text: "Ten jokes")
        let ask = { (visited: [String]) in
            AgentRun.verdictKey(of: ErrandModel.verifyRequest(goal: "g", requirements: Self.wanted, today: "2026-10-15",
                                                              steps: [], page: page, evidence: [], visited: visited))
        }
        XCTAssertEqual(ask(["https://a.test/"]), ask(["https://a.test/"]))
        XCTAssertNotEqual(ask(["https://a.test/"]), ask(["https://a.test/", "https://b.test/"]))
    }

    /// At most 60 claims of a reply are read, in code: the rest are dropped.
    func testAtMostSixtyClaimsOfAReplyAreRead() {
        let blocks = (1...61).map { ErrandModel.Block(label: "main/:\($0)", kind: "list_item", text: "Joke \($0)") }
        let claims = (1...61).map { Self.claim(("main/:\($0)", "main/:\($0)")) }
        let facts = ErrandModel.evidence(after: claims, shown: blocks, url: Self.page, kept: [], asked: ["r1"])
        XCTAssertEqual(facts.map(\.quote), (1...60).map { "Joke \($0)" })
        XCTAssertEqual(ErrandModel.maxClaims, 60)
    }

    /// The reader's answer is its strict schema's shape — `draws_on`,
    /// `records` and `requirement_id` may be left out, as the schema's
    /// defaults allow — or no reading at all: the read is then a miss, asked
    /// once.
    func testAReaderAnswerIsItsSchemasShapeOrNoReading() async throws {
        XCTAssertEqual(ErrandModel.claims(of: #"{"claims": [{"cite": {"first": "main/:1", "last": "main/:2"}, "draws_on": ["claim:0", "1"], "records": [{"first": "main/:3", "last": "main/:3"}], "text": "x", "requirement_id": "r1"}], "answered": true}"#),
                       [ErrandModel.Claim(cite: .init(first: "main/:1", last: "main/:2"), drawsOn: ["claim:0", "1"],
                                          records: [.init(first: "main/:3", last: "main/:3")], requirement: "r1",
                                          text: "x")])
        XCTAssertEqual(ErrandModel.claims(of: #"{"claims": [{"cite": null, "text": "x"}, {"cite": null, "text": "y", "requirement_id": null}], "answered": false}"#),
                       [Self.claim(nil, requirement: nil, text: "x"), Self.claim(nil, requirement: nil, text: "y")])
        XCTAssertEqual(ErrandModel.claims(of: #"{"claims": [], "answered": false}"#), [])
        let bad = [
            "Here are the jokes", #"{"claims": []}"#, #"{"claims": [], "answered": 1}"#, #"{"answered": true}"#,
            #"{"claims": {}, "answered": true}"#, #"{"claims": [], "answered": true, "tallies": []}"#,
            #"{"claims": [{"cite": null, "text": "x", "orders_list": null}], "answered": true}"#,
            #"{"claims": [{"text": "x"}], "answered": true}"#,
            #"{"claims": [{"cite": null}], "answered": true}"#,
            #"{"claims": [{"cite": "main/:1", "text": "x"}], "answered": true}"#,
            #"{"claims": [{"cite": {"first": "main/:1"}, "text": "x"}], "answered": true}"#,
            #"{"claims": [{"cite": {"first": "main/:1", "last": 2}, "text": "x"}], "answered": true}"#,
            #"{"claims": [{"cite": {"first": "main/:1", "last": "main/:1", "why": "x"}, "text": "x"}], "answered": true}"#,
            #"{"claims": [{"cite": null, "text": 5}], "answered": true}"#,
            #"{"claims": [{"cite": null, "text": "x", "requirement_id": 1}], "answered": true}"#,
            #"{"claims": [{"cite": null, "text": "x", "draws_on": "claim:0"}], "answered": true}"#,
            #"{"claims": [{"cite": null, "text": "x", "draws_on": [1]}], "answered": true}"#,
            #"{"claims": [{"cite": null, "text": "x", "records": [{"first": "main/:1"}]}], "answered": true}"#,
            #"{"claims": ["x"], "answered": true}"#,
        ]
        for answer in bad { XCTAssertNil(ErrandModel.claims(of: answer), answer) }

        let model = RecordedModel { _, _ in .text("Here are the jokes") }
        do {
            _ = try await model.model.read(goal: "g", wanted: [Self.wanted[0]], evidence: [],
                                           capture: ErrandModel.Capture(url: Self.page, frames: 0, blocks: Self.shown),
                                           chunk: Self.shown, index: 0, total: 1)
            XCTFail("a reading")
        } catch {
            XCTAssertEqual(error as? JevDecisionEngine.Failure, .invalidAnswer)
        }
        XCTAssertEqual(model.requests.count, 1, "asked once")
    }

    // MARK: - "Done?" (stage 1, № 35)

    /// Text 6 — with the page's one edit, "the screenshot, " removed — and its
    /// schema's three descriptions are the approved ones: the SHA-256 of each
    /// as the approval file holds it, equal to its source byte for byte
    /// otherwise. A changed one fails here: it needs the owner.
    func testTheVerifierTextAndItsSchemasWordsAreTheApprovedOnes() {
        let approved = "changed without the owner's approval"
        XCTAssertEqual(sha(ModelTexts.verifier), "6f0b5b01422859b315e42dd7ba67cbc440f0ac4b14004b3b0045bdf8a6810837", approved)
        // 2026-10-15 (Codex review, P1-1): the verdict checks a reader's conclusion against the notes it rests on — the
        // answer now gives the conclusion's words.
        XCTAssertEqual(sha(ModelTexts.verdict), "c3f278c86b15aec744e15ff3c46a7ebad784f7f29c55724d5f5e52d7917c77ce", approved)
        XCTAssertTrue(ModelTexts.verdict.contains("A note with a basis is the reader's conclusion, and the answer gives its words: it satisfies its requirement only when the notes it rests on show it"))
        XCTAssertEqual(sha(ModelTexts.verifierMissing), "acb92f6a47dc4fa56998d4d3433189b84f7e0c2349ec8dfb8fe1325b29a12280",
                       approved)
        XCTAssertEqual(sha(ModelTexts.verifierUngrounded), "75b901d5ce987146b9d02ff8498ec2eb2e4964161a8b9f8debbb6a53849548ae",
                       approved)
        XCTAssertEqual(sha(ModelTexts.verifierComplete), "062f57e6890e4aa53c22def982dca227731e35c7ce6563da63c2a0e0da540417",
                       approved)
        XCTAssertFalse(ModelTexts.verdict.contains("screenshot"), "the page's edit")
    }

    /// The verifier's own schema: its three fields, their kinds and the
    /// approved descriptions — every field required, as strict output wants,
    /// no title, no other word.
    private static let verifySchema: CDPValue = .object([
        "type": .string("object"),
        "properties": .object([
            "missing": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                "description": .string(ModelTexts.verifierMissing)]),
            "ungrounded": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                   "description": .string(ModelTexts.verifierUngrounded)]),
            "complete": .object(["type": .string("boolean"), "description": .string(ModelTexts.verifierComplete)]),
        ]),
        "required": .array([.string("missing"), .string("ungrounded"), .string("complete")]),
        "additionalProperties": .bool(false),
    ])

    /// One verifier call: text 6's trust line as the system message; as the
    /// user message, the run laid out as the approval page shows it — the
    /// task, the current date, the requirements, the steps taken, the set
    /// controls, where each requirement's facts were read, the visited
    /// addresses, the page and the notes — then text 6's verdict; no
    /// "Addresses this run built from the task", no screenshot. A section with
    /// nothing in it is left out as its source leaves it out; the steps and
    /// the controls are always there.
    func testTheVerifierIsTheApprovedTextAndTheRunLaidOutAsTheApprovalPageShowsIt() throws {
        let requirements: [AgentPlan.Requirement] = [.init(id: "r1", text: "Find 10 jokes", kind: .information),
                                                     .init(id: "r2", text: "Open the tips", kind: .action)]
        let steps = [RecentAction(label: "Search", kind: "click", typed: nil, pageChanged: true),
                     RecentAction(label: "Search", kind: "fill", typed: "jokes", pageChanged: false),
                     RecentAction(label: "Sort → Newest", kind: "select", typed: nil, pageChanged: true,
                                  effect: "changed Sort value: Relevance -> Newest")]
        func element(_ index: Int, _ role: String, _ name: String, value: String?, checked: Bool? = nil) -> ObservedElement {
            ObservedElement(index: index, role: role, name: name, text: "", href: nil, inputType: nil, heading: nil,
                            region: .main, inViewport: true, context: nil, formAction: nil, formMethod: nil,
                            formSubmitLabel: nil, options: nil, checked: checked, value: value)
        }
        let page = ObservedPage(url: "https://site-409.test/", title: "Jokes 409", truncated: false, flags: .none,
                                elements: [element(0, "combobox", "Search", value: "jokes"),
                                           element(1, "combobox", "Sort", value: "Newest"),
                                           element(2, "checkbox", "Funny only", value: nil, checked: true),
                                           element(5, "checkbox", "Clean only", value: nil, checked: false),
                                           element(3, "textbox", "Note", value: ""),
                                           element(4, "button", "Go", value: nil)],
                                text: "Four jokes\nJoke 7", address: "https://sam:pw@site-409.test/")
        let evidence: [ErrandRecord.Fact] = [
            .init(requirements: ["r1"], quote: "Joke 1", source: "main/:2", url: "https://b.test/"),
            .init(requirements: [], quote: "Six jokes", source: "main/:1", url: "https://b.test/"),
            .init(requirements: ["r1"], quote: "Joke 7", source: "main/:2", url: "https://a.test/"),
        ]
        let request = ErrandModel.verifyRequest(goal: "Find 10 jokes", requirements: requirements, today: "2026-09-29",
                                                steps: steps, page: page, evidence: evidence,
                                                visited: ["https://site-407.test/", "https://site-409.test/"])
        XCTAssertEqual(request.purpose, .verify)
        XCTAssertNil(request.maxTokens)
        XCTAssertNil(request.tools)
        XCTAssertEqual(request.messages.first, .object(["role": .string("system"), "content": .string(ModelTexts.verifier)]))
        let expected = """
            ## Task
            Find 10 jokes

            ## Current date
            2026-09-29

            ## Requirements
            - r1: Find 10 jokes
            - r2: Open the tips

            ## Steps taken
            - click Search -> executed
            - type Search = 'jokes' -> executed
            - Sort → Newest -> executed (changed Sort value: Relevance -> Newest)

            ## Set controls
            [{"label": "Search", "role": "combobox", "value": "jokes"}, {"label": "Sort", "role": "combobox", "value": "Newest"}, {"label": "Funny only", "role": "checkbox", "checked": true}]

            ## Where each requirement's facts were read
            - r1: https://a.test/, https://b.test/

            ## Visited addresses
            - https://site-407.test/
            - https://site-409.test/

            ## Page
            https://site-409.test/
            Four jokes
            Joke 7

            ## Notes
            [1] "Joke 1" requirements=r1 source="main/:2" url="https://b.test/" quote="Joke 1"
            [2] "Six jokes" requirements=- source="main/:1" url="https://b.test/" quote="Six jokes"
            [3] "Joke 7" requirements=r1 source="main/:2" url="https://a.test/" quote="Joke 7"
            """ + ModelTexts.verdict
        XCTAssertEqual(request.messages.dropFirst().first, .object(["role": .string("user"), "content": .string(expected)]))
        XCTAssertEqual(request.messages.count, 2)
        let format = try XCTUnwrap(request.responseFormat)
        XCTAssertEqual(format["type"], .string("json_schema"))
        XCTAssertEqual(format["json_schema"]?["name"], .string("LLMVerdict"))
        XCTAssertEqual(format["json_schema"]?["strict"], .bool(true))
        XCTAssertEqual(format["json_schema"]?.object.map { Set($0.keys) }, ["name", "strict", "schema"])
        XCTAssertEqual(format["json_schema"]?["schema"], Self.verifySchema)

        // Nothing taken, nothing read, nowhere visited.
        let bare = ErrandModel.verifyRequest(goal: "g", requirements: [requirements[1]], today: "2026-09-29", steps: [],
                                             page: ObservedPage(url: "https://a.test/", title: "", truncated: false,
                                                                flags: .none, elements: [], text: ""),
                                             evidence: [], visited: [])
        XCTAssertEqual(bare.messages.last?["content"]?.string, """
            ## Task
            g

            ## Current date
            2026-09-29

            ## Requirements
            - r2: Open the tips

            ## Steps taken


            ## Set controls
            []

            ## Page
            https://a.test/


            ## Notes

            """ + ModelTexts.verdict)
    }

    /// A step taken, as the reference shows one and the approval page lays it
    /// out: a click and a typing by their words, what was typed as Python
    /// writes a string, any other action by the label Jev reads it by — each
    /// "executed": every action the run lists went out.
    func testAStepTakenIsLaidOutAsTheApprovalPageShowsIt() {
        func typed(_ text: String) -> String {
            ErrandModel.step(RecentAction(label: "Note", kind: "fill", typed: text, pageChanged: nil))
        }
        XCTAssertEqual(ErrandModel.step(RecentAction(label: "Search", kind: "click", typed: nil, pageChanged: nil)),
                       "- click Search -> executed")
        XCTAssertEqual(typed("jokes"), "- type Note = 'jokes' -> executed")
        XCTAssertEqual(typed("don't"), #"- type Note = "don't" -> executed"#)
        XCTAssertEqual(typed("it's \"x\"\n\tback\\slash"), #"- type Note = 'it\'s "x"\n\tback\\slash' -> executed"#)
        XCTAssertEqual(typed("bell\u{07} zero\u{200B} caf\u{E9}"), "- type Note = 'bell\\x07 zero\\u200b caf\u{E9}' -> executed")
        XCTAssertEqual(ErrandModel.step(RecentAction(label: "Scroll down", kind: "scroll", typed: nil, pageChanged: nil)),
                       "- Scroll down -> executed")
        XCTAssertEqual(ErrandModel.step(RecentAction(label: "Search", kind: "fill", typed: nil, pageChanged: nil)),
                       "- type Search -> executed")
        // What it visibly did, once the next look told.
        XCTAssertEqual(ErrandModel.step(RecentAction(label: "Apple", kind: "click", typed: nil, pageChanged: true,
                                                     effect: "changed Apple checked: false -> true")),
                       "- click Apple -> executed (changed Apple checked: false -> true)")
    }

    /// The verdict is its schema's shape — `ungrounded` may be left out, as
    /// its default allows — or no verdict at all.
    func testAVerdictIsItsSchemasShapeOrNone() {
        XCTAssertEqual(ErrandModel.verdict(of: #"{"missing": ["r1"], "ungrounded": ["r2"], "complete": false}"#),
                       ErrandModel.Verdict(missing: ["r1"], ungrounded: ["r2"], complete: false, usage: nil))
        XCTAssertEqual(ErrandModel.verdict(of: #"{"missing": [], "complete": true}"#),
                       ErrandModel.Verdict(missing: [], ungrounded: [], complete: true, usage: nil))
        for bad in ["complete", #"{"missing": [], "ungrounded": []}"#, #"{"ungrounded": [], "complete": true}"#,
                    #"{"missing": [], "ungrounded": [], "complete": "yes"}"#, #"{"missing": "r1", "complete": true}"#,
                    #"{"missing": [1], "complete": true}"#, #"{"missing": [], "ungrounded": null, "complete": true}"#,
                    #"{"missing": [], "complete": true, "why": "x"}"#, #"["r1"]"#] {
            XCTAssertNil(ErrandModel.verdict(of: bad), bad)
        }
    }

    /// The page as the reader reads it: its lines labeled `main/:1`, `main/:2`,
    /// … in order, each with its kind — a line longer than one call cut into
    /// lines that fit — and anything else no page at all. A page is read in
    /// chunks of at most 12,000 characters, whole lines in order.
    func testAPagesLinesAreLabeledInOrderAndReadInChunksOfAtMost12000Characters() throws {
        let long = String(repeating: "a", count: 30_000)
        let json = #"{"url": "https://site-404.test/", "frames": 1, "blocks": [["heading", "Ten jokes"], ["list_item", "Joke 1"], ["paragraph", ""# + long + #""], ["paragraph", "End"]]}"#
        let capture = try XCTUnwrap(ErrandModel.Capture.decode(json))
        XCTAssertEqual(capture.url, "https://site-404.test/")
        XCTAssertEqual(capture.frames, 1)
        XCTAssertEqual(capture.blocks.map(\.label), (1...6).map { "main/:\($0)" })
        XCTAssertEqual(capture.blocks.map(\.kind), ["heading", "list_item", "paragraph", "paragraph", "paragraph", "paragraph"])
        XCTAssertEqual(capture.blocks.map(\.text.count), [9, 6, 12_000, 12_000, 6_000, 3])
        XCTAssertEqual(capture.blocks[2...4].map(\.text).joined(), long)
        for bad in [#"{"url": "https://a.test/", "frames": 0, "blocks": [["table", "x"]]}"#,
                    #"{"url": "https://a.test/", "frames": -1, "blocks": []}"#,
                    #"{"frames": 0, "blocks": []}"#,
                    #"{"url": "https://a.test/", "frames": 0, "blocks": [["paragraph"]]}"#,
                    #"{"url": "https://a.test/", "frames": 0, "blocks": [["paragraph", 5]]}"#,
                    "not json",
                    #"{"url": "https://a.test/", "frames": 0, "blocks": [["paragraph", ""# + String(repeating: "a", count: 2_000_001) + #""]]}"#] {
            XCTAssertNil(ErrandModel.Capture.decode(bad), String(bad.prefix(80)))
        }

        let blocks = (1...5).map { ErrandModel.Block(label: "main/:\($0)", kind: "paragraph",
                                                    text: String(repeating: "\($0)", count: 5_000)) }
        let chunks = ErrandModel.chunks(blocks)
        XCTAssertEqual(chunks.map { $0.map(\.label) }, [["main/:1", "main/:2"], ["main/:3", "main/:4"], ["main/:5"]])
        XCTAssertEqual(ErrandModel.chunks(capture.blocks).map { $0.map(\.label) },
                       [["main/:1", "main/:2"], ["main/:3"], ["main/:4"], ["main/:5", "main/:6"]])
        for chunk in ErrandModel.chunks(capture.blocks) + chunks {
            XCTAssertLessThanOrEqual(chunk.map(\.text).joined(separator: "\n").count, 12_000)
        }
        XCTAssertEqual(ErrandModel.chunkLimit, 12_000)
    }

    /// ITER-076 stage 4a: what the page's walk met comes beside its lines and
    /// is read by its kinds and counts alone — a rule the app does not know,
    /// or a count that is not one, is left out — and a walk that is not one
    /// costs the lines nothing: the page is read without it.
    func testAPagesWalkIsReadByItsKindsAndCountsAlone() throws {
        let lines = #""url": "https://site-1.test/", "frames": 0, "blocks": [["paragraph", "One"]]"#
        let walk = #""walk": {"root": "role", "roots": 2, "hidden": true, "met": 9, "kept": 1, "dropped": {"unseen": 5, "hidden": 2, "Sam's words": 3, "writing": -1, "dots": 1.5}, "cut": "time"}"#
        let read = try XCTUnwrap(ErrandModel.Capture.decode("{" + lines + ", " + walk + "}"))
        XCTAssertEqual(read.walk, ErrandModel.Capture.Walk(root: .role, roots: 2, pageHidden: true, met: 9, kept: 1,
                                                           dropped: [.unseen: 5, .hidden: 2], cut: .time))
        XCTAssertEqual(read.blocks.map(\.text), ["One"])
        for broken in [#""walk": {"root": "sidebar", "roots": 1, "hidden": false, "met": 1, "kept": 1, "dropped": {}}"#,
                       #""walk": {"root": "main", "roots": -1, "hidden": false, "met": 1, "kept": 1, "dropped": {}}"#,
                       #""walk": {"root": "main", "roots": 1, "met": 1, "kept": 1, "dropped": {}}"#,
                       #""walk": "everything""#] {
            let capture = try XCTUnwrap(ErrandModel.Capture.decode("{" + lines + ", " + broken + "}"), broken)
            XCTAssertNil(capture.walk, broken)
            XCTAssertEqual(capture.blocks.map(\.text), ["One"], broken)
        }
        let unknownCut = try XCTUnwrap(ErrandModel.Capture.decode(
            "{" + lines + #", "walk": {"root": "body", "roots": 0, "hidden": false, "met": 1, "kept": 1, "dropped": {}, "cut": "soon"}}"#))
        XCTAssertEqual(unknownCut.walk?.cut, nil, "a cut the app does not know is left out")
        XCTAssertEqual(unknownCut.walk?.root, .body)
        XCTAssertNil(try XCTUnwrap(ErrandModel.Capture.decode("{" + lines + "}")).walk)
    }
}
