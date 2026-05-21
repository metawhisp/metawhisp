import AppKit
import Combine
import SwiftUI

/// Controls the floating Meeting Copilot overlay window (ITER-019.2).
///
/// Architecture:
/// - Shows when `MeetingCoachState.shared.isVisible` flips to true (driven by
///   `LiveMeetingAdvisor.arm/disarm` via `meetingRecorder.isRecording`).
/// - Borderless, non-activating panel anchored to bottom-right of the main
///   screen. Floats above call windows (Zoom/Meet/Teams) but never grabs focus.
/// - Click-through-friendly: ignores mouse events except hover (so the user
///   can dismiss or read without interrupting the meeting).
@MainActor
final class MeetingCoachWindowController {
    private var window: NSPanel?
    private var hostingView: ClickThroughHostingView<MeetingCoachView>?
    private var visibilityCancellable: AnyCancellable?

    init() {
        // Subscribe once at app launch — state changes drive show/hide.
        visibilityCancellable = MeetingCoachState.shared.$isVisible
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] visible in
                if visible { self?.show() } else { self?.hide() }
            }
    }

    private func show() {
        if window == nil { createWindow() }
        guard let window else { return }
        if !window.isVisible {
            positionBottomRight(window)
            window.orderFrontRegardless()
        }
    }

    private func hide() {
        window?.orderOut(nil)
    }

    /// User clicked STOP on the overlay. Route to `AppDelegate` so the same
    /// teardown path runs as the menu-bar STOP button (cancels debounce tasks,
    /// finalizes transcript, persists, fires recap notif, etc.).
    private func handleStopTap() {
        guard let app = AppDelegate.shared else { return }
        // toggleMeetingRecording is the canonical user-driven path — picks
        // start vs stop based on current state.
        app.toggleMeetingRecording()
    }

    private func createWindow() {
        let view = MeetingCoachView(
            state: MeetingCoachState.shared,
            onStop: { [weak self] in
                self?.handleStopTap()
            }
        )
        let hosting = ClickThroughHostingView(rootView: view)
        // Wider/taller than the visible card so shadow (radius 28, y offset 14)
        // doesn't clip at the window boundary. The card itself has internal
        // padding to push it away from these edges. 540×440 leaves comfortable
        // room on every side even with 3 suggestions + transcript footer.
        hosting.frame = NSRect(x: 0, y: 0, width: 540, height: 440)
        hosting.autoresizingMask = [.width, .height]
        // The MeetingCoachView wraps its card in `.padding(42)` (the shadow
        // envelope). Tell the hosting view about it so clicks inside that
        // 42-pt transparent border fall through to whatever app is below
        // (Zoom, browser, etc.) instead of being eaten by the floating panel.
        hosting.shadowInset = 42

        // Borderless, non-activating panel — appears over Zoom etc. without
        // stealing focus. `nonactivatingPanel` is critical so clicking near it
        // doesn't switch app focus mid-call.
        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // shadow is drawn inside SwiftUI for liquid-glass look
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false  // allow hover for tooltips later; not focus-stealing
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true  // user can drag it out of the way
        panel.contentView = hosting

        self.window = panel
        self.hostingView = hosting
    }

    private func positionBottomRight(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        // Margin from screen edges; bottom-right per spec to mirror Apple's
        // own meeting indicators that live in the top-right tray.
        let margin: CGFloat = 16
        let x = visible.maxX - size.width - margin
        let y = visible.minY + margin
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
