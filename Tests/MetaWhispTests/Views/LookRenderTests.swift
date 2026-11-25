import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import MetaWhisp

/// ITER-087 — the main window's screens drawn to PNG without ordering a window, in the dark and the light look, so
/// the new look is checked by eye before a build reaches anyone. Opt-in through METAWHISP_RENDER_DIR.
/// METAWHISP_RENDER_STORE may point at a COPY of a store (made with sqlite's `.backup`, never the live file) to draw
/// real rows; without it the screens are drawn empty.
@MainActor
final class LookRenderTests: XCTestCase {
    func testRenderTheWindowScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["METAWHISP_RENDER_DIR"] else {
            throw XCTSkip("Set METAWHISP_RENDER_DIR to write the window renders.")
        }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        let configuration: ModelConfiguration
        if let copy = environment["METAWHISP_RENDER_STORE"] {
            XCTAssertFalse(copy.hasSuffix("/Application Support/MetaWhisp.store"), "a copy, never the live store")
            configuration = ModelConfiguration(schema: schema, url: URL(fileURLWithPath: copy))
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        let container = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self,
                                           configurations: [configuration])
        let fixture = OnboardingAppFixture()
        defer { fixture.tearDown() }
        let history = HistoryService(container: container)
        let recorder = AudioRecordingService()
        let aggregator = ProjectAggregator()
        let meetingRecorder = MeetingRecorder(mic: recorder, systemAudio: SystemAudioCaptureService())
        let screenContext = ScreenContextService()
        let dailySummary = DailySummaryService()

        let app = NSApplication.shared
        let previousLook = app.appearance
        let previousAccent = UserDefaults.standard.object(forKey: "accentColor")
        defer {
            app.appearance = previousLook
            if let previousAccent {
                UserDefaults.standard.set(previousAccent, forKey: "accentColor")
            } else {
                UserDefaults.standard.removeObject(forKey: "accentColor")
            }
        }

        let shots: [(name: String, tab: MainWindowView.SidebarTab, size: NSSize)] = [
            ("dashboard", .dashboard, NSSize(width: 960, height: 640)),
            ("dashboard-whole", .dashboard, NSSize(width: 960, height: 1900)),
            ("workspace", .workspace, NSSize(width: 960, height: 640)),
            ("settings", .settings, NSSize(width: 960, height: 640)),
            ("settings-whole", .settings, NSSize(width: 960, height: 1400)),
            ("dashboard-wide", .dashboard, NSSize(width: 1280, height: 800)),
            ("library", .library, NSSize(width: 960, height: 640)),
            ("insights", .weeklyInsights, NSSize(width: 960, height: 640)),
            ("chat", .chat, NSSize(width: 960, height: 640)),
            ("dictionary", .dictionary, NSSize(width: 960, height: 640)),
        ]
        let looks: [(name: String, appearance: NSAppearance.Name, accent: String)] = [
            ("dark", .darkAqua, "mint"), ("light", .aqua, "mint"), ("dark-mono", .darkAqua, "mono"),
            ("dark-violet", .darkAqua, "violet"),
        ]
        for look in looks {
            let appearance = try XCTUnwrap(NSAppearance(named: look.appearance))
            app.appearance = appearance
            AppSettings.shared.accentColor = look.accent
            for shot in shots where !look.name.contains("-") || ["dashboard", "settings-whole"].contains(shot.name) {
                let view = MainWindowView(coordinator: fixture.coordinator, modelManager: fixture.manager,
                                          modelPreparer: fixture.preparer, recorder: recorder,
                                          historyService: history, initialTab: shot.tab)
                    .environmentObject(aggregator)
                try render(view, size: shot.size, appearance: appearance,
                           to: directory.appendingPathComponent("\(shot.name)-\(look.name).png"))
            }
            // The menu-bar popover, on the services existing tests already build without side effects.
            let popover = PopoverRootView(coordinator: fixture.coordinator, recorder: recorder,
                                          meetingRecorder: meetingRecorder, screenContext: screenContext,
                                          dailySummary: dailySummary, closePopover: {})
            try render(popover, size: NSSize(width: 320, height: 420), appearance: appearance,
                       to: directory.appendingPathComponent("popover-\(look.name).png"))
        }
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
