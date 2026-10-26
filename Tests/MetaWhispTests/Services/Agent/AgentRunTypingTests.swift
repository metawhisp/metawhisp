import XCTest
@testable import MetaWhisp

/// ITER-076 stage 3 (№ 89, 97) — typing safety: the text a Yes is given for is
/// exactly the text typed; after a No, the same field is not typed into again
/// — the No is kept by the field, whatever text was written for it; and an act
/// with the user's Yes whose delivery is not known is never sent again.
final class AgentRunTypingTests: XCTestCase {

    private static let goal = "Send a hello through the contact form on site four seventeen"

    private static func plan() throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: goal, requirements: [.init(id: "r1", text: "Send the hello", kind: .action)],
                                answerExpected: false))
    }

    /// The model: one sub-goal, then done; a field's text is always the same.
    private static func model() -> RecordedModel {
        RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return n < 1 ? .calls([RecordedModel.goal("Write and send the hello")]) : .text("Done.")
            case "field_text": return .text(#"{"text": "Hello there"}"#)
            default: return .status(400)
            }
        }
    }

    /// Jev picks `wanted` while it is offered, then DONE; every risk answer
    /// says the step may be irreversible.
    private static func jev(_ wanted: @escaping @Sendable (Candidate) -> Bool) -> ScriptedEngine {
        ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first(where: wanted)
                                    ?? request.candidates.first { $0.action.operation == .done })
        }, irreversible: { _ in 0.9 })
    }

    @MainActor
    private final class Questions {
        var asked: [ConfirmationRequest] = []
    }

    /// The fixture browser, whose tab stays open when the run closes it.
    @MainActor
    private final class KeepsItsTab: BrowserBridge {
        let inner = WebViewBridge()
        private(set) var tab: BrowserTab?

        func openTab(_ url: URL) async throws -> BrowserTab {
            let opened = try await inner.openTab(url)
            tab = opened
            return opened
        }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws {}
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String { try await inner.run(javascript, in: tab) }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }

        /// What the page holds, read in it once the run is over.
        func read(_ script: String) async throws -> String {
            try await inner.run(script, in: try XCTUnwrap(tab))
        }
    }

    @MainActor
    private func run(_ jev: ScriptedEngine, _ model: RecordedModel, bridge: KeepsItsTab, questions: Questions,
                     answer: ConfirmationRequest.Answer) throws -> AgentRun {
        AgentRun(goal: Self.goal, planner: try FixedPlanner(plan: Self.plan()), errandID: UUID(),
                 collaborators: .init(bridge: bridge, engine: jev, writer: nil, sheet: nil, confirm: { request in
                     questions.asked.append(request)
                     return answer
                 }, log: { _ in }, model: model.model),
                 startPage: URL(string: "https://site-417.test/")!)
    }

    private static let message: @Sendable (Candidate) -> Bool = {
        $0.action.operation == .type && $0.action.target?.name == "Message" && ($0.action.target?.value ?? "").isEmpty
    }

    /// The Yes is given for the very text typed: written before it was asked,
    /// carried by the question, and landed as it is.
    @MainActor
    func testTheTextAYesIsGivenForIsExactlyTheTextTyped() async throws {
        let questions = Questions()
        let bridge = KeepsItsTab()
        let run = try run(Self.jev(Self.message), Self.model(), bridge: bridge, questions: questions, answer: .yes)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.map(\.action.payload), ["Hello there"], "\(run.record.eventLines)")
        let typed = try await bridge.read("document.getElementById('message').value")
        XCTAssertEqual(typed, "Hello there")
    }

    /// After a No, the field is not typed into again — not even with text
    /// written anew (critic row 9).
    @MainActor
    func testAfterANoTheSameFieldIsNotTypedAgain() async throws {
        let questions = Questions()
        let model = Self.model()
        let bridge = KeepsItsTab()
        let run = try run(Self.jev(Self.message), model, bridge: bridge, questions: questions, answer: .no)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertEqual(model.requests("field_text").count, 1, "no text written for it again")
        let typed = try await bridge.read("document.getElementById('message').value")
        XCTAssertEqual(typed, "", "nothing typed")
    }

    /// An act with the user's Yes whose delivery cannot be seen — it changed
    /// nothing a look reads — is never sent again, not even with a new Yes.
    @MainActor
    func testAnActWhoseDeliveryIsUnknownIsNeverSentAgain() async throws {
        let questions = Questions()
        let bridge = KeepsItsTab()
        let send: @Sendable (Candidate) -> Bool = { $0.action.target?.name == "Send message" }
        let run = try run(Self.jev(send), Self.model(), bridge: bridge, questions: questions, answer: .yes)
        _ = await run.run(report: { _ in })
        let sent = try await bridge.read("String(window.sent || 0)")
        XCTAssertEqual(sent, "1", "\(run.record.eventLines)")
        XCTAssertEqual(questions.asked.count, 1)
    }
}
