import XCTest
@testable import MetaWhisp

/// Pure-function tests for `ConversationTitleResolver.resolve(...)`.
///
/// History: 2026-05-07 user observed calendar event "Standup C" being
/// overwritten in the Library by an LLM-hallucinated title "Discussing Project
/// Updates And Marketing". `StructuredGenerator` was unconditionally setting
/// `conv.title = parsed.title` from LLM output, ignoring the calendar event
/// name even when it had been linked to the conversation.
///
/// Resolver gives calendar title priority: user's own naming in the calendar
/// is authoritative — what they wrote there is what they expect to see.
final class ConversationTitleResolverTests: XCTestCase {

    /// User's calendar event has a clear name → it wins, LLM title discarded.
    func test_calendarTitleWinsOverLLM() {
        let result = ConversationTitleResolver.resolve(
            calendarEventTitle: "Standup C",
            llmTitle: "Discussing Project Updates And Marketing"
        )
        XCTAssertEqual(result, "Standup C")
    }

    /// No calendar event linked (manual recording or no permission) → LLM
    /// title is used as before.
    func test_nilCalendarFallsBackToLLM() {
        let result = ConversationTitleResolver.resolve(
            calendarEventTitle: nil,
            llmTitle: "Q3 Planning Session"
        )
        XCTAssertEqual(result, "Q3 Planning Session")
    }

    /// Calendar linked but the event title is an empty string (e.g. event
    /// was created without a title) → fall back to LLM rather than show
    /// an empty conversation title.
    func test_emptyCalendarFallsBackToLLM() {
        let result = ConversationTitleResolver.resolve(
            calendarEventTitle: "",
            llmTitle: "Stand Up Discussion"
        )
        XCTAssertEqual(result, "Stand Up Discussion")
    }
}
