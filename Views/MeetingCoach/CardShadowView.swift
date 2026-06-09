import AppKit

/// Draws ONLY the drop shadow of the Meeting Copilot card, in its own
/// `ignoresMouseEvents` window placed just behind the card window.
///
/// Why a separate window: keeping the shadow here lets the *card* window be
/// sized exactly to the visible card, so only the card receives clicks/drags
/// while the shadow halo (and all empty space around it) clicks straight
/// through to the app underneath. Matches the previous SwiftUI shadow
/// (`.shadow(color: .black.opacity(0.35), radius: 28, y: 14)`).
final class CardShadowView: NSView {
    private let shadowLayer = CALayer()

    /// Transparent breathing room on each side between the view bounds and the
    /// card silhouette the shadow is cast from. Equals the window's shadow
    /// padding so the inset rect lines up with the card window on top.
    private let inset: CGFloat

    init(frame frameRect: NSRect, inset: CGFloat) {
        self.inset = inset
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowLayer.masksToBounds = false
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.35
        shadowLayer.shadowRadius = 28
        // Non-flipped NSView: negative y = downward, matching SwiftUI's y: 14.
        shadowLayer.shadowOffset = CGSize(width: 0, height: -14)
        layer?.addSublayer(shadowLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        shadowLayer.frame = bounds
        let cardRect = bounds.insetBy(dx: inset, dy: inset)
        // An explicit shadowPath casts the shadow along the card silhouette
        // even though the layer itself draws nothing — so we get the halo
        // without an opaque fill obscuring the app behind.
        shadowLayer.shadowPath = CGPath(
            roundedRect: cardRect,
            cornerWidth: MW.rLarge,
            cornerHeight: MW.rLarge,
            transform: nil
        )
    }
}
