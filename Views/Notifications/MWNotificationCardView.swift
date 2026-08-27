import AppKit
import SwiftUI  // for Color → NSColor conversion only; no SwiftUI rendering happens

/// Pure AppKit notification card. Replaces the SwiftUI `MWNotificationCard`
/// after Tahoe (macOS 26) repeatedly crashed the app inside NSISEngine
/// while rendering animated SwiftUI cards. By using NSView + CALayer for
/// the chrome and NSTextField for the labels, there's no SwiftUI-to-AppKit
/// constraint bridge at all — the Auto Layout solver only sees a couple of
/// explicit constraints we set ourselves, never the SwiftUI display-list
/// recursion that crashed Tahoe.
///
/// The surface is real glass: an `NSVisualEffectView` blurring what is behind
/// the window, a tint gradient over it, and a single diagonal sheen. The
/// previous card painted an opaque dark fill instead — cheaper in layers, but
/// it read as a foreign rectangle dropped on the desktop rather than something
/// belonging to the system it sits in.
///
/// Layout, top to bottom: a badge row carrying the kind's symbol and, where
/// the card asserts something about the screen, where that was read from;
/// then the title; then the body. No accent bar — colour is a state now, not
/// a category, and lives in the badge alone.
@MainActor
final class MWNotificationCardView: NSView {

    let notification: MWNotification
    private let onClose: () -> Void
    private let onTap: (() -> Void)?
    private let onHover: (Bool) -> Void

    /// Cached height after `layout()` so the stack controller can place
    /// cards without re-measuring through Auto Layout.
    private(set) var measuredHeight: CGFloat = 80

    private let cardWidth: CGFloat = 344
    private let corner: CGFloat = 26
    private let padH: CGFloat = 20
    private let padV: CGFloat = 18
    private let badgeSize: CGFloat = 34
    private let closeSize: CGFloat = 22

    /// A view that is never the answer to a click. The glass is three stacked
    /// layers under the text; letting any of them win a hit test makes taps and
    /// hover depend on which one happened to be on top.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Clips the glass; the card itself must not clip or it would cut its own
    /// shadow off.
    private let clipView = PassThroughView()
    private let blurView = NSVisualEffectView()
    /// The tint, the sheen and the lit edge live on their own view rather than
    /// as loose sublayers of `clipView`.
    ///
    /// `clipView` also holds the blur as a SUBVIEW, and a subview's backing
    /// layer does not exist until the view joins a window — so at construction
    /// time the blur is simply absent from `clipView.layer.sublayers`, and
    /// AppKit inserts it later at an index of its own choosing. Ordering that
    /// depends on when AppKit decides to back a view is not ordering. As a
    /// sibling view added after the blur, this one is above it by the only
    /// rule AppKit actually guarantees.
    private let glassView = PassThroughView()
    private let tintLayer = CAGradientLayer()
    private let sheenLayer = CAGradientLayer()
    private let rimLayer = CALayer()

    private let badgeView = NSView()
    private let badgeIcon = NSImageView()
    private let sourceField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let bodyField = NSTextField(wrappingLabelWithString: "")
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?

    /// "Chrome · 14:07" — the window this was read from and when. Only cards
    /// that claim something about the screen carry one; on the rest the badge
    /// sits alone and the claim needs no citation.
    private var sourceLine: String? {
        guard let app = notification.sourceApp, !app.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return "\(app) · \(f.string(from: notification.createdAt))"
    }

    init(
        notification: MWNotification,
        onClose: @escaping () -> Void,
        onTap: (() -> Void)?,
        onHover: @escaping (Bool) -> Void
    ) {
        self.notification = notification
        self.onClose = onClose
        self.onTap = onTap
        self.onHover = onHover
        super.init(frame: NSRect(x: 0, y: 0, width: cardWidth, height: 80))
        setupLayer()
        setupContent()
        applyAppearanceColors()
        layoutContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported — programmatic only.")
    }

    // MARK: - Glass

    private func setupLayer() {
        wantsLayer = true
        guard let layer else { return }
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.44
        layer.shadowOffset = CGSize(width: 0, height: -10)
        layer.shadowRadius = 26

        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = corner
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        clipView.layer?.borderWidth = 1
        addSubview(clipView)

        // `.behindWindow` is what makes it glass rather than a grey panel: the
        // desktop and whatever the user is working in show through it.
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        clipView.addSubview(blurView)

        // Added after the blur, so it is above it — the one ordering rule that
        // does not depend on AppKit's layer-backing schedule.
        glassView.wantsLayer = true
        clipView.addSubview(glassView)

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

    // MARK: - Content

    private func setupContent() {
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = badgeSize / 2
        badgeView.layer?.masksToBounds = true
        addSubview(badgeView)

        if let symbol = NSImage(systemSymbolName: notification.kind.icon,
                                accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            badgeIcon.image = symbol.withSymbolConfiguration(config)
            badgeIcon.imageScaling = .scaleProportionallyDown
        }
        badgeView.addSubview(badgeIcon)

        sourceField.stringValue = sourceLine ?? ""
        sourceField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        sourceField.isBezeled = false
        sourceField.isEditable = false
        sourceField.drawsBackground = false
        sourceField.lineBreakMode = .byTruncatingTail
        sourceField.isHidden = (sourceLine == nil)
        addSubview(sourceField)

        titleField.stringValue = notification.title
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.maximumNumberOfLines = 2
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.wraps = true
        titleField.cell?.isScrollable = false
        titleField.preferredMaxLayoutWidth = cardWidth - padH * 2
        titleField.isBezeled = false
        titleField.isEditable = false
        titleField.drawsBackground = false
        addSubview(titleField)

        bodyField.stringValue = notification.body
        bodyField.font = .systemFont(ofSize: 13)
        bodyField.maximumNumberOfLines = 3
        bodyField.lineBreakMode = .byTruncatingTail
        bodyField.cell?.wraps = true
        bodyField.cell?.isScrollable = false
        bodyField.preferredMaxLayoutWidth = cardWidth - padH * 2
        bodyField.isBezeled = false
        bodyField.isEditable = false
        bodyField.drawsBackground = false
        bodyField.isHidden = notification.body.isEmpty
        addSubview(bodyField)

        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark",
                                    accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = closeSize / 2
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        addSubview(closeButton)
    }

    // MARK: - Appearance

    /// CALayer holds resolved `CGColor`s, which do not follow the system the
    /// way `NSColor` does — so every layer colour is re-resolved whenever the
    /// appearance changes. Text uses `labelColor`/`secondaryLabelColor` and
    /// needs no help.
    private func applyAppearanceColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

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

        clipView.layer?.borderColor = NSColor(calibratedWhite: dark ? 1 : 0,
                                              alpha: dark ? 0.11 : 0.10).cgColor
        rimLayer.backgroundColor = NSColor(calibratedWhite: 1,
                                           alpha: dark ? 0.16 : 0.85).cgColor

        // Colour is a state of the world, so the badge is neutral unless the
        // kind actually reports one. Neutral means "inverted from the glass":
        // a light disc on dark glass, a dark disc on light.
        let accent = notification.kind.accent
        let neutralAccent = MW.textSecondary
        let isNeutral = NSColor(accent).usingColorSpace(.sRGB)?.description
            == NSColor(neutralAccent).usingColorSpace(.sRGB)?.description

        if isNeutral {
            badgeView.layer?.backgroundColor = dark
                ? NSColor(calibratedWhite: 0.97, alpha: 1).cgColor
                : NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
            badgeIcon.contentTintColor = dark
                ? NSColor(calibratedWhite: 0.09, alpha: 1)
                : NSColor(calibratedWhite: 1.00, alpha: 1)
        } else {
            badgeView.layer?.backgroundColor = NSColor(accent).cgColor
            badgeIcon.contentTintColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        }

        sourceField.textColor = .tertiaryLabelColor
        titleField.textColor = .labelColor
        bodyField.textColor = .secondaryLabelColor
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.layer?.backgroundColor = NSColor(calibratedWhite: dark ? 1 : 0,
                                                     alpha: 0.07).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    // MARK: - Layout (no Auto Layout — manual frames, no NSISEngine entry)

    private func layoutContent() {
        let contentWidth = cardWidth - padH * 2

        let titleHeight = titleField.cell?
            .cellSize(forBounds: NSRect(x: 0, y: 0, width: contentWidth, height: 100)).height ?? 18
        let bodyHeight: CGFloat = notification.body.isEmpty ? 0
            : (bodyField.cell?
                .cellSize(forBounds: NSRect(x: 0, y: 0, width: contentWidth, height: 200)).height ?? 16)

        let headGap: CGFloat = 12
        let titleBodyGap: CGFloat = notification.body.isEmpty ? 0 : 4
        let contentTotal = badgeSize + headGap + titleHeight + titleBodyGap + bodyHeight
        let total = contentTotal + padV * 2

        // AppKit origin is bottom-left; lay out top-down and accumulate.
        var y = total - padV - badgeSize
        badgeView.frame = NSRect(x: padH, y: y, width: badgeSize, height: badgeSize)
        badgeIcon.frame = NSRect(x: 0, y: 0, width: badgeSize, height: badgeSize)

        let sourceX = padH + badgeSize + 11
        // Stop short of the close button rather than sliding under it.
        let sourceW = max(0, cardWidth - sourceX - padH - closeSize)
        let sourceH = sourceField.intrinsicContentSize.height
        sourceField.frame = NSRect(x: sourceX,
                                   y: y + (badgeSize - sourceH) / 2,
                                   width: sourceW, height: sourceH)

        y -= headGap + titleHeight
        titleField.frame = NSRect(x: padH, y: y, width: contentWidth, height: titleHeight)

        if !notification.body.isEmpty {
            y -= titleBodyGap + bodyHeight
            bodyField.frame = NSRect(x: padH, y: y, width: contentWidth, height: bodyHeight)
        }

        closeButton.frame = NSRect(x: cardWidth - 13 - closeSize,
                                   y: total - 13 - closeSize,
                                   width: closeSize, height: closeSize)

        measuredHeight = total
        frame = NSRect(x: 0, y: 0, width: cardWidth, height: total)

        let box = NSRect(x: 0, y: 0, width: cardWidth, height: total)
        clipView.frame = box
        blurView.frame = box
        glassView.frame = box
        // Implicit animations would make the glass slide behind the text while
        // the card is still growing into its measured height.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = box
        sheenLayer.frame = box
        rimLayer.frame = NSRect(x: corner * 0.55, y: total - 1,
                                width: cardWidth - corner * 1.1, height: 1)
        CATransaction.commit()
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    // MARK: - Click

    override func mouseDown(with event: NSEvent) {
        // Don't fire tap if the user clicked on the close button — the
        // button has its own action wired.
        let point = convert(event.locationInWindow, from: nil)
        if closeButton.frame.contains(point) { return }
        onTap?()
    }

    @objc private func handleClose() {
        onClose()
    }
}
