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

    /// ITER-055 — black-box trace for the recurring «throws me to another
    /// screen / Space» bug. Logs where a window actually lands vs where the
    /// user is (cursor screen), so the next repro pins the cause instead of a
    /// theory. Cheap; safe to keep on. Grep `[SpaceTrace]`.
    static func logPlacement(_ w: NSWindow?, _ phase: String) {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        let mouseScreen = screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) }
        let mainScreen = screens.firstIndex { $0 == NSScreen.main }
        if let w {
            let winScreen = screens.firstIndex { $0.frame.intersects(w.frame) }
            NSLog("[SpaceTrace] %@ — winFrame=%@ winScreen=%@ mouseScreen=%@ mainScreen=%@ onActiveSpace=%@ visible=%@ screens=%d",
                  phase, NSStringFromRect(w.frame),
                  winScreen.map(String.init) ?? "OFF-ALL-SCREENS",
                  mouseScreen.map(String.init) ?? "?", mainScreen.map(String.init) ?? "?",
                  w.isOnActiveSpace ? "yes" : "no", w.isVisible ? "yes" : "no", screens.count)
        } else {
            NSLog("[SpaceTrace] %@ — no window; mouseScreen=%@ mainScreen=%@ screens=%d",
                  phase, mouseScreen.map(String.init) ?? "?", mainScreen.map(String.init) ?? "?", screens.count)
        }
    }

    /// ITER-055 — if the autosave-restored frame is not visible on ANY current
    /// screen (stale frame from a now-disconnected / rearranged display), the
    /// window opens «somewhere» off the user's view. Re-center it on the screen
    /// the user is actually looking at (cursor screen, else main). Only fires
    /// when the frame is genuinely off all screens — an intentional placement on
    /// a real secondary display is left alone (the trace log will reveal if THAT
    /// is the reported case, and we fix precisely then).
    static func recenterIfOffscreen(_ w: NSWindow) {
        let visibleOnSome = NSScreen.screens.contains { $0.visibleFrame.intersects(w.frame) }
        guard !visibleOnSome else { return }
        let target = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let scr = target else { return }
        let vf = scr.visibleFrame
        let s = w.frame.size
        w.setFrameOrigin(NSPoint(x: vf.midX - s.width / 2, y: vf.midY - s.height / 2))
        NSLog("[SpaceTrace] recentered off-screen window onto cursor screen %@", NSStringFromRect(w.frame))
    }

    /// Collection behavior applied to the main window on create / reactivate.
    ///
    /// ITER-050 B2.1 — `.canJoinAllSpaces` (via `MWWindowBehavior.main`)
    /// replaced the previous `.moveToActiveSpace` + activation-policy dance,
    /// which macOS 26 re-broke: activating the window mid-typing yanked the
    /// user to the Space it was bound to. A join-all-Spaces window IS on the
    /// user's current Space by definition, so activation never needs a Space
    /// switch — the same reason the overlay panels never exhibited the bug.
    /// `WindowBehaviorGuardTests` enforces the single source of truth.
    private static let windowBehavior: NSWindow.CollectionBehavior = MWWindowBehavior.main

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
            Self.logPlacement(window, "reuse:on-entry")
            // Space-throw fix, final form (ITER-050 B2.1): join-all-Spaces is
            // applied TRANSIENTLY around the order-in, so activation can never
            // switch Spaces, then the window parks on the Space it appeared on
            // (a permanently sticky 1440×1000 window on every desktop would be
            // its own regression — review finding).
            window.collectionBehavior = Self.windowBehavior
            // Space-throw fix #2 (2026-06-10): if the window is already
            // VISIBLE on another Space, `makeKeyAndOrderFront` switches the
            // USER to that Space instead («кидает на первый экран» on any
            // button that routes here). Order it out first so re-ordering
            // places it on the current Space.
            if window.isVisible && !window.isOnActiveSpace {
                window.orderOut(nil)
            }
            // ITER-055 — same off-screen guard as the create path: a hidden
            // window's frame may be stranded on a display that's since gone.
            Self.recenterIfOffscreen(window)
            // ORDER MATTERS for Space-throw prevention:
            //   1. makeKeyAndOrderFront FIRST — with join-all-Spaces the
            //      window is on the user's current Space by definition.
            //   2. setActivationPolicy(.regular) AFTER — the dock-app
            //      promotion happens with the window already placed, so
            //      macOS doesn't snap user to the window's last-known Space.
            //   3. NO `NSApp.activate()` — that was the explicit cause of
            //      «приложение кидает в другой экран» reported 2026-05-13.
            window.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async { [weak window] in
                window?.collectionBehavior = MWWindowBehavior.mainParked
                Self.logPlacement(window, "reuse:after-order-front")
            }
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
        // macOS 26 fix — disable window state restoration (auto-saved
        // NSWindow constraints replay on next launch and re-trigger
        // NSISEngine recursion if last layout had a cycle). Frame
        // autosave below still persists position/size in UserDefaults
        // separately, so users keep their window placement across launches.
        window.isRestorable = false
        // Persist user's last frame across launches via UserDefaults.
        window.setFrameAutosaveName("MetaWhispMainWindow")
        // ITER-055 — the autosave restore above can place the window on a
        // now-disconnected / rearranged display → "opens somewhere but not on
        // my screen". Pull it back onto a visible screen before showing.
        Self.logPlacement(window, "create:after-autosave-restore")
        Self.recenterIfOffscreen(window)
        window.collectionBehavior = Self.windowBehavior
        // Install delegate so `windowShouldClose` intercepts the red button.
        window.delegate = self

        self.window = window

        // Order matters here to prevent Space-throw:
        //   1. makeKeyAndOrderFront FIRST — with transient join-all-Spaces
        //      the window appears in the user's current Space by definition.
        //   2. setActivationPolicy(.regular) AFTER — the policy flip from
        //      .accessory → .regular happens once the window is already
        //      where the user is, so macOS doesn't pick a "natural" Space
        //      to drag the user to.
        //   3. NO `NSApp.activate()` — was the trigger for «через несколько
        //      секунд приложение кидает в другой экран». makeKeyAndOrderFront
        //      is sufficient for bringing window forward in current Space.
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        // Park after order-in (see the reuse branch above for the rationale).
        DispatchQueue.main.async { [weak window] in
            window?.collectionBehavior = MWWindowBehavior.mainParked
            Self.logPlacement(window, "create:after-order-front")
        }

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
