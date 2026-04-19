import SwiftData
import SwiftUI

/// Rewind tab — screen activity timeline. Shows ScreenObservation rows grouped by date,
/// with search over OCR / contextSummary, app / category filters.
/// Click a row to expand and see source OCR + linked memories + linked tasks.
/// on their desktop screenshots. Ours is leaner: no video chunk preview (we're OCR-only),
/// no draggable scrubber yet — list + expand instead.
/// spec://BACKLOG#Phase2.R3
struct RewindView: View {
    @Query(
        sort: \ScreenObservation.startedAt,
        order: .reverse
    )
    private var observations: [ScreenObservation]

    @State private var selectedRange: DateRange = .today
    @State private var searchQuery: String = ""
    @State private var expandedIds: Set<UUID> = []

    @Environment(\.modelContext) private var modelContext

    enum DateRange: String, CaseIterable {
        case today = "TODAY"
        case yesterday = "YESTERDAY"
        case week = "THIS WEEK"
        case all = "ALL"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(MW.border).frame(height: MW.hairline)
            searchBar
            Rectangle().fill(MW.border).frame(height: MW.hairline)
            filterBar
            Rectangle().fill(MW.border).frame(height: MW.hairline)

            if filtered.isEmpty {
                emptyState
            } else {
                observationList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("SCREEN")
                .font(MW.monoLg)
                .foregroundStyle(MW.textPrimary)
                .tracking(2)
            Spacer()
            Text("\(observations.count) observations")
                .font(MW.monoSm)
                .foregroundStyle(MW.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(MW.textMuted)
            TextField("Search activity, apps, topics…", text: $searchQuery)
                .font(MW.mono)
                .foregroundStyle(MW.textPrimary)
                .textFieldStyle(.plain)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(MW.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Filter chips

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(DateRange.allCases, id: \.self) { r in
                let isActive = selectedRange == r
                Text(r.rawValue)
                    .font(MW.label)
                    .tracking(0.8)
                    .foregroundStyle(isActive ? MW.textPrimary : MW.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(isActive ? MW.elevated : .clear)
                    .overlay(Rectangle().stroke(isActive ? MW.borderLight : MW.border, lineWidth: MW.hairline))
                    .onTapGesture { selectedRange = r }
            }
            Spacer()
            Text("\(filtered.count) shown")
                .font(MW.monoSm)
                .foregroundStyle(MW.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Filtering & grouping

    private var filtered: [ScreenObservation] {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let rangeStart: Date
        switch selectedRange {
        case .today:     rangeStart = today
        case .yesterday: rangeStart = cal.date(byAdding: .day, value: -1, to: today)!
        case .week:      rangeStart = cal.date(byAdding: .day, value: -7, to: today)!
        case .all:       rangeStart = .distantPast
        }
        let rangeEnd: Date? = selectedRange == .yesterday ? today : nil
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return observations.filter { obs in
            if obs.startedAt < rangeStart { return false }
            if let end = rangeEnd, obs.startedAt >= end { return false }
            if !query.isEmpty {
                let hay = "\(obs.appName) \(obs.contextSummary) \(obs.currentActivity) \(obs.windowTitle ?? "") \(obs.sourceCategory ?? "")".lowercased()
                if !hay.contains(query) { return false }
            }
            return true
        }
    }

    private var grouped: [(label: String, items: [ScreenObservation])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        var ordered: [String] = []
        var buckets: [String: [ScreenObservation]] = [:]

        let df: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MMM d, yyyy"
            return f
        }()

        for obs in filtered {
            let day = cal.startOfDay(for: obs.startedAt)
            let label: String
            if day == today { label = "TODAY" }
            else if day == yesterday { label = "YESTERDAY" }
            else { label = df.string(from: obs.startedAt).uppercased() }
            if buckets[label] == nil {
                buckets[label] = []
                ordered.append(label)
            }
            buckets[label]?.append(obs)
        }
        return ordered.map { ($0, buckets[$0] ?? []) }
    }

    // MARK: - List

    private var observationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(grouped, id: \.label) { group in
                    sectionHeader(group.label)
                    ForEach(group.items) { obs in
                        observationRow(obs)
                            .padding(.vertical, 4)
                    }
                }
            }
            .padding(16)
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(MW.label).tracking(1.0)
            .foregroundStyle(MW.textMuted)
            .padding(.top, 12).padding(.bottom, 6)
    }

    @ViewBuilder
    private func observationRow(_ obs: ScreenObservation) -> some View {
        let isExpanded = expandedIds.contains(obs.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 2) {
                    Text(obs.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    let duration = max(1, Int(obs.endedAt.timeIntervalSince(obs.startedAt) / 60))
                    Text("\(duration)m")
                        .font(MW.label).tracking(0.4).foregroundStyle(MW.textMuted)
                }
                .frame(width: 50, alignment: .leading)

                Image(systemName: obs.hasTask ? "checklist" : iconFor(category: obs.sourceCategory))
                    .font(.system(size: 13))
                    .foregroundStyle(MW.textSecondary)
                    .frame(width: 20, height: 20, alignment: .center)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(obs.appName)
                            .font(MW.mono).foregroundStyle(MW.textPrimary)
                        if let title = obs.windowTitle, !title.isEmpty {
                            Text("· \(title)")
                                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let focus = obs.focusStatus { focusChip(focus) }
                        if let cat = obs.sourceCategory, cat != "other" { categoryChip(cat) }
                    }
                    Text(obs.contextSummary)
                        .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                        .lineLimit(isExpanded ? nil : 2)
                    if isExpanded {
                        Text(obs.currentActivity)
                            .font(MW.label).tracking(0.5)
                            .foregroundStyle(MW.textMuted)
                            .padding(.top, 2)
                    }
                }
            }
            if isExpanded { expandedDetails(obs).padding(.leading, 80) }
        }
        .padding(12)
        .background(MW.surface)
        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded { expandedIds.remove(obs.id) } else { expandedIds.insert(obs.id) }
        }
    }

    @ViewBuilder
    private func expandedDetails(_ obs: ScreenObservation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if obs.hasTask, let taskTitle = obs.taskTitle {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "flag").font(.system(size: 10)).foregroundStyle(MW.textMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DETECTED TASK").font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                        Text(taskTitle).font(MW.monoSm).foregroundStyle(MW.textSecondary)
                    }
                }
            }
            linkedTasks(obs)
            linkedMemories(obs)
            linkedOCR(obs)
        }
    }

    @ViewBuilder
    private func linkedTasks(_ obs: ScreenObservation) -> some View {
        let tasks = fetchTasks(screenContextId: obs.screenContextId)
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("EXTRACTED TASKS · \(tasks.count)")
                    .font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                ForEach(tasks) { task in
                    HStack(spacing: 6) {
                        Image(systemName: task.completed ? "checkmark.square.fill" : "square")
                            .font(.system(size: 10)).foregroundStyle(MW.textMuted)
                        Text(task.taskDescription)
                            .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                            .strikethrough(task.completed)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func linkedMemories(_ obs: ScreenObservation) -> some View {
        let mems = fetchMemories(screenContextId: obs.screenContextId)
        if !mems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("EXTRACTED MEMORIES · \(mems.count)")
                    .font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                ForEach(mems) { mem in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "brain").font(.system(size: 9)).foregroundStyle(MW.textMuted)
                        Text(mem.content).font(MW.monoSm).foregroundStyle(MW.textSecondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func linkedOCR(_ obs: ScreenObservation) -> some View {
        if let ctx = fetchScreenContext(id: obs.screenContextId), !ctx.ocrText.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("OCR SNAPSHOT").font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                Text(String(ctx.ocrText.prefix(600)))
                    .font(MW.monoSm).foregroundStyle(MW.textMuted.opacity(0.85))
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Fetch helpers

    private func fetchTasks(screenContextId: UUID?) -> [TaskItem] {
        guard let sid = screenContextId else { return [] }
        var desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.screenContextId == sid && !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        desc.fetchLimit = 20
        return (try? modelContext.fetch(desc)) ?? []
    }

    private func fetchMemories(screenContextId: UUID?) -> [UserMemory] {
        guard let sid = screenContextId else { return [] }
        var desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { $0.screenContextId == sid && !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        desc.fetchLimit = 20
        return (try? modelContext.fetch(desc)) ?? []
    }

    private func fetchScreenContext(id: UUID?) -> ScreenContext? {
        guard let sid = id else { return nil }
        var desc = FetchDescriptor<ScreenContext>(predicate: #Predicate { $0.id == sid })
        desc.fetchLimit = 1
        return try? modelContext.fetch(desc).first
    }

    // MARK: - Chips + icon helpers

    private func focusChip(_ focus: String) -> some View {
        Text(focus.uppercased())
            .font(MW.label).tracking(0.5)
            .foregroundStyle(focus == "focused" ? MW.textSecondary : MW.textMuted)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
    }

    private func categoryChip(_ category: String) -> some View {
        Text(category.uppercased())
            .font(MW.label).tracking(0.5)
            .foregroundStyle(MW.textMuted)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(MW.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    /// Minimal category → SF Symbol mapping (monochrome).
    private func iconFor(category: String?) -> String {
        switch category ?? "" {
        case "work", "business": return "briefcase"
        case "technology": return "laptopcomputer"
        case "finance", "economics": return "dollarsign.circle"
        case "health": return "heart"
        case "education", "literature", "history": return "book"
        case "entertainment", "music": return "play.circle"
        case "social", "family": return "person.2"
        case "travel": return "airplane"
        case "sports": return "figure.run"
        case "design", "architecture": return "paintbrush"
        case "science", "psychology": return "atom"
        case "news": return "newspaper"
        case "environment": return "leaf"
        case "real": return "house"
        case "weather": return "cloud.sun"
        case "inspiration", "philosophy", "spiritual": return "sparkles"
        default: return "circle"
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(MW.textMuted)
            Text("No screen activity yet").font(MW.monoLg).foregroundStyle(MW.textSecondary)
            Text("Rewind analyses your screen hourly. Change your apps / read / work for an hour and observations appear here.")
                .font(MW.mono).foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
