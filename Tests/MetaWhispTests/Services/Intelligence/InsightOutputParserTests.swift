import XCTest
@testable import MetaWhisp

/// Pure-function tests for `InsightOutputParser.parse(jsonString:)`.
///
/// History (ITER-027.1, 2026-05-09): porting reference Omi's InsightAssistant
/// pattern. The LLM response can be either a `provide_advice` tool call
/// (yielding an actionable insight) or a `no_advice` tool call (model decided
/// nothing worth surfacing). We must reject malformed JSON, missing required
/// fields, and out-of-range confidence values without surfacing garbage.
final class InsightOutputParserTests: XCTestCase {

    // MARK: - Happy paths

    /// Standard `provide_advice` payload with all required fields → returns
    /// a fully-populated insight.
    func test_parsesProvideAdviceComplete() {
        let json = """
        {
          "tool": "provide_advice",
          "advice": "You stashed changes 2 hours ago — remember to git stash pop",
          "headline": "Stash from 2h ago",
          "reasoning": "User shows git output with old stash entry",
          "category": "productivity",
          "source_app": "Terminal",
          "confidence": 0.92
        }
        """
        let result = InsightOutputParser.parse(jsonString: json)
        guard case let .provideInsight(ins) = result else {
            return XCTFail("expected provideInsight, got \(result)")
        }
        XCTAssertEqual(ins.body, "You stashed changes 2 hours ago — remember to git stash pop")
        XCTAssertEqual(ins.headline, "Stash from 2h ago")
        XCTAssertEqual(ins.confidence, 0.92, accuracy: 0.001)
        XCTAssertEqual(ins.category, "productivity")
        XCTAssertEqual(ins.sourceApp, "Terminal")
    }

    /// `no_advice` tool call → returns `.noInsight` with the reason.
    func test_parsesNoAdvice() {
        let json = """
        {
          "tool": "no_advice",
          "context_summary": "User reading documentation",
          "current_activity": "browsing"
        }
        """
        XCTAssertEqual(
            InsightOutputParser.parse(jsonString: json),
            .noInsight(reason: "User reading documentation")
        )
    }

    /// Optional fields (headline, reasoning) absent → still valid insight.
    func test_parsesProvideAdviceMinimal() {
        let json = """
        {
          "tool": "provide_advice",
          "advice": "Tokens expiring tomorrow",
          "category": "other",
          "source_app": "Terminal",
          "confidence": 0.88
        }
        """
        guard case let .provideInsight(ins) = InsightOutputParser.parse(jsonString: json) else {
            return XCTFail("expected provideInsight")
        }
        XCTAssertNil(ins.headline)
        XCTAssertNil(ins.reasoning)
        XCTAssertEqual(ins.body, "Tokens expiring tomorrow")
    }

    // MARK: - Rejection paths

    /// Malformed JSON → parseError, no insight surfaced.
    func test_rejectsMalformedJSON() {
        XCTAssertEqual(
            InsightOutputParser.parse(jsonString: "{not json"),
            .parseError
        )
    }

    /// Tool field missing entirely → parseError.
    func test_rejectsMissingTool() {
        XCTAssertEqual(
            InsightOutputParser.parse(jsonString: "{\"advice\":\"foo\"}"),
            .parseError
        )
    }

    /// `provide_advice` with missing required `advice` field → parseError.
    func test_rejectsProvideAdviceWithoutBody() {
        let json = """
        {"tool":"provide_advice","category":"other","source_app":"X","confidence":0.9}
        """
        XCTAssertEqual(
            InsightOutputParser.parse(jsonString: json),
            .parseError
        )
    }

    /// Confidence out of [0, 1] → rejected as parseError. Prevents the model
    /// from gaming the confidence gate by returning > 1.0.
    func test_rejectsConfidenceOutOfRange() {
        let json = """
        {"tool":"provide_advice","advice":"x","category":"other","source_app":"X","confidence":1.5}
        """
        XCTAssertEqual(
            InsightOutputParser.parse(jsonString: json),
            .parseError
        )
        let json2 = """
        {"tool":"provide_advice","advice":"x","category":"other","source_app":"X","confidence":-0.1}
        """
        XCTAssertEqual(
            InsightOutputParser.parse(jsonString: json2),
            .parseError
        )
    }

    /// Empty body string → parseError (no useful insight).
    func test_rejectsEmptyAdviceBody() {
        let json = """
        {"tool":"provide_advice","advice":"   ","category":"other","source_app":"X","confidence":0.9}
        """
        XCTAssertEqual(
            InsightOutputParser.parse(jsonString: json),
            .parseError
        )
    }

    /// Unknown tool name → noInsight (treat as the model declining).
    func test_unknownToolTreatedAsNoInsight() {
        let json = """
        {"tool":"unknown_thing","advice":"x"}
        """
        if case .noInsight = InsightOutputParser.parse(jsonString: json) {
            // OK
        } else {
            XCTFail("expected noInsight for unknown tool")
        }
    }
}
