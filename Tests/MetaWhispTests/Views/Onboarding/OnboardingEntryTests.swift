import AppKit
import XCTest
@testable import MetaWhisp

/// D6 — the ways in. Settings' "Show onboarding" did nothing: it built a bare window controller the app had never
/// set up. It now opens the app's own onboarding through the same `show()` as the first launch, which also starts
/// the quick model (C5). Replaying it on an existing install changes no setting (E3). Every Get Pro and Sign in
/// opens the account page in one place, so a sign-in the app started is known there.
@MainActor
final class OnboardingEntryTests: XCTestCase {

    private func code(_ path: String) throws -> [String] { try OnboardingWindowTests.codeLines(of: path) }

    func testShowOnboardingInSettingsOpensTheAppsOwnOnboarding() throws {
        let settings = try code("Views/Windows/MainSettingsView.swift")
        XCTAssertFalse(settings.contains { $0.contains("OnboardingWindowController(") }, "no bare controller")
        XCTAssertTrue(settings.contains { $0.contains("showOnboarding()") })

        let app = try code("App/AppDelegate.swift")
        let start = try XCTUnwrap(app.firstIndex { $0.contains("func showOnboarding()") })
        let body = app[start...].prefix { !$0.hasPrefix("    }") }
        XCTAssertTrue(body.contains { $0.contains("onboardingWindow.show()") }, "the same show() as the first launch")
        XCTAssertEqual(app.filter { $0.contains("onboardingWindow.show()") }.count, 1, "one way to show it")
        XCTAssertTrue(app.contains { $0.trimmingCharacters(in: .whitespaces) == "showOnboarding()" }, "the first launch")
    }

    /// B1 — the quick model starts as the onboarding opens: show() asks for it before the window is placed, so both
    /// ways in (the first launch and Settings) start it.
    func testShowStartsTheQuickModelBeforeTheWindow() throws {
        let controller = try code("Views/Windows/OnboardingWindowController.swift")
        let show = try XCTUnwrap(controller.firstIndex { $0.contains("func show()") })
        let prepare = try XCTUnwrap(controller[show...].firstIndex { $0.contains("prepareForOnboarding()") })
        let place = try XCTUnwrap(controller[show...].firstIndex { $0.contains("OnboardingWindowPlacement.show(") })
        XCTAssertLessThan(prepare, place)
    }

    /// D1 — every ending closes the onboarding and opens the main window, on the Dashboard.
    func testTheFinishOpensTheMainWindowOnTheDashboard() throws {
        let controller = try code("Views/Windows/OnboardingWindowController.swift")
        let finished = try XCTUnwrap(controller.firstIndex { $0.contains("func finished(") })
        let body = controller[finished...].prefix { !$0.hasPrefix("    }") }
        XCTAssertTrue(body.contains { $0.contains("window?.close()") })
        XCTAssertTrue(body.contains { $0.contains("dependencies?.openMainWindow()") })
        XCTAssertTrue(try code("App/AppDelegate.swift").contains { $0.contains("openMainWindow(tab: .dashboard)") })
    }

    /// Codex step-2 #3 — the finish opens the Dashboard, and that window keeps the window invariant: closing it
    /// releases it (never kept hidden on a Space), and the next open makes a new window around the same content.
    func testTheFinishOpensTheDashboardWhoseCloseReleasesItsWindow() throws {
        let app = OnboardingAppFixture()
        defer { app.tearDown() }
        AppSettings.shared.hasCompletedOnboarding = true
        let main = MainWindowController()
        let content = NSView()
        var opened = 0
        let controller = app.controller(openMainWindow: {
            opened += 1
            main.open(tab: .dashboard) { content }
        })
        controller.show()
        let onboarding = try XCTUnwrap(controller.window)

        try XCTUnwrap(controller.flow).complete(.free)
        app.settle()
        XCTAssertNil(controller.window, "the onboarding is closed and released")
        XCTAssertFalse(onboarding.isVisible)
        XCTAssertEqual(opened, 1, "the finish opens the main window")
        let dashboard = try XCTUnwrap(main.window)
        XCTAssertTrue(dashboard.isVisible)

        main.close()   // the red button's path
        app.settle()
        XCTAssertNil(main.window, "closed means released")
        XCTAssertFalse(dashboard.isVisible)
        XCTAssertTrue(main.content === content, "the content is kept for the next window")

        main.open(tab: .dashboard) { NSView() }
        let reopened = try XCTUnwrap(main.window)
        XCTAssertFalse(reopened === dashboard, "a new window")
        XCTAssertTrue(reopened.contentView === content)
        XCTAssertTrue(reopened.isVisible)
        main.close()
        app.settle()
        XCTAssertNil(main.window)
    }

    /// E3 — an existing install replays the onboarding: completing it leaves every setting as it was.
    func testReplayingTheOnboardingChangesNoSetting() throws {
        let fixture = try OnboardingFixture()
        defer { fixture.tearDown() }
        let defaults = fixture.defaults
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set("ru", forKey: "transcriptionLanguage")
        defaults.set("large-v3-turbo", forKey: "selectedModel")
        defaults.set("cloud", forKey: "transcriptionEngine")
        let before = defaults.dictionaryRepresentation().filter { $0.key != OnboardingFlow.resumeKey }
        let flow = fixture.flow()
        XCTAssertEqual(flow.screen, .welcome, "the same flow, from the start")
        flow.complete(.free)
        let after = defaults.dictionaryRepresentation().filter { $0.key != OnboardingFlow.resumeKey }
        XCTAssertEqual(after as NSDictionary, before as NSDictionary)
    }

    // MARK: - Opening it again from Settings (E3) — the real show()

    /// Codex step-2 #1: a Pro user on the cloud engine picked Large, and only Base is on disk. Settings → Show
    /// onboarding opens the same window, and the pick, the engine and the upgrade plan stay theirs.
    func testAReplayKeepsThePickTheEngineAndTheUpgradePlan() throws {
        let app = OnboardingAppFixture(pro: true)
        defer { app.tearDown() }
        let settings = AppSettings.shared
        settings.hasCompletedOnboarding = true
        settings.transcriptionEngine = "cloud"
        settings.selectedModel = ModelBootstrap.bestModelId
        settings.pendingBestModelUpgrade = false
        try app.putOnDisk([ModelBootstrap.quickModelId])

        app.controller().show()

        XCTAssertEqual(settings.selectedModel, ModelBootstrap.bestModelId, "the pick is the user's")
        XCTAssertEqual(settings.transcriptionEngine, "cloud")
        XCTAssertFalse(settings.pendingBestModelUpgrade)
        XCTAssertFalse(app.manager.isDownloading)
    }

    /// The same with nothing on disk and the on-device engine: no quick start, no background upgrade planned.
    func testAReplayStartsNoDownloadAndPlansNoUpgrade() throws {
        let app = OnboardingAppFixture()
        defer { app.tearDown() }
        let settings = AppSettings.shared
        settings.hasCompletedOnboarding = true
        settings.transcriptionEngine = "ondevice"
        settings.selectedModel = ModelBootstrap.bestModelId
        settings.pendingBestModelUpgrade = false

        let controller = app.controller()
        controller.show()

        XCTAssertNotNil(controller.window, "the onboarding opened")
        XCTAssertFalse(app.manager.isDownloading)
        XCTAssertEqual(settings.selectedModel, ModelBootstrap.bestModelId)
        XCTAssertFalse(settings.pendingBestModelUpgrade)
    }

    /// The paired first run (B1): the same show() starts the quick model and plans Large after it, as before.
    func testTheFirstRunStillStartsTheQuickModel() throws {
        let app = OnboardingAppFixture()
        defer { app.tearDown() }
        let settings = AppSettings.shared
        settings.hasCompletedOnboarding = false
        settings.transcriptionEngine = "ondevice"
        settings.selectedModel = ModelBootstrap.bestModelId
        settings.pendingBestModelUpgrade = false

        app.controller().show()

        XCTAssertTrue(app.manager.isDownloading)
        XCTAssertEqual(app.manager.currentDownloadModel, ModelBootstrap.quickModelId)
        XCTAssertEqual(settings.selectedModel, ModelBootstrap.quickModelId)
        XCTAssertTrue(settings.pendingBestModelUpgrade, "Large follows in the background")
    }

    /// The first run with a model already on disk uses it as it is, as before (after a reinstall the pick resets
    /// to Large while Base's files stay).
    func testTheFirstRunStillUsesAModelOnDisk() throws {
        let app = OnboardingAppFixture()
        defer { app.tearDown() }
        let settings = AppSettings.shared
        settings.hasCompletedOnboarding = false
        settings.transcriptionEngine = "ondevice"
        settings.selectedModel = ModelBootstrap.bestModelId
        try app.putOnDisk([ModelBootstrap.quickModelId])

        app.controller().show()

        XCTAssertEqual(settings.selectedModel, ModelBootstrap.quickModelId)
        XCTAssertFalse(app.manager.isDownloading)
    }

    /// The release of a replay's "prepares nothing": the user's own Try again. On an install that completed the
    /// onboarding — a replay, or the Dashboard after "Skip for now" — a press still gets a speech model.
    func testTryAgainStillPreparesOnACompletedInstall() throws {
        let app = OnboardingAppFixture()
        defer { app.tearDown() }
        let settings = AppSettings.shared
        settings.hasCompletedOnboarding = true
        settings.transcriptionEngine = "ondevice"
        settings.selectedModel = ModelBootstrap.bestModelId
        app.controller().show()
        XCTAssertFalse(app.manager.isDownloading, "the replay prepared nothing")

        app.preparer.retry()

        XCTAssertTrue(app.manager.isDownloading)
        XCTAssertEqual(app.manager.currentDownloadModel, ModelBootstrap.quickModelId)
    }

    /// Every Get Pro and Sign in in the app — the onboarding's and Settings' — opens the account page through
    /// AccountPage, the one place a sign-in the app started is known.
    func testEveryGetProAndSignInOpensTheAccountPageInOnePlace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var holders: [String] = []
        for folder in ["App", "Views", "Services", "Models", "Helpers"] {
            guard let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder),
                                                             includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                if try String(contentsOf: url, encoding: .utf8).contains("metawhisp.com/account") {
                    holders.append(url.lastPathComponent)
                }
            }
        }
        XCTAssertEqual(holders, ["AccountPage.swift"])
    }

    /// A2 — Settings reads the plan line from the billing period, not from the license's plan name.
    func testSettingsShowsThePlanFromTheBillingPeriod() throws {
        let settings = try code("Views/Windows/MainSettingsView.swift")
        XCTAssertTrue(settings.contains { $0.contains("LicenseService.planLabel(interval:") })
        XCTAssertFalse(settings.contains { $0.contains("\"Monthly plan\"") }, "never a guessed Monthly")
    }
}
