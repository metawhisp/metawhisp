import XCTest
import SwiftData
@testable import MetaWhisp

/// ITER-083 I1 — a saved meeting takes its event, its call name and its real
/// times from its own recording. Before, the grouper got a call name the next
/// recording had already overwritten, bounds back-dated from the save time, and
/// no event at all: the event was guessed afterwards by time overlap, which
/// failed for every call that ran past its slot (0 of 9 dailies named in a week).
@MainActor
final class MeetingRecordingAssignTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_330_400)   // 2026-09-25 10:00 UTC
    private var container: ModelContainer!
    private var grouper: ConversationGrouper!

    override func setUp() async throws {
        container = try ModelContainer(for: Schema([HistoryItem.self, Conversation.self]),
                                       configurations: [ModelConfiguration("Test", isStoredInMemoryOnly: true)])
        grouper = ConversationGrouper()
        grouper.configure(modelContainer: container)
    }

    private func occurrence(_ id: String, title: String?, at start: Date, attendees: [String] = []) -> CalendarOccurrence {
        CalendarOccurrence(eventID: id, title: title, start: start, end: start.addingTimeInterval(1500),
                           attendees: attendees)!
    }

    /// A meeting part as the save path makes it: saved some time after the stop.
    private func savedPart(_ text: String, savedAt: Date) throws -> HistoryItem {
        let ctx = ModelContext(container)
        let item = HistoryItem(text: text, language: "en", audioDuration: 60, processingTime: 1)
        item.createdAt = savedAt
        ctx.insert(item)
        try ctx.save()
        item.source = "meeting"
        return item
    }

    private func stored(_ id: UUID) throws -> Conversation {
        try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Conversation>()).first { $0.id == id })
    }

    func testACalendarMeetingIsSavedWithItsOwnEvent() throws {
        let event = occurrence("daily", title: "Daily Sync", at: start, attendees: ["Sam", "Alex"])
        let stop = start.addingTimeInterval(37 * 60)              // ran 12 min past its 25-min slot
        let recording = RecordingContext.calendar(event, startedAt: start).stopped(at: stop)
        let item = try savedPart("Sam: the release is on Friday.", savedAt: stop.addingTimeInterval(90))

        // The audio's length, as the save path passes it too.
        let conv = try stored(XCTUnwrap(grouper.assign(historyItem: item, recording: recording,
                                                       meetingDurationSec: 37 * 60)).id)

        XCTAssertEqual(conv.calendarEventId, "daily")
        XCTAssertEqual(conv.calendarOccurrenceKey, event.key)
        XCTAssertEqual(conv.calendarEventTitle, "Daily Sync")
        XCTAssertEqual(conv.calendarEventStartDate, event.start)
        XCTAssertEqual(conv.calendarEventEndDate, event.end)
        XCTAssertEqual(conv.calendarAttendeesJSON, #"["Sam","Alex"]"#)
        XCTAssertEqual(conv.recordingOrigin, "calendar")
        XCTAssertEqual(conv.callContext, "Daily Sync")
        XCTAssertEqual(conv.startedAt, start, "the recording's own start, not save time minus duration")
        XCTAssertEqual(conv.finishedAt, stop, "the recording's own stop, not its save time")
    }

    func testThePartKeepsItsRealInterval() throws {
        let stop = start.addingTimeInterval(600)
        let recording = RecordingContext.fallback(callName: "Zoom", startedAt: start).stopped(at: stop)
        let item = try savedPart("Me: let's start.", savedAt: stop.addingTimeInterval(45))
        grouper.assign(historyItem: item, recording: recording)

        let part = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<HistoryItem>()).first { $0.id == item.id })
        XCTAssertEqual(part.recordedAt, start)
        XCTAssertEqual(part.recordedUntil, stop)
    }

    /// Nothing observed, nothing claimed: a call window or the record button
    /// names no calendar event, and the meeting keeps its own title.
    func testARecordingWithoutAnEventSavesNoEvent() throws {
        for recording in [RecordingContext.fallback(callName: "Google Meet", startedAt: start),
                          RecordingContext.manual(startedAt: start)] {
            let item = try savedPart("Me: quick question.", savedAt: start.addingTimeInterval(300))
            let conv = try stored(XCTUnwrap(grouper.assign(historyItem: item,
                                                           recording: recording.stopped(at: start.addingTimeInterval(240)))).id)
            XCTAssertNil(conv.calendarEventId)
            XCTAssertNil(conv.calendarEventTitle)
            XCTAssertNil(conv.calendarOccurrenceKey)
            XCTAssertEqual(conv.recordingOrigin, recording.origin.rawValue)
        }
    }

    /// An event the calendar shows without a title names nothing: the meeting
    /// gets its own title, not the word "Meeting".
    func testAnUntitledEventLeavesTheTitleToTheMeeting() throws {
        let recording = RecordingContext.calendar(occurrence("e", title: " ", at: start), startedAt: start)
            .stopped(at: start.addingTimeInterval(900))
        let item = try savedPart("Them: hello.", savedAt: start.addingTimeInterval(960))
        let conv = try stored(XCTUnwrap(grouper.assign(historyItem: item, recording: recording)).id)
        XCTAssertEqual(conv.calendarEventId, "e")
        XCTAssertNil(conv.calendarEventTitle)
        XCTAssertEqual(ConversationTitleResolver.resolve(calendarEventTitle: conv.calendarEventTitle,
                                                         llmTitle: "Kickoff"), "Kickoff")
    }

    /// Back-to-back: A is stopped at B's start, B starts, and A's transcript
    /// is saved after B's. Each keeps its own event and name.
    func testBackToBackMeetingsKeepTheirOwnEvents() throws {
        let aStop = start.addingTimeInterval(1500)
        let a = RecordingContext.calendar(occurrence("a", title: "Planning", at: start), startedAt: start).stopped(at: aStop)
        let b = RecordingContext.calendar(occurrence("b", title: "Review", at: aStop), startedAt: aStop)
            .stopped(at: aStop.addingTimeInterval(300))

        let bItem = try savedPart("Them: review notes.", savedAt: aStop.addingTimeInterval(330))
        let bConv = try stored(XCTUnwrap(grouper.assign(historyItem: bItem, recording: b)).id)
        let aItem = try savedPart("Me: planning notes.", savedAt: aStop.addingTimeInterval(400))
        let aConv = try stored(XCTUnwrap(grouper.assign(historyItem: aItem, recording: a)).id)

        XCTAssertNotEqual(aConv.id, bConv.id)
        XCTAssertEqual(aConv.calendarEventTitle, "Planning")
        XCTAssertEqual(bConv.calendarEventTitle, "Review")
    }

    /// Kimi, I1 review — the call name alone resumed two different
    /// occurrences that share a title (every untitled event is "Meeting").
    /// In either save order, each keeps its own occurrence.
    func testSameTitledOccurrencesNeverResumeEachOther() throws {
        for reversed in [false, true] {
            let aStop = start.addingTimeInterval(1800)
            let a = RecordingContext.calendar(occurrence("one", title: "1:1", at: start), startedAt: start)
                .stopped(at: aStop, outcome: .ended)   // open for a part: only identity can keep B out
            let b = RecordingContext.calendar(occurrence("two", title: "1:1", at: aStop), startedAt: aStop)
                .stopped(at: aStop.addingTimeInterval(600))
            let first = reversed ? b : a, second = reversed ? a : b
            let firstConv = try XCTUnwrap(grouper.assign(
                historyItem: try savedPart("first", savedAt: aStop.addingTimeInterval(620)), recording: first))
            let secondConv = try XCTUnwrap(grouper.assign(
                historyItem: try savedPart("second", savedAt: aStop.addingTimeInterval(680)), recording: second))
            XCTAssertNotEqual(firstConv.id, secondConv.id, "reversed: \(reversed)")
            XCTAssertEqual(try stored(secondConv.id).calendarOccurrenceKey, second.occurrenceKey)
        }
    }

    /// The pair: a part of the same occurrence still resumes its meeting.
    func testAPartOfTheSameOccurrenceResumesItsMeeting() throws {
        let event = occurrence("daily", title: "Daily", at: start)
        let part1 = RecordingContext.calendar(event, startedAt: start)
            .stopped(at: start.addingTimeInterval(900), outcome: .ended)   // the app ended it: open for a part
        let part2 = RecordingContext.calendar(event, startedAt: start.addingTimeInterval(960))
            .stopped(at: start.addingTimeInterval(1200))
        let conv1 = try XCTUnwrap(grouper.assign(
            historyItem: try savedPart("one", savedAt: start.addingTimeInterval(930)), recording: part1))
        let conv2 = try XCTUnwrap(grouper.assign(
            historyItem: try savedPart("two", savedAt: start.addingTimeInterval(1230)), recording: part2))
        XCTAssertEqual(conv1.id, conv2.id)
    }

    /// A part with a context never resumes a meeting saved before contexts
    /// existed (it would keep no origin, and its event could still be guessed),
    /// nor a fallback meeting whose call name happens to equal the event's title.
    func testAPartWithAContextResumesNoMeetingOfAnotherKind() throws {
        let legacy = Conversation(source: "meeting", startedAt: start)
        legacy.status = "completed"
        legacy.callContext = "Google Meet"
        legacy.updatedAt = start.addingTimeInterval(600)
        let ctx = ModelContext(container)
        ctx.insert(legacy)
        try ctx.save()

        let fallback = RecordingContext.fallback(callName: "Google Meet", startedAt: start.addingTimeInterval(620))
            .stopped(at: start.addingTimeInterval(700))
        let fallbackConv = try XCTUnwrap(grouper.assign(
            historyItem: try savedPart("ad hoc", savedAt: start.addingTimeInterval(720)), recording: fallback))
        XCTAssertNotEqual(fallbackConv.id, legacy.id, "an old meeting is not resumed by a contexted part")

        let named = occurrence("e", title: "Google Meet", at: start.addingTimeInterval(710))
        let calendar = RecordingContext.calendar(named, startedAt: start.addingTimeInterval(710))
            .stopped(at: start.addingTimeInterval(800))
        let calendarConv = try XCTUnwrap(grouper.assign(
            historyItem: try savedPart("planned", savedAt: start.addingTimeInterval(820)), recording: calendar))
        XCTAssertNotEqual(calendarConv.id, fallbackConv.id, "a calendar part does not resume a fallback meeting")
        XCTAssertEqual(try stored(calendarConv.id).calendarOccurrenceKey, named.key)
    }

    /// A meeting whose recording carried its own context is never guessed:
    /// not by the close, not by the summary, not by the launch backfill.
    func testOnlyMeetingsFromBeforeTheContextAreGuessed() throws {
        let old = Conversation(source: "meeting", startedAt: start)
        old.callContext = "Google Meet"
        XCTAssertTrue(CalendarReaderService.mayGuessEvent(for: old), "rows saved before this release")
        for origin in ["calendar", "fallback", "manual"] {
            let new = Conversation(source: "meeting", startedAt: start)
            new.callContext = "Google Meet"
            new.recordingOrigin = origin
            XCTAssertFalse(CalendarReaderService.mayGuessEvent(for: new), origin)
        }
    }

    /// Parts read in the order they were recorded, not the order their
    /// transcription finished.
    func testPartsReadInRecordingOrder() throws {
        let conversationId = UUID()
        let ctx = ModelContext(container)
        let later = HistoryItem(text: "second", language: "en", audioDuration: 1, processingTime: 1)
        later.createdAt = start.addingTimeInterval(100)              // saved first…
        later.recordedAt = start.addingTimeInterval(1200)            // …recorded second
        later.conversationId = conversationId
        let earlier = HistoryItem(text: "first", language: "en", audioDuration: 1, processingTime: 1)
        earlier.createdAt = start.addingTimeInterval(200)
        earlier.recordedAt = start
        earlier.conversationId = conversationId
        ctx.insert(later); ctx.insert(earlier)
        try ctx.save()

        XCTAssertEqual(StructuredGenerator.fetchHistoryItems(conversationId: conversationId, in: ModelContext(container))
            .map(\.text), ["first", "second"])
    }
}
