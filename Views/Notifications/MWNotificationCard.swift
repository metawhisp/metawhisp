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
            if let items = notification.proactiveItems, !items.isEmpty {
                ForEach(items) { item in
                    proactiveRow(item)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleProactiveTap(item)
                            onClose()
                        }
                }
            } else {
                if !notification.title.isEmpty {
                    Text(notification.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MW.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(MW.body)
                        .foregroundStyle(MW.textSecondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(MW.sp12)
        .frame(width: 344, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(MW.border, lineWidth: 0.5)
        )
        .overlay(
            // Specular top rim — subtle white gradient gives the glass its
            // depth. Same trick used by MenuBarView and FloatingVoiceView.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [MW.rimInner, .clear],
                        startPoint: .top, endPoint: .center
                    )
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
        .contentShape(Rectangle())
        .onTapGesture {
            // Single-card kinds: click anywhere → run the action.
            // Proactive cards consume the gesture per row already.
            guard notification.proactiveItems == nil else { return }
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

    // MARK: - Proactive row

    private func proactiveRow(_ item: SurfaceItem) -> some View {
        HStack(alignment: .top, spacing: MW.sp8) {
            Image(systemName: item.iconName)
                .font(.system(size: 11))
                .foregroundStyle(MW.textMuted)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MW.textPrimary)
                    .lineLimit(item.kind == .memory ? 2 : 1)
                if !item.meta.isEmpty {
                    Text(item.meta)
                        .font(.system(size: 11))
                        .foregroundStyle(MW.textMuted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Proactive tap dispatch

    /// Runs the per-row `SurfaceTapAction` for proactive notification cards.
    /// Mirrors the previous `ProactiveChipWindow.handleTap(_:)` behaviour:
    /// `.openChat` opens MetaChat with the query pre-filled (fired through
    /// the existing notification channel after a small mount delay), `.openTab`
    /// just switches the tab.
    private func handleProactiveTap(_ item: SurfaceItem) {
        switch item.tapAction {
        case .openChat(let query):
            AppDelegate.shared?.openMainWindow(tab: .chat)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: .proactivePrefillChat, object: query)
            }
        case .openTab(let tab):
            AppDelegate.shared?.openMainWindow(tab: tab)
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
}
