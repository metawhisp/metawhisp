import SwiftUI

/// Library — single hub for all captured data. Sub-sections: Conversations / Screen / Memories / History.
/// User's mental model (2026-04-19): dictations + meetings + screen activity + extracted memories
/// belong under one umbrella. Data hub.
///
/// Each sub-view keeps its own header + filters; Library adds only the top section picker.
///
/// spec://BACKLOG#sidebar-reorg
struct LibraryView: View {
    @State private var section: Section = .conversations

    /// Liquid Glass design — TitleCase pill labels, not the legacy UPPERCASE.
    /// Mirrors mockup §02 Library top section picker.
    enum Section: String, CaseIterable {
        case conversations = "Conversations"
        case screen = "Screen"
        case files = "Files"
        case memories = "Memories"
        case history = "History"
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Rectangle().fill(MW.border).frame(height: MW.hairline)

            switch section {
            case .conversations: ConversationsView()
            case .screen: RewindView()
            case .files: FilesView()
            case .memories: MemoriesView()
            case .history: HistoryView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // openConversation deep-link: ensure CONVERSATIONS section is active
        // so ConversationsView mounts and can pick up the same notification.
        .onReceive(NotificationCenter.default.publisher(for: .openConversation)) { _ in
            section = .conversations
        }
    }

    /// Liquid Glass design — pill-shaped chips per spec § 7 mapping table.
    /// Active chip = `selectFill` background + `selectRim` border + primary text.
    /// Inactive = ultraThin material + border + muted text. Radius 999 (pill).
    private var picker: some View {
        HStack(spacing: 8) {
            ForEach(Section.allCases, id: \.self) { s in
                GlassChipButton(
                    label: s.rawValue,
                    isActive: section == s,
                    radius: 999,
                    action: { section = s }
                )
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}
