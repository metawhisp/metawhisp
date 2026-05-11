import AppKit
import SwiftUI

extension Notification.Name {
    static let switchMainTab = Notification.Name("MetaWhisp.switchMainTab")
    /// Posted with `object: UUID` (Conversation.id). LibraryView switches its
    /// section to `.conversations` and ConversationsView opens detail for that ID.
    /// Used by Dashboard's calendar event rows to drill into a recorded meeting.
    static let openConversation = Notification.Name("MetaWhisp.openConversation")
}

/// Manages the main application window (singleton — only one instance).
///
/// **Close semantics — hide-on-close, NOT close-and-recreate.**
/// The red traffic-light button does NOT destroy the NSWindow. We intercept
/// the close via `windowShouldClose(_:)` returning `false`, then `orderOut` the
/// window (hides it without binding it to any Space) and flip the activation
/// policy back to `.accessory` (hides from Dock). The NSWindow object stays
/// alive in `self.window` for the next `open()` to reuse — which keeps the
/// user's frame, scroll positions, expanded sections, etc.
///
/// Two prior states this design replaces:
///
/// 1. **Originally**: `willClose` observer nilled `self.window` → every
///    `open()` was a fresh NSWindow → first open from inside someone else's
///    fullscreen Space had no Space association, so AppKit picked the active
///    Space (the other app's fullscreen) and — since our `windowBehavior` is
///    empty (no `.fullScreenAuxiliary`) — forced the other app OUT of
///    fullscreen to make room. User saw "switches me to empty Desktop briefly
///    then back to Claude with MetaWhisp on top."
///
/// 2. **First fix attempt**: keep the NSWindow alive across red-button closes
///    by not nilling `self.window`. Worked for the flicker, BUT introduced a
///    new bug: a closed-but-alive NSWindow is still "associated with" the
///    Space where it last appeared. `NSApp.activate()` from another Space
///    would route the user to that bound Space — except the window is hidden
///    there, so the user lands on an empty Desktop with no MetaWhisp anywhere.
///    User report 2026-05-11: «теперь при фокусе на окне аппки кидает на
///    отдельный другой экран где нет аппки».
///
/// 3. **Current design (this file)**: `windowShouldClose` returns `false` +
///    `orderOut`. The window is hidden, not closed; macOS unbinds it from
///    its Space. Re-show via `makeKeyAndOrderFront` puts it on whatever
///    Space the user is currently on — clean navigation, no flicker, no
///    empty-Space throw. Trade-off: when user is inside someone else's
///    fullscreen, the window opens overlaid on that Space (because that's
///    "wherever the user is"). Mitigated by the fact that there's no
///    `.fullScreenAuxiliary` flag — AppKit handles the de-fullscreen
///    transition itself, smoothly.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Collection behavior applied to the main window on create / reactivate.
    /// **Default-managed (empty option set).** Reverted from
    /// `[.moveToActiveSpace, .fullScreenAuxiliary]` (2026-05-10) — the prior
    /// pair forced the window to overlay whatever fullscreen-Space the user
    /// was in. Empty set is the macOS-standard behavior: window lives on its
    /// own Desktop Space, AppKit handles the transition.
    private static let windowBehavior: NSWindow.CollectionBehavior = []

    func open(
        coordinator: TranscriptionCoordinator,
        modelManager: ModelManagerService,
        recorder: AudioRecordingService,
        historyService: HistoryService,
        projectAggregator: ProjectAggregator,
        initialTab: MainWindowView.SidebarTab? = nil
    ) {
        // Reuse the NSWindow if it exists (visible OR hidden via the hide-on-
        // close delegate). Recreating each open would lose the user's frame
        // autosave + SwiftUI state. `orderOut` (used by the delegate) unbinds
        // the window from any Space, so `makeKeyAndOrderFront` here places it
        // on the user's current Space without dragging anyone else's
        // fullscreen along.
        if let window {
            if let tab = initialTab {
                NotificationCenter.default.post(name: .switchMainTab, object: tab)
            }
            // The hide-on-close delegate set policy to .accessory; flip back.
            NSApp.setActivationPolicy(.regular)
            window.collectionBehavior = Self.windowBehavior
            // Bind to user's current Space, then activate. Reverse order
            // would tell macOS to switch user to wherever MetaWhisp lives —
            // which is "nowhere visible" since we orderOut'd, so the user
            // bounces. `activate()` (without `ignoringOtherApps:`) is
            // gentler — smooth navigation, no forced snap.
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        // First-ever creation of the main window for this app launch.
        // Subsequent opens reuse this NSWindow instance via the branch above.
        let contentView = MainWindowView(
            coordinator: coordinator,
            modelManager: modelManager,
            recorder: recorder,
            historyService: historyService,
            initialTab: initialTab ?? .dashboard
        )
        .environmentObject(projectAggregator)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MetaWhisp"
        window.minSize = NSSize(width: 900, height: 600)
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.isReleasedWhenClosed = false
        // Persist user's last frame across launches via UserDefaults.
        window.setFrameAutosaveName("MetaWhispMainWindow")
        window.collectionBehavior = Self.windowBehavior
        // Install delegate so `windowShouldClose` intercepts the red button.
        window.delegate = self

        self.window = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        NSLog("[MainWindow] Opened")
    }

    func close() {
        // Manual API close — same hide-on-close path as the red button.
        // Goes through windowShouldClose → returns false → orderOut.
        // We call `performClose` (NOT `close`) so the delegate is consulted.
        window?.performClose(nil)
    }

    // MARK: - NSWindowDelegate

    /// Intercept red-button / Cmd-W / `performClose`. Hides the window
    /// (orderOut) instead of letting AppKit actually close it. Net effect
    /// is identical to "close" from the user's POV — window disappears,
    /// app goes back to menubar-only — but the NSWindow stays alive for
    /// the next `open()` to reuse, and is NOT bound to any Space while
    /// hidden, so re-opening from a different Space doesn't tug the user
    /// across desktops.
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in
            sender.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            NSLog("[MainWindow] Hidden (orderOut)")
        }
        return false
    }
}
