import XCTest
@testable import MetaWhisp

/// ITER-075 step 1, US-1.1 — a recurring meeting's end is the current
/// occurrence's, never the series' first. Dates are fixed instants, so no time
/// zone is involved.
final class CalendarOccurrenceTests: XCTestCase {

    /// 2026-09-25 10:00 UTC, a weekly meeting's occurrence of that day.
    private let today = Date(timeIntervalSince1970: 1_790_330_400)
    private let minute: TimeInterval = 60

    private func occurrence(_ id: String = "series-1", start: Date, minutes: Double = 30,
                            title: String? = "Weekly sync") -> CalendarOccurrence {
        CalendarOccurrence(eventID: id, title: title, start: start, end: start.addingTimeInterval(minutes * minute))!
    }

    private func candidate(_ occurrence: CalendarOccurrence, allDay: Bool = false, canceled: Bool = false,
                           declined: Bool = false) -> CalendarCandidate {
        CalendarCandidate(occurrence: occurrence, isAllDay: allDay, isCanceled: canceled, declinedByMe: declined)
    }

    func testAnOccurrenceNeedsAnIDAndItsDates() {
        XCTAssertNil(CalendarOccurrence(eventID: nil, title: "A", start: today, end: today))
        XCTAssertNil(CalendarOccurrence(eventID: "", title: "A", start: today, end: today))
        XCTAssertNil(CalendarOccurrence(eventID: "x", title: "A", start: nil, end: today))
        XCTAssertEqual(CalendarOccurrence(eventID: "x", title: "  ", start: today, end: today)?.title, "Meeting")
    }

    /// Two occurrences of one series share the series id but not the key.
    func testEachOccurrenceOfASeriesHasItsOwnKey() {
        let first = occurrence(start: Date(timeIntervalSince1970: 1_764_928_800))   // 2025-12-05 10:00 UTC
        let current = occurrence(start: today)
        XCTAssertEqual(first.eventID, current.eventID)
        XCTAssertNotEqual(first.key, current.key)
    }

    /// The meeting running now is today's occurrence, with today's end, even
    /// when EventKit also lists the series' earlier occurrences.
    func testTheRunningMeetingIsTodaysOccurrenceWithTodaysEnd() {
        let first = occurrence(start: Date(timeIntervalSince1970: 1_764_928_800))       // 2025-12-05
        let lastWeek = occurrence(start: today.addingTimeInterval(-7 * 24 * 3600))
        let current = occurrence(start: today)
        let all = [candidate(first), candidate(lastWeek), candidate(current)]
        let running = CalendarOccurrencePicker.running(in: all, at: today.addingTimeInterval(5 * minute))
        XCTAssertEqual(running, current)
        XCTAssertEqual(running?.end, today.addingTimeInterval(30 * minute))
        XCTAssertEqual(CalendarOccurrencePicker.startingNow(in: all, at: today.addingTimeInterval(30)), current)
    }

    func testAllDayCanceledAndDeclinedEventsDoNotCount() {
        let now = today.addingTimeInterval(5 * minute)
        for excluded in [candidate(occurrence(start: today), allDay: true),
                         candidate(occurrence(start: today), canceled: true),
                         candidate(occurrence(start: today), declined: true)] {
            XCTAssertNil(CalendarOccurrencePicker.running(in: [excluded], at: now))
            XCTAssertNil(CalendarOccurrencePicker.startingNow(in: [excluded], at: now))
        }
    }

    /// Overlapping calendars: the occurrence that started last is the one the owner is in.
    func testTheLatestStartWinsAmongOverlaps() {
        let earlier = occurrence("series-1", start: today)
        let later = occurrence("series-2", start: today.addingTimeInterval(10 * minute))
        let now = today.addingTimeInterval(15 * minute)
        XCTAssertEqual(CalendarOccurrencePicker.running(in: [candidate(later), candidate(earlier)], at: now), later)
    }

    /// The same meeting in two calendars starts at the same time: the pick
    /// must not depend on the order EventKit lists them in, or a live
    /// recording would look like a new meeting on the next tick.
    func testTheSameStartPicksTheSameOccurrenceInAnyOrder() {
        let one = candidate(occurrence("calendar-a", start: today))
        let other = candidate(occurrence("calendar-b", start: today))
        let now = today.addingTimeInterval(30)
        XCTAssertEqual(CalendarOccurrencePicker.running(in: [one, other], at: now),
                       CalendarOccurrencePicker.running(in: [other, one], at: now))
        XCTAssertEqual(CalendarOccurrencePicker.startingNow(in: [one, other], at: now),
                       CalendarOccurrencePicker.startingNow(in: [other, one], at: now))
    }

    /// ITER-083 — what the calendar calls the event, kept apart from the word
    /// the countdown card shows: an event without a title is saved without
    /// one, so the meeting's own title is used, not the word "Meeting".
    func testTheRawTitleIsWhatTheCalendarSays() {
        XCTAssertEqual(occurrence(start: today, title: "  Weekly sync ").rawTitle, "Weekly sync")
        XCTAssertNil(occurrence(start: today, title: "   ").rawTitle)
        XCTAssertNil(occurrence(start: today, title: nil).rawTitle)
        XCTAssertEqual(occurrence(start: today, title: nil).title, "Meeting", "the card still has a word")
        XCTAssertEqual(occurrence(start: today, title: "Busy").rawTitle, "Busy", "as the calendar shows it")
    }

    func testAttendeesTravelWithTheOccurrence() {
        let o = CalendarOccurrence(eventID: "x", title: "A", start: today, end: today.addingTimeInterval(60),
                                   attendees: ["Sam", "alex@example.com"])
        XCTAssertEqual(o?.attendees, ["Sam", "alex@example.com"])
        XCTAssertEqual(CalendarOccurrence(eventID: "x", title: "A", start: today, end: today)?.attendees, [])
    }

    /// ITER-083 — the gate and the back-to-back check are told an occurrence,
    /// not a series: with the series id, one day's refusal, attempts and
    /// boundary carried into the next day's meeting of the same series.
    func testTheGateIdentityIsTheOccurrence() {
        let monday = occurrence(start: today)
        let tuesday = occurrence(start: today.addingTimeInterval(24 * 3600))
        XCTAssertEqual(monday.gateEvent.id, monday.key)
        XCTAssertNotEqual(monday.gateEvent.id, tuesday.gateEvent.id)
        XCTAssertEqual(monday.gateEvent.title, monday.title)
    }

    func testStartingNowOnlyInItsFirst65Seconds() {
        let current = occurrence(start: today)
        XCTAssertEqual(CalendarOccurrencePicker.startingNow(in: [candidate(current)], at: today.addingTimeInterval(65)),
                       current)
        XCTAssertNil(CalendarOccurrencePicker.startingNow(in: [candidate(current)], at: today.addingTimeInterval(66)),
                     "past the 65 s window it is running, not starting")
        XCTAssertNil(CalendarOccurrencePicker.startingNow(in: [candidate(current)], at: today.addingTimeInterval(-1)),
                     "not started yet")
    }
}
