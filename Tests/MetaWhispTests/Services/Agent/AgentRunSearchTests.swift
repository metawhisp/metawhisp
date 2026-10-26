import XCTest
@testable import MetaWhisp

/// ITER-076 stage 3 (№ 81, 82, 84, 58, 83, 253, 122) — a search without a Yes,
/// strictly as D4: it goes to the address code builds from its form — the
/// form's destination, its hidden fields as they are, the field's typed text —
/// never by a click, so none of the page's code runs for it. Only a search
/// field makes a search; a one-field e-mail form, or a form with a second
/// filled control, asks the Yes as before. Words in the query ask nothing. A
/// site that ignores the query is a miss, never a loop. A form with no button
/// is searched the same way.
final class AgentRunSearchTests: XCTestCase {

    private static let goal = "Find a joke on site four fifteen"

    private static func plan() throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: goal, requirements: [.init(id: "r1", text: "Find a joke", kind: .information)],
                                answerExpected: true))
    }

    /// The model: one sub-goal, then done; a field's text is `query`.
    private static func model(query: String) -> RecordedModel {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: ["text": query]), as: UTF8.self)
        return RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return n < 1 ? .calls([RecordedModel.goal("Search for a joke")]) : .text("Done.")
            case "field_text": return .text(text)
            default: return .status(400)
            }
        }
    }

    /// Jev: on the results, done — or, `resultsDone` false, press the button
    /// they show again; else type into the empty field, then press the form's
    /// button — or, with none, wait for the search to go.
    private static func jev(field: String = "Search", button: String = "Search",
                            resultsDone: Bool = true) -> ScriptedEngine {
        ScriptedEngine(choice: { request in
            let pick = { (operation: AgentOperation, name: String) in
                request.candidates.first { $0.action.operation == operation && $0.action.target?.name == name }
            }
            let done = request.candidates.first { $0.action.operation == .done }
            if resultsDone, request.page.title == "Results 415" { return ScriptedEngine.pick(done) }
            if let typing = pick(.type, field), typing.action.target?.value ?? "" == "" { return ScriptedEngine.pick(typing) }
            return ScriptedEngine.pick(pick(.click, button) ?? done)
        })
    }

    @MainActor
    private final class Asked {
        var questions: [ConfirmationRequest] = []
    }

    @MainActor
    private func run(on start: String, jev: ScriptedEngine, model: RecordedModel, bridge: WebViewBridge,
                     asked: Asked, facts: FormFacts = .none) throws -> AgentRun {
        AgentRun(goal: Self.goal, planner: try FixedPlanner(plan: Self.plan()), errandID: UUID(),
                 collaborators: .init(bridge: bridge, engine: jev, writer: nil, sheet: nil,
                                      confirm: { request in
                                          asked.questions.append(request)
                                          return .no
                                      }, log: { _ in }, model: model.model, facts: { facts }),
                 startPage: URL(string: start)!)
    }

    private static let built = URL(string: "https://site-415.test/search?src=hp+%26+home&q=jokes")!

    /// The search goes to the address its form builds — hidden fields as they
    /// are, in the form's own order — with no Yes; the button is never pressed
    /// and the form never sent, so its page code never runs.
    @MainActor
    func testASearchGoesToTheAddressItsFormBuildsAndNoPageCodeRuns() async throws {
        let asked = Asked()
        let bridge = WebViewBridge()
        let run = try run(on: "https://site-415.test/", jev: Self.jev(), model: Self.model(query: "jokes"),
                          bridge: bridge, asked: asked)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(asked.questions.count, 0, "no Yes")
        XCTAssertTrue(bridge.navigatedURLs.contains(Self.built), "\(bridge.navigatedURLs)")
        XCTAssertFalse(bridge.navigatedURLs.contains { ["/clicked", "/submitted"].contains($0.path) },
                       "the page's own code never ran: \(bridge.navigatedURLs)")
        XCTAssertTrue(run.record.steps.contains { $0.operation == "open" && $0.outcome == .acted },
                      "the search is an open of the built address")
        XCTAssertFalse(run.record.steps.contains { $0.operation == "click" }, "nothing was clicked")
    }

    /// A one-field e-mail form — a sign-up, GET to its own site — is no
    /// search: it asks the Yes, and a No sends nothing (Codex review 2, P1-1).
    /// It is a form of the user's details (ITER-076 stage 7, review round 1,
    /// C1): the Yes it asks is its preview's, the user's own e-mail in it.
    @MainActor
    func testAOneFieldEmailFormAsksTheYes() async throws {
        let asked = Asked()
        let bridge = WebViewBridge()
        let facts = FormFacts.collect(memories: [], proEmail: "sam.pro@example.test")
        let run = try run(on: "https://site-415.test/?kind=email", jev: Self.jev(field: "Email", button: "Join"),
                          model: Self.model(query: "someone"), bridge: bridge, asked: asked, facts: facts)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(asked.questions.count, 1, "\(run.record.eventLines)")
        XCTAssertEqual(asked.questions.first?.form?.kind, .fill)
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/join" }, "a No sends nothing")
    }

    /// A second filled control — a category the form would send too — makes
    /// it no pure search: the Yes as before.
    @MainActor
    func testASecondFilledControlAsksTheYesAsBefore() async throws {
        let asked = Asked()
        let bridge = WebViewBridge()
        let run = try run(on: "https://site-415.test/?category=1", jev: Self.jev(), model: Self.model(query: "jokes"),
                          bridge: bridge, asked: asked)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(asked.questions.count, 1, "\(run.record.eventLines)")
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/search" })
    }

    /// Words like "delete" in the query ask no Yes: no button is pressed, and
    /// the query is the user's (№ 83, 253).
    @MainActor
    func testWordsInTheQueryAskNoYes() async throws {
        let asked = Asked()
        let bridge = WebViewBridge()
        let run = try run(on: "https://site-415.test/", jev: Self.jev(),
                          model: Self.model(query: "how to delete an account"), bridge: bridge, asked: asked)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(asked.questions.count, 0)
        XCTAssertTrue(bridge.navigatedURLs.contains(
            URL(string: "https://site-415.test/search?src=hp+%26+home&q=how+to+delete+an+account")!),
                      "\(bridge.navigatedURLs)")
    }

    /// A site that ignores the address's query shows its form again: the same
    /// address is never sent twice — a miss, not a loop (№ 58).
    @MainActor
    func testASiteThatIgnoresTheQueryIsAMissNeverALoop() async throws {
        let asked = Asked()
        let bridge = WebViewBridge()
        let run = try run(on: "https://site-415.test/?mode=ignore", jev: Self.jev(), model: Self.model(query: "jokes"),
                          bridge: bridge, asked: asked)
        _ = await run.run(report: { _ in })
        let sent = bridge.navigatedURLs.filter { $0.path == "/search" }
        XCTAssertEqual(sent.count, 1, "sent once: \(bridge.navigatedURLs)")
        XCTAssertEqual(asked.questions.count, 0)
        XCTAssertTrue(run.record.steps.contains { $0.outcome == .reconsidered }, "\(run.record.eventLines)")
    }

    /// A search engine's results draw its box again, the query in it, under
    /// another heading — another fingerprint (live, 2026-10-07, DuckDuckGo: a
    /// Yes was asked for its Search). Jev's press of that Search is the
    /// agent's own search: no Yes, the page's code never runs, and the address
    /// already sent is not sent again — a miss, not a loop (№ 58).
    @MainActor
    func testTheResultsBoxShowingTheAgentsQueryAsksNoYes() async throws {
        let asked = Asked()
        let bridge = WebViewBridge()
        let run = try run(on: "https://site-415.test/?mode=again", jev: Self.jev(resultsDone: false),
                          model: Self.model(query: "jokes"), bridge: bridge, asked: asked)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(asked.questions.count, 0, "\(run.record.eventLines)")
        XCTAssertEqual(bridge.navigatedURLs.filter { $0.path == "/search" }.count, 1, "\(bridge.navigatedURLs)")
        XCTAssertFalse(bridge.navigatedURLs.contains { ["/clicked", "/submitted"].contains($0.path) },
                       "the page's own code never ran: \(bridge.navigatedURLs)")
    }

    /// A search form with no button is searched the same way once its field
    /// is typed into (№ 122).
    @MainActor
    func testAFormWithNoButtonIsSearchedTheSameWay() async throws {
        let asked = Asked()
        let bridge = WebViewBridge()
        let run = try run(on: "https://site-415.test/?button=0", jev: Self.jev(), model: Self.model(query: "jokes"),
                          bridge: bridge, asked: asked)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(asked.questions.count, 0)
        XCTAssertTrue(bridge.navigatedURLs.contains(Self.built), "\(bridge.navigatedURLs)")
    }

    /// A search form whose button no one can press — drawn at no size and
    /// transparent, as a search box that sends on Enter draws it — is to the
    /// person a form with no button: searched the same way once its field is
    /// typed into, its button never pressed (№ 122).
    @MainActor
    func testAFormWhoseButtonNoOneCanPressIsSearchedTheSameWay() async throws {
        let asked = Asked()
        let bridge = WebViewBridge()
        let run = try run(on: "https://site-415.test/?button=hidden", jev: Self.jev(), model: Self.model(query: "jokes"),
                          bridge: bridge, asked: asked)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(asked.questions.count, 0)
        XCTAssertTrue(bridge.navigatedURLs.contains(Self.built), "\(bridge.navigatedURLs)")
    }
}
