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
/// **Close semantics — close for real, keep the content.** The red button,
/// Cmd-W and `close()` close the NSWindow, and `windowWillClose` releases it.
/// No window of this app is ever kept hidden: a hidden window keeps the Space
/// it was last on, and showing it there is what switched the user to another
/// desktop in every report since 2026-05-11. The window's content — the
/// SwiftUI hosting view, with the tab, the scroll positions and any draft —
/// is kept in `content` and put into the next window, so a re-open looks
/// like the window never went away.
///
/// The states this design replaces:
///
/// 1. **Originally**: `willClose` observer nilled `self.window` → every
///    `open()` was a fresh NSWindow → first open from inside someone else's
///    fullscreen Space had no Space association, so AppKit picked the active
///    Space (the other app's fullscreen) and — since our `windowBehavior` was
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
/// 3. **2026-07-07 to 2026-10-19**: `windowShouldClose` returns `false` +
///    `orderOut`, and the re-show wrapped `makeKeyAndOrderFront` in a
///    transient `.canJoinAllSpaces`, then "parked" the window on
///    `[.fullScreenAuxiliary]` a runloop later. The belief was that a hidden
///    window has no Space. It has: parking put it back on the Space it was
///    last on, and the user — the window now key there — was switched to it.
///    The `[SpaceTrace]` log on the owner's Mac: 9 of 10 re-opens landed
///    `onActiveSpace=no` right after the order-front (2026-10-15..19).
///
/// 4. **2026-10-19, same day**: the hidden window kept, with
///    `.moveToActiveSpace` for its whole life to move it on the re-show.
///    Right by AppKit's rule, but it still kept the one thing every report
///    came from: a window hidden on a Space.
///
/// 5. **Current design (this file)**: no hidden window. Closed means
///    released; the content stays; the next open builds a new window around
///    it — a new window is made on the Space the user is on. The window
///    keeps `MWWindowBehavior.main` — `.moveToActiveSpace` and
///    `.fullScreenAuxiliary` — so an open while it is visible on another
///    Space moves it to the user instead of the user to it, and a window
///    left visible on another Space is closed on the Space change
///    (`unbindIfLeftBehind`). After every order-front the trace checks
///    `isOnActiveSpace`; a `VIOLATION` line means the rule broke again.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    /// The window while it is open; nil once it is closed and released.
    private(set) var window: NSWindow?
    /// The window's content, kept across closes: SwiftUI's state lives in it.
    private(set) var content: NSView?

    /// Whether a person can currently see the main window. SwiftUI's
    /// `onAppear` fires for a hidden, miniaturised or occluded window just the
    /// same, so "shown" has to be asked of AppKit, not of the view tree.
    var isShowing: Bool {
        guard let window, NSApp.isActive else { return false }
        return window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
    }

    /// ITER-055 — black-box trace for the recurring «throws me to another
    /// screen / Space» bug. Logs where a window actually lands vs where the
    /// user is (cursor screen), so the next repro pins the cause instead of a
    /// theory. Cheap; safe to keep on. Grep `[SpaceTrace]`.
    /// The user has moved to another Space. A window left visible on the one
    /// they came from is exactly what macOS drags them back to on the next
    /// activation — a popover button, a card, the Dock icon (the recurring
    /// "it scrolls me to another desktop" report, 2026-09-08). It is closed —
    /// released, its content kept — and `open()` makes a new window where
    /// the user actually is.
    func unbindIfLeftBehind() {
        guard let window else { return }
        let decision = WindowSpaceResidency.decide(
            isVisible: window.isVisible,
            isOnActiveSpace: window.isOnActiveSpace,
            appIsActive: NSApp.isActive)
        guard decision == .unbind else { return }
        Self.logPlacement(window, "space-change:closing")
        window.close()
        NSLog("[MainWindow] window was left on another Space — closed so activation cannot drag you there")
    }

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

    /// Collection behavior of the main window, set once when it is created
    /// and never changed: `.moveToActiveSpace` brings it to the user's Space
    /// whenever it is ordered front (2026-10-19; see the history above).
    /// `WindowBehaviorGuardTests` enforces the single source of truth.
    private static let windowBehavior: NSWindow.CollectionBehavior = MWWindowBehavior.main

    /// Shows `window` on the Space the user is on, in the order that never
    /// drags the user anywhere, and checks that it landed there:
    ///   1. a window still visible on another Space is ordered out first — a
    ///      visible window is not moved by an order-front (2026-06-10);
    ///   2. `makeKeyAndOrderFront` — `.moveToActiveSpace` moves it here;
    ///   3. `setActivationPolicy(.regular)` after — the Dock promotion happens
    ///      with the window already placed;
    ///   4. no `NSApp.activate()` — the explicit cause of the owner's
    ///      "thrown to another screen" report of 2026-05-13.
    /// On the next runloop turn the trace records where the window is. Not on
    /// the active Space — the rule broke — it is logged as a VIOLATION and
    /// ordered front once more so the user is not dragged.
    private func show(_ window: NSWindow, phase: String) {
        if window.isVisible && !window.isOnActiveSpace {
            window.orderOut(nil)
        }
        Self.recenterIfOffscreen(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak window] in
            Self.logPlacement(window, "\(phase):after-order-front")
            guard let window, window.isVisible, !window.isOnActiveSpace else { return }
            NSLog("[SpaceTrace] VIOLATION — the main window is not on the user's Space after the order-front")
            window.orderOut(nil)
            window.makeKeyAndOrderFront(nil)
            Self.logPlacement(window, "\(phase):after-retry")
        }
    }

    func open(
        coordinator: TranscriptionCoordinator,
        modelManager: ModelManagerService,
        modelPreparer: ModelPreparer,
        recorder: AudioRecordingService,
        historyService: HistoryService,
        projectAggregator: ProjectAggregator,
        initialTab: MainWindowView.SidebarTab? = nil
    ) {
        open(tab: initialTab) {
            let contentView = MainWindowView(
                coordinator: coordinator,
                modelManager: modelManager,
                modelPreparer: modelPreparer,
                recorder: recorder,
                historyService: historyService,
                initialTab: initialTab ?? .dashboard
            )
            .environmentObject(projectAggregator)
            return NSHostingView(rootView: contentView)
        }
    }

    /// Shows the main window: the one open now, brought to the user's Space;
    /// else a new window around the content kept from the last one, or
    /// around `make()`'s on the first open of this launch. `tab`: the tab to
    /// switch to; the first content starts on it.
    func open(tab: MainWindowView.SidebarTab?, make: () -> NSView) {
        if let tab, content != nil {
            NotificationCenter.default.post(name: .switchMainTab, object: tab)
        }
        if let window {
            Self.logPlacement(window, "reuse:on-entry")
            show(window, phase: "reuse")
            return
        }
        let content = self.content ?? make()
        self.content = content

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MetaWhisp"
        window.minSize = NSSize(width: 900, height: 600)
        window.contentView = content
        window.center()
        // Released by `windowWillClose`, which drops this controller's reference.
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
        window.delegate = self

        self.window = window

        show(window, phase: "create")

        NSLog("[MainWindow] Opened")
    }

    func close() {
        // Manual API close — the same path as the red button: `performClose`
        // (NOT `close`) so the delegate is consulted, then `windowWillClose`.
        window?.performClose(nil)
    }

    // MARK: - NSWindowDelegate

    /// The window is closing — the red button, Cmd-W, `close()` or a Space
    /// change that left it behind. Its content leaves it for the next window,
    /// the controller's reference is dropped so the window is released, and
    /// the app goes back to the menu bar. Nothing of the app stays hidden on
    /// any Space.
    nonisolated func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        Task { @MainActor in
            guard let closing, closing === window else { return }
            closing.contentView = NSView()
            window = nil
            NSApp.setActivationPolicy(.accessory)
            NSLog("[MainWindow] Closed and released; its content kept")
        }
    }
}
