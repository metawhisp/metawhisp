import Foundation
import SwiftData

/// A single message in the Chat thread.
/// Mirrors Omi's `Message` (`backend/models/chat.py`) with minimal fields — no files/voice/sharing in MVP.
///
/// spec://BACKLOG#B2
@Model
final class ChatMessage {
    var id: UUID
    /// "human" — user typed; "ai" — assistant response.
    var sender: String
    var text: String
    var createdAt: Date
    /// If the AI response errored, capture for UI display.
    var errorText: String?

    init(sender: String, text: String, errorText: String? = nil) {
        self.id = UUID()
        self.sender = sender
        self.text = text
        self.errorText = errorText
        self.createdAt = Date()
    }
}
