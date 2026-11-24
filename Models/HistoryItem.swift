import Foundation
import SwiftData

/// Persisted transcription record.
@Model
final class HistoryItem {
    var id: UUID
    var text: String
    var processedText: String?
    var translatedTo: String?
    var language: String?
    var audioDuration: Double
    var processingTime: Double
    var wordCount: Int
    var createdAt: Date
    var modelName: String?
    /// Audio source: "microphone", "system_audio", "meeting"
    var source: String?
    /// Foreign key to `Conversation.id`. Assigned by `ConversationGrouper` after save.
    /// Nullable for legacy rows that predate C1.1.
    /// spec://BACKLOG#C1.1
    var conversationId: UUID?
    /// ITER-083 — a meeting part's own recording interval. `createdAt` is when
    /// the transcript was saved, which can be minutes after the stop, and a
    /// short part's transcription can finish before a long one's. Parts read
    /// in this order. nil for dictations and rows saved before ITER-083.
    var recordedAt: Date?
    var recordedUntil: Date?

    /// ITER-083 — the order a conversation's parts are read in, by every reader
    /// of a transcript: recording order, ties in save order. Save order alone
    /// put a short part before a longer, earlier one whose transcription
    /// finished later.
    static func inRecordingOrder(_ a: HistoryItem, _ b: HistoryItem) -> Bool {
        (a.recordedAt ?? a.createdAt, a.createdAt) < (b.recordedAt ?? b.createdAt, b.createdAt)
    }

    /// The best available text: processed if available, otherwise raw.
    var displayText: String { processedText ?? text }

    init(text: String, language: String?, audioDuration: Double, processingTime: Double) {
        self.id = UUID()
        self.text = text
        self.language = language
        self.audioDuration = audioDuration
        self.processingTime = processingTime
        self.wordCount = text.split(separator: " ").count
        self.createdAt = Date()
    }

    /// Create from a TranscriptionResult.
    convenience init(result: TranscriptionResult) {
        self.init(
            text: result.text,
            language: result.language,
            audioDuration: result.duration,
            processingTime: result.processingTime
        )
    }
}
