import SwiftData
import SwiftUI

/// Tasks — standalone top-level tab. Promoted from Insights → Tasks section.
/// Shows all non-dismissed TaskItem records with checkbox + due badge + dismiss button.
/// spec://BACKLOG#sidebar-reorg + B1
struct TasksView: View {
    @Query(
        filter: #Predicate<TaskItem> { !$0.isDismissed },
        sort: \TaskItem.createdAt,
        order: .reverse
    )
    private var tasks: [TaskItem]

    @ObservedObject private var settings = AppSettings.shared
    @State private var isExtracting = false
    @State private var extractionResult: String?

    @Environment(\.modelContext) private var modelContext

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
                Text("TASKS")
                    .font(MW.monoLg)
                    .foregroundStyle(MW.textPrimary)
                    .tracking(2)
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
                        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isExtracting)
                }
                Text("\(tasks.count) active")
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
        } else if tasks.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasks) { item in
                        taskCard(item)
                    }
                }
                .padding(16)
            }
        }
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
        .background(MW.surface)
        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
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
