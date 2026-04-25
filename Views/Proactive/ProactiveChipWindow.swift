import AppKit
import SwiftUI

/// Borderless, non-activating NSWindow that hosts the proactive chip.
///
/// Key constraints:
/// - NEVER steals focus — `isReleasedWhenClosed = false`, `styleMask = .borderless`,
///   `level = .statusBar`, and we set `becomesKey = false` via subclass override.
///   The user's typing app stays frontmost while the chip renders on top.
/// - Positions top-right of active screen, below the menu bar, with safe inset.
/// - Auto-fades after 8s unless hovered. Re-arms timer on hover-exit.
/// - Click item → opens MetaChat with a pre-filled query. Click dismiss → hides.
///
/// spec://iterations/ITER-015-proactive-surfacing
@MainActor
final class ProactiveChipWindow {
    static let shared = ProactiveChipWindow()

    private var window: NonActivatingPanel?
    private var fadeTask: Task<Void, Never>?

    private let visibleSeconds: TimeInterval = 8

    private init() {}

    /// Show the chip with the given items. If already visible, it's replaced.
    func show(items: [SurfaceItem], source: String) {
        guard !items.isEmpty else { return }

        // Build a SwiftUI host with callbacks bound to self.
        // ITER-016 v2 polish: hover-extension. While the cursor is over the chip
        // we cancel the auto-fade. When the cursor leaves we re-arm a fresh timer
        // so the user always gets the FULL `visibleSeconds` after each "leave".
        // This makes long memories actually readable without snatching the chip.
        let hosting = NSHostingController(rootView:
            ProactiveChipView(
                items: items,
                source: source,
                onItemTap: { [weak self] item in
                    self?.handleTap(item)
                },
                onDismiss: { [weak self] in
                    self?.hide()
                },
                onHoverChange: { [weak self] isHovering in
                    self?.handleHoverChange(isHovering)
                }
            )
        )
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        let size = NSSize(width: 344, height: calculatedHeight(itemCount: items.count))

        if let window {
            // Replace contents on re-show without closing/opening — avoids flicker.
            window.contentViewController = hosting
            window.setContentSize(size)
            positionTopRight(window, size: size)
            window.orderFrontRegardless()
        } else {
            let panel = NonActivatingPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false        // SwiftUI .shadow handles it so edges look right
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = false
            panel.ignoresMouseEvents = false
            panel.contentViewController = hosting
            positionTopRight(panel, size: size)
            panel.orderFrontRegardless()
            self.window = panel
        }

        armFadeTimer()
    }

    /// Hide immediately. Cancels any pending fade.
    func hide() {
        fadeTask?.cancel()
        fadeTask = nil
        window?.orderOut(nil)
    }

    // MARK: - Internal

    private func handleTap(_ item: SurfaceItem) {
        switch item.tapAction {
        case .openChat(let query):
            hide()
            // Open MetaChat tab + pre-fill via the existing notification channel.
            // We post switchMainTab → ChatView picks up pre-fill by a separate
            // notification that ChatView listens for.
            AppDelegate.shared?.openMainWindow(tab: .chat)
            NotificationCenter.default.post(name: .proactivePrefillChat, object: query)
        case .openTab(let tab):
            hide()
            AppDelegate.shared?.openMainWindow(tab: tab)
        }
    }

    /// Estimates window height from the item count. Kept in-line rather than
    /// `.sizeThatFits` because NSHostingController's sizing lags the first frame
    /// on a freshly-constructed panel and we want the position correct on open.
    private func calculatedHeight(itemCount: Int) -> CGFloat {
        let headerHeight: CGFloat = 18
        let rowHeight: CGFloat = 44
        let vPadding: CGFloat = 24
        return headerHeight + CGFloat(itemCount) * rowHeight + vPadding
    }

    private func positionTopRight(_ w: NSWindow, size: NSSize) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let margin: CGFloat = 12
        let x = frame.maxX - size.width - margin
        let y = frame.maxY - size.height - margin
        w.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// `visibleSeconds` auto-fade. Re-runs on each `show(...)` call AND on hover-exit
    /// (so the user always gets the full window after the cursor leaves). Cancelled
    /// by `hide()`, by hover-enter, and by `show(...)` while another timer is pending.
    private func armFadeTimer() {
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.visibleSeconds ?? 8))
            guard !Task.isCancelled, let self else { return }
            self.hide()
        }
    }

    /// Hover-extension callback wired through `ProactiveChipView`.
    /// - enter: cancel the running fade so chip stays put while user reads.
    /// - exit: re-arm a FULL fade window from zero (not the leftover from before
    ///   hover-enter) — gives the user a fresh chance to glance back if they missed
    ///   something, without trapping the chip on screen forever.
    private func handleHoverChange(_ isHovering: Bool) {
        if isHovering {
            fadeTask?.cancel()
            fadeTask = nil
        } else {
            armFadeTimer()
        }
    }
}

/// Non-activating panel subclass — `canBecomeKey` and `canBecomeMain` return
/// false so clicking the chip doesn't pull MetaWhisp to the front and steal
/// the user's current frontmost app focus.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    /// Posted by `ProactiveChipWindow` when the user taps an item.
    /// `object: String` = the query to pre-fill in MetaChat input.
    static let proactivePrefillChat = Notification.Name("MetaWhisp.proactivePrefillChat")
}
