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

    /// Drives the mandatory investigation (search → successful get_screen_text)
    /// and then returns `final`. Advice is only reachable through this path.
    private func investigateThen(_ final: I.ModelTurn) -> I.Transport {
        var rounds = 0
        return { _, _ in
            rounds += 1
            switch rounds {
            case 1:
                return I.ModelTurn(text: "", toolName: "search_screen_history", toolArgs: [:],
                                   toolArgsRaw: "{}", toolCallId: "c1")
            case 2:
                return I.ModelTurn(text: "", toolName: "get_screen_text", toolArgs: ["id": 0],
                                   toolArgsRaw: "{}", toolCallId: "c2")
            default:
                return final
            }
        }
    }

    // MARK: - the loop

    func test_loop_investigateThenAdvise() async {
        let snaps = [snap(120, "Terminal", "zsh", "git stash push wip")]
        var rounds = 0
        let outcome = await I.run(snapshots: snaps, userPrompt: "ctx", transport: { messages, _ in
            rounds += 1
            switch rounds {
            case 1:
                return I.ModelTurn(text: "", toolName: "search_screen_history",
                                   toolArgs: ["text_contains": "stash"],
                                   toolArgsRaw: #"{"text_contains":"stash"}"#, toolCallId: "c1")
            case 2:
                // The tool result from round 1 must be in the transcript.
                XCTAssertTrue(messages.contains { ($0["role"] as? String) == "tool" })
                return I.ModelTurn(text: "", toolName: "get_screen_text",
                                   toolArgs: ["id": 0], toolArgsRaw: #"{"id":0}"#, toolCallId: "c2")
            default:
                return I.ModelTurn(text: "", toolName: "provide_advice",
                                   toolArgs: ["advice": "You stashed changes 2h ago — git stash pop",
                                              "category": "productivity", "source_app": "Terminal",
                                              "confidence": 0.9],
                                   toolArgsRaw: "{}", toolCallId: "c3")
            }
        })
        guard case let .advice(insight, _) = outcome else {
            return XCTFail("expected advice, got \(outcome)")
        }
        XCTAssertEqual(insight.confidence, 0.9)
        XCTAssertEqual(rounds, 3)
    }

    // MARK: - Codex 2026-08-10: advice REQUIRES a completed investigation

    func test_loop_adviceWithoutInvestigation_isNudgedNotAccepted() async {
        // The echo failure mode: the model skips investigation and comments on
        // the current screen. It must be pushed back to the tools, not surfaced.
        var rounds = 0
        var sawNudge = false
        let outcome = await I.run(snapshots: [snap(5, "App", "W", "text")], userPrompt: "ctx",
                                  transport: { messages, _ in
            rounds += 1
            if rounds == 1 {
                return I.ModelTurn(text: "", toolName: "provide_advice",
                                   toolArgs: ["advice": "Rerun the failed agents",
                                              "category": "other", "source_app": "App",
                                              "confidence": 0.95],
                                   toolArgsRaw: "{}", toolCallId: "c1")
            }
            let last = (messages.last?["content"] as? String) ?? ""
            if last.lowercased().contains("investigate") { sawNudge = true }
            return I.ModelTurn(text: "", toolName: "no_advice", toolArgs: [:],
                               toolArgsRaw: "{}", toolCallId: "c2")
        })
        XCTAssertTrue(sawNudge, "model must be told to investigate first")
        XCTAssertEqual(outcome, .none(reason: "no_advice"))
    }

    func test_loop_adviceAfterSearchButNoConfirmation_isNudged() async {
        // Snippet-only advice is explicitly forbidden by the prompt — the
        // model must confirm with get_screen_text before advising.
        var rounds = 0
        let outcome = await I.run(snapshots: [snap(5, "App", "W", "text")], userPrompt: "ctx",
                                  transport: { _, _ in
            rounds += 1
            switch rounds {
            case 1:
                return I.ModelTurn(text: "", toolName: "search_screen_history", toolArgs: [:],
                                   toolArgsRaw: "{}", toolCallId: "c1")
            default:
                return I.ModelTurn(text: "", toolName: "provide_advice",
                                   toolArgs: ["advice": "something", "category": "other",
                                              "source_app": "App", "confidence": 0.95],
                                   toolArgsRaw: "{}", toolCallId: "c\(rounds)")
            }
        })
        // Never accepted — the loop runs out of rounds instead.
        XCTAssertEqual(outcome, .none(reason: "rounds exhausted (\(I.maxRounds))"))
    }

    func test_loop_failedConfirmationDoesNotUnlockAdvice() async {
        // get_screen_text on a bad id returns an error — that is NOT a
        // confirmed read and must not unlock provide_advice.
        var rounds = 0
        let outcome = await I.run(snapshots: [snap(5, "App", "W", "text")], userPrompt: "ctx",
                                  transport: { _, _ in
            rounds += 1
            switch rounds {
            case 1:
                return I.ModelTurn(text: "", toolName: "search_screen_history", toolArgs: [:],
                                   toolArgsRaw: "{}", toolCallId: "c1")
            case 2:
                return I.ModelTurn(text: "", toolName: "get_screen_text", toolArgs: ["id": 999],
                                   toolArgsRaw: "{}", toolCallId: "c2")
            default:
                return I.ModelTurn(text: "", toolName: "provide_advice",
                                   toolArgs: ["advice": "x", "category": "other",
                                              "source_app": "App", "confidence": 0.95],
                                   toolArgsRaw: "{}", toolCallId: "c\(rounds)")
            }
        })
        XCTAssertEqual(outcome, .none(reason: "rounds exhausted (\(I.maxRounds))"))
    }

    // MARK: - Codex 2026-08-10: model-generated args must never crash the app

    func test_nonFiniteNumericArgs_doNotCrash() async {
        // `Double("NaN").map(Int.init)` traps. Tool args are model-generated
        // and may be anything.
        var rounds = 0
        let outcome = await I.run(snapshots: [snap(5, "App", "W", "text")], userPrompt: "ctx",
                                  transport: { _, _ in
            rounds += 1
            switch rounds {
            case 1:
                return I.ModelTurn(text: "", toolName: "search_screen_history",
                                   toolArgs: ["limit": "NaN", "minutes_back": "Infinity"],
                                   toolArgsRaw: "{}", toolCallId: "c1")
            case 2:
                return I.ModelTurn(text: "", toolName: "get_screen_text",
                                   toolArgs: ["id": "Infinity"], toolArgsRaw: "{}", toolCallId: "c2")
            case 3:
                return I.ModelTurn(text: "", toolName: "get_screen_text",
                                   toolArgs: ["id": 1e30], toolArgsRaw: "{}", toolCallId: "c3")
            default:
                return I.ModelTurn(text: "", toolName: "no_advice", toolArgs: [:],
                                   toolArgsRaw: "{}", toolCallId: "c4")
            }
        })
        XCTAssertEqual(outcome, .none(reason: "no_advice"))
    }

    func test_nonFiniteConfidence_suppressed() async {
        let outcome = await I.run(snapshots: [snap(5, "App", "W", "text")], userPrompt: "ctx",
                                  transport: investigateThen(
            I.ModelTurn(text: "", toolName: "provide_advice",
                        toolArgs: ["advice": "x", "confidence": "NaN"],
                        toolArgsRaw: "{}", toolCallId: "c3")))
        XCTAssertEqual(outcome, .none(reason: "malformed provide_advice args"))
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
        let outcome = await I.run(snapshots: [snap(5, "App", "W", "text")], userPrompt: "ctx",
                                  transport: investigateThen(
            I.ModelTurn(text: "", toolName: "provide_advice",
                        toolArgs: ["category": "other"], toolArgsRaw: "{}", toolCallId: "c3")))
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

    // MARK: - ITER-069 follow-up (Codex): one ref per retrieved RECORD

    func test_recordRefs_splitsJSONItemsIntoIndividualRefs() {
        let json = #"{"items":[{"id":"AAAA-1111","description":"Send deck to Sam","assignee":"Alex"},"#
            + #"{"id":"BBBB-2222","description":"Pay hosting invoice","dueAt":"2026-09-01T10:00:00Z"}],"count":2}"#
        let refs = I.recordRefs(prefix: "t", result: json)
        XCTAssertEqual(refs.count, 2)
        XCTAssertEqual(refs[0].id, "t0")
        XCTAssertEqual(refs[1].id, "t1")
        XCTAssertTrue(refs[0].text.contains("Send deck to Sam"))
        XCTAssertTrue(refs[0].text.contains("Alex"))
        XCTAssertTrue(refs[1].text.contains("2026-09-01"))
        // Scaffolding must not become quotable text: no JSON keys, no UUIDs.
        for ref in refs {
            XCTAssertFalse(ref.text.contains("AAAA"))
            XCTAssertFalse(ref.text.contains("BBBB"))
            XCTAssertFalse(ref.text.localizedCaseInsensitiveContains("count"))
            XCTAssertFalse(ref.text.contains("items"))
        }
    }

    func test_recordRefs_emptySearchResultIsNotEvidence() {
        // Before the split, {"items":[],"count":0} rode into the allowlist as a
        // ref — an empty search grounded nothing yet looked like it could.
        XCTAssertEqual(I.recordRefs(prefix: "t", result: #"{"items":[],"count":0}"#), [])
    }

    func test_recordRefs_nonJSONFallsBackToSingleRef() {
        let refs = I.recordRefs(prefix: "m", result: "plain text result")
        XCTAssertEqual(refs, [I.RetrievedRef(id: "m0", text: "plain text result")])
    }

    func test_recordRefs_malformedEnvelopeDoesNotResurrectScaffolding() {
        // Codex: {"items":null,"count":18} took the non-JSON fallback and rode
        // in whole — "18 overdue tasks" grounded against the scaffolding count.
        // Parseable JSON with a broken envelope is a broken result, not prose.
        XCTAssertEqual(I.recordRefs(prefix: "t", result: #"{"items":null,"count":18}"#), [])
        XCTAssertEqual(I.recordRefs(prefix: "t", result: #"{"count":18}"#), [])
        XCTAssertEqual(I.recordRefs(prefix: "t", result: #"{"items":"oops","count":2}"#), [])
        XCTAssertEqual(I.recordRefs(prefix: "t", result: #"[1,2,3]"#), [])
    }

    func test_recordRefs_numericAndBoolFieldsSurviveAsText() {
        // Codex: a record whose description arrived as a number vanished from
        // evidence entirely while the model had seen it — silencing an honest
        // claim about it as "ungrounded".
        let json = #"{"items":[{"id":"GGGG-7777","description":42,"assignee":"Ada"}],"count":1}"#
        let refs = I.recordRefs(prefix: "t", result: json)
        XCTAssertEqual(refs.count, 1)
        XCTAssertTrue(refs[0].text.contains("42"))
        XCTAssertTrue(refs[0].text.contains("Ada"))
    }

    func test_recordRefs_memoryFieldsJoined() {
        let json = #"{"items":[{"id":"CCCC-3333","headline":"Pricing decision","content":"Pro tier stays at $49"}],"count":1}"#
        let refs = I.recordRefs(prefix: "m", result: json)
        XCTAssertEqual(refs.count, 1)
        XCTAssertTrue(refs[0].text.contains("Pricing decision"))
        XCTAssertTrue(refs[0].text.contains("$49"))
    }

    func test_retrieval_countFieldCannotGroundAnInventedNumber() {
        // The scaffolding vulnerability end to end: a claim's anchor "8" must
        // not validate against the executor's "count": 8 — no record says 8.
        let json = #"{"items":[{"id":"DDDD-4444","description":"Review pull request"}],"count":8}"#
        let refs = I.recordRefs(prefix: "t", result: json)
        let (evidence, ids) = ScreenAgentCandidateAdapter.evidence(
            contextID: UUID(), ocrText: "unrelated screen", retrieved: refs)
        XCTAssertEqual(evidence.validate(citedIDs: ids, quotes: ["8"]),
                       .quoteNotInSource)
    }

    func test_loop_taskSearchProducesPerRecordRefs() async {
        let snaps = [snap(5, "Mail", "Inbox", "deck feedback thread")]
        var rounds = 0
        let outcome = await I.run(snapshots: snaps, userPrompt: "ctx", transport: { _, _ in
            rounds += 1
            switch rounds {
            case 1:
                return I.ModelTurn(text: "", toolName: "search_tasks",
                                   toolArgs: ["query": "deck"], toolArgsRaw: "{}", toolCallId: "c1")
            case 2:
                return I.ModelTurn(text: "", toolName: "search_screen_history", toolArgs: [:],
                                   toolArgsRaw: "{}", toolCallId: "c2")
            case 3:
                return I.ModelTurn(text: "", toolName: "get_screen_text", toolArgs: ["id": 0],
                                   toolArgsRaw: "{}", toolCallId: "c3")
            default:
                return I.ModelTurn(text: "", toolName: "provide_advice",
                                   toolArgs: ["advice": "You promised Sam the deck — the thread is open",
                                              "category": "productivity", "source_app": "Mail",
                                              "confidence": 0.8],
                                   toolArgsRaw: "{}", toolCallId: "c4")
            }
        }, searchTasks: { _ in
            #"{"items":[{"id":"EEEE-5555","description":"Send deck to Sam"},"#
                + #"{"id":"FFFF-6666","description":"Book flights"}],"count":2}"#
        })
        guard case let .advice(_, retrieved) = outcome else {
            return XCTFail("expected advice, got \(outcome)")
        }
        XCTAssertEqual(retrieved.map(\.id), ["t0", "t1"])
        XCTAssertEqual(retrieved[0].text, "Send deck to Sam")
    }
}
