import AppKit
import Combine
import SwiftUI

/// Hosts `MWNotificationStackView` inside a borderless non-activating panel
/// docked to the top-right of the active screen. The panel is sized to fit the
/// stack so individual card shadows render without clipping and cards never
/// overlap each other (the SwiftUI `VStack` handles spacing).
@MainActor
final class MWNotificationStackController {
    private var window: NonActivatingPanel?
    private var hosting: NSHostingController<MWNotificationStackView>?
    private var stackCancellable: AnyCancellable?

    /// Initial size — gets recalculated from the host view's fittingSize on
    /// every items change. Width is fixed (one card per row); height grows
    /// with the stack (up to maxStack=4 cards).
    /// Width = 344pt card + 28pt shadow envelope (14 each side, see
    /// MWNotificationCard `.padding(.horizontal, 14)`). 2026-05-12 — was 360,
    /// bumped to fit shadow without clipping.
    private static let cardWidth: CGFloat = 372
    private static let edgeInset: CGFloat = 12

    init() {
        // Show the panel only when the stack has items. Empty → panel is
        // hidden so it never paints invisible chrome or blocks clicks behind
        // it. Resize on every items change so the panel matches the stack
        // exactly (no surrounding click-blocker rectangle).
        stackCancellable = MWNotificationStack.shared.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                if items.isEmpty {
                    self?.hide()
                } else {
                    self?.show()
                }
            }
    }

    // MARK: - Window lifecycle

    private func show() {
        if window == nil { createWindow() }
        guard let window else { return }
        resizeAndPosition(window)
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    private func hide() {
        window?.orderOut(nil)
    }

    private func createWindow() {
        let host = NSHostingController(rootView: MWNotificationStackView())
        host.sizingOptions = [.preferredContentSize]
        let initialSize = NSSize(width: Self.cardWidth, height: 100)

        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.contentViewController = host

        self.hosting = host
        self.window = panel
    }

    /// Recompute panel size to fit the current stack and re-anchor at top-right.
    /// Reads SwiftUI's `fittingSize` AFTER a layout pass so animated insertions
    /// settle to the right height. Falls back to a per-card heuristic on the
    /// first frame (when fittingSize is still 0,0).
    private func resizeAndPosition(_ window: NSPanel) {
        guard let host = hosting else { return }
        host.view.layoutSubtreeIfNeeded()
        let fitting = host.view.fittingSize
        let height: CGFloat = {
            if fitting.height > 1 { return fitting.height }
            // Heuristic: ~110pt per card + 8pt gap + 16pt outer padding.
            let count = max(1, MWNotificationStack.shared.items.count)
            return CGFloat(count) * 110 + CGFloat(max(0, count - 1)) * 8 + 16
        }()
        let size = NSSize(width: Self.cardWidth, height: height)
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.maxX - size.width - Self.edgeInset
        let y = frame.maxY - size.height - Self.edgeInset
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

/// Borderless panel that never becomes key/main. Clicking a card runs its
/// `onTap` action without pulling MetaWhisp to the front and stealing focus
/// from whatever app the user is currently typing in.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
