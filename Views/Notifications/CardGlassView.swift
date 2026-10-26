import AppKit

/// The glass the top-right cards stand on — the notification card and the
/// errand card (ITER-076 I-11), one surface for both: an `NSVisualEffectView`
/// blurring what is behind the window, a tint gradient over it, a single
/// diagonal sheen and a lit top edge, clipped to the card's corners. It never
/// answers a click. The card itself casts the shadow (`castShadow`): this view
/// clips, and a clipped view would cut its own shadow off.
@MainActor
final class CardGlassView: NSView {
    /// A view that is never the answer to a click. The glass is three stacked
    /// layers under the text; letting any of them win a hit test makes taps and
    /// hover depend on which one happened to be on top.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private let corner: CGFloat
    private let blurView = NSVisualEffectView()
    /// The tint, the sheen and the lit edge live on their own view rather than
    /// as loose sublayers of this one.
    ///
    /// This view also holds the blur as a SUBVIEW, and a subview's backing
    /// layer does not exist until the view joins a window — so at construction
    /// time the blur is simply absent from `layer.sublayers`, and AppKit
    /// inserts it later at an index of its own choosing. Ordering that depends
    /// on when AppKit decides to back a view is not ordering. As a sibling view
    /// added after the blur, this one is above it by the only rule AppKit
    /// actually guarantees.
    private let glassView = PassThroughView()
    private let tintLayer = CAGradientLayer()
    private let sheenLayer = CAGradientLayer()
    private let rimLayer = CALayer()

    init(corner: CGFloat) {
        self.corner = corner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = corner
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        // `.behindWindow` is what makes it glass rather than a grey panel: the
        // desktop and whatever the user is working in show through it.
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        addSubview(blurView)

        // Added after the blur, so it is above it — the one ordering rule that
        // does not depend on AppKit's layer-backing schedule.
        glassView.wantsLayer = true
        addSubview(glassView)

        tintLayer.startPoint = CGPoint(x: 0.08, y: 0)
        tintLayer.endPoint = CGPoint(x: 0.62, y: 1)
        glassView.layer?.addSublayer(tintLayer)

        // One diagonal sheen across the top-left, fading out before the middle.
        // More than one reads as a texture rather than as light.
        sheenLayer.startPoint = CGPoint(x: 0, y: 0)
        sheenLayer.endPoint = CGPoint(x: 0.85, y: 1)
        sheenLayer.locations = [0, 0.26, 0.46]
        glassView.layer?.addSublayer(sheenLayer)

        // The lit top edge. A border alone is flat on every side; real glass
        // catches the light where it faces up.
        glassView.layer?.addSublayer(rimLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported — programmatic only.")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The card's shadow, on the card's own layer.
    static func castShadow(on layer: CALayer?) {
        guard let layer else { return }
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.44
        layer.shadowOffset = CGSize(width: 0, height: -10)
        layer.shadowRadius = 26
    }

    /// CALayer holds resolved `CGColor`s, which do not follow the system the
    /// way `NSColor` does — so the card calls this whenever its appearance
    /// changes.
    func applyColors(dark: Bool) {
        tintLayer.colors = dark
            ? [NSColor(calibratedWhite: 0.19, alpha: 0.62).cgColor,
               NSColor(calibratedWhite: 0.10, alpha: 0.72).cgColor,
               NSColor(calibratedWhite: 0.07, alpha: 0.76).cgColor]
            : [NSColor(calibratedWhite: 1.00, alpha: 0.62).cgColor,
               NSColor(calibratedWhite: 0.97, alpha: 0.54).cgColor,
               NSColor(calibratedWhite: 0.94, alpha: 0.58).cgColor]

        sheenLayer.colors = [
            NSColor(calibratedWhite: 1, alpha: dark ? 0.13 : 0.62).cgColor,
            NSColor(calibratedWhite: 1, alpha: dark ? 0.05 : 0.20).cgColor,
            NSColor(calibratedWhite: 1, alpha: 0).cgColor
        ]

        layer?.borderColor = NSColor(calibratedWhite: dark ? 1 : 0, alpha: dark ? 0.11 : 0.10).cgColor
        rimLayer.backgroundColor = NSColor(calibratedWhite: 1, alpha: dark ? 0.16 : 0.85).cgColor
    }

    /// Fills `box`, the card's bounds.
    func place(in box: NSRect) {
        frame = box
        blurView.frame = bounds
        glassView.frame = bounds
        // Implicit animations would make the glass slide behind the text while
        // the card is still growing into its measured height.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        sheenLayer.frame = bounds
        rimLayer.frame = NSRect(x: corner * 0.55, y: bounds.height - 1, width: bounds.width - corner * 1.1, height: 1)
        CATransaction.commit()
    }
}
