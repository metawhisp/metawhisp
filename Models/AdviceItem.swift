import Foundation
import SwiftData

/// AI-generated advice/suggestion based on screen context and transcriptions.
@Model
final class AdviceItem {
    var id: UUID
    var content: String
    /// Category: productivity, health, communication, learning, other
    var category: String
    /// Why this advice was given.
    var reasoning: String?
    /// Which app/context triggered the advice.
    var sourceApp: String?
    /// 0.0–1.0 confidence score.
    var confidence: Double
    var isRead: Bool
    var isDismissed: Bool
    var createdAt: Date

    init(content: String, category: String, reasoning: String? = nil, sourceApp: String? = nil, confidence: Double = 0.5) {
        self.id = UUID()
        self.content = content
        self.category = category
        self.reasoning = reasoning
        self.sourceApp = sourceApp
        self.confidence = confidence
        self.isRead = false
        self.isDismissed = false
        self.createdAt = Date()
    }
}
