import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// FEAT-0006 review round 2, N1 — an open task reloads when the tracker changes, and only then: never in a loop of
/// its own renders. Drawn headless, nothing on screen.
@MainActor
final class TaskDetailSheetLoadTests: XCTestCase {
    func testAnOpenTaskReloadsOnChangesOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sheet-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        let main = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self,
                                      configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let tracker = try TrackerStore.makeContainer(url: dir.appendingPathComponent("T.store"))
        let service = TrackerService(main: main, tracker: tracker, mutations: MutationService(runHooks: { _ in }),
                                     home: dir.path)
        let previous = TrackerService.shared
        TrackerService.shared = service
        defer { TrackerService.shared = previous }
        let id = try service.createTask(title: "Open me", projectId: nil)

        var loads = 0
        let sheet = TaskDetailSheet(service: service, taskId: id, projects: [], changed: {}, onLoad: { loads += 1 })
        let host = NSHostingView(rootView: sheet.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func spin() {
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
        }
        spin()
        let settled = loads
        XCTAssertLessThanOrEqual(settled, 2, "opening loads the task once or twice")
        spin()
        XCTAssertEqual(loads, settled, "no reload without a change")
        try service.move(taskId: id, to: .inProgress)
        spin()
        XCTAssertGreaterThan(loads, settled, "a change reloads it")
        XCTAssertLessThanOrEqual(loads, settled + 2)
    }
}
