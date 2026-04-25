import SwiftData
import SwiftUI

/// Projects — auto-detected clusters of conversations + memories + tasks tagged
/// with the same `Conversation.primaryProject`. Powered by `ProjectAggregator`
/// which canonicalizes raw LLM project labels through `ProjectAlias` rows.
///
/// Layout: card grid of projects (sorted by lastActivity desc). Click → detail
/// view with timeline + linked items.
///
/// spec://iterations/ITER-014-project-clustering
struct ProjectsView: View {
    @EnvironmentObject private var projectAggregator: ProjectAggregator

    @State private var summaries: [ProjectSummary] = []
    @State private var selectedProject: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(MW.border).frame(height: MW.hairline)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Projects")
                .font(MW.monoTitle)
                .foregroundStyle(MW.textPrimary)
            Spacer()
            Button {
                Task { await refresh() }
            } label: {
                HStack(spacing: 4) {
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    }
                    Text("REFRESH").font(MW.label).tracking(0.6)
                }
                .foregroundStyle(MW.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            Text("\(summaries.count) project\(summaries.count == 1 ? "" : "s")")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let projectName = selectedProject {
            ProjectDetailView(canonicalName: projectName) {
                // ITER-021.1 — onBack callback. After detail view returns
                // (whether by BACK or after DELETE), refresh the list so a
                // deleted project disappears from the grid immediately.
                selectedProject = nil
                Task { await refresh() }
            }
        } else if summaries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(summaries) { project in
                        projectCard(project)
                            .onTapGesture { selectedProject = project.canonicalName }
                    }
                }
                .padding(16)
            }
        }
    }

    private func projectCard(_ p: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.canonicalName)
                    .font(MW.mono.weight(.semibold))
                    .foregroundStyle(MW.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("\(p.conversationCount)")
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
            }
            HStack(spacing: 10) {
                statChip(label: "tasks", value: "\(p.pendingTaskCount)")
                statChip(label: "done", value: "\(p.completedTaskCount)")
                statChip(label: "memories", value: "\(p.memoryCount)")
            }
            HStack(spacing: 6) {
                Text("Last:")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                Text(relativeDate(p.lastActivity))
                    .font(MW.monoSm).foregroundStyle(MW.textSecondary)
            }
            if !p.members.isEmpty {
                HStack(spacing: 4) {
                    Text("With:")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    Text(p.members.sorted().prefix(4).joined(separator: ", "))
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(MW.sp12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private func statChip(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(value).font(MW.mono).foregroundStyle(MW.textPrimary)
            Text(label).font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 28))
                .foregroundStyle(MW.textMuted)
            Text("No projects detected yet")
                .font(MW.mono).foregroundStyle(MW.textSecondary)
            Text("MetaWhisp tags each finished meeting with a primary project. Once a few meetings close, clusters appear here.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Refresh

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        // listProjects is sync but cheap — wrap in Task only for UI consistency.
        summaries = projectAggregator.listProjects()
    }
}

// MARK: - Detail view

private struct ProjectDetailView: View {
    let canonicalName: String
    let onBack: () -> Void

    @EnvironmentObject private var projectAggregator: ProjectAggregator
    @State private var details: ProjectDetails?
    @State private var showDeleteConfirm = false
    @State private var deleteResultMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11))
                        Text("BACK").font(MW.label).tracking(0.6)
                    }
                    .foregroundStyle(MW.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                Text(canonicalName)
                    .font(MW.monoTitle)
                    .foregroundStyle(MW.textPrimary)
                Spacer()
                // ITER-021.1 — DELETE button. Removes the cluster + unlinks
                // conversations (their transcripts stay; just the project tag clears).
                Button {
                    showDeleteConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash").font(.system(size: 10))
                        Text("DELETE").font(MW.label).tracking(0.6)
                    }
                    .foregroundStyle(.red.opacity(0.85))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(Color.red.opacity(0.4), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Rectangle().fill(MW.border).frame(height: MW.hairline)

            if let d = details {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section("CONVERSATIONS") {
                            if d.conversations.isEmpty {
                                Text("(none)").font(MW.monoSm).foregroundStyle(MW.textMuted)
                            } else {
                                ForEach(d.conversations.prefix(20)) { conv in
                                    convRow(conv)
                                }
                            }
                        }
                        section("PENDING TASKS") {
                            let pending = d.tasks.filter { !$0.completed && $0.effectiveStatus == "committed" }
                            if pending.isEmpty {
                                Text("(none)").font(MW.monoSm).foregroundStyle(MW.textMuted)
                            } else {
                                ForEach(pending) { t in
                                    taskRow(t)
                                }
                            }
                        }
                        section("KEY MEMORIES") {
                            if d.memories.isEmpty {
                                Text("(none)").font(MW.monoSm).foregroundStyle(MW.textMuted)
                            } else {
                                ForEach(d.memories.prefix(20)) { m in
                                    memoryRow(m)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            details = projectAggregator.details(for: canonicalName)
        }
        .confirmationDialog(
            "Delete project \"\(canonicalName)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete project", role: .destructive) {
                let unlinked = projectAggregator.deleteProject(canonicalName: canonicalName)
                deleteResultMessage = unlinked > 0
                    ? "Removed. \(unlinked) conversation\(unlinked == 1 ? "" : "s") now uncategorized."
                    : "Removed."
                // Pop back to list — the project no longer exists.
                onBack()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let convCount = details?.conversations.count ?? 0
            let taskCount = details?.tasks.count ?? 0
            let memCount = details?.memories.count ?? 0
            Text("This removes the cluster from the Projects view. \(convCount) conversation\(convCount == 1 ? "" : "s") will become uncategorized. Linked tasks (\(taskCount)) and memories (\(memCount)) are NOT affected.")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(MW.label).tracking(0.6)
                .foregroundStyle(MW.textMuted)
            content()
        }
    }

    private func convRow(_ c: Conversation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: c.emoji ?? "bubble.left")
                .font(.system(size: 12)).foregroundStyle(MW.textMuted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title ?? "Untitled")
                    .font(MW.mono).foregroundStyle(MW.textPrimary)
                    .lineLimit(1)
                if let ov = c.overview, !ov.isEmpty {
                    Text(ov).font(MW.monoSm).foregroundStyle(MW.textMuted).lineLimit(2)
                }
            }
            Spacer()
            Text(c.startedAt.formatted(date: .abbreviated, time: .omitted))
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
        .padding(.vertical, 4)
    }

    private func taskRow(_ t: TaskItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle").font(.system(size: 11)).foregroundStyle(MW.textMuted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.taskDescription).font(MW.mono).foregroundStyle(MW.textPrimary)
                if let assignee = t.assignee, !assignee.isEmpty {
                    Text("waiting on \(assignee)")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func memoryRow(_ m: UserMemory) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "brain").font(.system(size: 11)).foregroundStyle(MW.textMuted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                if let h = m.headline, !h.isEmpty {
                    Text(h).font(MW.mono).foregroundStyle(MW.textPrimary).lineLimit(1)
                }
                Text(m.content).font(MW.monoSm).foregroundStyle(MW.textSecondary).lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
