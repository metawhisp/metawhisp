import Combine
import MetaWhispTrackerKit
import SwiftUI

/// FEAT-0006 §9 — the Tasks window's state: the cards of the picked project (board or archive) and the projects to
/// pick from, reloaded after every tracker write and every task change elsewhere.
@MainActor
final class TasksWindowModel: ObservableObject {
    @Published private(set) var cards: [TaskBoard.Card] = []
    @Published private(set) var projects: [(id: UUID, name: String)] = []
    @Published var filter: TaskBoard.ProjectFilter = .all { didSet { reload() } }

    /// A project's page: its one project, never another one or all of them (review 2026-11-27, #3).
    private let pinnedProject: UUID?
    /// The page's project no longer exists (deleted or merged away while open).
    @Published private(set) var projectGone = false

    /// `filter`: `.project(id)` for a project's page, which shows that project only.
    init(filter: TaskBoard.ProjectFilter = .all) {
        self.filter = filter
        if case .project(let id) = filter { pinnedProject = id } else { pinnedProject = nil }
    }
    @Published var showArchive = false { didSet { reload() } }
    @Published private(set) var lastError: String?

    private var subscription: AnyCancellable?
    private var attempts = 0

    var selectedProjectId: UUID? {
        if case .project(let id) = filter { return id }
        return nil
    }

    var filterName: String {
        switch filter {
        case .all: return "All projects"
        case .none: return "No project"
        case .project(let id): return projects.first { $0.id == id }?.name ?? "Project"
        }
    }

    /// The tracker opens shortly after launch; until then this retries once a second, at most 30 times.
    func attach() {
        guard subscription == nil else { reload(); return }
        guard let service = TrackerService.shared else {
            guard attempts < 30 else { return }
            attempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.attach() }
            return
        }
        subscription = service.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
        reload()
    }

    func reload() {
        guard let service = TrackerService.shared else { return }
        projects = service.projectChoices()
        if let pinned = pinnedProject {
            projectGone = !projects.contains { $0.id == pinned }
            if projectGone { cards = []; return }
        } else if case .project(let id) = filter, !projects.contains(where: { $0.id == id }) {
            filter = .all
            return
        }
        cards = service.boardCards(filter: filter, archived: showArchive)
    }

    /// Runs one change through the tracker; a refusal is shown in the header, never swallowed.
    func perform(_ change: (TrackerService) throws -> Void) {
        guard let service = TrackerService.shared else {
            lastError = "Tasks are still starting; try again in a moment."
            return
        }
        do {
            try change(service)
            lastError = nil
        } catch let f as TrackerFailure {
            lastError = f.message
        } catch {
            lastError = error.localizedDescription
        }
        reload()
    }
}

/// One task in full: what the agent recorded (description, criteria, plan, notes, comments, summary, links), its
/// column and project; Archive / Restore, and Delete forever for an archived task, after a confirmation.
struct TaskDetailSheet: View {
    /// Observed: an agent may change the task while it is open; the sheet reloads on the tracker's revision —
    /// a stable source, never a publisher rebuilt on each render (review round 2, N1).
    @ObservedObject var service: TrackerService
    let taskId: UUID
    let projects: [(id: UUID, name: String)]
    let changed: () -> Void
    /// Test seam: called on every reload of the task.
    var onLoad: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var value: TrackerService.TaskDetailValue?
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var titleDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let value {
                header(value.card)
                Rectangle().fill(MW.border).frame(height: MW.hairline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if value.card.archived, let due = value.card.dueAt {
                            Text("Due \(due.formatted(date: .abbreviated, time: value.card.dueIsDay ? .omitted : .shortened))")
                                .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                        }
                        if let from = value.conversation {
                            Button {
                                AppDelegate.shared?.openConversationInLibrary(id: from.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "bubble.left").font(.system(size: 11))
                                    Text("From \(from.title) · \(from.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(MW.monoSm).lineLimit(1)
                                }
                                .foregroundStyle(MW.textSecondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if let d = value.detail { sections(d) }
                        if value.card.projectId == nil {
                            Text("No project yet: pick one above.")
                                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer(value.card)
            } else {
                Text("This task is gone.").font(MW.mono).foregroundStyle(MW.textMuted).padding(20)
                HStack { Spacer(); Button("Close") { dismiss() } }.padding(16)
            }
        }
        // Fits the narrowest window (450 pt) and grows to its usual size (UI review #7).
        .frame(minWidth: 360, idealWidth: 560, maxWidth: 560, minHeight: 360, idealHeight: 620, maxHeight: 620)
        .onAppear(perform: load)
        // An agent may change the task while it is open: show its state, not the state at opening (review P1-3).
        .onChange(of: service.revision) { _, _ in load() }
        .confirmationDialog("Delete this task forever?", isPresented: $confirmDelete) {
            Button("Delete forever", role: .destructive) {
                run { try $0.deleteForever(taskId: taskId) }
                dismiss()
            }
        } message: {
            Text("It cannot be brought back.")
        }
    }

    private func load() {
        onLoad?()
        value = service.detail(taskId: taskId)
    }

    private func run(_ change: (TrackerService) throws -> Void) {
        do {
            try change(service)
            error = nil
        } catch let f as TrackerFailure {
            error = f.message
        } catch let e {
            error = e.localizedDescription
        }
        load()
        changed()
    }

    private func header(_ card: TaskBoard.Card) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let key = card.key { Text(key).font(MW.dataSmall).foregroundStyle(MW.textMuted) }
                if !card.archived { priorityMenu(card) }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundStyle(MW.textMuted)
                }
                .buttonStyle(.plain)
            }
            if card.archived {
                Text(card.title).font(MW.monoLg).foregroundStyle(MW.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Owner 2026-11-27 (Q1): the title is fixed here; Return or leaving the field keeps it.
                TextField("Title", text: $titleDraft, axis: .vertical)
                    .font(MW.monoLg).foregroundStyle(MW.textPrimary)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit { saveTitle(card) }
                    .onAppear { titleDraft = card.title }
                    .onChange(of: card.title) { _, new in titleDraft = new }
                    .onDisappear { saveTitle(card) }
                dueRow(card)
            }
            HStack(spacing: 10) {
                if card.archived {
                    Text("Archived · \(card.status.rawValue)").font(MW.monoSm).foregroundStyle(MW.textMuted)
                } else {
                    Picker("", selection: Binding(get: { card.status }, set: { status in
                        run { try $0.move(taskId: taskId, to: status) }
                    })) {
                        ForEach(TrackerStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    // §9b — every task is in a project; one without shows "+ add project" in its place.
                    Menu(card.projectName ?? "+ add project") {
                        ForEach(projects, id: \.id) { p in
                            Button(p.name) { run { try $0.setProject(taskId: taskId, projectId: p.id) } }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer()
                if let source = card.source { Text(source).font(MW.monoSm).foregroundStyle(MW.textMuted) }
            }
            if let error { Text(error).font(MW.monoSm).foregroundStyle(MW.textSecondary) }
        }
        .padding(20)
    }

    private func saveTitle(_ card: TaskBoard.Card) {
        let new = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != card.title else {
            if new.isEmpty { titleDraft = card.title }
            return
        }
        run { try $0.editFromApp(taskId: taskId, title: new) }
    }

    /// The due day: shown and changed here, or cleared (Q1).
    private func dueRow(_ card: TaskBoard.Card) -> some View {
        HStack(spacing: 8) {
            if let due = card.dueAt {
                DatePicker("Due", selection: Binding(get: { due }, set: { picked in
                    run { try $0.editFromApp(taskId: taskId, due: .day(TaskDue.dayString(picked))) }
                }), displayedComponents: .date)
                .datePickerStyle(.field)
                .font(MW.monoSm)
                .fixedSize()
                Button("Clear") { run { try $0.editFromApp(taskId: taskId, due: .clear) } }
                    .buttonStyle(.borderless).font(MW.monoSm)
            } else {
                Button("+ due date") {
                    run { try $0.editFromApp(taskId: taskId, due: .day(TaskDue.dayString(Date()))) }
                }
                .buttonStyle(.borderless).font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
        }
    }

    private func priorityMenu(_ card: TaskBoard.Card) -> some View {
        Menu {
            ForEach(TrackerPriority.allCases, id: \.self) { p in
                Button(p.display) { run { try $0.editFromApp(taskId: taskId, priority: .set(p)) } }
            }
            if card.priority != nil {
                Divider()
                Button("No priority") { run { try $0.editFromApp(taskId: taskId, priority: .set(nil)) } }
            }
        } label: {
            Text(card.priority?.display ?? "+ priority").font(MW.monoSm)
                .foregroundStyle(card.priority == nil ? MW.textMuted : MW.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func sections(_ d: TrackerTaskDetail) -> some View {
        if !d.summary.labels.isEmpty { field("Labels", d.summary.labels.joined(separator: ", ")) }
        if !d.summary.assignee.isEmpty { field("Assignee", d.summary.assignee.joined(separator: ", ")) }
        if let p = d.parent { field("Parent", "\(p.id) - \(p.title)") }
        if !d.subtasks.isEmpty { field("Subtasks", d.subtasks.map { "\($0.id) - \($0.title) [\($0.status)]" }.joined(separator: "\n")) }
        if !d.dependsOn.isEmpty { field("Depends on", d.dependsOn.map { "\($0.id) - \($0.title) [\($0.status)]" }.joined(separator: "\n")) }
        if let text = d.description, !text.isEmpty { field("Description", text) }
        if !d.acceptanceCriteria.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Acceptance criteria").mwBadge()
                ForEach(d.acceptanceCriteria, id: \.index) { item in
                    Button { run { try $0.toggleCriterion(taskId: taskId, index: item.index, expectedText: item.text) } } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(item.checked ? MW.accent : MW.textMuted)
                            Text(item.text).font(MW.mono).foregroundStyle(MW.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(d.summary.archived)
                }
            }
        }
        if !d.definitionOfDone.isEmpty {
            field("Definition of done", d.definitionOfDone.map { "\($0.checked ? "☑" : "☐") \($0.text)" }.joined(separator: "\n"))
        }
        if let plan = d.implementationPlan, !plan.isEmpty { field("Plan", plan) }
        if let notes = d.implementationNotes, !notes.isEmpty { field("Notes", notes) }
        if !d.comments.isEmpty {
            field("Comments", d.comments.map { "\($0.author ?? "—"): \($0.body)" }.joined(separator: "\n\n"))
        }
        if let summary = d.finalSummary, !summary.isEmpty { field("Final summary", summary) }
        let links = d.references + d.documentation
        if !links.isEmpty { field("Links", links.joined(separator: "\n")) }
    }

    private func field(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).mwBadge()
            Text(text).font(MW.mono).foregroundStyle(MW.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(_ card: TaskBoard.Card) -> some View {
        HStack(spacing: 8) {
            if card.archived {
                Button("Restore") { run { try $0.restore(taskId: taskId) } }
                Button("Delete forever…", role: .destructive) { confirmDelete = true }
            } else {
                Button("Archive") {
                    run { try $0.archive(taskId: taskId) }
                    dismiss()
                }
            }
            Spacer()
            // "Close", not "Done": Done is a column (UI review #7).
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }
}

/// A task by the user's hand: a title and a project (the picked one by default).
struct NewTaskSheet: View {
    let projects: [(id: UUID, name: String)]
    let initialProject: UUID?
    let create: (String, UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var projectId: UUID?
    /// The project the user last put a new task in: Return works at once on "All projects" (UI review #4).
    @AppStorage("tasks.lastNewTaskProject") private var lastProject = ""
    @State private var askedForProject = false

    /// §9b — a task goes into a project: one must be picked while the user has any.
    private var canAdd: Bool { Self.canAdd(title: title, projectId: projectId, hasProjects: !projects.isEmpty) }

    static func canAdd(title: String, projectId: UUID?, hasProjects: Bool) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (projectId != nil || !hasProjects)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New task").font(MW.monoLg)
            TextField("What needs doing", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if !projects.isEmpty {
                Picker("Project", selection: $projectId) {
                    Text("Choose a project").tag(UUID?.none)
                    ForEach(projects, id: \.id) { p in Text(p.name).tag(UUID?.some(p.id)) }
                }
                if askedForProject && projectId == nil {
                    Text("Choose a project for it.").font(MW.monoSm).foregroundStyle(.red.opacity(0.85))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: save).keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(maxWidth: 420)
        .onAppear {
            projectId = initialProject
                ?? UUID(uuidString: lastProject).flatMap { id in projects.first { $0.id == id }?.id }
        }
    }

    private func save() {
        guard canAdd else {
            askedForProject = true
            return
        }
        if let projectId { lastProject = projectId.uuidString }
        create(title.trimmingCharacters(in: .whitespacesAndNewlines), projectId)
        dismiss()
    }
}
