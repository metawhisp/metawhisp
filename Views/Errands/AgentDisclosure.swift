import AppKit
import Combine

/// The disclosure before the first errand (ITER-076 stage 8b, № 151): board 4 left of the approved "Jev agent
/// interface" — what the agent sends and where — in the words the owner approved on 2026-10-06 (8b-01…12, 8b-32),
/// byte for byte. One source for the panel and for Settings → Agent.
enum AgentDisclosure {
    /// One row: what goes where. `symbol`: an SF Symbol for the board's icon.
    struct Row: Equatable {
        let symbol: String
        let title: String
        let body: String
    }

    static let header = "Before the first errand"
    static let title = "What the agent sends and where"
    /// MetaWhisp's own Chrome window (8b-32): the panel's line under the title in that way — the user's own Chrome
    /// shows none — and Settings → Agent's line while "Use your own Chrome" is off.
    static let ownWindow = "Errands run in MetaWhisp's own Chrome window, so the agent never sees your browser's tabs, history or sign-ins. When a site asks you to sign in, you do it there."
    static let rows = [
        Row(symbol: "server.rack", title: "To Jev, through MetaWhisp's Pro server",
            body: "Your request and the page: its address, text, controls and the values of ordinary fields. Jev decides every step."),
        Row(symbol: "pencil", title: "To an AI model, through MetaWhisp's Pro server",
            body: "Your request and the pages: their address, text and the values of ordinary fields. It plans the errand, writes what to type, reads the pages and checks the result."),
        Row(symbol: "lock", title: "Never leaves your Mac",
            body: "The values of password, one-time code and card fields."),
        Row(symbol: "exclamationmark.triangle", title: "To MetaWhisp, when an errand fails or gets stuck",
            body: "A report of the failure, in kinds and numbers only. Never your request, page text or what was typed."),
    ]
    static let allow = "Allow"
    static let notNow = "Not now"
    static let footer = "You can turn the agent off any time in Settings → Agent."
}

/// Settings → Agent (ITER-076 stage 8b, № 153, 160): the words the owner approved on 2026-10-06 (8b-17…20, 8b-23…26,
/// 8b-33), byte for byte, with the disclosure's own rows (`AgentDisclosure`).
enum AgentSetup {
    /// The Settings tab (8.3).
    static let tab = "Agent"
    /// The agent's switch (8.1: on by default).
    static let browserAgent = "Browser agent"
    /// The second way (8.7): off — MetaWhisp's own Chrome window; on — the user's own Chrome, with its steps.
    static let useYourOwnChrome = "Use your own Chrome"
    /// Without Pro, in the rows' place.
    static let needsPro = "The browser agent needs Pro."
    /// The second way's steps, as board 4's Connect Chrome panel draws them.
    static let oneTimeSetup = "A one-time setup in Chrome. MetaWhisp never clicks Allow for you."
    static let openAddress = "Open this address in Chrome"
    static let address = "chrome://inspect/#remote-debugging"
    static let copyAddress = "Copy address"
    static let tick = "Tick “Allow remote debugging for this browser instance”."
    static let clickAllow = "Click Allow when Chrome asks."
    /// MetaChat's empty screen, under "Try:", while an errand can start.
    static let example = "• Find 10 jokes online"

    /// Copy address: the address goes to `pasteboard` — on the user's click alone, the button's meaning (A4).
    static func copyAddress(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(address, forType: .string)
    }
}

/// The disclosure, drawn as board 4 draws it (ITER-076 stage 8b): 540 pt wide, 28 pt corners, on the cards' glass
/// (`CardGlassView`), in pure AppKit with manual frames like the errand card. Its buttons act on the first click and
/// never take the keyboard: there is no default button, so Return or Space never Allows.
@MainActor
final class AgentDisclosureView: NSView {
    static let width: CGFloat = 540
    private let pad: CGFloat = 28
    private let corner: CGFloat = 28
    private let badgeSize: CGFloat = 34
    private let chipSize: CGFloat = 36
    private let buttonHeight: CGFloat = 28

    /// A view that is never the answer to a click.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// A button that acts on the first click in a panel that is never key, and never becomes the first responder.
    final class Button: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private(set) var measuredHeight: CGFloat = 0
    private let onAllow: () -> Void
    private let onNotNow: () -> Void
    private lazy var glass = CardGlassView(corner: corner)
    private let badge = PassThroughView()
    private let badgeIcon = NSImageView()
    private let headerField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(wrappingLabelWithString: AgentDisclosure.title)
    private let subtitleField = NSTextField(wrappingLabelWithString: "")
    private var rowViews: [(chip: PassThroughView, icon: NSImageView, title: NSTextField, body: NSTextField)] = []
    private var separators: [PassThroughView] = []
    let allowButton = Button()
    let notNowButton = Button()
    private let footerField = NSTextField(wrappingLabelWithString: AgentDisclosure.footer)

    /// `ownWindow`: the errand runs in MetaWhisp's own Chrome window, and the panel says so under its title.
    init(ownWindow: Bool, onAllow: @escaping () -> Void, onNotNow: @escaping () -> Void) {
        self.onAllow = onAllow
        self.onNotNow = onNotNow
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        wantsLayer = true
        CardGlassView.castShadow(on: layer)
        addSubview(glass)

        badge.wantsLayer = true
        badge.layer?.cornerRadius = badgeSize / 2
        badgeIcon.image = NSImage(systemSymbolName: "shield", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        badge.addSubview(badgeIcon)
        addSubview(badge)
        headerField.attributedStringValue = NSAttributedString(
            string: AgentDisclosure.header.uppercased(),
            attributes: [.kern: 0.6, .font: NSFont.systemFont(ofSize: 10, weight: .semibold)])
        configure(headerField)
        configure(titleField, font: .systemFont(ofSize: 22, weight: .semibold))
        subtitleField.stringValue = ownWindow ? AgentDisclosure.ownWindow : ""
        configure(subtitleField, font: .systemFont(ofSize: 13))
        for row in AgentDisclosure.rows {
            let chip = PassThroughView()
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 10
            chip.layer?.borderWidth = 0.5
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            chip.addSubview(icon)
            addSubview(chip)
            let title = NSTextField(wrappingLabelWithString: row.title)
            configure(title, font: .systemFont(ofSize: 13, weight: .semibold))
            let body = NSTextField(wrappingLabelWithString: row.body)
            configure(body, font: .systemFont(ofSize: 13))
            rowViews.append((chip, icon, title, body))
        }
        for _ in 1..<AgentDisclosure.rows.count {
            let line = PassThroughView()
            line.wantsLayer = true
            addSubview(line)
            separators.append(line)
        }
        for (button, title, action) in [(allowButton, AgentDisclosure.allow, #selector(allow)),
                                        (notNowButton, AgentDisclosure.notNow, #selector(notNow))] {
            button.title = title
            button.isBordered = false
            button.refusesFirstResponder = true
            button.keyEquivalent = ""
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.target = self
            button.action = action
            addSubview(button)
        }
        configure(footerField, font: .systemFont(ofSize: 11))
        applyAppearanceColors()
        layoutContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported — programmatic only.")
    }

    /// Every line the panel shows, top to bottom.
    var shownLines: [String] {
        [headerField.stringValue, titleField.stringValue] + (subtitleField.isHidden ? [] : [subtitleField.stringValue])
            + rowViews.flatMap { [$0.title.stringValue, $0.body.stringValue] }
            + [allowButton.title, notNowButton.title, footerField.stringValue]
    }

    @objc private func allow() { onAllow() }
    @objc private func notNow() { onNotNow() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func configure(_ field: NSTextField, font: NSFont? = nil) {
        if let font { field.font = font }
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.preferredMaxLayoutWidth = Self.width - pad * 2
        addSubview(field)
    }

    // MARK: - Appearance

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Board 4's ink and chips, in light and dark; CALayer colours are resolved again on each change.
    private func applyAppearanceColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        glass.applyColors(dark: dark)
        let ink = dark ? Self.rgb(0xF5F5F7) : Self.rgb(0x1C1C1E)
        let ink2 = dark ? Self.rgb(0xF5F5F7, 0.72) : Self.rgb(0x1C1C1E, 0.72)
        let ink3 = dark ? Self.rgb(0xF5F5F7, 0.64) : Self.rgb(0x1C1C1E, 0.64)
        let accent = dark ? Self.rgb(0xF7F7F7) : Self.rgb(0x1C1C1C)
        let chipFill = dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 1, alpha: 0.6)
        let chipBorder = dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.14)
        badge.layer?.backgroundColor = accent.cgColor
        badgeIcon.contentTintColor = dark ? Self.rgb(0x171717) : Self.rgb(0xFFFFFF)
        headerField.textColor = ink2
        titleField.textColor = ink
        subtitleField.textColor = ink2
        for row in rowViews {
            row.chip.layer?.backgroundColor = chipFill.cgColor
            row.chip.layer?.borderColor = chipBorder.cgColor
            row.icon.contentTintColor = ink
            row.title.textColor = ink
            row.body.textColor = ink2
        }
        for line in separators {
            line.layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.08)).cgColor
        }
        for (button, primary) in [(allowButton, true), (notNowButton, false)] {
            button.layer?.backgroundColor = primary ? accent.cgColor : chipFill.cgColor
            button.layer?.borderWidth = primary ? 0 : 0.5
            button.layer?.borderColor = chipBorder.cgColor
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: primary ? (dark ? Self.rgb(0x161616) : Self.rgb(0xFFFFFF)) : ink])
        }
        footerField.textColor = ink3
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    // MARK: - Layout (manual frames, no Auto Layout)

    private func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        guard let cell = field.cell, !field.stringValue.isEmpty else { return 0 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1_000)).height)
    }

    private func layoutContent() {
        let width = Self.width - pad * 2
        let textX = pad + chipSize + 14
        let textWidth = Self.width - pad - textX
        let titleHeight = height(of: titleField, width: width)
        let subtitleHeight = height(of: subtitleField, width: width)
        subtitleField.isHidden = subtitleHeight == 0
        let rowHeights = rowViews.map { row in
            max(chipSize, height(of: row.title, width: textWidth) + 3 + height(of: row.body, width: textWidth))
        }
        let footerHeight = height(of: footerField, width: width)

        var total = pad + badgeSize + 16 + titleHeight
        if subtitleHeight > 0 { total += 6 + subtitleHeight }
        total += 16 + rowHeights.reduce(0) { $0 + $1 + 32 }
        total += 14 + buttonHeight + 14 + footerHeight + pad

        // AppKit's origin is bottom-left: lay out from the top down.
        var y = total - pad - badgeSize
        badge.frame = NSRect(x: pad, y: y, width: badgeSize, height: badgeSize)
        badgeIcon.frame = badge.bounds
        headerField.frame = NSRect(x: pad + badgeSize + 11, y: y + (badgeSize - 13) / 2, width: width - badgeSize - 11,
                                   height: 13)
        y -= 16 + titleHeight
        titleField.frame = NSRect(x: pad, y: y, width: width, height: titleHeight)
        if subtitleHeight > 0 {
            y -= 6 + subtitleHeight
            subtitleField.frame = NSRect(x: pad, y: y, width: width, height: subtitleHeight)
        }
        y -= 16
        for (index, row) in rowViews.enumerated() {
            let top = y - 16
            row.chip.frame = NSRect(x: pad, y: top - chipSize, width: chipSize, height: chipSize)
            row.icon.frame = row.chip.bounds.insetBy(dx: 9, dy: 9)
            let titleHeight = height(of: row.title, width: textWidth)
            row.title.frame = NSRect(x: textX, y: top - titleHeight, width: textWidth, height: titleHeight)
            let bodyHeight = height(of: row.body, width: textWidth)
            row.body.frame = NSRect(x: textX, y: top - titleHeight - 3 - bodyHeight, width: textWidth, height: bodyHeight)
            y -= rowHeights[index] + 32
            if index < separators.count {
                separators[index].frame = NSRect(x: pad, y: y, width: width, height: 1)
            }
        }
        y -= 14 + buttonHeight
        var x = pad
        for button in [allowButton, notNowButton] {
            let text = (button.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            let buttonWidth = ceil(text.width) + 28
            button.frame = NSRect(x: x, y: y, width: buttonWidth, height: buttonHeight)
            x += buttonWidth + 8
        }
        y -= 14 + footerHeight
        footerField.frame = NSRect(x: pad, y: y, width: width, height: footerHeight)

        measuredHeight = total
        setFrameSize(NSSize(width: Self.width, height: total))
        glass.place(in: NSRect(x: 0, y: 0, width: Self.width, height: total))
    }
}

/// Shows the disclosure while an errand waits for the user's Allow (ITER-076 stage 8b, 8.2): one panel, centred on
/// the active screen (A3), on every Space, a full-screen one included; non-activating and never key, so the user's
/// window keeps the keyboard and no key press answers it. Nothing goes to the menu bar. Allow and Not now go to the
/// errand service; the service closes it.
@MainActor
final class AgentDisclosureController {
    /// Room for the card's shadow on each side: 2 · radius 26 + |offset| 10.
    private static let shadowRoom: CGFloat = 62
    private(set) var panel: NSPanel?
    private(set) var view: AgentDisclosureView?
    private let allow: () -> Void
    private let notNow: () -> Void
    private var subscription: AnyCancellable?

    /// `disclosure`: the browser of the errand that waits, or nil when none does.
    init(disclosure: AnyPublisher<AgentBrowser?, Never>, allow: @escaping () -> Void,
         notNow: @escaping () -> Void) {
        self.allow = allow
        self.notNow = notNow
        subscription = disclosure.removeDuplicates().sink { [weak self] way in
            MainActor.assumeIsolated {
                if let way { self?.show(way) } else { self?.hide() }
            }
        }
    }

    private func show(_ way: AgentBrowser) {
        let view = AgentDisclosureView(ownWindow: way == .ownWindow, onAllow: allow, onNotNow: notNow)
        let room = Self.shadowRoom
        let size = NSSize(width: AgentDisclosureView.width + room * 2, height: view.measuredHeight + room * 2)
        let panel = self.panel ?? Self.makePanel()
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        view.setFrameOrigin(NSPoint(x: room, y: room))
        container.addSubview(view)
        panel.contentView = container
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view
        NSLog("[AgentDisclosure] shown (%@)", way.rawValue)
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        view = nil
        NSLog("[AgentDisclosure] closed")
    }

    private static func makePanel() -> NSPanel {
        let panel = NonActivatingPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = MWWindowBehavior.overlay
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        return panel
    }
}
