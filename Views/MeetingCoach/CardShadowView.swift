import AppKit

/// Draws the drop shadow of a card — and, when asked, a coloured glow — in its
/// own `ignoresMouseEvents` window placed just behind the card window.
///
/// Why a separate window: keeping the shadow here lets the *card* window be
/// sized exactly to the visible card, so only the card receives clicks/drags
/// while the shadow halo (and all empty space around it) clicks straight
/// through to the app underneath. Matches the previous SwiftUI shadow
/// (`.shadow(color: .black.opacity(0.35), radius: 28, y: 14)`).
final class CardShadowView: NSView {
    private let shadowLayer = CALayer()
    /// A coloured glow around the card, off unless `glow(_:opacity:)` turns
    /// it on — the voice Island glows red while it listens (ITER-078).
    private let glowLayer = CALayer()

    /// Transparent breathing room on each side between the view bounds and the
    /// card silhouette the shadow is cast from. Equals the window's shadow
    /// padding so the inset rect lines up with the card window on top.
    private let inset: CGFloat
    /// Corner radius of the card silhouette — parametrized (ITER-050 B2.2) so
    /// FloatingVoice and MeetingRecap (rLarge) reuse this view instead of the
    /// broken ClickThroughHostingView. The voice Island changes it with its
    /// shape (ITER-078).
    var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }

    /// Draw only outside the card's outline, for a card that is glass: a
    /// shadow under it would tint it from behind (the voice Island, ITER-078).
    private let cutsOutCard: Bool
    private let cutOut = CAShapeLayer()

    init(
        frame frameRect: NSRect,
        inset: CGFloat,
        cornerRadius: CGFloat = MW.rLarge,
        shadowRadius: CGFloat = 28,
        shadowOpacity: Float = 0.35,
        shadowYOffset: CGFloat = 14,
        cutsOutCard: Bool = false
    ) {
        self.inset = inset
        self.cornerRadius = cornerRadius
        self.cutsOutCard = cutsOutCard
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
        glowLayer.masksToBounds = false
        glowLayer.shadowOffset = .zero
        glowLayer.shadowRadius = 20
        glowLayer.shadowOpacity = 0
        layer?.addSublayer(glowLayer)
        if cutsOutCard {
            cutOut.fillRule = .evenOdd
            layer?.mask = cutOut
        }
    }

    /// Turns the glow on in `color`, or off with nil.
    func glow(_ color: NSColor?, opacity: Float) {
        glowLayer.shadowColor = color?.cgColor
        glowLayer.shadowOpacity = color == nil ? 0 : opacity
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        shadowLayer.frame = bounds
        let cardRect = bounds.insetBy(dx: inset, dy: inset)
        // No wider than the card allows: a radius set before its size may
        // be larger than half of it for one layout.
        let radius = max(0, min(cornerRadius, cardRect.width / 2, cardRect.height / 2))
        // An explicit shadowPath casts the shadow along the card silhouette
        // even though the layer itself draws nothing — so we get the halo
        // without an opaque fill obscuring the app behind.
        let silhouette = CGPath(roundedRect: cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        shadowLayer.shadowPath = silhouette
        glowLayer.frame = bounds
        glowLayer.shadowPath = silhouette
        if cutsOutCard {
            let outside = CGMutablePath()
            outside.addRect(bounds)
            outside.addPath(silhouette)
            cutOut.frame = bounds
            cutOut.path = outside
        }
    }
}
