import SwiftData
import SwiftUI

/// Full conversation detail view (ITER-021).
///
/// Replaces the previous inline-expand pattern in `ConversationsView` for a
/// dedicated push-navigation surface. Layout:
///
/// - Header: emoji + title + category/project chips + status + dates
/// - Action bar: REGENERATE / STAR / DISCARD
/// - Tabs: SUMMARY / TRANSCRIPT / LINKED
///   - SUMMARY tab — overview + 5 structured sections (decisions / action items /
///     participants / key quotes / next steps). Empty sections hidden.
///   - TRANSCRIPT tab — full scrollable + selectable text.
///   - LINKED tab — pending tasks (split MY / WAITING-ON via ITER-013) + memories.
///
/// Source-of-truth fix for the user-reported "Quick note + (empty)" bug:
/// REGENERATE button calls `StructuredGenerator.regenerate(_:)` which fully
/// resets and re-runs the LLM path. Combined with the expanded launch backfill +
/// new 30-min periodic backfill, conversations should never stay stuck on
/// placeholder fields silently.
///
/// spec://iterations/ITER-021-structured-summary
struct ConversationDetailView: View {
    let conversationId: UUID

    @Environment(\.modelContext) private var modelContext

    @State private var conversation: Conversation?
    @State private var transcript: [HistoryItem] = []
    @State private var linkedTasks: [TaskItem] = []
    @State private var linkedMemories: [UserMemory] = []
    @State private var selectedTab: Tab = .summary
    @State private var isRegenerating = false
    @State private var lastError: String?

    private enum Tab: String, CaseIterable {
        case summary = "SUMMARY"
        case transcript = "TRANSCRIPT"
        case linked = "LINKED"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let conv = conversation {
                header(conv)
                Rectangle().fill(MW.border).frame(height: MW.hairline)
                tabBar
                Rectangle().fill(MW.border).frame(height: MW.hairline)
                ScrollView {
                    VStack(alignment: .leading, spacing: MW.sp16) {
                        switch selectedTab {
                        case .summary:    summaryTab(conv)
                        case .transcript: transcriptTab
                        case .linked:     linkedTab
                        }
                    }
                    .padding(MW.sp16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: conversationId) {
            await reload()
        }
    }

    // MARK: - Header

    private func header(_ conv: Conversation) -> some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            HStack(alignment: .center, spacing: MW.sp10) {
                Image(systemName: conv.emoji ?? "bubble.left")
                    .font(.system(size: 22))
                    .foregroundStyle(MW.textSecondary)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conv.title ?? (conv.status == "inProgress" ? "In progress…" : "Untitled"))
                        .font(MW.monoTitle)
                        .foregroundStyle(MW.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let cat = conv.category, !cat.isEmpty, cat != "other" {
                            chip(cat.uppercased())
                        }
                        if let proj = conv.primaryProject, !proj.isEmpty {
                            chip("📁 \(proj)")
                        }
                        chip(conv.source.uppercased())
                        Text(conv.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(MW.monoSm)
                            .foregroundStyle(MW.textMuted)
                    }
                }
                Spacer()
                actionBar(conv)
            }
            if let ov = conv.overview, !ov.isEmpty, ov != "(empty)" {
                Text(ov)
                    .font(MW.mono)
                    .foregroundStyle(MW.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = lastError {
                Text(err)
                    .font(MW.monoSm)
                    .foregroundStyle(.red.opacity(0.85))
            }
        }
        .padding(.horizontal, MW.sp20)
        .padding(.vertical, MW.sp16)
    }

    private func actionBar(_ conv: Conversation) -> some View {
        HStack(spacing: 6) {
            Button {
                Task { await regenerate() }
            } label: {
                HStack(spacing: 4) {
                    if isRegenerating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    }
                    Text(isRegenerating ? "REGENERATING…" : "REGENERATE")
                        .font(MW.label).tracking(0.6)
                }
                .foregroundStyle(MW.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(isRegenerating)

            Button {
                conv.starred.toggle()
                conv.updatedAt = Date()
                try? modelContext.save()
            } label: {
                Image(systemName: conv.starred ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(conv.starred ? MW.textSecondary : MW.textMuted)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { selectedTab = t }
                } label: {
                    Text(t.rawValue)
                        .font(MW.label).tracking(0.6)
                        .foregroundStyle(selectedTab == t ? MW.textPrimary : MW.textMuted)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity)
                        .background(
                            Rectangle()
                                .fill(MW.textPrimary)
                                .frame(height: 2)
                                .opacity(selectedTab == t ? 1 : 0)
                                .padding(.top, 32),
                            alignment: .bottom
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, MW.sp20)
    }

    // MARK: - SUMMARY tab

    private func summaryTab(_ conv: Conversation) -> some View {
        VStack(alignment: .leading, spacing: MW.sp16) {
            section(label: "DECISIONS", icon: "checkmark.circle", items: conv.decisions)
            section(label: "ACTION ITEMS", icon: "arrow.forward.circle", items: conv.actionItems)
            participantsSection(conv.participants)
            quotesSection(conv.keyQuotes)
            section(label: "NEXT STEPS", icon: "arrow.uturn.right", items: conv.nextSteps)
            if conv.decisions.isEmpty && conv.actionItems.isEmpty
                && conv.participants.isEmpty && conv.keyQuotes.isEmpty
                && conv.nextSteps.isEmpty {
                emptySummary(conv)
            }
        }
    }

    private func section(label: String, icon: String, items: [String]) -> some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: icon).font(.system(size: 11)).foregroundStyle(MW.textMuted)
                        Text(label).font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                    }
                    ForEach(items, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•").font(MW.mono).foregroundStyle(MW.textMuted)
                            Text(item).font(MW.mono).foregroundStyle(MW.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                    }
                }
                .padding(MW.sp12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .mwCard(radius: MW.rMedium, elevation: .raised)
            }
        }
    }

    private func participantsSection(_ items: [String]) -> some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2").font(.system(size: 11)).foregroundStyle(MW.textMuted)
                        Text("PARTICIPANTS").font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                    }
                    HStack(spacing: 6) {
                        ForEach(items, id: \.self) { name in
                            Text(name)
                                .font(MW.monoSm)
                                .foregroundStyle(MW.textPrimary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                        }
                        Spacer()
                    }
                }
                .padding(MW.sp12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .mwCard(radius: MW.rMedium, elevation: .raised)
            }
        }
    }

    private func quotesSection(_ items: [String]) -> some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "quote.opening").font(.system(size: 11)).foregroundStyle(MW.textMuted)
                        Text("KEY QUOTES").font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                    }
                    ForEach(items, id: \.self) { quote in
                        Text("\u{201C}\(quote)\u{201D}")
                            .font(MW.mono.italic())
                            .foregroundStyle(MW.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 12)
                            .overlay(
                                Rectangle()
                                    .fill(MW.border)
                                    .frame(width: 2)
                                    .padding(.vertical, 2),
                                alignment: .leading
                            )
                    }
                }
                .padding(MW.sp12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .mwCard(radius: MW.rMedium, elevation: .raised)
            }
        }
    }

    private func emptySummary(_ conv: Conversation) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(MW.textMuted)
            Text("No structured summary yet")
                .font(MW.mono).foregroundStyle(MW.textSecondary)
            Text(conv.title == "Quick note"
                 ? "This conversation needs to be regenerated. Click REGENERATE in the header."
                 : "Sections appear here once the LLM extracts decisions, action items, quotes, etc. Try REGENERATE if it's been a while.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - TRANSCRIPT tab

    private var transcriptTab: some View {
        Group {
            if transcript.isEmpty {
                Text("No transcript items linked.")
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
            } else {
                VStack(alignment: .leading, spacing: MW.sp10) {
                    Text("\(transcript.count) item\(transcript.count == 1 ? "" : "s") · \(totalChars) chars")
                        .font(MW.label).tracking(0.6)
                        .foregroundStyle(MW.textMuted)
                    ForEach(transcript) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                                if let lang = item.language, !lang.isEmpty {
                                    Text(lang.uppercased())
                                        .font(MW.label).tracking(0.6)
                                        .foregroundStyle(MW.textMuted)
                                }
                                Spacer()
                            }
                            Text(item.displayText)
                                .font(MW.mono)
                                .foregroundStyle(MW.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(MW.sp12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .mwCard(radius: MW.rSmall, elevation: .flat)
                    }
                }
            }
        }
    }

    private var totalChars: Int {
        transcript.reduce(0) { $0 + $1.displayText.count }
    }

    // MARK: - LINKED tab

    private var linkedTab: some View {
        VStack(alignment: .leading, spacing: MW.sp16) {
            // Tasks split by ownership (ITER-013).
            let myTasks = linkedTasks.filter { $0.isMyTask && !$0.completed }
            let waitingMap = Dictionary(grouping: linkedTasks.filter { !$0.isMyTask && !$0.completed }) {
                ($0.assignee ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !myTasks.isEmpty {
                taskSection(label: "MY TASKS", tasks: myTasks)
            }
            ForEach(waitingMap.keys.sorted(), id: \.self) { name in
                if let group = waitingMap[name], !name.isEmpty {
                    taskSection(label: "WAITING ON \(name.uppercased())", tasks: group)
                }
            }
            if !linkedMemories.isEmpty {
                memoriesSection
            }
            if linkedTasks.isEmpty && linkedMemories.isEmpty {
                Text("No tasks or memories extracted from this conversation.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
        }
    }

    private func taskSection(label: String, tasks: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
            ForEach(tasks) { t in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle").font(.system(size: 11)).foregroundStyle(MW.textMuted)
                    Text(t.taskDescription).font(MW.mono).foregroundStyle(MW.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
        .padding(MW.sp12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private var memoriesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MEMORIES").font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
            ForEach(linkedMemories) { m in
                VStack(alignment: .leading, spacing: 2) {
                    if let h = m.headline, !h.isEmpty {
                        Text(h).font(MW.mono).foregroundStyle(MW.textPrimary).lineLimit(1)
                    }
                    Text(m.content).font(MW.monoSm).foregroundStyle(MW.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(MW.sp12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    // MARK: - Bits

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(MW.label).tracking(0.6)
            .foregroundStyle(MW.textMuted)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(MW.border, lineWidth: 0.5))
    }

    // MARK: - Data

    private func reload() async {
        var convDesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conversationId })
        convDesc.fetchLimit = 1
        conversation = try? modelContext.fetch(convDesc).first
        let id = conversationId
        var histDesc = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.conversationId == id },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        histDesc.fetchLimit = 200
        transcript = (try? modelContext.fetch(histDesc)) ?? []
        let taskDesc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed && $0.conversationId == id },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        linkedTasks = (try? modelContext.fetch(taskDesc)) ?? []
        let memDesc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed && $0.conversationId == id },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        linkedMemories = (try? modelContext.fetch(memDesc)) ?? []
    }

    private func regenerate() async {
        guard let appDelegate = AppDelegate.shared else { return }
        isRegenerating = true
        defer { isRegenerating = false }
        lastError = nil
        await appDelegate.structuredGenerator.regenerate(conversationId: conversationId)
        await reload()
        if let conv = conversation,
           conv.title == "Quick note" || (conv.overview ?? "") == "(empty)" {
            lastError = "Regenerate produced no useful output. The transcript may be too short or the LLM proxy is unavailable."
        }
    }
}
