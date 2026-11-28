import SwiftData
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// Codex review of the whole tracker branch (2026-11-27): each finding reproduced here before its fix.
@MainActor
final class CodexReviewFixTests: XCTestCase {

    private var dir: URL!
    private var main: ModelContainer!
    private var tracker: ModelContainer!
    private var service: TrackerService!
    private var aggregator: ProjectAggregator!
    private var acme: String { dir.appendingPathComponent("Code/Acme").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-fix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        main = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self,
                                  configurations: [ModelConfiguration(schema: schema, url: dir.appendingPathComponent("M.store"))])
        tracker = try TrackerStore.makeContainer(url: dir.appendingPathComponent("T.store"))
        service = makeService()
        aggregator = ProjectAggregator()
        aggregator.configure(modelContainer: main, trackerContainer: tracker)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeService(saveTracker: @escaping (ModelContext) throws -> Void = { try $0.save() }) -> TrackerService {
        TrackerService(main: main, tracker: tracker, mutations: MutationService(runHooks: { _ in }), home: dir.path,
                       saveTracker: saveTracker)
    }

    private func plainTask(_ title: String) throws -> UUID {
        let ctx = ModelContext(main)
        let t = TaskItem(taskDescription: title, sourceApp: "meeting")
        ctx.insert(t)
        try ctx.save()
        return t.id
    }

    // MARK: - P1-1 a failed archive never loses the task

    /// The tracker's save fails while archiving a plain task: the task stays on the board, not dismissed without
    /// the record the Archive lists it by.
    func testAFailedTrackerSaveLeavesTheTaskOnTheBoard() throws {
        let id = try plainTask("Call the bank")
        struct Refused: Error {}
        let failing = makeService(saveTracker: { _ in throw Refused() })
        XCTAssertThrowsError(try failing.archive(taskId: id))
        XCTAssertEqual(service.boardCards(filter: .all, archived: false).map(\.id), [id], "still on the board")
        let task = try XCTUnwrap(try ModelContext(main).fetch(FetchDescriptor<TaskItem>()).first)
        XCTAssertFalse(task.isDismissed)
    }

    /// Every context the tracker makes saves only what its operation saves. With autosave on, the context of this
    /// failed archive was written later, during another test's window work (10 store-open and save errors in the
    /// render tests that followed; 0 with it off). The trigger is AppKit's, so the setting itself is what is tested.
    func testTheTrackersContextsDoNotAutosave() {
        XCTAssertFalse(TrackerService.freshContext(main).autosaveEnabled)
        XCTAssertFalse(TrackerService.freshContext(tracker).autosaveEnabled)
    }

    // MARK: - P1-2 an unmatched block never costs the user's text

    func testAStartWithoutEndBeforeAnotherBlockLeavesTheFileAlone() {
        let text = """
        # My rules

        \(TrackerGuides.blockStart)
        half a block

        My own text that must stay.

        \(TrackerGuides.blockStart)
        a whole block
        \(TrackerGuides.blockEnd)
        """
        guard case .refused = AgentInstructionsFile.remove(text) else { return XCTFail("removal must refuse") }
        guard case .refused = AgentInstructionsFile.install(text) else { return XCTFail("install must refuse") }
    }

    /// A row the cleanup could not put away keeps it from being marked done: the next launch tries again.
    func testTheWaitingOnCleanupIsNotDoneWhileARowFailed() throws {
        let ctx = ModelContext(main)
        ctx.insert(TaskItem(taskDescription: "Send the revised budget", sourceApp: "meeting", assignee: "Maya"))
        try ctx.save()
        let suite = "codex-fix-cleanup"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        struct Refused: Error {}
        let failing = makeService(saveTracker: { _ in throw Refused() })
        XCTAssertThrowsError(try WaitingOnCleanup.runOnce(service: failing, defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: WaitingOnCleanup.doneKey))
        XCTAssertEqual(try WaitingOnCleanup.runOnce(service: service, defaults: defaults), 1, "the next launch does it")
    }

    // MARK: - P2-3 a task taken again after MetaChat's complete is the new session's

    private func move(_ id: String, _ status: TrackerStatus, session: String, client: String = "Claude Code") throws {
        var e = TaskEditInput(id: id)
        e.status = status
        _ = try service.edit(e, folder: acme, client: client, session: session)
    }

    func testATaskReopenedAfterMetaChatFinishedItIsTheReopeningSessions() throws {
        let id = try service.create(TaskCreateInput(title: "Ship it"), folder: acme, client: "Claude Code",
                                    session: "one").summary.id
        try move(id, .inProgress, session: "one")
        // MetaChat's complete changes the task alone, as ChatToolExecutor's completeTask does.
        let ctx = ModelContext(main)
        try XCTUnwrap(try ctx.fetch(FetchDescriptor<TaskItem>()).first).completed = true
        try ctx.save()
        try move(id, .inProgress, session: "two")
        XCTAssertNoThrow(try move(id, .done, session: "two"), "the session that took it finishes it")
    }

    // MARK: - P2-4 a write remembers the agent's folder

    private func folder(_ path: String) throws -> String {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// A project the user made has no folder; an agent's edit from /A/Acme makes it that repository's, so another
    /// repository of the same name gets a project of its own.
    func testAnEditFromAFolderMakesTheProjectThatFoldersOwn() throws {
        let a = try folder("A/Acme"), b = try folder("B/Acme")
        let acmeId = try service.createProject(name: "Acme")
        _ = try service.createTask(title: "Write the plan", projectId: acmeId)
        var e = TaskEditInput(id: "TASK-1")
        e.notesAppend = ["Started"]
        _ = try service.edit(e, folder: a, client: "Codex")
        _ = try service.create(TaskCreateInput(title: "Other repository"), folder: b, client: "Codex")
        XCTAssertEqual(try service.list(TaskListInput(), folder: a).tasks.map(\.title), ["Write the plan"])
        let other = try service.list(TaskListInput(), folder: b)
        XCTAssertNotEqual(other.project, "Acme")
        XCTAssertEqual(other.tasks.map(\.title), ["Other repository"])
    }

    /// The same when an agent's first look numbered a call's tasks: the project became real from that folder.
    func testNumberingACallsTasksMakesTheProjectThatFoldersOwn() throws {
        let a = try folder("A/Acme"), b = try folder("B/Acme")
        let ctx = ModelContext(main)
        ctx.insert(ProjectAlias(canonicalName: "Acme"))
        let call = Conversation(source: "meeting")
        call.primaryProject = "Acme"
        ctx.insert(call)
        let task = TaskItem(taskDescription: "Send the deck", sourceApp: "meeting")
        task.conversationId = call.id
        ctx.insert(task)
        try ctx.save()
        XCTAssertEqual(try service.list(TaskListInput(), folder: a).tasks.map(\.id), ["TASK-1"])
        _ = try service.create(TaskCreateInput(title: "Other repository"), folder: b, client: "Codex")
        XCTAssertEqual(try service.list(TaskListInput(), folder: b).tasks.map(\.title), ["Other repository"])
    }

    // MARK: - P2-5 an archived project is there to restore

    private func archivedNova() throws -> (nova: UUID, live: UUID) {
        let ctx = ModelContext(main)
        let nova = ProjectAlias(canonicalName: "Nova"), live = ProjectAlias(canonicalName: "NOVA")
        ctx.insert(nova)
        ctx.insert(live)
        try ctx.save()
        let tctx = ModelContext(tracker)
        tctx.insert(TrackedProject(projectId: live.id, origin: .user, folders: []))
        try tctx.save()
        try service.archiveProject(nova.id)
        return (nova.id, live.id)
    }

    private func projectIds() throws -> Set<UUID> {
        Set(try ModelContext(main).fetch(FetchDescriptor<ProjectAlias>()).map(\.id))
    }

    func testTheMergePassLeavesAnArchivedProjectAlone() async throws {
        let ids = try archivedNova()
        await aggregator.mergeAliases()
        XCTAssertEqual(try projectIds(), [ids.nova, ids.live])
    }

    func testThePrunePassLeavesAnArchivedProjectAlone() throws {
        let ids = try archivedNova()
        XCTAssertEqual(aggregator.pruneOrphanAliases(), 0, "an archived project without conversations stays")
        XCTAssertEqual(try projectIds(), [ids.nova, ids.live])
    }

    func testTheRenamePassLeavesAnArchivedProjectsName() throws {
        let ids = try archivedNova()
        let ctx = ModelContext(main)
        let nova = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ProjectAlias>()).first { $0.id == ids.nova })
        nova.addAlias("Nova Labs")
        for _ in 0..<2 {
            let c = Conversation(source: "meeting")
            c.primaryProject = "Nova Labs"
            ctx.insert(c)
        }
        try ctx.save()
        _ = aggregator.recanonicalizeAll()
        let name = try ModelContext(main).fetch(FetchDescriptor<ProjectAlias>()).first { $0.id == ids.nova }?.canonicalName
        XCTAssertEqual(name, "Nova")
    }

    // MARK: - P2-6 a legacy task without a status is on the board

    func testALegacyTaskWithoutAStatusIsOnTheBoard() throws {
        let ctx = ModelContext(main)
        let t = TaskItem(taskDescription: "An old task", sourceApp: "meeting")
        t.status = nil
        ctx.insert(t)
        try ctx.save()
        XCTAssertEqual(service.boardCards(filter: .all, archived: false).map(\.title), ["An old task"])
    }

    // MARK: - P2-7 a call's task archived in the app is the agent's to restore

    func testACallsTaskArchivedInTheAppIsTheAgentsToSeeAndRestore() throws {
        let ctx = ModelContext(main)
        ctx.insert(ProjectAlias(canonicalName: "Acme"))
        let call = Conversation(source: "meeting")
        call.primaryProject = "Acme"
        ctx.insert(call)
        let task = TaskItem(taskDescription: "Send the deck", sourceApp: "meeting")
        task.conversationId = call.id
        ctx.insert(task)
        let dropped = TaskItem(taskDescription: "A dropped suggestion", sourceApp: "meeting", status: "dismissed")
        dropped.conversationId = call.id
        dropped.isDismissed = true
        ctx.insert(dropped)
        try ctx.save()
        try service.archive(taskId: task.id)
        XCTAssertEqual(try service.view(id: "TASK-1", folder: acme).summary.title, "Send the deck")
        _ = try service.restore(id: "TASK-1", folder: acme, client: "Codex")
        XCTAssertEqual(service.boardCards(filter: .all, archived: false).map(\.id), [task.id])
        XCTAssertThrowsError(try service.view(id: "TASK-2", folder: acme), "a dropped suggestion gets no number")
    }

    // MARK: - P2-9 a regeneration keeps a conversation in its archived project

    func testARegenerationKeepsAConversationInItsArchivedProject() throws {
        let ctx = ModelContext(main)
        let nova = ProjectAlias(canonicalName: "Nova")
        nova.addAlias("Nova Labs")
        ctx.insert(nova)
        ctx.insert(ProjectAlias(canonicalName: "Acme"))
        try ctx.save()
        try service.archiveProject(nova.id)
        XCTAssertNil(aggregator.existingCanonical(for: "Nova"), "an archived project gets no new conversations")
        XCTAssertEqual(aggregator.projectAfterGeneration(proposed: nil, current: "Nova"), "Nova")
        XCTAssertEqual(aggregator.projectAfterGeneration(proposed: "Acme", current: "nova labs"), "nova labs",
                       "nor loses one, by a spelling too")
        XCTAssertEqual(aggregator.projectAfterGeneration(proposed: "Acme", current: "Acme Old"), "Acme",
                       "any other conversation takes the model's answer")
        XCTAssertNil(aggregator.projectAfterGeneration(proposed: nil, current: "Acme"))
    }

    /// The summary step writes the project through that rule.
    func testTheSummaryStepWritesTheProjectThroughTheRule() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized
        let generator = try String(contentsOf: root.appendingPathComponent("Services/Intelligence/StructuredGenerator.swift"),
                                   encoding: .utf8)
        XCTAssertTrue(generator.contains("target.primaryProject = projectAggregator?.projectAfterGeneration("))
        XCTAssertEqual(generator.components(separatedBy: "primaryProject = ").count - 1, 1,
                       "the one write of a generated conversation's project")
    }

    // MARK: - P2-10 the JSON an agent reads carries the revision

    func testTheJSONOfATaskCarriesItsExactRevision() throws {
        let created = try service.create(TaskCreateInput(title: "Ship it"), folder: acme, client: "Codex")
        let viewed = try service.view(id: created.summary.id, folder: acme)
        let json = try XCTUnwrap(JSONValue.encoding(viewed)?.objectValue?["summary"]?.objectValue)
        XCTAssertEqual(json["revision"]?.stringValue, viewed.summary.revision)
        var e = TaskEditInput(id: created.summary.id)
        e.notesAppend = ["Started"]
        e.expectedRevision = try XCTUnwrap(json["revision"]?.stringValue)
        XCTAssertNoThrow(try service.edit(e, folder: acme, client: "Codex"), "the token from the JSON is accepted")
    }

    // MARK: - both checklists take indexes of the list that results

    func testRemoveThenCheckTicksTheItemThatMovedUpInBothLists() throws {
        var input = TaskCreateInput(title: "Ship it")
        input.acceptanceCriteria = ["A", "B"]
        input.definitionOfDoneAdd = ["A", "B"]
        let id = try service.create(input, folder: acme, client: "Codex").summary.id
        var e = TaskEditInput(id: id)
        e.acceptanceCriteriaRemove = [1]
        e.acceptanceCriteriaCheck = [1]
        e.definitionOfDoneRemove = [1]
        e.definitionOfDoneCheck = [1]
        let d = try service.edit(e, folder: acme, client: "Codex")
        XCTAssertEqual(d.acceptanceCriteria.map { "\($0.text)\($0.checked)" }, ["Btrue"])
        XCTAssertEqual(d.definitionOfDone.map { "\($0.text)\($0.checked)" }, ["Btrue"])
    }

    // MARK: - MetaChat offers Undo only where it can undo

    func testEveryToolOfferedUndoHasItsUndoAndCreatingAProjectIsNotOffered() throws {
        let executor = ChatToolExecutor()
        executor.configure(modelContainer: main)
        let ctx = ModelContext(main)
        for tool in ChatToolExecutor.undoableTools.sorted() {
            let entry = AuditLog(tool: tool, argsJSON: "{}", resultSummary: "done", success: true, snapshotJSON: "{}",
                                 chatMessageId: nil)
            ctx.insert(entry)
            try ctx.save()
            XCTAssertNotEqual(executor.undo(auditId: entry.id), "Cannot undo — unknown tool", tool)
        }
        XCTAssertNil(ChatToolExecutor.undoWindowStart(tool: "createProject"), "no Undo button for a created project")
        XCTAssertNotNil(ChatToolExecutor.undoWindowStart(tool: "addTask"))
    }

    // MARK: - P2-8 a task whose project was deleted keeps its body in the window

    func testATaskWhoseProjectWasDeletedShowsWhatItsRecordHolds() throws {
        var input = TaskCreateInput(title: "Ship it")
        input.description = "The whole plan"
        input.acceptanceCriteria = ["Tests pass"]
        _ = try service.create(input, folder: acme, client: "Codex")
        _ = aggregator.deleteProject(canonicalName: "Acme")
        let id = try XCTUnwrap(service.boardCards(filter: .all, archived: false).first?.id)
        let shown = try XCTUnwrap(service.detail(taskId: id)?.detail)
        XCTAssertEqual(shown.description, "The whole plan")
        XCTAssertEqual(shown.acceptanceCriteria.map(\.text), ["Tests pass"])
        XCTAssertNil(service.detail(taskId: id)?.card.projectId)
    }

    // MARK: - P2-12, P2-13 a call's project changed elsewhere moves its tasks on an open board

    private func spin(_ seconds: TimeInterval = 0.6) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testAConversationMovedToAnotherProjectMovesItsTaskOnTheOpenBoard() throws {
        let previous = TrackerService.shared
        TrackerService.shared = service
        defer { TrackerService.shared = previous }
        let ctx = ModelContext(main)
        let acmeRow = ProjectAlias(canonicalName: "Acme"), betaRow = ProjectAlias(canonicalName: "Beta")
        ctx.insert(acmeRow)
        ctx.insert(betaRow)
        let call = Conversation(source: "meeting")
        call.primaryProject = "Acme"
        ctx.insert(call)
        let task = TaskItem(taskDescription: "Send the deck", sourceApp: "meeting")
        task.conversationId = call.id
        ctx.insert(task)
        try ctx.save()
        spin()   // the setup's own change has been seen
        let board = TasksWindowModel()
        board.attach()
        spin()
        XCTAssertEqual(board.cards.first?.projectId, acmeRow.id)
        // A regeneration elsewhere moves the call to Beta: no task and no tracker record changes.
        let other = ModelContext(main)
        try XCTUnwrap(try other.fetch(FetchDescriptor<Conversation>()).first).primaryProject = "Beta"
        try other.save()
        spin()
        XCTAssertEqual(board.cards.first?.projectId, betaRow.id)
    }

    func testOnlyTheRowsTheBoardIsReadFromCountAsAChange() throws {
        spin()
        let before = service.revision
        let ctx = ModelContext(main)
        ctx.insert(UserMemory(content: "Likes short answers", category: "preference", sourceApp: "chat", confidence: 1))
        try ctx.save()
        spin()
        XCTAssertEqual(service.revision, before, "a memory is not on the board")
        ctx.insert(ProjectAlias(canonicalName: "Gamma"))
        try ctx.save()
        spin()
        XCTAssertGreaterThan(service.revision, before)
    }

    /// The open project page reloads on every change the grid sees, memories included (view wiring, read from the
    /// source: the page's state is its own).
    func testAnOpenProjectPageReloadsWithEveryChangeOfTheGrid() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized
        let view = try String(contentsOf: root.appendingPathComponent("Views/Windows/ProjectsView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("ProjectPage(summary: project, changes: changes)"))
        XCTAssertTrue(view.contains(".onChange(of: changes) { _, _ in reload() }"))
        XCTAssertTrue(view.contains("changes &+= 1"))
        XCTAssertTrue(view.contains(".onChange(of: newestMemory.first?.updatedAt) { _, _ in refresh() }"))
    }

    // MARK: - P2-14 the conversation's picker is the one project list

    /// The list itself (`projectChoices`: a project made in Tasks in, an archived one out) is tested with the archive;
    /// here, that the conversation's picker reads it and not raw names from old rows.
    func testTheConversationsProjectPickerListsTheActiveProjects() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized
        let view = try String(contentsOf: root.appendingPathComponent("Views/Windows/ConversationDetailView.swift"),
                              encoding: .utf8)
        XCTAssertTrue(view.contains("existingProjects = TrackerService.shared?.projectChoices() ?? []"))
        XCTAssertFalse(view.contains("seen.insert(p)"), "no names collected from conversations and memories")
        XCTAssertTrue(view.contains(".onReceive(trackerChanges) { loadExistingProjects() }"), "and follows changes")
        let tracked = try service.createProject(name: "Made in Tasks")
        let ctx = ModelContext(main)
        let old = ProjectAlias(canonicalName: "Put away")
        ctx.insert(old)
        try ctx.save()
        try service.archiveProject(old.id)
        XCTAssertEqual(service.projectChoices().map(\.id), [tracked])
    }

    // MARK: - P2-15 a due day is the user's day in every time zone

    func testADueDayIsThatDayEastOfUTCPlusTwelveAndAfterATimeZoneChange() throws {
        let stored = try XCTUnwrap(TrackerService.dueDate("2026-12-24"))
        XCTAssertEqual(TrackerFormat.day(stored), "2026-12-24", "what an agent reads")
        for zone in ["Pacific/Auckland", "Pacific/Tongatapu", "Europe/Berlin", "America/Los_Angeles", "Pacific/Pago_Pago"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let shown = TaskDue.localDay(stored, calendar: calendar)
            XCTAssertEqual(TaskDue.dayString(shown, calendar: calendar), "2026-12-24", "the card and the picker, \(zone)")
            // A day picked there is stored as that day, and reads as it in every other zone.
            let picked = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 24, hour: 9)))
            let again = try XCTUnwrap(TrackerService.dueDate(TaskDue.dayString(picked, calendar: calendar)))
            XCTAssertEqual(TrackerFormat.day(again), "2026-12-24", "picked in \(zone)")
        }
    }

    /// The board's card carries the day as the user's own day.
    func testTheCardShowsADueDayOnTheUsersClock() throws {
        var input = TaskCreateInput(title: "Ship it")
        input.dueDate = "2026-12-24"
        _ = try service.create(input, folder: acme, client: "Codex")
        let card = try XCTUnwrap(service.boardCards(filter: .all, archived: false).first)
        XCTAssertEqual(card.dueAt, TaskDue.localDay(try XCTUnwrap(TrackerService.dueDate("2026-12-24"))))
        XCTAssertEqual(TaskDue.dayString(try XCTUnwrap(card.dueAt)), "2026-12-24")
    }

    /// Re-review of P2-4: the folder is in the save of the first number, never a save of its own after them.
    func testTheFolderIsRememberedWithTheFirstNumber() throws {
        let a = try folder("A/Acme"), b = try folder("B/Acme")
        let ctx = ModelContext(main)
        ctx.insert(ProjectAlias(canonicalName: "Acme"))
        let call = Conversation(source: "meeting")
        call.primaryProject = "Acme"
        ctx.insert(call)
        let task = TaskItem(taskDescription: "Send the deck", sourceApp: "meeting")
        task.conversationId = call.id
        ctx.insert(task)
        try ctx.save()
        // The numbering's own saves go through; a save of the folder after them would be refused.
        struct Refused: Error {}
        let refusing = makeService(saveTracker: { _ in throw Refused() })
        _ = try? refusing.list(TaskListInput(), folder: a)
        let tracked = try ModelContext(tracker).fetch(FetchDescriptor<TrackedProject>())
        XCTAssertEqual(tracked.flatMap(\.folders), [a], "remembered with the number")
        _ = try service.create(TaskCreateInput(title: "Other repository"), folder: b, client: "Codex")
        XCTAssertEqual(try service.list(TaskListInput(), folder: b).tasks.map(\.title), ["Other repository"])
    }

    /// Re-review of P2-7: a task the Archive lists — a record, dismissed by MetaChat — is the agent's to restore.
    func testATaskWithARecordDismissedByMetaChatIsTheAgentsToRestore() throws {
        let ctx = ModelContext(main)
        ctx.insert(ProjectAlias(canonicalName: "Acme"))
        let call = Conversation(source: "meeting")
        call.primaryProject = "Acme"
        ctx.insert(call)
        let task = TaskItem(taskDescription: "Send the deck", sourceApp: "meeting")
        task.conversationId = call.id
        ctx.insert(task)
        try ctx.save()
        try service.editFromApp(taskId: task.id, priority: .set(.high))   // the window makes its record
        let fresh = ModelContext(main)                                      // MetaChat's dismiss: the task alone
        let row = try XCTUnwrap(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        row.isDismissed = true
        row.status = "dismissed"
        try fresh.save()
        XCTAssertEqual(service.boardCards(filter: .all, archived: true).map(\.id), [task.id], "in the Archive")
        XCTAssertEqual(try service.view(id: "TASK-1", folder: acme).summary.archived, true)
        _ = try service.restore(id: "TASK-1", folder: acme, client: "Codex")
        XCTAssertEqual(service.boardCards(filter: .all, archived: false).map(\.id), [task.id])
    }
}
