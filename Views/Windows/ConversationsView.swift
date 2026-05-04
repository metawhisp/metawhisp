import SwiftData
import SwiftUI

/// Conversations tab — the root view onto aggregated dictation sessions and meetings.
/// Each row shows LLM-generated title + overview + SF Symbol icon + category chip.
/// Click to expand and see linked memories / tasks / transcripts.
/// Adaptations for our minimal monochrome desktop design:
/// - SF Symbols instead of Unicode emoji
/// - Grouped by relative date (Today / Yesterday / specific date)
/// - Two filter chips only (ALL / STARRED) — 33 categories too many for top filter bar
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
    /// ITER-021 — when non-nil, the list is replaced by `ConversationDetailView`
    /// for that conversation. Tap row to push, click BACK to pop.
    @State private var openedDetailId: UUID?
    /// 2026-04-29 — About Me sheet trigger.
    @State private var showingAboutMe: Bool = false

    @Environment(\.modelContext) private var modelContext

    enum Filter: String, CaseIterable {
        case all = "All"
        case starred = "Starred"
        case meetings = "Meetings"
        case dictations = "Dictations"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ITER-021 — when a conversation is opened, swap the list for the
            // dedicated detail view. Keep navigation state local (not pushing
            // through SwiftUI NavigationStack) so this view continues to work
            // inside the existing tab container without restructure.
            if let detailId = openedDetailId {
                detailHeader
                Rectangle().fill(MW.border).frame(height: MW.hairline)
                ConversationDetailView(conversationId: detailId)
            } else {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showingAboutMe) {
            AboutMeView()
        }
        // openConversation deep-link from Dashboard calendar event rows.
        // Posted after a brief delay so this view has time to mount under
        // the Library tab switch.
        .onReceive(NotificationCenter.default.publisher(for: .openConversation)) { notification in
            if let convId = notification.object as? UUID {
                openedDetailId = convId
            }
        }
    }

    /// Header for the detail mode — BACK button + breadcrumb. Replaces the
    /// regular Conversations header while a detail is open.
    private var detailHeader: some View {
        HStack(spacing: 8) {
            Button {
                openedDetailId = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11))
                    Text("CONVERSATIONS").font(MW.label).tracking(0.6)
                }
                .foregroundStyle(MW.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Header

    /// Liquid Glass spec: big page title. Right side shows an "About me"
    /// button (replaced the redundant `total/shown` counter pair on
    /// 2026-04-29 — `shown` counter survives in the filter bar below).
    /// Click → opens the About Me sheet with sections built from UserMemory.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Conversations")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(MW.textPrimary)
            Spacer()
            Button {
                showingAboutMe = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 11))
                    Text("About me")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.3)
                }
                .foregroundStyle(MW.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassChip(selected: false, radius: 999)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Filter chips

    /// Pill chips per mockup §02: All / Starred / Meetings / Dictations.
    /// TitleCase, ultraThin material inactive, selectFill active.
    /// "N shown" counter stays right-aligned.
    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases, id: \.self) { f in
                GlassChipButton(
                    label: f.rawValue,
                    isActive: selectedFilter == f,
                    radius: 999,
                    action: { selectedFilter = f }
                )
            }
            Spacer()
            Text("\(filtered.count) shown")
                .font(MW.dataSmall)
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

    /// Liquid Glass §02 mockup: each date-group rendered as a SINGLE rounded
    /// glass card containing all rows for that day. Section header sits above
    /// the card. Inner rows are flush — no per-row card chrome (which previously
    /// made the page look like a stack of small chips). Hairlines separate rows.
    private var conversationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(grouped, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(group.label)
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, conv in
                                conversationRow(conv)
                                if idx < group.items.count - 1 {
                                    Rectangle()
                                        .fill(MW.hairlineColor)
                                        .frame(height: 0.5)
                                        .padding(.horizontal, 12)
                                }
                            }
                        }
                        .background {
                            RoundedRectangle(cornerRadius: MW.rMedium, style: .continuous)
                                .fill(.ultraThinMaterial)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: MW.rMedium, style: .continuous)
                                .strokeBorder(MW.border, lineWidth: 0.5)
                        )
                    }
                }
            }
            .padding(20)
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(MW.label)
            .tracking(1.2)
            .foregroundStyle(MW.textMuted)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func conversationRow(_ conv: Conversation) -> some View {
        // Liquid Glass §02 row: flush inside the date-group glass card.
        // Drop the per-row card chrome — wrapper provides it. Inline LIVE pip
        // when status == "inProgress" per mockup.
        let isLive = conv.status == "inProgress"
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: conv.emoji ?? fallbackIcon(for: conv))
                .font(.system(size: 14))
                .foregroundStyle(MW.textSecondary)
                .frame(width: 20, height: 20)

            Text(displayTitle(for: conv, isLive: isLive))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MW.textPrimary)
                .lineLimit(1)

            if isLive {
                HStack(spacing: 4) {
                    Circle()
                        .fill(MW.live)
                        .frame(width: 5, height: 5)
                        .shadow(color: MW.live.opacity(0.6), radius: 4)
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(MW.live)
                }
            }

            if let category = conv.category, !category.isEmpty, category != "other" {
                categoryChip(category)
            }

            Spacer()
            meta(conv)
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundStyle(MW.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture {
            openedDetailId = conv.id
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

    /// Title priority: calendar event name first (when CalendarReader linked
    /// the meeting), else LLM summary title (`conv.title`), else placeholder.
    private func displayTitle(for conv: Conversation, isLive: Bool) -> String {
        if let cal = conv.calendarEventTitle?.trimmingCharacters(in: .whitespaces),
           !cal.isEmpty {
            return cal
        }
        return conv.title ?? (isLive ? "In progress…" : "Untitled")
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
            .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
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
