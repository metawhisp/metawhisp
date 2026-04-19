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
}
