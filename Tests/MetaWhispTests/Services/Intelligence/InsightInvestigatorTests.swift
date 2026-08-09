import XCTest
@testable import MetaWhisp

/// ITER-027.6 — pins the investigation loop: tools over history, scripted
/// transports, hard round cap. The content fix for «бесполезные подсказки»:
/// advice must be born from INVESTIGATED history, not echoed from the frame.
final class InsightInvestigatorTests: XCTestCase {

    private typealias I = InsightInvestigator

    private func snap(_ minutesAgo: Double, _ app: String, _ window: String, _ ocr: String,
                      now: Date = Date()) -> I.Snapshot {
        I.Snapshot(time: now.addingTimeInterval(-minutesAgo * 60), app: app, window: window, ocr: ocr)
    }

    // MARK: - tool execution

    func test_search_filtersByAppAndText() {
        let now = Date()
        let snaps = [
            snap(5, "Terminal", "zsh", "git stash push wip-parser", now: now),
            snap(10, "Safari", "Docs", "some documentation text", now: now),
            snap(90, "Terminal", "zsh", "npm install something", now: now),
        ]
        let hit = I.executeSearch(snapshots: snaps, appContains: "term", textContains: "stash",
                                  minutesBack: nil, limit: nil, now: now)
        XCTAssertTrue(hit.contains("id=0"))
        XCTAssertFalse(hit.contains("id=1"))
        XCTAssertFalse(hit.contains("id=2"))
    }

    func test_search_respectsLookbackAndLimitCaps() {
        let now = Date()
        let snaps = (0 ..< 50).map { snap(Double($0), "App", "W", "text \($0)", now: now) }
        let recent = I.executeSearch(snapshots: snaps, appContains: nil, textContains: nil,
                                     minutesBack: 10, limit: 100, now: now)
        // Lookback 10 min → ids 0-10; limit capped at 20 regardless of ask.
        XCTAssertTrue(recent.contains("id=0"))
        XCTAssertFalse(recent.contains("id=15"))
        XCTAssertLessThanOrEqual(recent.components(separatedBy: "\n").count, I.searchLimitCap)
    }

    func test_search_snippetTruncated() {
        let now = Date()
        let long = String(repeating: "x", count: 2000)
        let out = I.executeSearch(snapshots: [snap(1, "App", "W", long, now: now)],
                                  appContains: nil, textContains: nil, minutesBack: nil, limit: nil, now: now)
        XCTAssertLessThan(out.count, 400)
    }

    func test_getText_fullTextCappedAndBadIdSafe() {
        let snaps = [snap(1, "App", "W", String(repeating: "y", count: 10000))]
        XCTAssertLessThanOrEqual(I.executeGetText(snapshots: snaps, id: 0).count, I.fullTextChars + 100)
        XCTAssertTrue(I.executeGetText(snapshots: snaps, id: 7).hasPrefix("Error"))
        XCTAssertTrue(I.executeGetText(snapshots: snaps, id: -1).hasPrefix("Error"))
    }

    // MARK: - the loop

    func test_loop_investigateThenAdvise() async {
        let snaps = [snap(120, "Terminal", "zsh", "git stash push wip")]
        var rounds = 0
        let outcome = await I.run(snapshots: snaps, userPrompt: "ctx", transport: { messages, _ in
            rounds += 1
            if rounds == 1 {
                return I.ModelTurn(text: "", toolName: "search_screen_history",
                                   toolArgs: ["text_contains": "stash"],
                                   toolArgsRaw: #"{"text_contains":"stash"}"#, toolCallId: "c1")
            }
            // Round 2: the tool result from round 1 must be in the transcript.
            let hasToolResult = messages.contains { ($0["role"] as? String) == "tool" }
            XCTAssertTrue(hasToolResult)
            return I.ModelTurn(text: "", toolName: "provide_advice",
                               toolArgs: ["advice": "You stashed changes 2h ago — git stash pop",
                                          "category": "productivity", "source_app": "Terminal",
                                          "confidence": 0.9],
                               toolArgsRaw: "{}", toolCallId: "c2")
        })
        guard case let .advice(insight) = outcome else {
            return XCTFail("expected advice, got \(outcome)")
        }
        XCTAssertEqual(insight.confidence, 0.9)
        XCTAssertEqual(rounds, 2)
    }

    func test_loop_noAdviceEnds() async {
        let outcome = await I.run(snapshots: [], userPrompt: "ctx", transport: { _, _ in
            I.ModelTurn(text: "", toolName: "no_advice", toolArgs: ["context_summary": "quiet"],
                        toolArgsRaw: "{}", toolCallId: "c1")
        })
        XCTAssertEqual(outcome, .none(reason: "quiet"))
    }

    func test_loop_roundsExhausted() async {
        var rounds = 0
        let outcome = await I.run(snapshots: [snap(1, "A", "W", "t")], userPrompt: "ctx", transport: { _, _ in
            rounds += 1
            return I.ModelTurn(text: "", toolName: "search_screen_history", toolArgs: [:],
                               toolArgsRaw: "{}", toolCallId: "c\(rounds)")
        })
        XCTAssertEqual(rounds, I.maxRounds)
        XCTAssertEqual(outcome, .none(reason: "rounds exhausted (\(I.maxRounds))"))
    }

    func test_loop_bareTextAnswerSuppressed() async {
        // The model dodging tools = the old echo failure mode. Silence wins.
        let outcome = await I.run(snapshots: [], userPrompt: "ctx", transport: { _, _ in
            I.ModelTurn(text: "You should rerun failed agents", toolName: nil)
        })
        XCTAssertEqual(outcome, .none(reason: "no tool call in round 1"))
    }

    func test_loop_transportErrorGraceful() async {
        struct Boom: Error {}
        let outcome = await I.run(snapshots: [], userPrompt: "ctx", transport: { _, _ in throw Boom() })
        if case .none = outcome {} else { XCTFail("expected .none") }
    }

    func test_loop_malformedAdviceSuppressed() async {
        let outcome = await I.run(snapshots: [], userPrompt: "ctx", transport: { _, _ in
            I.ModelTurn(text: "", toolName: "provide_advice",
                        toolArgs: ["category": "other"], toolArgsRaw: "{}", toolCallId: "c1")
        })
        XCTAssertEqual(outcome, .none(reason: "malformed provide_advice args"))
    }

    func test_loop_unknownToolGetsErrorAndContinues() async {
        var rounds = 0
        let outcome = await I.run(snapshots: [], userPrompt: "ctx", transport: { messages, _ in
            rounds += 1
            if rounds == 1 {
                return I.ModelTurn(text: "", toolName: "hack_the_planet", toolArgs: [:],
                                   toolArgsRaw: "{}", toolCallId: "c1")
            }
            let toolMsg = messages.last { ($0["role"] as? String) == "tool" }
            XCTAssertTrue(((toolMsg?["content"] as? String) ?? "").hasPrefix("Error: unknown tool"))
            return I.ModelTurn(text: "", toolName: "no_advice", toolArgs: [:],
                               toolArgsRaw: "{}", toolCallId: "c2")
        })
        XCTAssertEqual(outcome, .none(reason: "no_advice"))
    }
}
