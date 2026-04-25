import SwiftUI

/// The content of the proactive chip — rendered inside `ProactiveChipWindow`.
/// Stays out of the activation path (window is non-activating) so clicking
/// items here doesn't steal focus from the app the user is typing in.
///
/// spec://iterations/ITER-015-proactive-surfacing
struct ProactiveChipView: View {
    let items: [SurfaceItem]
    let source: String
    let onItemTap: (SurfaceItem) -> Void
    let onDismiss: () -> Void
    /// Called when the user's cursor enters/leaves the chip.
    /// `ProactiveChipWindow` uses this to freeze the auto-fade while reading.
    var onHoverChange: ((Bool) -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow.opacity(0.8))
                Text("CONTEXT")
                    .font(MW.label).tracking(0.6)
                    .foregroundStyle(MW.textMuted)
                Text("· while typing in \(source)")
                    .font(MW.label).tracking(0.4)
                    .foregroundStyle(MW.textMuted)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(MW.textMuted)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }

            ForEach(items) { item in
                chipRow(item)
                    .contentShape(Rectangle())
                    .onTapGesture { onItemTap(item) }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MW.border, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
        .onHover { hovering in
            isHovering = hovering
            onHoverChange?(hovering)
        }
    }

    /// Expose hover state so the window controller can extend the fade timer
    /// as long as the cursor is over the chip.
    var hovering: Bool { isHovering }

    private func chipRow(_ item: SurfaceItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.iconName)
                .font(.system(size: 11))
                .foregroundStyle(MW.textMuted)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(MW.mono)
                    .foregroundStyle(MW.textPrimary)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
