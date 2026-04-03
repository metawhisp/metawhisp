import SwiftData
import SwiftUI

/// Transcription history list — BLOCKS monochromatic style.
struct HistoryView: View {
    @Query(sort: \HistoryItem.createdAt, order: .reverse) private var items: [HistoryItem]
    @Environment(\.modelContext) private var context
    @State private var searchText = ""
    @State private var showClearConfirm = false
    @State private var selectedId: UUID?

    private var filtered: [HistoryItem] {
        guard !searchText.isEmpty else { return items }
        let q = searchText.lowercased()
        return items.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            searchBar
            if items.isEmpty {
                emptyState
            } else {
                tableHeader
                tableContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MW.bg)
        .alert("Clear all history?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) { clearAll() }
        } message: {
            Text("This cannot be undone. All \(items.count) transcriptions will be deleted.")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("HISTORY")
                .font(MW.monoLg)
                .foregroundStyle(MW.textPrimary)
                .tracking(2)
            Spacer()
            if !items.isEmpty {
                Text("\(filtered.count) RECORDS").blocksLabel()
                BlocksButton(label: "CLEAR ALL", icon: "trash") {
                    showClearConfirm = true
                }
            }
        }
        .padding(MW.sp16)
        .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: MW.sp8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(MW.textMuted)
            TextField("", text: $searchText, prompt:
                Text("SEARCH...")
                    .font(MW.mono)
                    .foregroundStyle(MW.textMuted)
            )
            .textFieldStyle(.plain)
            .font(MW.mono)
            .foregroundStyle(MW.textPrimary)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(MW.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, MW.sp16)
        .padding(.vertical, MW.sp8)
        .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
    }

    // MARK: - Table Header

    private var tableHeader: some View {
        HStack(spacing: 0) {
            columnHeader("TEXT", flex: true)
            columnHeader("LANG", width: 50)
            columnHeader("MODEL", width: 90)
            columnHeader("TIME", width: 60)
            columnHeader("WORDS", width: 55)
            columnHeader("DATE", width: 60)
            columnHeader("", width: 32) // copy button column
        }
        .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
    }

    @ViewBuilder
    private func columnHeader(_ text: String, width: CGFloat = 0, flex: Bool = false) -> some View {
        let content = Text(text)
            .font(MW.label)
            .tracking(1)
            .foregroundStyle(MW.textMuted)
            .padding(.horizontal, MW.sp12)
            .padding(.vertical, MW.sp8)

        if flex {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().fill(MW.border).frame(width: MW.hairline), alignment: .trailing)
        } else {
            content
                .frame(width: width, alignment: .leading)
                .overlay(Rectangle().fill(MW.border).frame(width: MW.hairline), alignment: .trailing)
        }
    }

    // MARK: - Table Content

    private var tableContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { item in
                    let selected = item.id == selectedId
                    HistoryRowView(item: item, isSelected: selected)
                        .id("\(item.id)-\(selected)")  // Force layout recalc on expand/collapse
                        .onTapGesture { selectedId = selected ? nil : item.id }
                        .contextMenu {
                            Button("Copy") { copyText(item.displayText) }
                            Divider()
                            Button("Delete", role: .destructive) { deleteItem(item) }
                        }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: MW.sp16) {
            Text("NO TRANSCRIPTIONS")
                .font(MW.monoLg)
                .foregroundStyle(MW.textMuted)
                .tracking(2)
            Text("PRESS RIGHT \u{2318} TO START RECORDING")
                .font(MW.mono)
                .foregroundStyle(MW.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func deleteItem(_ item: HistoryItem) {
        context.delete(item)
        try? context.save()
    }

    private func clearAll() {
        do {
            try context.delete(model: HistoryItem.self)
            try context.save()
        } catch { NSLog("[History] Clear all failed: \(error)") }
    }
}

// MARK: - Row

struct HistoryRowView: View {
    let item: HistoryItem
    var isSelected: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Text
            Text(item.displayText)
                .font(MW.mono)
                .foregroundStyle(MW.textPrimary)
                .lineLimit(isSelected ? 20 : 2)
                .lineSpacing(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, MW.sp12)
                .clipped()

            // Language badge
            Group {
                if let lang = item.language {
                    Text(lang.uppercased())
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textSecondary)
                } else {
                    Text("--")
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textMuted)
                }
            }
            .frame(width: 50, alignment: .leading)
            .padding(.horizontal, MW.sp12)

            // Model name
            Group {
                if let model = item.modelName {
                    Text(model.uppercased())
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("--")
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textMuted)
                }
            }
            .frame(width: 90, alignment: .leading)
            .padding(.horizontal, MW.sp12)

            // Processing time
            Text(String(format: "%.1fs", item.processingTime))
                .font(MW.monoSm)
                .foregroundStyle(MW.textSecondary)
                .frame(width: 60, alignment: .leading)
                .padding(.horizontal, MW.sp12)

            // Word count
            Text("\(item.wordCount)")
                .font(MW.monoSm)
                .foregroundStyle(MW.textSecondary)
                .frame(width: 55, alignment: .leading)
                .padding(.horizontal, MW.sp12)

            // Date
            Text(timeAgo(item.createdAt))
                .font(MW.monoSm)
                .foregroundStyle(MW.textMuted)
                .frame(width: 60, alignment: .leading)
                .padding(.horizontal, MW.sp12)

            // Copy button
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.displayText, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(MW.textMuted)
            }
            .buttonStyle(.plain)
            .frame(width: 32)
            .help("Copy to clipboard")
        }
        .padding(.vertical, MW.sp8)
        .fixedSize(horizontal: false, vertical: true)
        .background(isSelected ? Color.white.opacity(0.04) : .clear)
        .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    private func timeAgo(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}
