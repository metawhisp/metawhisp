import Foundation
import SwiftData

/// Action item extracted from voice, calendar, or screen activity.
///
/// Lifecycle (status field, reference-pattern StagedTaskStorage analog):
/// - `"committed"` — visible in main Tasks list. Sources with STRONG signal land here:
///   voice dictation (user said it aloud), explicit calendar events, user-promoted candidates.
/// - `"staged"` — hidden from main list, shown in "REVIEW CANDIDATES" section. Sources
///   with WEAK signal land here: LLM inference from screen OCR (ScreenExtractor,
///   RealtimeScreenReactor). User promotes ✓ → committed, or rejects ✗ → dismissed.
/// - `"dismissed"` — soft-deleted. Kept in DB for dedup history but hidden everywhere.
///
/// spec://BACKLOG#B1 + iterations/ITER-007-staged-tasks
@Model
final class TaskItem {
    var id: UUID
    /// Action description. ≤15 words, starts with verb, no time references (those go in dueAt).
    var taskDescription: String
    var completed: Bool
    /// Optional due date, extracted separately from description by LLM.
    var dueAt: Date?
    /// Which voice transcript (HistoryItem) this came from, if any.
    var sourceTranscriptId: UUID?
    /// Foreign key to `Conversation.id`. Set at insert time via extractor.
    /// spec://BACKLOG#C1.3
    var conversationId: UUID?
    /// Foreign key to `ScreenContext.id` when task was extracted from screen.
    /// `ActionItemRecord.screenshotId`. Nullable.
    /// spec://BACKLOG#Phase2.R2
    var screenContextId: UUID?
    /// App where user was when the transcription happened.
    var sourceApp: String?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    /// Soft delete — excluded from queries but row retained.
    /// Kept for backward-compat. New code prefers checking `status == "dismissed"`.
    var isDismissed: Bool
    /// Lifecycle state. Optional so SwiftData lightweight migration adds the column
    /// without a versioning plan. `nil` is treated as `"committed"` (legacy rows).
    /// New writes always set an explicit value.
    var status: String?
    /// OpenAI text-embedding-3-small 1536d Float32 vector, packed as raw Data.
    /// Used for semantic dedup + semantic retrieval. Nil → fallback to string match.
    /// spec://iterations/ITER-008-embeddings
    var embedding: Data?

    /// Owner of the action — `nil` means the user themselves (My task).
    /// Non-nil means someone else owes the user this delivery (Waiting-on bin).
    /// Captured from extraction context: explicit delegation ("я попросил Васю X")
    /// or co-commitment ("мы решили что Вася X" with user inside "мы").
    /// Bare third-person mentions without delegation → SKIP entirely (handled in extractor).
    /// spec://iterations/ITER-013-action-items-owners
    var assignee: String?

    init(
        taskDescription: String,
        dueAt: Date? = nil,
        sourceTranscriptId: UUID? = nil,
        sourceApp: String? = nil,
        conversationId: UUID? = nil,
        screenContextId: UUID? = nil,
        status: String = "committed",
        assignee: String? = nil
    ) {
        self.id = UUID()
        self.taskDescription = taskDescription
        self.completed = false
        self.dueAt = dueAt
        self.sourceTranscriptId = sourceTranscriptId
        self.sourceApp = sourceApp
        self.conversationId = conversationId
        self.screenContextId = screenContextId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isDismissed = false
        self.status = status
        self.assignee = assignee
    }

    /// Effective status — treat legacy `nil` as `"committed"` (rows from before the
    /// Staged Tasks migration).
    var effectiveStatus: String { status ?? "committed" }

    /// True if this task belongs to the user themselves (no third-party owner).
    /// Existing rows from before ITER-013 have `assignee == nil` → naturally MY.
    /// spec://iterations/ITER-013-action-items-owners
    var isMyTask: Bool {
        guard let a = assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else {
            return true
        }
        return false
    }
}
