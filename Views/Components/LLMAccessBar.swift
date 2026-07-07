import SwiftUI

/// Thin red reminder strip shown at the top of the smart-feature screens
/// (Tasks / Memories / MetaChat) when there's no LLM access (ITER-047 Element B).
///
/// Sits flush to the top of the content, above the screen's own header. Pure
/// state indicator — it writes nothing and disappears the moment access is
/// granted (the host view only mounts it while its gate is closed). Tapping
/// "Settings" deep-links to the Settings tab.
struct LLMAccessBar: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MW.recording)
            Text("Smart features are off — add an API key, Pro, or a local model")
                .font(MW.monoSm)
                .foregroundStyle(MW.recording)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NotificationCenter.default.post(
                    name: .switchMainTab,
                    object: MainWindowView.SidebarTab.settings
                )
            } label: {
                Text("Settings →")
                    .font(MW.label).tracking(0.4)
                    .foregroundStyle(MW.recording)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(MW.recording.opacity(0.4), lineWidth: MW.hairline)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(MW.recording.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(MW.recording.opacity(0.30)).frame(height: MW.hairline)
        }
    }
}
