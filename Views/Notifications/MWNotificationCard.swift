import SwiftUI

/// One Liquid Glass card. Same shape for every kind — only icon/accent/content
/// differ. Designed to read in 1–2 seconds while the user is doing something
/// else; details live in the destination tab when they click.
@MainActor
struct MWNotificationCard: View {
    let notification: MWNotification
    let onClose: @MainActor () -> Void
    let onHoverChange: (@MainActor (Bool) -> Void)?

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: MW.sp6) {
            header
            // ITER-027.5 — single-line render for ALL kinds including
            // `.proactive`. The previous SurfaceItem list is gone; insights
            // surface as headline + body just like `.task` / `.advice` etc.
            // macOS 26 — inner `.frame(maxWidth: .infinity)` on Text views
            // combined with outer `.frame(width: 344)` on the VStack
            // triggered NSISEngine constraint-solver recursion every time
            // a proactive insight was surfaced (user-reported crash
            // 2026-05-19 21:04:59). Outer fixed width handles horizontal
            // expansion; inner Text width-constraints are redundant and
            // confuse Tahoe's stricter Auto Layout bridge.
            if !notification.title.isEmpty {
                Text(notification.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MW.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if !notification.body.isEmpty {
                Text(notification.body)
                    .font(MW.body)
                    .foregroundStyle(MW.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(MW.sp12)
        .frame(width: 344, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        // macOS 26 Tahoe crash fix (2026-05-19): the previous stack of
        // `.background(.thinMaterial)` + two `.overlay(RoundedRectangle…)`
        // + `.shadow(…)` triggered NSISEngine recursion every time a
        // proactive insight surfaced. Tahoe's stricter Auto Layout bridge
        // can't keep up with multiple round-rect-clipped layers stacked
        // on a SwiftUI Card. Reduced to a single opaque background +
        // single border. Lose the liquid-glass specular rim + drop shadow
        // here; trade-off is acceptable because cards are short-lived
        // (6 s autodismiss). Reintroduce one effect at a time once we
        // have a Layout Instruments trace of the exact cycle source.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(MW.border, lineWidth: 0.5)
        )
        // Explicit shadow envelope (20pt = radius 14 + |y| 6) — without this,
        // the 344pt card centred in a 360pt window only has 8pt margin per
        // side, but shadow needs 14pt → straight cut on left/right + a bigger
        // one on bottom. Stack controller bumps cardWidth + height calc to
        // accommodate this padding. 2026-05-12.
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .contentShape(Rectangle())
        .onTapGesture {
            // Single-tap action for all kinds (ITER-027.5 unified rendering).
            notification.onTap?()
            onClose()
        }
        .onHover { hovering in
            isHovering = hovering
            onHoverChange?(hovering)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: MW.sp6) {
            Image(systemName: notification.kind.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(notification.kind.accent)
                .frame(width: 14)
            Text(notification.kind.label)
                .font(MW.label).tracking(0.6)
                .foregroundStyle(MW.textMuted)
            Text("· \(relativeTime)")
                .font(MW.label).tracking(0.4)
                .foregroundStyle(MW.textDim)
            Spacer(minLength: MW.sp4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MW.textMuted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    /// Compact relative-time stamp ("2m" / "1h" / "now"). Recomputed each render
    /// — cards are short-lived (≤6s default) so we don't bother with timer.
    private var relativeTime: String {
        let elapsed = Date().timeIntervalSince(notification.createdAt)
        if elapsed < 5 { return "now" }
        if elapsed < 60 { return "\(Int(elapsed))s" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
        return "\(Int(elapsed / 3600))h"
    }
}

extension Notification.Name {
    /// Posted when a proactive-card row with `.openChat(query:)` is tapped.
    /// `object: String` = the query to pre-fill in MetaChat input. ChatView
    /// listens via `.onReceive(...)` and writes it into its input field.
    static let proactivePrefillChat = Notification.Name("MetaWhisp.proactivePrefillChat")

    /// ITER-068 — "continue this comment". Carries a `ScreenAgentThreadAnchor`,
    /// not a question: the user writes their own.
    static let screenAgentAnchorChat = Notification.Name("MetaWhisp.screenAgentAnchorChat")

    /// Switch the MetaChat pane back to the conversation.
    static let screenAgentShowChatPane = Notification.Name("MetaWhisp.screenAgentShowChatPane")

    /// A specific comment was asked for; the Inbox reloads and selects it even
    /// when it is already on screen.
    static let screenAgentOpenItem = Notification.Name("MetaWhisp.screenAgentOpenItem")

    /// Switch the MetaChat pane to the Inbox.
    static let screenAgentShowInboxPane = Notification.Name("MetaWhisp.screenAgentShowInboxPane")
}
