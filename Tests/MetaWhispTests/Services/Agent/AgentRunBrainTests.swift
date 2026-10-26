import XCTest
@testable import MetaWhisp

/// ITER-076 brain, step 1, in the loop: an answer errand. The text model names
/// one sub-goal at a time with the `browser_do` tool and reads what came of
/// each; Jev picks every step of it, its question A and watchers reading the
/// sub-goal while its risk questions keep the user's goal; a field's text is
/// the text model's; a search the agent typed goes without a Yes (D4); and
/// what the model's service says is the errand's honest end.
final class AgentRunBrainTests: XCTestCase {

    private static let goal = "Find 10 jokes on site four oh one"
    private static let start = URL(string: "https://site-401.test/")!

    private static func plan() throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: goal, requirements: [.init(id: "r1", text: "Find 10 jokes", kind: .information),
                                                           .init(id: "r2", text: "Open the tips", kind: .action)],
                                answerExpected: true))
    }

    @MainActor
    private func run(_ engine: any DecisionEngine, _ model: RecordedModel, planner: (any ErrandPlanner)? = nil,
                     goal: String = goal, bridge: (any BrowserBridge)? = nil, start: URL = start,
                     confirm: @escaping @MainActor @Sendable (ConfirmationRequest) async -> ConfirmationRequest.Answer?
                        = { _ in .no },
                     lines: LogLines? = nil, limits: AgentBudget.Limits = .standard,
                     switchedOff: @escaping @MainActor @Sendable () -> Void = {}) throws -> AgentRun {
        AgentRun(goal: goal, planner: try planner ?? FixedPlanner(plan: Self.plan()), errandID: UUID(),
                 collaborators: .init(bridge: bridge ?? WebViewBridge(), engine: engine, writer: FakeWriter(),
                                      sheet: FixtureSheet(),
                                      confirm: confirm, log: lines?.sink ?? { _ in }, model: model.model,
                                      switchedOff: switchedOff),
                 limits: limits, startPage: start)
    }

    private static func named(_ name: String, _ request: ChooseRequest) -> Candidate? {
        request.candidates.first { $0.action.target?.name == name }
    }

    private static func operation(_ operation: AgentOperation, _ request: ChooseRequest) -> Candidate? {
        request.candidates.first { $0.action.operation == operation }
    }

    private static func field(_ request: ChooseRequest) -> Candidate? {
        request.candidates.first { $0.action.operation == .type && $0.action.target?.name == "Search" }
    }

    /// The model's sub-goal call `index`, from 0.
    private func subgoalCall(_ model: RecordedModel, _ index: Int) throws -> RecordedModel.Asked {
        try XCTUnwrap(model.requests("subgoal").dropFirst(index).first, "sub-goal call \(index)")
    }

    /// The results the model read in that sub-goal call for the calls of its
    /// last reply, in order.
    private func lastResults(_ asked: RecordedModel.Asked) -> [[String: Any]] {
        let messages = asked.messages
        guard let reply = messages.lastIndex(where: { $0["role"] as? String == "assistant" }) else { return [] }
        return messages[(reply + 1)...].filter { $0["role"] as? String == "tool" }.compactMap {
            ($0["content"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
    }

    /// The model: each sub-goal call answers from `subgoals` — a call naming
    /// that goal, or, past the list, a reply without one.
    private static func calling(_ subgoals: [String], fieldText: [String] = []) -> RecordedModel {
        RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return n < subgoals.count ? .calls([RecordedModel.goal(subgoals[n])]) : .text("Done.")
            case "field_text": return n < fieldText.count ? .text(fieldText[n]) : .status(400)
            default: return .status(400)
            }
        }
    }

    // MARK: - Where an answer errand begins

    /// The fixture browser, keeping every address a tab is opened at.
    @MainActor
    private final class KeepsOpened: BrowserBridge {
        let inner = WebViewBridge()
        var opened: [URL] = []

        func openTab(_ url: URL) async throws -> BrowserTab {
            opened.append(url)
            return try await inner.openTab(url)
        }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String { try await inner.run(javascript, in: tab) }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// An errand whose goal names a website begins on it — a link as the user wrote it, a bare host as https —
    /// not on the search engine (2026-10-07: "Start at https://pypi.org/. …" began on the search page and had to find
    /// the site first). A goal naming none, or only an address the agent never opens, begins on the start page.
    @MainActor
    func testAnErrandWhoseGoalNamesASiteBeginsOnIt() async throws {
        let cases: [(goal: String, start: String)] = [
            ("Start at https://site-402.test/jokes. Find 10 jokes.", "https://site-402.test/jokes"),
            ("Request a demo on example.com please", "https://example.com"),
            ("Find 10 jokes", Self.start.absoluteString),
            ("Open http://localhost:8080/admin and find 10 jokes", Self.start.absoluteString),
            ("Write to sam@example.test about 10 jokes", Self.start.absoluteString),
        ]
        for (goal, start) in cases {
            let bridge = KeepsOpened()
            let model = Self.calling([])
            let errand = try run(Self.done, model, goal: goal, bridge: bridge)
            _ = await errand.run(report: { _ in })
            XCTAssertEqual(bridge.opened.first?.absoluteString, start, goal)
        }
    }

    /// The address the user named reaches the run through its setup when MetaChat's goal lost it (2026-10-12: the
    /// goal "Find 10 short jokes in Russian using DuckDuckGo" began on the search engine's start page, which showed
    /// its CAPTCHA): the factory's run begins there. A goal with an address of its own begins on that one.
    @MainActor
    func testTheFactorysRunBeginsAtItsSetupsStartWhenTheGoalNamesNone() async throws {
        let cases: [(goal: String, start: String)] = [
            ("Find 10 jokes", "https://site-402.test/jokes"),
            ("Start at https://site-403.test/. Find 10 jokes.", "https://site-403.test/"),
        ]
        for (goal, start) in cases {
            let bridge = KeepsOpened()
            let factory = AgentRun.factory(planner: try FixedPlanner(plan: Self.plan()), engine: Self.done,
                                           writer: FakeWriter(), sheet: nil, model: Self.calling([]).model,
                                           startPage: Self.start)
            let errand = factory(ErrandSetup(id: UUID(), goal: goal, bridge: bridge, confirm: { _ in .no },
                                             start: URL(string: "https://site-402.test/jokes")))
            _ = await errand.run(report: { _ in })
            XCTAssertEqual(bridge.opened.first?.absoluteString, start, goal)
        }
    }

    /// A sub-goal that names an address opens it as its first step, the run's own (2026-10-07: the model wrote
    /// "Open https://…" five times and Jev had no step that goes to an address); a sub-goal naming only an
    /// address the agent never opens stays on its page.
    @MainActor
    func testASubgoalThatNamesAnAddressOpensItFirst() async throws {
        let bridge = WebViewBridge()
        _ = await (try run(Self.done, Self.calling(["Open https://site-402.test/ and find the jokes"]), bridge: bridge))
            .run(report: { _ in })
        XCTAssertTrue(bridge.navigatedURLs.contains(URL(string: "https://site-402.test/")!), "\(bridge.navigatedURLs)")
        let stays = WebViewBridge()
        _ = await (try run(Self.done, Self.calling(["Open http://localhost:8080/ and find the jokes"]), bridge: stays))
            .run(report: { _ in })
        XCTAssertFalse(stays.navigatedURLs.contains { $0.host == "localhost" }, "\(stays.navigatedURLs)")
    }

    // MARK: - The sub-goal conversation (G3)

    /// The model names a sub-goal; Jev works toward it until it is done; the
    /// model reads the result and, calling no more, thinks the errand done.
    @MainActor
    func testAnAnswerErrandRunsTheSubgoalsTheModelNamesAndEndsWhenItCallsNoMore() async throws {
        let model = Self.calling(["Show the tips"])
        let seen = Seen()
        let engine = ScriptedEngine(choice: { request in
            seen.add(request)
            return ScriptedEngine.pick(Self.named("Hide tips", request) != nil ? Self.operation(.done, request)
                                                                               : Self.named("Show tips", request))
        })
        let bridge = WebViewBridge()
        let run = try run(engine, model, bridge: bridge)
        let outcome = await run.run(report: { _ in })

        XCTAssertEqual(outcome.ending, .notFinished,
                       "no call: the model thinks it is done; nothing answers r1, so the errand is not finished")
        XCTAssertEqual(model.requests("subgoal").count, 4, "its end rejected twice, then not finished (2026-10-15)")
        XCTAssertEqual(seen.all.map(\.goal), ["Show the tips", "Show the tips"], "Jev works toward the sub-goal")
        XCTAssertEqual(bridge.openedURLs, [Self.start], "the start page")
        XCTAssertEqual(bridge.openTabCount, 0)
        let result = try XCTUnwrap(lastResults(try subgoalCall(model, 1)).first)
        XCTAssertEqual(result["status"] as? String, "done")
        XCTAssertEqual(result["actions"] as? [String], ["click Show tips"])
        XCTAssertEqual(result["url"] as? String, "https://site-401.test/")
        XCTAssertEqual(result["title"] as? String, "Search 401")
        XCTAssertEqual(result["still_to_find"] as? [String], ["Find 10 jokes"], "the facts still to find")
        XCTAssertTrue((result["page_text"] as? String)?.contains("Hide tips") == true,
                      "done with facts still to find: the page the next sub-goal is named by (2026-10-16)")
    }

    /// The step's question A and the watchers read the sub-goal; the risk
    /// questions read the user's goal — on the wire, as Jev gets them.
    @MainActor
    func testJevsStepAndWatchersReadTheSubgoalAndItsRiskQuestionsTheUsersGoal() async throws {
        let model = Self.calling(["Show the tips"])
        let jev = RecordedJev { asked, _ in
            guard asked.isStep else { return .answers() }
            if let key = asked.key(labelled: "Show tips") { return .answers(operation: "CLICK", target: key) }
            return .answers(operation: "DONE")
        }
        let outcome = await (try run(jev.engine, model)).run(report: { _ in })
        XCTAssertEqual(outcome.ending, .notFinished)

        let bodies = try jev.bodies.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        let questions = { (body: [String: Any]) in body["questions"] as? [String: [String: Any]] ?? [:] }
        let steps = bodies.filter { questions($0)["operation"] != nil }
        let risks = bodies.filter { questions($0)["destructive_0"] != nil }
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(risks.count, 1)
        for step in steps {
            let instructions = questions(step)["operation"]?["instructions"] as? [String: Any]
            XCTAssertEqual(instructions?["goal"] as? String, "Show the tips", "question A reads the sub-goal")
            XCTAssertEqual((step["state"] as? [String: Any])?["task"] as? String, "Show the tips",
                           "the watchers read the sub-goal")
        }
        XCTAssertEqual((risks[0]["state"] as? [String: Any])?["task"] as? String, Self.goal,
                       "the risk questions read the user's goal")
    }

    /// A reply with several calls: the first runs; each other gets the
    /// result's shape with status `stuck` and no actions — it was not tried.
    @MainActor
    func testAReplyWithSeveralCallsRunsTheFirstAndTellsTheOthersTheyWereNotTried() async throws {
        let model = RecordedModel { asked, n in
            n == 0 ? .calls([RecordedModel.goal("Show the tips"), RecordedModel.goal("Open the other page")])
                   : .text("Done.")
        }
        let seen = Seen()
        let engine = ScriptedEngine(choice: { request in
            seen.add(request)
            return ScriptedEngine.pick(Self.named("Hide tips", request) != nil ? Self.operation(.done, request)
                                                                               : Self.named("Show tips", request))
        })
        let outcome = await (try run(engine, model)).run(report: { _ in })
        XCTAssertEqual(outcome.ending, .notFinished)
        XCTAssertEqual(Set(seen.all.map(\.goal)), ["Show the tips"], "only the first call runs")

        let second = try subgoalCall(model, 1)
        XCTAssertEqual(second.messages.filter { $0["role"] as? String == "tool" }.map { $0["tool_call_id"] as? String },
                       ["call_1", "call_2"], "every call id gets its result")
        let results = lastResults(second)
        XCTAssertEqual(results.map { $0["status"] as? String }, ["done", "stuck"])
        XCTAssertEqual(results[1]["actions"] as? [String], [])
        XCTAssertNotNil(results[1]["page_text"] as? String)
        XCTAssertEqual(results[1]["still_to_find"] as? [String], ["Find 10 jokes"])
    }

    /// A call with no goal is not run: its result is `stuck` with no actions.
    @MainActor
    func testACallWithoutAGoalIsNotRun() async throws {
        let model = RecordedModel { _, n in n == 0 ? .calls([#"{"goal":"  "}"#]) : .text("Done.") }
        let seen = Seen()
        let engine = ScriptedEngine(choice: { request in
            seen.add(request)
            return ScriptedEngine.pick(Self.operation(.done, request))
        })
        let outcome = await (try run(engine, model)).run(report: { _ in })
        XCTAssertEqual(outcome.ending, .notFinished)
        XCTAssertEqual(seen.count, 0, "Jev is never asked")
        XCTAssertEqual(lastResults(try subgoalCall(model, 1)).map { $0["status"] as? String }, ["stuck"])
    }

    /// At most 15 sub-goals: the model is asked no more, and an errand it
    /// never said was done was not getting anywhere.
    @MainActor
    func testTheModelIsAskedForAtMostFifteenSubgoals() async throws {
        let model = RecordedModel { _, _ in .calls([RecordedModel.goal("Finish the page")]) }
        let engine = ScriptedEngine(choice: { ScriptedEngine.pick(Self.operation(.done, $0)) })
        let outcome = await (try run(engine, model)).run(report: { _ in })
        XCTAssertEqual(model.requests("subgoal").count, 15)
        XCTAssertEqual(outcome.ending, .stuck)
    }

    /// 2026-10-08 (live, a country on a long list): Jev scrolled a long page
    /// for a fact the reader reads whole, and after eight steps with no
    /// progress the whole errand ended stuck, the page never read. No
    /// progress still ends the errand — but only once the page it stopped on
    /// is read: a fact the reader finds there is its answer.
    @MainActor
    func testNoProgressEndsTheErrandOnlyOnceItsPageIsRead() async throws {
        let model = RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return n < 1 ? .calls([RecordedModel.goal("Find the joke")]) : .text("Done.")
            case "read": return .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:2"),
                                                                                  requirement: "r1")]))
            case "verify": return RecordedModel.verdict(complete: true)
            default: return .status(400)
            }
        }
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.operation == .scroll }
                                ?? Self.operation(.done, request))
        })
        let run = try run(engine, model, planner: Self.reads(), start: Self.jokes)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(run.record.steps.filter { $0.operation == "scroll" }.count, ProgressTracker.stepsWithoutProgressLimit,
                       "the premise: no progress, as long as the watcher allows: \(run.record.eventLines)")
        XCTAssertEqual(model.requests("read").count, 1, "the page it left is read")
        XCTAssertEqual(outcome.ending, .done, "\(run.record.eventLines)")
        XCTAssertEqual(outcome.answer, Self.jokeLines[0] + "\nhttps://site-404.test/")
    }

    /// ITER-076 stage 4c (F4): every sub-goal call lets the model answer
    /// without the tool (`auto`): a provider failed the first call that
    /// required it. A first reply without a call answers from no page: the
    /// user's own goal runs as the first sub-goal — the run's own call of the
    /// tool, the reply's words not kept — and the loop goes on. It runs once:
    /// a model that never names a sub-goal ends after it, and the errand's
    /// answer is what its page gave, never the model's words.
    @MainActor
    func testAFirstReplyWithoutACallRunsTheUsersOwnGoalOnceAndTheAnswerIsWhatWasRead() async throws {
        let model = RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return .text("MODEL-MEMORY-\(n)")
            case "read": return .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:2"),
                                                                                  requirement: "r1")]))
            case "verify": return RecordedModel.verdict(complete: n == 1)
            default: return .status(400)
            }
        }
        let seen = Seen()
        let engine = ScriptedEngine(choice: { request in
            seen.add(request)
            return ScriptedEngine.pick(Self.operation(.done, request))
        })
        let run = try run(engine, model, planner: Self.reads(), start: Self.jokes)
        let outcome = await run.run(report: { _ in })

        let asks = model.requests("subgoal")
        XCTAssertEqual(asks.map { $0.body["tool_choice"] as? String }, ["auto", "auto"],
                       "auto every time: asked again after the run's own sub-goal, the model stopped")
        XCTAssertEqual(seen.all.map(\.goal), [Self.goal], "the user's own goal is the first sub-goal, once")
        XCTAssertEqual(model.requests("read").count, 1, "the page it left is read")
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.answer, Self.jokeLines[0] + "\nhttps://site-404.test/", "the answer is what was read")
        XCTAssertEqual(outcome.sources, [Self.jokes])

        // The run's own call, as the model reads it next: the tool with the
        // user's goal as its one parameter, its result under the call's id.
        let next = try XCTUnwrap(asks.dropFirst().first)
        XCTAssertEqual(next.messages.count, 4)
        let reply = try XCTUnwrap(next.messages.dropFirst(2).first)
        XCTAssertEqual(reply["role"] as? String, "assistant")
        XCTAssertTrue(reply["content"] is NSNull, "the reply's words are not kept")
        let calls = try XCTUnwrap(reply["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 1)
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        let id = try XCTUnwrap(calls.first?["id"] as? String)
        let arguments = try XCTUnwrap(function["arguments"] as? String)
        XCTAssertEqual(ErrandModel.goal(of: ProLLMClient.ToolCall(id: id, name: function["name"] as? String ?? "",
                                                                  arguments: arguments)), Self.goal)
        XCTAssertEqual(next.messages.dropFirst(3).first?["tool_call_id"] as? String, id)
        XCTAssertEqual(lastResults(next).first?["status"] as? String, "done")
        let record = String(decoding: try JSONEncoder().encode(run.record), as: UTF8.self)
        XCTAssertFalse(record.contains("MODEL-MEMORY"), "the model's words are in no fact")
        XCTAssertFalse(outcome.answer?.contains("MODEL-MEMORY") ?? true, "nor in the answer")
    }

    // MARK: - How a sub-goal ends (G4)

    /// The status of the first sub-goal, as the model read it, and the steps.
    @MainActor
    private func firstSubgoal(_ choice: @escaping @Sendable (ChooseRequest) -> ChooseAnswer)
        async throws -> (status: String?, actions: [String]?, steps: [ErrandRecord.Outcome]) {
        let model = Self.calling(["Finish the tips"])
        let run = try run(ScriptedEngine(choice: choice), model)
        _ = await run.run(report: { _ in })
        let result = lastResults(try XCTUnwrap(model.requests("subgoal").dropFirst().first)).first
        return (result?["status"] as? String, result?["actions"] as? [String], run.record.steps.map(\.outcome))
    }

    /// DONE ends the sub-goal at any confidence: it acts on nothing, and the page it leaves is read and judged —
    /// as a reference browser agent keeps DONE out of its confidence gate (`agent.py` 767-772, MIT). Reconsidered
    /// below 0.80, an unsure DONE on a page that showed the result sent Jev to pick a link and leave it
    /// (2026-10-16). BLOCKED ends it only from `subgoalEndsFrom`; below it, it is reconsidered, two in a row stuck.
    @MainActor
    func testADoneEndsTheSubgoalAtAnyConfidenceABlockedOnlyWhenJevIsSure() async throws {
        let done = try await firstSubgoal { ScriptedEngine.pick(Self.operation(.done, $0), confidence: 0.80) }
        XCTAssertEqual(done.status, "done")
        XCTAssertEqual(done.steps, [.acted])
        let unsure = try await firstSubgoal { ScriptedEngine.pick(Self.operation(.done, $0), confidence: 0.29) }
        XCTAssertEqual(unsure.status, "done")
        XCTAssertEqual(unsure.steps, [.acted])
        let blocked = try await firstSubgoal { ScriptedEngine.pick(Self.operation(.stuck, $0), confidence: 0.9) }
        XCTAssertEqual(blocked.status, "blocked")
        XCTAssertEqual(blocked.steps, [.acted])
        let unsureBlocked = try await firstSubgoal { ScriptedEngine.pick(Self.operation(.stuck, $0), confidence: 0.5) }
        XCTAssertEqual(unsureBlocked.status, "stuck")
        XCTAssertEqual(unsureBlocked.steps, [.reconsidered, .reconsidered])
    }

    /// ITER-076 stage 4a (F1, the owner's copy-first rule, 2026-10-06): a link Jev
    /// would open at 0.79 — the first live run's first result — is opened: a
    /// reversible step acts from 0.55.
    @MainActor
    func testALinkJevWouldOpenAtPointSevenNineIsOpened() async throws {
        let model = Self.reading(["Open the next page of jokes"]) { _, _ in .text(RecordedModel.reading([])) }
        let engine = ScriptedEngine(choice: { request in
            guard request.page.url == Self.sixJokes.absoluteString else {
                return ScriptedEngine.pick(Self.operation(.done, request))
            }
            return ScriptedEngine.pick(Self.named("Four more jokes", request), confidence: 0.79)
        })
        let bridge = WebViewBridge()
        let run = try run(engine, model, planner: Self.reads(), bridge: bridge, start: Self.sixJokes)
        _ = await run.run(report: { _ in })
        let first = try XCTUnwrap(run.record.steps.first)
        XCTAssertEqual(first.operation, "open")
        XCTAssertEqual(first.outcome, .acted)
        XCTAssertEqual(first.confidence, 0.79)
        XCTAssertTrue(bridge.navigatedURLs.contains(Self.fourJokes), "the page it leads to was opened")
    }

    /// `goal_done` above 0.85 ends the sub-goal before the step acts (A2
    /// P2-4); at 0.85 the step acts.
    @MainActor
    func testGoalDoneAboveTheLineEndsTheSubgoalBeforeTheStepActs() async throws {
        let above = try await firstSubgoal { ScriptedEngine.pick(Self.named("Show tips", $0), goalMet: 0.86) }
        XCTAssertEqual(above.status, "done")
        XCTAssertEqual(above.actions, [], "the step did not act")
        XCTAssertEqual(above.steps, [])
        let at = try await firstSubgoal { request in
            Self.named("Hide tips", request) != nil ? ScriptedEngine.pick(Self.operation(.done, request))
                : ScriptedEngine.pick(Self.named("Show tips", request), goalMet: 0.85)
        }
        XCTAssertEqual(at.status, "done")
        XCTAssertEqual(at.actions, ["click Show tips"])
    }

    /// The stuck watcher ends a sub-goal from its own third step, and counts
    /// again from the next sub-goal's first.
    @MainActor
    func testTheStuckWatcherEndsTheSubgoalFromItsOwnThirdStep() async throws {
        let model = Self.calling(["Look around", "Look again"])
        let steps = Steps()
        let engine = ScriptedEngine(choice: { request in
            let n = steps.next(request.goal)
            // Wait then scroll, then scroll then wait: no repeat, no A-B-A-B.
            let order: [AgentOperation] = request.goal == "Look around" ? [.wait, .scroll, .wait] : [.scroll, .wait, .scroll]
            return ScriptedEngine.pick(Self.operation(order[min(n, 2)], request), stuck: 0.95)
        })
        let run = try run(engine, model)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .notFinished)
        let first = lastResults(try subgoalCall(model, 1)).first
        XCTAssertEqual(first?["status"] as? String, "stuck")
        XCTAssertEqual(first?["actions"] as? [String], ["Wait for the page to update", "Scroll down"],
                       "a page control by the label Jev reads it by")
        let second = lastResults(try subgoalCall(model, 2)).first
        XCTAssertEqual(second?["status"] as? String, "stuck")
        XCTAssertEqual(second?["actions"] as? [String], ["Scroll down", "Wait for the page to update"],
                       "counted again from its first step")
    }

    /// Ten steps end a sub-goal at `max_actions`.
    @MainActor
    func testASubgoalEndsAfterTenSteps() async throws {
        let steps = Steps()
        // A scroll, then a BLOCKED Jev is unsure of, in turn: no two misses in
        // a row, and too few steps for the progress rule. (An unsure scroll is
        // tried now, once a page state, 2026-10-15: it would act; an unsure
        // DONE ends the sub-goal, 2026-10-16.)
        let status = try await firstSubgoal { request in
            steps.next("all") % 2 == 0 ? ScriptedEngine.pick(Self.operation(.scroll, request), confidence: 0.95)
                : ScriptedEngine.pick(Self.operation(.stuck, request), confidence: 0.6)
        }
        XCTAssertEqual(status.status, "max_actions")
        XCTAssertEqual(status.steps.count, 10)
        XCTAssertEqual(status.actions, Array(repeating: "Scroll down", count: 5))
    }

    /// A finished sub-goal is progress: eight steps without one end the
    /// errand as stuck, but a sub-goal done starts the count again.
    @MainActor
    func testAFinishedSubgoalCountsAsProgress() async throws {
        let steps = Steps()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(Self.operation(steps.next(request.goal) < 5 ? .scroll : .done, request))
        })
        let model = Self.calling(["Scroll first", "Scroll again"])
        let outcome = await (try run(engine, model)).run(report: { _ in })
        XCTAssertEqual(outcome.ending, .notFinished, "five steps and done, twice: never eight without progress")
        XCTAssertEqual(model.requests("subgoal").count, 5, "two sub-goals, the model's end and two ends rejected")
    }

    /// … and the progress rule still holds when no sub-goal is finished: seven steps, BLOCKED, then the next
    /// sub-goal's first step make eight without progress. In an answer errand that ends the sub-goal stuck, not the
    /// errand: the model reads it and names another way (2026-10-15; a reference browser agent sends a stall to
    /// recovery). A rows errand still ends stuck.
    @MainActor
    func testEightStepsWithoutAFinishedSubgoalEndTheSubgoalStuckAndTheModelGoesOn() async throws {
        let steps = Steps()
        let engine = ScriptedEngine(choice: { request in
            let n = steps.next(request.goal)
            return ScriptedEngine.pick(Self.operation(request.goal == "Scroll first" && n == 7 ? .stuck : .scroll, request))
        })
        let model = Self.calling(["Scroll first", "Scroll again"])
        let run = try run(engine, model)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(steps.count("Scroll again"), 1, "the eighth step without progress")
        XCTAssertEqual(lastResults(try subgoalCall(model, 2)).first?["status"] as? String, "stuck",
                       "the model reads the stalled sub-goal stuck, and is asked again")
        XCTAssertEqual(outcome.ending, .notFinished)
        XCTAssertEqual(model.requests("subgoal").count, 5, "two sub-goals, the model's end and two ends rejected")
    }

    /// A hand-over or a ceiling ends the errand, not the sub-goal: the model
    /// is not asked again.
    @MainActor
    func testAHandoverOrACeilingEndsTheErrandNotTheSubgoal() async throws {
        let model = Self.calling(["Show the tips", "Show them again"])
        let grant = ScriptedEngine(choice: { ScriptedEngine.pick(Self.named("Show tips", $0)) }, grant: { _ in 0.2 })
        let handedOver = await (try run(grant, model)).run(report: { _ in })
        XCTAssertEqual(handedOver.ending, .needsUser)
        XCTAssertEqual(model.requests("subgoal").count, 1)

        let capped = Self.calling(["Show the tips", "Show them again"])
        let scroll = ScriptedEngine(choice: { ScriptedEngine.pick(Self.operation(.scroll, $0)) })
        let ceiling = await (try run(scroll, capped, limits: AgentBudget.Limits(steps: 2, activeSeconds: 600,
                                                                                spendMicros: 500_000,
                                                                                expiry: .seconds(1_800))))
            .run(report: { _ in })
        XCTAssertEqual(ceiling.ending, .ceiling)
        XCTAssertEqual(capped.requests("subgoal").count, 1)
    }

    // MARK: - A field's text

    /// Jev picks TYPE_TEXT: the text model writes the field's text from the
    /// user's goal, the field, the page and the last actions, and the agent
    /// types it — never into the record or the log.
    @MainActor
    func testWhenJevTypesTheFieldsTextIsWrittenByTheModelAndTyped() async throws {
        let typed = "SENTINEL-TYPED-7c1d"
        let model = Self.calling(["Search for jokes"], fieldText: [#"{"text": "\#(typed)"}"#])
        let seen = Seen()
        let typedOnce = Asked()
        let engine = ScriptedEngine(choice: { request in
            seen.add(request)
            if typedOnce.count == 0, let field = Self.field(request), field.action.target?.value ?? "" == "" {
                typedOnce.add()
                return ScriptedEngine.pick(field)
            }
            return ScriptedEngine.pick(Self.operation(.done, request))
        })
        let lines = LogLines()
        let bridge = WebViewBridge()
        let run = try run(engine, model, bridge: bridge, lines: lines)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .notFinished)

        let asked = try XCTUnwrap(model.requests("field_text").first)
        XCTAssertEqual(model.requests("field_text").count, 1)
        XCTAssertEqual(asked.contents.first, ModelTexts.fieldText)
        let input = try XCTUnwrap(asked.contents.last ?? nil)
        XCTAssertTrue(input.hasPrefix(#"{"goal": "\#(Self.goal)", "field": {"label": "Search", "role": "searchbox", "value": ""}, "page": {"title": "Search 401", "text": "#),
                      input)
        XCTAssertTrue(input.hasSuffix(#", "recent_actions": []}"#), input)
        // Typed, then sent as its typing ends (D4): the search the page's form builds carries the model's text.
        XCTAssertTrue(bridge.navigatedURLs.contains { $0.path == "/search" && $0.query?.contains(typed) == true },
                      "typed into the field and searched: \(bridge.navigatedURLs)")
        XCTAssertEqual((lastResults(try subgoalCall(model, 1)).first?["actions"] as? [String])?.first, "type into Search")

        let record = String(decoding: try JSONEncoder().encode(run.record), as: UTF8.self)
        XCTAssertFalse(record.contains(typed), "never in the record")
        XCTAssertFalse(lines.all.contains { $0.contains(typed) }, "never in the log")
    }

    /// `{"text": null}`, or no answer, types nothing: the step is a miss.
    @MainActor
    func testAFieldTextOfNullOrNoAnswerTypesNothingAndIsAMiss() async throws {
        let model = Self.calling(["Search for jokes"], fieldText: [#"{"text": null}"#, "jokes"])
        let seen = Seen()
        let engine = ScriptedEngine(choice: { request in
            seen.add(request)
            return ScriptedEngine.pick(seen.count <= 2 ? Self.field(request) : Self.operation(.done, request))
        })
        let run = try run(engine, model)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .notFinished)
        XCTAssertEqual(model.requests("field_text").count, 2)
        XCTAssertEqual(run.record.steps.map(\.outcome), [.reconsidered, .reconsidered])
        let result = lastResults(try subgoalCall(model, 1)).first
        XCTAssertEqual(result?["status"] as? String, "stuck", "two misses in a row")
        XCTAssertEqual(result?["actions"] as? [String], [], "nothing typed")
    }

    // MARK: - D4: a search the agent typed goes without a Yes

    /// The page's own GET search, its one text field typed in this sub-goal:
    /// its button sends it without a Yes.
    @MainActor
    func testASearchTheAgentTypedInThisSubgoalGoesWithoutAYes() async throws {
        let model = Self.calling(["Search for jokes"], fieldText: [#"{"text": "jokes"}"#])
        let engine = ScriptedEngine(choice: { request in
            if request.page.title == "Results 401" { return ScriptedEngine.pick(Self.operation(.done, request)) }
            let field = Self.field(request)
            return ScriptedEngine.pick(field?.action.target?.value ?? "" == "" ? field
                : request.candidates.first { $0.action.target?.name == "Search" && $0.action.operation == .click })
        })
        let asked = Asked()
        let bridge = WebViewBridge()
        let outcome = await (try run(engine, model, bridge: bridge, confirm: { _ in asked.add(); return .no }))
            .run(report: { _ in })
        XCTAssertEqual(outcome.ending, .notFinished)
        XCTAssertEqual(asked.count, 0, "no Yes for the search")
        XCTAssertTrue(bridge.navigatedURLs.contains(URL(string: "https://site-401.test/search?q=jokes")!),
                      "\(bridge.navigatedURLs)")
    }

    /// The start page's own search box, drawn as a textarea that is a combobox
    /// (as the start page draws it), is typed into, and its search goes
    /// without a Yes.
    @MainActor
    func testASearchBoxDrawnAsATextareaIsTypedAndSearchedWithoutAYes() async throws {
        let model = Self.calling(["Search for jokes"], fieldText: [#"{"text": "jokes"}"#])
        let engine = ScriptedEngine(choice: { request in
            if request.page.title == "Results 403" { return ScriptedEngine.pick(Self.operation(.done, request)) }
            let field = Self.field(request)
            return ScriptedEngine.pick(field?.action.target?.value ?? "" == "" ? field
                : request.candidates.first { $0.action.target?.name == "Search 403" })
        })
        let asked = Asked()
        let bridge = WebViewBridge()
        let outcome = await (try run(engine, model, bridge: bridge, start: URL(string: "https://site-403.test/")!,
                                     confirm: { _ in asked.add(); return .no })).run(report: { _ in })
        XCTAssertEqual(outcome.ending, .notFinished)
        XCTAssertEqual(model.requests("field_text").count, 1, "the box was typed into")
        XCTAssertEqual(asked.count, 0, "no Yes for the search")
        XCTAssertTrue(bridge.navigatedURLs.contains { url in
            url.host == "site-403.test" && url.path == "/search"
                && URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
                == "jokes"
        }, "\(bridge.navigatedURLs)")
    }

    /// A box whose page changes what was typed: the typing did not hold, so
    /// the field is not the agent's, and its search asks the user's Yes as
    /// any other form does (ITER-076 stage 2: the field is counted after the
    /// step's window and its check, only when the typing held).
    @MainActor
    func testASearchWhoseTypingDidNotHoldStillAsks() async throws {
        let model = Self.calling(["Search for jokes"], fieldText: [#"{"text": "jokes"}"#])
        let engine = ScriptedEngine(choice: { request in
            let field = Self.field(request)
            return ScriptedEngine.pick(field?.action.target?.value ?? "" == "" ? field
                : request.candidates.first { $0.action.target?.name == "Search" && $0.action.operation == .click }
                  ?? Self.operation(.done, request))
        })
        let asked = Asked()
        let bridge = WebViewBridge()
        _ = await (try run(engine, model, bridge: bridge, start: URL(string: "https://site-410.test/")!,
                           confirm: { _ in asked.add(); return .no })).run(report: { _ in })
        XCTAssertEqual(model.requests("field_text").count, 1, "the premise: the box was typed into")
        XCTAssertEqual(asked.count, 1, "the search is asked about")
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/search" }, "and not sent on a No")
    }

    /// Every other form still asks: a field typed in an earlier sub-goal, and
    /// a form with two text fields.
    @MainActor
    func testEveryOtherFormStillAsks() async throws {
        let click = { (request: ChooseRequest) in
            request.candidates.first { $0.action.target?.name == "Search" && $0.action.operation == .click }
        }
        // A pure search the sub-goal typed is sent as its typing ends, with no Yes (D4, 2026-10-07): what follows
        // are the forms that still ask.
        let earlier = Self.calling(["Type the query"], fieldText: [#"{"text": "jokes"}"#])
        let asked = Asked()
        let bridge = WebViewBridge()
        _ = await (try run(Self.typesOnce(), earlier, bridge: bridge, confirm: { _ in asked.add(); return .no }))
            .run(report: { _ in })
        XCTAssertEqual(asked.count, 0, "a pure search the agent typed is not asked about")
        XCTAssertTrue(bridge.navigatedURLs.contains { $0.path == "/search" }, "it is sent as its typing ends")

        // Two text fields.
        let twoFields = Self.calling(["Search for jokes"], fieldText: [#"{"text": "jokes"}"#])
        let both = Asked()
        let other = ScriptedEngine(choice: { request in
            let field = Self.field(request)
            if field?.action.target?.value ?? "" == "" { return ScriptedEngine.pick(field) }
            return ScriptedEngine.pick(click(request) ?? Self.operation(.done, request))
        })
        _ = await (try run(other, twoFields, start: URL(string: "https://site-402.test/")!,
                           confirm: { _ in both.add(); return .no })).run(report: { _ in })
        XCTAssertEqual(both.count, 1, "a form with two text fields is asked about")
    }

    // MARK: - Honest endings (G5)

    private struct RefusingPlanner: ErrandPlanner {
        let failure: JevDecisionEngine.Failure
        func worstCaseUSD(goal: String) -> Double { 0 }
        func plan(goal: String) async throws -> AgentPlan { throw failure }
    }

    /// What the model's service says about the plan is the errand's end — no
    /// Pro, the day's limit, a service down once waited for — never a failed
    /// plan.
    @MainActor
    func testAPlannersRefusalIsItsOwnEndingNeverAFailedPlan() async throws {
        let cases: [(JevDecisionEngine.Failure, ErrandRecord.Ending, ErrandRecord.Failure?)] = [
            (.noPro, .noPro, nil), (.dailyLimit(retryAfter: .seconds(60)), .dailyLimit, nil),
            (.unavailable(retryAfter: .zero), .unavailable, .engineUnavailable),
            (.timedOut, .unavailable, .engineUnavailable),
        ]
        for (failure, ending, kind) in cases {
            let run = AgentRun(goal: Self.goal, planner: RefusingPlanner(failure: failure), errandID: UUID(),
                               collaborators: .init(bridge: WebViewBridge(),
                                                    engine: ScriptedEngine(choice: { _ in ScriptedEngine.pick(nil) }),
                                                    writer: FakeWriter(), sheet: FixtureSheet(), confirm: { _ in nil }))
            let outcome = await run.run(report: { _ in })
            XCTAssertEqual(outcome.ending, ending, "\(failure)")
            XCTAssertEqual(outcome.failure, kind, "\(failure)")
        }
    }

    /// Every call of the text model ends the errand honestly: 401 no Pro, 429
    /// the day's limit, 503 or a timeout one wait and then unavailable.
    @MainActor
    func testTheTextModelsRefusalsEndTheErrandHonestly() async throws {
        let cases: [(String, Int, ErrandRecord.Ending, ErrandRecord.Failure?)] = [
            ("plan", 401, .noPro, nil), ("plan", 429, .dailyLimit, nil), ("plan", 503, .unavailable, .engineUnavailable),
            ("subgoal", 401, .noPro, nil), ("subgoal", 429, .dailyLimit, nil),
            ("subgoal", 503, .unavailable, .engineUnavailable), ("subgoal", 504, .unavailable, .engineUnavailable),
            ("field_text", 401, .noPro, nil), ("field_text", 429, .dailyLimit, nil),
            ("field_text", 503, .unavailable, .engineUnavailable),
        ]
        for (purpose, status, ending, failure) in cases {
            let model = RecordedModel { asked, n in
                if asked.purpose == purpose { return .status(status, retryAfter: status == 429 ? "3600" : "0") }
                switch asked.purpose {
                case "plan": return .text(RecordedModel.plan([("r1", "Find 10 jokes", "information")]))
                case "subgoal": return n == 0 ? .calls([RecordedModel.goal("Search for jokes")]) : .text("Done.")
                default: return .text(#"{"text": "jokes"}"#)
                }
            }
            let engine = ScriptedEngine(choice: { request in
                ScriptedEngine.pick(Self.field(request)?.action.target?.value ?? "" == "" ? Self.field(request)
                                                                                         : Self.operation(.done, request))
            })
            let outcome = await (try run(engine, model, planner: model.planner)).run(report: { _ in })
            let what = "\(purpose) \(status)"
            XCTAssertEqual(outcome.ending, ending, what)
            XCTAssertEqual(outcome.failure, failure, what)
            XCTAssertEqual(model.requests(purpose).count, [503, 504].contains(status) ? 2 : 1,
                           "\(what): one wait at most")
            if status == 429 { XCTAssertNotNil(outcome.retryAt, what) }
        }
    }

    /// ITER-076 stage 9d, № 27 — the owner's switch on the text model's
    /// route ends the errand stopped at once, whichever call heard it: one
    /// call, no wait and no second try, no failure; the service hears it.
    @MainActor
    func testTheOwnersSwitchOnTheTextModelEndsTheErrandStoppedAtOnce() async throws {
        for purpose in ["plan", "subgoal"] {
            let model = RecordedModel { asked, n in
                if asked.purpose == purpose { return .switchedOff }
                switch asked.purpose {
                case "plan": return .text(RecordedModel.plan([("r1", "Find 10 jokes", "information")]))
                default: return n == 0 ? .calls([RecordedModel.goal("Search for jokes")]) : .text("Done.")
                }
            }
            let heard = Counter()
            let run = try run(Self.done, model, planner: model.planner, switchedOff: { heard.add() })
            let outcome = await run.run(report: { _ in })
            XCTAssertEqual(outcome.ending, .stopped, purpose)
            XCTAssertNil(outcome.failure, purpose)
            XCTAssertEqual(model.requests(purpose).count, 1, "\(purpose): no wait, no second try")
            XCTAssertEqual(heard.value, 1, "\(purpose): the service hears it")
        }
    }

    /// A plan answer that fails the schema or the checks ends the errand as
    /// planFailed after one call, before any page.
    @MainActor
    func testAnInvalidPlanEndsAsPlanFailedAfterOneCall() async throws {
        let model = RecordedModel { _, _ in
            .text(RecordedModel.plan([("r1", "Find jokes", "information"), ("r1", "Open one", "action")]))
        }
        let bridge = WebViewBridge()
        let run = try run(ScriptedEngine(choice: { ScriptedEngine.pick(Self.operation(.done, $0)) }), model,
                          planner: model.planner, bridge: bridge)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .failed)
        XCTAssertEqual(outcome.failure, .planFailed)
        XCTAssertEqual(model.requests.count, 1, "no repair call")
        XCTAssertTrue(bridge.openedURLs.isEmpty)
    }

    // MARK: - Stop

    /// Stop while the text model is asked — for a sub-goal, or for a field's
    /// text — ends the errand within Stop's limit: no step after it, nothing
    /// typed, and the call on record as stopped.
    @MainActor
    func testStopWhileTheTextModelIsAskedEndsTheErrandAndTypesNothing() async throws {
        for purpose in ["subgoal", "field_text"] {
            let box = Box<AgentRun>()
            let model = RecordedModel { asked, n in
                let stops = asked.purpose == purpose && (purpose == "field_text" || n == 1)
                if stops { Task { @MainActor in box.value?.stop() } }
                let reply: RecordedModel.Reply = asked.purpose == "subgoal"
                    ? (n == 0 ? .calls([RecordedModel.goal("Search for jokes")]) : .text("Done."))
                    : .text(#"{"text": "jokes"}"#)
                return stops ? .after(.seconds(5), reply) : reply
            }
            let seen = Seen()
            let engine = ScriptedEngine(choice: { request in
                seen.add(request)
                let field = Self.field(request)
                return ScriptedEngine.pick(field?.action.target?.value ?? "" == "" ? field : Self.operation(.done, request))
            })
            let run = try run(engine, model)
            box.value = run
            let clock = ContinuousClock()
            let started = clock.now
            let outcome = await run.run(report: { _ in })
            XCTAssertEqual(outcome.ending, .stopped, purpose)
            XCTAssertLessThan(clock.now - started, .seconds(4), "\(purpose): Stop's limit, not the model's 5 s")
            XCTAssertTrue(run.record.events.map(\.shape).contains("model \(purpose) stopped"), purpose)
            if purpose == "field_text" {
                XCTAssertEqual(seen.count, 1, "no step after Stop")
                XCTAssertEqual(run.record.steps.count, 0, "nothing typed")
            } else {
                XCTAssertEqual(model.requests("subgoal").count, 2)
            }
        }
    }

    // MARK: - On record by numbers only

    /// Each call of the text model is on record, and in the log, by its
    /// purpose, how it went, its time and its cost — never the goal, a
    /// sub-goal or a field's text.
    @MainActor
    func testEachModelCallIsOnRecordByNumbersOnly() async throws {
        let model = RecordedModel { asked, n in
            switch asked.purpose {
            case "plan": return .text(RecordedModel.plan([("r1", "Find 10 jokes", "information")]))
            case "subgoal": return n == 0 ? .calls([RecordedModel.goal("SENTINEL-SUBGOAL-4e2b")]) : .text("Done.")
            // Step 2: the page the sub-goal left is read.
            case "read": return .text(RecordedModel.reading([]))
            default: return .text(#"{"text": "SENTINEL-TYPED-91fa"}"#)
            }
        }
        let engine = Self.typesOnce()
        let lines = LogLines()
        let run = try run(engine, model, planner: model.planner, lines: lines)
        _ = await run.run(report: { _ in })
        let shapes = run.record.events.map(\.shape)
        XCTAssertEqual(shapes.filter { $0.hasPrefix("plan") || $0.hasPrefix("model") },
                       ["plan ok", "model subgoal ok", "model field_text ok", "model read ok", "model subgoal ok",
                        "model subgoal ok", "model subgoal ok"])
        for event in run.record.events {
            guard case .model(_, _, let milliseconds, let cost) = event else { continue }
            XCTAssertGreaterThanOrEqual(milliseconds, 0)
            XCTAssertEqual(cost, 0.0002, accuracy: 1e-9, "the call's own cost")
        }
        for secret in [Self.goal, "SENTINEL-SUBGOAL-4e2b", "SENTINEL-TYPED-91fa", "Find 10 jokes"] {
            XCTAssertFalse(run.record.eventLines.contains { $0.contains(secret) }, secret)
            XCTAssertFalse(lines.all.contains { $0.contains(secret) }, secret)
        }
    }

    /// ITER-076 stage 4a: a step Jev chose keeps, on record and in the log,
    /// Jev's own confidences — the operation's and its target's — and how
    /// many targets its operation was offered; a step Jev said nothing of
    /// keeps none.
    @MainActor
    func testAStepKeepsJevsOwnConfidencesAndTheTargetsOffered() async throws {
        let model = Self.calling(["Show the tips"])
        let engine = ScriptedEngine(choice: { request in
            guard let show = Self.named("Show tips", request) else { return ScriptedEngine.pick(Self.operation(.done, request)) }
            return ChooseAnswer(candidateID: show.id, confidence: 0.9, goalMet: 0, stuck: nil,
                                usage: EngineUsage(costUSD: 0.0005), operationConfidence: 0.97, targetConfidence: 0.9,
                                targets: 7)
        })
        let lines = LogLines()
        let run = try run(engine, model, lines: lines)
        _ = await run.run(report: { _ in })
        let steps = run.record.steps
        XCTAssertEqual(steps.map(\.operation), ["click", "done"])
        XCTAssertEqual(steps.first?.operationConfidence, 0.97)
        XCTAssertEqual(steps.first?.targetConfidence, 0.9)
        XCTAssertEqual(steps.first?.targets, 7)
        XCTAssertNil(steps.last?.operationConfidence)
        XCTAssertNil(steps.last?.targets)
        XCTAssertTrue(lines.all.contains { $0.contains(" step op=click ") && $0.contains(" opConfidence=0.97 targetConfidence=0.9 targets=7 ") },
                      "\(lines.all)")
    }

    // MARK: - Reading the page and the answer (step 2)

    private static let jokes = URL(string: "https://site-404.test/")!
    /// The ten jokes the page `jokes` lists, in order.
    private static let jokeLines = [
        "Joke 1: The calendar felt nervous because its days were numbered.",
        "Joke 2: The bicycle fell over because it was two tired.",
        "Joke 3: The scarecrow won an award for being outstanding in his field.",
        "Joke 4: The math book looked sad because it had too many problems.",
        "Joke 5: The skeleton skipped the party because it had no body to go with.",
        "Joke 6: The coffee filed a police report because it got mugged.",
        "Joke 7: The tomato turned red because it saw the salad dressing.",
        "Joke 8: The golfer wore two pairs of pants in case he got a hole in one.",
        "Joke 9: The pencil stayed home because it was pointless.",
        "Joke 10: The ocean said nothing to the shore and simply waved.",
    ]

    /// A plan to find 10 jokes, and `more` beside it.
    private static func reads(_ more: [AgentPlan.Requirement] = []) throws -> FixedPlanner {
        FixedPlanner(plan: try XCTUnwrap(AgentPlan(goal: goal, requirements: [.init(id: "r1", text: "Find 10 jokes",
                                                                                      kind: .information)] + more,
                                                   answerExpected: true)))
    }

    /// The model: each sub-goal call answers from `subgoals` — past the list,
    /// a reply without one — each read from `read` and each verdict from
    /// `verify`, by its number from 0.
    private static func reading(_ subgoals: [String],
                                verify: @escaping @Sendable (RecordedModel.Asked, Int) -> RecordedModel.Reply
                                    = { _, _ in .status(400) },
                                read: @escaping @Sendable (RecordedModel.Asked, Int) -> RecordedModel.Reply)
        -> RecordedModel {
        RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return n < subgoals.count ? .calls([RecordedModel.goal(subgoals[n])]) : .text("Done.")
            case "read": return read(asked, n)
            case "verify": return verify(asked, n)
            default: return .status(400)
            }
        }
    }


    private static var done: ScriptedEngine {
        ScriptedEngine(choice: { ScriptedEngine.pick(Self.operation(.done, $0)) })
    }

    /// The lines of the blocks a read shows, each `[label] (kind) words`.
    private static func blockLines(_ asked: RecordedModel.Asked) -> [String] {
        guard let content = asked.contents.last ?? nil, let start = content.range(of: "# Source blocks ("),
              let end = content.range(of: "\n\n# Question\n") else { return [] }
        return content[start.lowerBound..<end.lowerBound].split(separator: "\n").dropFirst().map(String.init)
    }

    /// After a sub-goal, the page is read: text 5, then the page's lines as
    /// the observer reads them for the writer, each block a line with its
    /// label and kind. The quotes are the page's own words, copied by code
    /// from the blocks the reader cites; they are the facts, in the record as
    /// they come, and the answer is each with its page's link. The verifier,
    /// asked once r1 has its claim and again when the model stops, says done
    /// the second time (stage 1).
    @MainActor
    func testAfterASubgoalThePageIsReadAndItsFactsAreTheAnswer() async throws {
        let model = Self.reading(["Read the jokes"], verify: { _, n in RecordedModel.verdict(complete: n == 1) }) { _, _ in
            .text(RecordedModel.reading((0..<10).map {
                RecordedModel.claim(cite: ("main/:\($0 + 2)", "main/:\($0 + 2)"), text: "MODEL-WORDS-\($0)")
            } + [RecordedModel.claim(cite: nil, drawsOn: (0..<10).map { "claim:\($0)" }, text: "MODEL-WORDS-ALL",
                                     requirement: "r1")], answered: true))
        }
        let run = try run(Self.done, model, planner: Self.reads(), start: Self.jokes)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done)

        XCTAssertEqual(model.requests("read").count, 1)
        let asked = try XCTUnwrap(model.requests("read").first)
        XCTAssertEqual(asked.contents.first, ModelTexts.reader)
        XCTAssertEqual(Self.blockLines(asked), ["[main/:1] (heading) Ten jokes"]
            + Self.jokeLines.enumerated().map { "[main/:\($0.offset + 2)] (list_item) \($0.element)" }
            + ["[main/:12] (paragraph) Knock knock.", "[main/:13] (paragraph) Who is there?",
               "[main/:14] (paragraph) By Sam the joke keeper", "[main/:15] (paragraph) More jokes"])
        let content = try XCTUnwrap(asked.contents.last ?? nil)
        XCTAssertTrue(content.hasPrefix("# Collected evidence\n\n\n# Capture\nURL: https://site-404.test/\nInaccessible frames: 0\n\n# Source blocks (chunk 1 of 1)\n"),
                      content)
        XCTAssertTrue(content.hasSuffix("\n# Question\n\(Self.goal)\n\nRequirements still to evidence:\n- Find 10 jokes\n\n# Requirement ids\nr1"),
                      content)

        XCTAssertEqual(run.record.facts, Self.jokeLines.enumerated().map {
            .init(requirements: ["r1"], quote: $0.element, source: "main/:\($0.offset + 2)", url: "https://site-404.test/")
        })
        // 2026-10-15: the reader's claim for r1 in its words, then the page's own words of each joke beneath it.
        XCTAssertEqual(outcome.answer, (["MODEL-WORDS-ALL\nhttps://site-404.test/"]
            + Self.jokeLines.map { $0 + "\nhttps://site-404.test/" }).joined(separator: "\n\n"))
        XCTAssertEqual(outcome.sources, [Self.jokes])
        XCTAssertEqual(lastResults(try subgoalCall(model, 1)).first?["still_to_find"] as? [String], ["Find 10 jokes"],
                       "the verifier's first verdict said not complete: r1 is still to find")
        let facts = String(decoding: try JSONEncoder().encode(run.record.facts), as: UTF8.self)
        XCTAssertFalse(facts.contains("MODEL-WORDS"), "the model's words are in no fact")
        XCTAssertEqual(run.record.statements.last?.text, "MODEL-WORDS-ALL", "they are its statements")
        XCTAssertEqual(run.record.events.map(\.shape).filter { $0.hasPrefix("model") },
                       ["model subgoal ok", "model read ok", "model verify ok", "model subgoal ok", "model verify ok"])
    }

    /// What the reader gave is said in the log in numbers and the chunk's own
    /// line labels alone — its claims, those citing a line it was not shown, those
    /// answering no requirement asked, the facts before and after, and those
    /// answering one (bench of 2026-10-06: two reads of 77 and 15 lines kept
    /// nothing, and only these numbers told why). Never a claim's words or a
    /// page's text.
    @MainActor
    func testWhatTheReaderGaveIsSaidInTheLogInNumbers() async throws {
        let model = Self.reading(["Read the jokes"], verify: { _, n in RecordedModel.verdict(complete: n == 1) }) { _, _ in
            .text(RecordedModel.reading([RecordedModel.claim(cite: ("MODEL-WORDS-IN-A-CITE", "main/:99"),
                                                             text: "MODEL-WORDS-UNSHOWN")] + (0..<10).map {
                RecordedModel.claim(cite: ("main/:\($0 + 2)", "main/:\($0 + 2)"), text: "MODEL-WORDS-\($0)")
            } + [RecordedModel.claim(cite: nil, drawsOn: (1...10).map { "claim:\($0)" }, text: "MODEL-WORDS-ALL",
                                     requirement: "r1")], answered: true))
        }
        let lines = LogLines()
        let run = try run(Self.done, model, planner: Self.reads(), start: Self.jokes, lines: lines)
        _ = await run.run(report: { _ in })

        let said = lines.lines(of: run.record.errandID).filter { $0.hasPrefix("read chunk") }
        XCTAssertFalse(lines.all.contains { $0.contains("MODEL-WORDS") }, "no claim's words, not even in a citation")
        XCTAssertEqual(said, ["read chunk 1/1: claims=12 unplaced=1 noRequirement=11 facts 0→10 answering=10 "
                              + "labels=main/:1…main/:15"])
        XCTAssertFalse(lines.all.contains { line in Self.jokeLines.contains { line.contains($0) } }, "no page text")
    }

    /// A page is read again only when its text is new and a fact is still to
    /// find.
    @MainActor
    func testAPageIsReadOnlyWhenItsTextIsNewAndAFactIsStillToFind() async throws {
        let showsMore = { (steps: Steps) in
            ScriptedEngine(choice: { request in
                let more = request.goal.hasPrefix("Show more") && steps.next(request.goal) == 0
                return ScriptedEngine.pick(more ? Self.named("More jokes", request) : Self.operation(.done, request))
            })
        }
        // A text whose reads added nothing is read at most twice (2026-10-15, `barrenReads`).
        let same = Self.reading(["Read the jokes", "Read them again", "And again"]) { _, _ in .text(RecordedModel.reading([])) }
        _ = await (try run(showsMore(Steps()), same, planner: Self.reads(), start: Self.jokes)).run(report: { _ in })
        XCTAssertEqual(same.requests("read").count, 2, "a text whose reads added nothing is read at most twice")

        let open = Self.reading(["Read the jokes", "Show more jokes"]) { _, _ in .text(RecordedModel.reading([])) }
        _ = await (try run(showsMore(Steps()), open, planner: Self.reads(), start: Self.jokes)).run(report: { _ in })
        XCTAssertEqual(open.requests("read").count, 2, "new text, a fact still to find: read")
        XCTAssertTrue(Self.blockLines(try XCTUnwrap(open.requests("read").last))
            .contains("[main/:12] (list_item) Extra joke 1: the page changed."))

        let found = Self.reading(["Read the jokes", "Show more jokes"]) { _, _ in
            .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:11"), requirement: "r1")]))
        }
        let run = try run(showsMore(Steps()), found, planner: Self.reads(), start: Self.jokes)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(found.requests("read").count, 1, "nothing still to find: no read")
        XCTAssertEqual(run.record.facts.map(\.quote), [Self.jokeLines.joined(separator: "\n")])
    }

    /// A page longer than one call is read in chunks of at most 12,000
    /// characters, every line once, in order.
    @MainActor
    func testALongPageIsReadInChunksOfAtMost12000Characters() async throws {
        let model = Self.reading(["Read the page"]) { _, _ in .text(RecordedModel.reading([])) }
        let outcome = await (try run(Self.done, model, planner: Self.reads(), start: URL(string: "https://site-406.test/")!))
            .run(report: { _ in })
        XCTAssertEqual(outcome.ending, .notFinished)
        let reads = model.requests("read")
        XCTAssertEqual(reads.count, 3)
        var labels: [String] = []
        for (index, asked) in reads.enumerated() {
            let content = try XCTUnwrap(asked.contents.last ?? nil)
            XCTAssertTrue(content.contains("\n# Source blocks (chunk \(index + 1) of 3)\n"), String(content.prefix(300)))
            let lines = Self.blockLines(asked)
            let text = lines.map { $0.components(separatedBy: ") ").dropFirst().joined(separator: ") ") }
                .joined(separator: "\n")
            XCTAssertLessThanOrEqual(text.count, 12_000)
            labels += lines.map { String($0.prefix { $0 != " " }) }
        }
        XCTAssertEqual(labels, (1...102).map { "[main/:\($0)]" }, "every line once, in order")
    }

    /// A long page is read no further once nothing is still to find.
    @MainActor
    func testALongPageIsReadNoFurtherOnceNothingIsStillToFind() async throws {
        let model = Self.reading(["Read the page"]) { _, _ in
            .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:2"), requirement: "r1")]))
        }
        let run = try run(Self.done, model, planner: Self.reads(), start: URL(string: "https://site-406.test/")!)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(model.requests("read").count, 1, "the first of three chunks answered it")
        XCTAssertEqual(run.record.facts.map(\.source), ["main/:2"])
    }

    /// A read may cite only the lines it was shown: a line another chunk of
    /// the page showed is not one of them, and its claim is dropped.
    @MainActor
    func testACiteToALineAnotherReadShowedIsDropped() async throws {
        let model = Self.reading(["Read the page"]) { _, n in
            switch n {
            case 1: return .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:2"), requirement: "r1")]))
            case 2: return .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:102", "main/:102"),
                                                                            requirement: "r1")]))
            default: return .text(RecordedModel.reading([]))
            }
        }
        let run = try run(Self.done, model, planner: Self.reads(), start: URL(string: "https://site-406.test/")!)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(model.requests("read").count, 3, "the second read's cite was dropped: the third is read")
        XCTAssertEqual(run.record.facts, [.init(requirements: ["r1"], quote: "More", source: "main/:102",
                                                url: "https://site-406.test/")])
    }

    /// At most 16 reads an errand: five pages of three calls, then one; then
    /// none.
    @MainActor
    func testAtMostSixteenReadsAnErrand() async throws {
        let model = Self.reading((1...7).map { "Show more \($0)" }) { _, _ in .text(RecordedModel.reading([])) }
        let steps = Steps()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(steps.next(request.goal) == 0 ? Self.named("More", request) : Self.operation(.done, request))
        })
        let outcome = await (try run(engine, model, planner: Self.reads(), start: URL(string: "https://site-406.test/")!))
            .run(report: { _ in })
        XCTAssertEqual(outcome.ending, .notFinished)
        XCTAssertEqual(model.requests("subgoal").count, 10, "seven sub-goals, the model's end and two ends rejected")
        XCTAssertEqual(model.requests("read").count, 16)
        XCTAssertEqual(AgentRun.maxReads, 16)
    }

    /// The reader is never sent a field's value — a password's, a card's, any
    /// other — nor what someone wrote, nor text drawn as dots: the observer's
    /// rules for the writer's excerpt hold for its lines.
    @MainActor
    func testTheReaderIsNeverSentAFieldsValueSomeonesWritingOrTextDrawnAsDots() async throws {
        let model = Self.reading(["Read the page"]) { _, _ in .text(RecordedModel.reading([])) }
        let outcome = await (try run(Self.done, model, planner: Self.reads(), start: URL(string: "https://site-405.test/")!))
            .run(report: { _ in })
        XCTAssertEqual(outcome.ending, .notFinished)
        let index = try XCTUnwrap(model.requests.firstIndex { $0.purpose == "read" })
        let sent = String(decoding: model.bodies[index], as: UTF8.self)
        for kept in ["PASS-SECRET-4051", "TYPED-VALUE-4052", "4111 1111 1111 1111", "4111111111111111",
                     "WRITTEN-NOTE-4053", "DOTS-SECRET-4054", "EDITED-TEXT-4055"] {
            XCTAssertFalse(sent.contains(kept), kept)
        }
        for shown in ["PUBLIC-WORDS-4050", "PUBLIC-WORDS-4056"] { XCTAssertTrue(sent.contains(shown), shown) }
    }

    /// Stop while the reader is asked: the errand ends within Stop's limit
    /// with the facts found before — none from the call Stop cut — and they
    /// are its answer.
    @MainActor
    func testFactsFoundBeforeStopAreKeptAndAreTheAnswer() async throws {
        let box = Box<AgentRun>()
        let model = Self.reading(["Read the jokes", "Show more jokes"]) { _, n in
            guard n == 1 else {
                return .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:2"), requirement: "r1")]))
            }
            Task { @MainActor in box.value?.stop() }
            return .after(.seconds(5), .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:3", "main/:3"),
                                                                                         requirement: "r3")])))
        }
        let steps = Steps()
        let engine = ScriptedEngine(choice: { request in
            let more = request.goal == "Show more jokes" && steps.next(request.goal) == 0
            return ScriptedEngine.pick(more ? Self.named("More jokes", request) : Self.operation(.done, request))
        })
        let run = try run(engine, model, planner: Self.reads([.init(id: "r3", text: "Find who keeps the jokes",
                                                                    kind: .information)]), start: Self.jokes)
        box.value = run
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertLessThan(clock.now - started, .seconds(4), "Stop's limit, not the reader's 5 s")
        XCTAssertEqual(run.record.facts, [.init(requirements: ["r1"], quote: Self.jokeLines[0], source: "main/:2",
                                                url: "https://site-404.test/")], "kept as it came; none after Stop")
        XCTAssertEqual(outcome.answer, Self.jokeLines[0] + "\nhttps://site-404.test/")
        XCTAssertEqual(outcome.sources, [Self.jokes])
        XCTAssertTrue(run.record.events.map(\.shape).contains("model read stopped"))
    }

    /// The reader's service refusing ends the errand honestly: no Pro, the
    /// day's limit, a service down once waited for.
    @MainActor
    func testTheReadersRefusalsEndTheErrandHonestly() async throws {
        let cases: [(Int, ErrandRecord.Ending, ErrandRecord.Failure?, Int)] = [
            (401, .noPro, nil, 1), (429, .dailyLimit, nil, 1), (503, .unavailable, .engineUnavailable, 2),
        ]
        for (status, ending, failure, asked) in cases {
            let model = Self.reading(["Read the jokes"]) { _, _ in .status(status, retryAfter: status == 429 ? "3600" : "0") }
            let outcome = await (try run(Self.done, model, planner: Self.reads(), start: Self.jokes)).run(report: { _ in })
            XCTAssertEqual(outcome.ending, ending, "\(status)")
            XCTAssertEqual(outcome.failure, failure, "\(status)")
            XCTAssertEqual(model.requests("read").count, asked, "\(status): one wait at most")
        }
    }

    /// The reads of a run as its record keeps them.
    @MainActor
    private static func reads(of run: AgentRun) -> [ErrandRecord.Event.Read] {
        run.record.events.compactMap { if case .read(let read) = $0 { read } else { nil } }
    }

    /// ITER-076 stage 4a (F3): every read of the page a sub-goal left is on
    /// record by the guard that ended it — nothing left to find, the reads
    /// spent, a script that failed, no line, a text read before — or as read,
    /// with how many lines the page gave and what its walk met.
    @MainActor
    func testEveryReadIsOnRecordByWhatEndedItAndWhatItsWalkMet() async throws {
        let none = Self.reading(["Read the page"]) { _, _ in .text(RecordedModel.reading([])) }
        let unseen = try run(Self.done, none, planner: Self.reads(), start: URL(string: "https://site-430.test/")!)
        _ = await unseen.run(report: { _ in })
        XCTAssertEqual(none.requests("read").count, 0, "no line: the reader is not asked")
        let empty = try XCTUnwrap(Self.reads(of: unseen).first)
        XCTAssertEqual(Self.reads(of: unseen).map(\.end), [.noLines])
        XCTAssertEqual(empty.blocks, 0)
        XCTAssertEqual(empty.walk?.root, .body, "its one main part kept no word: the body was read (stage 4c)")
        XCTAssertEqual(empty.walk?.met, 5)
        XCTAssertEqual(empty.walk?.kept, 0)
        XCTAssertEqual(empty.walk?.dropped, [.unseen: 3, .hidden: 1, .writing: 1])

        let twice = Self.reading(["Read the jokes", "Read them again", "And again"]) { _, _ in .text(RecordedModel.reading([])) }
        let again = try run(Self.done, twice, planner: Self.reads(), start: Self.jokes)
        _ = await again.run(report: { _ in })
        XCTAssertEqual(Self.reads(of: again).map(\.end), [.read, .read, .readBefore], "a barren read twice, then not")
        XCTAssertEqual(Self.reads(of: again).map(\.blocks), [15, 15, 15])
        XCTAssertEqual(Self.reads(of: again).first?.walk?.kept, 17)

        let tips = FixedPlanner(plan: try XCTUnwrap(AgentPlan(goal: Self.goal, requirements: [
            .init(id: "r2", text: "Open the tips", kind: .action)], answerExpected: false)))
        let actions = try run(Self.done, Self.calling(["Show the tips"]), planner: tips)
        _ = await actions.run(report: { _ in })
        XCTAssertEqual(Self.reads(of: actions).map(\.end), [.nothingToFind])
        XCTAssertNil(Self.reads(of: actions).first?.walk)

        let failing = FailsTheLines()
        let broken = try run(Self.done, Self.reading(["Read the jokes"]) { _, _ in .text(RecordedModel.reading([])) },
                             planner: Self.reads(), bridge: failing, start: Self.jokes)
        _ = await broken.run(report: { _ in })
        XCTAssertEqual(Self.reads(of: broken).map(\.end), [.failed])
        let shapes = broken.record.events.map(\.shape)
        XCTAssertEqual(shapes.firstIndex(of: "miss read").map { $0 + 1 }, shapes.firstIndex(of: "read failed"),
                       "the page miss says how, right before")

        let more = Self.reading((1...7).map { "Show more \($0)" }) { _, _ in .text(RecordedModel.reading([])) }
        let steps = Steps()
        let spender = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(steps.next(request.goal) == 0 ? Self.named("More", request) : Self.operation(.done, request))
        })
        let spent = try run(spender, more, planner: Self.reads(), start: URL(string: "https://site-406.test/")!)
        _ = await spent.run(report: { _ in })
        XCTAssertEqual(more.requests("read").count, 16, "the premise: the reads are spent")
        XCTAssertEqual(Self.reads(of: spent).last?.end, .readsSpent)
    }

    /// The fixture browser, failing every read of the page's lines.
    @MainActor
    private final class FailsTheLines: BrowserBridge {
        let inner = WebViewBridge()

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            guard javascript == ObserverScript.blocksSource(limit: ErrandModel.chunkLimit * AgentRun.maxReads) else {
                return try await inner.run(javascript, in: tab)
            }
            throw BrowserBridgeError.scriptFailed(code: -3)
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    // MARK: - Evidence across pages, "done?" and not finished (stage 1)

    private static let sixJokes = URL(string: "https://site-408.test/")!
    private static let fourJokes = URL(string: "https://site-409.test/")!
    /// Jev on the two pages: the first sub-goal is done where it starts; the
    /// next one follows the link to the second page, and is done there.
    private static var followsToTheSecondPage: ScriptedEngine {
        ScriptedEngine(choice: { request in
            guard request.goal == "Open the next page of jokes", request.page.url == sixJokes.absoluteString else {
                return ScriptedEngine.pick(Self.operation(.done, request))
            }
            return ScriptedEngine.pick(Self.named("Four more jokes", request))
        })
    }

    /// 2026-10-15 (the bench: "the cheapest book in Mystery", "J.K. Rowling's quotes across the whole site" — the
    /// reader concluded, or gave up, on the first page; a reference browser agent's Lists over several pages and
    /// `_follow_pages`, MIT): the first read says the list goes on past its page, names the control that shows the
    /// rest and gives the page's records. The model hears the requirement still to find with the reader's word and
    /// the control; the next sub-goal's first step is that control, taken without asking Jev; the second page's
    /// read concludes on all the records, and the verifier is asked only then.
    @MainActor
    func testAListTheReaderSawGoOnIsFollowedByTheControlItNamed() async throws {
        let model = Self.reading(["Read the jokes here", "Show the rest of the list"],
                                 verify: { _, _ in RecordedModel.verdict(complete: true) }) { asked, _ in
            let content = asked.contents.last.flatMap { $0 } ?? ""
            if content.contains("URL: https://site-408.test/") {
                let records = (2...7).map { ["first": "main/:\($0)", "last": "main/:\($0)"] }
                let reply: [String: Any] = ["claims": [], "answered": false,
                                            "continues": [["requirement_id": "r1", "expands": "Four more jokes",
                                                           "records": records]]]
                return .text(String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
            }
            return .text(RecordedModel.reading([RecordedModel.claim(cite: nil, drawsOn: (1...6).map(String.init),
                                                                    records: (2...5).map { ("main/:\($0)", "main/:\($0)") },
                                                                    text: "Ten jokes.", requirement: "r1")],
                                               answered: true))
        }
        let seen = Seen()
        let engine = ScriptedEngine(choice: { request in
            seen.add(request)
            return ScriptedEngine.pick(Self.operation(.done, request))
        })
        let run = try run(engine, model, planner: Self.reads(), start: Self.sixJokes)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(lastResults(try subgoalCall(model, 1)).first?["still_to_find"] as? [String],
                       ["Find 10 jokes (the reader saw the list this ranges over go on past what the page shows: load "
                        + "the rest first: \"Four more jokes\")"])
        XCTAssertEqual(model.requests("verify").count, 1, "asked only once the list was read whole")
        XCTAssertFalse(seen.all.contains { $0.goal == "Show the rest of the list" && $0.page.url == Self.sixJokes.absoluteString },
                       "Jev was not asked on the first page: the control the reader named was taken")
        XCTAssertTrue(run.record.steps.contains { $0.operation == "open" && $0.outcome == .acted }, "\(run.record.eventLines)")
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(run.record.facts.filter { $0.requirements == ["r1"] }.count, 10, "six records, then four")
    }

    /// A result that loads for six seconds after Start, past the look's own wait on its loading indicator; Jev,
    /// shown "Loading...", is unsure and would leave by a link. A page still loading is not unclear: it is waited
    /// on once more and looked at again, and the result is read where it appears — the unsure pick is not tried
    /// (a reference browser agent's `_outwait` of a page still rendering, MIT). Tried, it left the page before the
    /// text came (practice.expandtesting dynamic loading, 2026-10-16).
    @MainActor
    func testAnUnsurePickOnAPageStillLoadingWaitsForItInstead() async throws {
        let model = Self.reading(["Start the example and read the text"],
                                 verify: { _, _ in RecordedModel.verdict(complete: true) }) { asked, _ in
            let content = asked.contents.last.flatMap { $0 } ?? ""
            guard content.contains("Hello World!") else { return .text(RecordedModel.reading([])) }
            let line = content.components(separatedBy: "\n").first { $0.contains("Hello World!") } ?? ""
            let label = String(line.dropFirst().prefix { $0 != "]" })
            return .text(RecordedModel.reading([RecordedModel.claim(cite: (label, label), text: "Hello World!",
                                                                    requirement: "r1")], answered: true))
        }
        let engine = ScriptedEngine(choice: { request in
            if let start = Self.named("Start", request) { return ScriptedEngine.pick(start) }
            if request.page.text.contains("Hello World!") { return ScriptedEngine.pick(Self.operation(.done, request)) }
            return ScriptedEngine.pick(Self.named("Elsewhere", request), confidence: 0.3)
        })
        let run = try run(engine, model, planner: Self.reads(), start: URL(string: "https://site-479.test/")!)
        let outcome = await run.run(report: { _ in })
        XCTAssertFalse(run.record.steps.contains { $0.operation == "open" && $0.outcome == .acted },
                       "never left: \(run.record.eventLines)")
        XCTAssertTrue(run.record.steps.contains { $0.operation == "open" && $0.outcome == .reconsidered },
                      "the unsure pick was waited out: \(run.record.eventLines)")
        XCTAssertEqual(outcome.ending, .done, "\(run.record.eventLines)")
        XCTAssertTrue(run.record.facts.contains { $0.quote.contains("Hello World!") }, "\(run.record.eventLines)")
    }

    /// The wait has an end: a loading indicator that never goes is waited on once, up to `loadingOutwait`, and
    /// then Jev's unsure pick is tried as on any page — the errand never waits on a page for ever.
    @MainActor
    func testAnUnsurePickOnAPageLoadingForEverIsTriedOnceItWasWaitedOn() async throws {
        let model = Self.reading(["Start the example and read the text"]) { _, _ in .text(RecordedModel.reading([])) }
        let engine = ScriptedEngine(choice: { request in
            if let start = Self.named("Start", request) { return ScriptedEngine.pick(start) }
            guard let elsewhere = Self.named("Elsewhere", request) else {
                return ScriptedEngine.pick(Self.operation(.stuck, request))
            }
            return ScriptedEngine.pick(elsewhere, confidence: 0.3)
        })
        let run = try run(engine, model, planner: Self.reads(), start: URL(string: "https://site-479.test/forever")!)
        _ = await run.run(report: { _ in })
        let opens = run.record.steps.filter { $0.operation == "open" }.map(\.outcome)
        XCTAssertEqual(Array(opens.prefix(2)), [.reconsidered, .acted], "waited once, then tried: \(run.record.eventLines)")
    }

    /// The wait on a page still loading ends with the errand's time: begun with a little of it left, it is no
    /// longer than what is left, and the errand ends at its ceiling — never `loadingOutwait` past it (Codex review
    /// of 2026-10-18, P1-3). Waited whole, it ran up to ten seconds past the ceiling. The expiry is the same
    /// ceiling's other clock (`paid` bounds a call by both).
    @MainActor
    func testTheWaitOnAPageStillLoadingEndsWithTheErrandsTime() async throws {
        let model = Self.reading(["Start the example and read the text"]) { _, _ in .text(RecordedModel.reading([])) }
        let engine = ScriptedEngine(choice: { request in
            if let start = Self.named("Start", request) { return ScriptedEngine.pick(start) }
            guard let elsewhere = Self.named("Elsewhere", request) else {
                return ScriptedEngine.pick(Self.operation(.stuck, request))
            }
            return ScriptedEngine.pick(elsewhere, confidence: 0.3)
        })
        let limits = AgentBudget.Limits(steps: 40, activeSeconds: 9, spendMicros: 500_000, expiry: .seconds(1_800))
        let run = try run(engine, model, planner: Self.reads(), start: URL(string: "https://site-479.test/forever")!,
                          limits: limits)
        let began = ContinuousClock.now
        let outcome = await run.run(report: { _ in })
        let took = ContinuousClock.now - began
        XCTAssertTrue(run.record.steps.contains { $0.operation == "open" && $0.outcome == .reconsidered },
                      "the wait on the loading page began: \(run.record.eventLines)")
        XCTAssertNotEqual(outcome.ending, .done)
        XCTAssertLessThan(took, .seconds(12), "the errand ended at its time, not ten seconds past it: \(run.record.eventLines)")
    }

    /// A list over three pages whose reader says it goes on but names no control, and a model that names one
    /// sub-goal and gives up: code walks the list — the page's one next link, never asked of Jev — and reads each
    /// page, told of its next-page control, until the last gives the count (a reference browser agent's
    /// `_follow_pages` and `_paging`, MIT). Told only that the list went on, the model answered a count from its
    /// own memory (quotes.toscrape, 2026-10-16).
    @MainActor
    func testAListThatGoesOnIsWalkedByItsNextLinkAndEachPageRead() async throws {
        let model = Self.reading(["Count the quotes here"],
                                 verify: { _, _ in RecordedModel.verdict(complete: true) }) { asked, _ in
            let content = asked.contents.last.flatMap { $0 } ?? ""
            if !content.contains("URL: https://site-478.test/page/3/") {
                let reply: [String: Any] = ["claims": [], "answered": false,
                                            "continues": [["requirement_id": "r1", "expands": NSNull(),
                                                           "records": [["first": "main/:2", "last": "main/:3"]]]]]
                return .text(String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
            }
            return .text(RecordedModel.reading([RecordedModel.claim(cite: nil, drawsOn: ["1", "2", "3", "4"],
                                                                    records: [("main/:2", "main/:3")],
                                                                    text: "Six quotes.", requirement: "r1")],
                                               answered: true))
        }
        let seen = Seen()
        let engine = ScriptedEngine(choice: { request in
            seen.add(request)
            return ScriptedEngine.pick(Self.operation(.done, request))
        })
        let run = try run(engine, model, planner: Self.reads(), start: URL(string: "https://site-478.test/page/1/")!)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done, "\(run.record.eventLines)")
        let reads = model.requests("read").compactMap { $0.contents.last ?? nil }
        XCTAssertEqual(reads.map { $0.contains("URL: https://site-478.test/page/1/") }, [true, false, false])
        XCTAssertEqual(reads.map { $0.contains("URL: https://site-478.test/page/3/") }, [false, false, true])
        XCTAssertEqual(reads.map { $0.contains(NextPage.notice("Next →")) }, [true, true, false],
                       "each page with a next link tells the reader so")
        XCTAssertEqual(reads.map { $0.contains(ErrandModel.pagesFrom("https://site-478.test/page/1/")) },
                       [true, true, true], "every read of the list says where the run began")
        XCTAssertFalse(seen.all.contains { $0.page.url.hasSuffix("/page/1/") && $0.goal != "Count the quotes here" },
                       "the next link was taken, not asked of Jev")
        XCTAssertEqual(run.record.steps.filter { $0.operation == "open" && $0.outcome == .acted }.count, 2,
                       "\(run.record.eventLines)")
        XCTAssertEqual(model.requests("subgoal").count, 1, "the model named one sub-goal; code walked the rest")
    }

    /// A list whose pager is drawn above it and below it — two "Next →" links to one address, under two headings,
    /// two controls to Jev — is walked as one with a single drawing: the walk takes the page's next link as found on
    /// the look it goes against, its first drawing, never a label two controls share. Handed only the label, the
    /// step met two controls of it and stopped the walk at the first page (Codex review of 2026-10-18, P1-4).
    @MainActor
    func testAListWhosePagerIsDrawnAboveAndBelowIsWalkedByItsNextLink() async throws {
        let model = Self.reading(["Count the quotes here"],
                                 verify: { _, _ in RecordedModel.verdict(complete: true) }) { asked, _ in
            let content = asked.contents.last.flatMap { $0 } ?? ""
            if !content.contains("URL: https://site-485.test/page/3/") {
                let reply: [String: Any] = ["claims": [], "answered": false,
                                            "continues": [["requirement_id": "r1", "expands": NSNull(),
                                                           "records": [["first": "main/:3", "last": "main/:4"]]]]]
                return .text(String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
            }
            return .text(RecordedModel.reading([RecordedModel.claim(cite: nil, drawsOn: ["1", "2"],
                                                                    records: [("main/:3", "main/:4")],
                                                                    text: "Six quotes.", requirement: "r1")],
                                               answered: true))
        }
        let engine = ScriptedEngine(choice: { ScriptedEngine.pick(Self.operation(.done, $0)) })
        let run = try run(engine, model, planner: Self.reads(), start: URL(string: "https://site-485.test/page/1/")!)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done, "\(run.record.eventLines)")
        let reads = model.requests("read").compactMap { $0.contents.last ?? nil }
        XCTAssertEqual((1...3).map { page in reads.filter { $0.contains("URL: https://site-485.test/page/\(page)/") }.count },
                       [1, 1, 1], "each of the three pages read once: \(run.record.eventLines)")
        XCTAssertEqual(run.record.steps.filter { $0.operation == "open" && $0.outcome == .acted }.count, 2,
                       "\(run.record.eventLines)")
    }

    /// A list over ten pages is walked to its end: each next page is a page state the errand never reached, which
    /// is progress, so the no-progress rule never ends the walk (a reference browser agent counts only actions
    /// that reach no new state, `agent.py` 1081-1094, MIT). Counted as steps without a row, the walk of
    /// quotes.toscrape ended at its eighth next page, unread, and the count was never reached (2026-10-16).
    @MainActor
    func testAListOverTenPagesIsWalkedToItsEnd() async throws {
        let model = Self.reading(["Count the quotes here"],
                                 verify: { _, _ in RecordedModel.verdict(complete: true) }) { asked, _ in
            let content = asked.contents.last.flatMap { $0 } ?? ""
            if !content.contains("URL: https://site-481.test/page/10/") {
                let reply: [String: Any] = ["claims": [], "answered": false,
                                            "continues": [["requirement_id": "r1", "expands": NSNull(),
                                                           "records": [["first": "main/:2", "last": "main/:3"]]]]]
                return .text(String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
            }
            return .text(RecordedModel.reading([RecordedModel.claim(cite: nil, drawsOn: ["1", "2"],
                                                                    records: [("main/:2", "main/:3")],
                                                                    text: "Twenty quotes.", requirement: "r1")],
                                               answered: true))
        }
        let engine = ScriptedEngine(choice: { ScriptedEngine.pick(Self.operation(.done, $0)) })
        let run = try run(engine, model, planner: Self.reads(), start: URL(string: "https://site-481.test/page/1/")!)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done, "\(run.record.eventLines)")
        let reads = model.requests("read").compactMap { $0.contents.last ?? nil }
        XCTAssertEqual((1...10).map { page in reads.filter { $0.contains("URL: https://site-481.test/page/\(page)/") }.count },
                       Array(repeating: 1, count: 10), "each of the ten pages read once: \(run.record.eventLines)")
        XCTAssertEqual(run.record.steps.filter { $0.operation == "open" && $0.outcome == .acted }.count, 9)
        XCTAssertEqual(model.requests("subgoal").count, 1, "the model named one sub-goal; code walked the rest")
    }

    /// The walk's ceiling counts the next pages code opens, as the reference's `max_pages` counts the pages it
    /// follows (`config.py` 124; its own test: one page followed at `max_pages=1`, MIT): on a list longer than the
    /// ceiling the first page and the next `maxPages` are read, each once, and no further next page is opened by the
    /// walk (Codex review of 2026-10-18, P1-2: the boundary pinned).
    @MainActor
    func testTheWalkOpensAtMostMaxPagesNextPages() async throws {
        let model = Self.reading(["Count the quotes here"]) { _, _ in
            let reply: [String: Any] = ["claims": [], "answered": false,
                                        "continues": [["requirement_id": "r1", "expands": NSNull(),
                                                       "records": [["first": "main/:2", "last": "main/:3"]]]]]
            return .text(String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        }
        let engine = ScriptedEngine(choice: { ScriptedEngine.pick(Self.operation(.stuck, $0)) })
        let run = try run(engine, model, planner: Self.reads(), start: URL(string: "https://site-486.test/page/1/")!)
        _ = await run.run(report: { _ in })
        let reads = model.requests("read").compactMap { $0.contents.last ?? nil }
        let last = AgentRun.maxPages + 1
        XCTAssertEqual((1...last).map { page in reads.filter { $0.contains("URL: https://site-486.test/page/\(page)/") }.count },
                       Array(repeating: 1, count: last), "the first page and the next \(AgentRun.maxPages), each once")
        XCTAssertFalse(reads.contains { $0.contains("URL: https://site-486.test/page/\(last + 1)/") },
                       "no page past the ceiling: \(run.record.eventLines)")
        XCTAssertEqual(run.record.steps.filter { $0.operation == "open" && $0.outcome == .acted }.count, AgentRun.maxPages)
    }

    /// № 34: six jokes on one page and four on another. The first read gives
    /// no claim the requirement's id; every claim is kept as numbered evidence
    /// and r1 stays open. The second read sees them as `requirements=-` and
    /// its one claim for r1 draws on them: the answer is all ten, each with
    /// its page's link — a repeat once, the heading no claim for r1 drew on
    /// not at all. The verifier, asked once r1 has its claim, says done.
    @MainActor
    func testSixJokesOnOnePageAndFourOnAnotherAreOneAnswerOfTen() async throws {
        let model = Self.reading(["Read the jokes here", "Open the next page of jokes"],
                                 verify: { _, _ in RecordedModel.verdict(complete: true) }) { asked, _ in
            RecordedModel.readsSixThenFour(asked)
        }
        let run = try run(Self.followsToTheSecondPage, model, planner: Self.reads(), start: Self.sixJokes)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done)

        let reads = model.requests("read")
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(Self.blockLines(try XCTUnwrap(reads.first)), ["[main/:1] (heading) Six jokes"]
            + RecordedModel.tenJokes.prefix(6).enumerated().map { "[main/:\($0.offset + 2)] (list_item) \($0.element)" }
            + ["[main/:8] (paragraph) Four more jokes"], "the premise: the first page's lines")
        XCTAssertEqual(lastResults(try subgoalCall(model, 1)).first?["still_to_find"] as? [String], ["Find 10 jokes"],
                       "no claim with r1's id yet: r1 stays open")
        // The first read's facts, then its claims' words, each resting on its fact (2026-10-15).
        let collected = ([#"[1] "Six jokes" requirements=- source="main/:1" url="https://site-408.test/" quote="Six jokes""#]
            + RecordedModel.tenJokes.prefix(6).enumerated().map { index, joke in
                #"[\#(index + 2)] "\#(joke)" requirements=- source="main/:\#(index + 2)" url="https://site-408.test/" quote="\#(joke)""#
            }
            + (1...7).map { #"[\#($0 + 7)] "MODEL-WORDS-\#($0)" requirements=- basis=[\#($0)]"# }).joined(separator: "\n")
        let second = try XCTUnwrap(reads.dropFirst().first?.contents.last ?? nil)
        XCTAssertTrue(second.hasPrefix("# Collected evidence\n" + collected + "\n\n# Capture\nURL: https://site-409.test/\n"),
                      second)

        let claim = try XCTUnwrap(run.record.statements.last { $0.requirement == "r1" })
        XCTAssertEqual(outcome.answer, (["\(claim.text)\n\(Self.sixJokes.absoluteString)\n\(Self.fourJokes.absoluteString)"]
            + RecordedModel.tenJokes.enumerated().map {
                $0.element + "\n" + ($0.offset < 6 ? Self.sixJokes : Self.fourJokes).absoluteString
            }).joined(separator: "\n\n"), "the claim, then ten, each with its page's link; the heading is not one")
        XCTAssertEqual(outcome.sources, [Self.sixJokes, Self.fourJokes])
        XCTAssertEqual(run.record.facts.count, 11, "a repeat is one entry")
        XCTAssertEqual(model.requests("verify").count, 1)
        XCTAssertEqual(model.requests("subgoal").count, 2, "done once r1 had its claim: the model is not asked again")
        let facts = String(decoding: try JSONEncoder().encode(run.record.facts), as: UTF8.self)
        XCTAssertFalse(facts.contains("MODEL-WORDS"), "the model's words are in no fact")
    }

    /// One claim for r1 on the jokes page; the model names one sub-goal, then
    /// stops; the verifier answers `verify`.
    @MainActor
    private func verified(_ verify: @escaping @Sendable (RecordedModel.Asked, Int) -> RecordedModel.Reply,
                          planner: FixedPlanner? = nil) async throws -> (ErrandOutcome, RecordedModel) {
        let model = Self.reading(["Read the jokes"], verify: verify) { _, _ in
            .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:2"), requirement: "r1")]))
        }
        let outcome = await (try run(Self.done, model, planner: try planner ?? Self.reads(), start: Self.jokes))
            .run(report: { _ in })
        return (outcome, model)
    }

    /// № 35: code decides done — the verifier says complete and names nothing
    /// missing or ungrounded. It is asked once r1 has its claim and, when it
    /// says no, again when the model stops: at most twice. An errand it never
    /// confirms ends not finished, with what it found (№ 36).
    @MainActor
    func testTheVerifiersVerdictDecidesDone() async throws {
        let cases: [(String, RecordedModel.Reply, ErrandRecord.Ending, Int)] = [
            ("complete, nothing named", RecordedModel.verdict(complete: true), .done, 1),
            ("missing", RecordedModel.verdict(complete: true, missing: ["r1"]), .notFinished, 2),
            ("ungrounded", RecordedModel.verdict(complete: true, ungrounded: ["r1"]), .notFinished, 2),
            ("an id the plan lacks", RecordedModel.verdict(complete: true, missing: ["req_1"]), .notFinished, 2),
            ("not complete", RecordedModel.verdict(complete: false), .notFinished, 2),
            // No verdict is no no: asked again at each end, two of them rejected (2026-10-15).
            ("no verdict", .status(400), .notFinished, 4),
        ]
        for (what, reply, ending, calls) in cases {
            let (outcome, model) = try await verified { _, _ in reply }
            XCTAssertEqual(outcome.ending, ending, what)
            XCTAssertEqual(model.requests("verify").count, calls, what)
            XCTAssertEqual(outcome.answer, Self.jokeLines[0] + "\nhttps://site-404.test/", "\(what): what it found")
            XCTAssertEqual(outcome.sources, [Self.jokes], what)
        }
    }

    /// The recovery reply naming the listed action labelled `label` (2026-10-15).
    private static func recovering(_ asked: RecordedModel.Asked, to label: String?, giveUp: Bool = false) -> RecordedModel.Reply {
        let content = asked.contents.last.flatMap { $0 } ?? ""
        let listed = content.components(separatedBy: "## Actions\n").last?.components(separatedBy: "\n\n## Page\n").first ?? "[]"
        let actions = (try? JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [[String: Any]]) ?? []
        let index = label.flatMap { label in actions.first { $0["label"] as? String == label }?["index"] as? Int }
        return .text(#"{"diagnosis": "MODEL-DIAGNOSIS", "next_subgoal": "MODEL-SUBGOAL", "action": \#(index.map(String.init) ?? "null"), "give_up": \#(giveUp)}"#)
    }

    /// 2026-10-15 (the bench: Jev at 0.3–0.6 on a link, a select, a "new tab" link — reconsidered twice and the
    /// sub-goal stuck, again and again; a reference browser agent's `_try_unsure` and `_recover`): Jev's unsure pick
    /// is tried once on a page state; on that state again, the text model names the step — its recovery text, the
    /// page's actions listed by index, the problem — and the step it names is taken as any step is.
    @MainActor
    func testAnUnsurePickIsTriedOnceAPageStateThenTheModelNamesTheStep() async throws {
        let model = RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return n == 0 ? .calls([RecordedModel.goal("Show the tips")]) : .text("Done.")
            case "recover": return Self.recovering(asked, to: "Show tips")
            default: return .status(400)
            }
        }
        let engine = ScriptedEngine(choice: { request in
            Self.named("Hide tips", request) != nil ? ScriptedEngine.pick(Self.operation(.done, request))
                : ScriptedEngine.pick(Self.operation(.wait, request), confidence: 0.4)
        })
        let run = try run(engine, model)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(run.record.steps.prefix(3).map { "\($0.operation) \($0.outcome.rawValue)" },
                       ["wait acted", "click acted", "done acted"], "\(run.record.eventLines)")
        XCTAssertEqual(model.requests("recover").count, 1, "the second time on that page, not the first")
        let asked = try XCTUnwrap(model.requests("recover").first)
        XCTAssertEqual(asked.contents.first, ModelTexts.recovery)
        let content = try XCTUnwrap(asked.contents.last ?? nil)
        XCTAssertTrue(content.hasPrefix("## Actions\n[{\"index\": 1, \"action\": "), content)
        XCTAssertTrue(content.contains(#"{"index": "#) && content.contains(#""action": "click", "label": "Show tips", "role": "button"}"#), content)
        XCTAssertTrue(content.contains("\n\n## Page\nhttps://site-401.test/\n"), content)
        XCTAssertTrue(content.contains("\n\n## Recovery memory\nnone\n\n"), content)
        XCTAssertTrue(content.hasSuffix("## Task\n\(Self.goal)\n\n## Current subgoal\nShow the tips\n\n## Problem\nuncertain next step (0.40)"), content)
        XCTAssertEqual(asked.body["purpose"] as? String, "recover")
        let format = asked.body["response_format"] as? [String: Any]
        XCTAssertEqual((format?["json_schema"] as? [String: Any])?["name"] as? String, "Recovery")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(run.record), as: UTF8.self).contains("MODEL-"),
                       "its words are on no record")
    }

    /// 2026-10-15 (the bench: Jev said DONE at 0.5-0.7 on Hacker News's front page and the "new tab" page, again
    /// and again, and each sub-goal ended stuck where it began): Jev's doubted BLOCKED is reconsidered once on a
    /// page state; the second time there the text model names the step, and the step it names is taken. (A
    /// doubted DONE ends the sub-goal since 2026-10-16, and its page is read.)
    @MainActor
    func testATwiceDoubtedBlockedOnAPageStateAsksTheModelForTheStep() async throws {
        let model = RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return n == 0 ? .calls([RecordedModel.goal("Show the tips")]) : .text("Done.")
            case "recover": return Self.recovering(asked, to: "Show tips")
            default: return .status(400)
            }
        }
        let engine = ScriptedEngine(choice: { request in
            Self.named("Hide tips", request) != nil ? ScriptedEngine.pick(Self.operation(.done, request), confidence: 0.95)
                : ScriptedEngine.pick(Self.operation(.stuck, request), confidence: 0.6)
        })
        let run = try run(engine, model)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(run.record.steps.prefix(3).map { "\($0.operation) \($0.outcome.rawValue)" },
                       ["stuck reconsidered", "click acted", "done acted"], "\(run.record.eventLines)")
        let content = try XCTUnwrap(model.requests("recover").first?.contents.last ?? nil)
        XCTAssertTrue(content.hasSuffix("## Problem\nuncertain whether the sub-goal is blocked (0.60)"), content)
        XCTAssertEqual(model.requests("recover").count, 1)
    }

    /// A step that did nothing from a page state is not taken from it again: Jev, picking the menu's link to the
    /// page itself once more, has the text model told that it already did nothing here, and the step it names is
    /// taken (a reference browser agent's `attempted.idle`, `agent.py` 778-788, MIT). Jev opened such a link
    /// seven times over (qa-practice new tab, 2026-10-16).
    @MainActor
    func testAStepThatDidNothingFromAPageStateIsNotTakenFromItAgain() async throws {
        let model = RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return n == 0 ? .calls([RecordedModel.goal("Open the page the new tab link opens")]) : .text("Done.")
            case "recover": return Self.recovering(asked, to: "New page will be opened on a new tab")
            default: return .status(400)
            }
        }
        let engine = ScriptedEngine(choice: { request in
            if request.page.url.hasSuffix("/new_page") { return ScriptedEngine.pick(Self.operation(.done, request)) }
            return ScriptedEngine.pick(Self.named("New tab link", request))
        })
        let run = try run(engine, model, start: URL(string: "https://site-480.test/link")!)
        _ = await run.run(report: { _ in })
        let opened = run.record.steps.filter { $0.operation == "open" && $0.outcome == .acted }
        XCTAssertEqual(opened.count, 2, "the link to the page itself once, then the one named: \(run.record.eventLines)")
        XCTAssertEqual(model.requests("recover").count, 1, "\(run.record.eventLines)")
        let content = try XCTUnwrap(model.requests("recover").first?.contents.last ?? nil)
        XCTAssertTrue(content.hasSuffix("## Problem\nopen New tab link already did nothing here"), content)
    }

    /// The recovery's limits (2026-10-15): one that names no action leaves Jev's step reconsidered; one that gives
    /// up ends the sub-goal blocked; an errand asks it at most four times; and a step the structure calls
    /// irreversible is never tried unsure — the model is asked at once.
    @MainActor
    func testTheRecoveryNamesNothingGivesUpAndIsAskedAtMostFourTimesAnErrand() async throws {
        let none = RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return n < 6 ? .calls([RecordedModel.goal("Show the tips \(n)")]) : .text("Done.")
            case "recover": return Self.recovering(asked, to: nil)
            default: return .status(400)
            }
        }
        let waits = ScriptedEngine(choice: { ScriptedEngine.pick(Self.operation(.wait, $0), confidence: 0.4) })
        _ = await (try run(waits, none)).run(report: { _ in })
        XCTAssertEqual(none.requests("recover").count, AgentRun.maxRecoveries)
        XCTAssertEqual(AgentRun.maxRecoveries, 4)

        let quits = RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return n == 0 ? .calls([RecordedModel.goal("Show the tips")]) : .text("Done.")
            case "recover": return Self.recovering(asked, to: "Show tips", giveUp: true)
            default: return .status(400)
            }
        }
        let gaveUp = try run(waits, quits)
        _ = await gaveUp.run(report: { _ in })
        XCTAssertEqual(lastResults(try subgoalCall(quits, 1)).first?["status"] as? String, "blocked")
        XCTAssertFalse(gaveUp.record.steps.contains { $0.operation == "click" }, "a give-up takes nothing")
    }

    /// 2026-10-15 (the bench: the model said "I can't" on its first reply without a call, and the errand ended): a
    /// reply without a call while something is still to do is rejected — the model reads "DONE rejected: " and each
    /// requirement still to do, by its id and words, after its own reply — and is asked again, at most twice an
    /// errand; then the errand ends not finished. Once an end was rejected, the verifier is not asked again about a
    /// run it said no to that has not changed since.
    @MainActor
    func testAModelThatStopsWithSomethingStillToDoHearsWhyAtMostTwice() async throws {
        let model = Self.reading(["Read the jokes"]) { _, _ in .text(RecordedModel.reading([])) }
        let outcome = await (try run(Self.done, model, planner: Self.reads(), start: Self.jokes)).run(report: { _ in })
        XCTAssertEqual(outcome.ending, .notFinished)
        let asked = model.requests("subgoal")
        XCTAssertEqual(asked.count, 4, "the first call, its end, and two ends rejected")
        let second = try XCTUnwrap(asked.dropFirst(2).first?.messages)
        XCTAssertEqual(second.suffix(2).map { $0["role"] as? String }, ["assistant", "user"])
        XCTAssertEqual(second.suffix(2).first?["content"] as? String, "Done.", "its own words")
        XCTAssertNil(second.suffix(2).first?["tool_calls"], "no empty list of calls")
        XCTAssertEqual(second.last?["content"] as? String, "DONE rejected: r1: Find 10 jokes")
        XCTAssertEqual(asked.last?.messages.filter { $0["role"] as? String == "user" }.count, 3, "the goal and two rejections")

        let judged = Self.reading(["Read the jokes"], verify: { _, _ in RecordedModel.verdict(complete: false, missing: ["r1"]) }) { _, _ in
            .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:2"), requirement: "r1")]))
        }
        let unchanged = await (try run(Self.done, judged, planner: Self.reads(), start: Self.jokes)).run(report: { _ in })
        XCTAssertEqual(unchanged.ending, .notFinished)
        XCTAssertEqual(judged.requests("verify").count, 2, "asked at the claim and at the model's first end; then its no stands")
        XCTAssertEqual(judged.requests("subgoal").count, 4)
    }

    /// 2026-10-15 (the bench's two filter tasks: the verifier named the filters and the sort still undone, and the
    /// model heard only the facts still to find): an action requirement the verifier's no named is in the model's
    /// next result beside the facts still to find, in the plan's order; one named read off the wrong page says the
    /// pages it was read off.
    @MainActor
    func testWhatTheVerifiersNoNamedIsInTheModelsNextResult() async throws {
        let plan = try XCTUnwrap(AgentPlan(goal: Self.goal, requirements: [
            .init(id: "r1", text: "Find 10 jokes", kind: .information),
            .init(id: "r2", text: "Sort the jokes by date", kind: .action),
            .init(id: "r3", text: "Open the jokes page", kind: .action),
        ], answerExpected: true))
        let model = Self.reading(["Read the jokes", "Sort them"],
                                 verify: { _, _ in RecordedModel.verdict(complete: false, missing: ["r2"], ungrounded: ["r1"]) }) { _, _ in
            .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:2"), requirement: "r1")]))
        }
        _ = await (try run(Self.done, model, planner: FixedPlanner(plan: plan), start: Self.jokes)).run(report: { _ in })
        XCTAssertEqual(lastResults(try subgoalCall(model, 1)).first?["still_to_find"] as? [String],
                       ["Find 10 jokes (read off https://site-404.test/, not the page the task describes)",
                        "Sort the jokes by date"])
    }

    /// A requirement the verifier names — missing or ungrounded, by its id as
    /// the verifier may spell it, or every one when it names none of the
    /// plan's and says the errand is not complete — is still to find: the
    /// model's next result lists it, the next page is read for it, and its
    /// new claim asks the verifier again (ITER-076, live 2026-10-06 23:40: a
    /// page of eleven game titles read as the jokes asked for, the verifier
    /// said no, and the model was told nothing was left to find).
    @MainActor
    func testARequirementTheVerifierNamesIsStillToFind() async throws {
        // Named as read off the wrong page, it says the pages it was read off (2026-10-15).
        let misread = "Find 10 jokes (read off https://site-408.test/, not the page the task describes)"
        let rejections: [(String, RecordedModel.Reply, String)] = [
            ("missing", RecordedModel.verdict(complete: false, missing: ["r1"]), "Find 10 jokes"),
            ("ungrounded, spelled by its number", RecordedModel.verdict(complete: true, ungrounded: ["1"]), misread),
            ("not complete, naming nothing", RecordedModel.verdict(complete: false), "Find 10 jokes"),
        ]
        for (what, rejection, line) in rejections {
            let model = Self.reading(["Read the jokes here", "Open the next page of jokes"],
                                     verify: { _, n in n == 0 ? rejection : RecordedModel.verdict(complete: true) }) { asked, _ in
                guard (asked.contents.last.flatMap { $0 } ?? "").contains("URL: https://site-408.test/") else {
                    return RecordedModel.readsSixThenFour(asked)
                }
                return .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:7"), requirement: "r1")]))
            }
            let run = try run(Self.followsToTheSecondPage, model, planner: Self.reads(), start: Self.sixJokes)
            let outcome = await run.run(report: { _ in })
            XCTAssertEqual(lastResults(try subgoalCall(model, 1)).first?["still_to_find"] as? [String], [line], what)
            XCTAssertEqual(model.requests("read").count, 2, "\(what): the next page is read for it")
            XCTAssertEqual(model.requests("verify").count, 2, "\(what): its new claim asks the verifier again")
            XCTAssertEqual(outcome.ending, .done, what)
            XCTAssertEqual(outcome.sources, [Self.sixJokes, Self.fourJokes], what)
        }
    }

    /// The verifier's ids are read as the reference reads them: by the id
    /// without punctuation or case, or by a trailing number alone, the last
    /// requirement with that number winning (Codex review 1 of the fix, P2: a
    /// number two requirements end in named the first, an action, and left the
    /// information requirement out of what is still to find).
    @MainActor
    func testTheVerifiersIdsAreReadAsTheReferenceReadsThem() throws {
        let plan = try XCTUnwrap(AgentPlan(goal: Self.goal, requirements: [
            .init(id: "action-1", text: "Open the jokes page", kind: .action),
            .init(id: "req-1", text: "Find 10 jokes", kind: .information),
            .init(id: "R_2", text: "Find who wrote them", kind: .information),
        ], answerExpected: true))
        XCTAssertEqual(AgentRun.planIDs(["1"], in: plan), ["req-1"], "a number: the last requirement ending in it")
        XCTAssertEqual(AgentRun.planIDs(["r2", "REQ_1", "action1"], in: plan), ["R_2", "req-1", "action-1"],
                       "an id without punctuation or case")
        XCTAssertEqual(AgentRun.planIDs(["req_3", "", "3"], in: plan), [], "a name matching none names nothing")
    }

    /// Done needs a claim with its id for every information requirement: with
    /// r3 unanswered the verifier is never asked, whatever it would say, and
    /// the errand is not finished.
    @MainActor
    func testDoneNeedsAClaimForEveryInformationRequirement() async throws {
        let (outcome, model) = try await verified({ _, _ in RecordedModel.verdict(complete: true) },
                                                  planner: Self.reads([.init(id: "r3", text: "Find who keeps the jokes",
                                                                             kind: .information)]))
        XCTAssertEqual(outcome.ending, .notFinished)
        XCTAssertEqual(model.requests("verify").count, 0)
        XCTAssertEqual(outcome.answer, Self.jokeLines[0] + "\nhttps://site-404.test/")
    }

    /// An errand of actions alone has no claim to wait for: the verifier is
    /// asked when the model stops, and its verdict decides.
    @MainActor
    func testAnErrandOfActionsIsVerifiedWhenTheModelStops() async throws {
        for (complete, ending) in [(true, ErrandRecord.Ending.done), (false, .notFinished)] {
            let model = Self.reading(["Show the tips"], verify: { _, _ in RecordedModel.verdict(complete: complete) }) { _, _ in
                .status(400)
            }
            let engine = ScriptedEngine(choice: { request in
                ScriptedEngine.pick(Self.named("Hide tips", request) != nil ? Self.operation(.done, request)
                                                                           : Self.named("Show tips", request))
            })
            let planner = FixedPlanner(plan: try XCTUnwrap(AgentPlan(goal: Self.goal, requirements: [
                .init(id: "r2", text: "Open the tips", kind: .action)], answerExpected: false)))
            let outcome = await (try run(engine, model, planner: planner)).run(report: { _ in })
            XCTAssertEqual(outcome.ending, ending, "\(complete)")
            XCTAssertEqual(model.requests("verify").count, 1, "\(complete): when the model stopped")
            XCTAssertEqual(model.requests("read").count, 0, "nothing to read for")
        }
    }

    /// What a step did reaches the verifier, and which boxes are ticked: told only "click Apple -> executed" and
    /// shown no box's tick, it could not tell a filter ticked from one unticked, and named a met requirement missing
    /// again and again (bstackdemo, 2026-10-16). Each step says what it visibly changed, once the next look tells.
    @MainActor
    func testTheVerifierSeesWhatEachStepChangedAndWhichBoxesAreTicked() async throws {
        let goal = "Show only Apple phones on site four seven six"
        let model = RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return n == 0 ? .calls([RecordedModel.goal("Tick Apple")]) : .text("Done.")
            case "verify": return RecordedModel.verdict(complete: true)
            default: return .status(400)
            }
        }
        let engine = ScriptedEngine(choice: { request in
            let apple = Self.named("Apple", request)
            return ScriptedEngine.pick(apple?.action.target?.checked == false ? apple : Self.operation(.done, request))
        })
        let planner = FixedPlanner(plan: try XCTUnwrap(AgentPlan(goal: goal, requirements: [
            .init(id: "r1", text: "Filter the phones to Apple", kind: .action)], answerExpected: false)))
        let outcome = await (try run(engine, model, planner: planner, goal: goal,
                                     start: URL(string: "https://site-476.test/")!)).run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done)
        let content = try XCTUnwrap(model.requests("verify").first?.contents.last ?? nil)
        XCTAssertTrue(content.contains("""
            ## Steps taken
            - click Apple -> executed (changed Apple checked: false -> true)

            ## Set controls
            [{"label": "Apple", "role": "checkbox", "checked": true}]
            """), content)
    }

    /// The verifier reads text 6 — the trust line, then the run laid out as
    /// the approval page shows it, the verdict text last — for its strict
    /// schema. The steps taken come from the run's last actions and what was
    /// typed with them — the search typed is sent as its typing ends (D4,
    /// 2026-10-07) — and the visited addresses are the pages' shown ones
    /// (№ 91). What was typed reaches neither the log nor the record but as
    /// part of the address its search led to, where the facts were read.
    @MainActor
    func testTheVerifierReadsTheRunAsTheApprovalPageLaysItOut() async throws {
        let typed = "SENTINEL-TYPED-5b7e"
        let model = RecordedModel { asked, _ in
            switch asked.purpose {
            case "subgoal": return .calls([RecordedModel.goal("Search for jokes")])
            case "field_text": return .text(#"{"text": "\#(typed)"}"#)
            case "read": return .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:1", "main/:1"),
                                                                                  requirement: "r1")]))
            case "verify": return RecordedModel.verdict(complete: true)
            default: return .status(400)
            }
        }
        let engine = Self.typesOnce()
        let lines = LogLines()
        let run = try run(engine, model, planner: Self.reads(), lines: lines)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done)

        let asked = try XCTUnwrap(model.requests("verify").first)
        XCTAssertEqual(asked.messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(asked.contents.first, ModelTexts.verifier)
        let content = try XCTUnwrap(asked.contents.last ?? nil)
        let today = { () -> String in
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.calendar = Calendar(identifier: .gregorian)
            format.dateFormat = "yyyy-MM-dd"
            return format.string(from: .now)
        }()
        XCTAssertTrue(content.hasPrefix("""
            ## Task
            \(Self.goal)

            ## Current date
            \(today)

            ## Requirements
            - r1: Find 10 jokes

            ## Steps taken
            - type Search = '\(typed)' -> executed (changed Search value: empty -> \(typed))
            - click site-401.test -> executed (went to https://site-401.test/search?q=\(typed); changed Search value: \(typed) -> empty; showed 4 controls: Search, Search, Show tips, Other page; removed 4 controls: Search, Search, Show tips, Other page)

            ## Set controls
            []

            ## Where each requirement's facts were read
            - r1: https://site-401.test/search?q=\(typed)

            ## Visited addresses
            - https://site-401.test/
            - https://site-401.test/search?q=\(typed)

            ## Page
            https://site-401.test/search?q=\(typed)

            """), content)
        XCTAssertTrue(content.contains("\n\n## Notes\n[1] \""), content)
        XCTAssertTrue(content.hasSuffix(ModelTexts.verdict), content)
        let format = try XCTUnwrap(asked.body["response_format"] as? [String: Any])
        let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["name"] as? String, "LLMVerdict")
        XCTAssertEqual(schema["strict"] as? Bool, true)
        XCTAssertNil(asked.body["tools"])

        let record = String(decoding: try JSONEncoder().encode(run.record), as: UTF8.self)
        XCTAssertFalse(record.replacingOccurrences(of: "search?q=" + typed, with: "").contains(typed),
                       "typed text is stored only in the address its search led to")
        XCTAssertFalse(lines.all.contains { $0.contains(typed) }, "nor said in the log")
        XCTAssertTrue(run.record.events.map(\.shape).contains("model verify ok"))
    }

    /// № 91: the verifier reads every address as the page shows it — never
    /// where the tab really is, which here holds a user name and a password,
    /// as a browser that keeps them in the tab's address reports it.
    @MainActor
    func testTheVerifierReadsTheAddressesThePagesShowNeverWhereTheTabIs() async throws {
        let model = Self.reading(["Read the jokes"], verify: { _, _ in RecordedModel.verdict(complete: true) }) { _, _ in
            .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:2"), requirement: "r1")]))
        }
        let bridge = TabAddressWithCredentials()
        let outcome = await (try run(Self.done, model, planner: Self.reads(), bridge: bridge, start: Self.jokes))
            .run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertGreaterThan(bridge.reports, 0, "the premise: the looks reported where the tab is, with credentials")
        let asked = try XCTUnwrap(model.requests("verify").first?.contents.last ?? nil)
        XCTAssertTrue(asked.contains("## Visited addresses\n- https://site-404.test/\n\n## Page\nhttps://site-404.test/\n"),
                      asked)
        XCTAssertFalse(asked.contains("pw-4417"), asked)
        XCTAssertEqual(outcome.sources, [Self.jokes])
    }

    /// The fixture browser, its looks reporting the tab's own address with a
    /// user name and a password in it; the address the page shows has none.
    @MainActor
    private final class TabAddressWithCredentials: BrowserBridge {
        let inner = WebViewBridge()
        private(set) var reports = 0

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            let answer = try await inner.run(javascript, in: tab)
            guard javascript == ObserverScript.source else { return answer }
            let address = #""address":"https://site-404.test/"#
            guard answer.contains(address) else { return answer }
            reports += 1
            return answer.replacingOccurrences(of: address, with: #""address":"https://sam:pw-4417@site-404.test/"#)
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// № 44: Stop while the verifier is asked ends the errand within Stop's
    /// limit, with what it found.
    @MainActor
    func testStopWhileTheVerifierIsAskedEndsTheErrandWithWhatItFound() async throws {
        let box = Box<AgentRun>()
        let model = Self.reading(["Read the jokes"], verify: { _, _ in
            Task { @MainActor in box.value?.stop() }
            return .after(.seconds(5), RecordedModel.verdict(complete: true))
        }) { _, _ in .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:2"), requirement: "r1")])) }
        let run = try run(Self.done, model, planner: Self.reads(), start: Self.jokes)
        box.value = run
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await run.run(report: { _ in })
        XCTAssertLessThan(clock.now - started, .seconds(4), "Stop's limit, not the verifier's 5 s")
        XCTAssertTrue(run.record.events.map(\.shape).contains("model verify stopped"))
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(model.requests("verify").count, 1)
        XCTAssertEqual(outcome.answer, Self.jokeLines[0] + "\nhttps://site-404.test/")
    }

    /// № 90: a No is final for that action on that page in the whole errand:
    /// the next sub-goal is not offered it, and the user is not asked again.
    @MainActor
    func testANoIsNotAskedAgainInALaterSubgoal() async throws {
        let model = Self.calling(["Send the search", "Send the search again"])
        let seen = Seen()
        let send = { (request: ChooseRequest) in
            request.candidates.first { $0.action.target?.name == "Search" && $0.action.operation == .click }
        }
        let engine = ScriptedEngine(choice: { request in
            seen.add(request)
            return ScriptedEngine.pick(send(request) ?? Self.operation(.done, request))
        })
        let asked = Asked()
        _ = await (try run(engine, model, start: URL(string: "https://site-402.test/")!,
                           confirm: { _ in asked.add(); return .no })).run(report: { _ in })
        XCTAssertEqual(asked.count, 1, "asked once, in the first sub-goal")
        let later = seen.all.filter { $0.goal == "Send the search again" }
        XCTAssertFalse(later.isEmpty, "the premise: the second sub-goal ran")
        XCTAssertTrue(later.allSatisfy { send($0) == nil }, "and was not offered it")
    }

    /// № 12: a browser error after a fact was found is a miss — the errand
    /// goes on — and a lost browser ends it; either way the facts found stay
    /// and are its answer.
    @MainActor
    func testABrowserErrorIsAMissAndTheFactsFoundStay() async throws {
        for failure in [BrowserBridgeError.scriptFailed(code: -3), .connectionLost] {
            let model = Self.reading(["Read the jokes", "Read them again"]) { _, _ in
                .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:2", "main/:2"), requirement: "r1")]))
            }
            // The third look is the second sub-goal's first step.
            let bridge = FailsALook(number: 3, with: failure)
            let run = try run(Self.done, model, planner: Self.reads([.init(id: "r3", text: "Find who keeps the jokes",
                                                                          kind: .information)]),
                              bridge: bridge, start: Self.jokes)
            let outcome = await run.run(report: { _ in })
            let what = "\(failure)"
            XCTAssertEqual(bridge.looks >= 3, true, "\(what): the premise: the failing look came")
            if failure == .connectionLost {
                XCTAssertEqual(outcome.ending, .failed, what)
                XCTAssertEqual(outcome.failure, .bridgeLost, what)
            } else {
                XCTAssertEqual(outcome.ending, .notFinished, "\(what): a miss, then on to the model's stop")
                XCTAssertTrue(run.record.steps.map(\.outcome).contains(.reconsidered), what)
            }
            XCTAssertEqual(run.record.facts.map(\.quote), [Self.jokeLines[0]], what)
            XCTAssertEqual(outcome.answer, Self.jokeLines[0] + "\nhttps://site-404.test/", what)
        }
    }

    /// The fixture browser, failing the observer's look `number` with `error`.
    @MainActor
    private final class FailsALook: BrowserBridge {
        let inner = WebViewBridge()
        private let number: Int
        private let error: BrowserBridgeError
        private(set) var looks = 0

        init(number: Int, with error: BrowserBridgeError) {
            self.number = number
            self.error = error
        }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            guard javascript == ObserverScript.source else { return try await inner.run(javascript, in: tab) }
            looks += 1
            if looks == number { throw error }
            return try await inner.run(javascript, in: tab)
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    // MARK: - What a call reserves (ITER-076 stage 10b)

    /// The model, answering every purpose of an errand that plans, types,
    /// reads and is verified; each answer says `costUSD`.
    private static func answering(costUSD: Double?) -> RecordedModel {
        RecordedModel(costUSD: costUSD) { asked, _ in
            switch asked.purpose {
            case "plan": return .text(RecordedModel.plan([("r1", "Find 10 jokes", "information")]))
            case "subgoal": return .calls([RecordedModel.goal("Search for jokes")])
            case "field_text": return .text(#"{"text": "jokes"}"#)
            case "read": return .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:1", "main/:1"),
                                                                                  requirement: "r1")]))
            case "verify": return RecordedModel.verdict(complete: true)
            default: return .status(400)
            }
        }
    }

    /// Jev types in the empty search field, then is done.
    private static var typesThenDone: ScriptedEngine { typesOnce() }

    /// Jev types the query once — into the empty field it first sees — then calls the sub-goal done: the search
    /// it typed is sent as its typing ends (D4, 2026-10-07), and the results page's own field is not typed in again.
    private static func typesOnce() -> ScriptedEngine {
        let typed = Asked()
        return ScriptedEngine(choice: { request in
            if typed.count == 0, let field = Self.field(request), field.action.target?.value ?? "" == "" {
                typed.add()
                return ScriptedEngine.pick(field)
            }
            return ScriptedEngine.pick(Self.operation(.done, request))
        })
    }

    /// What one call reserved before stage 10b, whatever it sent: the route's
    /// largest body read as one token a byte and the route's default cap,
    /// once, at MiniMax-M3's price.
    private static let routesLargest = (262_144 * 0.30 + 4_096 * 1.20) / 1_000_000

    /// A spend ceiling of $0.30.
    private static let thirtyCents = AgentBudget.Limits(steps: 40, activeSeconds: 600, spendMicros: 300_000,
                                                        expiry: .seconds(1_800))

    /// Each call of the text model reserves the worst case of the request it
    /// sends — the plan, a sub-goal, a field's text, a read and the verdict
    /// alike — not the route's largest: a call whose server says no cost
    /// counts exactly that (§8). The plan of a short goal is about 2.5 KB.
    @MainActor
    func testEveryModelCallReservesTheWorstCaseOfItsOwnRequest() async throws {
        let model = Self.answering(costUSD: nil)
        let run = try run(Self.typesThenDone, model, planner: model.planner)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done, "\(run.record.eventLines)")
        XCTAssertEqual(model.requests.map(\.purpose), ["plan", "subgoal", "field_text", "read", "verify"],
                       "the premise: every purpose went out")
        XCTAssertLessThan(try XCTUnwrap(model.bodies.first).count, 3_000, "the premise: a plan of about 2.5 KB")
        let costs = RecordedModel.costs(on: run.record)
        XCTAssertEqual(costs.count, model.worstCases.count)
        for (index, (cost, worst)) in zip(costs, model.worstCases).enumerated() {
            XCTAssertEqual(cost, worst, accuracy: 1e-6, "call \(index), \(model.requests[index].purpose)")
        }
        XCTAssertLessThan(try XCTUnwrap(costs.first), Self.routesLargest / 3, "the plan: its own size")
    }

    /// The bench's errand of 2026-10-06 10:57: two calls on a small request
    /// failed and said no cost. Each counts whole (§8) — and whole is now its
    /// own request's worst case, not the route's largest: under $0.05 for the
    /// two, where they counted $0.167.
    @MainActor
    func testTwoFailedCallsOnASmallRequestCountTheirOwnWorstCaseNotTheRoutesLargest() async throws {
        let model = RecordedModel { _, _ in .status(502, retryAfter: "0") }
        let run = try run(Self.done, model, planner: model.planner)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .unavailable)
        XCTAssertEqual(model.requests.map(\.purpose), ["plan", "plan"], "the premise: two calls, one wait between")
        let spent = try XCTUnwrap(run.record.spentUSD)
        XCTAssertEqual(spent, model.worstCases.reduce(0, +), accuracy: 2e-6)
        XCTAssertLessThan(spent, 0.05, "not twice the route's largest")
    }

    /// A body near the route's limit reserves every try the route may make
    /// for one call — the arm the owner may switch on, Groq twice, Cerebras
    /// once — each reading the whole body: at least four times one try.
    @MainActor
    func testAPlanNearTheRoutesLimitReservesEveryTryTheRouteMayMake() async throws {
        let model = Self.answering(costUSD: nil)
        let run = try run(Self.done, model, planner: model.planner, goal: String(repeating: "x", count: 250_000))
        _ = await run.run(report: { _ in })
        let body = try XCTUnwrap(model.bodies.first)
        XCTAssertGreaterThan(body.count, 250_000, "the premise: near the route's limit")
        XCTAssertLessThanOrEqual(body.count, ProLLMClient.maxBodyBytes, "the premise: it went out")
        let oneTry = (Double(body.count) * 0.30 + 4_096 * 1.20) / 1_000_000
        let plan = try XCTUnwrap(RecordedModel.costs(on: run.record).first)
        XCTAssertGreaterThanOrEqual(plan, 4 * oneTry)
        XCTAssertEqual(plan, try XCTUnwrap(model.worstCases.first), accuracy: 1e-6)
    }

    /// The spend ceiling refuses a call whose own worst case would cross it:
    /// near the route's limit, the plan is not sent under a $0.30 ceiling.
    @MainActor
    func testTheSpendCeilingRefusesACallWhoseOwnWorstCaseWouldCrossIt() async throws {
        let model = Self.answering(costUSD: nil)
        let run = try run(Self.done, model, planner: model.planner, goal: String(repeating: "x", count: 250_000),
                          limits: Self.thirtyCents)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .ceiling)
        XCTAssertTrue(model.requests.isEmpty, "never sent")
        XCTAssertEqual(run.record.spentUSD ?? 0, 0, accuracy: 1e-12)
    }

    /// Its sibling: under the same ceiling, calls whose own worst case fits
    /// still go out, each counted whole, and the errand ends done — the
    /// ceiling refuses by the request, not by the route's largest.
    @MainActor
    func testTheSpendCeilingStillLetsThroughACallWhoseOwnWorstCaseFits() async throws {
        let model = Self.answering(costUSD: nil)
        let run = try run(Self.done, model, planner: model.planner, limits: Self.thirtyCents)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(model.requests.map(\.purpose), ["plan", "subgoal", "read", "verify"], "sent")
        XCTAssertEqual(outcome.ending, .done, "\(run.record.eventLines)")
    }

    /// A body over the route's limit is never sent — the client refuses it,
    /// and the route would before any provider — so it reserves nothing: under
    /// a ceiling below what the route's largest body would reserve, the plan
    /// of a goal twice the limit fails as a plan that could not be asked and
    /// costs nothing — never a ceiling crossed on spend no provider could make.
    @MainActor
    func testABodyOverTheRoutesLimitIsNeverSentAndReservesNothing() async throws {
        let model = Self.answering(costUSD: nil)
        let run = try run(Self.done, model, planner: model.planner,
                          goal: String(repeating: "x", count: 2 * ProLLMClient.maxBodyBytes), limits: Self.thirtyCents)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.failure, .planFailed, "\(run.record.eventLines)")
        XCTAssertTrue(model.requests.isEmpty, "the premise: never sent")
        XCTAssertEqual(run.record.spentUSD ?? -1, 0, accuracy: 1e-12)
    }

    // MARK: - Helpers

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [ChooseRequest] = []
        func add(_ request: ChooseRequest) { lock.lock(); requests.append(request); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
        var all: [ChooseRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    }

    /// Steps counted by what they work toward.
    private final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        /// The number of this step among its goal's, from 0.
        func next(_ goal: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let n = counts[goal, default: 0]
            counts[goal] = n + 1
            return n
        }
        func count(_ goal: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[goal, default: 0] }
    }

    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
}
