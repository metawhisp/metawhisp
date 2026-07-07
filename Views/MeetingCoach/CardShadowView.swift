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
    /// Corner radius of the card silhouette — parametrized (ITER-050 B2.2) so
    /// FloatingVoice (r14) and MeetingRecap (rLarge) reuse this view instead
    /// of the broken ClickThroughHostingView.
    private let cornerRadius: CGFloat

    init(
        frame frameRect: NSRect,
        inset: CGFloat,
        cornerRadius: CGFloat = MW.rLarge,
        shadowRadius: CGFloat = 28,
        shadowOpacity: Float = 0.35,
        shadowYOffset: CGFloat = 14
    ) {
        self.inset = inset
        self.cornerRadius = cornerRadius
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowLayer.masksToBounds = false
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = shadowOpacity
        shadowLayer.shadowRadius = shadowRadius
        // Non-flipped NSView: negative y = downward, matching SwiftUI's y offset.
        shadowLayer.shadowOffset = CGSize(width: 0, height: -shadowYOffset)
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
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
    }
}
