import SwiftUI

/// One in-app notification rendered by `MWNotificationStack`.
///
/// Replaces the previous mix of macOS-native `UNUserNotificationCenter` banners
/// + the standalone `ProactiveChipWindow` — both of which lived in the same
/// top-right corner without knowing about each other and visually collided.
/// Now everything routes through one stack with one shape.
///
/// spec://iterations/ITER-026-notification-unification
@MainActor
struct MWNotification: Identifiable {
    let id: UUID
    let kind: Kind
    let title: String
    let body: String
    let createdAt: Date
    /// Click → execute. Pass `nil` for purely informational cards.
    let onTap: (@MainActor () -> Void)?
    /// Multi-row content used ONLY by `.proactive`. The card renders rows
    /// instead of a single body when this is non-nil.
    let proactiveItems: [SurfaceItem]?

    init(
        kind: Kind,
        title: String,
        body: String,
        onTap: (@MainActor () -> Void)? = nil,
        proactiveItems: [SurfaceItem]? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.body = body
        self.createdAt = Date()
        self.onTap = onTap
        self.proactiveItems = proactiveItems
    }

    enum Kind {
        case task             // task extracted from voice / screen
        case call             // call detected (Zoom/Meet/Teams)
        case recordingStopped // meeting recorder auto-stopped
        case recap            // meeting recap (light variant — heavy block lives in MeetingRecapWindow)
        case advice           // proactive advice item
        case proactive        // multi-row proactive surface (memory / past decision / waiting-on)

        var icon: String {
            switch self {
            case .task:             return "text.badge.plus"
            case .call:             return "phone.fill"
            case .recordingStopped: return "stop.circle"
            case .recap:            return "doc.text"
            case .advice:           return "sparkles"
            case .proactive:        return "lightbulb.fill"
            }
        }

        var accent: Color {
            switch self {
            case .task:             return MW.idle
            case .call:             return MW.postProcess
            case .recordingStopped: return MW.textMuted
            case .recap:            return MW.idle
            case .advice:           return Color(red: 0.65, green: 0.40, blue: 1.00)
            case .proactive:        return Color(red: 1.00, green: 0.80, blue: 0.20)
            }
        }

        var label: String {
            switch self {
            case .task:             return "NEW TASK"
            case .call:             return "CALL DETECTED"
            case .recordingStopped: return "RECORDING STOPPED"
            case .recap:            return "MEETING RECAP"
            case .advice:           return "ADVICE"
            case .proactive:        return "CONTEXT"
            }
        }
    }
}
