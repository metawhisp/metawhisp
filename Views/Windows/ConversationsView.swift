import SwiftData
import SwiftUI

/// Conversations tab — the Omi-style root view onto aggregated dictation sessions and meetings.
/// Each row shows LLM-generated title + overview + SF Symbol icon + category chip.
/// Click to expand and see linked memories / tasks / transcripts.
///
/// Omi reference: mobile/desktop Conversations tab (screenshot 2026-04-19).
/// Adaptations for our minimal monochrome desktop design:
/// - SF Symbols instead of Unicode emoji
/// - Grouped by relative date (Today / Yesterday / specific date)
/// - Two filter chips only (ALL / STARRED) — 33 Omi categories too many for top filter bar
///
/// spec://BACKLOG#C1.4
struct ConversationsView: View {
    @Query(
        filter: #Predicate<Conversation> { !$0.discarded },
        sort: \Conversation.startedAt,
        order: .reverse
    )
    private var conversations: [Conversation]

    @State private var selectedFilter: Filter = .all
    @State private var expandedIds: Set<UUID> = []

    @Environment(\.modelContext) private var modelContext

    enum Filter: String, CaseIterable {
        case all = "ALL"
        case starred = "STARRED"
        case meetings = "MEETINGS"
        case dictations = "DICTATIONS"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(MW.border).frame(height: MW.hairline)
            filterBar
            Rectangle().fill(MW.border).frame(height: MW.hairline)

            if filtered.isEmpty {
                emptyState
            } else {
                conversationList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("CONVERSATIONS")
                .font(MW.monoLg)
                .foregroundStyle(MW.textPrimary)
                .tracking(2)
            Spacer()
            Text("\(conversations.count) total")
                .font(MW.monoSm)
                .foregroundStyle(MW.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Filter chips

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases, id: \.self) { f in
                let isActive = selectedFilter == f
                Text(f.rawValue)
                    .font(MW.label)
                    .tracking(0.8)
                    .foregroundStyle(isActive ? MW.textPrimary : MW.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(isActive ? MW.elevated : .clear)
                    .overlay(Rectangle().stroke(isActive ? MW.borderLight : MW.border, lineWidth: MW.hairline))
                    .onTapGesture { selectedFilter = f }
            }
            Spacer()
            Text("\(filtered.count) shown")
                .font(MW.monoSm)
                .foregroundStyle(MW.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - List

    private var filtered: [Conversation] {
        switch selectedFilter {
        case .all: return conversations
        case .starred: return conversations.filter { $0.starred }
        case .meetings: return conversations.filter { $0.source == "meeting" }
        case .dictations: return conversations.filter { $0.source == "dictation" }
        }
    }

    private var grouped: [(label: String, items: [Conversation])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        var bucketsOrdered: [String] = []
        var buckets: [String: [Conversation]] = [:]

        let df: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MMM d, yyyy"
            return f
        }()

        for conv in filtered {
            let day = cal.startOfDay(for: conv.startedAt)
            let label: String
            if day == today { label = "TODAY" }
            else if day == yesterday { label = "YESTERDAY" }
            else { label = df.string(from: conv.startedAt).uppercased() }
            if buckets[label] == nil {
                buckets[label] = []
                bucketsOrdered.append(label)
            }
            buckets[label]?.append(conv)
        }
        return bucketsOrdered.map { ($0, buckets[$0] ?? []) }
    }

    private var conversationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(grouped, id: \.label) { group in
                    sectionHeader(group.label)
                    ForEach(group.items) { conv in
                        conversationRow(conv)
                    }
                }
            }
            .padding(16)
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(MW.label)
            .tracking(1.0)
            .foregroundStyle(MW.textMuted)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func conversationRow(_ conv: Conversation) -> some View {
        let isExpanded = expandedIds.contains(conv.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: conv.emoji ?? fallbackIcon(for: conv))
                    .font(.system(size: 14))
                    .foregroundStyle(MW.textSecondary)
                    .frame(width: 20, height: 20, alignment: .center)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(conv.title ?? (conv.status == "inProgress" ? "In progress…" : "Untitled"))
                            .font(MW.mono)
                            .foregroundStyle(MW.textPrimary)
                            .lineLimit(1)
                        if let category = conv.category, !category.isEmpty, category != "other" {
                            categoryChip(category)
                        }
                        Spacer()
                        meta(conv)
                    }
                    if let overview = conv.overview, !overview.isEmpty {
                        Text(overview)
                            .font(MW.monoSm)
                            .foregroundStyle(MW.textSecondary)
                            .lineLimit(isExpanded ? nil : 2)
                    }
                }
            }
            if isExpanded {
                expandedDetails(conv)
                    .padding(.leading, 30)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .background(MW.surface)
        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded { expandedIds.remove(conv.id) } else { expandedIds.insert(conv.id) }
        }
    }

    private func meta(_ conv: Conversation) -> some View {
        HStack(spacing: 8) {
            Button {
                conv.starred.toggle()
                conv.updatedAt = Date()
                try? modelContext.save()
            } label: {
                Image(systemName: conv.starred ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(conv.starred ? MW.textSecondary : MW.textMuted)
            }
            .buttonStyle(.plain)

            Text(conv.startedAt.formatted(date: .omitted, time: .shortened))
                .font(MW.monoSm)
                .foregroundStyle(MW.textMuted)
        }
    }

    /// Icon shown before StructuredGenerator sets a specific SF Symbol.
    /// Meetings get a distinct visual; dictations get a waveform.
    private func fallbackIcon(for conv: Conversation) -> String {
        switch conv.source {
        case "meeting": return "video"
        case "dictation": return "waveform"
        default: return "bubble.left"
        }
    }

    private func categoryChip(_ category: String) -> some View {
        Text(category.uppercased())
            .font(MW.label)
            .tracking(0.5)
            .foregroundStyle(MW.textMuted)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(MW.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Expanded details

    @ViewBuilder
    private func expandedDetails(_ conv: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            linkedTranscripts(conversationId: conv.id)
            linkedTasks(conversationId: conv.id)
            linkedMemories(conversationId: conv.id)
            HStack {
                if conv.source == "meeting" {
                    labelChip("MEETING")
                } else {
                    labelChip("DICTATION")
                }
                labelChip(conv.status.uppercased())
                Spacer()
                Button {
                    conv.discarded = true
                    conv.updatedAt = Date()
                    try? modelContext.save()
                } label: {
                    Text("DISCARD").font(MW.label).tracking(0.5).foregroundStyle(MW.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func labelChip(_ text: String) -> some View {
        Text(text)
            .font(MW.label)
            .tracking(0.6)
            .foregroundStyle(MW.textMuted)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
    }

    @ViewBuilder
    private func linkedTranscripts(conversationId: UUID) -> some View {
        let items = fetchHistory(conversationId: conversationId)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("TRANSCRIPTS · \(items.count)")
                    .font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "waveform").font(.system(size: 9)).foregroundStyle(MW.textMuted)
                        Text(item.displayText)
                            .font(MW.monoSm)
                            .foregroundStyle(MW.textSecondary)
                            .lineLimit(3)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func linkedTasks(conversationId: UUID) -> some View {
        let items = fetchTasks(conversationId: conversationId)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("TASKS · \(items.count)")
                    .font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.completed ? "checkmark.square.fill" : "square")
                            .font(.system(size: 10)).foregroundStyle(MW.textMuted)
                        Text(item.taskDescription)
                            .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                            .strikethrough(item.completed)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func linkedMemories(conversationId: UUID) -> some View {
        let items = fetchMemories(conversationId: conversationId)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("MEMORIES · \(items.count)")
                    .font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "brain").font(.system(size: 9)).foregroundStyle(MW.textMuted)
                        Text(item.content)
                            .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Fetch helpers (called lazily per-row; small result sets)

    private func fetchHistory(conversationId: UUID) -> [HistoryItem] {
        var descriptor = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 50
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchTasks(conversationId: UUID) -> [TaskItem] {
        var descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.conversationId == conversationId && !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 20
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchMemories(conversationId: UUID) -> [UserMemory] {
        var descriptor = FetchDescriptor<UserMemory>(
            predicate: #Predicate { $0.conversationId == conversationId && !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 20
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(MW.textMuted)
            Text("No conversations yet")
                .font(MW.monoLg)
                .foregroundStyle(MW.textSecondary)
            Text("Dictate through Right ⌘ or start a meeting recording. Transcripts auto-group into conversations after 10 min of silence.")
                .font(MW.mono)
                .foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
