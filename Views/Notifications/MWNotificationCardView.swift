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
/// **Identical UX surface** to the SwiftUI version it replaces:
///   - Same 344 pt fixed width + intrinsic height from text.
///   - Same accent-bar / label / title / body layout.
///   - Hover pauses the auto-dismiss timer (delegates back to the stack).
///   - X button to close.
///   - Optional tap action (fires `onTap` from `MWNotification`).
///   - Rounded corners + thin border + drop shadow (the «liquid glass»
///     look). Material blur is dropped — Tahoe's NSVisualEffectView still
///     works fine but we omit it here to keep the layer count low; the
///     opaque dark fill reads cleanly against any background.
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

    private let labelField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let bodyField = NSTextField(wrappingLabelWithString: "")
    private let iconView = NSImageView()
    private let accentBar = NSView()
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?

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
        layoutContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported — programmatic only.")
    }

    // MARK: - Layer (background, border, shadow)

    private func setupLayer() {
        wantsLayer = true
        guard let layer else { return }
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.backgroundColor = NSColor(white: 0.13, alpha: 0.95).cgColor
        layer.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        layer.borderWidth = 0.5
        // Drop shadow at view level (CALayer), not via SwiftUI .shadow().
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowOffset = CGSize(width: 0, height: -6)
        layer.shadowRadius = 14
        layer.masksToBounds = false
    }

    // MARK: - Content

    private func setupContent() {
        // Accent vertical bar on the left edge — coloured by kind.
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = Self.nsColor(notification.kind.accent).cgColor
        accentBar.layer?.cornerRadius = 1.5
        addSubview(accentBar)

        // Icon next to the kind label.
        if let symbol = NSImage(systemSymbolName: notification.kind.icon, accessibilityDescription: nil) {
            iconView.image = symbol
            iconView.contentTintColor = Self.nsColor(notification.kind.accent)
            iconView.imageScaling = .scaleProportionallyDown
        }
        addSubview(iconView)

        // Kind label («NEW TASK», «CALL DETECTED», etc).
        labelField.stringValue = notification.kind.label
        labelField.font = .systemFont(ofSize: 9, weight: .bold)
        labelField.textColor = Self.nsColor(notification.kind.accent)
        labelField.isBezeled = false
        labelField.isEditable = false
        labelField.drawsBackground = false
        addSubview(labelField)

        // Title (main text).
        titleField.stringValue = notification.title
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .white
        titleField.maximumNumberOfLines = 2
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.wraps = true
        titleField.cell?.isScrollable = false
        titleField.preferredMaxLayoutWidth = cardWidth - 24
        titleField.isBezeled = false
        titleField.isEditable = false
        titleField.drawsBackground = false
        addSubview(titleField)

        // Body (secondary text). Hidden when empty.
        bodyField.stringValue = notification.body
        bodyField.font = .systemFont(ofSize: 11)
        bodyField.textColor = NSColor(white: 1.0, alpha: 0.70)
        bodyField.maximumNumberOfLines = 3
        bodyField.lineBreakMode = .byTruncatingTail
        bodyField.cell?.wraps = true
        bodyField.cell?.isScrollable = false
        bodyField.preferredMaxLayoutWidth = cardWidth - 24
        bodyField.isBezeled = false
        bodyField.isEditable = false
        bodyField.drawsBackground = false
        bodyField.isHidden = notification.body.isEmpty
        addSubview(bodyField)

        // Close button (X). Top-right.
        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor(white: 1.0, alpha: 0.45)
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        addSubview(closeButton)
    }

    // MARK: - Layout (no Auto Layout — manual frames, no NSISEngine entry)

    private func layoutContent() {
        let inset: CGFloat = 12
        let contentWidth = cardWidth - inset * 2

        // Accent bar: 3 pt wide, full height minus padding.
        accentBar.frame = NSRect(x: 6, y: 12, width: 3, height: 0) // height set after measure

        // Icon: 14×14 next to label.
        iconView.frame = NSRect(x: inset + 6, y: 0, width: 14, height: 14)
        // Label: right of icon.
        let labelSize = labelField.intrinsicContentSize
        labelField.frame = NSRect(x: iconView.frame.maxX + 6, y: 0, width: labelSize.width, height: labelSize.height)

        // Title: full width.
        let titleHeight = titleField.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: contentWidth, height: 100)).height ?? 18
        titleField.frame = NSRect(x: inset + 6, y: 0, width: contentWidth - 6, height: titleHeight)

        // Body: full width, may be 0 height when hidden.
        let bodyHeight: CGFloat = notification.body.isEmpty ? 0
            : (bodyField.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: contentWidth, height: 200)).height ?? 16)
        bodyField.frame = NSRect(x: inset + 6, y: 0, width: contentWidth - 6, height: bodyHeight)

        // Total content stack (top→bottom): label row (14), 6 gap, title, 4 gap, body. Then padding.
        let labelRowH: CGFloat = 14
        let interGap: CGFloat = 6
        let titleBodyGap: CGFloat = notification.body.isEmpty ? 0 : 4
        let contentTotal = labelRowH + interGap + titleHeight + titleBodyGap + bodyHeight
        let total = contentTotal + inset * 2

        // Pin actual y positions now that we know totals. Origin is bottom-left in AppKit views by default.
        // We lay out top-down, so accumulate from top.
        var y = total - inset - labelRowH
        iconView.frame.origin.y = y
        labelField.frame.origin.y = y
        y -= interGap + titleHeight
        titleField.frame.origin.y = y
        if !notification.body.isEmpty {
            y -= titleBodyGap + bodyHeight
            bodyField.frame.origin.y = y
        }

        // Accent bar runs the full content area height.
        accentBar.frame = NSRect(x: 6, y: inset, width: 3, height: total - inset * 2)

        // Close button top-right.
        closeButton.frame = NSRect(x: cardWidth - 22, y: total - 22, width: 14, height: 14)

        measuredHeight = total
        // Update own frame to match measured height — caller positions us.
        frame = NSRect(x: 0, y: 0, width: cardWidth, height: total)
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

    // MARK: - SwiftUI Color → NSColor bridge

    /// SwiftUI's `Color` ↔ AppKit's `NSColor` via the built-in initializer
    /// available since macOS 12. This is pure value conversion — no
    /// SwiftUI rendering pipeline is invoked, so the Tahoe NSISEngine
    /// recursion bug doesn't apply here.
    private static func nsColor(_ swiftUIColor: Color) -> NSColor {
        NSColor(swiftUIColor)
    }
}
