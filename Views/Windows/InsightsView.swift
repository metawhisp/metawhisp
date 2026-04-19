import SwiftData
import SwiftUI

/// Displays tasks (action items), meeting recordings, and screen context.
/// spec://BACKLOG#B1
struct InsightsView: View {
    @Query(filter: #Predicate<TaskItem> { !$0.isDismissed },
           sort: \TaskItem.createdAt, order: .reverse)
    private var tasks: [TaskItem]
    @Query(filter: #Predicate<HistoryItem> { $0.source == "meeting" },
           sort: \HistoryItem.createdAt, order: .reverse)
    private var meetingItems: [HistoryItem]
    @Query(sort: \ScreenContext.timestamp, order: .reverse) private var screenContexts: [ScreenContext]
    @ObservedObject private var settings = AppSettings.shared

    @State private var selectedSection: Section = .tasks
    @State private var isExtracting = false
    @State private var extractionResult: String?

    enum Section: String, CaseIterable {
        case tasks = "Tasks"
        case meetings = "Meetings"
        case screen = "Screen Context"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("INSIGHTS")
                        .font(MW.monoLg)
                        .foregroundStyle(MW.textPrimary)
                        .tracking(2)
                    Spacer()
                    // "Extract Now" — runs TaskExtractor on the most recent transcript.
                    if selectedSection == .tasks && settings.tasksEnabled {
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
                    // Section picker
                    Picker("", selection: $selectedSection) {
                        ForEach(Section.allCases, id: \.self) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }
                if let result = extractionResult {
                    Text(result)
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textSecondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Rectangle().fill(MW.border).frame(height: MW.hairline)

            // Content
            switch selectedSection {
            case .tasks:
                tasksSection
            case .meetings:
                meetingsSection
            case .screen:
                screenSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Actions

    private func extractTasksNow() {
        NSLog("[InsightsView] EXTRACT NOW (tasks) clicked")
        isExtracting = true
        extractionResult = nil
        let beforeCount = tasks.count
        Task { @MainActor in
            guard let appDelegate = AppDelegate.shared else {
                extractionResult = "TaskExtractor not available (SwiftUI context issue)"
                isExtracting = false
                return
            }
            await appDelegate.taskExtractor.extractOnce()
            try? await Task.sleep(for: .milliseconds(500))
            let delta = tasks.count - beforeCount
            extractionResult = delta > 0
                ? "Added \(delta) new \(delta == 1 ? "task" : "tasks")"
                : "No new tasks (nothing actionable in the last transcript)"
            isExtracting = false
        }
    }

    // MARK: - Tasks Section

    @Environment(\.modelContext) private var modelContext

    private var tasksSection: some View {
        Group {
            if !settings.tasksEnabled {
                featureDisabledView(
                    icon: "checklist",
                    title: "Tasks are disabled",
                    subtitle: "Enable in Settings to auto-extract action items from your voice transcripts."
                )
            } else if tasks.isEmpty {
                emptyStateView(
                    icon: "checklist",
                    title: "No tasks yet",
                    subtitle: "Say \"Remind me to X\" or mention a deadline — MetaWhisp will capture it."
                )
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
    }

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
                Spacer()
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
            }
        }
        .padding(12)
        .background(MW.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(MW.border, lineWidth: MW.hairline)
        )
    }

    /// Relative label: "TODAY", "TOMORROW", "Apr 22", "OVERDUE".
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

    // MARK: - Meetings Section

    private var meetingsSection: some View {
        Group {
            if !settings.meetingRecordingEnabled {
                featureDisabledView(
                    icon: "video",
                    title: "Meeting recording is disabled",
                    subtitle: "Enable in Settings to record and transcribe Zoom, Meet, Teams calls locally."
                )
            } else {
                meetingHistoryView
            }
        }
    }

    @ViewBuilder
    private var meetingHistoryView: some View {
        if meetingItems.isEmpty {
            emptyStateView(
                icon: "video",
                title: "No meetings recorded yet",
                subtitle: "Start a call in Zoom, Meet, or Teams and click Record Meeting in the menu bar."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(meetingItems) { item in
                        MeetingCardView(item: item)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Screen Context Section

    private var screenSection: some View {
        Group {
            if !settings.screenContextEnabled {
                featureDisabledView(
                    icon: "rectangle.on.rectangle",
                    title: "Screen context is disabled",
                    subtitle: "Enable in Settings to let MetaWhisp understand your activity for better suggestions."
                )
            } else if screenContexts.isEmpty {
                emptyStateView(
                    icon: "rectangle.on.rectangle",
                    title: "Screen context active",
                    subtitle: "MetaWhisp is observing window changes. Data stays on your Mac."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(screenContexts) { ctx in
                            screenContextCard(ctx)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func screenContextCard(_ ctx: ScreenContext) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(ctx.appName.uppercased())
                    .font(MW.label).tracking(0.6)
                    .foregroundStyle(MW.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(MW.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(ctx.windowTitle)
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .lineLimit(1)
                Spacer()
                Text(ctx.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
            if !ctx.ocrText.isEmpty {
                Text(String(ctx.ocrText.prefix(200)))
                    .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .background(MW.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(MW.border, lineWidth: MW.hairline)
        )
    }

    // MARK: - Shared Components

    private func featureDisabledView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(MW.textMuted)
            Text(title)
                .font(MW.monoLg)
                .foregroundStyle(MW.textSecondary)
            Text(subtitle)
                .font(MW.mono)
                .foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Open Settings") {
                NotificationCenter.default.post(name: .switchMainTab, object: MainWindowView.SidebarTab.settings)
            }
            .font(MW.mono)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func emptyStateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(MW.textMuted)
            Text(title)
                .font(MW.monoLg)
                .foregroundStyle(MW.textSecondary)
            Text(subtitle)
                .font(MW.mono)
                .foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Meeting Card

/// Meeting transcript card with Copy / Export / Delete actions (revealed on hover).
/// Implements spec://audio/FEAT-0001#ui-contract.copy-export
private struct MeetingCardView: View {
    let item: HistoryItem
    @Environment(\.modelContext) private var modelContext

    @State private var isHovered = false
    @State private var showCopiedFeedback = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row — icon, date, meta
            HStack {
                Image(systemName: "video").font(.system(size: 10)).foregroundStyle(MW.textMuted)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                Spacer()
                Text(String(format: "%.0f min", item.audioDuration / 60))
                    .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                Text("\(item.wordCount) words")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }

            // Transcript (clipped to 6 lines)
            Text(item.displayText)
                .font(MW.mono)
                .foregroundStyle(MW.textPrimary)
                .lineLimit(6)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Actions row — revealed on hover
            if isHovered || showCopiedFeedback {
                HStack(spacing: 8) {
                    Spacer()
                    if showCopiedFeedback {
                        Text("COPIED")
                            .font(MW.label).tracking(0.6)
                            .foregroundStyle(MW.idle)
                    } else {
                        actionButton(label: "COPY", icon: "doc.on.doc") {
                            copyToClipboard()
                        }
                        actionButton(label: "EXPORT", icon: "square.and.arrow.up") {
                            exportToFile()
                        }
                        actionButton(label: "DELETE", icon: "trash", destructive: true) {
                            showDeleteConfirmation = true
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(MW.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(MW.border, lineWidth: MW.hairline)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .confirmationDialog(
            "Delete this meeting transcript?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteItem() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Action Button

    private func actionButton(label: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .medium))
                Text(label).font(MW.label).tracking(0.6)
            }
            .foregroundStyle(destructive ? Color.red.opacity(0.8) : MW.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .overlay(Rectangle().stroke(destructive ? Color.red.opacity(0.3) : MW.border, lineWidth: MW.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.displayText, forType: .string)
        showCopiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            showCopiedFeedback = false
        }
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        // Default filename: Meeting-YYYY-MM-DD-HHMM.txt
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        panel.nameFieldStringValue = "Meeting-\(formatter.string(from: item.createdAt)).txt"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let content = formatExportContent()
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func formatExportContent() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let durationMin = Int(item.audioDuration / 60)
        let model = item.modelName ?? "unknown"

        return """
        Meeting — \(dateFormatter.string(from: item.createdAt))
        Duration: \(durationMin) min
        Model: \(model)

        \(item.displayText)
        """
    }

    private func deleteItem() {
        modelContext.delete(item)
        try? modelContext.save()
    }
}
