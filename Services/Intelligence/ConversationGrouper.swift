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

    /// Window for meeting RESUMPTION (lid-bounce / wake-from-sleep / brief
    /// network blip). If a meeting closed less than this many minutes ago for
    /// the SAME callContext (Google Meet / Zoom / etc), the next meeting
    /// recording is appended to it instead of opening a fresh row. Prevents
    /// the «one real call → 5 conversations in Tasks» fragmentation user
    /// reported on 2026-04-29.
    static let meetingResumeWindowSeconds: TimeInterval = 600   // 10 min

    /// Assign a freshly-saved HistoryItem to an active Conversation or create a new one.
    /// Called by TranscriptionCoordinator after `historyService.save(result)`.
    /// `callContext` (e.g. "Google Meet") enables meeting RESUMPTION across
    /// brief gaps caused by lid-bounce or wake-from-sleep.
    /// `meetingDurationSec` (when source == "meeting") is the actual length of
    /// the recorded audio in seconds. Used to back-date `startedAt` so the
    /// conversation row reflects real recording duration. Without this, fresh
    /// meetings get `startedAt == finishedAt == now()` → duration always 0,
    /// and the recap-popup `durationSec >= 60` guard kills the popup.
    @discardableResult
    func assign(
        historyItem: HistoryItem,
        callContext: String? = nil,
        meetingDurationSec: Double? = nil
    ) -> Conversation? {
        guard let container = modelContainer else { return nil }
        let ctx = ModelContext(container)

        let source = historyItem.source ?? "microphone"
        let (conv, isFreshMeeting) = activeOrNewConversation(
            source: source,
            at: historyItem.createdAt,
            callContext: callContext,
            meetingDurationSec: meetingDurationSec,
            in: ctx
        )

        historyItem.conversationId = conv.id
        conv.updatedAt = historyItem.createdAt
        try? ctx.save()

        // Schedule structured-gen / extractors here (not inside
        // `activeOrNewConversation`) so we can pass the in-memory transcript
        // through, dodging the cross-ModelContext race that produced "Quick
        // note (empty)" placeholders even after the predicate-vs-filter fix.
        if isFreshMeeting {
            scheduleOnClose(for: conv.id, knownTranscript: historyItem.displayText)
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
    /// Meetings RESUME a recently-closed conversation if `callContext` matches
    /// and the close was within `meetingResumeWindowSeconds` — handles lid
    /// bounce / wake-from-sleep without fragmenting one real call into N rows.
    /// Returns (conversation, didCreateFreshMeeting). `didCreateFreshMeeting`
    /// is true only for the brand-new "single-shot" meeting branch — caller
    /// uses it to decide whether to fire `scheduleOnClose` with the
    /// in-memory transcript right after `assign()` saves.
    private func activeOrNewConversation(source: String, at time: Date, callContext: String?, meetingDurationSec: Double? = nil, in ctx: ModelContext) -> (Conversation, Bool) {
        let groupSource = source == "meeting" ? "meeting" : "dictation"

        if groupSource == "meeting" {
            // RESUME path — try to find a meeting with the same callContext
            // that closed within the resume window.
            if let cc = callContext, !cc.isEmpty {
                var resumeDesc = FetchDescriptor<Conversation>(
                    predicate: #Predicate {
                        $0.source == "meeting" && !$0.discarded && $0.callContext == cc
                    },
                    sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
                )
                resumeDesc.fetchLimit = 1
                if let recent = try? ctx.fetch(resumeDesc).first,
                   time.timeIntervalSince(recent.updatedAt) <= Self.meetingResumeWindowSeconds {
                    // Re-open the recent meeting. Status flips back to inProgress
                    // so downstream code (popup, recap, structured-gen) treats
                    // it as still ongoing. finishedAt cleared — will be re-set
                    // when this resumed segment closes.
                    NSLog("[ConversationGrouper] 🔁 RESUMING meeting %@ (callContext=%@, gap=%.0fs)",
                          recent.id.uuidString.prefix(8) as CVarArg,
                          cc,
                          time.timeIntervalSince(recent.updatedAt))
                    recent.status = "inProgress"
                    recent.finishedAt = nil
                    return (recent, false)
                }
            }
            // Fresh meeting conversation.
            // Back-date `startedAt` by the actual recording length so the row
            // shows the real duration. If duration is unknown (legacy callers),
            // fall back to `time` so behavior is no worse than before.
            let started = meetingDurationSec.map { time.addingTimeInterval(-$0) } ?? time
            let conv = Conversation(source: "meeting", startedAt: started)
            conv.status = "completed"
            conv.finishedAt = time
            conv.callContext = callContext
            ctx.insert(conv)
            // scheduleOnClose moved to caller (`assign`) so we can pass the
            // in-memory transcript through and bypass the cross-context race.
            NSLog("[ConversationGrouper] Fresh meeting conv %@ (callContext=%@, duration=%.0fs)",
                  conv.id.uuidString.prefix(8) as CVarArg,
                  callContext ?? "nil",
                  meetingDurationSec ?? 0)
            return (conv, true)
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
            return (active, false)
        }

        // No active conversation within gap — close any stragglers + open fresh.
        // (closeStaleConversations would also catch them, but be proactive on assign.)
        if let stale = try? ctx.fetch(descriptor).first {
            close(stale, in: ctx)
        }

        let fresh = Conversation(source: "dictation", startedAt: time)
        ctx.insert(fresh)
        return (fresh, false)
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
    private func scheduleOnClose(for conversationId: UUID, knownTranscript: String? = nil) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            _ = self
            await AppDelegate.shared?.structuredGenerator.generate(
                conversationId: conversationId,
                knownTranscript: knownTranscript
            )
            AppDelegate.shared?.memoryExtractor.triggerOnConversationClose(conversationId: conversationId)
            AppDelegate.shared?.taskExtractor.triggerOnConversationClose(conversationId: conversationId)
        }
    }
}
