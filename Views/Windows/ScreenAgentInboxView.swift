import SwiftData
import SwiftUI

/// Where a Screen Agent comment lives after its popup is gone.
///
/// A comment used to exist for six seconds and then not exist. Anything noticed
/// out of the corner of an eye was lost, and anything suppressed because the
/// user was in a meeting was thrown away rather than deferred. This is the
/// difference between quiet hours and losing work.
struct ScreenAgentInboxView: View {

    enum Filter: String, CaseIterable, Identifiable {
        case new = "New"
        case later = "Later"
        case all = "All"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .new
    @State private var items: [ScreenAgentItem] = []
    @State private var selectedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if visible.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible, id: \.id) { item in
                            row(item)
                            Divider()
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    // MARK: - Rows

    private func row(_ item: ScreenAgentItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.sourceApp.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(relativeAge(item.capturedAt))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                stateBadge(item)
            }

            Text(item.headline)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)

            if !item.body.isEmpty {
                Text(item.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            if !item.sourceWindowTitle.isEmpty {
                Text(item.sourceWindowTitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Button("Ask MetaWhisp") { ask(item) }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .medium))
                Button("Later") { mark(item, .later) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                Button("Dismiss") { mark(item, .dismissed) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(item.id == selectedID ? Color.accentColor.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.sourceApp): \(item.headline). \(item.body)")
    }

    /// Says plainly why a comment never interrupted, instead of leaving the
    /// user to wonder whether it was shown and missed.
    private func stateBadge(_ item: ScreenAgentItem) -> some View {
        let text: String
        if item.deliveryOutcome == ScreenAgentDelivery.Outcome.suppressed.rawValue {
            switch ScreenAgentDelivery.SuppressionReason(rawValue: item.suppressionReason ?? "") {
            case .meetingInProgress: text = "held — you were in a meeting"
            case .paused: text = "held — paused"
            case .pacing: text = "held — too soon after the last one"
            case .stackFull: text = "held — no room on screen"
            case .staleVisit: text = "held — you had moved on"
            case .featureOff: text = "held — feature was off"
            default: text = "held"
            }
        } else if item.interaction == ScreenAgentDelivery.Interaction.later.rawValue {
            text = "later"
        } else {
            text = ""
        }
        return Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.tertiary)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(filter == .new ? "Nothing new" : "Nothing here")
                .font(.system(size: 13, weight: .medium))
            Text("Comments from the Screen Agent collect here, including the ones it held back.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Data

    private var visible: [ScreenAgentItem] {
        switch filter {
        case .new:
            return items.filter {
                $0.interaction == ScreenAgentDelivery.Interaction.none.rawValue
                    || $0.interaction == ScreenAgentDelivery.Interaction.timedOut.rawValue
                    || $0.interaction == ScreenAgentDelivery.Interaction.replaced.rawValue
            }
        case .later:
            return items.filter { $0.interaction == ScreenAgentDelivery.Interaction.later.rawValue }
        case .all:
            return items
        }
    }

    private func reload() {
        items = AppDelegate.shared?.screenAgentDelivery?.recentItems() ?? []
        if let pending = AppDelegate.shared?.consumePendingScreenAgentItem() {
            selectedID = pending
            filter = .all
        }
    }

    /// Continue this comment in the conversation, with its screen pinned.
    private func ask(_ item: ScreenAgentItem) {
        AppDelegate.shared?.screenAgentDelivery?.recordInteraction(.opened, itemID: item.id)
        NotificationCenter.default.post(
            name: .screenAgentAnchorChat,
            object: ScreenAgentThreadAnchor(item: item)
        )
        NotificationCenter.default.post(name: .screenAgentShowChatPane, object: nil)
        reload()
    }

    private func mark(_ item: ScreenAgentItem, _ interaction: ScreenAgentDelivery.Interaction) {
        AppDelegate.shared?.screenAgentDelivery?.recordInteraction(interaction, itemID: item.id)
        reload()
    }

    private func relativeAge(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(max(0, seconds))s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}
