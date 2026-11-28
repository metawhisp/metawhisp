import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import MetaWhisp

/// Owner 2026-11-26 (a narrowed window broke every screen; then: allow it twice as narrow): the main
/// window never gets narrower than its minimum, 450 pt. The hosting view sets the window's minimum from what its SwiftUI content says it
/// can shrink to, which was far below the window's own 900 pt, so the content must say it. Headless: the window is
/// never ordered front.
@MainActor
final class MainWindowMinimumSizeTests: XCTestCase {
    func testTheWindowKeepsItsMinimumOnceTheContentIsIn() throws {
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        let container = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self,
                                           configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let fixture = OnboardingAppFixture()
        defer { fixture.tearDown() }
        let recorder = AudioRecordingService()
        let view = MainWindowView(coordinator: fixture.coordinator, modelManager: fixture.manager,
                                  modelPreparer: fixture.preparer, recorder: recorder,
                                  historyService: HistoryService(container: container), initialTab: .workspace)
            .environmentObject(ProjectAggregator())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 1000),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = MainWindowView.minimumSize
        window.contentView = NSHostingView(rootView: view)
        defer { window.close() }
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertGreaterThanOrEqual(window.minSize.width, MainWindowView.minimumSize.width,
                                    "the hosting view must not lower the window's minimum")
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, MainWindowView.minimumSize.width - 1)
        XCTAssertEqual(MainWindowView.minimumSize, NSSize(width: 450, height: 600))
    }
}
