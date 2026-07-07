import AppKit
import Combine
import SwiftUI

/// Controls the floating Meeting Copilot overlay (ITER-019.2).
///
/// **Two-window design (2026-06-05).** Click-through is a *structural*
/// property here, not a runtime toggle:
///   - `cardWindow` — sized exactly to the visible card. Interactive and
///     draggable; receives every click that lands on the card.
///   - `shadowWindow` — a child window `shadowPadding` larger on each side that
///     renders ONLY the drop shadow (`CardShadowView`) and has
///     `ignoresMouseEvents = true`. Every click in the shadow halo / empty
///     space passes straight through to the app beneath (Zoom/Meet/etc).
///
/// Replaces the previous single-panel `ClickThroughHostingView` approach, whose
/// `NSTrackingArea` (+ `.inVisibleRect`) made the whole 540×440 canvas
/// clickable — user-reported: clicking the empty space around the card dragged
/// it. ITER-050 B2.2: FloatingVoice + MeetingRecap migrated to this same
/// two-window pattern and `ClickThroughHostingView` was deleted.
@MainActor
final class MeetingCoachWindowController {
    private var cardWindow: NSPanel?
    private var shadowWindow: NSPanel?
    private var shadowView: CardShadowView?
    private var hostingView: SelfSizingHostingView<MeetingCoachView>?
    private var visibilityCancellable: AnyCancellable?

    /// Transparent shadow breathing room around the card, in points. Sized to
    /// fully contain the drop shadow (radius 28 + |offset| 14): a blurred
    /// CoreAnimation shadow has a soft tail beyond radius+offset, so
    /// 2·radius + |offset| = 70 is the no-hard-clip value. The shadow window is
    /// `ignoresMouseEvents`, so enlarging it never affects click-through.
    private let shadowPadding: CGFloat = 70

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
        if cardWindow == nil { createWindows() }
        guard let cardWindow, let shadowWindow else { return }
        if !cardWindow.isVisible {
            positionBottomRight(cardWindow)
            // Order ONLY the parent — children come along. Explicitly ordering
            // a child window (orderOut/orderFront) DETACHES it from its parent;
            // a detached shadow stops following drags. That was the reported
            // «тень отдельно снизу справа всегда» (2026-06-10): after one
            // hide/show cycle the shadow stayed at the default bottom-right
            // spot while the card moved.
            cardWindow.orderFrontRegardless()
            // Defensive re-attach — orderOut on the parent can also drop the
            // child relationship on some macOS versions.
            if cardWindow.childWindows?.contains(shadowWindow) != true {
                cardWindow.addChildWindow(shadowWindow, ordered: .below)
            }
            updateShadowFrame()
        }
    }

    private func hide() {
        // Parent orderOut hides its children too — never order the shadow
        // child directly (it detaches; see `show`).
        cardWindow?.orderOut(nil)
        // Defensive: if the relationship was already broken, the shadow is a
        // free-standing window now — hiding it explicitly is then safe.
        if let shadowWindow, shadowWindow.isVisible,
           cardWindow?.childWindows?.contains(shadowWindow) != true {
            shadowWindow.orderOut(nil)
        }
    }

    /// User clicked STOP on the overlay. Route to `AppDelegate` so the same
    /// teardown path runs as the menu-bar STOP button.
    private func handleStopTap() {
        guard let app = AppDelegate.shared else { return }
        app.toggleMeetingRecording()
    }

    private func createWindows() {
        let hosting = SelfSizingHostingView(rootView: MeetingCoachView(
            state: MeetingCoachState.shared,
            onStop: { [weak self] in self?.handleStopTap() }
        ))
        hosting.onContentSizeChange = { [weak self] size in
            self?.updateCardSize(size)
        }
        self.hostingView = hosting

        // Card window — exactly the visible card. Interactive + draggable.
        // `nonactivatingPanel` so clicking it never steals focus mid-call.
        let card = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        card.isOpaque = false
        card.backgroundColor = .clear
        card.hasShadow = false
        card.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        card.collectionBehavior = MWWindowBehavior.overlay
        card.ignoresMouseEvents = false
        card.hidesOnDeactivate = false
        card.isMovableByWindowBackground = true   // drag the CARD itself to reposition
        card.contentView = hosting

        // Shadow window — child, ordered below the card. Renders only the drop
        // shadow and is transparent to mouse events, so the halo + empty space
        // around the card click through to the app underneath.
        let shadowFrame = card.frame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
        let shadow = NSPanel(
            contentRect: shadowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let shadowContent = CardShadowView(
            frame: NSRect(origin: .zero, size: shadowFrame.size),
            inset: shadowPadding
        )
        shadow.isOpaque = false
        shadow.backgroundColor = .clear
        shadow.hasShadow = false
        shadow.level = card.level
        shadow.collectionBehavior = card.collectionBehavior
        shadow.ignoresMouseEvents = true
        shadow.hidesOnDeactivate = false
        shadow.isMovableByWindowBackground = false
        shadow.contentView = shadowContent

        // Child window so the shadow follows the card automatically when the
        // user drags it (isMovableByWindowBackground) — no manual sync needed
        // for drags; resizes are synced explicitly via `updateShadowFrame`.
        card.addChildWindow(shadow, ordered: .below)

        self.cardWindow = card
        self.shadowWindow = shadow
        self.shadowView = shadowContent

        // Force the first measurement now so the card panel shrinks to the
        // content immediately (before the window is shown), not on a later
        // async layout pass.
        hosting.layoutSubtreeIfNeeded()
        hosting.reportCurrentSize()
    }

    /// Resize the card window to the measured card size, keeping the
    /// bottom-right corner anchored (card grows up/left as suggestions arrive),
    /// then resync the shadow window.
    private func updateCardSize(_ size: CGSize) {
        guard let cardWindow, size.width > 0, size.height > 0 else { return }
        let newSize = NSSize(width: ceil(size.width), height: ceil(size.height))
        var frame = cardWindow.frame
        guard abs(frame.width - newSize.width) > 0.5 ||
              abs(frame.height - newSize.height) > 0.5 else { return }
        frame.origin.x = frame.maxX - newSize.width   // keep right edge
        frame.size = newSize                          // keep bottom edge (origin.y)
        cardWindow.setFrame(frame, display: true)
        updateShadowFrame()
    }

    private func updateShadowFrame() {
        guard let cardWindow, let shadowWindow else { return }
        let frame = cardWindow.frame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
        shadowWindow.setFrame(frame, display: true)
        shadowView?.frame = NSRect(origin: .zero, size: frame.size)
        shadowView?.needsLayout = true
    }

    private func positionBottomRight(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        // Leave room for the shadow envelope so the halo isn't clipped at the
        // screen edge: 16pt visual margin measured from the shadow's outer edge.
        let margin: CGFloat = 16 + shadowPadding
        let x = visible.maxX - size.width - margin
        let y = visible.minY + margin
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
