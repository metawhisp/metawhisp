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

    enum Section: String, CaseIterable {
        case conversations = "CONVERSATIONS"
        case screen = "SCREEN"
        case files = "FILES"
        case memories = "MEMORIES"
        case history = "HISTORY"
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
    }

    private var picker: some View {
        HStack(spacing: 8) {
            ForEach(Section.allCases, id: \.self) { s in
                let isActive = section == s
                Text(s.rawValue)
                    .font(MW.label)
                    .tracking(0.8)
                    .foregroundStyle(isActive ? MW.textPrimary : MW.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(isActive ? MW.elevated : .clear)
                    .overlay(Rectangle().stroke(isActive ? MW.borderLight : MW.border, lineWidth: MW.hairline))
                    .onTapGesture { section = s }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}
