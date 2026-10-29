import AppKit
import SwiftUI

/// A card button that performs its action without taking keyboard focus.
struct MeetingCoachButton: NSViewRepresentable {
    let title: String
    var isEnabled = true
    var isStop = false
    var contentPadding: CGSize = .zero
    var symbolName: String? = nil
    var isAccent = false
    var repeatPulse = 0
    let action: () -> Void

    func makeNSView(context: Context) -> MeetingCoachNativeButton {
        Self.makeButton(title: title, action: action, initialRepeatPulse: repeatPulse)
    }

    func updateNSView(_ button: MeetingCoachNativeButton, context: Context) {
        updateButton(button)
    }

    func updateButton(_ button: MeetingCoachNativeButton) {
        button.contentPadding = contentPadding
        button.title = symbolName == nil ? title : ""
        button.isEnabled = isEnabled
        button.onPress = action
        button.applyRepeatPulse(repeatPulse)
        button.image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
        button.imagePosition = symbolName == nil ? .noImage : .imageOnly
        button.setAccessibilityLabel(title)
        button.font = .systemFont(ofSize: 11.5, weight: isStop ? .semibold : .medium)
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = isAccent ? .white : (isStop ? .systemRed : .labelColor)
        button.attributedTitle = NSAttributedString(string: symbolName == nil ? title : "", attributes: [
            .font: button.font ?? NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: isStop ? NSColor.systemRed : NSColor.labelColor
        ])
        button.imagePosition = symbolName == nil ? .noImage : .imageOnly
    }

    func symbol(_ name: String, accent: Bool = false) -> Self {
        var button = self
        button.symbolName = name
        button.isAccent = accent
        return button
    }

    func padded(horizontal: CGFloat, vertical: CGFloat) -> Self {
        var button = self
        button.contentPadding = CGSize(width: horizontal, height: vertical)
        return button
    }

    func repeatFeedback(_ pulse: Int) -> Self {
        var button = self
        button.repeatPulse = pulse
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                     nsView: MeetingCoachNativeButton,
                     context: Context) -> CGSize? {
        symbolName == nil ? nsView.intrinsicContentSize : CGSize(width: 26, height: 26)
    }

    /// The native configuration is tested without creating or showing a panel.
    static func makeButton(title: String, action: @escaping () -> Void,
                           initialRepeatPulse: Int = 0) -> MeetingCoachNativeButton {
        let button = MeetingCoachNativeButton(title: title, target: nil, action: nil)
        button.seedRepeatPulse(initialRepeatPulse)
        button.refusesFirstResponder = true
        button.focusRingType = .none
        button.controlSize = .small
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.onPress = action
        button.target = button
        button.action = #selector(MeetingCoachNativeButton.pressed)
        return button
    }
}

/// A click does not make the panel key, even when it contains an editable field.
final class MeetingCoachNativeButton: NSButton {
    private(set) var repeatFlashCount = 0
    private var lastRepeatPulse = 0

    func seedRepeatPulse(_ pulse: Int) { lastRepeatPulse = pulse }

    func applyRepeatPulse(_ pulse: Int) {
        guard pulse != lastRepeatPulse else { return }
        lastRepeatPulse = pulse
        guard pulse > 0 else { return }
        repeatFlashCount += 1
        alphaValue = 0.35
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
    }
    var onPress: (() -> Void)?
    var contentPadding: CGSize = .zero {
        didSet { if oldValue != contentPadding { invalidateIntrinsicContentSize() } }
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + contentPadding.width * 2,
                      height: size.height + contentPadding.height * 2)
    }

    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    @objc func pressed() {
        guard isEnabled else { return }
        onPress?()
    }
}
