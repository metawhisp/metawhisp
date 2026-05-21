import AppKit
import SwiftUI

/// NSHostingView that lets clicks fall through the shadow-envelope padding
/// to whatever app sits beneath the floating panel.
///
/// **2026-05-20 — rewrite.** Previous version only overrode `hitTest(_:)`
/// to return nil for the outer ring. That stops the host view itself from
/// claiming the click, but AppKit still routes the event to the enclosing
/// NSPanel which DOES claim it — net effect: nothing happens, but the
/// click is consumed and the underlying app misses it. User-reported:
/// «всё это пространство всё зона клика» — they couldn't click through
/// the shadow halo to apps below the Meeting Copilot widget.
///
/// **Real fix:** toggle `NSWindow.ignoresMouseEvents` dynamically via
/// `NSTrackingArea`. When the cursor is OVER the inner card region, the
/// window catches clicks (buttons work). When the cursor is OUTSIDE the
/// card (in the shadow envelope), the window forwards every click to the
/// next window in z-order — the underlying app gets it as if the panel
/// weren't there.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    /// Pixel margin around the card that's transparent shadow padding.
    /// Set from the owning window controller after init.
    var shadowInset: CGFloat = 0 {
        didSet { needsUpdateTrackingArea = true; updateTrackingAreas() }
    }

    private var cardTrackingArea: NSTrackingArea?
    private var needsUpdateTrackingArea: Bool = true

    /// Track whether the cursor is currently over the inner card region
    /// so we know to toggle the host window's `ignoresMouseEvents`
    /// correctly when the view re-lays out (frame change can move the
    /// inner rect out from under a stationary cursor).
    private var cursorIsOverCard: Bool = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Start in pass-through mode — the panel acts as if it isn't
        // there until the cursor enters the actual card area. This is
        // the difference vs the old hitTest-only approach.
        window?.ignoresMouseEvents = true
        needsUpdateTrackingArea = true
        updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        needsUpdateTrackingArea = true
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard needsUpdateTrackingArea else { return }
        needsUpdateTrackingArea = false

        if let existing = cardTrackingArea {
            removeTrackingArea(existing)
            cardTrackingArea = nil
        }

        // The inner rect is the card-sized region; outside it = shadow
        // envelope = pass-through.
        let inner = bounds.insetBy(dx: shadowInset, dy: shadowInset)
        guard inner.width > 0, inner.height > 0 else { return }

        let area = NSTrackingArea(
            rect: inner,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cardTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        cursorIsOverCard = true
        window?.ignoresMouseEvents = false
    }

    override func mouseExited(with event: NSEvent) {
        cursorIsOverCard = false
        window?.ignoresMouseEvents = true
    }
}
