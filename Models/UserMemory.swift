import Foundation
import SwiftData

/// Structured fact about the user, extracted from screen activity + transcripts.
/// Ported 's MemoryExtraction architecture — key to personalized Insights.
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
    /// counterpart: `MemoryRecord.screenshotId`. Nullable — voice-extracted memories have nil.
    /// spec://BACKLOG#Phase2.R2
    var screenContextId: UUID?
    /// Absolute file path when memory was extracted from a file (Obsidian note, .md/.txt).
    /// Nullable — other sources have nil.
    /// spec://BACKLOG#Phase3.E1
    var sourceFile: String?
    var createdAt: Date
    var updatedAt: Date
    /// OpenAI text-embedding-3-small 1536d Float32 vector, packed as raw Data.
    /// Used for semantic dedup + semantic retrieval in MetaChat RAG.
    /// Nullable — legacy rows and rows inserted without LLM access have nil and
    /// fall back to substring matching. EmbeddingService backfill fills missing ones.
    /// spec://iterations/ITER-008-embeddings
    var embedding: Data?

    // Enrichment fields (ITER-010 — reference-pattern memory metadata):
    // - `headline`: ≤6 word label rendered as the primary line in the Memories
    //   UI and in MetaChat retrieval previews. Lets the user scan a list quickly
    //   without reading every full content sentence.
    // - `reasoning`: WHY this fact was stored — short justification pulled from
    //   the source context. The chat LLM cites this when explaining where a
    //   memory came from ("Mentioned in Q2 standup on Apr 21").
    // - `tagsCSV`: comma-separated tags for category filtering (e.g. "work,product").
    // Optional so SwiftData migration adds the columns without a versioning plan.
    var headline: String?
    var reasoning: String?
    var tagsCSV: String?

    /// Structured-extraction fields (2026-04-28). When the LLM identifies
    /// that a memory is ABOUT a person / project / decision, it fills these
    /// so MetaChat can surface clean entries (e.g. `PERSON · Sam Smith
    /// — community building partner`) instead of quoting noisy raw transcripts.
    /// Nil for legacy rows and for facts without a clear subject.
    /// `kind`: "person" | "project" | "decision" | "preference" | "fact"
    /// `subject`: canonical name (for person — full name; for project — name)
    /// `characterization`: clean one-liner, ASR-noise-free, ≤15 words
    var kind: String?
    var subject: String?
    var characterization: String?

    /// Project this memory belongs to. Drives ObsidianExporter folder
    /// placement: `Memories/<project>/<date>--<slug>.md`. Nil → "General".
    /// Added 2026-05-12 (ITER-035 Obsidian sync v2). SwiftData lightweight
    /// migration: Optional field added without schema version bump, legacy
    /// rows get nil = General bucket.
    var project: String?

    /// ITER-071.6 — a fact the hourly screen analysis PROPOSED, not one the
    /// user stands behind. Stored so nothing is lost, excluded from what the
    /// assistant treats as known about the user until confirmed.
    ///
    /// 858 screen-derived facts had accumulated with no confirmation step at
    /// all: a misread became something the assistant believed about you,
    /// permanently, unless you found it in a list and removed it.
    var needsReview: Bool = false

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
