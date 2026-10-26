import XCTest
@testable import MetaWhisp

/// D6 / E4 — the Dashboard after setup (mockup v6 `readyBody`): one thing to do next, in the user's own apps. With
/// Accessibility off it says what works and gives the one button that fixes the rest — until the grant. With it on,
/// "Ready for dictation" — until the first dictation. Free is offered nothing (D7). Before any of that, the engine:
/// while it cannot transcribe, the card says so and gives Try again (Codex step-2 #4).
final class DashboardReadyCardTests: XCTestCase {

    private func card(accessibility: Bool, model: ModelPreparer.State = .ready, cloud: Bool = false,
                      isPro: Bool = false, hasDictated: Bool = false,
                      hotkeyMode: String = "toggle") -> DashboardReadyCard.Content? {
        DashboardReadyCard.content(model: model,
                                   rightCommand: .current(accessibility: accessibility, hotkeyMode: hotkeyMode),
                                   cloud: cloud, isPro: isPro, hasDictated: hasDictated)
    }

    func testWithAccessibilityOffItSaysDictationWorksInMetaWhispWithTheWayToSettings() throws {
        for dictated in [false, true] {
            let content = try XCTUnwrap(card(accessibility: false, hasDictated: dictated), "dictated \(dictated)")
            XCTAssertEqual(content.title, "Dictation works in MetaWhisp")
            XCTAssertEqual(content.detail, "Turn on Accessibility to use Right ⌘ and type into other apps.")
            XCTAssertTrue(content.opensAccessibility)
            XCTAssertEqual(DashboardReadyCard.openAccessibility, "Open Accessibility Settings")
            XCTAssertNil(content.footnote)
            XCTAssertFalse(content.retriesModel)
        }
    }

    func testReadyForDictationUntilTheFirstDictation() throws {
        let local = try XCTUnwrap(card(accessibility: true))
        XCTAssertEqual(local.title, "Ready for dictation")
        XCTAssertEqual(local.detail, "Click in any text field, then tap Right ⌘.")
        XCTAssertFalse(local.opensAccessibility)
        XCTAssertFalse(local.retriesModel)
        XCTAssertEqual(local.footnote, "Dictation runs on your Mac.")
        XCTAssertEqual(card(accessibility: true, cloud: true)?.footnote, "Cloud dictation is on.",
                       "the engine in use, not the plan, says where dictation runs")
        XCTAssertNil(card(accessibility: true, hasDictated: true), "done once it has been done")
    }

    /// Push-to-talk holds Right ⌘; the toggle taps it.
    func testPushToTalkReadsHold() throws {
        XCTAssertEqual(try XCTUnwrap(card(accessibility: true, hotkeyMode: "pushToTalk")).detail,
                       "Click in any text field, then hold Right ⌘.")
        XCTAssertEqual(try XCTUnwrap(card(accessibility: true, hotkeyMode: "toggle")).detail,
                       "Click in any text field, then tap Right ⌘.")
        XCTAssertEqual(try XCTUnwrap(card(accessibility: false, hotkeyMode: "pushToTalk")).title,
                       "Dictation works in MetaWhisp", "without Accessibility, either mode")
    }

    /// D7 — Free is offered nothing; a Pro user sees the PRO mark beside "Ready for dictation", nothing to buy.
    func testFreeIsOfferedNothing() throws {
        for accessibility in [false, true] {
            let free = try XCTUnwrap(card(accessibility: accessibility))
            XCTAssertFalse(free.showsPro)
            XCTAssertFalse("\(free.title) \(free.detail ?? "") \(free.footnote ?? "")".contains("Pro"))
        }
        XCTAssertEqual(card(accessibility: true, cloud: true, isPro: true)?.showsPro, true)
    }

    // MARK: - The engine first (Codex step-2 #4)

    /// "Skip for now" after a failed download, then Continue with Free: nothing can transcribe, so the card never
    /// says "Ready for dictation" — nor, without Accessibility, "Dictation works in MetaWhisp". It says what is
    /// wrong, in the words the practice used, with Try again; whatever Accessibility and the first dictation say.
    func testAModelThatDidNotDownloadIsTheRemainingStep() throws {
        for accessibility in [false, true] {
            for dictated in [false, true] {
                let content = try XCTUnwrap(card(accessibility: accessibility,
                                                 model: .failed("The speech model didn't download."),
                                                 hasDictated: dictated))
                XCTAssertEqual(content.title, "The speech model didn't download.")
                XCTAssertNil(content.detail)
                XCTAssertTrue(content.retriesModel)
                XCTAssertFalse(content.opensAccessibility)
                XCTAssertNil(content.footnote)
                XCTAssertFalse(content.showsPro)
            }
        }
        XCTAssertEqual(DashboardReadyCard.tryAgain, "Try again")
    }

    /// The same for a full disk: the practice's plain words, and Try again for once space is free.
    func testAFullDiskIsTheRemainingStep() throws {
        for accessibility in [false, true] {
            let content = try XCTUnwrap(card(accessibility: accessibility, model: .lowDisk, hasDictated: true))
            XCTAssertEqual(content.title, "Not enough disk space for the speech model.")
            XCTAssertEqual(content.detail, "Free up about 500 MB, then try again.")
            XCTAssertTrue(content.retriesModel)
            XCTAssertFalse(content.opensAccessibility)
        }
    }

    /// On its way — after a Try again, or while it loads — the card waits with the practice's words, and its %.
    func testAModelOnItsWayWaitsWithItsPercent() throws {
        let downloading = try XCTUnwrap(card(accessibility: true, model: .downloading(0.4)))
        XCTAssertEqual(downloading.title, "Getting dictation ready…")
        XCTAssertEqual(downloading.detail, "40%")
        XCTAssertFalse(downloading.retriesModel)
        XCTAssertFalse(downloading.opensAccessibility)
        let loading = try XCTUnwrap(card(accessibility: false, model: .loading, hasDictated: true))
        XCTAssertEqual(loading.title, "Getting dictation ready…")
        XCTAssertNil(loading.detail)
        XCTAssertFalse(loading.retriesModel)
    }

    /// The practice and the Dashboard say a model problem in the same words, from one place.
    func testThePracticeAndTheDashboardShareTheWords() {
        XCTAssertEqual(TryVoiceScreen.box(phase: .ready, model: .lowDisk, rightCommand: .tap),
                       .modelProblem(title: ModelPreparer.lowDiskTitle, detail: ModelPreparer.lowDiskDetail))
        XCTAssertEqual(card(accessibility: true, model: .lowDisk)?.title, ModelPreparer.lowDiskTitle)
        XCTAssertEqual(DashboardReadyCard.tryAgain, TryVoiceScreen.tryAgain)
        XCTAssertEqual(card(accessibility: true, model: .loading)?.title, TryVoiceScreen.preparing)
    }
}

/// The card over the real readiness owner: "Skip for now" left the model unavailable, the onboarding is complete,
/// and the Dashboard's own Try again brings dictation back — after a failed download, and after a full disk.
@MainActor
final class DashboardReadyCardRecoveryTests: XCTestCase {
    private var app: OnboardingAppFixture!

    override func setUp() async throws {
        app = OnboardingAppFixture()
        AppSettings.shared.hasCompletedOnboarding = false
        AppSettings.shared.transcriptionEngine = "ondevice"
        AppSettings.shared.selectedModel = ModelBootstrap.bestModelId
        AppSettings.shared.pendingBestModelUpgrade = false
    }

    override func tearDown() async throws {
        app.tearDown()
    }

    private func card(accessibility: Bool = true) -> DashboardReadyCard.Content? {
        DashboardReadyCard.content(model: app.preparer.state,
                                   rightCommand: .current(accessibility: accessibility, hotkeyMode: "toggle"),
                                   cloud: app.coordinator.usesCloud, isPro: false, hasDictated: false)
    }

    /// The download lands the model's folder.
    private func downloadCompletes() {
        let speechModels = app.manager.folder.speechModels
        app.manager.download = { variant, _, _ in
            let model = speechModels.appendingPathComponent(variant, isDirectory: true)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            return model
        }
    }

    private func until(_ done: @escaping () -> Bool) async {
        for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    func testAfterAFailedDownloadTryAgainOnTheDashboardBringsDictationBack() async throws {
        app.manager.download = { _, _, _ in throw URLError(.notConnectedToInternet) }
        app.preparer.prepareForOnboarding()   // the first run's quick start
        await until { !self.app.manager.isDownloading }
        AppSettings.shared.hasCompletedOnboarding = true   // "Skip for now", then Continue with Free
        for accessibility in [false, true] {
            let stuck = try XCTUnwrap(card(accessibility: accessibility))
            XCTAssertEqual(stuck.title, "The speech model didn't download.", "Accessibility \(accessibility)")
            XCTAssertTrue(stuck.retriesModel)
        }

        downloadCompletes()
        app.preparer.retry()   // the card's Try again
        await until { !self.app.manager.isDownloading }
        XCTAssertEqual(app.manager.phase, .done)
        app.load(ModelBootstrap.quickModelId)   // the auto-load after the download
        XCTAssertEqual(card()?.title, "Ready for dictation")
        XCTAssertEqual(card(accessibility: false)?.title, "Dictation works in MetaWhisp")
    }

    func testAfterAFullDiskTryAgainOnTheDashboardBringsDictationBackOnceThereIsSpace() async throws {
        app.space.bytes = 100_000_000
        app.preparer.prepareForOnboarding()   // the quick start starts nothing on a full disk
        AppSettings.shared.hasCompletedOnboarding = true
        XCTAssertEqual(card()?.title, "Not enough disk space for the speech model.")
        app.preparer.retry()
        XCTAssertFalse(app.manager.isDownloading, "still full: nothing starts")
        XCTAssertEqual(card()?.title, "Not enough disk space for the speech model.")

        app.space.bytes = 50_000_000_000
        downloadCompletes()
        app.preparer.retry()
        XCTAssertEqual(card()?.title, "Getting dictation ready…")
        await until { !self.app.manager.isDownloading }
        app.load(ModelBootstrap.quickModelId)
        XCTAssertEqual(card()?.title, "Ready for dictation")
    }
}
