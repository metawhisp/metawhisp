import XCTest
@testable import MetaWhispTrackerKit

/// FEAT-0006 §6 — the plain text an agent reads back.
final class TrackerFormatTests: XCTestCase {

    private let created = Date(timeIntervalSince1970: 1_795_000_000)   // 2026-11-18 11:06:40 UTC

    private func summary(_ id: String, _ title: String, status: TrackerStatus = .toDo,
                         priority: TrackerPriority? = nil, archived: Bool = false) -> TrackerTaskSummary {
        TrackerTaskSummary(id: id, title: title, status: status.rawValue, archived: archived,
                           priority: priority?.rawValue, type: nil, labels: [], assignee: [],
                           dependencies: [], parentTaskId: nil, acceptanceCriteriaCompleted: 0,
                           acceptanceCriteriaCount: 0, dueDate: nil, ordinal: nil,
                           createdAt: created, updatedAt: created, isReady: true, project: "Acme")
    }

    func testAListLineCarriesPriorityIdTitleProgressAndDue() {
        var row = summary("TASK-3", "Fix login", priority: .high)
        row.type = "bug"
        row.acceptanceCriteriaCompleted = 1
        row.acceptanceCriteriaCount = 3
        row.dueDate = "2026-12-01"
        XCTAssertEqual(TrackerFormat.line(row), "  [HIGH] [bug] TASK-3 - Fix login (ac: 1/3) (due 2026-12-01)")
        XCTAssertEqual(TrackerFormat.line(summary("TASK-4", "Plain")), "  TASK-4 - Plain")
    }

    func testAListIsGroupedByColumnInBoardOrder() {
        let text = TrackerFormat.list(project: "Acme", tasks: [
            summary("TASK-2", "Ship", status: .done),
            summary("TASK-1", "Plan", status: .toDo),
            summary("TASK-3", "Build", status: .inProgress),
        ])
        XCTAssertEqual(text, """
        Project: Acme

        To Do:
          TASK-1 - Plan

        In Progress:
          TASK-3 - Build (no assignee)

        Done:
          TASK-2 - Ship
        """)
    }

    func testAnEmptyListSaysSo() {
        XCTAssertEqual(TrackerFormat.list(project: "Acme", tasks: []), "Project: Acme\n\nNo tasks found.")
    }

    func testSearchLinesNameTheColumnAndArchive() {
        let text = TrackerFormat.search(project: "Acme", query: "login", tasks: [
            summary("TASK-3", "Fix login", status: .inProgress),
            summary("TASK-1", "Old login", status: .done, archived: true),
        ])
        XCTAssertEqual(text, """
        Project: Acme

        Tasks:
          TASK-3 - Fix login (In Progress, no assignee)
          TASK-1 - Old login (Done, archived)
        """)
        XCTAssertEqual(TrackerFormat.search(project: "Acme", query: "zzz", tasks: []),
                       "Project: Acme\n\nNo tasks found for \"zzz\".")
    }

    func testATaskViewShowsEverySectionAndSaysWhatIsEmpty() {
        var detail = TrackerTaskDetail(summary: summary("TASK-3", "Fix login", status: .inProgress, priority: .high))
        detail.summary.assignee = ["@claude"]
        detail.summary.labels = ["auth", "web"]
        detail.description = "Users cannot sign in after the update."
        detail.acceptanceCriteria = [.init(index: 1, text: "Sign-in works", checked: true),
                                     .init(index: 2, text: "Test added", checked: false)]
        detail.implementationPlan = "1. Find the cause"
        detail.dependsOn = [.init(id: "TASK-2", title: "Session store", status: "Done")]
        let text = TrackerFormat.view(detail)
        XCTAssertTrue(text.hasPrefix("Task TASK-3 - Fix login\n" + String(repeating: "=", count: 50)), text)
        for line in ["Status: ◒ In Progress", "Priority: High", "Project: Acme", "Assignee: @claude",
                     "Labels: auth, web", "Created: 2026-11-18 11:06 UTC",
                     "Depends on:\n- TASK-2 - Session store [Done]",
                     "Description:\n" + String(repeating: "-", count: 50) + "\nUsers cannot sign in after the update.",
                     "- [x] #1 Sign-in works", "- [ ] #2 Test added",
                     "No Definition of Done items defined",
                     "Implementation Plan:\n" + String(repeating: "-", count: 50) + "\n1. Find the cause"] {
            XCTAssertTrue(text.contains(line), "missing «\(line)» in\n\(text)")
        }
        XCTAssertFalse(text.contains("Final Summary"), "an empty optional section is left out")
        XCTAssertFalse(text.contains("Implementation Notes"))
    }

    func testAnArchivedTaskSaysSoInItsStatus() {
        let text = TrackerFormat.view(TrackerTaskDetail(summary: summary("TASK-1", "Old", status: .done,
                                                                         archived: true)))
        XCTAssertTrue(text.contains("Status: ✔ Done (archived)"), text)
        XCTAssertTrue(text.contains("No description provided"))
        XCTAssertTrue(text.contains("No acceptance criteria defined"))
    }
}
