import AppKit
import Combine

/// Hosts a vertical stack of `MWNotificationCardView` instances inside a
/// borderless non-activating panel docked to the top-right of the active
/// screen.
///
/// **2026-05-19 — pure AppKit rewrite.** The previous implementation hosted
/// `MWNotificationStackView` (SwiftUI) inside `NSHostingController`. On
/// macOS 26 Tahoe, every proactive-insight surface (the `withAnimation`
/// insertion of a SwiftUI card into a `VStack` inside an `NSHostingController`
/// with `sizingOptions = .preferredContentSize`) recursed forever in
/// `NSISEngine._flushPendingRemovals`, killing the app within 1-2 s of the
/// surface event. We tried 4 layers of mitigation (simpler card, defer
/// resize, dropped animation, fixedSize) — Tahoe still crashed.
///
/// The fix: stop using SwiftUI for this surface. AppKit `NSView` cards laid
/// out manually with explicit frames have no Auto Layout cycle to recurse.
/// CALayer handles the rounded corners / shadow / accent bar. No
/// `NSHostingController`, no `NSHostingView`, no SwiftUI animation. The
/// notification API (`MWNotificationStack.shared.push(...)`) is unchanged.
@MainActor
final class MWNotificationStackController {
    private var window: NonActivatingPanel?
    private var containerView: NSView?
    private var cardViews: [UUID: MWNotificationCardView] = [:]
    private var stackCancellable: AnyCancellable?

    // Shadow envelope per side: 2·radius 14 + |offset| 6 = 34 (the no-clip
    // rule from MeetingCoach CardShadowView — a blurred shadow's soft tail
    // extends beyond radius+offset). The old 14/side + 8 panelPadding
    // hard-clipped the card shadows («тень обрезана криво», 2026-06-10).
    private static let cardWidth: CGFloat = 412  // 344 card + 2·34 envelope
    // 0 window margin: the 34pt transparent envelope already provides the
    // visual gap (was 12 + 14 = 26 visual; now 0 + 34 ≈ unchanged).
    private static let edgeInset: CGFloat = 0
    private static let interCardGap: CGFloat = 8
    private static let panelPadding: CGFloat = 34

    init() {
        // Observe stack changes, render the AppKit views.
        stackCancellable = MWNotificationStack.shared.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                self?.render(items: items)
            }
    }

    // MARK: - Lifecycle

    private func render(items: [MWNotification]) {
        if items.isEmpty {
            hide()
            return
        }
        ensureWindow()
        guard let container = containerView else { return }

        // Diff: remove cards no longer present, add new ones, keep existing.
        let nextIDs = Set(items.map(\.id))
        for (id, view) in cardViews where !nextIDs.contains(id) {
            view.removeFromSuperview()
            cardViews.removeValue(forKey: id)
        }
        for item in items where cardViews[item.id] == nil {
            let card = MWNotificationCardView(
                notification: item,
                onClose: { MWNotificationStack.shared.dismiss(id: item.id) },
                onTap: item.onTap.map { handler in { handler() } },
                onHover: { hovering in
                    MWNotificationStack.shared.setHovering(hovering, id: item.id)
                }
            )
            container.addSubview(card)
            cardViews[item.id] = card
        }

        // Lay out cards top-down inside the container.
        layoutCards(items: items)

        // Position the panel.
        repositionWindow()

        if let window, !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    private func hide() {
        window?.orderOut(nil)
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 100),
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
        panel.contentView = container

        self.containerView = container
        self.window = panel
    }

    // MARK: - Layout (manual frames — NO Auto Layout)

    private func layoutCards(items: [MWNotification]) {
        // Newest first (items[0]) at the visual TOP. AppKit Y axis is
        // bottom-up by default, so we lay out from total height downwards.
        var totalHeight: CGFloat = Self.panelPadding * 2
        var heights: [(UUID, CGFloat)] = []
        for item in items {
            guard let card = cardViews[item.id] else { continue }
            // Re-measure in case dynamic-type or content changes between
            // pushes. The card sets its own frame inside `layoutContent`,
            // which is already called on init; reading height is cheap.
            let h = card.measuredHeight
            heights.append((item.id, h))
            totalHeight += h
        }
        if heights.count > 1 {
            totalHeight += CGFloat(heights.count - 1) * Self.interCardGap
        }

        // Place cards top-down within the container, expressed in
        // container-local coordinates (origin top-left visually but
        // AppKit math is bottom-left).
        var y = totalHeight - Self.panelPadding
        for (id, h) in heights {
            guard let card = cardViews[id] else { continue }
            y -= h
            let cardX = (Self.cardWidth - 344) / 2  // centre 344-wide card in the panel
            card.frame = NSRect(x: cardX, y: y, width: 344, height: h)
            y -= Self.interCardGap
        }

        containerView?.frame = NSRect(x: 0, y: 0, width: Self.cardWidth, height: totalHeight)
    }

    private func repositionWindow() {
        guard let window, let container = containerView else { return }
        let size = NSSize(width: Self.cardWidth, height: container.frame.height)
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
