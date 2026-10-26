import AppKit

/// The errand card (ITER-076 I-11), drawn as board 3 draws it, in the
/// notification card's shape: 344 pt wide, 26 pt corners, on the same glass
/// (`CardGlassView`). Pure AppKit with manual frames, like
/// `MWNotificationCardView`: SwiftUI cards inside these panels recursed in
/// Tahoe's Auto Layout bridge. It updates in place; its buttons act on the
/// first click and never take the keyboard, so the user's window keeps its
/// focus.
@MainActor
final class ErrandCardView: NSView {
    private(set) var card: ErrandCard
    /// Cached after each layout so the column places cards without
    /// re-measuring through Auto Layout.
    private(set) var measuredHeight: CGFloat = 0
    /// The most the card may take on its screen, as the column it stands in
    /// says (ITER-076 stage 7, review round 3, R3-4): a form's rows that would
    /// push its buttons past it scroll inside the card instead. Unbounded
    /// unless the column says.
    var maxHeight: CGFloat = .greatestFiniteMagnitude {
        didSet { if maxHeight != oldValue { layoutContent() } }
    }

    private let onPress: (ErrandCard.Action) -> Void
    private let onClose: () -> Void
    private let onHover: (Bool) -> Void

    static let width: CGFloat = 344
    private let corner: CGFloat = 26
    private let padH: CGFloat = 20
    private let padV: CGFloat = 18
    private let badgeSize: CGFloat = 34
    private let closeSize: CGFloat = 22
    private let buttonHeight: CGFloat = 28

    /// A view that is never the answer to a click.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// What the rows stand on, laid out from its top down.
    private final class RowsView: NSView {
        override var isFlipped: Bool { true }
    }

    /// A card button: it acts on the first click in a panel that is never
    /// key, and never becomes the first responder.
    private final class CardButton: NSButton {
        var cardAction: ErrandCard.Action?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private lazy var glass = CardGlassView(corner: corner)
    private let badgeView = PassThroughView()
    private let badgeIcon = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let sourceField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(wrappingLabelWithString: "")
    private let bodyField = NSTextField(wrappingLabelWithString: "")
    private let barView = PassThroughView()
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let metaField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private let closeButton = CardButton()
    private var buttons: [CardButton] = []
    /// A form's fields, under the title (ITER-076 stage 7), in a box of
    /// their own that scrolls when they need more room than the card has
    /// (review round 3, R3-4).
    private var rowFields: [NSTextField] = []
    private let rowsScroll = NSScrollView()
    private let rowsView = RowsView()
    private var countdown: Timer?
    private var trackingArea: NSTrackingArea?

    init(card: ErrandCard, onPress: @escaping (ErrandCard.Action) -> Void, onClose: @escaping () -> Void,
         onHover: @escaping (Bool) -> Void) {
        self.card = card
        self.onPress = onPress
        self.onClose = onClose
        self.onHover = onHover
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 80))
        wantsLayer = true
        CardGlassView.castShadow(on: layer)
        addSubview(glass)
        setupContent()
        show(card)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported — programmatic only.")
    }

    /// The card as it is now, in the same view.
    func update(_ card: ErrandCard) {
        self.card = card
        show(card)
    }

    /// The time left to answer, at `now`.
    func refresh(at now: ContinuousClock.Instant) {
        guard let left = card.countdown(at: now) else { return }
        timeField.stringValue = left.time
        layoutBar(fraction: left.fractionLeft)
    }

    // MARK: - Content

    private func setupContent() {
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = badgeSize / 2
        badgeView.layer?.masksToBounds = true
        badgeIcon.imageScaling = .scaleProportionallyDown
        badgeView.addSubview(badgeIcon)
        addSubview(badgeView)

        configure(labelField, font: .systemFont(ofSize: 10, weight: .semibold), color: Self.ink2)
        configure(sourceField, font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: Self.ink3)
        configure(titleField, font: .monospacedDigitSystemFont(ofSize: 15, weight: .semibold), color: Self.ink)
        configure(bodyField, font: .systemFont(ofSize: 13), color: Self.ink2)
        configure(metaField, font: .systemFont(ofSize: 11), color: Self.ink3)
        configure(timeField, font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: Self.ink2)
        bodyField.maximumNumberOfLines = 2
        bodyField.lineBreakMode = .byTruncatingTail
        bodyField.cell?.wraps = true
        bodyField.cell?.truncatesLastVisibleLine = true
        bodyField.preferredMaxLayoutWidth = contentWidth

        rowsScroll.drawsBackground = false
        rowsScroll.borderType = .noBorder
        rowsScroll.hasVerticalScroller = true
        rowsScroll.autohidesScrollers = true
        rowsScroll.scrollerStyle = .overlay
        rowsScroll.contentView.drawsBackground = false
        rowsScroll.documentView = rowsView
        addSubview(rowsScroll)

        barView.wantsLayer = true
        trackLayer.cornerRadius = 1.5
        fillLayer.cornerRadius = 1.5
        trackLayer.masksToBounds = true
        trackLayer.addSublayer(fillLayer)
        barView.layer?.addSublayer(trackLayer)
        addSubview(barView)

        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.refusesFirstResponder = true
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = closeSize / 2
        closeButton.contentTintColor = Self.ink3
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        addSubview(closeButton)
    }

    private func configure(_ field: NSTextField, font: NSFont, color: NSColor) {
        field.font = font
        field.textColor = color
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = false
        addSubview(field)
    }

    private var contentWidth: CGFloat { Self.width - padH * 2 }

    private func show(_ card: ErrandCard) {
        badgeIcon.image = NSImage(systemSymbolName: Self.symbol(card.glyph), accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        labelField.attributedStringValue = NSAttributedString(
            string: card.label.uppercased(), attributes: [.kern: 0.6, .font: labelField.font!, .foregroundColor: Self.ink2])
        sourceField.stringValue = card.source
        titleField.stringValue = card.title
        // A running errand's title ends with its count: one line, cut in the
        // middle, so the count stays in sight. Any other title wraps to four
        // lines at most and is cut at its end. The cell's wrapping and its
        // line break mode reset each other: the one that must hold is set last.
        if card.titleEndsWithCount {
            titleField.cell?.wraps = false
            titleField.lineBreakMode = .byTruncatingMiddle
            titleField.maximumNumberOfLines = 1
        } else {
            titleField.lineBreakMode = .byTruncatingTail
            titleField.cell?.wraps = true
            titleField.cell?.truncatesLastVisibleLine = true
            titleField.maximumNumberOfLines = 4
        }
        titleField.preferredMaxLayoutWidth = contentWidth
        bodyField.stringValue = card.body
        setRows(card.rows)
        metaField.stringValue = card.meta
        timeField.stringValue = card.countdown(at: .now)?.time ?? ""
        closeButton.isHidden = !card.hasEnded
        setButtons(card.buttons)
        applyAppearanceColors()
        layoutContent()
        followCountdown()
        slide(card.bar == .sliding)
    }

    private func setButtons(_ wanted: [ErrandCard.Button]) {
        let current = buttons.map { ErrandCard.Button(label: $0.title, action: $0.cardAction!, primary: $0.tag == 1) }
        guard current != wanted else { return }
        buttons.forEach { $0.removeFromSuperview() }
        buttons = wanted.map { spec in
            let button = CardButton()
            button.cardAction = spec.action
            button.tag = spec.primary ? 1 : 0
            button.title = spec.label
            button.isBordered = false
            button.refusesFirstResponder = true
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.target = self
            button.action = #selector(handlePress(_:))
            addSubview(button)
            return button
        }
    }

    /// A form's field lines (ITER-076 stage 7), in the rows' box, read from
    /// its top again when they change; they update in place.
    private func setRows(_ wanted: [String]) {
        guard rowFields.map(\.stringValue) != wanted else { return }
        rowFields.forEach { $0.removeFromSuperview() }
        defer { rowsScroll.contentView.scroll(to: .zero) }
        // A row is a form's field with the value the Yes is given for: shown
        // whole, on every line it needs, never cut (review round 2 of ITER-076
        // stage 7).
        rowFields = wanted.map { line in
            let field = NSTextField(wrappingLabelWithString: line)
            configure(field, font: .systemFont(ofSize: 12), color: Self.ink2)
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
            field.cell?.wraps = true
            field.cell?.truncatesLastVisibleLine = false
            field.preferredMaxLayoutWidth = contentWidth
            rowsView.addSubview(field)
            return field
        }
    }

    // MARK: - Appearance

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    // Board 3's ink, in light and dark.
    private static let ink = dynamic(rgb(0x1C1C1E), rgb(0xF5F5F7))
    private static let ink2 = dynamic(rgb(0x1C1C1E, 0.72), rgb(0xF5F5F7, 0.72))
    private static let ink3 = dynamic(rgb(0x1C1C1E, 0.64), rgb(0xF5F5F7, 0.64))

    /// CALayer holds resolved `CGColor`s: every layer colour is resolved again
    /// whenever the appearance changes.
    private func applyAppearanceColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        glass.applyColors(dark: dark)
        // Colour is a state: plain while it works or once it stopped (inverted
        // from the glass), orange for the user's move, green when done.
        let (badge, glyph): (NSColor, NSColor) = switch card.tone {
        case .plain: dark ? (Self.rgb(0xF7F7F7), Self.rgb(0x171717)) : (Self.rgb(0x1C1C1C), Self.rgb(0xFFFFFF))
        case .yourMove: (Self.rgb(0xFF9E0A), Self.rgb(0x1A1A1A))
        case .done: (Self.rgb(0x33C759), Self.rgb(0x1A1A1A))
        }
        badgeView.layer?.backgroundColor = badge.cgColor
        badgeIcon.contentTintColor = glyph
        let accent = dark ? Self.rgb(0xF7F7F7) : Self.rgb(0x1C1C1C)
        trackLayer.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.10)).cgColor
        let muted = if case .progress(_, muted: true) = card.bar { true } else { false }
        fillLayer.backgroundColor = muted ? Self.rgb(dark ? 0xF5F5F7 : 0x1C1C1E, 0.64).cgColor : accent.cgColor
        closeButton.layer?.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.08 : 0.07).cgColor
        let ink = dark ? Self.rgb(0xF5F5F7) : Self.rgb(0x1C1C1E)
        for button in buttons {
            let primary = button.tag == 1
            button.layer?.backgroundColor = primary ? accent.cgColor
                : (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 1, alpha: 0.6)).cgColor
            button.layer?.borderWidth = primary ? 0 : 0.5
            button.layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.14)).cgColor
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: primary ? (dark ? Self.rgb(0x161616) : Self.rgb(0xFFFFFF)) : ink])
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    // MARK: - Layout (manual frames, no Auto Layout)

    /// Height of `field`'s text across `width`, at most `lines` lines — all
    /// of them for 0.
    private func height(of field: NSTextField, lines: Int) -> CGFloat {
        guard let cell = field.cell, !field.stringValue.isEmpty else { return 0 }
        let bounds = NSRect(x: 0, y: 0, width: contentWidth, height: 10_000)
        let full = cell.cellSize(forBounds: bounds).height
        guard lines > 0 else { return ceil(full) }
        let probe = cell.copy() as? NSCell
        probe?.stringValue = Array(repeating: "Ag", count: lines).joined(separator: "\n")
        let most = probe?.cellSize(forBounds: bounds).height ?? full
        return ceil(min(full, most))
    }

    private func layoutContent() {
        let titleHeight = height(of: titleField, lines: titleField.maximumNumberOfLines)
        let rowHeights = rowFields.map { height(of: $0, lines: 0) }
        let bodyHeight = height(of: bodyField, lines: 2)
        let hasStatus = card.bar != .none || !card.meta.isEmpty || !timeField.stringValue.isEmpty
        let rowHeight: CGFloat = 14

        var total = padV + badgeSize
        if titleHeight > 0 { total += 12 + titleHeight }
        if bodyHeight > 0 { total += 3 + bodyHeight }
        if hasStatus { total += 10 + rowHeight }
        if !buttons.isEmpty { total += 12 + buttonHeight }
        total += padV
        // The rows take what room the card leaves them under `maxHeight` —
        // at least a few lines — and scroll in it; every row whole in its box
        // (review round 3, R3-4).
        let rowsHeight = rowHeights.reduce(0) { $0 + $1 + 2 }
        let rowsShown = rowHeights.isEmpty ? 0 : min(rowsHeight, max(maxHeight - total - 8, min(rowsHeight, 48)))
        if !rowHeights.isEmpty { total += 8 + rowsShown }

        // AppKit's origin is bottom-left: lay out from the top down.
        var y = total - padV - badgeSize
        badgeView.frame = NSRect(x: padH, y: y, width: badgeSize, height: badgeSize)
        badgeIcon.frame = badgeView.bounds
        // The label and the source beside the badge, stopping short of the
        // close button rather than sliding under it.
        let textX = padH + badgeSize + 11
        let textWidth = Self.width - textX - padH - 18
        let labelHeight: CGFloat = 13, sourceHeight: CGFloat = 14
        let stack = card.source.isEmpty ? labelHeight : labelHeight + 2 + sourceHeight
        let top = y + (badgeSize + stack) / 2
        labelField.frame = NSRect(x: textX, y: top - labelHeight, width: textWidth, height: labelHeight)
        sourceField.frame = NSRect(x: textX, y: top - stack, width: textWidth, height: sourceHeight)
        sourceField.isHidden = card.source.isEmpty

        titleField.isHidden = titleHeight == 0
        if titleHeight > 0 {
            y -= 12 + titleHeight
            titleField.frame = NSRect(x: padH, y: y, width: contentWidth, height: titleHeight)
        }
        rowsScroll.isHidden = rowHeights.isEmpty
        if !rowHeights.isEmpty {
            y -= 8 + rowsShown
            rowsScroll.frame = NSRect(x: padH, y: y, width: contentWidth, height: rowsShown)
            rowsView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: rowsHeight)
            var top: CGFloat = 0
            for (field, rowHeight) in zip(rowFields, rowHeights) {
                top += 2
                field.frame = NSRect(x: 0, y: top, width: contentWidth, height: rowHeight)
                top += rowHeight
            }
        }
        bodyField.isHidden = bodyHeight == 0
        if bodyHeight > 0 {
            y -= 3 + bodyHeight
            bodyField.frame = NSRect(x: padH, y: y, width: contentWidth, height: bodyHeight)
        }
        barView.isHidden = card.bar == .none
        metaField.isHidden = card.meta.isEmpty
        timeField.isHidden = timeField.stringValue.isEmpty
        if hasStatus {
            y -= 10 + rowHeight
            // The bar takes the room the line and the time leave, 10 pt apart.
            var x = padH + contentWidth
            if !timeField.isHidden {
                let width = oneLineWidth(of: timeField)
                x -= width
                timeField.frame = NSRect(x: x, y: y, width: width, height: rowHeight)
                x -= 10
            }
            if !metaField.isHidden {
                let fits = min(oneLineWidth(of: metaField), x - padH)
                let width = barView.isHidden ? x - padH : fits
                x -= width
                metaField.frame = NSRect(x: x, y: y, width: width, height: rowHeight)
                x -= 10
            }
            barView.frame = NSRect(x: padH, y: y + (rowHeight - 3) / 2, width: max(0, x - padH), height: 3)
            layoutBar(fraction: card.countdown(at: .now)?.fractionLeft)
        }
        if !buttons.isEmpty {
            y -= 12 + buttonHeight
            var x = padH
            for button in buttons {
                let text = (button.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
                let width = min(ceil(text.width) + 24, padH + contentWidth - x)
                button.frame = NSRect(x: x, y: y, width: width, height: buttonHeight)
                x += width + 8
            }
        }
        closeButton.frame = NSRect(x: Self.width - 13 - closeSize, y: total - 13 - closeSize,
                                   width: closeSize, height: closeSize)

        measuredHeight = total
        setFrameSize(NSSize(width: Self.width, height: total))
        glass.place(in: NSRect(x: 0, y: 0, width: Self.width, height: total))
    }

    /// The width a one-line field needs for its whole text, with the 2 pt
    /// its cell keeps on either side.
    private func oneLineWidth(of field: NSTextField) -> CGFloat {
        guard let font = field.font else { return 0 }
        return ceil((field.stringValue as NSString).size(withAttributes: [.font: font]).width) + 4
    }

    /// The bar's fill: rows done, the time left, or a sliding segment.
    private func layoutBar(fraction countdown: Double?) {
        let fraction: Double = switch card.bar {
        case .progress(let done, _): done
        case .countdown: countdown ?? 0
        case .sliding: 0.3
        case .none: 0
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = barView.bounds
        fillLayer.frame = NSRect(x: 0, y: 0, width: barView.bounds.width * min(max(fraction, 0), 1), height: 3)
        CATransaction.commit()
    }

    /// The sliding segment of a wait whose length is unknown, unless the user
    /// asked for less motion.
    private func slide(_ on: Bool) {
        fillLayer.removeAnimation(forKey: "slide")
        guard on, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let width = barView.bounds.width
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = -0.33 * width
        move.toValue = 1.02 * width
        move.duration = 1.6
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.55, 1)
        fillLayer.add(move, forKey: "slide")
    }

    // MARK: - The countdown

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        followCountdown()
    }

    /// While the card asks and is on screen, its time left is shown again
    /// four times a second.
    private func followCountdown() {
        guard window != nil, card.bar == .countdown else {
            countdown?.invalidate()
            countdown = nil
            return
        }
        guard countdown == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(at: .now) }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdown = timer
    }

    // MARK: - Hover and clicks

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func handlePress(_ sender: CardButton) {
        guard let action = sender.cardAction else { return }
        onPress(action)
    }

    @objc private func handleClose() {
        onClose()
    }

    private static func symbol(_ glyph: ErrandCard.Glyph) -> String {
        switch glyph {
        case .globe: "globe"
        case .send: "paperplane"
        case .lock: "lock"
        case .key: "key"
        case .stop: "stop"
        case .check: "checkmark"
        case .pen: "pencil"
        }
    }
}
