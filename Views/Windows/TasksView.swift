import SwiftData
import SwiftUI

/// Tasks — standalone top-level tab. Promoted from Insights → Tasks section.
/// Shows all non-dismissed TaskItem records with checkbox + due badge + dismiss button.
/// spec://BACKLOG#sidebar-reorg + B1
struct TasksView: View {
    /// All non-dismissed tasks — we split by `status` in-memory instead of two
    /// @Queries so the counts stay consistent with a single sort order.
    @Query(
        filter: #Predicate<TaskItem> { !$0.isDismissed && $0.status != "dismissed" },
        sort: \TaskItem.createdAt,
        order: .reverse
    )
    private var tasks: [TaskItem]

    @ObservedObject private var settings = AppSettings.shared
    @State private var isExtracting = false
    @State private var extractionResult: String?
    @State private var candidatesExpanded = true

    @Environment(\.modelContext) private var modelContext

    /// Main list = status=="committed" (explicit) or nil (legacy rows pre-migration).
    /// Voice / calendar / user-promoted.
    private var committedTasks: [TaskItem] { tasks.filter { $0.effectiveStatus == "committed" } }
    /// REVIEW bin = status=="staged". Screen-inferred candidates awaiting user decision.
    private var stagedTasks: [TaskItem] { tasks.filter { $0.effectiveStatus == "staged" } }

    /// ITER-013 — split committed list by ownership.
    /// MY tasks: assignee == nil (or empty whitespace). Owner is the user.
    private var myTasks: [TaskItem] { committedTasks.filter { $0.isMyTask } }
    /// Waiting-on tasks grouped by assignee name (preserve insertion order from
    /// `committedTasks` so the most-recently-created group sorts to the top).
    /// Returns array of (name, tasks) pairs sorted by group size desc, then name asc.
    private var waitingOnGroups: [(name: String, items: [TaskItem])] {
        var groups: [String: [TaskItem]] = [:]
        for t in committedTasks where !t.isMyTask {
            // `assignee` is non-nil here by isMyTask false; trim defensively.
            let name = (t.assignee ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            groups[name, default: []].append(t)
        }
        // Bigger waiting-on groups likely matter more (someone owes you a lot →
        // surface first). Tiebreak alphabetically for stable UI.
        return groups
            .map { (name: $0.key, items: $0.value) }
            .sorted { a, b in
                if a.items.count != b.items.count { return a.items.count > b.items.count }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(MW.border).frame(height: MW.hairline)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tasks")
                    .font(MW.monoTitle)
                    .foregroundStyle(MW.textPrimary)
                Spacer()
                if settings.tasksEnabled {
                    Button(action: extractTasksNow) {
                        HStack(spacing: 4) {
                            if isExtracting {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "sparkles").font(.system(size: 10))
                            }
                            Text(isExtracting ? "EXTRACTING…" : "EXTRACT NOW")
                                .font(MW.label).tracking(0.6)
                        }
                        .foregroundStyle(MW.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isExtracting)
                }
                Text("\(committedTasks.count) active")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
            if let result = extractionResult {
                Text(result)
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textSecondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !settings.tasksEnabled {
            featureDisabled
        } else if committedTasks.isEmpty && stagedTasks.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    // Staged candidates bin — rendered first when non-empty so user sees
                    // them on open. Collapsible to stay out of the way.
                    if !stagedTasks.isEmpty {
                        stagedSection
                    }
                    // ITER-013 — committed tasks split into MY / WAITING-ON sections.
                    // Order: MY first (action surface), WAITING-ON below grouped by person.
                    if !myTasks.isEmpty {
                        ownershipSectionHeader(label: "MY TASKS", count: myTasks.count)
                        ForEach(myTasks) { item in
                            taskCard(item)
                        }
                    }
                    ForEach(waitingOnGroups, id: \.name) { group in
                        ownershipSectionHeader(label: "WAITING ON \(group.name.uppercased())",
                                               count: group.items.count)
                        ForEach(group.items) { item in
                            taskCard(item)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    /// ITER-013 — small header used to label MY / WAITING-ON sections inside the
    /// committed list. Visual weight kept low (uppercase mono micro) so groupings
    /// stay scan-able without dominating the cards.
    private func ownershipSectionHeader(label: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(MW.label).tracking(0.6)
                .foregroundStyle(MW.textMuted)
            Text("\(count)")
                .font(MW.label).tracking(0.6)
                .foregroundStyle(MW.textMuted)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(MW.border.opacity(0.4))
                )
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    // MARK: - Staged (review candidates) section

    private var stagedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { candidatesExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: candidatesExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(MW.textMuted)
                    Text("REVIEW CANDIDATES")
                        .font(MW.label).tracking(0.8)
                        .foregroundStyle(MW.textSecondary)
                    Text("\(stagedTasks.count)")
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textMuted)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                    Spacer()
                    Text("auto-extracted · ✓ done · + save for later · ✗ skip")
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textMuted)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if candidatesExpanded {
                ForEach(stagedTasks) { item in
                    candidateCard(item)
                }
                Rectangle().fill(MW.border).frame(height: MW.hairline)
                    .padding(.vertical, 4)
            }
        }
    }

    private func candidateCard(_ item: TaskItem) -> some View {
        // ITER-021.2 — 3-action row redesign (user feedback 2026-04-25).
        // Old design: ✓ promote → still need a SECOND tap in committed list to mark done.
        // Two clicks for what most users intuitively read as "done in one tap".
        // New default: ✓ MARKS DONE in a single click (most common case for screen-
        // extracted tasks — they reflect work the user has ALREADY done or is doing).
        // For the "save for later" case (less common), a + button promotes to MY TASKS.
        // ✗ unchanged — dismiss / not relevant.
        HStack(spacing: 6) {
            // ✓ DONE — one-click completion (status=committed, completed=true,
            // completedAt=now). Counts toward Shipped/Done stats. Disappears
            // from staged list. The "right" thing for the "I already did this" case.
            Button {
                item.status = "committed"
                item.completed = true
                item.completedAt = Date()
                item.updatedAt = Date()
                try? modelContext.save()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MW.textPrimary)
                    .frame(width: 22, height: 22)
                    .overlay(Rectangle().stroke(MW.textMuted, lineWidth: MW.hairline))
            }
            .buttonStyle(.plain)
            .help("Mark done — one tap")

            // + SAVE FOR LATER — promote to MY TASKS active (old ✓ behavior).
            // Use case: screen detected something user wants to do later, not yet.
            Button {
                item.status = "committed"
                item.updatedAt = Date()
                try? modelContext.save()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MW.textSecondary)
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Save for later — adds to MY TASKS")

            // ✗ DISMISS — hide, kept for dedup history.
            Button {
                item.status = "dismissed"
                item.isDismissed = true
                item.updatedAt = Date()
                try? modelContext.save()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MW.textMuted)
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Not relevant — dismiss")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.taskDescription)
                    .font(MW.mono)
                    .foregroundStyle(MW.textSecondary)
                HStack(spacing: 6) {
                    if let app = item.sourceApp {
                        Text(app).font(MW.monoSm).foregroundStyle(MW.textMuted)
                    }
                    if let due = item.dueAt {
                        Text(dueLabel(due))
                            .font(MW.label).tracking(0.5)
                            .foregroundStyle(dueColor(due))
                    }
                    Spacer()
                    Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(MW.bg)
        .overlay(Rectangle().stroke(MW.border.opacity(0.5), lineWidth: MW.hairline))
    }

    // MARK: - Task card

    private func taskCard(_ item: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    item.completed.toggle()
                    item.completedAt = item.completed ? Date() : nil
                    item.updatedAt = Date()
                    try? modelContext.save()
                } label: {
                    Image(systemName: item.completed ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(item.completed ? MW.textSecondary : MW.textMuted)
                }
                .buttonStyle(.plain)

                Text(item.taskDescription)
                    .font(MW.mono)
                    .foregroundStyle(item.completed ? MW.textMuted : MW.textPrimary)
                    .strikethrough(item.completed)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let due = item.dueAt {
                    Text(dueLabel(due))
                        .font(MW.label).tracking(0.5)
                        .foregroundStyle(dueColor(due))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Rectangle().stroke(dueColor(due).opacity(0.4), lineWidth: MW.hairline))
                }

                Button {
                    item.isDismissed = true
                    item.updatedAt = Date()
                    try? modelContext.save()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(MW.textMuted)
                }
                .buttonStyle(.plain)
            }

            HStack {
                if let app = item.sourceApp {
                    Text(app).font(MW.monoSm).foregroundStyle(MW.textMuted)
                }
                Spacer()
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
            }
        }
        .padding(12)
        .mwCard(radius: MW.rSmall, elevation: .flat)
    }

    private func dueLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if date < Date() { return "OVERDUE" }
        if cal.isDateInToday(date) { return "TODAY" }
        if cal.isDateInTomorrow(date) { return "TOMORROW" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func dueColor(_ date: Date) -> Color {
        if date < Date() { return .red.opacity(0.85) }
        if Calendar.current.isDateInToday(date) { return .orange }
        return MW.textSecondary
    }

    // MARK: - Empty / disabled

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 32))
                .foregroundStyle(MW.textMuted)
            Text("No tasks yet")
                .font(MW.monoLg).foregroundStyle(MW.textSecondary)
            Text("Say \"Напомни мне X\" or mention a deadline — MetaWhisp will capture it. Tasks also auto-appear from screen activity (Library → Screen).")
                .font(MW.mono).foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var featureDisabled: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 32)).foregroundStyle(MW.textMuted)
            Text("Tasks are disabled")
                .font(MW.monoLg).foregroundStyle(MW.textSecondary)
            Text("Enable in Settings to auto-extract action items from your voice and screen.")
                .font(MW.mono).foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Open Settings") {
                NotificationCenter.default.post(name: .switchMainTab, object: MainWindowView.SidebarTab.settings)
            }
            .font(MW.mono)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func extractTasksNow() {
        isExtracting = true
        extractionResult = nil
        let before = tasks.count
        Task { @MainActor in
            guard let appDelegate = AppDelegate.shared else {
                extractionResult = "TaskExtractor not available"
                isExtracting = false
                return
            }
            await appDelegate.taskExtractor.extractOnce()
            try? await Task.sleep(for: .milliseconds(500))
            let delta = tasks.count - before
            extractionResult = delta > 0
                ? "Added \(delta) new \(delta == 1 ? "task" : "tasks")"
                : "No new tasks (nothing actionable in the last transcript)"
            isExtracting = false
        }
    }
}
