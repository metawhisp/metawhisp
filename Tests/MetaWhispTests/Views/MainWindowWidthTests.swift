import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import MetaWhisp

/// Owner 2026-11-26 (allow the window twice as narrow, one column left, nothing broken): the main
/// window may be about half as narrow as before, and no tab may then reach past its edges. Two ways a tab breaks:
/// its content asks for a minimum wider than the window (the hosting view then raises the window's minimum, and a
/// window already narrower than that overflows and is clipped on both sides), or a part of it is laid out wider than
/// the space it is given (clipped inside a scroll view). The first is read from the window, the second from where
/// the tab's controls and texts end up. Headless: no window is ordered front.
@MainActor
final class MainWindowWidthTests: XCTestCase {

    private var container: ModelContainer!
    private var fixture: OnboardingAppFixture!
    private var aggregator: ProjectAggregator!
    private var trackerDir: URL!
    private var previousTracker: TrackerService?

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        container = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self,
                                       configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        fixture = OnboardingAppFixture()
        try seed(container)
        // Projects and tasks are drawn too (review 2026-11-27, #7): a tracker over these rows.
        trackerDir = FileManager.default.temporaryDirectory.appendingPathComponent("width-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: trackerDir, withIntermediateDirectories: true)
        let tracker = try TrackerStore.makeContainer(url: trackerDir.appendingPathComponent("T.store"))
        aggregator = ProjectAggregator()
        aggregator.configure(modelContainer: container, trackerContainer: tracker)
        previousTracker = TrackerService.shared
        TrackerService.shared = TrackerService(main: container, tracker: tracker,
                                               mutations: MutationService(runHooks: { _ in }), home: trackerDir.path)
    }

    override func tearDown() {
        TrackerService.shared = previousTracker
        if let trackerDir { try? FileManager.default.removeItem(at: trackerDir) }
        fixture?.tearDown()
        fixture = nil
        container = nil
        super.tearDown()
    }

    /// Enough rows that the screens draw their filled layouts (statistics, tasks, conversations), not empty states.
    private func seed(_ container: ModelContainer) throws {
        let ctx = ModelContext(container)
        for day in 0..<12 {
            let item = HistoryItem(text: "A dictated note about the release plan and the next steps for the team",
                                   language: "en", audioDuration: 42, processingTime: 1.2)
            item.createdAt = Date().addingTimeInterval(-Double(day) * 86_400)
            ctx.insert(item)
        }
        for name in ["Acme", "Billing"] {
            ctx.insert(ProjectAlias(canonicalName: name))
            for i in 0..<3 {
                let c = Conversation(source: "meeting")
                c.status = "completed"
                c.finishedAt = Date()
                c.primaryProject = name
                c.title = "Weekly sync about the launch"
                ctx.insert(c)
                let t = TaskItem(taskDescription: "Follow up on the launch checklist item \(i + 1) with the whole team",
                                 dueAt: Date().addingTimeInterval(Double(i - 1) * 86_400), sourceApp: "meeting")
                t.conversationId = c.id
                ctx.insert(t)
            }
        }
        ctx.insert(TaskItem(taskDescription: "Send the release notes to the team", sourceApp: "meeting"))
        ctx.insert(TaskItem(taskDescription: "Book a room for Thursday", sourceApp: "meeting", status: "staged"))
        try ctx.save()
    }

    private func mainView(_ tab: MainWindowView.SidebarTab) -> some View {
        MainWindowView(coordinator: fixture.coordinator, modelManager: fixture.manager,
                       modelPreparer: fixture.preparer, recorder: AudioRecordingService(),
                       historyService: HistoryService(container: container), initialTab: tab)
            .environmentObject(aggregator)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    /// At the minimum width nothing of any tab is laid out wider than the scroll area showing it. A vertical scroll
    /// view cuts what is wider than itself, so a part of a tab that will not shrink shows there as a document wider
    /// than its clip view.
    func testNoTabIsWiderThanItsScrollAreaAtTheMinimum() throws {
        let size = NSSize(width: MainWindowView.minimumSize.width, height: 800)
        for tab in MainWindowView.SidebarTab.allCases {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: mainView(tab))
            window.contentView = host
            host.setFrameSize(size)
            settle(host)
            XCTAssertFalse(window.isVisible)
            var areas = 0
            var wider: [String] = []
            Self.scrollViews(in: host).forEach { scroll in
                // Pages scroll up and down; a strip that scrolls sideways is wider than its view by design.
                guard let document = scroll.documentView, scroll.hasVerticalScroller else { return }
                areas += 1
                let clip = scroll.contentView.bounds.width
                if document.frame.width > clip + 1 {
                    wider.append("\(Int(document.frame.width)) pt in \(Int(clip)) pt")
                }
                // A part that will not shrink can also push the whole scroll area past the window's edge.
                let inWindow = scroll.convert(scroll.bounds, to: nil)
                if inWindow.minX < -1 || inWindow.maxX > size.width + 1 {
                    wider.append("a scroll area at x \(Int(inWindow.minX))…\(Int(inWindow.maxX)) in \(Int(size.width)) pt")
                }
            }
            print("[width] \(tab.rawValue): \(areas) scroll areas, \(wider.count) too wide")
            // Not a pass by finding nothing: these tabs lay their pages out in scroll areas.
            if [.dashboard, .library, .workspace, .settings].contains(tab) {
                XCTAssertGreaterThan(areas, 0, "\(tab.rawValue): no scroll area was read")
            }
            XCTAssertTrue(wider.isEmpty, "\(tab.rawValue) at \(Int(size.width)) pt: " + wider.joined(separator: "; "))
            window.close()
        }
    }

    /// Every inner tab too, drawn in the width a screen gets in the narrowest window (the folded rail beside it).
    func testNoInnerTabIsWiderThanItsScrollArea() throws {
        let width = MainWindowView.minimumSize.width - 68
        var screens: [(String, AnyView)] = []
        for tab in MainSettingsView.SettingsTab.allCases {
            screens.append(("Settings / \(tab.rawValue)",
                            AnyView(MainSettingsView(modelManager: fixture.manager, initialTab: tab))))
        }
        for section in LibraryView.Section.allCases {
            screens.append(("Library / \(section.rawValue)", AnyView(LibraryView(initialSection: section))))
        }
        for section in WorkspaceView.Section.allCases {
            screens.append(("Workspace / \(section.rawValue)", AnyView(WorkspaceView(initialSection: section))))
        }
        for (name, screen) in screens {
            let size = NSSize(width: width, height: 800)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: screen.modelContainer(container).environmentObject(aggregator))
            window.contentView = host
            host.setFrameSize(size)
            settle(host)
            XCTAssertFalse(window.isVisible)
            var wider: [String] = []
            var areas = 0
            for scroll in Self.scrollViews(in: host) {
                guard let document = scroll.documentView, scroll.hasVerticalScroller else { continue }
                areas += 1
                if document.frame.width > scroll.contentView.bounds.width + 1 {
                    wider.append("\(Int(document.frame.width)) pt in \(Int(scroll.contentView.bounds.width)) pt")
                }
                let inWindow = scroll.convert(scroll.bounds, to: nil)
                if inWindow.minX < -1 || inWindow.maxX > width + 1 {
                    wider.append("a scroll area at x \(Int(inWindow.minX))…\(Int(inWindow.maxX))")
                }
            }
            // The screen as a whole must not be laid out wider than the space it is given either.
            if host.fittingSize.width > width + 1, host.subviews.contains(where: { $0.frame.width > width + 1 }) {
                wider.append("the screen is \(Int(host.subviews.map(\.frame.width).max() ?? 0)) pt")
            }
            print("[inner] \(name): \(areas) scroll areas, \(wider.isEmpty ? "fits" : wider.joined(separator: "; "))")
            // These pages are lists in scroll areas with the seeded rows: reading none would prove nothing.
            if name.hasPrefix("Settings") || ["Library / Conversations", "Workspace / Projects", "Workspace / Tasks"]
                .contains(name) {
                XCTAssertGreaterThan(areas, 0, "\(name): no scroll area was read")
            }
            XCTAssertTrue(wider.isEmpty, "\(name) at \(Int(width)) pt: " + wider.joined(separator: "; "))
            window.close()
        }
    }

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { sub -> [NSScrollView] in
            (sub as? NSScrollView).map { [$0] + scrollViews(in: $0) } ?? scrollViews(in: sub)
        }
    }

    /// Every tab drawn at four widths in both looks, to check by eye. Opt-in through METAWHISP_RENDER_DIR;
    /// METAWHISP_RENDER_STORE may point at a COPY of a store (sqlite `.backup`, never the live file) for real rows.
    func testRenderEveryTabAtEveryWidth() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["METAWHISP_RENDER_DIR"] else {
            throw XCTSkip("Set METAWHISP_RENDER_DIR to write the width renders.")
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if let copy = environment["METAWHISP_RENDER_STORE"] {
            XCTAssertFalse(copy.hasSuffix("/Application Support/MetaWhisp.store"), "a copy, never the live store")
            let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
            container = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self,
                                           configurations: [ModelConfiguration(schema: schema,
                                                                               url: URL(fileURLWithPath: copy))])
            aggregator.configure(modelContainer: container)
        }
        // METAWHISP_RENDER_TRACKER: a COPY of the tracker store, so Tasks and a project's page draw real tasks.
        let previousTracker = TrackerService.shared
        defer { TrackerService.shared = previousTracker }
        if let trackerCopy = environment["METAWHISP_RENDER_TRACKER"] {
            XCTAssertFalse(trackerCopy.hasSuffix("/MetaWhisp/Tracker.store"), "a copy, never the live store")
            let tracker = try TrackerStore.makeContainer(url: URL(fileURLWithPath: trackerCopy))
            aggregator.configure(modelContainer: container, trackerContainer: tracker)
            TrackerService.shared = TrackerService(main: container, tracker: tracker,
                                                   mutations: MutationService(runHooks: { _ in }),
                                                   home: FileManager.default.homeDirectoryForCurrentUser.path)
            // METAWHISP_RENDER_ARCHIVE: put this project away in the COPY, to draw the "Archived · N" card.
            if let name = environment["METAWHISP_RENDER_ARCHIVE"],
               let id = TrackerService.shared?.projectChoices().first(where: { $0.name == name })?.id {
                try TrackerService.shared?.archiveProject(id)
            }
        }
        let widths: [CGFloat] = (environment["METAWHISP_RENDER_WIDTHS"] ?? "450,600,900,1280")
            .split(separator: ",").compactMap { Double($0).map { CGFloat($0) } }
        let only = environment["METAWHISP_RENDER_TABS"].map { Set($0.split(separator: ",").map(String.init)) }
        let tabs = MainWindowView.SidebarTab.allCases.filter { only?.contains(Self.slug($0)) ?? true }
        let app = NSApplication.shared
        let previousLook = app.appearance
        defer { app.appearance = previousLook }
        for (look, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let appearance = try XCTUnwrap(NSAppearance(named: look))
            app.appearance = appearance
            for tab in tabs {
                for width in widths {
                    let size = NSSize(width: width, height: CGFloat(Double(environment["METAWHISP_RENDER_HEIGHT"] ?? "") ?? 900))
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                          backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = appearance
                    let host = NSHostingView(rootView: mainView(tab))
                    host.appearance = appearance
                    window.contentView = host
                    host.setFrameSize(size)
                    settle(host)
                    XCTAssertFalse(window.isVisible)
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    try png.write(to: out.appendingPathComponent("\(Self.slug(tab))-\(Int(width))-\(name).png"))
                    window.close()
                }
            }
            // The Workspace's own screens: Tasks, and the first project's page in each of its parts.
            if only == nil || only?.contains("workspace") == true {
                var extra: [(String, AnyView)] = [("workspace-tasks", AnyView(WorkspaceView(initialSection: .tasks)))]
                if let first = aggregator.listProjects(includeSingletons: true).first {
                    extra.append(("project-page", AnyView(ProjectPage(summary: first, changes: 0, onBack: {}))))
                }
                for (slug, screen) in extra {
                    for width in widths {
                        let size = NSSize(width: max(width - 68, 300), height: 900)
                        try draw(screen.modelContainer(container).environmentObject(aggregator), size: size,
                                 appearance: appearance,
                                 to: out.appendingPathComponent("\(slug)-\(Int(width))-\(name).png"))
                    }
                }
            }
        }
    }

    /// A screen on its own, in the wall the main window gives it.
    private func draw(_ view: some View, size: NSSize, appearance: NSAppearance, to url: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        let host = NSHostingView(rootView: ZStack { PageWash(); view })
        host.appearance = appearance
        window.contentView = host
        host.setFrameSize(size)
        settle(host)
        XCTAssertFalse(window.isVisible)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        window.close()
    }

    private static func slug(_ tab: MainWindowView.SidebarTab) -> String {
        tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
