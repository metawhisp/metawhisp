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
    /// ITER-067 — the durable Screen Agent comment this card is showing, when
    /// it is showing one. Lets the stack report what became of the card:
    /// timed out, closed, or pushed off by newer ones. Without it those all
    /// looked identical to "nothing happened", and a comment the user never got
    /// to read was indistinguishable from one they ignored.
    var screenAgentItemID: UUID?

    /// The app this was read from, when the card asserts something about the
    /// screen. Rendered beside the badge as «Chrome · 14:07», which turns an
    /// assertion the reader would have to take on faith into one they can
    /// check. Cards that report their own doing — a task added, a recording
    /// saved — leave it nil: there is nothing to cite.
    var sourceApp: String?

    /// Click → execute. Pass `nil` for purely informational cards.
    let onTap: (@MainActor () -> Void)?

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        body: String,
        onTap: (@MainActor () -> Void)? = nil,
        screenAgentItemID: UUID? = nil,
        sourceApp: String? = nil,
        proactiveItems: Void? = nil
    ) {
        // ITER-027.5 — `proactiveItems` parameter retained as a no-op for
        // the few call sites that still pass `proactiveItems: nil`. They'll
        // be cleaned up in a follow-up; for now this keeps the diff minimal.
        _ = proactiveItems
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.createdAt = Date()
        self.onTap = onTap
        self.screenAgentItemID = screenAgentItemID
        self.sourceApp = sourceApp
    }

    enum Kind {
        case task             // task extracted from voice / screen
        case call             // call detected (Zoom/Meet/Teams)
        case recordingStopped // meeting recorder auto-stopped — recording REALLY ended
        case recordingOverrun // recording CONTINUES past calendar slot — info only (user can tap to stop)
        case recap            // meeting recap (light variant — heavy block lives in MeetingRecapWindow)
        case dayRecap         // the once-a-day recap — the one announcement a day worth making
        case advice           // proactive advice item
        case proactive        // multi-row proactive surface (memory / past decision / waiting-on)
        case signIn           // web sign-in / Pro activation result (post deep-link)

        var icon: String {
            switch self {
            case .task:             return "checklist"
            case .call:             return "phone.fill"
            case .recordingStopped: return "stop.circle.fill"
            // A stopwatch says "time is passing" and nothing more. This card
            // fires because the recording outran its calendar slot, which the
            // user may want to stop — the symbol has to say so.
            case .recordingOverrun: return "clock.badge.exclamationmark"
            case .recap:            return "doc.text"
            case .dayRecap:         return "calendar"
            case .advice:           return "sparkles"
            // A lightbulb means "here is an idea". This surface carries the
            // opposite: something already decided, or something being waited
            // on. That is history, and history has its own symbol.
            case .proactive:        return "clock.arrow.circlepath"
            case .signIn:           return "checkmark.seal.fill"
            }
        }

        /// Colour is reserved for a state of the world, never for which sort of
        /// card this is. Purple used to mean "advice" and yellow "context" —
        /// a filing system the reader has no key to and no reason to learn,
        /// and it spent the one signal that should have been available when
        /// something is actually wrong.
        ///
        /// Exactly one kind qualifies: a recording still running past the
        /// calendar slot that was supposed to end it.
        var accent: Color {
            switch self {
            case .recordingOverrun: return MW.processing
            default:                return MW.textSecondary
            }
        }

        var label: String {
            switch self {
            case .task:             return "NEW TASK"
            case .call:             return "CALL DETECTED"
            case .recordingStopped: return "RECORDING STOPPED"
            case .recordingOverrun: return "STILL RECORDING"
            case .recap:            return "MEETING RECAP"
            case .dayRecap:         return "DAY RECAP"
            case .advice:           return "ADVICE"
            case .proactive:        return "CONTEXT"
            case .signIn:           return "ACCOUNT"
            }
        }
    }
}
