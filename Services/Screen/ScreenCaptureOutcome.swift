import Foundation

/// How an attempt to read the screen ended.
///
/// The capture path had no way to say this. A failed ScreenCaptureKit grab
/// returned a snapshot carrying the app name, the window title and an empty OCR
/// string — indistinguishable from a genuinely blank window. That row was
/// persisted, the capture mark advanced so the window was never retried, and
/// the agent was woken for a frame nobody had managed to read. Persistence had
/// the same shape: `try? save()` and then fire the callback regardless, so the
/// agent could reason about a row that was never written.
///
/// Naming the outcomes makes the two questions that follow answerable: may this
/// reach the agent, and did this window use up its turn?
enum ScreenCaptureOutcome: Equatable {

    /// A frame was read. Zero characters is a real answer — a blank window —
    /// and the agent is expected to look at it and decide there is nothing to
    /// say.
    case captured(ocrCharacters: Int)

    /// The user's policy says this app is not observed.
    case excluded

    case permissionDenied
    /// More than one window of the front app and nothing to say which has
    /// focus. Reading both and labelling the result with one of them would be
    /// confidently wrong, so the attempt is abandoned.
    case ambiguousWindow
    case captureFailed
    /// The frame was read but could not be stored, so nothing downstream may
    /// treat it as history.
    case persistenceFailed

    /// Only a real read wakes the agent.
    var deliversToAgent: Bool {
        if case .captured = self { return true }
        return false
    }

    var isFailure: Bool {
        switch self {
        case .captured, .excluded: return false
        default: return true
        }
    }

    /// Whether this window's turn is used up.
    ///
    /// A window the app could not read stays eligible for the next poll —
    /// otherwise one failure silences it until the user happens to switch away
    /// and back. An excluded app is settled rather than failed: re-reading it
    /// every tick only burns work to reach the same answer.
    var consumesWindowTurn: Bool {
        switch self {
        case .captured, .excluded: return true
        case .permissionDenied, .ambiguousWindow, .captureFailed, .persistenceFailed: return false
        }
    }

    /// Stable code for logs and metrics. Carries no screen content.
    var reasonCode: String {
        switch self {
        case .captured: return "captured"
        case .excluded: return "excluded"
        case .permissionDenied: return "permission_denied"
        case .ambiguousWindow: return "ambiguous_window"
        case .captureFailed: return "capture_failed"
        case .persistenceFailed: return "persistence_failed"
        }
    }
}
