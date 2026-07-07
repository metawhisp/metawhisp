import AppKit

/// ITER-050 B2.1 — the ONE source of truth for `NSWindow.collectionBehavior`
/// across every MetaWhisp window and panel.
///
/// History: the "click a button → thrown to an empty Space" bug recurred for
/// months because each window hand-rolled its own behavior array and the main
/// window relied on `.moveToActiveSpace` + an activation-policy flip — a
/// fragile, macOS-version-dependent dance that macOS 26 re-broke. Overlay
/// panels on `.canJoinAllSpaces` never threw once. So: all windows now join
/// all Spaces, and `WindowBehaviorGuardTests` fails the build if any window
/// code strays from these constants.
///
/// `.fullScreenAuxiliary` is mandatory everywhere: without it, showing a
/// window while the user is inside another app's fullscreen Space forces
/// macOS to kick them out to a neighboring desktop.
enum MWWindowBehavior {
    /// Titled app windows (main window, onboarding) DURING order-in: joining
    /// all Spaces at show time means activation can never trigger a Space
    /// switch. `MainWindowController` restores `mainParked` on the next
    /// runloop turn so an OPEN window doesn't follow the user across Spaces
    /// (review finding: a permanently sticky 1440×1000 window on every
    /// desktop is its own regression).
    static let main: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    /// Titled app windows AFTER order-in: parked on the Space they appeared
    /// on. Re-opening from another Space goes through the orderOut → sticky →
    /// orderFront cycle in `MainWindowController.open()`.
    static let mainParked: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]

    /// Floating overlay panels pinned in place on every Space (recording
    /// pill, notifications, meeting recap, meeting coach).
    static let overlay: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

    /// Floating overlays that may move with normal Space transitions
    /// (voice-question pill).
    static let overlayFollowing: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
}
