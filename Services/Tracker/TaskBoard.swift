import Foundation
import MetaWhispTrackerKit
import SwiftData

/// FEAT-0006 §9 (D2) — what the Tasks window shows: every task the user has (agent tasks with their project and
/// `TASK-n`, and plain voice / call / chat tasks), as a board of three columns or one list. Drafts stay in the
/// Suggested strip (FEAT-0005).
enum TaskBoard {

    enum ProjectFilter: Hashable {
        case all
        /// Tasks of no project.
        case none
        case project(UUID)
    }

    struct Card: Identifiable, Equatable {
        let id: UUID
        let title: String
        /// `TASK-n` within its project; nil for a task of no project.
        let key: String?
        let projectId: UUID?
        let projectName: String?
        let status: TrackerStatus
        let archived: Bool
        let priority: TrackerPriority?
        let labels: [String]
        let criteriaDone: Int
        let criteriaCount: Int
        let dueAt: Date?
        /// An agent's due day, not a moment: "Today" all that day.
        let dueIsDay: Bool
        let createdAt: Date
        let ordinal: Double?
        let source: String?
    }

    struct Column: Equatable {
        let status: TrackerStatus
        let cards: [Card]
    }

    static func columns(_ cards: [Card]) -> [Column] {
        TrackerStatus.allCases.map { s in Column(status: s, cards: cards.filter { $0.status == s }) }
    }

    /// Keyed tasks in board order (ordinal, priority, number); tasks without a number after them: those with a due
    /// date first, earliest first (an overdue one on top), then the rest newest first (UI review 2026-11-27, #3).
    static func precedes(_ a: Card, _ b: Card) -> Bool {
        let ka = a.key.flatMap(TrackerKey.init(parsing:)), kb = b.key.flatMap(TrackerKey.init(parsing:))
        let ta = ka != nil || a.ordinal != nil, tb = kb != nil || b.ordinal != nil
        if ta != tb { return ta }
        if ta {
            return TrackerSortKey.precedes(
                TrackerSortKey(ordinal: a.ordinal, priority: a.priority, key: ka, createdAt: a.createdAt),
                TrackerSortKey(ordinal: b.ordinal, priority: b.priority, key: kb, createdAt: b.createdAt))
        }
        switch (a.dueAt, b.dueAt) {
        case let (da?, db?) where da != db: return da < db
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.createdAt > b.createdAt
        }
    }
}

/// How a task's due date reads on a card: the date itself (never a bare "Overdue"), and its tone. A finished task is
/// never shown late (UI review 2026-11-27, #3).
enum TaskDue {
    enum Tone: Equatable { case plain, today, late }

    /// `isDay`: an agent's due day (stored at noon) is "Today" all that day.
    static func label(_ date: Date, isDay: Bool, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// A stored due day (noon UTC, `TrackerService.dueDate`) as that same day at noon on the user's clock: what the
    /// card, its label and the date picker show. Read as an instant it was the next day east of UTC+12 (NZ summer;
    /// Codex review P2-15); kept as the UTC date, it stays its day when the Mac changes time zone.
    static func localDay(_ stored: Date, calendar: Calendar = .current) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let d = utc.dateComponents([.year, .month, .day], from: stored)
        return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12)) ?? stored
    }

    /// The calendar day a picked date names where the user is, as the tracker stores days (`yyyy-MM-dd`).
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func tone(_ date: Date, isDay: Bool, done: Bool, now: Date = Date(), calendar: Calendar = .current) -> Tone {
        if done { return .plain }
        let today = calendar.isDate(date, inSameDayAs: now)
        if isDay { return today ? .today : (date < now ? .late : .plain) }
        if date < now { return .late }
        return today ? .today : .plain
    }
}

extension TrackerService {

    /// A task with a tracker record is in the Archive when it was dismissed by any path (the window, MetaChat, an
    /// agent); a suggestion never is. The Archive lists by this and agents number by it, so both see the same tasks.
    static func isInArchive(_ task: TaskItem) -> Bool {
        task.effectiveStatus != "staged" && (task.isDismissed || task.effectiveStatus == "dismissed")
    }

    /// The cards of the Tasks window. `archived`: the archive instead of the board — tracker tasks that were
    /// archived; the dismissed tasks of before the tracker (no record) never show.
    func boardCards(filter: TaskBoard.ProjectFilter, archived: Bool) -> [TaskBoard.Card] {
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        let records = (try? tctx.fetch(FetchDescriptor<TaskTrackerRecord>())) ?? []
        let byTask = Dictionary(records.map { ($0.taskId, $0) }, uniquingKeysWith: { a, _ in a })
        let names = Dictionary(((try? mctx.fetch(FetchDescriptor<ProjectAlias>())) ?? []).map { ($0.id, $0.canonicalName) },
                               uniquingKeysWith: { a, _ in a })
        let tasks: [TaskItem]
        if archived {
            let ids = records.map(\.taskId)
            tasks = ((try? mctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { ids.contains($0.id) }))) ?? [])
                .filter(Self.isInArchive)
        } else {
            tasks = ((try? mctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate {
                // A legacy row has no status (it counts as committed); `!= "dismissed"` alone is false for NULL in
                // the store's query and dropped it (Codex review P2-6).
                !$0.isDismissed && ($0.status == nil || $0.status != "dismissed")
            }))) ?? []).filter(\.isTask)
        }
        // §9b — one rule for a task's project, the same the Projects list counts by.
        let projectOf = TaskProjects.map(main: mctx, tracker: tctx)
        return tasks.compactMap { task -> TaskBoard.Card? in
            let record = byTask[task.id]
            let projectId = projectOf[task.id]
            switch filter {
            case .all: break
            case .none: if projectId != nil { return nil }
            case .project(let id): if projectId != id { return nil }
            }
            return card(task, record, projectId: projectId, names: names)
        }.sorted(by: TaskBoard.precedes)
    }

    private func card(_ task: TaskItem, _ record: TaskTrackerRecord?, projectId: UUID?,
                      names: [UUID: String]) -> TaskBoard.Card {
        let body = record?.body ?? TrackerTaskBody()
        let criteria = body.acceptanceCriteria ?? []
        return TaskBoard.Card(
            id: task.id, title: task.taskDescription,
            // A number belongs to the project the record placed the task in.
            key: projectId != nil && record?.projectId == projectId ? record?.trackerKey?.display : nil,
            projectId: projectId, projectName: projectId.flatMap { names[$0] },
            status: task.completed ? .done : (record?.startedAt != nil ? .inProgress : .toDo),
            archived: task.isDismissed || task.effectiveStatus == "dismissed",
            priority: body.priority.flatMap(TrackerPriority.init(rawValue:)), labels: body.labels ?? [],
            criteriaDone: criteria.filter(\.checked).count, criteriaCount: criteria.count,
            dueAt: body.dueIsDay == true ? task.dueAt.map { TaskDue.localDay($0) } : task.dueAt,
            dueIsDay: body.dueIsDay == true, createdAt: task.createdAt,
            ordinal: projectId != nil && record?.projectId == projectId ? record?.ordinal : nil,
            // Who made it when an agent did; a call's or a dictation's task links its conversation in the sheet.
            source: body.createdBy.flatMap { $0 == "user" ? nil : $0 })
    }

    /// Tasks the tracker holds (on the board or archived): the user's, whatever made them (review P3-14).
    func recordedTaskIds() -> Set<UUID> {
        Set(((try? Self.freshContext(tracker).fetch(FetchDescriptor<TaskTrackerRecord>())) ?? []).map(\.taskId))
    }

    /// §9b — the projects a task can be put in: every project in the Projects list (an archived one is not, Q4).
    func projectChoices() -> [(id: UUID, name: String)] {
        let archived = archivedProjectIds()
        return ((try? Self.freshContext(main).fetch(FetchDescriptor<ProjectAlias>())) ?? [])
            .filter { !archived.contains($0.id) }
            .map { (id: $0.id, name: $0.canonicalName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// T4 — the user makes a project by hand. A project of the same name (normalized) is reused and made real.
    @discardableResult
    func createProject(name raw: String, origin: TrackedProjectOrigin = .user) throws -> UUID {
        try requireHealthy()
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TrackerFailure.validation("A project needs a name.") }
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        let wanted = ProjectNaming.normalized(name)
        let aliases = try mctx.fetch(FetchDescriptor<ProjectAlias>())
        let alias = aliases.first { ProjectNaming.normalized($0.canonicalName) == wanted }
            ?? aliases.first { $0.aliases.contains { ProjectNaming.normalized($0) == wanted } }
            ?? { () -> ProjectAlias in
                let a = ProjectAlias(canonicalName: name)
                mctx.insert(a)
                return a
            }()
        try mctx.save()
        if try tctx.fetch(FetchDescriptor<TrackedProject>()).first(where: { $0.projectId == alias.id }) == nil {
            tctx.insert(TrackedProject(projectId: alias.id, origin: origin, folders: [], now: now()))
            try tctx.save()
        }
        revision &+= 1
        return alias.id
    }

    /// D7 — a project the user named: the one of that name (normalized; a real one first), and the real projects
    /// of a similar name.
    func projectMatch(name: String) -> (exact: (id: UUID, name: String)?, similar: [String]) {
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        let tracked = Set(((try? tctx.fetch(FetchDescriptor<TrackedProject>())) ?? []).map(\.projectId))
        let aliases = ((try? mctx.fetch(FetchDescriptor<ProjectAlias>())) ?? [])
            .sorted { tracked.contains($0.id) && !tracked.contains($1.id) }
        let wanted = ProjectNaming.normalized(name)
        guard !wanted.isEmpty else { return (nil, []) }
        let exact = aliases.first { ProjectNaming.normalized($0.canonicalName) == wanted }
            ?? aliases.first { $0.aliases.contains { ProjectNaming.normalized($0) == wanted } }
        let similar = aliases.filter { tracked.contains($0.id) && $0.id != exact?.id }
            .filter { ProjectNaming.isSimilar($0.canonicalName, name) }
            .map(\.canonicalName).sorted()
        return (exact.map { (id: $0.id, name: $0.canonicalName) }, similar)
    }

    /// The user's new task, in a project (with the next `TASK-n`) or in none.
    @discardableResult
    func createTask(title raw: String, projectId: UUID?) throws -> UUID {
        try requireHealthy()
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw TrackerFailure.validation("A task needs a title.") }
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        let t = now()
        let task = TaskItem(taskDescription: String(title.prefix(200)), sourceApp: "MetaWhisp", status: "committed")
        task.createdAt = t
        task.updatedAt = t
        var body = TrackerTaskBody()
        body.createdBy = "user"
        let record = TaskTrackerRecord(taskId: task.id, projectId: nil, key: nil, body: body, now: t)
        if let projectId {
            try place(record, in: projectId, tctx: tctx, mctx: mctx)
            try bringBack(projectId, tctx: tctx)   // a task put in a project brings it back (Q4)
        }
        try write { try mutations.insert(task, in: mctx) }
        tctx.insert(record)
        try tctx.save()
        revision &+= 1
        return task.id
    }

    /// C21 — a task moved into a project gets that project's next number; out of every project, none.
    func setProject(taskId: UUID, projectId: UUID?) throws {
        try requireHealthy()
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        guard let task = try fetchTask(taskId, mctx), task.effectiveStatus != "staged" else {
            throw TrackerFailure(.taskNotFound, "That task is gone.")
        }
        let record = try fetchRecord(taskId, tctx) ?? { () -> TaskTrackerRecord in
            let r = TaskTrackerRecord(taskId: taskId, projectId: nil, key: nil, body: TrackerTaskBody(), now: now())
            tctx.insert(r)
            return r
        }()
        guard record.projectId != projectId else { return }
        // No link crosses a project (review P2-7): it leaves its parent and its dependencies behind, its subtasks
        // stay unparented, and the tasks that waited on it stop waiting.
        record.parentTaskId = nil
        var body = record.body
        body.dependencies = nil
        record.body = body
        for other in try tctx.fetch(FetchDescriptor<TaskTrackerRecord>()) where other.taskId != taskId {
            var changed = false
            if other.parentTaskId == taskId { other.parentTaskId = nil; changed = true }
            var otherBody = other.body
            if let deps = otherBody.dependencies, deps.contains(taskId) {
                otherBody.dependencies = deps.filter { $0 != taskId }
                if otherBody.dependencies?.isEmpty == true { otherBody.dependencies = nil }
                other.body = otherBody
                changed = true
            }
            if changed { other.updatedAt = now() }
        }
        if let projectId {
            try place(record, in: projectId, tctx: tctx, mctx: mctx)
            try bringBack(projectId, tctx: tctx)   // a task put in a project brings it back (Q4)
        } else {
            record.projectId = nil
            record.key = nil
            record.ordinal = nil
        }
        record.updatedAt = now()
        try tctx.save()
        revision &+= 1
    }

    /// A due date set in the task window: unchanged, cleared, or a day (`yyyy-MM-dd`, stored as an agent's day is).
    enum DueEdit: Equatable { case unchanged, clear, day(String) }
    /// A priority set in the task window: unchanged, or set (nil clears it).
    enum PriorityEdit: Equatable { case unchanged, set(TrackerPriority?) }

    /// Owner 2026-11-27 (Q1) — the user fixes a task in its window: its title, due day, priority. One write on fresh
    /// fetches by id, the same fields an agent's `task_edit` writes.
    func editFromApp(taskId: UUID, title rawTitle: String? = nil, due: DueEdit = .unchanged,
                     priority: PriorityEdit = .unchanged) throws {
        try requireHealthy()
        let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, title.isEmpty { throw TrackerFailure.validation("A task needs a title.") }
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        guard let task = try fetchTask(taskId, mctx), task.effectiveStatus != "staged" else {
            throw TrackerFailure(.taskNotFound, "That task is gone.")
        }
        let t = now()
        if title != nil || due != .unchanged {
            try write {
                try mutations.commit(.taskSaved(taskId), in: mctx) {
                    if let title { task.taskDescription = String(title.prefix(200)) }
                    switch due {
                    case .unchanged: break
                    case .clear: task.dueAt = nil
                    case .day(let day): task.dueAt = Self.dueDate(day)
                    }
                    task.updatedAt = t
                }
            }
        }
        if due != .unchanged || priority != .unchanged {
            let record = try fetchRecord(taskId, tctx) ?? { () -> TaskTrackerRecord in
                let r = TaskTrackerRecord(taskId: taskId, projectId: nil, key: nil, body: TrackerTaskBody(), now: t)
                tctx.insert(r)
                return r
            }()
            var body = record.body
            switch due {
            case .unchanged: break
            case .clear: body.dueIsDay = nil
            case .day: body.dueIsDay = true
            }
            if case .set(let p) = priority { body.priority = p?.rawValue }
            record.body = body
            record.updatedAt = t
            try tctx.save()
        }
        revision &+= 1
    }

    func move(taskId: UUID, to status: TrackerStatus) throws {
        try requireHealthy()
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        guard let task = try fetchTask(taskId, mctx), task.isTask else {
            throw TrackerFailure.validation("Only a task on the board can move; a suggestion is accepted first.")
        }
        let record = try fetchRecord(taskId, tctx) ?? { () -> TaskTrackerRecord in
            let r = TaskTrackerRecord(taskId: taskId, projectId: nil, key: nil, body: TrackerTaskBody(), now: now())
            tctx.insert(r)
            return r
        }()
        let t = now()
        let from = record.column(of: task)
        try write {
            try mutations.commit(.taskSaved(taskId), in: mctx) {
                Self.move(task, record, to: status, at: t)
                task.updatedAt = t
            }
        }
        record.noteMove(from: from.rawValue, to: status.rawValue, by: "user", at: t)
        // Q2 — the user moving a task out of In Progress frees it for any agent.
        if status != .inProgress { record.clearHolder() }
        record.updatedAt = t
        try tctx.save()
        revision &+= 1
    }

    /// `by`: who put it away, for the agents' history (the user, or MetaWhisp itself).
    func archive(taskId: UUID, by: String = "user") throws {
        try requireHealthy()
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        guard let task = try fetchTask(taskId, mctx), task.isTask else {
            throw TrackerFailure.validation("Only a task on the board can be archived.")
        }
        let record = try fetchRecord(taskId, tctx) ?? { () -> TaskTrackerRecord in
            let r = TaskTrackerRecord(taskId: taskId, projectId: nil, key: nil, body: TrackerTaskBody(), now: now())
            tctx.insert(r)
            return r
        }()
        let t = now()
        // The record first (Codex review P1-1): the Archive lists a task by its record, so a task dismissed without
        // one would be on neither the board nor the Archive. If the task's own save then fails, the record is put
        // back as it was.
        let wasArchivedAt = record.archivedAt, wasBody = record.body, wasUpdatedAt = record.updatedAt
        record.archivedAt = t
        record.noteMove(from: record.column(of: task).rawValue, to: "Archived", by: by, at: t)
        record.clearHolder()
        record.updatedAt = t
        try saveTracker(tctx)
        do {
            try write {
                try mutations.commit(.taskDismissed(taskId), in: mctx) {
                    task.status = "dismissed"
                    task.isDismissed = true
                    task.updatedAt = t
                }
            }
        } catch {
            record.archivedAt = wasArchivedAt
            record.body = wasBody
            record.updatedAt = wasUpdatedAt
            try? saveTracker(tctx)
            throw error
        }
        revision &+= 1
    }

    func restore(taskId: UUID) throws {
        try requireHealthy()
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        guard let task = try fetchTask(taskId, mctx), let record = try fetchRecord(taskId, tctx),
              task.isDismissed || task.effectiveStatus == "dismissed" else {
            throw TrackerFailure.validation("Only an archived task can be restored.")
        }
        let t = now()
        try write {
            try mutations.commit(.taskSaved(taskId), in: mctx) {
                task.status = "committed"
                task.isDismissed = false
                task.updatedAt = t
            }
        }
        record.archivedAt = nil
        record.noteMove(from: "Archived", to: record.column(of: task).rawValue, by: "user", at: t)
        record.updatedAt = t
        try tctx.save()
        revision &+= 1
    }

    /// The window's Delete forever, after its own confirmation: archived tasks only, never with subtasks.
    func deleteForever(taskId: UUID) throws {
        try requireHealthy()
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        guard let task = try fetchTask(taskId, mctx), let record = try fetchRecord(taskId, tctx),
              task.isDismissed || task.effectiveStatus == "dismissed" else {
            throw TrackerFailure.validation("Only an archived task can be deleted forever.")
        }
        let all = try tctx.fetch(FetchDescriptor<TaskTrackerRecord>())
        guard !all.contains(where: { $0.parentTaskId == taskId }) else {
            throw TrackerFailure.validation("A task with subtasks cannot be deleted.")
        }
        for other in all where other.taskId != taskId {
            var body = other.body
            guard let deps = body.dependencies, deps.contains(taskId) else { continue }
            body.dependencies = deps.filter { $0 != taskId }
            if body.dependencies?.isEmpty == true { body.dependencies = nil }
            other.body = body
            other.updatedAt = now()
        }
        // The links go first, so a refused main delete never leaves a dependency on a task that is gone (P3-12).
        try tctx.save()
        try write { try mutations.hardDelete(task, in: mctx) }
        tctx.delete(record)
        try tctx.save()
        revision &+= 1
    }

    /// The sheet names the criterion it shows (index and text): an agent may have changed the list since, and a
    /// tick must never land on another criterion (review P1-3).
    func toggleCriterion(taskId: UUID, index: Int, expectedText: String) throws {
        try requireHealthy()
        let tctx = Self.freshContext(tracker)
        guard let record = try fetchRecord(taskId, tctx) else { throw TrackerFailure.validation("No criteria.") }
        var body = record.body
        var list = body.acceptanceCriteria ?? []
        guard index >= 1, index <= list.count, list[index - 1].text == expectedText else {
            throw TrackerFailure.validation("The criteria changed meanwhile; look again.")
        }
        list[index - 1].checked.toggle()
        body.acceptanceCriteria = list
        record.body = body
        record.updatedAt = now()
        try tctx.save()
        revision &+= 1
    }

    struct TaskDetailValue {
        let card: TaskBoard.Card
        /// The tracker record in full: a task of a project with its links, any other with what its record holds.
        let detail: TrackerTaskDetail?
        /// The call or dictation the task came from: "Call X" is only actionable next to its call (UI review #1).
        var conversation: (id: UUID, title: String, date: Date)? = nil
    }

    func detail(taskId: UUID) -> TaskDetailValue? {
        let mctx = Self.freshContext(main), tctx = Self.freshContext(tracker)
        guard let task = try? fetchTask(taskId, mctx) else { return nil }
        let record = (try? fetchRecord(taskId, tctx)) ?? nil
        let names = Dictionary(((try? mctx.fetch(FetchDescriptor<ProjectAlias>())) ?? []).map { ($0.id, $0.canonicalName) },
                               uniquingKeysWith: { a, _ in a })
        let projectId = TaskProjects.map(main: mctx, tracker: tctx)[taskId]   // §9b, as the board shows it
        let card = card(task, record, projectId: projectId, names: names)
        var full: TrackerTaskDetail?
        if let projectId, let name = names[projectId],
           let rows = try? loadRows(projectId, mctx: mctx, tctx: tctx),
           let row = rows.first(where: { $0.task.id == taskId }) {
            full = detail(row, rows: rows, project: ProjectRef(id: projectId, name: name))
        } else if let record {
            full = detail(of: task, record: record, archived: card.archived)
        }
        var from: (id: UUID, title: String, date: Date)?
        if let cid = task.conversationId {
            var d = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid })
            d.fetchLimit = 1
            d.propertiesToFetch = [\.id, \.title, \.startedAt]
            if let c = try? mctx.fetch(d).first {
                from = (c.id, c.title?.isEmpty == false ? c.title! : "Untitled conversation", c.startedAt)
            }
        }
        return TaskDetailValue(card: card, detail: full, conversation: from)
    }

    // MARK: - Helpers

    private func fetchTask(_ id: UUID, _ ctx: ModelContext) throws -> TaskItem? {
        var d = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try ctx.fetch(d).first
    }

    private func fetchRecord(_ taskId: UUID, _ ctx: ModelContext) throws -> TaskTrackerRecord? {
        var d = FetchDescriptor<TaskTrackerRecord>(predicate: #Predicate { $0.taskId == taskId })
        d.fetchLimit = 1
        return try ctx.fetch(d).first
    }

    /// Gives the record the project's next number and ordinal, and makes the project real (origin user).
    /// Puts `record` in the project with its next `TASK-n` and an ordinal at the end; makes the project real.
    func place(_ record: TaskTrackerRecord, in projectId: UUID, tctx: ModelContext, mctx: ModelContext) throws {
        let pid: UUID? = projectId
        guard try mctx.fetch(FetchDescriptor<ProjectAlias>(predicate: #Predicate { $0.id == projectId })).first != nil else {
            throw TrackerFailure(.noProject, "That project is gone.")
        }
        let others = try tctx.fetch(FetchDescriptor<TaskTrackerRecord>(predicate: #Predicate { $0.projectId == pid }))
            .filter { $0.taskId != record.taskId }
        record.projectId = projectId
        record.key = TrackerKey.nextTopLevel(existing: others.compactMap(\.trackerKey)).stored
        record.ordinal = TrackerSortKey.newOrdinal(existing: others.map(\.ordinal), boardIsEmpty: others.isEmpty)
        if try tctx.fetch(FetchDescriptor<TrackedProject>()).first(where: { $0.projectId == projectId }) == nil {
            tctx.insert(TrackedProject(projectId: projectId, origin: .user, folders: [], now: now()))
        }
    }
}
