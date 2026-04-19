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
