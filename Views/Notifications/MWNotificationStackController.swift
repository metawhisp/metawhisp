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
    /// ITER-076 I-11 — each errand's card, in the same column above the
    /// notification cards: two surfaces in one corner that do not know of
    /// each other collide (the ITER-026 lesson).
    private var errandViews: [UUID: ErrandCardView] = [:]
    private let errands: ErrandCardStack
    /// The visible part of the screen the panel is on: the main screen's,
    /// unless a test gives its own.
    private let screen: () -> NSRect?
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
    /// How far apart two cards' tops stay at least when the column has to
    /// close up to fit the screen: the badge row of each stays in sight.
    private static let leastStep: CGFloat = 52

    /// The panel the cards are in, once a card was shown.
    var panel: NSPanel? { window }

    /// `errands`: the errand cards to show, the app's own unless a test
    /// gives its stack; `screen`: the visible part of the screen the panel
    /// is on, the main screen's unless a test gives its own.
    init(errands: ErrandCardStack? = nil, screen: (() -> NSRect?)? = nil) {
        let errands = errands ?? .shared
        self.errands = errands
        self.screen = screen ?? { (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame }
        // Observe both stacks, render the AppKit views.
        stackCancellable = Publishers.CombineLatest(MWNotificationStack.shared.$items, errands.$cards)
            .receive(on: RunLoop.main)
            .sink { [weak self] items, cards in
                self?.render(items: items, errands: cards)
            }
    }

    // MARK: - Lifecycle

    /// Errand cards first, in the order the errand stack keeps, then the
    /// notification cards, newest first; the panel goes once both are empty.
    func render(items: [MWNotification], errands cards: [ErrandCard]) {
        if items.isEmpty && cards.isEmpty {
            hide()
            return
        }
        ensureWindow()
        guard let container = containerView else { return }

        // Diff: remove cards no longer present, add new ones, keep existing —
        // an errand's card is updated in place. Each takes at most the
        // screen's height less the column's own room around it: a form's
        // rows scroll inside it rather than push its buttons off the screen
        // (ITER-076 stage 7, review round 3, R3-4).
        let room = (screen()?.height ?? .greatestFiniteMagnitude) - Self.panelPadding * 2
        let nextErrands = Set(cards.map(\.id))
        for (id, view) in errandViews where !nextErrands.contains(id) {
            view.removeFromSuperview()
            errandViews.removeValue(forKey: id)
        }
        for card in cards {
            if let view = errandViews[card.id] {
                view.maxHeight = room
                view.update(card)
                continue
            }
            let id = card.id
            let view = ErrandCardView(
                card: card,
                onPress: { [weak errands] action in errands?.press(action, on: id) },
                onClose: { [weak errands] in errands?.close(id) },
                onHover: { [weak errands] hovering in errands?.setHovering(hovering, id: id) }
            )
            view.maxHeight = room
            container.addSubview(view)
            errandViews[id] = view
        }
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
        layoutCards(cards.compactMap { card in errandViews[card.id].map { ($0, $0.measuredHeight) } }
                    + items.compactMap { item in cardViews[item.id].map { ($0, $0.measuredHeight) } })

        // Position the panel.
        repositionWindow()
        NSLog("[Notifications] panel placed — %d card(s), %d errand card(s), %.0fpt tall at (%.0f, %.0f), was visible=%@", items.count, cards.count, container.frame.height, window?.frame.origin.x ?? 0, window?.frame.origin.y ?? 0, (window?.isVisible ?? false) ? "YES" : "NO")

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
        panel.collectionBehavior = MWWindowBehavior.overlay
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.contentView = container

        self.containerView = container
        self.window = panel
    }

    // MARK: - Layout (manual frames — NO Auto Layout)

    /// Where each card's top sits below the column's top, and the column's
    /// height: one card under the other with the gap between and the shadow's
    /// room around — or, when that would run past `available` (the screen's
    /// height), closer together, so every card stays on the screen with at
    /// least its badge row in sight.
    static func column(heights: [CGFloat], available: CGFloat) -> (tops: [CGFloat], height: CGFloat) {
        guard !heights.isEmpty else { return ([], panelPadding * 2) }
        let natural = panelPadding * 2 + heights.reduce(0, +) + CGFloat(heights.count - 1) * interCardGap
        let squeeze = heights.count > 1 ? max(0, natural - available) / CGFloat(heights.count - 1) : 0
        var tops: [CGFloat] = []
        var top = panelPadding
        for height in heights {
            tops.append(top)
            top += max(height + interCardGap - squeeze, leastStep)
        }
        return (tops, tops[tops.count - 1] + heights[heights.count - 1] + panelPadding)
    }

    private func layoutCards(_ cards: [(view: NSView, height: CGFloat)]) {
        let column = Self.column(heights: cards.map(\.height),
                                 available: screen()?.height ?? .greatestFiniteMagnitude)
        // AppKit's Y axis is bottom-up: a top measured down from the
        // column's top is a y measured up from its bottom.
        for (card, top) in zip(cards, column.tops) {
            let cardX = (Self.cardWidth - 344) / 2  // centre 344-wide card in the panel
            card.view.frame = NSRect(x: cardX, y: column.height - top - card.height, width: 344, height: card.height)
        }
        // A card higher in the column is drawn over the one below it, so a
        // column closed up to fit keeps each card's top in sight. Setting the
        // same subviews in another order reorders them and moves none: no
        // view leaves its window, so hover and timers are undisturbed.
        if let container = containerView {
            let drawn = container.subviews.sorted { $0.frame.maxY < $1.frame.maxY }
            if drawn != container.subviews { container.subviews = drawn }
        }
        containerView?.frame = NSRect(x: 0, y: 0, width: Self.cardWidth, height: column.height)
    }

    private func repositionWindow() {
        guard let window, let container = containerView else { return }
        let size = NSSize(width: Self.cardWidth, height: container.frame.height)
        guard let frame = screen() else { return }
        let x = frame.maxX - size.width - Self.edgeInset
        let y = frame.maxY - size.height - Self.edgeInset
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

/// Borderless panel that never becomes key/main. Clicking a card runs its
/// `onTap` action without pulling MetaWhisp to the front and stealing focus
/// from whatever app the user is currently typing in. The agent's disclosure
/// stands on one too (ITER-076 stage 8b).
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
