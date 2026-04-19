import Foundation
import SwiftData

/// Persisted screen context record.
/// Stores only extracted text — screenshots are NOT saved to disk.
@Model
final class ScreenContext {
    var id: UUID
    var timestamp: Date
    var appName: String
    var windowTitle: String
    var ocrText: String
    /// Optional LLM-generated summary of the context.
    var summary: String?
    /// Foreign key to active `Conversation.id` at capture time.
    /// Nullable while there's no in-progress conversation. Phase 2 will populate via
    /// ScreenContextService when linking screen activity to conversations.
    /// spec://BACKLOG#C1.3
    var conversationId: UUID?

    init(appName: String, windowTitle: String, ocrText: String, conversationId: UUID? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.appName = appName
        self.windowTitle = windowTitle
        self.ocrText = ocrText
        self.conversationId = conversationId
    }
}
