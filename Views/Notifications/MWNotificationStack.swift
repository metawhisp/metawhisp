import AppKit
import SwiftUI

/// Singleton state for the in-app notification stack. Push notifications via
/// `MWNotificationStack.shared.push(...)` from anywhere on the main actor.
///
/// Hard cap: 4 cards visible at once. Pushing a 5th drops the oldest with
/// animation (FIFO).
@MainActor
final class MWNotificationStack: ObservableObject {
    static let shared = MWNotificationStack()

    /// Most-recent card first. The view renders newest at the top of the stack.
    @Published private(set) var items: [MWNotification] = []

    /// Per-item auto-fade tasks. Cancelled on hover-enter, re-armed on hover-exit.
    private var fadeTasks: [UUID: Task<Void, Never>] = [:]

    private let maxStack = 4

    /// ITER-067 — how many cards can appear without displacing one already on
    /// screen. The delivery authority asks before deciding to interrupt, so a
    /// comment is held back and kept in the Inbox rather than shoving an
    /// earlier one off before it was read.
    var freeSlots: Int { max(0, maxStack - items.count) }
    private let autoDismissSeconds: TimeInterval = 6

    /// Stretching an agent card to forty-five seconds was the wrong repair.
    /// Fourteen cards in a day, every one recorded as timedOut — and a surface
    /// that sits for forty-five seconds and then vanishes with no consequence
    /// teaches, once per card, that ignoring it costs nothing. The reference
    /// implementation holds a message for two seconds by default and four to
    /// five when there is something to do; nothing anywhere holds one for
    /// three quarters of a minute.
    ///
    /// Six is what this card needs to be read: roughly twelve words of title
    /// and body, about four seconds at reading speed, plus one to notice it.
    /// Nothing is lost by the card going away — the comment itself is a
    /// durable Inbox row and the card is a pointer to it — and hovering still
    /// pauses the timer.
    private let agentCardDismissSeconds: TimeInterval = 6

    /// Visible to tests so the lifetime is a pinned contract rather than a
    /// number someone can quietly stretch again.
    static let toastLifetimeForTests: TimeInterval = 6
    static let agentCardLifetimeForTests: TimeInterval = 6

    private init() {}

    /// Tell the durable record what became of a Screen Agent card. Cards that
    /// are not Screen Agent comments carry no item ID and are ignored.
    private func recordScreenAgentOutcome(_ card: MWNotification,
                                          _ interaction: ScreenAgentDelivery.Interaction) {
        guard let itemID = card.screenAgentItemID else { return }
        AppDelegate.shared?.screenAgentDelivery?.recordInteraction(interaction, itemID: itemID)
        // The outcome of a card is what decides whether it is still waiting for
        // someone, so the count beside the menu bar icon moves with it — the
        // card leaving the screen is the exact moment it becomes findable only
        // through the Inbox.
        AppDelegate.shared?.refreshScreenAgentBadge()
    }


    // MARK: - Public

    /// Push a new card. If the stack is full, drops the oldest.
    func push(_ notification: MWNotification) {
        // FIFO drop when over cap.
        while items.count >= maxStack, let oldest = items.last {
            cancelFade(for: oldest.id)
            // It was on screen; it may not have been read. That is a different
            // fact from the user closing it, and recording it as nothing at all
            // is how a comment silently ceases to exist.
            recordScreenAgentOutcome(oldest, .replaced)
            NSLog("[Notifications] card evicted — stack full at %d, dropped kind=%@ after %.1fs on screen", maxStack, String(describing: oldest.kind), Date().timeIntervalSince(oldest.createdAt))
            items.removeLast()
        }
        // Insert at index 0 so the newest is at the top of the visual stack.
        // macOS 26 fix (2026-05-19) — dropped `withAnimation(.spring)` here.
        // The spring animation kept the SwiftUI ViewUpdater pipeline busy
        // while the panel's resize-on-items-change ran in the same run loop,
        // and Tahoe's stricter Auto Layout bridge recursed forever solving
        // the half-animated frame. Plain insert + transition still gives a
        // visible appearance via the View's `.transition(.move + .opacity)`
        // modifier (also tamed below).
        items.insert(notification, at: 0)
        armFade(for: notification.id)
        NSLog("[Notifications] card shown kind=%@ agent=%@ title=%dch body=%dch stack=%d/%d life=%.0fs", String(describing: notification.kind), notification.screenAgentItemID == nil ? "no" : "yes", notification.title.count, notification.body.count, items.count, maxStack, notification.screenAgentItemID == nil ? autoDismissSeconds : agentCardDismissSeconds)
    }

    /// Dismiss one card by id. No-op if not present.
    ///
    /// `reason` separates the user closing a card from it fading out on its
    /// own. Treating a timeout as a dismissal would teach the product that
    /// silence is rejection.
    func dismiss(id: UUID, reason: ScreenAgentDelivery.Interaction = .dismissed) {
        if let card = items.first(where: { $0.id == id }) {
            recordScreenAgentOutcome(card, reason)
            NSLog("[Notifications] card gone kind=%@ reason=%@ after %.1fs agent=%@", String(describing: card.kind), reason.rawValue, Date().timeIntervalSince(card.createdAt), card.screenAgentItemID == nil ? "no" : "yes")
        }
        cancelFade(for: id)
        withAnimation(.easeOut(duration: 0.2)) {
            items.removeAll { $0.id == id }
        }
    }

    /// Snap close every visible card. Useful for "clear all" key shortcuts.
    func dismissAll() {
        for (_, task) in fadeTasks { task.cancel() }
        fadeTasks.removeAll()
        withAnimation(.easeOut(duration: 0.2)) {
            items.removeAll()
        }
    }

    // MARK: - Hover bridging (called from card view)

    /// Pause the fade timer for the given card while the cursor is over it.
    func setHovering(_ hovering: Bool, id: UUID) {
        if hovering {
            cancelFade(for: id)
        } else {
            // Only re-arm if the card is still in the stack.
            guard items.contains(where: { $0.id == id }) else { return }
            armFade(for: id)
        }
    }

    // MARK: - Private

    private func armFade(for id: UUID) {
        cancelFade(for: id)
        let isAgentCard = items.first { $0.id == id }?.screenAgentItemID != nil
        let life = isAgentCard ? agentCardDismissSeconds : autoDismissSeconds
        fadeTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(life))
            guard !Task.isCancelled else { return }
            // Faded out on its own — nobody closed it, and nobody may have read
            // it either.
            self?.dismiss(id: id, reason: .timedOut)
        }
    }

    private func cancelFade(for id: UUID) {
        fadeTasks[id]?.cancel()
        fadeTasks.removeValue(forKey: id)
    }
}

/// Vertical stack of cards. Sized intrinsically — the stack view is NOT
/// expanded to fill its host. The panel hosts this view and matches its
/// fitting size, so clicks outside the visible cards pass through to whatever
/// app the user is working in (no invisible click-blocker covering the
/// top-right corner of the screen).
struct MWNotificationStackView: View {
    @ObservedObject var stack: MWNotificationStack = .shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(stack.items) { item in
                MWNotificationCard(
                    notification: item,
                    onClose: { stack.dismiss(id: item.id) },
                    onHoverChange: { hovering in
                        stack.setHovering(hovering, id: item.id)
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
        // Outer padding so the drop shadow on each card has room to render
        // without clipping at the panel edge. The panel size is computed
        // from this view's fittingSize in `MWNotificationStackController`.
        .padding(8)
    }
}
