import XCTest
import SwiftData
@testable import MetaWhisp

/// ITER-083 I3 — a meeting is processed once, on its final content, and is
/// never left "in progress". Before, a part that resumed a meeting set it
/// "in progress" and nothing ever closed it (9 meetings LIVE forever on the
/// owner's Mac, their later parts in no summary or task), and a second part
/// longer than ten minutes never joined at all: the gap was measured to its
/// save, not its start.
@MainActor
final class MeetingSettlingTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_330_400)   // 2026-09-25 10:00 UTC
    private var container: ModelContainer!
    private var grouper: ConversationGrouper!
    private var processed: [ConversationGrouper.Processing] = []

    override func setUp() async throws {
        container = try ModelContainer(for: Schema([HistoryItem.self, Conversation.self]),
                                       configurations: [ModelConfiguration("Test", isStoredInMemoryOnly: true)])
        grouper = ConversationGrouper()
        grouper.configure(modelContainer: container)
        processed = []
        grouper.process = { [unowned self] in self.processed.append($0) }
    }

    private func part(_ text: String, savedAt: Date) throws -> HistoryItem {
        let ctx = ModelContext(container)
        let item = HistoryItem(text: text, language: "en", audioDuration: 60, processingTime: 1)
        item.createdAt = savedAt
        ctx.insert(item)
        try ctx.save()
        item.source = "meeting"
        return item
    }

    private func zoom(from: TimeInterval, to: TimeInterval, _ outcome: StopOutcome) -> RecordingContext {
        RecordingContext.fallback(callName: "Zoom", startedAt: start.addingTimeInterval(from))
            .stopped(at: start.addingTimeInterval(to), outcome: outcome)
    }

    private func stored(_ id: UUID) throws -> Conversation {
        try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Conversation>()).first { $0.id == id })
    }

    private func meetings() throws -> [Conversation] {
        try ModelContext(container).fetch(FetchDescriptor<Conversation>()).filter { $0.source == "meeting" }
    }

    // MARK: - Final at once, or settling

    /// Processed at once, and completed only once its processing is queued
    /// on disk (release review): completed at its save, a quit in the minute
    /// its summary took left it with no summary, memories or tasks for good.
    func testAMeetingAPersonStoppedIsProcessedAtOnce() throws {
        let conv = try XCTUnwrap(grouper.assign(historyItem: try part("Me: done.", savedAt: start.addingTimeInterval(660)),
                                                recording: zoom(from: 0, to: 600, .refusal)))
        XCTAssertEqual(processed, [.init(id: conv.id, knownTranscript: "Me: done.", regenerate: false, settles: true)])
        XCTAssertEqual(try stored(conv.id).status, "processing", "not completed before its processing is queued")
        grouper.settleMeetings(now: start.addingTimeInterval(3600))
        XCTAssertEqual(processed.count, 1, "not picked again while its processing runs")
        grouper.finishSettling(conv.id)
        XCTAssertEqual(try stored(conv.id).status, "completed")
    }

    func testAMeetingTheNextEventCutIsProcessedAtOnce() throws {
        let conv = try XCTUnwrap(grouper.assign(historyItem: try part("Me: next.", savedAt: start.addingTimeInterval(660)),
                                                recording: zoom(from: 0, to: 600, .transition)))
        XCTAssertEqual(processed, [.init(id: conv.id, knownTranscript: "Me: next.", regenerate: false, settles: true)])
    }

    /// Release review — the app quits before a stopped meeting's processing
    /// was queued: the next launch processes it.
    func testAStoppedMeetingWhoseProcessingWasNotQueuedIsProcessedAfterARestart() throws {
        let conv = try XCTUnwrap(grouper.assign(historyItem: try part("Me: done.", savedAt: start.addingTimeInterval(660)),
                                                recording: zoom(from: 0, to: 600, .refusal)))
        XCTAssertEqual(processed.count, 1)
        let relaunched = ConversationGrouper()
        relaunched.configure(modelContainer: container)
        var again: [ConversationGrouper.Processing] = []
        relaunched.process = { again.append($0) }
        relaunched.settleMeetings(now: start.addingTimeInterval(661))
        XCTAssertEqual(again, [.init(id: conv.id, knownTranscript: nil, regenerate: false, settles: true)],
                       "at once: it waits for no continuation")
    }

    /// Re-review — a meeting a person stopped stays closed to joins across a
    /// restart: another Zoom call recorded minutes later is its own meeting.
    func testAStoppedMeetingIsNotJoinedAfterARestart() throws {
        let stopped = try XCTUnwrap(grouper.assign(historyItem: try part("Me: done.", savedAt: start.addingTimeInterval(660)),
                                                   recording: zoom(from: 0, to: 600, .refusal)))
        let relaunched = ConversationGrouper()
        relaunched.configure(modelContainer: container)
        relaunched.process = { _ in }
        let next = try XCTUnwrap(relaunched.assign(historyItem: try part("Them: hi.", savedAt: start.addingTimeInterval(1000)),
                                                   recording: zoom(from: 700, to: 960, .ended)))
        XCTAssertNotEqual(next.id, stopped.id)
    }

    /// Release review — a stopped part saved before an earlier part of the same
    /// call, still being transcribed, waits for it: both are one meeting,
    /// processed once. Processed at once, the earlier part became a second
    /// meeting with its own summary and tasks.
    func testAStoppedPartWaitsForAnEarlierPartStillBeingSaved() throws {
        let earlier = zoom(from: 0, to: 1800, .ended)
        let later = try XCTUnwrap(grouper.assign(historyItem: try part("two", savedAt: start.addingTimeInterval(2010)),
                                                 recording: zoom(from: 1900, to: 2000, .refusal), inFlight: [earlier]))
        XCTAssertTrue(processed.isEmpty, "the earlier part is still on its way")
        XCTAssertEqual(try stored(later.id).status, "settling")

        let first = try XCTUnwrap(grouper.assign(historyItem: try part("one", savedAt: start.addingTimeInterval(2100)),
                                                 recording: earlier))
        XCTAssertEqual(first.id, later.id)
        XCTAssertTrue(processed.isEmpty)
        grouper.settleMeetings(now: start.addingTimeInterval(2000 + 600))
        XCTAssertEqual(processed, [.init(id: later.id, knownTranscript: nil, regenerate: false, settles: true)])
    }

    /// The pair: a recording of another call in flight does not hold it.
    func testAStoppedPartIsProcessedAtOnceWhileAnotherCallIsBeingSaved() throws {
        let other = RecordingContext.fallback(callName: "Microsoft Teams", startedAt: start)
            .stopped(at: start.addingTimeInterval(1800), outcome: .ended)
        let conv = try XCTUnwrap(grouper.assign(historyItem: try part("two", savedAt: start.addingTimeInterval(2010)),
                                                recording: zoom(from: 1900, to: 2000, .refusal), inFlight: [other]))
        XCTAssertEqual(processed.map(\.id), [conv.id])
    }

    /// The app ended it by itself: a continuation may follow within ten
    /// minutes, so nothing is processed until that window is over.
    func testAMeetingTheAppEndedSettlesBeforeItIsProcessed() throws {
        let conv = try XCTUnwrap(grouper.assign(historyItem: try part("Them: hello.", savedAt: start.addingTimeInterval(660)),
                                                recording: zoom(from: 0, to: 600, .ended)))
        XCTAssertEqual(try stored(conv.id).status, "settling")
        XCTAssertTrue(processed.isEmpty)

        grouper.settleMeetings(now: start.addingTimeInterval(600 + 599))
        XCTAssertTrue(processed.isEmpty, "still inside the window")

        grouper.settleMeetings(now: start.addingTimeInterval(600 + 600))
        XCTAssertEqual(processed, [.init(id: conv.id, knownTranscript: nil, regenerate: false, settles: true)],
                       "processed once, on every part fetched from the store")
        XCTAssertEqual(try stored(conv.id).status, "settling", "completed only once its processing is queued")
        grouper.settleMeetings(now: start.addingTimeInterval(1500))
        XCTAssertEqual(processed.count, 1, "not picked again while its processing runs")

        grouper.finishSettling(conv.id)
        XCTAssertEqual(try stored(conv.id).status, "completed")
        grouper.settleMeetings(now: start.addingTimeInterval(3600))
        XCTAssertEqual(processed.count, 1, "settled once")
    }

    /// Kimi, I3 review — a continuation that started inside the window but is
    /// still recording (or being transcribed) when the window ends holds its
    /// meeting open, so it joins instead of becoming a second meeting.
    func testAContinuationNotYetSavedHoldsItsMeetingOpen() throws {
        let first = try XCTUnwrap(grouper.assign(historyItem: try part("one", savedAt: start.addingTimeInterval(345)),
                                                 recording: zoom(from: 0, to: 300, .ended)))
        let live = RecordingContext.fallback(callName: "Zoom", startedAt: start.addingTimeInterval(600))
        grouper.settleMeetings(now: start.addingTimeInterval(1000), inFlight: [live])
        XCTAssertTrue(processed.isEmpty, "the continuation is still recording")

        let second = try XCTUnwrap(grouper.assign(historyItem: try part("two", savedAt: start.addingTimeInterval(1900)),
                                                  recording: live.stopped(at: start.addingTimeInterval(1800), outcome: .refusal)))
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(processed, [.init(id: first.id, knownTranscript: nil, regenerate: false, settles: true)])
    }

    /// Release review — the hold has a ceiling: a save that never ends (a hung
    /// transcription) held its meeting unprocessed for as long as the app ran.
    /// An hour after that recording's stop, the meeting is processed anyway.
    func testAMeetingHeldByASaveIsSettledAnywayAnHourAfterThatRecordingStopped() throws {
        let first = try XCTUnwrap(grouper.assign(historyItem: try part("one", savedAt: start.addingTimeInterval(345)),
                                                 recording: zoom(from: 0, to: 300, .ended)))
        let hung = zoom(from: 400, to: 500, .ended)
        grouper.settleMeetings(now: start.addingTimeInterval(500 + ConversationGrouper.saveHoldSeconds), inFlight: [hung])
        XCTAssertTrue(processed.isEmpty, "held up to the ceiling")
        grouper.settleMeetings(now: start.addingTimeInterval(500 + ConversationGrouper.saveHoldSeconds + 1), inFlight: [hung])
        XCTAssertEqual(processed.map(\.id), [first.id])
    }

    /// The pair: a recording of another call does not hold it.
    func testAnotherCallsRecordingDoesNotHoldIt() throws {
        let first = try XCTUnwrap(grouper.assign(historyItem: try part("one", savedAt: start.addingTimeInterval(345)),
                                                 recording: zoom(from: 0, to: 300, .ended)))
        let other = RecordingContext.fallback(callName: "Microsoft Teams", startedAt: start.addingTimeInterval(600))
        grouper.settleMeetings(now: start.addingTimeInterval(1000), inFlight: [other])
        XCTAssertEqual(processed.map(\.id), [first.id])
    }

    /// Kimi, I3 review — a quit or a crash before the processing was queued on
    /// disk leaves the meeting settling, and the next launch settles it again.
    func testAMeetingWhoseProcessingWasNotQueuedIsSettledAgainAfterARestart() throws {
        let conv = try XCTUnwrap(grouper.assign(historyItem: try part("one", savedAt: start.addingTimeInterval(345)),
                                                recording: zoom(from: 0, to: 300, .ended)))
        grouper.settleMeetings(now: start.addingTimeInterval(1000))
        XCTAssertEqual(processed.count, 1)
        // The app ends before `finishSettling`; a new launch has a new grouper.
        let relaunched = ConversationGrouper()
        relaunched.configure(modelContainer: container)
        var again: [ConversationGrouper.Processing] = []
        relaunched.process = { again.append($0) }
        relaunched.settleMeetings(now: start.addingTimeInterval(2000))
        XCTAssertEqual(again.map(\.id), [conv.id])
    }

    /// A part that arrives once a meeting's processing has started does not
    /// join it: the run under way would miss it.
    func testAPartDoesNotJoinAMeetingWhoseProcessingStarted() throws {
        let first = try XCTUnwrap(grouper.assign(historyItem: try part("one", savedAt: start.addingTimeInterval(345)),
                                                 recording: zoom(from: 0, to: 300, .ended)))
        grouper.settleMeetings(now: start.addingTimeInterval(900))
        let late = try XCTUnwrap(grouper.assign(historyItem: try part("late", savedAt: start.addingTimeInterval(960)),
                                                recording: zoom(from: 880, to: 940, .refusal)))
        XCTAssertNotEqual(late.id, first.id)
    }

    // MARK: - Joining

    /// The 2026-10-23 case: part 2 started 77 s after part 1 ended and ran
    /// 18 min; it became its own meeting because the gap was measured to its
    /// save. Measured start to stop, it joins — and the whole meeting is
    /// processed once.
    func testALongSecondPartJoinsAndTheWholeMeetingIsProcessedOnce() throws {
        let first = try XCTUnwrap(grouper.assign(historyItem: try part("one", savedAt: start.addingTimeInterval(345)),
                                                 recording: zoom(from: 0, to: 300, .ended)))
        let second = try XCTUnwrap(grouper.assign(historyItem: try part("two", savedAt: start.addingTimeInterval(1500)),
                                                  recording: zoom(from: 377, to: 1457, .refusal)))
        XCTAssertEqual(first.id, second.id)
        let conv = try stored(first.id)
        XCTAssertEqual(conv.startedAt, start)
        XCTAssertEqual(conv.finishedAt, start.addingTimeInterval(1457))
        XCTAssertEqual(processed, [.init(id: conv.id, knownTranscript: nil, regenerate: false, settles: true)])
    }

    /// Kimi, I1 re-review — the old resume looked only at the newest meeting
    /// with the call's name: A, then a same-titled B, then A's next part made
    /// a fresh meeting instead of joining A. Every settling meeting is asked.
    func testAPartFindsItsMeetingPastAnotherWithTheSameTitle() throws {
        func oneOnOne(_ id: String, at offset: TimeInterval) -> CalendarOccurrence {
            CalendarOccurrence(eventID: id, title: "1:1", start: start.addingTimeInterval(offset),
                               end: start.addingTimeInterval(offset + 1800))!
        }
        let a = oneOnOne("a", at: 0), b = oneOnOne("b", at: 300)
        let a1 = try XCTUnwrap(grouper.assign(
            historyItem: try part("a1", savedAt: start.addingTimeInterval(320)),
            recording: RecordingContext.calendar(a, startedAt: start).stopped(at: start.addingTimeInterval(290), outcome: .ended)))
        let b1 = try XCTUnwrap(grouper.assign(
            historyItem: try part("b1", savedAt: start.addingTimeInterval(420)),
            recording: RecordingContext.calendar(b, startedAt: start.addingTimeInterval(300))
                .stopped(at: start.addingTimeInterval(400), outcome: .ended)))
        XCTAssertNotEqual(b1.id, a1.id, "another occurrence, though the same title, within the window")
        let a2 = try XCTUnwrap(grouper.assign(
            historyItem: try part("a2", savedAt: start.addingTimeInterval(700)),
            recording: RecordingContext.calendar(a, startedAt: start.addingTimeInterval(450))
                .stopped(at: start.addingTimeInterval(650), outcome: .refusal)))
        XCTAssertEqual(a1.id, a2.id)
    }

    func testAPartAfterTheWindowIsANewMeeting() throws {
        let first = try XCTUnwrap(grouper.assign(historyItem: try part("one", savedAt: start.addingTimeInterval(345)),
                                                 recording: zoom(from: 0, to: 300, .ended)))
        let second = try XCTUnwrap(grouper.assign(historyItem: try part("two", savedAt: start.addingTimeInterval(1000)),
                                                  recording: zoom(from: 901, to: 960, .refusal)))
        XCTAssertNotEqual(first.id, second.id)
    }

    /// A short later part can be saved before a long earlier one; they still
    /// join, and the meeting spans both.
    func testPartsSavedOutOfOrderStillJoin() throws {
        let later = try XCTUnwrap(grouper.assign(historyItem: try part("two", savedAt: start.addingTimeInterval(500)),
                                                 recording: zoom(from: 400, to: 460, .ended)))
        let earlier = try XCTUnwrap(grouper.assign(historyItem: try part("one", savedAt: start.addingTimeInterval(700)),
                                                   recording: zoom(from: 0, to: 360, .ended)))
        XCTAssertEqual(later.id, earlier.id)
        XCTAssertEqual(try stored(later.id).startedAt, start)
        XCTAssertEqual(try stored(later.id).finishedAt, start.addingTimeInterval(460))
    }

    /// A meeting already processed (its last part was final) is not joined:
    /// the next recording is a new meeting, and nothing is processed twice.
    func testAProcessedMeetingIsNotJoined() throws {
        let first = try XCTUnwrap(grouper.assign(historyItem: try part("one", savedAt: start.addingTimeInterval(345)),
                                                 recording: zoom(from: 0, to: 300, .refusal)))
        let second = try XCTUnwrap(grouper.assign(historyItem: try part("two", savedAt: start.addingTimeInterval(500)),
                                                  recording: zoom(from: 360, to: 460, .refusal)))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(processed.map(\.id), [first.id, second.id])
    }

    func testADeletedMeetingIsNotJoined() throws {
        let first = try XCTUnwrap(grouper.assign(historyItem: try part("one", savedAt: start.addingTimeInterval(345)),
                                                 recording: zoom(from: 0, to: 300, .ended)))
        let ctx = ModelContext(container)
        try XCTUnwrap(ctx.fetch(FetchDescriptor<Conversation>()).first { $0.id == first.id }).discarded = true
        try ctx.save()
        let second = try XCTUnwrap(grouper.assign(historyItem: try part("two", savedAt: start.addingTimeInterval(500)),
                                                  recording: zoom(from: 360, to: 460, .refusal)))
        XCTAssertNotEqual(first.id, second.id)
    }

    // MARK: - A stuck meeting's rewrite is paid once per launch

    /// A meeting left in progress, its rewrite run and the meeting completed — then reopened by something else.
    private func reopenedAfterItsRewrite() throws -> UUID {
        let stuck = Conversation(source: "meeting", startedAt: start)
        stuck.status = "inProgress"
        stuck.updatedAt = start.addingTimeInterval(900)
        let ctx = ModelContext(container)
        ctx.insert(stuck)
        try ctx.save()
        grouper.settleMeetings(now: start.addingTimeInterval(1500))
        XCTAssertEqual(processed.map(\.id), [stuck.id])
        grouper.rewriteEnded(stuck.id, result: .done)
        XCTAssertEqual(try stored(stuck.id).status, "completed")
        let reopen = ModelContext(container)
        try XCTUnwrap(reopen.fetch(FetchDescriptor<Conversation>()).first { $0.id == stuck.id }).status = "inProgress"
        try reopen.save()
        return stuck.id
    }

    /// 2026-11-24 on the owner's Mac: the store lost each completion, and the same 65 meetings were rewritten every
    /// ten minutes — 1,533 paid model calls in 4.5 h. The rewrite is paid once per launch, whatever the store says.
    func testAStuckMeetingReopenedAfterItsRewriteIsNotRewrittenAgainInTheSameLaunch() throws {
        let id = try reopenedAfterItsRewrite()
        grouper.settleMeetings(now: start.addingTimeInterval(7200))
        grouper.settleMeetings(now: start.addingTimeInterval(14_400))
        XCTAssertEqual(processed.count, 1, "one rewrite per launch")
        XCTAssertEqual(try stored(id).status, "completed", "closed again with the summary it has, not left live")
    }

    /// The ceiling ends with the launch: the next one rewrites it again, once.
    func testAStuckMeetingReopenedAfterItsRewriteIsRewrittenAgainAfterTheNextLaunch() throws {
        let id = try reopenedAfterItsRewrite()
        let nextLaunch = ConversationGrouper()
        nextLaunch.configure(modelContainer: container)
        var again: [ConversationGrouper.Processing] = []
        nextLaunch.process = { again.append($0) }
        nextLaunch.settleMeetings(now: start.addingTimeInterval(7200))
        XCTAssertEqual(again.map(\.id), [id])
    }

    // MARK: - Never "in progress"

    func testNoMeetingIsLeftInProgress() throws {
        _ = grouper.assign(historyItem: try part("one", savedAt: start.addingTimeInterval(345)),
                           recording: zoom(from: 0, to: 300, .ended))
        _ = grouper.assign(historyItem: try part("two", savedAt: start.addingTimeInterval(500)),
                           recording: zoom(from: 360, to: 460, .ended))
        _ = grouper.assign(historyItem: try part("three", savedAt: start.addingTimeInterval(900)),
                           recording: zoom(from: 520, to: 860, .refusal))
        XCTAssertFalse(try meetings().contains { $0.status == "inProgress" })
    }

    /// The meetings left "in progress" by earlier versions: the sweep closes
    /// each once and has its summary rewritten over all its parts. Its tasks
    /// are not extracted again — that would duplicate the first part's.
    func testTheSweepClosesAMeetingStuckInProgressOnce() throws {
        let stuck = Conversation(source: "meeting", startedAt: start)
        stuck.status = "inProgress"
        stuck.title = "Model-made title"
        stuck.updatedAt = start.addingTimeInterval(900)
        let ctx = ModelContext(container)
        ctx.insert(stuck)
        let lastPart = HistoryItem(text: "two", language: "en", audioDuration: 60, processingTime: 1)
        lastPart.createdAt = start.addingTimeInterval(900)
        lastPart.conversationId = stuck.id
        ctx.insert(lastPart)
        try ctx.save()

        grouper.settleMeetings(now: start.addingTimeInterval(900 + 599))
        XCTAssertTrue(processed.isEmpty)
        grouper.settleMeetings(now: start.addingTimeInterval(900 + 600))
        XCTAssertEqual(processed, [.init(id: stuck.id, knownTranscript: nil, regenerate: true, settles: true)])
        // The rewrite saves the summary, which moves `updatedAt` to now.
        let rewritten = ModelContext(container)
        try XCTUnwrap(rewritten.fetch(FetchDescriptor<Conversation>()).first { $0.id == stuck.id })
            .updatedAt = start.addingTimeInterval(1600)
        try rewritten.save()
        grouper.rewriteEnded(stuck.id, result: .done)
        let closed = try stored(stuck.id)
        XCTAssertEqual(closed.status, "completed")
        XCTAssertEqual(closed.finishedAt, start.addingTimeInterval(900), "its last part, not the rewrite")
        grouper.settleMeetings(now: start.addingTimeInterval(7200))
        XCTAssertEqual(processed.count, 1)
    }

    /// Kimi, I3 reviews — a rewrite that could not run yet (no network, a busy
    /// service) is not counted and not lost: the meeting stays open and is
    /// tried again after a wait that grows.
    func testARewriteThatCouldNotRunYetWaitsAndIsTriedAgain() throws {
        let stuck = try insertStuck()
        var clock = start.addingTimeInterval(2000)
        for attempt in 1...5 {
            grouper.settleMeetings(now: clock)
            XCTAssertEqual(processed.count, attempt, "attempt \(attempt)")
            grouper.rewriteEnded(stuck.id, result: .later, now: clock)
            XCTAssertEqual(try stored(stuck.id).status, "inProgress", "not closed by waiting")
            grouper.settleMeetings(now: clock.addingTimeInterval(30))
            XCTAssertEqual(processed.count, attempt, "it waits before the next try")
            clock = clock.addingTimeInterval(ConversationGrouper.maxRewriteWaitSeconds)
        }
        grouper.settleMeetings(now: clock)
        grouper.rewriteEnded(stuck.id, result: .done, now: clock)
        XCTAssertEqual(try stored(stuck.id).status, "completed")
    }

    /// The ceilings: three real failures close it with the summary it has, and
    /// with no model and no key at all it is closed at once — never left
    /// "in progress" for good.
    func testARewriteThatFailsThreeTimesOrCanNeverRunClosesTheMeeting() throws {
        let failing = try insertStuck()
        for attempt in 1...ConversationGrouper.maxRewriteAttempts {
            grouper.settleMeetings(now: start.addingTimeInterval(2000 + Double(attempt) * 60))
            XCTAssertEqual(try stored(failing.id).status, "inProgress")
            grouper.rewriteEnded(failing.id, result: .failed)
        }
        XCTAssertEqual(try stored(failing.id).status, "completed")

        let noModel = try insertStuck()
        grouper.settleMeetings(now: start.addingTimeInterval(9000))
        grouper.rewriteEnded(noModel.id, result: .impossible)
        XCTAssertEqual(try stored(noModel.id).status, "completed")
    }

    /// Release review — the ceiling of the wait: a rewrite that cannot run for
    /// `maxRewriteWaits` tries in a row (hours) closes the meeting with the
    /// summary it has instead of leaving it "in progress" for good.
    func testARewriteThatCannotRunForHoursClosesTheMeetingWithTheSummaryItHas() throws {
        let stuck = try insertStuck()
        var clock = start.addingTimeInterval(2000)
        for attempt in 1...ConversationGrouper.maxRewriteWaits {
            grouper.settleMeetings(now: clock)
            XCTAssertEqual(processed.count, attempt)
            XCTAssertEqual(try stored(stuck.id).status, "inProgress", "attempt \(attempt)")
            grouper.rewriteEnded(stuck.id, result: .later, now: clock)
            clock = clock.addingTimeInterval(ConversationGrouper.maxRewriteWaitSeconds)
        }
        XCTAssertEqual(try stored(stuck.id).status, "completed")
    }

    func testARewriteResultMapsAccess() {
        XCTAssertEqual(ConversationGrouper.RewriteResult(.notNow, hadAccess: true), .later)
        XCTAssertEqual(ConversationGrouper.RewriteResult(.notNow, hadAccess: false), .impossible)
        XCTAssertEqual(ConversationGrouper.RewriteResult(.written, hadAccess: true), .done)
        XCTAssertEqual(ConversationGrouper.RewriteResult(.unchanged, hadAccess: true), .done)
        XCTAssertEqual(ConversationGrouper.RewriteResult(.failed, hadAccess: true), .failed)
    }

    private func insertStuck() throws -> Conversation {
        let stuck = Conversation(source: "meeting", startedAt: start)
        stuck.status = "inProgress"
        stuck.updatedAt = start.addingTimeInterval(900)
        let ctx = ModelContext(container)
        ctx.insert(stuck)
        try ctx.save()
        return stuck
    }
}

/// ITER-083 I3 — the wiring, read off the source like the app's other wiring
/// tests: the sweep settles, the recap comes from processing, and nothing sets
/// a meeting "in progress" any more.
final class MeetingSettlingWiringTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../\(path)").standardized
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheSweepSettlesMeetings() throws {
        XCTAssertTrue(try source("App/AppDelegate.swift").contains(
            "self?.conversationGrouper.closeStaleConversations()\n                // ITER-083"))
        XCTAssertTrue(try source("App/AppDelegate.swift").contains(
            "self.conversationGrouper.settleMeetings(inFlight: self.meetingRecordingsInFlight)"))
    }

    /// Re-review — the production path completes a meeting once its
    /// processing is queued: the tests above stand a spy in for it.
    func testProcessingCompletesTheMeetingOnceItIsQueued() throws {
        let grouper = try source("Services/Intelligence/ConversationGrouper.swift")
        XCTAssertTrue(grouper.contains(
            "onQueued: processing.settles ? { [weak self] in self?.finishSettling(processing.id) } : nil"))
        let close = try XCTUnwrap(grouper.range(of: "private func scheduleOnClose("))
        let closeBody = grouper[close.upperBound...].prefix(1600)
        let tasks = try XCTUnwrap(closeBody.range(of: "app.taskExtractor.triggerOnConversationClose"))
        let queued = try XCTUnwrap(closeBody.range(of: "onQueued?()"))
        XCTAssertLessThan(tasks.lowerBound, queued.lowerBound, "after the extractors are queued")
    }

    func testTheRecapComesFromProcessingOnce() throws {
        let app = try source("App/AppDelegate.swift")
        let persist = try XCTUnwrap(app.range(of: "private func persistMeetingTranscript("))
        let persistBody = app[persist.upperBound...].prefix(4500)
        XCTAssertFalse(persistBody.contains("fireMeetingRecap"), "not per saved part")
        let grouper = try source("Services/Intelligence/ConversationGrouper.swift")
        let close = try XCTUnwrap(grouper.range(of: "private func scheduleOnClose("))
        let closeBody = grouper[close.upperBound...].prefix(1600)
        let tasks = try XCTUnwrap(closeBody.range(of: "app.taskExtractor.triggerOnConversationClose"))
        let recap = try XCTUnwrap(closeBody.range(of: "app.scheduleMeetingRecap(conversationId)"))
        XCTAssertLessThan(tasks.lowerBound, recap.lowerBound, "after the extractors have started")
    }

    /// Kimi, I3 review — the MCP snapshot lists processed conversations only:
    /// a settling meeting has an end but no summary yet.
    func testTheMCPSnapshotSkipsSettlingMeetings() throws {
        XCTAssertTrue(try source("Services/MCP/MCPSnapshotService.swift").contains(
            "!$0.discarded && $0.finishedAt != nil && $0.status == \"completed\""))
    }

    func testTheTranscriptionInFlightIsTrackedUntilItsSaveEnds() throws {
        let app = try source("App/AppDelegate.swift")
        XCTAssertTrue(app.contains("if let recording { meetingSavesInFlight[saveToken] = recording }"))
        XCTAssertTrue(app.contains("defer { self.meetingSavesInFlight[saveToken] = nil }"))
    }

    func testNothingSetsAMeetingInProgress() throws {
        XCTAssertFalse(try source("Services/Intelligence/ConversationGrouper.swift").contains(".status = \"inProgress\""))
    }
}
