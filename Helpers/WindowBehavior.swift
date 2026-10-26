import AppKit

/// ITER-050 B2.1 — the ONE source of truth for `NSWindow.collectionBehavior`
/// across every MetaWhisp window and panel.
///
/// History: the "click a button → thrown to another Space" bug recurred for
/// months because each window hand-rolled its own behavior array, and because
/// of one wrong turn: on 2026-07-07 the main window's `.moveToActiveSpace`
/// was replaced by a transient `.canJoinAllSpaces` around the order-in, then
/// "parked" on `[.fullScreenAuxiliary]` a runloop later. Parking put the
/// window back on the Space it was last on — a hidden window keeps its Space
/// — and the user was dragged there on the next open. The app's own
/// `[SpaceTrace]` log on the owner's Mac shows it: 9 of 10 re-opens between
/// 2026-10-15 and 2026-10-19 landed `onActiveSpace=no` right after
/// `makeKeyAndOrderFront` (`MainWindowController`). So the main window
/// carries `.moveToActiveSpace` for its whole life again — and, since the
/// same day, is never kept hidden at all: closed means released, and the
/// next open makes a new window around the kept content.
/// `WindowBehaviorGuardTests` fails the build if any window code strays from
/// these constants.
///
/// `.fullScreenAuxiliary` is mandatory everywhere: without it, showing a
/// window while the user is inside another app's fullscreen Space forces
/// macOS to kick them out to a neighboring desktop.
enum MWWindowBehavior {
    /// Titled app windows (main window, onboarding): when ordered front, the
    /// window moves to the Space the user is on — AppKit's own rule for a
    /// window that must come to the user; never sticky (a 1440×1000 window on
    /// every desktop is its own regression), never parked. A visible window
    /// the user swiped away from is unbound by `WindowSpaceResidency`, so an
    /// activation from another Space has nothing to drag the user to.
    static let main: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

    /// Floating overlay panels pinned in place on every Space (recording
    /// pill, notifications, meeting recap, meeting coach).
    static let overlay: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

    /// Floating overlays that may move with normal Space transitions
    /// (voice-question pill).
    static let overlayFollowing: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
}
