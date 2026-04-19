import Foundation
import SwiftData

/// Action item extracted from a voice transcription.
/// Mirrors Omi's `ActionItem` in `backend/models/structured.py`.
///
/// spec://BACKLOG#B1
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
    /// Omi's `ActionItemRecord.screenshotId`. Nullable.
    /// spec://BACKLOG#Phase2.R2
    var screenContextId: UUID?
    /// App where user was when the transcription happened.
    var sourceApp: String?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    /// Soft delete — excluded from queries but row retained.
    var isDismissed: Bool

    init(
        taskDescription: String,
        dueAt: Date? = nil,
        sourceTranscriptId: UUID? = nil,
        sourceApp: String? = nil,
        conversationId: UUID? = nil,
        screenContextId: UUID? = nil
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
    }
}
