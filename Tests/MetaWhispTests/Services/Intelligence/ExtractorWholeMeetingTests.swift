import XCTest
@testable import MetaWhisp

/// ITER-081 — the end of a long meeting reaches the model. The cloud prompt
/// used to be cut from the head at 20,000 characters, so tasks and memories
/// said near the end of a long call were never extracted.
@MainActor
final class ExtractorWholeMeetingTests: XCTestCase {

    private let started = Date(timeIntervalSince1970: 1_793_523_600)
    private let endMarker = "FINAL-DECISION: Sam cancels the vendor call."

    /// `count` fragments of about `each` characters; the last one ends with the marker.
    private func meeting(count: Int, each: Int) -> [String] {
        let sentence = "We reviewed the budget line by line. "
        return (1...count).map { i in
            let body = String(repeating: sentence, count: max(1, each / sentence.count))
            return i == count ? body + endMarker : body
        }
    }

    private func taskPrompt(_ fragments: [String], route: ExtractionRoute,
                            existing: [TaskItem] = [],
                            calendar: TaskExtractor.CalendarMeetingContext? = nil) -> String {
        TaskExtractor().buildPrompt(fragments: fragments, existing: existing, startedAt: started,
                                    calendarContext: calendar, route: route, now: started)
    }

    private func memoryPrompt(_ fragments: [String], route: ExtractionRoute, existing: [UserMemory] = []) -> String {
        MemoryExtractor().buildPrompt(fragments: fragments, existing: existing, route: route)
    }

    private let pro = ExtractionRoute.pro(licenseKey: "k")

    // MARK: - Tasks

    func testProSendsAWholeLongMeeting() {
        let fragments = meeting(count: 40, each: 1_125)   // about 45,000 characters
        let prompt = taskPrompt(fragments, route: pro)
        XCTAssertLessThanOrEqual(prompt.utf16.count, 128_000)
        XCTAssertFalse(prompt.contains(PromptFit.omissionMarker))
        for (i, fragment) in fragments.enumerated() {
            XCTAssertTrue(prompt.contains("--- fragment \(i + 1) ---\n" + fragment), "fragment \(i + 1)")
        }
        XCTAssertTrue(prompt.hasSuffix(endMarker))
    }

    func testProOverItsLimitKeepsTheStartAndTheEnd() {
        let prompt = taskPrompt(meeting(count: 160, each: 1_250), route: pro)   // about 200,000 characters
        XCTAssertLessThanOrEqual(prompt.utf16.count, 128_000)
        XCTAssertTrue(prompt.contains("--- fragment 1 ---"))
        XCTAssertTrue(prompt.contains(PromptFit.omissionMarker))
        XCTAssertTrue(prompt.hasSuffix(endMarker))
    }

    func testOwnKeyKeepsTodaysSizeAndNowTheEnd() {
        let prompt = taskPrompt(meeting(count: 40, each: 1_125), route: .byok)
        XCTAssertLessThanOrEqual(prompt.utf16.count, 20_000)
        XCTAssertTrue(prompt.contains("--- fragment 1 ---"))
        XCTAssertTrue(prompt.hasSuffix(endMarker))
    }

    func testEmojiStayWithinTheUnitsTheProxyCounts() {
        let fragments = [String(repeating: "\u{1F600}", count: 100_000) + endMarker]
        for route in [pro, ExtractionRoute.byok] {
            let prompt = taskPrompt(fragments, route: route)
            XCTAssertLessThanOrEqual(prompt.utf16.count, route.unitLimit, "\(route)")
            XCTAssertTrue(prompt.hasSuffix(endMarker), "\(route)")
        }
    }

    /// The largest header anything can produce still leaves the transcript room.
    func testAHugeCalendarAndTaskListCannotCrowdOutTheMeeting() {
        let calendar = TaskExtractor.CalendarMeetingContext(
            title: String(repeating: "Quarterly planning ", count: 600),
            startDate: started, endDate: started.addingTimeInterval(3_600),
            attendees: (1...300).map { "Attendee number \($0) of the company" })
        let existing = (1...200).map { TaskItem(taskDescription: "Task \($0) " + String(repeating: "x", count: 400)) }
        for route in [pro, ExtractionRoute.byok] {
            let prompt = taskPrompt(meeting(count: 40, each: 1_125), route: route, existing: existing, calendar: calendar)
            XCTAssertLessThanOrEqual(prompt.utf16.count, route.unitLimit, "\(route)")
            XCTAssertTrue(prompt.contains("Conversation fragments to analyze"), "\(route)")
            XCTAssertTrue(prompt.contains("--- fragment 1 ---"), "\(route)")
            XCTAssertTrue(prompt.hasSuffix(endMarker), "\(route)")
            XCTAssertTrue(prompt.contains("more omitted)"), "\(route)")
            XCTAssertTrue(prompt.contains("…\n- Scheduled:"), "\(route): the title is cut and says so")
            XCTAssertTrue(prompt.contains("more)\n"), "\(route): the attendee list says how many are left out")
        }
    }

    /// A header entry can be one Character and thousands of units; it is
    /// measured in units, so it cannot push the meeting out of the prompt.
    func testOversizedCharactersInTheHeaderCannotPushTheMeetingOut() {
        let heavy = "a" + String(repeating: "\u{0301}", count: 150_000)   // one Character, 150,001 units
        let calendar = TaskExtractor.CalendarMeetingContext(title: heavy, startDate: started,
                                                            endDate: started.addingTimeInterval(3_600),
                                                            attendees: [heavy, "Sam"])
        let existing = [TaskItem(taskDescription: heavy), TaskItem(taskDescription: "Call the dentist")]
        for route in [pro, ExtractionRoute.byok] {
            let prompt = taskPrompt(meeting(count: 40, each: 1_125), route: route, existing: existing, calendar: calendar)
            XCTAssertLessThanOrEqual(prompt.utf16.count, route.unitLimit, "\(route)")
            XCTAssertTrue(prompt.contains("Conversation fragments to analyze"), "\(route)")
            XCTAssertTrue(prompt.contains("--- fragment 1 ---"), "\(route)")
            XCTAssertTrue(prompt.hasSuffix(endMarker), "\(route)")
        }
    }

    /// The bounded calendar text is visible on a short meeting too: an overlong
    /// title is cut and says so; the transcript stays whole.
    func testAShortMeetingWithAnOverlongTitleKeepsItsTranscriptWhole() {
        let calendar = TaskExtractor.CalendarMeetingContext(title: String(repeating: "t", count: 700), startDate: started,
                                                            endDate: started.addingTimeInterval(3_600), attendees: ["Sam"])
        let fragments = ["Sam asked me to book the venue."]
        let prompt = taskPrompt(fragments, route: pro, calendar: calendar)
        XCTAssertTrue(prompt.contains("- Title: " + String(repeating: "t", count: 600) + "…\n"))
        XCTAssertTrue(prompt.hasSuffix("--- fragment 1 ---\nSam asked me to book the venue."))
    }

    /// The local route is unchanged: 70% head, 30% tail around its own marker.
    func testTheLocalRouteStillKeepsItsHeadAndTail() {
        let prompt = taskPrompt(meeting(count: 40, each: 1_125), route: .local)
        XCTAssertTrue(prompt.contains("\n[…middle omitted…]\n"))
        XCTAssertTrue(prompt.contains("--- fragment 1 ---"))
        XCTAssertTrue(prompt.hasSuffix(endMarker))
        XCTAssertFalse(prompt.contains(PromptFit.omissionMarker))
    }

    // MARK: - Memories

    func testMemoriesOnProReadTheWholeLongConversation() {
        let fragments = meeting(count: 40, each: 1_125)
        let prompt = memoryPrompt(fragments, route: pro)
        XCTAssertLessThanOrEqual(prompt.utf16.count, 128_000)
        XCTAssertFalse(prompt.contains(PromptFit.omissionMarker))
        XCTAssertTrue(prompt.contains("--- fragment 40 ---"))
        XCTAssertTrue(prompt.hasSuffix(endMarker))
    }

    func testMemoriesOverTheLimitAndOnOwnKeyKeepTheEnd() {
        let cases: [(ExtractionRoute, [String])] = [(pro, meeting(count: 160, each: 1_250)),
                                                    (.byok, meeting(count: 40, each: 1_125))]
        for (route, fragments) in cases {
            let prompt = memoryPrompt(fragments, route: route)
            XCTAssertLessThanOrEqual(prompt.utf16.count, route.unitLimit, "\(route)")
            XCTAssertTrue(prompt.contains("--- fragment 1 ---"), "\(route)")
            XCTAssertTrue(prompt.contains(PromptFit.omissionMarker), "\(route)")
            XCTAssertTrue(prompt.hasSuffix(endMarker), "\(route)")
        }
    }

    func testAnOversizedKnownFactCannotPushTheConversationOut() {
        let combining = "a" + String(repeating: "\u{0301}", count: 150_000)   // one Character, 150,001 units
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"   // one Character, 11 units
        let existing = [combining, String(repeating: family, count: 2_000), "User lives in Lisbon"].map {
            UserMemory(content: $0, category: "system", sourceApp: "test", confidence: 0.9)
        }
        for route in [pro, ExtractionRoute.byok] {
            let prompt = memoryPrompt(meeting(count: 40, each: 1_125), route: route, existing: existing)
            XCTAssertLessThanOrEqual(prompt.utf16.count, route.unitLimit, "\(route)")
            XCTAssertTrue(prompt.contains("Conversation fragments to analyze"), "\(route)")
            XCTAssertTrue(prompt.contains("--- fragment 1 ---"), "\(route)")
            XCTAssertTrue(prompt.hasSuffix(endMarker), "\(route)")
            XCTAssertTrue(prompt.contains("omitted for space)"), "\(route)")
        }
    }

    func testAThousandKnownFactsCannotCrowdOutTheConversation() {
        let existing = (1...1_000).map {
            UserMemory(content: "User fact \($0) " + String(repeating: "y", count: 100), category: "system",
                       sourceApp: "test", confidence: 0.9)
        }
        let fragments = [String(repeating: "\u{1F600}", count: 30_000) + endMarker]
        for route in [pro, ExtractionRoute.byok] {
            let prompt = memoryPrompt(fragments, route: route, existing: existing)
            XCTAssertLessThanOrEqual(prompt.utf16.count, route.unitLimit, "\(route)")
            XCTAssertTrue(prompt.contains("omitted for space)"), "\(route)")
            XCTAssertTrue(prompt.hasSuffix(endMarker), "\(route)")
        }
    }
}
