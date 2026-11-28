import MetaWhispTrackerKit
import SwiftData
import SwiftUI

/// Tasks — standalone top-level tab. Promoted from Insights → Tasks section.
/// FEAT-0006 §9 (D2): every task the user has — agents' tasks with their project and `TASK-n`, and plain voice,
/// call and chat tasks — as a board (To Do / In Progress / Done) or a plain list, per project; Suggested drafts
/// stay on top (FEAT-0005); the archive is one button away. Every change goes through `TrackerService` on a fresh
/// fetch by id (stale-save rule), never through this view's copies.
/// spec://BACKLOG#sidebar-reorg + B1, spec://tracker/FEAT-0006#ui
struct TasksView: View {
    /// All non-dismissed tasks — the drafts strip reads them; a change here also redraws the board.
    @Query(
        filter: #Predicate<TaskItem> { !$0.isDismissed && ($0.status == nil || $0.status != "dismissed") },
        sort: \TaskItem.createdAt,
        order: .reverse
    )
    private var tasks: [TaskItem]

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var license = LicenseService.shared
    @ObservedObject private var localLLM = LocalLLMService.shared
    @StateObject private var board: TasksWindowModel
    /// A project's page (§9b): that project's tasks only, its own header above, new tasks in it.
    private let projectId: UUID?
    /// "+ add project" → New project… on a task: the task goes into the project made.
    @State private var newProjectForTask: UUID?

    init(projectId: UUID? = nil) {
        self.projectId = projectId
        _board = StateObject(wrappedValue: TasksWindowModel(filter: projectId.map { .project($0) } ?? .all))
    }
    @AppStorage("tasksLayout") private var layout = "board"
    @State private var isExtracting = false
    @State private var extractionResult: String?
    @State private var candidatesExpanded = true
    @State private var openTask: OpenTask?
    @State private var newTaskOpen = false
    @State private var newProjectOpen = false
    @State private var newProjectName = ""

    @Environment(\.modelContext) private var modelContext

    /// Suggested = drafts (status=="staged"): voice and call suggestions, and screen candidates, awaiting the
    /// user's decision. FEAT-0005 — the same rule as the after-call card (`TaskDrafts.visible`): not dropped, not
    /// done, inside the 7-day window (hidden ≠ deleted, the rows stay), at most five, newest first. Drafts have no
    /// project, so they show under All and No project.
    private var stagedTasks: [TaskItem] {
        switch board.filter {
        case .all, .none: return TaskDrafts.visible(tasks)
        case .project: return []
        }
    }

    /// Redraws the board when any task changes elsewhere (a draft accepted, a call's task, MetaChat).
    private var tasksSignature: [Date] { tasks.map(\.updatedAt) }

    /// ITER-047 Element B — generic gate (local LLM counts) for the reminder bar.
    private var hasLLMAccess: Bool {
        LLMAccess.has(apiKey: settings.activeAPIKey, isPro: license.isPro, localReady: localLLM.isReady)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !hasLLMAccess { LLMAccessBar() }
            header
            Rectangle().fill(MW.border).frame(height: MW.hairline)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { board.attach() }
        .onChange(of: tasksSignature) { _, _ in board.reload() }
        .sheet(item: $openTask) { open in
            if let service = TrackerService.shared {
                TaskDetailSheet(service: service, taskId: open.id, projects: board.projects) { board.reload() }
            }
        }
        .sheet(isPresented: $newTaskOpen) {
            NewTaskSheet(projects: board.projects, initialProject: board.selectedProjectId) { title, projectId in
                board.perform { try $0.createTask(title: title, projectId: projectId) }
            }
        }
        .alert("New project", isPresented: $newProjectOpen) {
            TextField("Name", text: $newProjectName)
            Button("Create") {
                let name = newProjectName
                let task = newProjectForTask
                newProjectName = ""
                newProjectForTask = nil
                board.perform { service in
                    let id = try service.createProject(name: name)
                    if let task {
                        try service.setProject(taskId: task, projectId: id)
                    } else {
                        board.filter = .project(id)
                    }
                }
            }
            Button("Cancel", role: .cancel) { newProjectName = ""; newProjectForTask = nil }
        }
    }

    struct OpenTask: Identifiable { let id: UUID }

    // MARK: - Header

    /// One row when it fits; narrower, the controls take a second row under the title, and in the narrowest window
    /// two rows. A control's words never break inside it (owner 2026-11-26, the narrow-window screenshot).
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if projectId != nil {
                // A project's page names the project above: no title row, the count beside the view choice.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        controls
                        Spacer(minLength: 12)
                        activeCount
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            viewControls
                            Spacer(minLength: 8)
                            activeCount
                        }
                        HStack(spacing: 8) { actionControls }
                    }
                }
            } else {
                titledHeader
            }
            if let result = extractionResult ?? board.lastError {
                Text(result)
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textSecondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var titledHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                title
                Spacer(minLength: 12)
                controls
                activeCount
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    title
                    Spacer()
                    activeCount
                }
                HStack(spacing: 8) {
                    controls
                    Spacer(minLength: 0)
                }
            }
            // The narrowest window: the controls in two rows, the view choice above the actions.
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    title
                    Spacer()
                    activeCount
                }
                HStack(spacing: 8) { viewControls }
                HStack(spacing: 8) { actionControls }
            }
        }
    }

    /// In a project's page the page's own header names it; the title here is the Tasks tab's.
    @ViewBuilder private var title: some View {
        if projectId == nil {
            Text("Tasks")
                .font(MW.monoTitle)
                .foregroundStyle(MW.textPrimary)
                .fixedSize()
        }
    }

    private var activeCount: some View {
        Text("\(board.cards.filter { $0.status != .done }.count) open")
            .font(MW.monoSm).foregroundStyle(MW.textMuted)
            .fixedSize()
    }

    @ViewBuilder
    private var controls: some View {
        viewControls
        actionControls
    }

    /// Board or list, and which project.
    @ViewBuilder
    private var viewControls: some View {
        Picker("", selection: $layout) {
            Text("Board").tag("board")
            Text("List").tag("list")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 120)
        if projectId == nil { projectMenu }
    }

    /// Archive, a new task, and the extraction run.
    @ViewBuilder
    private var actionControls: some View {
        headerButton(board.showArchive ? (layout == "list" ? "List" : "Board") : "Archive",
                     icon: board.showArchive ? "square.grid.3x1.below.line.grid.1x2" : "archivebox") {
            board.showArchive.toggle()
        }
        headerButton("New task", icon: "plus") { newTaskOpen = true }
        // Suggestions show on the Tasks tab only, and are made only with smart features on (UI review #2).
        if settings.tasksEnabled && projectId == nil && hasLLMAccess {
            Button(action: extractTasksNow) {
                HStack(spacing: 4) {
                    if isExtracting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles").font(.system(size: 10))
                    }
                    Text(isExtracting ? "Extracting…" : "Extract now")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(MW.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                .contentShape(Rectangle())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .disabled(isExtracting)
        }
    }

    private func headerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(MW.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    private var projectMenu: some View {
        Menu {
            Button("All projects") { board.filter = .all }
            Button("No project") { board.filter = .none }
            if !board.projects.isEmpty { Divider() }
            ForEach(board.projects, id: \.id) { p in
                Button(p.name) { board.filter = .project(p.id) }
            }
            Divider()
            Button("New project…") { newProjectOpen = true }
        } label: {
            Text(board.filterName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(MW.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if board.cards.isEmpty && stagedTasks.isEmpty && !board.showArchive {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    // Staged candidates bin — rendered first when non-empty so user sees
                    // them on open. Collapsible to stay out of the way.
                    if !stagedTasks.isEmpty && !board.showArchive {
                        stagedSection
                    }
                    if board.showArchive {
                        archiveList
                    } else if layout == "list" {
                        taskList
                    } else {
                        taskBoard
                    }
                }
                .padding(16)
            }
            .onGeometryChange(for: Bool.self) { $0.size.width >= Self.columnsBesideFrom } action: { beside in
                if beside != columnsBeside { columnsBeside = beside }
            }
        }
    }

    @State private var columnsBeside = true
    /// The board's columns stand side by side from this width (three cards of a readable width).
    private static let columnsBesideFrom: CGFloat = 600

    /// The board: three columns; a card drags to another column; a click opens the task. A narrow window puts the
    /// columns one under another, To Do first.
    private var taskBoard: some View {
        let layout = columnsBeside ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                                   : AnyLayout(VStackLayout(spacing: 12))
        return layout {
            // Stacked in a narrow window, an empty column is left out: no empty band between the columns that have
            // cards (UI review #13). A card still moves there through its context menu.
            ForEach(TaskBoard.columns(board.cards).filter { columnsBeside || !$0.cards.isEmpty }, id: \.status) { column in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(column.status.rawValue).mwBadge()
                        Text("\(column.cards.count)").font(MW.monoSm).foregroundStyle(MW.textMuted)
                        Spacer()
                    }
                    ForEach(column.cards) { card in
                        boardCard(card)
                    }
                    Color.clear.frame(height: 24)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).fill(MW.border.opacity(0.35)))
                .dropDestination(for: String.self) { items, _ in
                    let ids = items.compactMap(UUID.init(uuidString:))
                    board.perform { service in for id in ids { try service.move(taskId: id, to: column.status) } }
                    return !ids.isEmpty
                }
            }
        }
    }

    private func boardCard(_ card: TaskBoard.Card) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Only when it has something to say: an empty row still took the card's spacing (UI review defect 3).
            if card.priority != nil || card.key != nil || card.criteriaCount > 0 {
                HStack(spacing: 6) {
                    if let p = card.priority { priorityMark(p) }
                    if let key = card.key {
                        Text(key).font(MW.dataSmall).foregroundStyle(MW.textMuted)
                    }
                    Spacer()
                    if card.criteriaCount > 0 {
                        Text("\(card.criteriaDone)/\(card.criteriaCount)").font(MW.dataSmall).foregroundStyle(MW.textMuted)
                    }
                }
            }
            Text(card.title)
                .font(MW.mono)
                .foregroundStyle(card.status == .done ? MW.textMuted : MW.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !card.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(card.labels.prefix(3), id: \.self) { label in
                        Text(label).font(MW.monoSm).foregroundStyle(MW.textSecondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule(style: .continuous).stroke(MW.border, lineWidth: 0.5))
                    }
                }
            }
            cardFooter(card)
        }
        .padding(10)
        .mwCard(radius: MW.rSmall, elevation: .flat)
        .contentShape(Rectangle())
        .onTapGesture { openTask = OpenTask(id: card.id) }
        .draggable(card.id.uuidString)
        .contextMenu { cardMenu(card) }
    }

    private func cardFooter(_ card: TaskBoard.Card) -> some View {
        HStack(spacing: 6) {
            // §9b — the project's name where tasks of many projects show; "+ add project" for a task without one.
            if let project = card.projectName {
                if case .all = board.filter {
                    Text(project).font(MW.monoSm).foregroundStyle(MW.textMuted).lineLimit(1)
                }
            } else if !card.archived && card.status != .done {
                addProjectMenu(card)
            }
            if let due = card.dueAt {
                Text(dueLabel(due, isDay: card.dueIsDay))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(dueColor(due, isDay: card.dueIsDay, done: card.status == .done))
            }
            Spacer(minLength: 0)
            if let source = card.source {
                Text(source).font(MW.monoSm).foregroundStyle(MW.textMuted).lineLimit(1)
            }
        }
    }

    /// A task of no project: the user's projects, or a new one, in the place its project's name would be.
    private func addProjectMenu(_ card: TaskBoard.Card) -> some View {
        Menu {
            ForEach(board.projects, id: \.id) { p in
                Button(p.name) { board.perform { try $0.setProject(taskId: card.id, projectId: p.id) } }
            }
            if !board.projects.isEmpty { Divider() }
            Button("New project…") {
                newProjectForTask = card.id
                newProjectOpen = true
            }
        } label: {
            Text("+ add project").font(MW.monoSm).foregroundStyle(MW.textMuted).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func cardMenu(_ card: TaskBoard.Card) -> some View {
        ForEach(TrackerStatus.allCases, id: \.self) { status in
            if status != card.status {
                Button("Move to \(status.rawValue)") {
                    board.perform { try $0.move(taskId: card.id, to: status) }
                }
            }
        }
        Divider()
        Button("Archive") { board.perform { try $0.archive(taskId: card.id) } }
    }

    private func priorityMark(_ p: TrackerPriority) -> some View {
        Text(p.display.uppercased())
            .font(MW.microLabel)
            .foregroundStyle(p == .high ? Color.orange : MW.textMuted)
    }

    /// The plain to-do list: the same tasks, grouped by column; the box ticks a task done or back to To Do.
    private var taskList: some View {
        ForEach(TaskBoard.columns(board.cards).filter { !$0.cards.isEmpty }, id: \.status) { column in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(column.status.rawValue).mwBadge()
                    Text("\(column.cards.count)").font(MW.monoSm).foregroundStyle(MW.textMuted)
                }
                .padding(.top, 10)
                ForEach(column.cards) { card in
                    listRow(card)
                }
            }
        }
    }

    private func listRow(_ card: TaskBoard.Card) -> some View {
        HStack(spacing: 8) {
            Button {
                board.perform { try $0.move(taskId: card.id, to: card.status == .done ? .toDo : .done) }
            } label: {
                Image(systemName: card.status == .done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(card.status == .done ? MW.accent : MW.textMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if columnsBeside {
                listTitle(card)
                if let p = card.priority { priorityMark(p) }
                cardFooter(card).fixedSize()
            } else {
                // A narrow window: the title gets the row, the project and date go under it (UI review #14).
                VStack(alignment: .leading, spacing: 4) {
                    listTitle(card)
                    HStack(spacing: 6) {
                        if let p = card.priority { priorityMark(p) }
                        cardFooter(card)
                    }
                }
            }
        }
        .padding(10)
        .mwCard(radius: MW.rSmall, elevation: .flat)
        .contentShape(Rectangle())
        .onTapGesture { openTask = OpenTask(id: card.id) }
        .contextMenu { cardMenu(card) }
    }

    private func listTitle(_ card: TaskBoard.Card) -> some View {
        HStack(spacing: 8) {
            if let key = card.key {
                Text(key).font(MW.dataSmall).foregroundStyle(MW.textMuted)
            }
            Text(card.title)
                .font(MW.mono)
                .foregroundStyle(card.status == .done ? MW.textMuted : MW.textPrimary)
                .strikethrough(card.status == .done)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Archived tasks: back to the board, or — after a confirmation in the task — gone for good.
    @ViewBuilder
    private var archiveList: some View {
        Text("Archive").mwBadge()
        if board.cards.isEmpty {
            Text("Nothing archived.").font(MW.mono).foregroundStyle(MW.textMuted)
        }
        ForEach(board.cards) { card in
            HStack(spacing: 8) {
                if let key = card.key { Text(key).font(MW.dataSmall).foregroundStyle(MW.textMuted) }
                Text(card.title).font(MW.mono).foregroundStyle(MW.textSecondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(card.status.rawValue).font(MW.monoSm).foregroundStyle(MW.textMuted)
                headerButton("Restore", icon: "arrow.uturn.backward") {
                    board.perform { try $0.restore(taskId: card.id) }
                }
            }
            .padding(10)
            .mwCard(radius: MW.rSmall, elevation: .flat)
            .contentShape(Rectangle())
            .onTapGesture { openTask = OpenTask(id: card.id) }
        }
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
                    Text("Suggested")
                        .mwBadge(color: MW.textSecondary)
                    Text("\(stagedTasks.count)")
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textMuted)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if candidatesExpanded {
                ForEach(stagedTasks) { item in
                    if item.screenContextId == nil {
                        draftCard(item)
                    } else {
                        candidateCard(item)
                    }
                }
                Rectangle().fill(MW.border).frame(height: MW.hairline)
                    .padding(.vertical, 4)
            }
        }
    }

    /// FEAT-0005 — a suggestion from a dictation or a call: ✓ makes it a task, ✗ drops it. Both go through
    /// `TaskDrafts` on a fresh fetch by id (the after-call card may have decided first; this list's copy may be old).
    private func draftCard(_ item: TaskItem) -> some View {
        let id = item.id
        let container = modelContext.container
        return HStack(spacing: 6) {
            Button {
                _ = TaskDrafts.accept(id, in: container)
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MW.textPrimary)
                    .frame(width: 22, height: 22)
                    .overlay(Rectangle().stroke(MW.textMuted, lineWidth: MW.hairline))
            }
            .buttonStyle(.plain)
            .help("Add to tasks")

            Button {
                _ = TaskDrafts.drop(id, in: container)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MW.textMuted)
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Not a task")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.taskDescription)
                    .font(MW.mono)
                    .foregroundStyle(MW.textSecondary)
                HStack(spacing: 6) {
                    if let who = item.assignee, !item.isMyTask {
                        Text("waiting on \(who)").font(MW.monoSm).foregroundStyle(MW.textMuted)
                    }
                    if let due = item.dueAt {
                        Text(dueLabel(due))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(dueColor(due))
                    }
                    Spacer()
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .mwCard(radius: MW.rSmall, elevation: .flat)
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
                // SB-3 — commit + Obsidian re-export + MCP refresh, atomically:
                // the hook fires only if the save succeeds (no divergence).
                do {
                    try MutationService.shared.commit(.taskSaved(item.id), in: modelContext) {
                        item.status = "committed"
                        item.completed = true
                        item.completedAt = Date()
                        item.updatedAt = Date()
                    }
                } catch {
                    NSLog("[TasksView] mark-done save failed: %@", error.localizedDescription)
                }
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
                do {
                    try MutationService.shared.commit(.taskSaved(item.id), in: modelContext) {
                        item.status = "committed"
                        item.updatedAt = Date()
                    }
                } catch {
                    NSLog("[TasksView] save-for-later save failed: %@", error.localizedDescription)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MW.textSecondary)
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Save for later — adds it to Tasks")

            // ✗ DISMISS — hide, kept for dedup history.
            Button {
                // SB-3 — soft dismiss; the vault file is removed by the hook ONLY
                // if the save succeeded (was: unconditional delete after try? save).
                do {
                    try MutationService.shared.commit(.taskDismissed(item.id), in: modelContext) {
                        item.status = "dismissed"
                        item.isDismissed = true
                        item.updatedAt = Date()
                    }
                } catch {
                    NSLog("[TasksView] dismiss save failed: %@", error.localizedDescription)
                }
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
                            .font(.system(size: 10.5, weight: .semibold))
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
        .mwCard(radius: MW.rSmall, elevation: .flat)
    }

    // MARK: - Due dates

    /// The card's due date: the date itself, red when late, orange today, never red on a finished task (`TaskDue`).
    private func dueLabel(_ date: Date, isDay: Bool = false) -> String { TaskDue.label(date, isDay: isDay) }

    private func dueColor(_ date: Date, isDay: Bool = false, done: Bool = false) -> Color {
        switch TaskDue.tone(date, isDay: isDay, done: done) {
        case .late: return .red.opacity(0.85)
        case .today: return .orange
        case .plain: return MW.textSecondary
        }
    }

    // MARK: - Empty

    /// What an empty board says depends on where it is: the long line explains suggestions only on the Tasks tab with
    /// every project, the one place they appear (UI review 2026-11-27, #5).
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 32))
                .foregroundStyle(MW.textMuted)
            Text(emptyTitle)
                .font(MW.monoLg).foregroundStyle(MW.textSecondary)
                .multilineTextAlignment(.center)
            if projectId == nil, case .all = board.filter {
                Text("Say \"Remind me to X\" or agree on something in a call — MetaWhisp suggests it here, and you add the ones you want.")
                    .font(MW.mono).foregroundStyle(MW.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private var emptyTitle: String {
        if board.projectGone { return "This project is gone." }
        switch board.filter {
        case .all: return "No tasks yet"
        case .none: return "Every task is in a project."
        case .project: return "No tasks in \(board.filterName)."
        }
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
                ? "\(delta) new \(delta == 1 ? "suggestion" : "suggestions")"
                : "No new suggestions (nothing actionable in the last transcript)"
                NSLog("[TasksView] EXTRACT NOW → banner=%@ (delta=%d, extractor lastError=%@)", delta > 0 ? "added" : "no new tasks", delta, appDelegate.taskExtractor.lastError ?? "none")
            isExtracting = false
        }
    }
}
