import XCTest
@testable import MetaWhisp

/// FEAT-0006 §9b (owner, 2026-11-26) — Workspace opens on Projects; a notification about a task still lands on Tasks;
/// a new task goes into a project.
@MainActor
final class WorkspaceProjectsFirstTests: XCTestCase {

    func testWorkspaceOpensOnProjects() {
        XCTAssertEqual(WorkspaceView.startingSection(nil), .projects)
        XCTAssertEqual(WorkspaceView.Section.allCases.first, .projects, "Projects comes first in the picker")
    }

    func testATaskNotificationOpensTasksOnceThenProjectsAgain() {
        WorkspaceView.open(.tasks)
        XCTAssertEqual(WorkspaceView.startingSection(nil), .tasks)
        XCTAssertEqual(WorkspaceView.startingSection(nil), .projects, "asked once, not forever")
    }

    func testTheNotificationsAboutTasksAskForTasks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized
        for file in ["Services/Intelligence/TaskPromotionService.swift", "Services/System/NotificationService.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(source.contains("openMainWindow(tab: .workspace)"), "\(file) opens Workspace without a section")
            XCTAssertTrue(source.contains("WorkspaceView.open(.tasks)"), file)
        }
    }

    func testANewTaskNeedsAProjectWhileThereAreAny() {
        XCTAssertFalse(NewTaskSheet.canAdd(title: "Ship it", projectId: nil, hasProjects: true))
        XCTAssertTrue(NewTaskSheet.canAdd(title: "Ship it", projectId: UUID(), hasProjects: true))
        XCTAssertTrue(NewTaskSheet.canAdd(title: "Ship it", projectId: nil, hasProjects: false), "no project to pick yet")
        XCTAssertFalse(NewTaskSheet.canAdd(title: "  ", projectId: UUID(), hasProjects: true))
    }
}
