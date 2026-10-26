import Foundation

/// Whether the main window may stay where it is when the user moves to
/// another Space.
///
/// The window belongs to exactly one Space while visible (`.moveToActiveSpace`
/// moves it only when it is ordered front). A window left visible on the
/// Space the user swiped away from is what macOS drags the user to when the
/// app is activated from elsewhere — a popover button, a card, the Dock icon.
/// So it is unbound instead, and `MainWindowController.open()` orders it front
/// again on the Space the user is actually on (2026-09-08; the order-front
/// itself moves the window since 2026-10-19).
///
/// `.canJoinAllSpaces` was tried and rejected — a 1440×1000 window on every
/// desktop is its own regression (`MWWindowBehavior`).
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
