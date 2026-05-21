import XCTest
@testable import MetaWhisp

/// Regression tests for `MeetingCoachService.parseSuggestion(_:)`.
///
/// 2026-05-21 crash repro: user's app died with
///     `Fatal error: Range requires lowerBound <= upperBound`
/// when the LLM coach returned a string where `}` appeared BEFORE the first
/// `{` and no closing `}` followed. The permissive fallback used
/// `cleaned[firstIndex("{") ... lastIndex("}")]`, which on such input
/// constructs a reversed Range and SIGTRAPs.
///
/// The fix added a `start <= end` guard. These tests pin both the crash
/// repro AND the cases that must keep working.
///
/// `MeetingCoachService` is `@MainActor` (singleton, observes `MainActor`-
/// isolated state), so the test class is `@MainActor` too — that lets us
/// call `parseSuggestion` synchronously without async hops.
@MainActor
final class MeetingCoachServiceTests: XCTestCase {

    private var svc: MeetingCoachService { MeetingCoachService.shared }

    // MARK: - Crash repros (would SIGTRAP before the fix)

    func test_parseSuggestion_doesNotCrashWhenCloseBraceBeforeOpenBrace() {
        // `}` at position 18, first `{` at position 35 — reversed Range
        // unless we guard. Should return nil, NOT crash.
        let bad = "Cannot answer that } here is { not valid"
        _ = svc.parseSuggestion(bad)  // assertion: returns without crashing
    }

    func test_parseSuggestion_doesNotCrashWithStrayCloseBraceAndOpenWithoutClose() {
        let bad = "preamble text } followed by { \"type\": \"question\""
        _ = svc.parseSuggestion(bad)
    }

    func test_parseSuggestion_doesNotCrashOnSingleStrayCloseBrace() {
        // Edge case: `}` exists but no `{` — firstIndex returns nil, skips
        // the slice path entirely. Still must not crash.
        _ = svc.parseSuggestion("just a } here")
    }

    func test_parseSuggestion_doesNotCrashOnEmptyString() {
        _ = svc.parseSuggestion("")
    }

    func test_parseSuggestion_doesNotCrashOnNullString() {
        XCTAssertNil(svc.parseSuggestion("null"))
        XCTAssertNil(svc.parseSuggestion("NULL"))
    }

    // MARK: - Happy paths (must still parse correctly)

    func test_parseSuggestion_parsesPlainJSON() {
        let raw = #"{"type": "question", "text": "What about the timeline?"}"#
        let result = svc.parseSuggestion(raw)
        XCTAssertEqual(result?.kind, .question)
        XCTAssertEqual(result?.text, "What about the timeline?")
    }

    func test_parseSuggestion_stripsMarkdownFences() {
        let raw = """
        ```json
        {"type": "attention", "text": "Speaker losing focus"}
        ```
        """
        let result = svc.parseSuggestion(raw)
        XCTAssertEqual(result?.kind, .attention)
        XCTAssertEqual(result?.text, "Speaker losing focus")
    }

    func test_parseSuggestion_extractsJSONFromPreamble() {
        // Permissive fallback: model added preamble + valid JSON window.
        let raw = "Sure, here is the suggestion: {\"type\": \"missed\", \"text\": \"Mentioned deadline\"} hope that helps."
        let result = svc.parseSuggestion(raw)
        XCTAssertEqual(result?.kind, .missed)
        XCTAssertEqual(result?.text, "Mentioned deadline")
    }

    func test_parseSuggestion_mapsAllKinds() {
        for (input, expected) in [
            ("question",  MeetingCoachState.Suggestion.Kind.question),
            ("attention", .attention),
            ("missed",    .missed),
            ("followup",  .followUp),
            ("follow_up", .followUp),
            ("follow-up", .followUp),
        ] as [(String, MeetingCoachState.Suggestion.Kind)] {
            let raw = "{\"type\": \"\(input)\", \"text\": \"x\"}"
            XCTAssertEqual(svc.parseSuggestion(raw)?.kind, expected, "kind mapping for '\(input)'")
        }
    }

    func test_parseSuggestion_unknownKindReturnsNil() {
        let raw = #"{"type": "gibberish", "text": "x"}"#
        XCTAssertNil(svc.parseSuggestion(raw))
    }
}
