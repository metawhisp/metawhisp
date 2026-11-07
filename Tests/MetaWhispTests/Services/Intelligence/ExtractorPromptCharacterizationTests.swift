import XCTest
@testable import MetaWhisp

/// ITER-081 step 0 — today's prompts, pinned before the extractors learn to
/// read a whole long conversation. A conversation that fits in one prompt
/// must keep getting exactly this text, on every route.
@MainActor
final class ExtractorPromptCharacterizationTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!   // its identifier reads "GMT" on macOS
    private let started = Date(timeIntervalSince1970: 1_793_523_600)   // 2026-11-01T09:00:00Z
    private let now = Date(timeIntervalSince1970: 1_793_527_200)       // 2026-11-01T10:00:00Z

    private let fragments = [
        "Let's meet on Monday to go over the budget.",
        "I will send the revised deck to Alex by Friday.",
        "Sam asked me to book the venue."
    ]

    private func existingTasks() -> [TaskItem] {
        let first = TaskItem(taskDescription: "Call the dentist")
        let second = TaskItem(taskDescription: "Send the deck to Alex",
                              dueAt: Date(timeIntervalSince1970: 1_793_725_200))   // 2026-11-03T17:00:00Z
        second.completed = true
        return [first, second]
    }

    private var calendar: TaskExtractor.CalendarMeetingContext {
        TaskExtractor.CalendarMeetingContext(title: "Weekly sync",
                                             startDate: Date(timeIntervalSince1970: 1_793_523_600),
                                             endDate: Date(timeIntervalSince1970: 1_793_527_200),
                                             attendees: ["Sam", "Alex"])
    }

    private let expectedTaskPrompt = """
    Conversation started_at: 2026-11-01T09:00:00Z
    Current time: 2026-11-01T10:00:00Z
    Timezone: GMT
    REFERENCE_TIME = started_at (recent conversation, anchor due-dates here)

    CALENDAR MEETING CONTEXT:
    - Title: Weekly sync
    - Scheduled: 2026-11-01 09:00 GMT → 2026-11-01 10:00 GMT
    - Participants: Sam, Alex

    EXISTING ACTION ITEMS FROM PAST 2 DAYS (do NOT duplicate):
    - Call the dentist (due: no due) [pending]
    - Send the deck to Alex (due: 2026-11-03T17:00:00Z) [completed]

    Conversation fragments to analyze (ordered by time, all from the same user):
    --- fragment 1 ---
    Let's meet on Monday to go over the budget.
    --- fragment 2 ---
    I will send the revised deck to Alex by Friday.
    --- fragment 3 ---
    Sam asked me to book the venue.
    """

    func testTaskPromptOnTheCloudRoutesIsUnchanged() {
        for route in [ExtractionRoute.pro(licenseKey: "k"), .byok] {
            let prompt = TaskExtractor().buildPrompt(fragments: fragments, existing: existingTasks(),
                                                     startedAt: started, calendarContext: calendar,
                                                     route: route, now: now, timeZone: utc)
            XCTAssertEqual(prompt, expectedTaskPrompt, "\(route)")
        }
    }

    func testTaskPromptOnTheLocalRouteIsUnchangedWhenItFits() {
        let prompt = TaskExtractor().buildPrompt(fragments: fragments, existing: existingTasks(),
                                                 startedAt: started, calendarContext: calendar,
                                                 route: .local, now: now, timeZone: utc)
        XCTAssertEqual(prompt, expectedTaskPrompt)
    }

    private let expectedMemoryPrompt = """
    Existing memories you already know about User (DO NOT repeat or duplicate):
    - User lives in Lisbon
    - User prefers morning meetings

    Conversation fragments to analyze (ordered by time, all from the same User):
    --- fragment 1 ---
    Let's meet on Monday to go over the budget.
    --- fragment 2 ---
    I will send the revised deck to Alex by Friday.
    --- fragment 3 ---
    Sam asked me to book the venue.
    """

    private func existingMemories() -> [UserMemory] {
        [UserMemory(content: "User lives in Lisbon", category: "system", sourceApp: "test", confidence: 0.9),
         UserMemory(content: "User prefers morning meetings", category: "system", sourceApp: "test", confidence: 0.9)]
    }

    func testMemoryPromptOnTheCloudRoutesIsUnchanged() {
        for route in [ExtractionRoute.pro(licenseKey: "k"), .byok] {
            let prompt = MemoryExtractor().buildPrompt(fragments: fragments, existing: existingMemories(),
                                                       route: route)
            XCTAssertEqual(prompt, expectedMemoryPrompt, "\(route)")
        }
    }

    func testMemoryPromptOnTheLocalRouteIsUnchangedWhenItFits() {
        let prompt = MemoryExtractor().buildPrompt(fragments: fragments, existing: existingMemories(),
                                                   route: .local)
        XCTAssertEqual(prompt, expectedMemoryPrompt)
    }
}
