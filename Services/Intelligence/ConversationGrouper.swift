import Foundation
import SwiftData

/// Groups transcripts into Conversations (aggregation root).
/// Rule: consecutive dictations within 10 min silence belong to one Conversation.
/// Meetings always get their own Conversation (source="meeting").
/// The 10-min gap is a desktop-adapted analog of 2-min wearable silence split —
/// keyboard/dictation rhythm on desktop is slower than continuous wearable audio.
/// spec://BACKLOG#C1.1
@MainActor
final class ConversationGrouper {
    /// Silence gap after which a dictation conversation auto-closes. 10 min for desktop.
    static let dictationGapSeconds: TimeInterval = 600

    private var modelContainer: ModelContainer?

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// ITER-083 — how far apart two recordings of one call may be: the gap
    /// between one's stop and the other's start, on their real times. A
    /// meeting the app ended by itself waits this long for a continuation
    /// (lid-bounce, wake-from-sleep, the call window back in front) before it
    /// is processed. The «one real call → 5 conversations» report of
    /// 2026-04-29 is why parts join at all.
    static let meetingJoinWindowSeconds: TimeInterval = 600   // 10 min

    /// ITER-083 — what processing a meeting is asked for: today's close
    /// (summary, memories, tasks, recap) with the in-memory transcript when the
    /// meeting is one part, from the store otherwise; `regenerate` rewrites the
    /// summary of a meeting left "in progress" by an earlier version.
    struct Processing: Equatable {
        let id: UUID
        let knownTranscript: String?
        let regenerate: Bool
        /// The meeting is marked completed only once its processing is queued
        /// on disk (`finishSettling`), so a quit or a crash before that leaves
        /// it settling, and the next launch settles it again.
        var settles = false
    }

    /// Where processing goes; tests record it. Nil → `scheduleOnClose`.
    var process: ((Processing) -> Void)?

    /// ITER-083 — meetings whose settling processing has started and is not
    /// yet queued on disk: the sweep does not pick them again, and no part
    /// joins them (it would miss the run already under way).
    private var settlingNow: Set<UUID> = []
    /// ITER-083 — summary rewrites of meetings left "in progress" that ran and
    /// failed, per meeting, this launch; and when one that could not run yet
    /// (no network, a busy service) may be tried again.
    private var failedRewrites: [UUID: Int] = [:]
    private var rewriteNotBefore: [UUID: Date] = [:]
    private var rewriteWaits: [UUID: Int] = [:]
    static let maxRewriteAttempts = 3
    static let maxRewriteWaitSeconds: TimeInterval = 1800
    /// The ceiling of the wait (release review): this many tries that could
    /// not run, in a row (about four hours), close the meeting with the summary
    /// it has. Each launch starts the count again.
    static let maxRewriteWaits = 12
    /// The ceiling of a hold (release review): a recording being saved holds a
    /// settling meeting at most this long after its stop. A save that never
    /// ends (a hung transcription) held it for as long as the app ran.
    static let saveHoldSeconds: TimeInterval = 3600

    /// How a rewrite of a meeting left "in progress" ended.
    enum RewriteResult: Equatable {
        /// A result was written, or there was nothing to change.
        case done
        /// It ran and nothing usable came back.
        case failed
        /// It could not run now (no network, a busy service): try later, uncounted.
        case later
        /// It can never run here: no model and no key at all.
        case impossible

        init(_ outcome: StructuredOutcome, hadAccess: Bool) {
            switch outcome {
            case .written, .unchanged: self = .done
            case .failed: self = .failed
            case .notNow: self = hadAccess ? .later : .impossible
            }
        }
    }

    /// Assign a freshly-saved HistoryItem to an active Conversation or create a new one.
    /// Called by TranscriptionCoordinator after `historyService.save(result)`.
    /// `recording` (meetings) is the recording's own snapshot, taken at its
    /// stop (ITER-083): its call name enables meeting RESUMPTION across brief
    /// gaps caused by lid-bounce or wake-from-sleep, and its event and real
    /// times are written onto the meeting. `meetingDurationSec` back-dates
    /// `startedAt` only for a meeting saved without a snapshot. `inFlight` —
    /// the other recordings running or still being saved: a stopped part waits
    /// for an earlier part of its call among them (release review).
    @discardableResult
    func assign(
        historyItem: HistoryItem,
        recording: RecordingContext? = nil,
        meetingDurationSec: Double? = nil,
        inFlight: [RecordingContext] = []
    ) -> Conversation? {
        guard let container = modelContainer else { return nil }
        let ctx = ModelContext(container)

        let source = historyItem.source ?? "microphone"
        let (conv, processing) = activeOrNewConversation(
            source: source,
            at: historyItem.createdAt,
            recording: recording,
            meetingDurationSec: meetingDurationSec,
            in: ctx
        )

        historyItem.conversationId = conv.id
        if let recording {
            historyItem.recordedAt = recording.startedAt
            historyItem.recordedUntil = recording.stoppedAt
        }
        conv.updatedAt = historyItem.createdAt
        // ITER-083 — a meeting is processed once, on its final content. Until
        // that processing is queued on disk it is "processing": closed to
        // joins, also across a restart, and the next launch's sweep processes
        // it if a quit came first (release review). A stopped part saved before
        // an earlier part of its call, still being transcribed, stays settling:
        // the sweep processes the meeting once that part has joined.
        let earlierPartComing = processing != .none
            && inFlight.contains { $0 != recording && Self.continues(conv, with: $0, now: historyItem.createdAt) }
        if processing != .none, !earlierPartComing { conv.status = "processing" }
        try? ctx.save()
        // ITER-075 step 1 (1.5) — the link is saved where it was written. The
        // item lives in its caller's context, and a fresh context (an
        // extractor's, a moment after the close) read no link until that
        // context saved on its own: a meeting's memories and tasks could be
        // lost.
        do {
            try historyItem.modelContext?.save()
        } catch {
            NSLog("[ConversationGrouper] ⚠️ the link of HistoryItem %@ was not saved — %@",
                  historyItem.id.uuidString.prefix(8) as CVarArg, error.localizedDescription)
        }

        // Schedule structured-gen / extractors here (not inside
        // `activeOrNewConversation`) so we can pass the in-memory transcript
        // through, dodging the cross-ModelContext race that produced "Quick
        // note (empty)" placeholders even after the predicate-vs-filter fix.
        // A one-part meeting with its transcript, a joined one from the store.
        switch processing {
        case .none: break
        case _ where earlierPartComing:
            NSLog("[ConversationGrouper] meeting %@ waits for a part of its call still being saved",
                  conv.id.uuidString.prefix(8) as CVarArg)
        case .thisPart:
            settlingNow.insert(conv.id)
            run(Processing(id: conv.id, knownTranscript: historyItem.displayText, regenerate: false, settles: true))
        case .allParts:
            settlingNow.insert(conv.id)
            run(Processing(id: conv.id, knownTranscript: nil, regenerate: false, settles: true))
        }

        NSLog("[ConversationGrouper] Assigned HistoryItem %@ → Conversation %@ (source=%@, status=%@)",
              historyItem.id.uuidString.prefix(8) as CVarArg,
              conv.id.uuidString.prefix(8) as CVarArg,
              conv.source,
              conv.status)
        return conv
    }

    /// Explicitly close any in-progress conversations that have been idle past the gap threshold.
    /// Can be called periodically (timer) or on-demand.
    func closeStaleConversations() {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.status == "inProgress" && !$0.discarded }
        )
        descriptor.fetchLimit = 50
        guard let actives = try? ctx.fetch(descriptor) else { return }

        let now = Date()
        var closedCount = 0
        for conv in actives {
            // Dictation conversations: close if silent past gap. Meetings stay open until explicit stop.
            guard conv.source == "dictation" else { continue }
            if now.timeIntervalSince(conv.updatedAt) > Self.dictationGapSeconds {
                close(conv, in: ctx)
                closedCount += 1
            }
        }
        if closedCount > 0 {
            try? ctx.save()
            NSLog("[ConversationGrouper] Closed %d stale dictation conversations", closedCount)
        }
    }

    /// ITER-083 — the meetings the app ended by itself, once their join window
    /// has passed with no new part: closed and processed, each once. Also the
    /// meetings an earlier version left "in progress" (it set a resumed meeting
    /// so and nothing closed it): closed with their last part's time and their
    /// summary rewritten over every part — their tasks are not extracted again,
    /// which would duplicate the first part's. Runs from the 60-s sweep, so a
    /// quit or a crash only delays it to the next launch — also for a meeting
    /// a person stopped, whose processing had not been queued yet.
    ///
    /// `inFlight` — recordings running or stopped and still being transcribed
    /// (Kimi, I3 review): a continuation that started inside the window but
    /// has not been saved yet holds its meeting open until it is, so it joins
    /// instead of becoming a second meeting. The hold ends when that recording
    /// is saved (or its save fails), at the latest `saveHoldSeconds` after its
    /// stop; a recording still running ends at its own cap.
    func settleMeetings(now: Date = Date(), inFlight: [RecordingContext] = []) {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        let desc = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.source == "meeting" && !$0.discarded
                && ($0.status == "settling" || $0.status == "inProgress" || $0.status == "processing") }
        )
        guard let open = try? ctx.fetch(desc), !open.isEmpty else { return }
        var due: [Processing] = []
        for conv in open where !settlingNow.contains(conv.id) {
            // Final, its processing not queued before a quit: at once.
            if conv.status == "processing" {
                settlingNow.insert(conv.id)
                due.append(Processing(id: conv.id, knownTranscript: nil, regenerate: false, settles: true))
                continue
            }
            let wasStuck = conv.status == "inProgress"
            if wasStuck, let notBefore = rewriteNotBefore[conv.id], now < notBefore { continue }
            let lastPart = wasStuck ? conv.updatedAt : (conv.finishedAt ?? conv.updatedAt)
            guard now.timeIntervalSince(lastPart) >= Self.meetingJoinWindowSeconds else { continue }
            if !wasStuck, inFlight.contains(where: { Self.continues(conv, with: $0, now: now) }) { continue }
            settlingNow.insert(conv.id)
            due.append(Processing(id: conv.id, knownTranscript: nil, regenerate: wasStuck, settles: true))
        }
        guard !due.isEmpty else { return }
        NSLog("[ConversationGrouper] Settling %d meeting(s) (%d left in progress by an earlier version)",
              due.count, due.filter(\.regenerate).count)
        due.forEach(run)
    }

    /// The meeting's processing is queued on disk (or, for a meeting left in
    /// progress, its summary was rewritten): it is completed now, once.
    func finishSettling(_ id: UUID) {
        settlingNow.remove(id)
        failedRewrites[id] = nil
        rewriteNotBefore[id] = nil
        rewriteWaits[id] = nil
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        desc.fetchLimit = 1
        guard let conv = try? ctx.fetch(desc).first,
              ["settling", "processing", "inProgress"].contains(conv.status) else { return }
        // Its last part's time: the summary just rewritten moved `updatedAt`
        // to now (release review).
        if conv.status == "inProgress" { conv.finishedAt = lastPart(of: id, in: ctx) ?? conv.updatedAt }
        conv.status = "completed"
        do {
            try ctx.save()
        } catch {
            NSLog("[ConversationGrouper] ⚠️ meeting %@ not marked completed — %@",
                  id.uuidString.prefix(8) as CVarArg, error.localizedDescription)
        }
    }

    /// When a meeting's last part was recorded or, for a part saved before
    /// parts kept their times, saved.
    private func lastPart(of id: UUID, in ctx: ModelContext) -> Date? {
        let desc = FetchDescriptor<HistoryItem>(predicate: #Predicate<HistoryItem> { $0.conversationId == id })
        return ((try? ctx.fetch(desc)) ?? []).map { $0.recordedUntil ?? $0.createdAt }.max()
    }

    /// A meeting left in progress whose summary rewrite ended (Kimi, I3
    /// re-review). A result completes it. A rewrite that could not run yet is
    /// not counted as a failure: it waits, longer each time up to 30 min, and
    /// is tried again — a Pro user offline for a few minutes does not lose it —
    /// up to `maxRewriteWaits` times in a row. One
    /// that ran and failed counts; the third completes the meeting with the
    /// summary it has. With no model and no key at all it can never run, and
    /// the meeting is completed at once rather than left "in progress".
    func rewriteEnded(_ id: UUID, result: RewriteResult, now: Date = Date()) {
        settlingNow.remove(id)
        switch result {
        case .done:
            finishSettling(id)
        case .impossible:
            NSLog("[ConversationGrouper] meeting %@ — no model or key to rewrite its summary, closed with the summary it has",
                  id.uuidString.prefix(8) as CVarArg)
            finishSettling(id)
        case .later:
            let waits = (rewriteWaits[id] ?? 0) + 1
            rewriteWaits[id] = waits
            if waits >= Self.maxRewriteWaits {
                NSLog("[ConversationGrouper] meeting %@ — summary rewrite could not run %d times, closed with the summary it has",
                      id.uuidString.prefix(8) as CVarArg, waits)
                finishSettling(id)
                return
            }
            rewriteNotBefore[id] = now.addingTimeInterval(min(Self.maxRewriteWaitSeconds, 60 * pow(2, Double(waits - 1))))
        case .failed:
            let attempts = (failedRewrites[id] ?? 0) + 1
            failedRewrites[id] = attempts
            if attempts >= Self.maxRewriteAttempts {
                NSLog("[ConversationGrouper] meeting %@ — summary rewrite failed %d times, closed with the summary it has",
                      id.uuidString.prefix(8) as CVarArg, attempts)
                finishSettling(id)
            }
        }
    }

    /// Whether a recording not yet saved continues this settling meeting. One
    /// stopped more than `saveHoldSeconds` ago no longer does.
    static func continues(_ meeting: Conversation, with recording: RecordingContext, now: Date) -> Bool {
        guard mayResume(meeting, with: recording) else { return false }
        if let stopped = recording.stoppedAt, now.timeIntervalSince(stopped) > saveHoldSeconds { return false }
        let meetingEnd = meeting.finishedAt ?? meeting.updatedAt
        let stop = recording.stoppedAt ?? now
        let gap = max(meeting.startedAt, recording.startedAt).timeIntervalSince(min(meetingEnd, stop))
        return gap <= meetingJoinWindowSeconds
    }

    private func run(_ processing: Processing) {
        if let process { return process(processing) }
        if processing.regenerate {
            Task { @MainActor [weak self] in
                guard let generator = AppDelegate.shared?.structuredGenerator else { return }
                let access = generator.hasAccess(mayUseLocal: true)
                let outcome = access ? await generator.generate(conversationId: processing.id, isRegeneration: true) : .notNow
                self?.rewriteEnded(processing.id, result: RewriteResult(outcome, hadAccess: access))
            }
        } else {
            scheduleOnClose(for: processing.id, knownTranscript: processing.knownTranscript,
                            onQueued: processing.settles ? { [weak self] in self?.finishSettling(processing.id) } : nil)
        }
    }

    /// Close a specific conversation explicitly (e.g. meeting stop button).
    func closeConversation(id: UUID) {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let conv = try? ctx.fetch(descriptor).first else { return }
        close(conv, in: ctx)
        try? ctx.save()
    }

    // MARK: - Private

    /// Find active dictation conversation within gap window, OR create a new one.
    /// A meeting part JOINS a settling meeting of the same recording within
    /// `meetingJoinWindowSeconds` — handles lid bounce / wake-from-sleep
    /// without fragmenting one real call into N rows. Returns the conversation
    /// and what `assign` processes once the part is saved.
    /// What `assign` does with a meeting once its part is placed.
    private enum MeetingProcessing { case none, thisPart, allParts }

    private func activeOrNewConversation(source: String, at time: Date, recording: RecordingContext?, meetingDurationSec: Double? = nil, in ctx: ModelContext) -> (Conversation, MeetingProcessing) {
        let groupSource = source == "meeting" ? "meeting" : "dictation"
        let callContext = recording?.callName

        if groupSource == "meeting" {
            // ITER-083 — a meeting is final when a person stopped it or the
            // next event began (or the save had no snapshot); the app's own end
            // leaves it settling, open for a continuation, until the sweep.
            let isFinal = recording?.outcome != .ended
            // JOIN — a settling meeting of the same observed recording whose
            // parts lie within the join window of this one, on real times.
            if let recording, let stop = recording.stoppedAt,
               let meeting = settlingMeeting(joining: recording, from: recording.startedAt, to: stop, in: ctx) {
                let start = recording.startedAt
                NSLog("[ConversationGrouper] 🔁 joining meeting %@ (callContext=%@)",
                      meeting.id.uuidString.prefix(8) as CVarArg, callContext ?? "nil")
                meeting.startedAt = min(meeting.startedAt, start)
                meeting.finishedAt = max(meeting.finishedAt ?? stop, stop)
                return (meeting, isFinal ? .allParts : .none)
            }
            // Fresh meeting conversation.
            // Back-date `startedAt` by the actual recording length so the row
            // shows the real duration. If duration is unknown (legacy callers),
            // fall back to `time` so behavior is no worse than before.
            let started = recording?.startedAt ?? meetingDurationSec.map { time.addingTimeInterval(-$0) } ?? time
            let conv = Conversation(source: "meeting", startedAt: started)
            conv.status = "settling"
            conv.finishedAt = recording?.stoppedAt ?? time
            conv.callContext = callContext
            if let recording { Self.record(recording, on: conv) }
            ctx.insert(conv)
            // scheduleOnClose moved to caller (`assign`) so we can pass the
            // in-memory transcript through and bypass the cross-context race.
            NSLog("[ConversationGrouper] Fresh meeting conv %@ (callContext=%@, duration=%.0fs, %@)",
                  conv.id.uuidString.prefix(8) as CVarArg,
                  callContext ?? "nil",
                  meetingDurationSec ?? 0, conv.status)
            return (conv, isFinal ? .thisPart : .none)
        }

        // Dictation: find in-progress dictation conversation within gap window.
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate {
                $0.source == "dictation" && $0.status == "inProgress" && !$0.discarded
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        if let active = try? ctx.fetch(descriptor).first,
           time.timeIntervalSince(active.updatedAt) <= Self.dictationGapSeconds {
            return (active, .none)
        }

        // No active conversation within gap — close any stragglers + open fresh.
        // (closeStaleConversations would also catch them, but be proactive on assign.)
        if let stale = try? ctx.fetch(descriptor).first {
            close(stale, in: ctx)
        }

        let fresh = Conversation(source: "dictation", startedAt: time)
        ctx.insert(fresh)
        return (fresh, .none)
    }

    /// ITER-083 — the settling meeting this part continues, if any: the same
    /// observed recording, with the gap between their intervals (either order —
    /// a short later part can be saved before a long earlier one) within the
    /// join window.
    private func settlingMeeting(joining recording: RecordingContext, from start: Date, to stop: Date,
                                 in ctx: ModelContext) -> Conversation? {
        let desc = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.source == "meeting" && !$0.discarded && $0.status == "settling" },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return ((try? ctx.fetch(desc)) ?? []).first { meeting in
            guard Self.mayResume(meeting, with: recording) else { return false }
            let meetingEnd = meeting.finishedAt ?? meeting.updatedAt
            let gap = max(meeting.startedAt, start).timeIntervalSince(min(meetingEnd, stop))
            return gap <= Self.meetingJoinWindowSeconds && !settlingNow.contains(meeting.id)
        }
    }

    /// ITER-083 — a part resumes a meeting only when both are the same
    /// observed recording: the same calendar occurrence, or both without one.
    /// The call name alone joined two different occurrences of an event with
    /// the same title (every untitled event is "Meeting"), and a part with a
    /// context never resumes a meeting saved before contexts existed — the
    /// meeting would keep no origin and its event could still be guessed.
    /// A save without a snapshot keeps the call-name rule.
    static func mayResume(_ recent: Conversation, with recording: RecordingContext?) -> Bool {
        guard let recording else { return true }
        guard recent.recordingOrigin != nil, recent.calendarOccurrenceKey == recording.occurrenceKey else { return false }
        // Without an event, the call is all there is to go by.
        if recording.occurrenceKey == nil {
            guard let name = recording.callName, recent.callContext == name else { return false }
        }
        return true
    }

    /// ITER-083 — what the recording observed, onto its meeting: how it
    /// started and, for a calendar start, the occurrence. Written here, before
    /// any summary or extractor reads the meeting, so the task extractor has
    /// the event's title and attendees from its first run.
    static func record(_ recording: RecordingContext, on conv: Conversation) {
        conv.recordingOrigin = recording.origin.rawValue
        guard let event = recording.event else { return }
        conv.calendarEventId = event.eventID
        conv.calendarOccurrenceKey = event.key
        conv.calendarEventTitle = event.rawTitle
        conv.calendarEventStartDate = event.start
        conv.calendarEventEndDate = event.end
        conv.calendarAttendeesJSON = (try? JSONEncoder().encode(event.attendees))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private func close(_ conv: Conversation, in ctx: ModelContext) {
        conv.status = "completed"
        conv.finishedAt = Date()
        conv.updatedAt = Date()
        scheduleOnClose(for: conv.id)
    }

    /// Fire-and-forget work on a closed conversation:
    /// 1. StructuredGenerator — title/overview/category/icon (spec://BACKLOG#C1.2)
    /// 2. MemoryExtractor — full-conversation memory extraction (spec://iterations/ITER-001)
    /// 3. TaskExtractor — full-conversation action items (spec://BACKLOG#B1)
    ///
    /// Replaces the previous per-transcript triggers. Running on close gives each
    /// extractor the whole conversation context — needed for resolution, assignee, dedup.
    ///
    /// Delay raised to 2s because meeting conversations are created + their HistoryItem
    /// is saved in the same tick (single-shot flow). The fresh ModelContext that
    /// StructuredGenerator opens can race the SwiftData commit — 300ms was occasionally
    /// too short and produced "Quick note (empty)" placeholder titles.
    ///
    /// `knownTranscript` is the in-memory transcript text we already hold from
    /// `assign()`. Passing it bypasses the SwiftData re-fetch entirely — no
    /// cross-context race, no retry-with-empty-result fallback. (2026-05-01:
    /// even with the in-memory filter fix, fresh ModelContexts sometimes still
    /// miss just-committed HistoryItem rows. Skipping the fetch is the only
    /// reliable cure.)
    /// `onQueued` — called once the summary has run (or is queued on disk) and
    /// the extractors are queued: a settling meeting is completed there.
    private func scheduleOnClose(for conversationId: UUID, knownTranscript: String? = nil,
                                 onQueued: (() -> Void)? = nil) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            _ = self
            guard let app = AppDelegate.shared else { return }
            // ITER-075 step 1 (1.5) — the calendar link first: the task
            // extractor reads it when it starts. Then this conversation's own
            // summary, in its turn (the Library and the recap show it), and
            // then its memories and tasks. The close waits for no other
            // conversation's summary: the rest of that queue runs on its own.
            await app.structuredGenerator.linkCalendar(conversationId)
            await app.structuredGenerator.summarizeClosed(conversationId, knownTranscript: knownTranscript)
            app.memoryExtractor.triggerOnConversationClose(conversationId: conversationId)
            app.taskExtractor.triggerOnConversationClose(conversationId: conversationId)
            onQueued?()
            app.scheduleMeetingRecap(conversationId)
        }
    }
}
