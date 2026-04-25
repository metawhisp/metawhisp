import Foundation
import SwiftData

/// Aggregation root for transcripts and linked entities (memories, tasks, screen contexts).
/// Mirrors `Conversation` (`backend/models/conversation.py`) — the core entity around which
/// everything downstream is organized.
/// C1.1 writes: id, startedAt, finishedAt, source, status, discarded, timestamps.
/// C1.2 writes: title, overview, category (via LLM on close).
/// C1.4 writes: starred (user action in UI).
/// Fields are added upfront (all optional/defaulted) to avoid multiple SwiftData migrations.
/// spec://BACKLOG#C1.1
@Model
final class Conversation {
    var id: UUID
    /// First transcript timestamp in this conversation.
    var startedAt: Date
    /// When the conversation closed (silence gap > threshold or explicit close). nil while active.
    var finishedAt: Date?
    /// Source type. Trimmed 's `ConversationSource`:
    /// - "dictation" — grouped Right ⌘ voice inputs
    /// - "meeting"   — MeetingRecorder (mic + system audio) session
    var source: String
    /// Status. Mirrors `ConversationStatus`:
    /// - "inProgress" — still accepting new transcripts
    /// - "completed"  — closed, ready for post-processing
    var status: String
    /// Soft delete / merge marker.
    var discarded: Bool

    // C1.2 fields — populated by StructuredGenerator on conversation close.
    /// LLM-generated Title Case headline ≤10 words. nil until conversation completes.
    var title: String?
    /// LLM-generated 1-2 sentence summary. nil until complete.
    var overview: String?
    /// One of `CategoryEnum` values (personal, work, business, health, etc.). nil until complete.
    var category: String?
    /// SF Symbol name reflecting core subject/mood (monochrome — matches app design).
    /// We diverge here (they generate color Unicode emoji) — our desktop app is minimal/monochrome.
    /// Stored in `emoji` field name for backward schema compat; value is SF Symbol string like "lightbulb" / "chart.bar".
    var emoji: String?

    // C1.4 field — user action in UI.
    var starred: Bool

    var createdAt: Date
    var updatedAt: Date

    /// OpenAI text-embedding-3-small 1536d Float32 vector, packed as raw Data.
    /// Source text = `title + " · " + overview + " " + first ~1200 chars of transcript`.
    /// Written by StructuredGenerator on close, by EmbeddingService.backfill for legacy rows.
    /// Used by ChatService.fetchMeetingsForQuery for semantic ranking — finds the right
    /// call even when the query uses different words ("про цены" → созвон где обсуждали "тарифы").
    /// Nullable: legacy rows + non-Pro users + transient embed failures all have nil and
    /// fall back to recency-only ranking.
    /// spec://iterations/ITER-011-conversation-embeddings
    var embedding: Data?

    /// ITER-014 — primary project/product label extracted by StructuredGenerator on close.
    /// `nil` = no clear project (personal chats, mixed topics). Non-nil = the most concrete
    /// brand/product/codename mentioned ("Overchat", "MetaWhisp", "Atomic Bot launch").
    /// NOT a category (work/personal/etc) — that's `category`. NOT a topic — that's `topicsJSON`.
    /// Canonicalized via `ProjectAlias` table so "Overchat"/"Оверчат"/"OverchatAI" merge.
    /// spec://iterations/ITER-014-project-clustering
    var primaryProject: String?

    /// JSON-encoded `[String]` — secondary topics extracted from this conversation
    /// (e.g. ["pricing", "infra"] for a call about Overchat pricing & infra). 0-3 items.
    /// Used by ProjectAggregator + MetaChat for cross-cutting topic queries.
    /// spec://iterations/ITER-014-project-clustering
    var topicsJSON: String?

    // ITER-021 — Structured meeting summary (5 sections, JSON-encoded `[String]`).
    // Populated by `StructuredGenerator` ON CLOSE for meeting-source conversations.
    // Display-only — `actionItemsJSON` here is a HISTORICAL READ-ONLY record;
    // actionable items are still created as `TaskItem` rows by `TaskExtractor`.
    // All Optional → SwiftData lightweight migration without versioning plan.

    /// Concrete decisions made during the conversation. ≤5 items, each ≤14 words.
    /// Empty/null when nothing decided (LLM instructed to prefer empty over filler).
    var decisionsJSON: String?

    /// Action items mentioned during the conversation (HISTORY only — not actionable).
    /// Coexists with TaskItem rows created by TaskExtractor: this list is for the
    /// detail-view rendering, TaskItems are for the Tasks tab + reminders.
    var actionItemsJSON: String?

    /// People named in the conversation. Single-user dictation: implicit "you", so
    /// this captures OTHER participants. Each entry preserved as spoken
    /// ("Pasha" stays "Pasha", "Майк" stays "Майк").
    var participantsJSON: String?

    /// Memorable verbatim quotes — raw fragments worth re-reading.
    /// LLM extracts up to 3 most striking lines, max 25 words each.
    var keyQuotesJSON: String?

    /// Next-meeting agenda / forward-looking items. Distinct from action items
    /// (which are concrete tasks to do); next steps are topics to bring back up.
    var nextStepsJSON: String?

    // ITER-018 — Calendar cross-reference. Populated by `CalendarLinker` on
    // conversation close (or backfill on launch). Lets the UI show "← Standup
    // with Pasha (10:00 - 10:30)" beside the meeting and lets MetaChat answer
    // "о чём говорили на standup в среду?" by matching a known event.
    /// `EKEvent.eventIdentifier` of the matched calendar event. Nil = no match found.
    var calendarEventId: String?
    /// Snapshot of the event title at link time (event may be edited / deleted later).
    var calendarEventTitle: String?
    /// Snapshot of event start. Used by UI to render time range without re-fetching.
    var calendarEventStartDate: Date?
    /// Snapshot of event end.
    var calendarEventEndDate: Date?
    /// JSON-encoded `[String]` of attendee display names (or emails as fallback).
    /// Snapshotted at link time. Empty array if event was solo or attendees unavailable.
    var calendarAttendeesJSON: String?

    init(source: String, startedAt: Date = Date()) {
        self.id = UUID()
        self.startedAt = startedAt
        self.finishedAt = nil
        self.source = source
        self.status = "inProgress"
        self.discarded = false
        self.title = nil
        self.overview = nil
        self.category = nil
        self.emoji = nil
        self.starred = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - ITER-021 decoded accessors
    // SwiftData stores arrays as JSON strings (flat schema). These accessors
    // decode on read. Cheap — arrays are short (≤5 items). UI uses these directly.

    var decisions: [String]    { Self.decodeStringArray(decisionsJSON) }
    var actionItems: [String]  { Self.decodeStringArray(actionItemsJSON) }
    var participants: [String] { Self.decodeStringArray(participantsJSON) }
    var keyQuotes: [String]    { Self.decodeStringArray(keyQuotesJSON) }
    var nextSteps: [String]    { Self.decodeStringArray(nextStepsJSON) }

    private static func decodeStringArray(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }
}
