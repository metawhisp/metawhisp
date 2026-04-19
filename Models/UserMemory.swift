import Foundation
import SwiftData

/// Structured fact about the user, extracted from screen activity + transcripts.
/// Ported from Omi's MemoryExtraction architecture — key to personalized Insights.
///
/// spec://iterations/ITER-001#architecture.model
@Model
final class UserMemory {
    var id: UUID
    /// Fact content. Max 15 words (validated at insert by MemoryExtractor).
    var content: String
    /// "system" — fact about the user (projects, tools, preferences, network).
    /// "interesting" — wisdom from others the user can learn from (quote source).
    var category: String
    /// App where this was captured (e.g. "Slack", "Xcode").
    var sourceApp: String
    /// Window title at capture time, optional.
    var windowTitle: String?
    /// LLM confidence 0.0-1.0. Threshold 0.7 applied at insert.
    var confidence: Double
    /// Short summary of what user was doing when this was extracted.
    var contextSummary: String?
    /// Soft delete — keeps row for audit but excludes from queries/prompts.
    var isDismissed: Bool
    /// Foreign key to `Conversation.id`. Set by extractor at insert time.
    /// Nullable for legacy rows that predate C1.3.
    /// spec://BACKLOG#C1.3
    var conversationId: UUID?
    /// Foreign key to `ScreenContext.id` when memory was extracted from screen, not voice.
    /// Omi's counterpart: `MemoryRecord.screenshotId`. Nullable — voice-extracted memories have nil.
    /// spec://BACKLOG#Phase2.R2
    var screenContextId: UUID?
    /// Absolute file path when memory was extracted from a file (Obsidian note, .md/.txt).
    /// Nullable — other sources have nil.
    /// spec://BACKLOG#Phase3.E1
    var sourceFile: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        content: String,
        category: String,
        sourceApp: String,
        confidence: Double,
        windowTitle: String? = nil,
        contextSummary: String? = nil,
        conversationId: UUID? = nil,
        screenContextId: UUID? = nil,
        sourceFile: String? = nil
    ) {
        self.id = UUID()
        self.content = content
        self.category = category
        self.sourceApp = sourceApp
        self.confidence = confidence
        self.windowTitle = windowTitle
        self.contextSummary = contextSummary
        self.isDismissed = false
        self.conversationId = conversationId
        self.screenContextId = screenContextId
        self.sourceFile = sourceFile
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
