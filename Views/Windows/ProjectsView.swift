import Combine
import MetaWhispTrackerKit
import SwiftData
import SwiftUI

/// Projects — every project the user has (FEAT-0006 §9b, owner 2026-11-26: projects and tasks are one). Workspace
/// opens here. A card per project, newest activity first, and a last empty card "+ Add project". A click opens the
/// project's page: its Tasks (the same board and list as the Tasks tab, that project only), Conversations and
/// Memories.
///
/// spec://iterations/ITER-014-project-clustering, spec://tracker/FEAT-0006#one
struct ProjectsView: View {
    @EnvironmentObject private var projectAggregator: ProjectAggregator

    @State private var summaries: [ProjectSummary] = []
    /// Projects the user put away (Q4): the "Archived · N" card lists them.
    @State private var archived: [ProjectSummary] = []
    @State private var archiveOpen = false
    @State private var openProject: ProjectSummary?
    /// The newest change to a task and to a conversation: the grid redraws when either moves, while it is on screen
    /// (review 2026-11-27, #5). One row each, not the tables.
    @Query(Self.newestTaskQuery) private var newestTask: [TaskItem]
    /// The tracker's writes (a task put in a project): made once, and without the current value, so subscribing
    /// never refreshes by itself — a publisher rebuilt on every render looped (found 2026-11-27 in the width test).
    @State private var trackerChanges: AnyPublisher<Void, Never> =
        TrackerService.shared?.$revision.dropFirst().map { _ in () }.eraseToAnyPublisher()
            ?? Empty().eraseToAnyPublisher()
    @Query(Self.newestConversationQuery) private var newestConversation: [Conversation]
    /// Memories are counted on the cards and listed on a project's page.
    @Query(Self.newestMemoryQuery) private var newestMemory: [UserMemory]
    /// Counts the grid's refreshes: an open project's page reloads with each, so a call or memory that lands in it
    /// while it is open shows (Codex review P2-13: it loaded once).
    @State private var changes = 0
    @State private var newProjectOpen = false
    @State private var newProjectName = ""
    @State private var problem: String?

    var body: some View {
        Group {
            if let project = openProject {
                ProjectPage(summary: project, changes: changes) {
                    openProject = nil
                    refresh()
                }
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { refresh() }
        .onChange(of: newestTask.first?.updatedAt) { _, _ in refresh() }
        .onChange(of: newestConversation.first?.updatedAt) { _, _ in refresh() }
        .onChange(of: newestMemory.first?.updatedAt) { _, _ in refresh() }
        .onReceive(trackerChanges) { refresh() }
        .alert("New project", isPresented: $newProjectOpen) {
            TextField("Name", text: $newProjectName)
            Button("Create") { createProject() }
            Button("Cancel", role: .cancel) { newProjectName = "" }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(MW.border).frame(height: MW.hairline)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                    ForEach(summaries) { project in
                        projectCard(project)
                            .contentShape(Rectangle())
                            .onTapGesture { openProject = project }
                    }
                    addProjectCard
                    if !archived.isEmpty { archivedCard }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Projects")
                .font(MW.monoTitle)
                .foregroundStyle(MW.textPrimary)
                .lineLimit(1)
                .fixedSize()
            Spacer()
            if let problem {
                Text(problem).font(MW.monoSm).foregroundStyle(MW.textSecondary).lineLimit(2)
            }
            Text("\(summaries.count) project\(summaries.count == 1 ? "" : "s")")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Cards

    /// One glance: name, open and done tasks, memories, how many conversations and how recent (UI review #8). A zero
    /// count is left out rather than shown as "0 tasks".
    private func projectCard(_ p: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.canonicalName)
                .font(MW.mono.weight(.semibold))
                .foregroundStyle(MW.textPrimary)
                .lineLimit(1)
            let counts = [(p.pendingTaskCount, "open"), (p.completedTaskCount, "done"),
                          (p.memoryCount, p.memoryCount == 1 ? "memory" : "memories")].filter { $0.0 > 0 }
            if counts.isEmpty {
                Text("No tasks yet").font(MW.monoSm).foregroundStyle(MW.textMuted)
            } else {
                HStack(spacing: 10) {
                    ForEach(counts, id: \.1) { statChip(label: $0.1, value: "\($0.0)") }
                }
            }
            Text("\(p.conversationCount) conversation\(p.conversationCount == 1 ? "" : "s") · \(relativeDate(p.lastActivity))")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .lineLimit(1)
        }
        .padding(MW.sp12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// P4 — the last card: empty, with "+ Add project".
    private var addProjectCard: some View {
        Button {
            newProjectOpen = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text("Add project").font(MW.mono)
            }
            .foregroundStyle(MW.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(
                RoundedRectangle(cornerRadius: MW.rMedium, style: .continuous)
                    .strokeBorder(MW.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Q4 — the last card when anything is archived: "Archived · N", a click lists them with Restore.
    private var archivedCard: some View {
        Button {
            archiveOpen = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "archivebox").font(.system(size: 11, weight: .medium))
                Text("Archived · \(archived.count)").font(MW.mono)
            }
            .foregroundStyle(MW.textMuted)
            .frame(maxWidth: .infinity, minHeight: 92)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $archiveOpen, onDismiss: refresh) {
            ArchivedProjectsSheet(projects: archived) { id in
                do {
                    try TrackerService.shared?.restoreProject(id)
                    problem = nil
                } catch let f as TrackerFailure {
                    problem = f.message
                } catch {
                    problem = error.localizedDescription
                }
                refresh()
            }
        }
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

    // MARK: - Changes

    private static var newestTaskQuery: FetchDescriptor<TaskItem> {
        var d = FetchDescriptor<TaskItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        d.fetchLimit = 1
        return d
    }

    private static var newestConversationQuery: FetchDescriptor<Conversation> {
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        d.fetchLimit = 1
        return d
    }

    private static var newestMemoryQuery: FetchDescriptor<UserMemory> {
        var d = FetchDescriptor<UserMemory>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        d.fetchLimit = 1
        return d
    }

    /// Every project the user has: since T4 nothing invents a project, so none is hidden as noise.
    private func refresh() {
        summaries = projectAggregator.listProjects(includeSingletons: true)
        archived = projectAggregator.listProjects(includeSingletons: true, archived: true)
        changes &+= 1
    }

    /// The user's own project, made real at once (a name already taken is that project).
    private func createProject() {
        let name = newProjectName
        newProjectName = ""
        guard let service = TrackerService.shared else {
            problem = "Projects are still starting; try again in a moment."
            return
        }
        do {
            try service.createProject(name: name)
            problem = nil
        } catch let f as TrackerFailure {
            problem = f.message
        } catch {
            problem = error.localizedDescription
        }
        refresh()
    }
}

/// One project: its name, then Tasks / Conversations / Memories. Renaming, its other spellings and Delete sit in the
/// "…" menu.
struct ProjectPage: View {
    let summary: ProjectSummary
    /// The grid's change count: a new value reloads the page.
    let changes: Int
    let onBack: () -> Void

    enum Part: String, CaseIterable {
        case tasks = "Tasks"
        case conversations = "Conversations"
        case memories = "Memories"
    }

    @EnvironmentObject private var projectAggregator: ProjectAggregator
    @State private var part: Part = .tasks
    @State private var details: ProjectDetails?
    @State private var name = ""
    @State private var renameOpen = false
    @State private var renameText = ""
    @State private var spellingsOpen = false
    @State private var showDeleteConfirm = false
    @State private var renameProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let renameProblem {
                Text(renameProblem).font(MW.monoSm).foregroundStyle(MW.textSecondary)
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
            HStack {
                SegmentStrip(options: Part.allCases, selection: $part) { $0.rawValue }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            Rectangle().fill(MW.border).frame(height: MW.hairline)
            switch part {
            case .tasks:
                if let id = summary.projectId {
                    TasksView(projectId: id)
                }
            case .conversations:
                rows(details?.conversations ?? [], empty: "No conversations in this project yet.") { convRow($0) }
            case .memories:
                rows(details?.memories ?? [], empty: "No memories from this project yet.") { memoryRow($0) }
            }
        }
        .task { reload() }
        .onChange(of: changes) { _, _ in reload() }
        .alert("Rename project", isPresented: $renameOpen) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let new = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !new.isEmpty, !projectAggregator.renameCanonical(currentCanonical: name, newName: new) {
                    renameProblem = "Another project is already called \(new)."
                } else {
                    renameProblem = nil
                }
                renameText = ""
                reload()
            }
            Button("Cancel", role: .cancel) { renameText = "" }
        }
        .sheet(isPresented: $spellingsOpen, onDismiss: reload) {
            ProjectSpellingsSheet(projectId: summary.projectId, canonicalName: name)
                .environmentObject(projectAggregator)
        }
        .confirmationDialog("Delete project \"\(name)\"?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete project", role: .destructive) {
                _ = projectAggregator.deleteProject(canonicalName: name)
                onBack()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let convCount = details?.conversations.count ?? 0
            let taskCount = details?.tasks.filter(\.isTask).count ?? 0   // FEAT-0005: tasks, not drafts
            Text("\(convCount) conversation\(convCount == 1 ? "" : "s") and \(taskCount) task\(taskCount == 1 ? "" : "s") "
                 + "stay in MetaWhisp; they leave this project.")
        }
    }

    /// The project's current name and contents, read by its id.
    private func reload() {
        name = summary.projectId.flatMap(projectAggregator.canonicalName(of:)) ?? summary.canonicalName
        details = projectAggregator.details(for: name)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11))
                    Text("Projects").font(.system(size: 11.5, weight: .medium)).lineLimit(1).fixedSize()
                }
                .foregroundStyle(MW.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(name.isEmpty ? summary.canonicalName : name)
                .font(MW.monoTitle)
                .foregroundStyle(MW.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                Button("Rename…") { renameText = name; renameOpen = true }
                Button("Other spellings…") { spellingsOpen = true }
                if let id = summary.projectId {
                    // Q4 — out of the grid and the pickers; its tasks stay in Tasks; Restore from "Archived · N".
                    Button("Archive project") {
                        do {
                            try TrackerService.shared?.archiveProject(id)
                            onBack()
                        } catch {
                            renameProblem = (error as? TrackerFailure)?.message ?? error.localizedDescription
                        }
                    }
                }
                Divider()
                Button("Delete project…", role: .destructive) { showDeleteConfirm = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MW.textSecondary)
                    .frame(width: 28, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func rows<Item: Identifiable, Row: View>(_ items: [Item], empty: String,
                                                    @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if details != nil && items.isEmpty {
                    Text(empty).font(MW.mono).foregroundStyle(MW.textMuted).padding(.vertical, 8)
                }
                ForEach(items) { row($0) }
            }
            .padding(16)
        }
    }

    private func convRow(_ c: Conversation) -> some View {
        Button {
            AppDelegate.shared?.openConversationInLibrary(id: c.id)
        } label: {
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
                Spacer(minLength: 8)
                Text(c.startedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

// MARK: - Archived projects

/// Q4 — the projects the user put away, each with Restore.
private struct ArchivedProjectsSheet: View {
    let projects: [ProjectSummary]
    let restore: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Archived projects").font(MW.monoLg)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(projects) { p in
                        HStack(spacing: 8) {
                            Text(p.canonicalName).font(MW.mono).foregroundStyle(MW.textPrimary).lineLimit(1)
                            Spacer()
                            if let id = p.projectId {
                                Button("Restore") {
                                    restore(id)
                                    if projects.count == 1 { dismiss() }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 400, maxWidth: 440)
    }
}

// MARK: - Other spellings

/// ITER-032.1 — the names a project goes by: one is its name, the others its spellings. A spelling can become the
/// name, or be split out as a project of its own (an accidental merge undone).
private struct ProjectSpellingsSheet: View {
    let projectId: UUID?
    let canonicalName: String

    @EnvironmentObject private var projectAggregator: ProjectAggregator
    @Environment(\.dismiss) private var dismiss
    @State private var aliases: [String] = []
    @State private var currentCanonical = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Other spellings").font(MW.monoLg)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(aliases, id: \.self) { variant in aliasRow(variant) }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360, maxWidth: 480)
        .onAppear(perform: reload)
    }

    /// The project's name and spellings now, by its id: a split never leaves this sheet on the split-off row.
    private func reload() {
        currentCanonical = projectId.flatMap(projectAggregator.canonicalName(of:)) ?? canonicalName
        aliases = projectAggregator.aliasVariants(for: currentCanonical)
    }

    /// ITER-032.1 — ALIASES row with two actions:
    ///  • "Make canonical" — promote this variant to be the cluster's
    ///    display name (when auto-merge picked the wrong winner).
    ///  • "Split out"      — extract this variant into its OWN ProjectAlias
    ///    row (when an accidental merge needs to be undone).
    /// The currently-canonical variant shows a non-clickable "canonical" tag.
    private func aliasRow(_ variant: String) -> some View {
        let isCurrentCanonical = variant.localizedCaseInsensitiveCompare(currentCanonical) == .orderedSame
        return HStack(spacing: 8) {
            Image(systemName: isCurrentCanonical ? "star.fill" : "star")
                .font(.system(size: 10))
                .foregroundStyle(isCurrentCanonical ? MW.accent : MW.textMuted)
                .frame(width: 16)
            Text(variant)
                .font(MW.mono)
                .foregroundStyle(isCurrentCanonical ? MW.textPrimary : MW.textSecondary)
            Spacer()
            if isCurrentCanonical {
                Text("Canonical")
                    .mwBadge()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            } else {
                Button("Make canonical") {
                    if projectAggregator.setCanonical(currentCanonical: currentCanonical, newCanonical: variant) {
                        reload()
                    }
                }
                .font(MW.label).foregroundStyle(MW.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                .buttonStyle(.plain)
            }
            Button("Split out") {
                if projectAggregator.splitAlias(currentCanonical: currentCanonical, variantToSplit: variant) {
                    // The split-off spelling is a project of its own now; this sheet stays on this project's row.
                    reload()
                }
            }
            .font(MW.label).foregroundStyle(.orange.opacity(0.85))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(Color.orange.opacity(0.4), lineWidth: 0.5))
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}
