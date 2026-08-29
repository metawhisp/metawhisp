import Foundation

/// What the Screen Agent is doing right now, in words a person can act on.
///
/// The feature's normal state is silence, which makes it indistinguishable from
/// being broken. A user whose allowlist is empty, whose permission was revoked,
/// or who paused it three days ago sees exactly what a working agent looks
/// like: nothing. Then they conclude it does not work and turn it off.
///
/// Every state here names the thing to do about it, because "not running" on
/// its own is a complaint rather than an answer.
struct ScreenAgentHealth: Equatable {

    enum State: Equatable {
        case off
        case paused
        case noPermission
        /// On, but nothing is allowed to be looked at.
        case nothingAllowed
        case excludedHere(app: String)
        /// On, but this window belongs to another assistant and we do not read
        /// those. Our decision, not the user's setting.
        case skippedAsAssistant(app: String)
        case watching(app: String)
        case degraded(reason: String)
    }

    let state: State

    /// One line, present tense, no jargon.
    var summary: String {
        switch state {
        case .off: return "Off"
        case .paused: return "Paused"
        case .noPermission: return "Needs Screen Recording permission"
        case .nothingAllowed: return "On, but no apps are allowed yet"
        case .excludedHere(let app): return "Not watching \(app) — you excluded it"
        case .skippedAsAssistant(let app):
            return "Not watching \(app) — MetaWhisp doesn't read other assistants\u{2019} windows"
        case .watching(let app): return "Watching \(app)"
        case .degraded(let reason): return "Not working — \(reason)"
        }
    }

    /// What to do about it, or nil when nothing is wrong.
    var action: String? {
        switch state {
        case .off: return "Turn on Screen Agent to use it."
        case .paused: return "Resume to start getting comments again."
        case .noPermission: return "Grant Screen Recording in System Settings, then reopen this."
        case .nothingAllowed: return "Add the apps you want watched, or switch to excluding instead."
        case .excludedHere, .skippedAsAssistant: return nil
        case .watching: return nil
        case .degraded: return "Restarting MetaWhisp usually clears this."
        }
    }

    /// Whether this state means the user is getting nothing and probably does
    /// not know why.
    var isSilentlyIdle: Bool {
        switch state {
        case .nothingAllowed, .noPermission, .degraded: return true
        case .off, .paused, .excludedHere, .skippedAsAssistant, .watching: return false
        }
    }

    /// Work out the state from the pieces that decide it. Pure, so the wording
    /// can be argued with without a running app.
    static func evaluate(
        featureEnabled: Bool,
        paused: Bool,
        hasPermission: Bool,
        allowlistIsActiveAndEmpty: Bool,
        currentAppAllowed: Bool,
        currentAppIsAssistant: Bool,
        currentApp: String?,
        captureOutcome: ScreenCaptureOutcome
    ) -> ScreenAgentHealth {
        // Ordered by what the user would have to change first. Telling someone
        // to grant a permission for a feature they turned off is noise.
        if !featureEnabled { return .init(state: .off) }
        if paused { return .init(state: .paused) }
        if !hasPermission { return .init(state: .noPermission) }
        if allowlistIsActiveAndEmpty { return .init(state: .nothingAllowed) }
        if case .permissionDenied = captureOutcome { return .init(state: .noPermission) }
        if case .ambiguousWindow = captureOutcome {
            return .init(state: .degraded(reason: "cannot tell which window is focused"))
        }
        if case .persistenceFailed = captureOutcome {
            return .init(state: .degraded(reason: "screen history could not be saved"))
        }
        if case .captureFailed = captureOutcome {
            return .init(state: .degraded(reason: "the screen could not be read"))
        }
        if !currentAppAllowed, let app = currentApp {
            return .init(state: .excludedHere(app: app))
        }
        // Their own setting outranks ours: it is the more useful answer and the
        // one they can change.
        if currentAppIsAssistant, let app = currentApp {
            return .init(state: .skippedAsAssistant(app: app))
        }
        return .init(state: .watching(app: currentApp ?? "your screen"))
    }
}
