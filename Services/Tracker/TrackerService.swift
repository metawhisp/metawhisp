import Combine
import Foundation
import MetaWhispTrackerKit
import SwiftData

/// FEAT-0006 — the owner of tracker data. Every caller goes through here: the local socket (Claude Code, Codex,
/// the command-line tool), the Tasks window and MetaChat.
///
/// Every operation reads in fresh contexts and writes in one synchronous step on the main actor (I1, I5): the main
/// row first (`TaskItem`, through `MutationService` so the vault follows), the tracker record second.
/// spec://tracker/FEAT-0006#ops
@MainActor
final class TrackerService: ObservableObject {

    /// Set at launch (`AppDelegate`); nil until the stores are open.
    static var shared: TrackerService?

    /// Bumps after every write, so the Tasks window redraws — and after a save elsewhere in the app of what the board
    /// is read from (`watchMainStore`).
    @Published var revision = 0

    let main: ModelContainer
    let tracker: ModelContainer
    let mutations: MutationService
    private let home: String
    let now: () -> Date
    /// Saves a tracker context; a test makes it fail to see what a failed save leaves behind.
    let saveTracker: (ModelContext) throws -> Void

    init(main: ModelContainer, tracker: ModelContainer, mutations: MutationService = .shared,
         home: String = NSHomeDirectory(), now: @escaping () -> Date = Date.init,
         saveTracker: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.main = main
        self.tracker = tracker
        self.mutations = mutations
        self.home = home
        self.now = now
        self.saveTracker = saveTracker
        watchMainStore()
    }

    /// The board is read from the main store's tasks, conversations and projects as well as the tracker's records: a
    /// call's task is in its conversation's project (`TaskProjects.map`). A regeneration that moved a call to another
    /// project changed no task and no record, so the open board, project page and task window kept the old place
    /// (Codex review P2-12, P2-13). A save of any of those rows, by any part of the app, is a change of the board.
    nonisolated static let boardEntities: Set<String> = ["TaskItem", "Conversation", "ProjectAlias"]
    private var mainSaves: AnyCancellable?

    private func watchMainStore() {
        let watched = main
        mainSaves = NotificationCenter.default.publisher(for: ModelContext.didSave)
            .filter { note in
                guard let context = note.object as? ModelContext, context.container === watched else { return false }
                return Self.touchesBoard(note.userInfo)
            }
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)   // a burst of saves is one change
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.revision &+= 1 } }
    }

    nonisolated static func touchesBoard(_ info: [AnyHashable: Any]?) -> Bool {
        guard let info else { return false }
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        return keys.contains { key in
            ((info[key.rawValue] as? [PersistentIdentifier]) ?? []).contains { boardEntities.contains($0.entityName) }
        }
    }

    /// A context for one operation: it saves what the operation saves and nothing else. A context SwiftData makes
    /// autosaves, so a change left behind by a failed save or by a refusal thrown halfway was written a moment later
    /// anyway — the task a failed archive kept on the board got its archive record all the same (found 2026-11-27
    /// re-running the Codex P1-1 test). Every context the tracker reads or writes in comes from here.
    nonisolated static func freshContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    // MARK: - Wire

    /// How many tasks `task_list` shows when the agent gives no limit.
    static let listCap = 50

    func handle(_ request: TrackerRequest) -> TrackerResponse {
        do {
            guard request.v == TrackerRequest.currentVersion else {
                throw TrackerFailure.validation("This MetaWhisp speaks tracker protocol \(TrackerRequest.currentVersion); "
                                                + "update the app or the tool.")
            }
            let a = request.args
            switch request.op {
            case "ping":
                return .success("MetaWhisp is running.")
            case "project_info":
                return .success(try projectInfo(folder: try folder(request)))
            case "task_create":
                let d = try create(TrackerArgs.create(a), folder: try folder(request), client: request.client,
                                   session: request.session)
                return .success("Created task \(d.summary.id).\n\n" + TrackerFormat.view(d), data: .encoding(d))
            case "task_list":
                let f = try folder(request)
                var input = try TrackerArgs.list(a)
                // At most `listCap` lines unless the agent asks for more, and never cut without saying so: a board
                // that grows with Done work must not fill the agent's context, nor look complete when it is not.
                let cap = input.limit ?? Self.listCap
                input.limit = nil
                let r = try list(input, folder: f)
                guard let project = r.project else { return .success(noProjectText(f)) }
                let shown = Array(r.tasks.prefix(cap))
                var text = TrackerFormat.list(project: project, tasks: shown)
                if shown.count < r.tasks.count {
                    text += "\n\nShowing \(shown.count) of \(r.tasks.count). Filter by status, labels or search, or raise "
                        + "limit, to see the rest."
                }
                return .success(text, data: .encoding(shown))
            case "task_search":
                let f = try folder(request)
                let input = try TrackerArgs.search(a)
                let r = try search(input, folder: f)
                guard let project = r.project else { return .success(noProjectText(f)) }
                return .success(TrackerFormat.search(project: project, query: input.query ?? "", tasks: r.tasks),
                                data: .encoding(r.tasks))
            case "task_view":
                let d = try view(id: TrackerArgs.id(a), folder: try folder(request))
                return .success(TrackerFormat.view(d), data: .encoding(d))
            case "task_edit":
                // A short answer: the whole task again after every note would spend the agent's context on echoes.
                // task_view shows it in full; the data carries it all.
                let d = try edit(TrackerArgs.edit(a), folder: try folder(request), client: request.client,
                                 session: request.session)
                return .success("Updated task \(d.summary.id).\n" + TrackerFormat.brief(d), data: .encoding(d))
            case "task_archive":
                let d = try archive(id: TrackerArgs.id(a), folder: try folder(request), client: request.client,
                                    session: request.session)
                return .success("Archived task \(d.summary.id).\n" + TrackerFormat.brief(d), data: .encoding(d))
            case "task_restore":
                let d = try restore(id: TrackerArgs.id(a), folder: try folder(request), client: request.client)
                return .success("Restored task \(d.summary.id).\n" + TrackerFormat.brief(d), data: .encoding(d))
            case "task_delete":
                return .success(try delete(TrackerArgs.delete(a), folder: try folder(request)))
            case "search_memories":
                let q = try TrackerArgs.query(a, defaultLimit: 10, maxLimit: 50)
                return .success(try searchMemories(q.query, limit: q.limit))
            case "search_conversations":
                let q = try TrackerArgs.query(a, defaultLimit: 5, maxLimit: 50)
                return .success(try conversations(matching: q.query, limit: q.limit, sinceDays: nil))
            case "recent_conversations":
                let r = try TrackerArgs.recent(a)
                return .success(try conversations(matching: nil, limit: r.limit, sinceDays: r.sinceDays))
            default:
                throw TrackerFailure.validation("Unknown operation: \(request.op)")
            }
        } catch let f as TrackerFailure {
            return .failure(f)
        } catch {
            NSLog("[Tracker] %@ failed: %@", request.op, error.localizedDescription)
            return .failure(TrackerFailure(.internalError, "MetaWhisp could not do that: \(error.localizedDescription)"))
        }
    }

    private func folder(_ request: TrackerRequest) throws -> String {
        guard let f = request.folder, f.hasPrefix("/") else {
            throw TrackerFailure.validation("No working folder was sent; MetaWhisp finds the project by its folder.")
        }
        return f
    }

    private func noProjectText(_ folder: String) -> String {
        "MetaWhisp has no project for \(ProjectNaming.trimmed(folder)) yet. "
            + "It is created, named after the folder, with the first task_create."
    }

    // MARK: - Operations

    func create(_ input: TaskCreateInput, folder: String, client: String?, session: String? = nil) throws -> TrackerTaskDetail {
        try requireHealthy()
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        guard let project = try resolve(folder: folder, create: true, mctx: mctx, tctx: tctx) else {
            throw TrackerFailure(.noProject, "No project for \(folder).")
        }
        try bringBack(project.id, tctx: tctx)   // an agent writing in its folder brings it back (Q4)
        let rows = try loadRows(project.id, mctx: mctx, tctx: tctx)
        let taken = try allKeys(project.id, tctx: tctx)

        var parent: Row?
        if let raw = input.parentTaskId {
            guard let p = find(raw, in: rows), case .board = p.column else {
                throw TrackerFailure.validation("Parent task \(raw) not found. Use an existing task ID of this project.")
            }
            parent = p
        }
        let key = parent.map { TrackerKey.nextSubtask(of: $0.key, existing: taken) }
            ?? TrackerKey.nextTopLevel(existing: taken)
        let dependencies = try resolveDependencies(input.dependencies, rows: rows, owner: nil)
        let board = rows.filter(\.onBoard)
        let ordinal = input.ordinal
            ?? TrackerSortKey.newOrdinal(existing: board.map(\.record.ordinal), boardIsEmpty: board.isEmpty)
        let criteria = try checklist { try Checklist.add([], texts: input.acceptanceCriteria) }
        let done = try checklist { try Checklist.add([], texts: input.definitionOfDoneAdd) }

        var body = TrackerTaskBody()
        body.description = input.description
        body.priority = input.priority?.rawValue
        body.type = input.type
        body.labels = unique(input.labels).nilIfEmpty
        body.assignee = input.assignee.nilIfEmpty
        body.dependencies = dependencies.nilIfEmpty
        body.references = input.references.nilIfEmpty
        body.documentation = input.documentation.nilIfEmpty
        body.modifiedFiles = input.modifiedFiles.nilIfEmpty
        body.acceptanceCriteria = criteria.nilIfEmpty
        body.definitionOfDone = done.nilIfEmpty
        body.finalSummary = input.finalSummary
        body.createdBy = client
        body.dueIsDay = input.dueDate != nil ? true : nil

        let t = now()
        if input.status == .inProgress { body.holder = TrackerHolder(client: client, session: session, since: t) }
        body.recordMove(from: nil, to: input.status.rawValue, by: client, at: t)
        let task = TaskItem(taskDescription: input.title, dueAt: Self.dueDate(input.dueDate),
                            sourceApp: client ?? "agent", status: "committed")
        task.createdAt = t
        task.updatedAt = t
        let record = TaskTrackerRecord(taskId: task.id, projectId: project.id, key: key.stored, body: body, now: t)
        record.parentTaskId = parent?.task.id
        record.ordinal = ordinal
        Self.move(task, record, to: input.status, at: t)

        try write { try mutations.insert(task, in: mctx) }
        tctx.insert(record)
        do {
            try tctx.save()
        } catch {
            try? mutations.hardDelete(task, in: mctx)
            throw TrackerFailure(.internalError, "The task could not be saved: \(error.localizedDescription)")
        }
        revision &+= 1
        return try detail(of: task.id, project: project)
    }

    func list(_ input: TaskListInput, folder: String) throws -> (project: String?, tasks: [TrackerTaskSummary]) {
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        guard let project = try resolve(folder: folder, create: false, mctx: mctx, tctx: tctx) else { return (nil, []) }
        let rows = try loadRows(project.id, mctx: mctx, tctx: tctx)
        var picked = rows.filter(\.onBoard).filter { row in
            let body = row.record.body
            if let s = input.status, row.status != s { return false }
            let assignees = (body.assignee ?? []).map { $0.lowercased() }
            if let a = input.assignee, !assignees.contains(a.lowercased()) { return false }
            if input.unassigned && !assignees.isEmpty { return false }
            let labels = Set((body.labels ?? []).map { $0.lowercased() })
            if !input.labels.allSatisfy({ labels.contains($0.lowercased()) }) { return false }
            if let q = input.search, score(q, row) == nil { return false }
            if input.ready && !isReady(row, rows: rows) { return false }
            return true
        }
        picked.sort(by: Self.boardOrder)
        if let limit = input.limit { picked = Array(picked.prefix(limit)) }
        return (project.name, picked.map { summary($0, rows: rows, project: project) })
    }

    func search(_ input: TaskSearchInput, folder: String) throws -> (project: String?, tasks: [TrackerTaskSummary]) {
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        guard let project = try resolve(folder: folder, create: false, mctx: mctx, tctx: tctx) else { return (nil, []) }
        let rows = try loadRows(project.id, mctx: mctx, tctx: tctx)
        var scored: [(row: Row, score: Int)] = rows.compactMap { row in
            let body = row.record.body
            if let s = input.status, row.status != s { return nil }
            if let p = input.priority, body.priority != p.rawValue { return nil }
            if !input.type.isEmpty, !input.type.contains(body.type ?? "") { return nil }
            if !input.modifiedFiles.isEmpty {
                let files = (body.modifiedFiles ?? []).map { $0.lowercased() }
                guard input.modifiedFiles.contains(where: { f in files.contains { $0.contains(f.lowercased()) } })
                else { return nil }
            }
            guard let q = input.query else { return (row, 0) }
            return score(q, row).map { (row, $0) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : Self.boardOrder(a.row, b.row) }
        if let limit = input.limit { scored = Array(scored.prefix(limit)) }
        return (project.name, scored.map { summary($0.row, rows: rows, project: project) })
    }

    func view(id: String, folder: String) throws -> TrackerTaskDetail {
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        let project = try existingProject(folder, mctx: mctx, tctx: tctx)
        let rows = try loadRows(project.id, mctx: mctx, tctx: tctx)
        let row = try require(id, in: rows)
        return detail(row, rows: rows, project: project)
    }

    func edit(_ e: TaskEditInput, folder: String, client: String?, session: String? = nil) throws -> TrackerTaskDetail {
        try requireHealthy()
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        let project = try existingProject(folder, mctx: mctx, tctx: tctx, write: true)
        try bringBack(project.id, tctx: tctx)   // an agent writing in its folder brings it back (Q4)
        let rows = try loadRows(project.id, mctx: mctx, tctx: tctx)
        let row = try require(e.id, in: rows)
        guard row.onBoard else {
            throw TrackerFailure.validation("Task \(row.key.display) is archived. Archived tasks are read-only. "
                                            + "Restore it first with task_restore.")
        }
        // An index read before someone else's change may point at another line now: refuse, the agent reads again.
        let current = TrackerTaskSummary.revision(of: max(row.task.updatedAt, row.record.updatedAt))
        if let expected = e.expectedRevision, expected != current {
            throw TrackerFailure.validation("Task \(row.key.display) changed since you read it (revision \(current) "
                                            + "now). View it again, then edit.")
        }

        // Everything is worked out before anything is written: a refused edit writes nothing.
        var body = row.record.body
        let t = now()
        if let d = e.description { body.description = d.isEmpty ? nil : d }
        if let p = e.priority { body.priority = p.rawValue }
        if let ty = e.type { body.type = ty }
        if e.labels != nil || !e.addLabels.isEmpty || !e.removeLabels.isEmpty {
            let removed = Set(e.removeLabels.map { $0.lowercased() })
            body.labels = unique((e.labels ?? body.labels ?? []) + e.addLabels)
                .filter { !removed.contains($0.lowercased()) }.nilIfEmpty
        }
        if let a = e.assignee { body.assignee = a.nilIfEmpty }
        if e.dependencies != nil || !e.addDependencies.isEmpty || !e.removeDependencies.isEmpty {
            var ids = try e.dependencies.map { try resolveDependencies($0, rows: rows, owner: row) }
                ?? body.dependencies ?? []
            for added in try resolveDependencies(e.addDependencies, rows: rows, owner: row) where !ids.contains(added) {
                ids.append(added)
            }
            let gone = Set(try resolveDependencies(e.removeDependencies, rows: rows, owner: nil))
            ids.removeAll { gone.contains($0) }
            // The whole list checked once more: a cycle the additions make together with the kept ones is refused.
            let keys = ids.compactMap { id in rows.first { $0.task.id == id }?.key.display }
            body.dependencies = try resolveDependencies(keys, rows: rows, owner: row).nilIfEmpty
        }
        // Owner 2026-11-27 (Q2) — In Progress is taken by one agent session. Another session neither takes it again nor
        // moves it; the user frees it by moving it back to To Do (or it goes to Done).
        if let s = e.status {
            if row.status == .inProgress, let h = body.holder, !h.isSame(client: client, session: session) {
                throw TrackerFailure.validation("Task \(row.key.display) is already In Progress with "
                    + "\(h.client ?? "another agent") since \(TrackerFormat.timestamp(h.since)). Pick another task "
                    + "(task_list with ready: true); the user can move it back to To Do to free it.")
            }
            switch s {
            case .inProgress:
                // Entering from another column takes it afresh: a hold left by a path that moved it out without
                // clearing it (MetaChat's complete) never outlives In Progress (Codex review P2-3).
                if row.status != .inProgress || body.holder == nil {
                    body.holder = TrackerHolder(client: client, session: session, since: t)
                }
            case .toDo, .done:
                body.holder = nil
            }
            body.recordMove(from: row.status.rawValue, to: s.rawValue, by: client, at: t)
        }
        // Done says the work is finished: not while a step of it or something it waits on is still open.
        if e.status == .done, row.status != .done, !e.force {
            let open = rows.filter { $0.onBoard && $0.status != .done && $0.record.parentTaskId == row.task.id }
                + (body.dependencies ?? []).compactMap { dep in rows.first { $0.task.id == dep } }
                    .filter { $0.onBoard && $0.status != .done }
            if !open.isEmpty {
                let names = open.map { "\($0.key.display) (\($0.status.rawValue))" }.joined(separator: ", ")
                throw TrackerFailure.validation("Task \(row.key.display) cannot move to Done while \(names) "
                                                + "\(open.count == 1 ? "is" : "are") open. Finish \(open.count == 1 ? "it" : "them") "
                                                + "first, or pass force: true and say why in commentsAppend.")
            }
        }
        body.references = Self.mergedList(body.references, set: e.references, add: e.addReferences,
                                    remove: e.removeReferences)
        body.documentation = Self.mergedList(body.documentation, set: e.documentation, add: e.addDocumentation,
                                       remove: e.removeDocumentation)
        if let m = e.modifiedFiles { body.modifiedFiles = m.nilIfEmpty }
        switch e.dueDate {
        case .unchanged: break
        case .clear: body.dueIsDay = nil
        case .set: body.dueIsDay = true
        }
        body.implementationPlan = Self.text(body.implementationPlan, clear: e.planClear, set: e.planSet,
                                            append: e.planAppend)
        body.implementationNotes = Self.text(body.implementationNotes, clear: e.notesClear, set: e.notesSet,
                                             append: e.notesAppend)
        body.finalSummary = Self.text(body.finalSummary, clear: e.finalSummaryClear, set: e.finalSummary,
                                      append: e.finalSummaryAppend)
        if !e.commentsAppend.isEmpty {
            body.comments = (body.comments ?? []) + e.commentsAppend.map {
                TrackerComment(body: $0, author: e.commentAuthor ?? client, createdAt: t)
            }
        }
        body.acceptanceCriteria = try checklist {
            try Checklist.edit(body.acceptanceCriteria ?? [], set: e.acceptanceCriteriaSet, add: e.acceptanceCriteriaAdd,
                               remove: e.acceptanceCriteriaRemove, check: e.acceptanceCriteriaCheck,
                               uncheck: e.acceptanceCriteriaUncheck)
        }.nilIfEmpty
        body.definitionOfDone = try checklist {
            try Checklist.edit(body.definitionOfDone ?? [], add: e.definitionOfDoneAdd, remove: e.definitionOfDoneRemove,
                               check: e.definitionOfDoneCheck, uncheck: e.definitionOfDoneUncheck)
        }.nilIfEmpty

        let task = row.task, record = row.record
        let mainChanges = e.title != nil || (e.status != nil && e.status != row.status) || e.dueDate != .unchanged
        if mainChanges {
            try write {
                try mutations.commit(.taskSaved(task.id), in: mctx) {
                    if let title = e.title { task.taskDescription = title }
                    switch e.dueDate {
                    case .unchanged: break
                    case .clear: task.dueAt = nil
                    case .set(let day): task.dueAt = Self.dueDate(day)
                    }
                    if let s = e.status { Self.move(task, record, to: s, at: t) }
                    task.updatedAt = t
                }
            }
        }
        record.body = body
        if let o = e.ordinal { record.ordinal = o }
        record.updatedAt = t
        try tctx.save()
        revision &+= 1
        return try detail(of: task.id, project: project)
    }

    func archive(id: String, folder: String, client: String? = nil, session: String? = nil) throws -> TrackerTaskDetail {
        try requireHealthy()
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        let project = try existingProject(folder, mctx: mctx, tctx: tctx, write: true)
        let row = try require(id, in: try loadRows(project.id, mctx: mctx, tctx: tctx))
        guard row.onBoard else { throw TrackerFailure.validation("Task \(row.key.display) is already archived.") }
        // Q2 — another agent session's In Progress task is the user's to free, not another agent's to put away.
        if row.status == .inProgress, let h = row.record.body.holder, !h.isSame(client: client, session: session) {
            throw TrackerFailure.validation("Task \(row.key.display) is In Progress with \(h.client ?? "another agent") "
                + "since \(TrackerFormat.timestamp(h.since)); the user can move it back to To Do first.")
        }
        let t = now()
        try write {
            try mutations.commit(.taskDismissed(row.task.id), in: mctx) {
                row.task.status = "dismissed"
                row.task.isDismissed = true
                row.task.updatedAt = t
            }
        }
        row.record.archivedAt = t
        row.record.noteMove(from: row.status.rawValue, to: "Archived", by: client, at: t)
        row.record.clearHolder()
        row.record.updatedAt = t
        try tctx.save()
        revision &+= 1
        return try detail(of: row.task.id, project: project)
    }

    func restore(id: String, folder: String, client: String? = nil) throws -> TrackerTaskDetail {
        try requireHealthy()
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        let project = try existingProject(folder, mctx: mctx, tctx: tctx, write: true)
        let row = try require(id, in: try loadRows(project.id, mctx: mctx, tctx: tctx))
        guard !row.onBoard else {
            throw TrackerFailure.validation("Task \(row.key.display) is not archived. It is already on the board.")
        }
        let t = now()
        try write {
            try mutations.commit(.taskSaved(row.task.id), in: mctx) {
                row.task.status = "committed"
                row.task.isDismissed = false
                row.task.updatedAt = t
            }
        }
        row.record.archivedAt = nil
        row.record.noteMove(from: "Archived", to: row.status.rawValue, by: client, at: t)
        row.record.updatedAt = t
        try tctx.save()
        revision &+= 1
        return try detail(of: row.task.id, project: project)
    }

    /// Delete forever: archived tasks only, only with the user's yes, never while subtasks exist (D6, D6b).
    func delete(_ input: TaskDeleteInput, folder: String) throws -> String {
        try requireHealthy()
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        let project = try existingProject(folder, mctx: mctx, tctx: tctx, write: true)
        let rows = try loadRows(project.id, mctx: mctx, tctx: tctx)
        let row = try require(input.id, in: rows)
        let name = row.key.display
        guard !row.onBoard else {
            throw TrackerFailure.validation("Task \(name) is not archived. A task must be archived before it can be "
                                            + "deleted; archive is usually enough.")
        }
        guard input.userConfirmed else {
            throw TrackerFailure.validation("Deleting \(name) forever needs the user's explicit yes. Ask them in this "
                                            + "chat, then call task_delete with userConfirmed: true.")
        }
        let children = try Self.freshContext(tracker).fetch(FetchDescriptor<TaskTrackerRecord>())
            .filter { $0.parentTaskId == row.task.id }
            .compactMap { $0.trackerKey?.display }.sorted()
        guard children.isEmpty else {
            throw TrackerFailure.validation("Task \(name) cannot be deleted while its subtasks exist: "
                                            + children.joined(separator: ", ") + ".")
        }
        var unlinked: [String] = []
        for other in rows where other.task.id != row.task.id {
            var body = other.record.body
            guard let deps = body.dependencies, deps.contains(row.task.id) else { continue }
            body.dependencies = deps.filter { $0 != row.task.id }.nilIfEmpty
            other.record.body = body
            other.record.updatedAt = now()
            unlinked.append(other.key.display)
        }
        // The links go first, so a refused main delete never leaves a dependency on a task that is gone (P3-12).
        try tctx.save()
        try write { try mutations.hardDelete(row.task, in: mctx) }
        tctx.delete(row.record)
        try tctx.save()
        revision &+= 1
        return "Deleted task \(name) forever."
            + (unlinked.isEmpty ? "" : " Removed it from the dependencies of \(unlinked.sorted().joined(separator: ", ")).")
    }

    func projectInfo(folder: String) throws -> String {
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        guard let project = try resolve(folder: folder, create: false, mctx: mctx, tctx: tctx) else {
            return noProjectText(folder)
        }
        let rows = try loadRows(project.id, mctx: mctx, tctx: tctx)
        let count = { (s: TrackerStatus) in rows.filter { $0.onBoard && $0.status == s }.count }
        return "Project: \(project.name)\nFolder: \(ProjectNaming.trimmed(folder))\n"
            + "Tasks: \(count(.toDo)) to do, \(count(.inProgress)) in progress, \(count(.done)) done, "
            + "\(rows.filter { !$0.onBoard }.count) archived"
    }

    // MARK: - Memories and conversations (read-only, live — D3)

    func searchMemories(_ query: String, limit: Int) throws -> String {
        let ctx = Self.freshContext(main)
        let all = try ctx.fetch(FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed && !$0.needsReview },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        let hits = all.filter { m in
            TrackerSearch.score(query: query, id: "", title: m.subject ?? "", body: m.content) != nil
        }.prefix(limit)
        guard !hits.isEmpty else { return "No memories matched «\(query)»." }
        return hits.map { m in
            "- [\(m.kind ?? "FACT")] \(m.subject.map { $0 + " — " } ?? "")\(m.content)"
                + (m.project.map { " (project: \($0))" } ?? "") + " (captured \(TrackerFormat.day(m.createdAt)))"
        }.joined(separator: "\n")
    }

    func conversations(matching query: String?, limit: Int, sinceDays: Int?) throws -> String {
        let ctx = Self.freshContext(main)
        let all = try ctx.fetch(FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.finishedAt != nil && $0.status == "completed" },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))
        let cutoff = sinceDays.map { now().addingTimeInterval(-Double($0) * 86_400) }
        let hits = all.filter { c in
            if let cutoff, (c.finishedAt ?? c.startedAt) < cutoff { return false }
            guard let query else { return true }
            return TrackerSearch.score(query: query, id: c.primaryProject ?? "", title: c.title ?? "",
                                       body: c.overview ?? "") != nil
        }.prefix(limit)
        guard !hits.isEmpty else { return query.map { "No conversations matched «\($0)»." } ?? "No conversations." }
        return hits.map { c in
            var s = "## \(c.title ?? "Untitled")"
            if let p = c.primaryProject, !p.isEmpty { s += " (project: \(p))" }
            s += "\n  \(TrackerFormat.timestamp(c.finishedAt ?? c.startedAt))"
            if let o = c.overview, !o.isEmpty { s += "\n  \(o)" }
            return s
        }.joined(separator: "\n\n")
    }

    // MARK: - Rows

    /// A tracker task as the board sees it: the main row, its record, its key and its column.
    struct Row {
        let task: TaskItem
        let record: TaskTrackerRecord
        let key: TrackerKey
        /// The column it is in, or would be in once restored.
        let status: TrackerStatus
        let onBoard: Bool

        var column: Column { onBoard ? .board(status) : .archived(status) }

        enum Column: Equatable {
            case board(TrackerStatus)
            case archived(TrackerStatus)
        }
    }

    /// The project's tracker tasks. Drafts never appear (I3); a tracker task dismissed by any path is archived.
    func loadRows(_ projectId: UUID, mctx: ModelContext, tctx: ModelContext) throws -> [Row] {
        let pid: UUID? = projectId
        let records = try tctx.fetch(FetchDescriptor<TaskTrackerRecord>(predicate: #Predicate { $0.projectId == pid }))
        let ids = records.map(\.taskId)
        let tasks = try mctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { ids.contains($0.id) }))
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return records.compactMap { record in
            guard let task = byId[record.taskId], let key = record.trackerKey,
                  task.effectiveStatus != "staged" else { return nil }
            let status: TrackerStatus = task.completed ? .done : (record.startedAt != nil ? .inProgress : .toDo)
            let archived = task.isDismissed || task.effectiveStatus == "dismissed"
            return Row(task: task, record: record, key: key, status: status, onBoard: !archived)
        }
    }

    /// Every key the project ever gave out that still has a record (archived included): numbers are not reused.
    func allKeys(_ projectId: UUID, tctx: ModelContext) throws -> [TrackerKey] {
        let pid: UUID? = projectId
        return try tctx.fetch(FetchDescriptor<TaskTrackerRecord>(predicate: #Predicate { $0.projectId == pid }))
            .compactMap(\.trackerKey)
    }

    private func find(_ raw: String, in rows: [Row]) -> Row? {
        guard let key = TrackerKey(parsing: raw) else { return nil }
        return rows.first { $0.key == key }
    }

    private func require(_ raw: String, in rows: [Row]) throws -> Row {
        guard let row = find(raw, in: rows) else {
            throw TrackerFailure(.taskNotFound, "Task \(TrackerKey(parsing: raw)?.display ?? raw) not found in this "
                                 + "project.")
        }
        return row
    }

    static func boardOrder(_ a: Row, _ b: Row) -> Bool {
        let ia = TrackerStatus.allCases.firstIndex(of: a.status)!, ib = TrackerStatus.allCases.firstIndex(of: b.status)!
        if ia != ib { return ia < ib }
        return TrackerSortKey.precedes(sortKey(a), sortKey(b))
    }

    static func sortKey(_ r: Row) -> TrackerSortKey {
        TrackerSortKey(ordinal: r.record.ordinal, priority: r.record.body.priority.flatMap(TrackerPriority.init),
                       key: r.key, createdAt: r.task.createdAt)
    }

    private func score(_ query: String, _ row: Row) -> Int? {
        let b = row.record.body
        var parts: [String] = []
        parts.append(b.description ?? "")
        parts.append(contentsOf: (b.acceptanceCriteria ?? []).map(\.text))
        parts.append(b.implementationPlan ?? "")
        parts.append(b.implementationNotes ?? "")
        parts.append(b.finalSummary ?? "")
        parts.append(contentsOf: (b.comments ?? []).map(\.body))
        parts.append(contentsOf: b.labels ?? [])
        parts.append(contentsOf: b.modifiedFiles ?? [])
        let text = parts.joined(separator: "\n")
        return TrackerSearch.score(query: query, id: row.key.display, title: row.task.taskDescription, body: text)
    }

    /// Free to pick up: in To Do (In Progress is someone's work already), and nothing it waits on is open — a
    /// dependency is done, archived (taken off the work) or gone.
    private func isReady(_ row: Row, rows: [Row]) -> Bool {
        guard row.onBoard, row.status == .toDo else { return false }
        return (row.record.body.dependencies ?? []).allSatisfy { dep in
            guard let other = rows.first(where: { $0.task.id == dep }) else { return true }
            return other.status == .done || !other.onBoard
        }
    }

    // MARK: - What agents read

    private func detail(of taskId: UUID, project: ProjectRef) throws -> TrackerTaskDetail {
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        let rows = try loadRows(project.id, mctx: mctx, tctx: tctx)
        guard let row = rows.first(where: { $0.task.id == taskId }) else {
            throw TrackerFailure(.internalError, "The task was saved but could not be read back.")
        }
        return detail(row, rows: rows, project: project)
    }

    func detail(_ row: Row, rows: [Row], project: ProjectRef) -> TrackerTaskDetail {
        var d = TrackerTaskDetail(summary: summary(row, rows: rows, project: project))
        Self.fill(&d, from: row.record.body)
        // An archived task says so: its column alone would read as work still open.
        let ref = { (r: Row) in
            TrackerTaskRef(id: r.key.display, title: r.task.taskDescription,
                           status: r.onBoard ? r.status.rawValue : "\(r.status.rawValue), archived")
        }
        let b = row.record.body
        d.parent = row.record.parentTaskId.flatMap { pid in rows.first { $0.task.id == pid } }.map(ref)
        d.subtasks = rows.filter { $0.record.parentTaskId == row.task.id }.sorted { $0.key < $1.key }.map(ref)
        d.dependsOn = (b.dependencies ?? []).compactMap { dep in rows.first { $0.task.id == dep } }.map(ref)
        d.dependents = rows.filter { ($0.record.body.dependencies ?? []).contains(row.task.id) }
            .sorted { $0.key < $1.key }.map(ref)
        return d
    }

    /// The window's detail of a task outside every project's numbered tasks (its project was deleted): what its
    /// record holds, without what only a project gives — a number and links to other tasks. The sheet hid all of it
    /// (Codex review P2-8).
    func detail(of task: TaskItem, record: TaskTrackerRecord, archived: Bool) -> TrackerTaskDetail {
        let b = record.body
        let criteria = b.acceptanceCriteria ?? []
        var d = TrackerTaskDetail(summary: TrackerTaskSummary(
            id: "", title: task.taskDescription, status: record.column(of: task).rawValue, archived: archived,
            priority: b.priority, type: b.type, labels: b.labels ?? [], assignee: b.assignee ?? [], dependencies: [],
            parentTaskId: nil, acceptanceCriteriaCompleted: criteria.filter(\.checked).count,
            acceptanceCriteriaCount: criteria.count, dueDate: task.dueAt.map { TrackerFormat.day($0) },
            ordinal: record.ordinal, createdAt: task.createdAt, updatedAt: max(task.updatedAt, record.updatedAt), isReady: false, project: ""))
        Self.fill(&d, from: b)
        return d
    }

    /// The record's own fields, the same in both details.
    private static func fill(_ d: inout TrackerTaskDetail, from b: TrackerTaskBody) {
        d.description = b.description
        d.acceptanceCriteria = Checklist.entries(b.acceptanceCriteria ?? [])
        d.definitionOfDone = Checklist.entries(b.definitionOfDone ?? [])
        d.implementationPlan = b.implementationPlan
        d.implementationNotes = b.implementationNotes
        d.comments = (b.comments ?? []).enumerated().map {
            TrackerCommentEntry(index: $0.offset + 1, body: $0.element.body, author: $0.element.author,
                                createdAt: $0.element.createdAt)
        }
        d.finalSummary = b.finalSummary
        d.history = b.events ?? []
        d.references = b.references ?? []
        d.documentation = b.documentation ?? []
        d.modifiedFiles = b.modifiedFiles ?? []
    }

    private func summary(_ row: Row, rows: [Row], project: ProjectRef) -> TrackerTaskSummary {
        let b = row.record.body
        let criteria = b.acceptanceCriteria ?? []
        return TrackerTaskSummary(
            id: row.key.display, title: row.task.taskDescription, status: row.status.rawValue,
            archived: !row.onBoard, priority: b.priority, type: b.type, labels: b.labels ?? [],
            assignee: b.assignee ?? [],
            dependencies: (b.dependencies ?? []).compactMap { dep in rows.first { $0.task.id == dep }?.key.display },
            parentTaskId: row.record.parentTaskId.flatMap { pid in rows.first { $0.task.id == pid }?.key.display },
            acceptanceCriteriaCompleted: criteria.filter(\.checked).count,
            acceptanceCriteriaCount: criteria.count,
            dueDate: row.task.dueAt.map { TrackerFormat.day($0) }, ordinal: row.record.ordinal,
            createdAt: row.task.createdAt, updatedAt: max(row.task.updatedAt, row.record.updatedAt),
            isReady: isReady(row, rows: rows), project: project.name,
            startedAt: row.status == .inProgress ? (b.holder?.since ?? row.record.startedAt) : nil,
            heldBy: row.status == .inProgress ? b.holder?.client : nil)
    }

    // MARK: - Which project (§5.2)

    struct ProjectRef: Equatable {
        let id: UUID
        let name: String
    }

    /// `write`: the request changes the project's tasks, so the folder is remembered for the project (D1) — a write
    /// that found it by name alone left another repository of that name matching it (Codex review P2-4).
    private func existingProject(_ folder: String, mctx: ModelContext, tctx: ModelContext,
                                 write: Bool = false) throws -> ProjectRef {
        guard let p = try resolve(folder: folder, create: false, mctx: mctx, tctx: tctx) else {
            throw TrackerFailure(.noProject, noProjectText(folder))
        }
        if write {
            let tracked = try tctx.fetch(FetchDescriptor<TrackedProject>())
            remember(ProjectNaming.trimmed(folder), for: p.id, tracked: tracked, tctx: tctx)
        }
        return p
    }

    /// The agent's project for `folder` (`findProject`), with the project's tasks numbered first: every agent request
    /// starts here, so an agent sees and can name exactly the tasks the user sees in that project (§9b).
    private func resolve(folder: String, create: Bool, mctx: ModelContext, tctx: ModelContext) throws -> ProjectRef? {
        guard let project = try findProject(folder: folder, create: create, mctx: mctx, tctx: tctx) else { return nil }
        try numberUnplacedTasks(of: project.id, folder: folder, mctx: mctx, tctx: tctx)
        return project
    }

    /// §9b — tasks in this project by the one rule (`TaskProjects`) that the tracker has not numbered yet (a call's
    /// task follows its conversation into the project) get their record and number now. A suggestion (draft) and a
    /// dropped task are not tasks and stay out. Once numbered, a task keeps its project and number.
    /// Numbering makes the project real, and `folder`'s from then on (D1): remembered in the same save as the first
    /// number, so a numbered project never lacks its folder (Codex review P2-4, re-review).
    @discardableResult
    private func numberUnplacedTasks(of projectId: UUID, folder: String, mctx: ModelContext,
                                     tctx: ModelContext) throws -> Int {
        guard (try? requireHealthy()) != nil else { return 0 }   // a store refusing writes: the agent reads what is there
        let members = TaskProjects.map(main: mctx, tracker: tctx).filter { $0.value == projectId }.map(\.key)
        guard !members.isEmpty else { return 0 }
        let records = try tctx.fetch(FetchDescriptor<TaskTrackerRecord>())
        let numbered = Set(records.filter { $0.projectId == projectId && $0.key != nil }.map(\.taskId))
        let missing = members.filter { !numbered.contains($0) }
        guard !missing.isEmpty else { return 0 }
        // Tasks on the board, and the tasks the Archive lists (a record and dismissed, by any path): an agent can see
        // and restore those too (Codex review P2-7). A dropped suggestion or junk (no record) stays out.
        let withRecord = Set(records.map(\.taskId))
        let tasks = try mctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { missing.contains($0.id) }))
            .filter { $0.isTask || (withRecord.contains($0.id) && Self.isInArchive($0)) }
            .sorted { $0.createdAt < $1.createdAt }
        if !tasks.isEmpty {
            let tracked = try tctx.fetch(FetchDescriptor<TrackedProject>())
            remember(ProjectNaming.trimmed(folder), for: projectId, tracked: tracked, tctx: tctx)
        }
        for task in tasks {
            let record = records.first { $0.taskId == task.id } ?? {
                let r = TaskTrackerRecord(taskId: task.id, projectId: nil, key: nil, body: TrackerTaskBody(), now: now())
                tctx.insert(r)
                return r
            }()
            try place(record, in: projectId, tctx: tctx, mctx: mctx)
            record.updatedAt = now()
            try tctx.save()   // one at a time: the next number is counted from saved records
        }
        revision &+= 1
        return tasks.count
    }

    /// Remembered folder → project; else a project of the folder's name (canonical or alias, normalized); else, on
    /// a write, a new project named after the folder. A write remembers the folder and makes the project real (D1).
    /// The caller saves both contexts.
    private func findProject(folder: String, create: Bool, mctx: ModelContext, tctx: ModelContext) throws -> ProjectRef? {
        let root = ProjectNaming.trimmed(folder)
        guard root.hasPrefix("/") else { throw TrackerFailure.validation("The working folder must be an absolute path.") }
        let tracked = try tctx.fetch(FetchDescriptor<TrackedProject>())
        let aliases = try mctx.fetch(FetchDescriptor<ProjectAlias>())
        let aliasById = Dictionary(aliases.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let remembered = tracked.flatMap { t in t.folders.filter { ProjectNaming.folder($0, covers: root) }.map { (t, $0) } }
            .filter { aliasById[$0.0.projectId] != nil }
            .max { $0.1.count < $1.1.count }
        if let hit = remembered, let alias = aliasById[hit.0.projectId] {
            return ProjectRef(id: alias.id, name: alias.canonicalName)
        }

        if ProjectNaming.isRefusedFolder(root, home: home) {
            guard create else { return nil }
            throw TrackerFailure(.noProject, "\(root) cannot be a project's folder. Work from the project's own "
                                 + "folder (a repository or a project directory).")
        }

        let name = ProjectNaming.projectName(forFolder: root)
        let wanted = ProjectNaming.normalized(name)
        let trackedIds = Set(tracked.map(\.projectId))
        // A tracked project whose remembered folder still exists somewhere else belongs to that other repository of
        // the same name (review P2-8); one whose folders are all gone was moved or renamed (C4) and may match. Only
        // projects of this name have their folders looked at (round 2, N2: no disk walk over every project).
        let named = aliases.filter { a in
            ProjectNaming.normalized(a.canonicalName) == wanted
                || a.aliases.contains { ProjectNaming.normalized($0) == wanted }
        }
        let namedIds = Set(named.map(\.id))
        let elsewhere = Set(tracked.filter { t in
            namedIds.contains(t.projectId) && t.folders.contains { FileManager.default.fileExists(atPath: $0) }
        }.map(\.projectId))
        let candidates = named.filter { !elsewhere.contains($0.id) }.sorted { a, b in
            let ta = trackedIds.contains(a.id), tb = trackedIds.contains(b.id)
            if ta != tb { return ta }
            let ca = ProjectNaming.normalized(a.canonicalName) == wanted
            let cb = ProjectNaming.normalized(b.canonicalName) == wanted
            if ca != cb { return ca }
            return a.updatedAt > b.updatedAt
        }
        if let alias = candidates.first {
            if create { remember(root, for: alias.id, tracked: tracked, tctx: tctx) }
            return ProjectRef(id: alias.id, name: alias.canonicalName)
        }
        guard create else { return nil }
        // Another repository already has this name: tell the two apart by the parent folder, "web (b)".
        let taken = aliases.contains { ProjectNaming.normalized($0.canonicalName) == wanted }
        let parent = URL(fileURLWithPath: root).deletingLastPathComponent().lastPathComponent
        let alias = ProjectAlias(canonicalName: taken && !parent.isEmpty ? "\(name) (\(parent))" : name)
        mctx.insert(alias)
        tctx.insert(TrackedProject(projectId: alias.id, origin: .agent, folders: [root], now: now()))
        return ProjectRef(id: alias.id, name: alias.canonicalName)
    }

    private func remember(_ root: String, for projectId: UUID, tracked: [TrackedProject], tctx: ModelContext) {
        if let t = tracked.first(where: { $0.projectId == projectId }) {
            if !t.folders.contains(root) { t.folders.append(root); t.updatedAt = now() }
        } else {
            tctx.insert(TrackedProject(projectId: projectId, origin: .agent, folders: [root], now: now()))
        }
    }

    // MARK: - Helpers

    func requireHealthy() throws {
        guard StoreHealthSignal.shared.isHealthy else {
            throw TrackerFailure(.internalError, "MetaWhisp's database is not available right now (temporary "
                                 + "session); nothing was written.")
        }
    }

    /// Runs a main-store write; a refused save becomes a tracker error.
    func write(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch MutationError.storeDegraded {
            throw TrackerFailure(.internalError, "MetaWhisp's database is not available right now; nothing was written.")
        }
    }

    func checklist(_ body: () throws -> [ChecklistItem]) throws -> [ChecklistItem] {
        do { return try body() } catch let e as ChecklistError { throw TrackerFailure.validation(e.message) }
    }

    private func resolveDependencies(_ raws: [String], rows: [Row], owner: Row?) throws -> [UUID] {
        var ids: [UUID] = []
        var missing: [String] = []
        for raw in raws {
            guard let dep = find(raw, in: rows) else {
                missing.append(TrackerKey(parsing: raw)?.display ?? raw)
                continue
            }
            if let owner, dep.task.id == owner.task.id {
                throw TrackerFailure.validation("Task \(owner.key.display) cannot depend on itself.")
            }
            if !ids.contains(dep.task.id) { ids.append(dep.task.id) }
        }
        if !missing.isEmpty {
            throw TrackerFailure.validation("The following dependencies do not exist: \(missing.joined(separator: ", ")). "
                                            + "Create these tasks first or check the IDs.")
        }
        if let owner {
            var graph = Dictionary(rows.map { ($0.task.id, $0.record.body.dependencies ?? []) },
                                   uniquingKeysWith: { a, _ in a })
            graph[owner.task.id] = []
            if let loop = DependencyGraph.cycle(adding: ids, to: owner.task.id, graph: graph) {
                let names = loop.map { id in rows.first { $0.task.id == id }?.key.display ?? "?" }
                throw TrackerFailure.validation("These dependencies would create a cycle: "
                                                + names.joined(separator: " -> "))
            }
        }
        return ids
    }

    /// Applies a column to the pair (§3.3).
    static func move(_ task: TaskItem, _ record: TaskTrackerRecord, to status: TrackerStatus, at t: Date) {
        switch status {
        case .toDo:
            task.completed = false
            task.completedAt = nil
            record.startedAt = nil
        case .inProgress:
            task.completed = false
            task.completedAt = nil
            if record.startedAt == nil { record.startedAt = t }
        case .done:
            if !task.completed {
                task.completed = true
                task.completedAt = t
            }
        }
    }

    /// A due day as noon UTC: its UTC date is the day, whatever zone wrote or reads it (an agent's `dueDate`). The app
    /// shows it through `TaskDue.localDay`, the same day on the Mac's clock.
    static func dueDate(_ day: String?) -> Date? {
        guard let day else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: day + " 12:00")
    }

    private static func mergedList(_ current: [String]?, set: [String]?, add: [String], remove: [String]) -> [String]? {
        var out = set ?? current ?? []
        for a in add where !out.contains(a) { out.append(a) }
        out.removeAll { remove.contains($0) }
        return out.nilIfEmpty
    }

    private static func text(_ current: String?, clear: Bool, set: String?, append: [String]) -> String? {
        var out = clear ? nil : current
        if let set { out = set.isEmpty ? nil : set }
        if !append.isEmpty { out = ([out].compactMap { $0 } + append).joined(separator: "\n\n") }
        return out
    }

    private func unique(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.filter { seen.insert($0.lowercased()).inserted }
    }
}

private extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
