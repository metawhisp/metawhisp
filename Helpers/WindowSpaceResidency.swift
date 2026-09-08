import Foundation

/// Whether the main window may stay where it is when the user moves to
/// another Space.
///
/// The window parks with `[.fullScreenAuxiliary]`, so it belongs to exactly
/// one Space and stays visible there. That is what gives macOS something to
/// drag the user to: activating the app from a different Space — a popover
/// button, a card, the Dock icon — brings the app's window forward, and the
/// user goes with it. The guard that existed lived inside
/// `MainWindowController.open()`, which the app's own SpaceTrace log shows was
/// never reached on that path (2026-09-08: two `create:` entries, no `reuse:`).
///
/// `.canJoinAllSpaces` was tried and rejected — a 1440×1000 window on every
/// desktop is its own regression (`MWWindowBehavior`). So the window is
/// unbound instead, and `MainWindowController.open()` puts it back on the
/// Space the user is actually on.
///
/// Pure, because this is the third attempt at this bug and the rule deserves
/// to be arguable without switching desktops by hand.
enum WindowSpaceResidency {

    enum Decision: Equatable {
        case leaveAlone
        /// Order the window out. It is not closed: the next open brings it
        /// back, on whichever Space the user is on then.
        case unbind

        var shouldReopenOnNextActivation: Bool { self == .unbind }
    }

    /// - Parameters:
    ///   - appIsActive: the user is IN MetaWhisp. Swiping away from a window
    ///     you are using must not take it from you — it should still be there
    ///     when you swipe back.
    static func decide(isVisible: Bool, isOnActiveSpace: Bool, appIsActive: Bool) -> Decision {
        guard isVisible, !isOnActiveSpace, !appIsActive else { return .leaveAlone }
        return .unbind
    }
}
