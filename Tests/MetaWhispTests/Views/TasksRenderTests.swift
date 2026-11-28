import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// FEAT-0006 §9 — the Tasks window (board, list, archive, a task) drawn to PNG without ordering a window, on
/// made-up tasks, so the look is checked by eye. Opt-in through METAWHISP_RENDER_DIR, like LookRenderTests.
@MainActor
final class TasksRenderTests: XCTestCase {
    func testRenderTheTasksWindow() throws {
        guard let folder = ProcessInfo.processInfo.environment["METAWHISP_RENDER_DIR"] else {
            throw XCTSkip("Set METAWHISP_RENDER_DIR to write the Tasks renders.")
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-render-\(UUID().uuidString)")
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

        let acme = dir.appendingPathComponent("Code/Acme").path
        var a = TaskCreateInput(title: "Add search across tasks and memories")
        a.priority = .high
        a.labels = ["search", "web"]
        a.acceptanceCriteria = ["Finds tasks by words", "Finds memories", "Tested"]
        a.description = "Finding anything means three separate commands today."
        _ = try service.create(a, folder: acme, client: "Claude Code")
        var b = TaskCreateInput(title: "Ship the board view")
        b.status = .inProgress
        b.assignee = ["@claude"]
        _ = try service.create(b, folder: acme, client: "Claude Code")
        _ = try service.edit({ var e = TaskEditInput(id: "TASK-2"); e.planSet = "1. Columns\n2. Drag and drop"
                               e.notesAppend = ["Columns done"]; e.acceptanceCriteriaAdd = ["Three columns", "Drag works"]
                               e.acceptanceCriteriaCheck = [1]; return e }(), folder: acme, client: "Claude Code")
        var c = TaskCreateInput(title: "Write release notes")
        c.status = .done
        _ = try service.create(c, folder: acme, client: "Codex")
        _ = try service.create(TaskCreateInput(title: "Fix the login timeout"), folder: dir.appendingPathComponent("Code/Billing").path,
                               client: "Codex")
        let ctx = ModelContext(main)
        let voice = TaskItem(taskDescription: "Call the bank about the card", sourceApp: "microphone")
        voice.assignee = nil
        ctx.insert(voice)
        let waiting = TaskItem(taskDescription: "Send the signed contract", sourceApp: "meeting", assignee: "Maya")
        ctx.insert(waiting)
        ctx.insert(TaskItem(taskDescription: "Book a room for Thursday", sourceApp: "meeting", status: "staged"))
        try ctx.save()

        // Projects for the Projects tab: conversations tagged with them.
        for (name, count) in [("Acme", 5), ("Billing", 3), ("Pixel Garden Studio", 2)] {
            for _ in 0..<count {
                let c = Conversation(source: "meeting")
                c.status = "completed"
                c.finishedAt = Date()
                c.primaryProject = name
                ctx.insert(c)
            }
        }
        try ctx.save()
        let aggregator = ProjectAggregator()
        aggregator.configure(modelContainer: main, trackerContainer: tracker)

        let app = NSApplication.shared
        let previousLook = app.appearance
        defer { app.appearance = previousLook }
        for (look, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let appearance = try XCTUnwrap(NSAppearance(named: look))
            app.appearance = appearance
            for layout in ["board", "list"] {
                UserDefaults.standard.set(layout, forKey: "tasksLayout")
                try render(TasksView().modelContainer(main), size: NSSize(width: 1080, height: 700),
                           appearance: appearance, to: out.appendingPathComponent("tasks-\(layout)-\(name).png"))
            }
            // A narrow Workspace: a 900 pt window minus the full sidebar.
            let narrow = NSSize(width: 660, height: 600)
            for layout in ["board", "list"] {
                UserDefaults.standard.set(layout, forKey: "tasksLayout")
                try render(TasksView().modelContainer(main), size: narrow, appearance: appearance,
                           to: out.appendingPathComponent("tasks-\(layout)-narrow-\(name).png"))
            }
            try render(WorkspaceView().modelContainer(main).environmentObject(aggregator), size: narrow,
                       appearance: appearance, to: out.appendingPathComponent("workspace-narrow-\(name).png"))
            try render(ProjectsView().modelContainer(main).environmentObject(aggregator), size: narrow,
                       appearance: appearance, to: out.appendingPathComponent("projects-narrow-\(name).png"))
            let id = try XCTUnwrap(service.boardCards(filter: .all, archived: false).first { $0.key == "TASK-2" }?.id)
            // A sheet takes its window's background; the borderless test window has none of its own.
            try render(TaskDetailSheet(service: service, taskId: id, projects: service.projectChoices()) {}
                        .background(Color(nsColor: .windowBackgroundColor)),
                       size: NSSize(width: 560, height: 620), appearance: appearance,
                       to: out.appendingPathComponent("task-detail-\(name).png"))
        }
        UserDefaults.standard.removeObject(forKey: "tasksLayout")
    }

    private func render(_ view: some View, size: NSSize, appearance: NSAppearance, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        defer { window.close() }
        host.setFrameSize(size)
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(window.isVisible, url.lastPathComponent)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
