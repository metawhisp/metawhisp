import AppKit
import Foundation

/// Short-lived, non-activating acknowledgement for a layout correction.
///
/// The before/after preview exists in memory only while visible and is cleared
/// before the panel is hidden. It is never logged or persisted.
@MainActor
final class LayoutFixFeedbackController {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var dismissTask: Task<Void, Never>?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let background = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 18, y: 42, width: 294, height: 18)

        detailLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.frame = NSRect(x: 18, y: 17, width: 294, height: 18)

        background.addSubview(titleLabel)
        background.addSubview(detailLabel)
        panel.contentView = background
        self.panel = panel
    }

    func show(_ correction: LayoutCorrection) {
        dismissTask?.cancel()
        titleLabel.stringValue = "Layout fixed · \(direction(for: correction))"
        detailLabel.stringValue = "\(preview(correction.replacement, limit: 24))  ·  ⌘Z to undo"

        positionPanel()
        panel.orderFrontRegardless()

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        titleLabel.stringValue = ""
        detailLabel.stringValue = ""
        panel.orderOut(nil)
    }

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouse, $0.frame, false)
        } ?? NSScreen.main
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let frame = NSRect(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.maxY - panel.frame.height - 18,
            width: panel.frame.width,
            height: panel.frame.height
        )
        panel.setFrame(frame, display: true)
    }

    private func direction(for correction: LayoutCorrection) -> String {
        switch correction.targetLayout {
        case .englishUS: "RU → EN"
        case .russian: "EN → RU"
        }
    }

    private func preview(_ text: String, limit: Int) -> String {
        String(text.prefix(limit))
    }
}
