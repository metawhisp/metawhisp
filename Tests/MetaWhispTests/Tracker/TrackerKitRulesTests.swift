import XCTest
@testable import MetaWhispTrackerKit

/// FEAT-0006 §3–§5 — the pure tracker rules shared by the app and the command-line tool.
final class TrackerKitRulesTests: XCTestCase {

    // MARK: - Status (§3.3)

    func testStatusInputIgnoresCaseAndSpaces() {
        XCTAssertEqual(TrackerStatus.parse("todo"), .toDo)
        XCTAssertEqual(TrackerStatus.parse("TO DO"), .toDo)
        XCTAssertEqual(TrackerStatus.parse(" to  do "), .toDo)
        XCTAssertEqual(TrackerStatus.parse("In progress"), .inProgress)
        XCTAssertEqual(TrackerStatus.parse("inprogress"), .inProgress)
        XCTAssertEqual(TrackerStatus.parse("DONE"), .done)
    }

    func testDraftAndUnknownStatusesAreNotTrackerStatuses() {
        XCTAssertNil(TrackerStatus.parse("Draft"), "drafts are the user's (I3)")
        XCTAssertNil(TrackerStatus.parse("Doing"))
        XCTAssertNil(TrackerStatus.parse(""))
        XCTAssertEqual(TrackerStatus.validList, "To Do, In Progress, Done")
    }

    func testPriorityParsesAndRanks() {
        XCTAssertEqual(TrackerPriority.parse("HIGH"), .high)
        XCTAssertEqual(TrackerPriority.parse("medium"), .medium)
        XCTAssertNil(TrackerPriority.parse("urgent"))
        XCTAssertGreaterThan(TrackerPriority.high.rank, TrackerPriority.medium.rank)
        XCTAssertGreaterThan(TrackerPriority.low.rank, 0)
    }

    // MARK: - IDs (§3.4)

    func testKeysParseWithOrWithoutThePrefixIgnoringCaseAndLeadingZeros() {
        XCTAssertEqual(TrackerKey(parsing: "TASK-12")?.segments, [12])
        XCTAssertEqual(TrackerKey(parsing: "task-012")?.segments, [12])
        XCTAssertEqual(TrackerKey(parsing: "12")?.segments, [12])
        XCTAssertEqual(TrackerKey(parsing: " TASK-12.1 ")?.segments, [12, 1])
        XCTAssertEqual(TrackerKey(parsing: "TASK-12")?.display, "TASK-12")
        XCTAssertEqual(TrackerKey(parsing: "task-12.01")?.stored, "12.1")
    }

    func testMalformedKeysAreRefused() {
        for raw in ["", "TASK-", "ABC-1", "12a", "TASK-1..2", "TASK--1", "-1", "TASK-1.", "DRAFT-3"] {
            XCTAssertNil(TrackerKey(parsing: raw), raw)
        }
    }

    func testKeysSortNumericallyBySegment() {
        let keys = ["TASK-10", "TASK-2.10", "TASK-2", "TASK-2.1"].compactMap(TrackerKey.init(parsing:))
        XCTAssertEqual(keys.sorted().map(\.display), ["TASK-2", "TASK-2.1", "TASK-2.10", "TASK-10"])
    }

    func testNextTopLevelKeyIsOneAboveTheHighestTopLevel() {
        XCTAssertEqual(TrackerKey.nextTopLevel(existing: []).display, "TASK-1")
        let existing = ["1", "3", "5.9", "2"].compactMap(TrackerKey.init(parsing:))
        XCTAssertEqual(TrackerKey.nextTopLevel(existing: existing).display, "TASK-4",
                       "subtask numbers do not count")
    }

    func testNextSubtaskKeyIsOneAboveTheParentsHighestChild() {
        let parent = TrackerKey(parsing: "TASK-5")!
        let existing = ["5", "5.1", "5.3", "6.1", "5.3.1"].compactMap(TrackerKey.init(parsing:))
        XCTAssertEqual(TrackerKey.nextSubtask(of: parent, existing: existing).display, "TASK-5.4")
        XCTAssertEqual(TrackerKey.nextSubtask(of: TrackerKey(parsing: "7")!, existing: existing).display, "TASK-7.1")
    }

    // MARK: - Order (§4)

    func testOrderIsOrdinalThenPriorityThenKey() {
        let rows: [TrackerSortKey] = [
            .init(ordinal: nil, priority: .high, key: TrackerKey(parsing: "9")),
            .init(ordinal: 2000, priority: nil, key: TrackerKey(parsing: "4")),
            .init(ordinal: 1000, priority: .low, key: TrackerKey(parsing: "8")),
            .init(ordinal: nil, priority: nil, key: TrackerKey(parsing: "1")),
            .init(ordinal: nil, priority: .high, key: TrackerKey(parsing: "3")),
        ]
        let order = rows.sorted(by: TrackerSortKey.precedes).compactMap { $0.key?.display }
        XCTAssertEqual(order, ["TASK-8", "TASK-4", "TASK-3", "TASK-9", "TASK-1"])
    }

    func testNewOrdinalFollowsTheHighest() {
        XCTAssertEqual(TrackerSortKey.newOrdinal(existing: [], boardIsEmpty: true), 1000)
        XCTAssertNil(TrackerSortKey.newOrdinal(existing: [nil, nil], boardIsEmpty: false),
                     "a board without ordinals keeps its default order")
        XCTAssertEqual(TrackerSortKey.newOrdinal(existing: [1000, nil, 3500], boardIsEmpty: false), 4500)
    }

    // MARK: - Checklists (§4)

    func testSettingCriteriaKeepsTheTickOfTheSameTextOncePerOldEntry() throws {
        let old = [ChecklistItem(text: "A", checked: true), ChecklistItem(text: "B", checked: false),
                   ChecklistItem(text: "A", checked: false)]
        let new = try Checklist.set(old, to: ["B", "A", "C", " A "])
        XCTAssertEqual(new, [ChecklistItem(text: "B", checked: false), ChecklistItem(text: "A", checked: true),
                             ChecklistItem(text: "C", checked: false), ChecklistItem(text: "A", checked: false)])
    }

    func testCriteriaAreOneLineEachAndBlankEntriesAreSkipped() throws {
        XCTAssertThrowsError(try Checklist.add([], texts: ["first\nsecond"])) { error in
            XCTAssertEqual(error as? ChecklistError, .multiline)
        }
        XCTAssertEqual(try Checklist.add([], texts: ["  ", "Saves on Return"]),
                       [ChecklistItem(text: "Saves on Return", checked: false)])
    }

    func testIndexesAreOneBasedAndOutOfRangeIsRefusedWithTheRange() throws {
        let list = [ChecklistItem(text: "A", checked: false), ChecklistItem(text: "B", checked: false),
                    ChecklistItem(text: "C", checked: false)]
        XCTAssertEqual(try Checklist.mark(list, indexes: [1, 3], checked: true).map(\.checked), [true, false, true])
        XCTAssertEqual(try Checklist.remove(list, indexes: [3, 1]).map(\.text), ["B"])
        XCTAssertThrowsError(try Checklist.remove(list, indexes: [4])) { error in
            XCTAssertEqual(error as? ChecklistError, .indexOutOfRange(index: 4, count: 3))
        }
        XCTAssertThrowsError(try Checklist.mark(list, indexes: [0], checked: true))
    }

    // MARK: - Dependencies (§4)

    func testANewDependencyThatClosesALoopIsFoundWithItsPath() {
        let a = UUID(), b = UUID(), c = UUID()
        let graph: [UUID: [UUID]] = [a: [b], b: [c]]
        XCTAssertEqual(DependencyGraph.cycle(adding: [a], to: c, graph: graph), [c, a, b, c])
        XCTAssertNil(DependencyGraph.cycle(adding: [b], to: a, graph: graph), "already so, no loop")
        XCTAssertEqual(DependencyGraph.cycle(adding: [c], to: c, graph: graph), [c, c], "itself")
    }

    // MARK: - Search (§4)

    func testSearchNeedsEveryWordAndRanksTitleAboveBody() throws {
        XCTAssertNil(TrackerSearch.score(query: "login bug", id: "TASK-1", title: "Fix login", body: "page"))
        let title = try XCTUnwrap(TrackerSearch.score(query: "login", id: "TASK-1", title: "Fix login", body: ""))
        let body = try XCTUnwrap(TrackerSearch.score(query: "login", id: "TASK-2", title: "Fix page",
                                                     body: "the login form"))
        XCTAssertGreaterThan(title, body)
        XCTAssertNotNil(TrackerSearch.score(query: "CAFE", id: "TASK-3", title: "Café menu", body: ""),
                        "case and accents fold")
        XCTAssertNotNil(TrackerSearch.score(query: "task-3", id: "TASK-3", title: "x", body: ""))
    }

    // MARK: - Project names and folders (§5)

    func testProjectNamesMatchIgnoringCaseSpacesDashesUnderscoresAndDots() {
        let forms = ["Pixel Garden", "pixel-gar_den", "PixelGarden", "pixel.garden"]
        XCTAssertEqual(Set(forms.map(ProjectNaming.normalized)).count, 1)
        XCTAssertEqual(ProjectNaming.normalized("Brightloom.io"), ProjectNaming.normalized("brightloom-io"))
        XCTAssertNotEqual(ProjectNaming.normalized("Acme"), ProjectNaming.normalized("Acme2"))
    }

    func testRootHomeAndTopLevelFoldersCannotBeProjects() {
        let home = "/Users/sam"
        XCTAssertTrue(ProjectNaming.isRefusedFolder("/", home: home))
        XCTAssertTrue(ProjectNaming.isRefusedFolder("/Users/sam", home: home))
        XCTAssertTrue(ProjectNaming.isRefusedFolder("/Users/sam/", home: home))
        XCTAssertTrue(ProjectNaming.isRefusedFolder("/Applications", home: home))
        XCTAssertFalse(ProjectNaming.isRefusedFolder("/Users/sam/Code/Acme", home: home))
        XCTAssertEqual(ProjectNaming.projectName(forFolder: "/Users/sam/Code/Acme/"), "Acme")
    }

    func testARememberedFolderCoversItsSubfoldersOnly() {
        XCTAssertTrue(ProjectNaming.folder("/a/Acme", covers: "/a/Acme"))
        XCTAssertTrue(ProjectNaming.folder("/a/Acme", covers: "/a/Acme/Sources/App"))
        XCTAssertFalse(ProjectNaming.folder("/a/Acme", covers: "/a/AcmeTools"))
        XCTAssertFalse(ProjectNaming.folder("/a/Acme/Sources", covers: "/a/Acme"))
    }

    // MARK: - Project root (§5.1)

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmp = tmp.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func mkdir(_ rel: String) throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testASubfolderOfARepositoryResolvesToTheRepository() throws {
        let repo = try mkdir("Acme")
        _ = try mkdir("Acme/.git")
        let deep = try mkdir("Acme/Sources/App")
        XCTAssertEqual(ProjectRoot.resolve(workingDirectory: deep.path, home: "/nonexistent"), repo.path)
    }

    func testAWorktreeResolvesToItsRepository() throws {
        let repo = try mkdir("Acme")
        _ = try mkdir("Acme/.git/worktrees/feature-x")
        let worktree = try mkdir("Acme/.claude/worktrees/feature-x")
        try "gitdir: \(repo.path)/.git/worktrees/feature-x\n"
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectRoot.resolve(workingDirectory: worktree.path, home: "/nonexistent"), repo.path)
    }

    func testARelativeWorktreePointerResolvesToo() throws {
        let repo = try mkdir("Acme")
        _ = try mkdir("Acme/.git/worktrees/wt")
        let worktree = try mkdir("wt")
        try "gitdir: ../Acme/.git/worktrees/wt\n"
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectRoot.resolve(workingDirectory: worktree.path, home: "/nonexistent"), repo.path)
    }

    func testASubmoduleIsItsOwnProject() throws {
        _ = try mkdir("Acme/.git/modules/lib")
        let sub = try mkdir("Acme/lib")
        try "gitdir: ../.git/modules/lib\n"
            .write(to: sub.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectRoot.resolve(workingDirectory: sub.path, home: "/nonexistent"), sub.path)
    }

    func testAPlainFolderIsItsOwnRootAndTheWalkStopsAtHome() throws {
        let plain = try mkdir("Notes/2026")
        XCTAssertEqual(ProjectRoot.resolve(workingDirectory: plain.path, home: "/nonexistent"), plain.path)
        _ = try mkdir("home/.git")
        let inHome = try mkdir("home/Plans")
        XCTAssertEqual(ProjectRoot.resolve(workingDirectory: inHome.path, home: tmp.appendingPathComponent("home").path),
                       inHome.path, "a repository at the home folder does not swallow its subfolders")
    }
}
