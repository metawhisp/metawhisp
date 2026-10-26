import XCTest
@testable import MetaWhisp

/// C5 — readiness from the engine the app uses, and the quick start when the
/// onboarding opens. A model folder of the test's own; the download is the
/// test runner's offline one, so nothing is fetched.
@MainActor
final class ModelPreparerTests: XCTestCase {
    private struct Saved {
        let engine, model, provider, groq, openai: String
        let pending, completed: Bool
    }

    private var saved: Saved!
    private var temp: URL!
    private var managers: [ModelManagerService] = []

    override func setUpWithError() throws {
        let settings = AppSettings.shared
        saved = Saved(engine: settings.transcriptionEngine, model: settings.selectedModel,
                      provider: settings.cloudTranscriptionProvider, groq: settings.groqKey,
                      openai: settings.openaiKey, pending: settings.pendingBestModelUpgrade,
                      completed: settings.hasCompletedOnboarding)
        settings.transcriptionEngine = "ondevice"
        settings.selectedModel = ModelBootstrap.bestModelId
        settings.cloudTranscriptionProvider = "groq"
        settings.groqKey = ""
        settings.openaiKey = ""
        settings.pendingBestModelUpgrade = false
        settings.hasCompletedOnboarding = false   // the first run; a replay is said where it is meant
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("mw-preparer-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        managers.forEach { $0.cancelDownload() }
        let settings = AppSettings.shared
        settings.transcriptionEngine = saved.engine
        settings.selectedModel = saved.model
        settings.cloudTranscriptionProvider = saved.provider
        settings.groqKey = saved.groq
        settings.openaiKey = saved.openai
        settings.pendingBestModelUpgrade = saved.pending
        settings.hasCompletedOnboarding = saved.completed
        try? FileManager.default.removeItem(at: temp)
    }

    /// A manager over the test's folder, with these models on disk.
    private func manager(onDisk models: [String] = []) throws -> ModelManagerService {
        let folder = ModelFolder(kind: .applicationSupport, home: temp, supportDirectory: temp)
        for id in models {
            let variant = try XCTUnwrap(ModelManagerService.models.first { $0.id == id }?.variant)
            try FileManager.default.createDirectory(at: folder.speechModels.appendingPathComponent(variant, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        let manager = ModelManagerService(folder: folder)
        managers.append(manager)
        return manager
    }

    /// `pro`: the Pro proxy is there — the coordinator owns whether cloud can be used (A4).
    private func coordinator(_ engine: LoadableEngine? = nil, pro: Bool = false) -> TranscriptionCoordinator {
        TranscriptionCoordinator(recorder: FakeMicrophone(), whisperEngine: engine, textInserter: TextInsertionService(),
                                 soundService: SoundService(enabled: { false }), settings: AppSettings.shared,
                                 voiceQuestions: VoiceQuestionState(), cloudEngine: HeldEngine(answersAtOnce: true),
                                 openMicrophoneSettings: {}, proxyAvailable: { pro })
    }

    private func preparer(_ manager: ModelManagerService, _ coordinator: TranscriptionCoordinator,
                          freeBytes: Int64 = 50_000_000_000) -> ModelPreparer {
        ModelPreparer(modelManager: manager, coordinator: coordinator, settings: .shared, freeBytes: { freeBytes })
    }

    // MARK: - Readiness

    /// The engine transcribes with whatever it holds; the pick may still be
    /// Large while Base serves.
    func testBaseOrLargeLoadedIsReadyWhateverThePick() throws {
        let flow = coordinator(LoadableEngine(loaded: true))
        let models = preparer(try manager(), flow)
        for loaded in [ModelBootstrap.quickModelId, ModelBootstrap.bestModelId] {
            flow.loadedWhisperModelId = loaded
            XCTAssertEqual(models.state, .ready, loaded)
        }
    }

    /// Step-1 review #7: a model id recorded while the engine dictation uses
    /// holds nothing — a replaced engine's late load — is not readiness.
    func testARecordedModelWithoutALoadedEngineIsNotReady() throws {
        let flow = coordinator()
        flow.loadedWhisperModelId = ModelBootstrap.quickModelId
        XCTAssertNotEqual(preparer(try manager(), flow).state, .ready, "no engine at all")
        flow.whisperEngine = LoadableEngine()
        XCTAssertNotEqual(preparer(try manager(), flow).state, .ready, "an engine that holds nothing")
    }

    func testTheOnDeviceEngineNeedsAModelWhateverProOrAKey() throws {
        AppSettings.shared.groqKey = "gsk_test"
        let models = preparer(try manager(), coordinator(pro: true))
        XCTAssertNotEqual(models.state, .ready)
    }

    /// A4 — cloud is ready with the Pro proxy or the user's own key; without either the on-device engine stands in,
    /// so readiness is the on-device engine's: no model yet says so, never that a key is missing.
    func testTheCloudEngineIsReadyWithProOrAKeyAndOnDeviceStandsInWithout() throws {
        AppSettings.shared.transcriptionEngine = "cloud"
        XCTAssertEqual(preparer(try manager(), coordinator(pro: true)).state, .ready, "the Pro proxy")
        XCTAssertEqual(preparer(try manager(), coordinator()).state, .failed("No speech model on this Mac yet."),
                       "no key, no Pro: the on-device engine has no model yet")
        let loaded = coordinator(LoadableEngine(loaded: true))
        loaded.loadedWhisperModelId = ModelBootstrap.quickModelId
        XCTAssertEqual(preparer(try manager(), loaded).state, .ready, "no key, no Pro: the on-device model serves")
        AppSettings.shared.groqKey = "gsk_test"
        XCTAssertEqual(preparer(try manager(), coordinator()).state, .ready, "the user's own key")
        AppSettings.shared.cloudTranscriptionProvider = "openai"
        XCTAssertEqual(preparer(try manager(), coordinator()).state, .failed("No speech model on this Mac yet."),
                       "the key is for the other provider")
    }

    func testADownloadShowsItsProgress() throws {
        let manager = try manager()
        manager.isDownloading = true
        manager.downloadProgress = 0.4
        XCTAssertEqual(preparer(manager, coordinator()).state, .downloading(0.4))
    }

    func testThePickOnDiskNotYetLoadedIsLoading() throws {
        AppSettings.shared.selectedModel = ModelBootstrap.quickModelId
        let manager = try manager(onDisk: [ModelBootstrap.quickModelId])
        manager.refreshDownloaded()
        XCTAssertEqual(preparer(manager, coordinator()).state, .loading)
    }

    func testAFailedDownloadOrLoadIsFailed() throws {
        let manager = try manager()
        manager.phase = .failed("offline")
        guard case .failed = preparer(manager, coordinator()).state else { return XCTFail("download failed") }
        manager.phase = .done
        manager.failedToLoadModelId = ModelBootstrap.bestModelId
        guard case .failed = preparer(manager, coordinator()).state else { return XCTFail("load failed") }
    }

    func testAFullDiskWithNoModelIsLowDisk() throws {
        XCTAssertEqual(preparer(try manager(), coordinator(), freeBytes: 100_000_000).state, .lowDisk)
    }

    // MARK: - The quick start when the onboarding opens

    func testAProUserOnTheOnDeviceEngineStillGetsTheQuickModel() throws {
        let manager = try manager()
        preparer(manager, coordinator(pro: true)).prepareForOnboarding()
        XCTAssertTrue(manager.isDownloading)
        XCTAssertEqual(manager.currentDownloadModel, ModelBootstrap.quickModelId)
        XCTAssertEqual(AppSettings.shared.selectedModel, ModelBootstrap.quickModelId)
        XCTAssertTrue(AppSettings.shared.pendingBestModelUpgrade, "Large follows in the background")
    }

    func testTheCloudEngineDownloadsNothing() throws {
        AppSettings.shared.transcriptionEngine = "cloud"
        let manager = try manager()
        preparer(manager, coordinator(pro: true)).prepareForOnboarding()
        XCTAssertFalse(manager.isDownloading)
    }

    /// Launch lists the models later than the onboarding opens; the preparer
    /// looks for itself.
    func testAModelAlreadyOnDiskIsNotDownloadedAgain() throws {
        let manager = try manager(onDisk: [ModelBootstrap.bestModelId])
        preparer(manager, coordinator()).prepareForOnboarding()
        XCTAssertFalse(manager.isDownloading)
        XCTAssertEqual(AppSettings.shared.selectedModel, ModelBootstrap.bestModelId)
    }

    /// After a reinstall the pick resets to Large while Base's files stay.
    func testAModelOnDiskThatIsNotThePickIsUsedAsItIs() throws {
        let manager = try manager(onDisk: [ModelBootstrap.quickModelId])
        preparer(manager, coordinator()).prepareForOnboarding()
        XCTAssertFalse(manager.isDownloading)
        XCTAssertEqual(AppSettings.shared.selectedModel, ModelBootstrap.quickModelId)
    }

    /// E3 — a replay on an install that completed the onboarding prepares nothing: nothing downloads or is planned,
    /// and a Large pick stays though Base is on disk. The user's Try again still gets a model.
    func testAReplayPreparesNothingAndTryAgainStillDoes() throws {
        AppSettings.shared.hasCompletedOnboarding = true
        let empty = try manager()
        let models = preparer(empty, coordinator())
        models.prepareForOnboarding()
        XCTAssertFalse(empty.isDownloading)
        XCTAssertEqual(AppSettings.shared.selectedModel, ModelBootstrap.bestModelId)
        XCTAssertFalse(AppSettings.shared.pendingBestModelUpgrade)
        models.retry()
        XCTAssertTrue(empty.isDownloading, "the press is the user's")
        XCTAssertEqual(empty.currentDownloadModel, ModelBootstrap.quickModelId)
    }

    func testAReplayKeepsALargePickThoughBaseIsOnDisk() throws {
        AppSettings.shared.hasCompletedOnboarding = true
        let withBase = try manager(onDisk: [ModelBootstrap.quickModelId])
        preparer(withBase, coordinator()).prepareForOnboarding()
        XCTAssertEqual(AppSettings.shared.selectedModel, ModelBootstrap.bestModelId, "the pick stays")
        XCTAssertFalse(withBase.isDownloading)
    }

    func testAFullDiskStartsNothing() throws {
        let manager = try manager()
        let models = preparer(manager, coordinator(), freeBytes: 100_000_000)
        models.prepareForOnboarding()
        XCTAssertFalse(manager.isDownloading)
        XCTAssertEqual(models.state, .lowDisk)
    }

    // MARK: - Try again (the practice screen, B2 and B3)

    /// A model on disk that did not load: Try again downloads it again — the files are there, so it takes seconds —
    /// and the auto-load after the download loads it.
    func testTryAgainAfterAFailedLoadDownloadsThatModelAgain() throws {
        let manager = try manager(onDisk: [ModelBootstrap.quickModelId])
        manager.refreshDownloaded()
        manager.phase = .failed("Model downloaded but failed to load — tap RETRY")
        manager.failedToLoadModelId = ModelBootstrap.quickModelId
        preparer(manager, coordinator()).retry()
        XCTAssertTrue(manager.isDownloading)
        XCTAssertEqual(manager.currentDownloadModel, ModelBootstrap.quickModelId)
    }

    /// A download that failed with nothing on disk: Try again starts the quick model again.
    func testTryAgainAfterAFailedDownloadStartsTheQuickModel() throws {
        let manager = try manager()
        manager.phase = .failed("offline")
        preparer(manager, coordinator()).retry()
        XCTAssertTrue(manager.isDownloading)
        XCTAssertEqual(manager.currentDownloadModel, ModelBootstrap.quickModelId)
    }

    /// Codex step-2 #2 — a download that stopped short after its first files: the folder is there, so the listing
    /// sees it, and still the model is not installed. Try again downloads that model again.
    func testTryAgainAfterAPartialDownloadDownloadsThatModelAgain() async throws {
        let manager = try manager()
        manager.download = Self.landsAFileThenGoesOffline(manager)
        let models = preparer(manager, coordinator())
        models.prepareForOnboarding()
        await until { !manager.isDownloading }
        manager.refreshDownloaded()   // as the next opening, Settings or a launch lists the folder
        XCTAssertFalse(manager.isDownloaded(ModelBootstrap.quickModelId), "part of a model is not a model")
        XCTAssertEqual(models.state, .failed("The speech model didn't download."))

        manager.download = ModelManagerService.defaultDownload
        models.retry()
        XCTAssertTrue(manager.isDownloading, "Try again downloads it again")
        XCTAssertEqual(manager.currentDownloadModel, ModelBootstrap.quickModelId)
    }

    /// On a completed install the bootstrap is not what Try again runs into: the download that stopped short is
    /// started again by name, and the pick and the upgrade plan are left as they are.
    func testTryAgainOnACompletedInstallRestartsTheDownloadThatStoppedShort() async throws {
        let manager = try manager()
        manager.download = Self.landsAFileThenGoesOffline(manager)
        let models = preparer(manager, coordinator())
        models.prepareForOnboarding()
        await until { !manager.isDownloading }
        AppSettings.shared.hasCompletedOnboarding = true
        AppSettings.shared.pendingBestModelUpgrade = false
        manager.download = ModelManagerService.defaultDownload
        models.retry()
        XCTAssertEqual(manager.currentDownloadModel, ModelBootstrap.quickModelId)
        XCTAssertTrue(manager.isDownloading)
        XCTAssertFalse(AppSettings.shared.pendingBestModelUpgrade, "nothing planned by the restart")
    }

    /// The paired case: a download that completed is a model, and Try again downloads nothing.
    func testACompletedDownloadIsAModelAndTryAgainDownloadsNothing() async throws {
        let manager = try manager()
        let speechModels = manager.folder.speechModels
        manager.download = { variant, _, _ in
            let model = speechModels.appendingPathComponent(variant, isDirectory: true)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            return model
        }
        let models = preparer(manager, coordinator())
        models.prepareForOnboarding()
        await until { !manager.isDownloading }
        XCTAssertEqual(manager.phase, .done)
        XCTAssertTrue(manager.isDownloaded(ModelBootstrap.quickModelId))
        models.retry()
        XCTAssertFalse(manager.isDownloading)
    }

    /// The disk-space check stays: a download that stopped short on a full disk is not started again, and the
    /// state says why — the plain reason, not "didn't download" over a Try again that does nothing (B3).
    func testTryAgainAfterAPartialDownloadOnAFullDiskStartsNothingAndSaysSo() async throws {
        let manager = try manager()
        manager.download = Self.landsAFileThenGoesOffline(manager)
        let space = FreeSpace()
        let models = ModelPreparer(modelManager: manager, coordinator: coordinator(), settings: .shared,
                                   freeBytes: { space.bytes })
        models.prepareForOnboarding()
        await until { !manager.isDownloading }
        space.bytes = 100_000_000
        manager.download = ModelManagerService.defaultDownload
        models.retry()
        XCTAssertFalse(manager.isDownloading)
        XCTAssertEqual(models.state, .lowDisk)
        space.bytes = 50_000_000_000
        XCTAssertEqual(models.state, .failed("The speech model didn't download."), "space back: the failure again")
        models.retry()
        XCTAssertTrue(manager.isDownloading, "and Try again downloads it")
    }

    /// The first file lands in the model's folder, then the network goes — as WhisperKit's download leaves it.
    private static func landsAFileThenGoesOffline(_ manager: ModelManagerService) -> ModelManagerService.Download {
        let speechModels = manager.folder.speechModels
        return { variant, _, _ in
            let model = speechModels.appendingPathComponent(variant, isDirectory: true)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: model.appendingPathComponent("config.json"))
            throw URLError(.notConnectedToInternet)
        }
    }

    private final class FreeSpace { var bytes: Int64 = 50_000_000_000 }

    private func until(_ done: @escaping () -> Bool) async {
        for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    /// B3 — a full disk: Try again starts nothing and the state still says so; nothing retries by itself.
    func testTryAgainOnAFullDiskStartsNothing() throws {
        let manager = try manager()
        let models = preparer(manager, coordinator(), freeBytes: 100_000_000)
        models.retry()
        XCTAssertFalse(manager.isDownloading)
        XCTAssertEqual(models.state, .lowDisk)
    }

    // MARK: - On-device in place of cloud (A4)

    /// Cloud is chosen but can't be used — Pro ended, no key of the user's own — and no model is on disk: the quick
    /// model downloads now, so dictation works again without a trip to Settings.
    func testCloudThatCantBeUsedDownloadsTheQuickModelInItsPlace() throws {
        AppSettings.shared.transcriptionEngine = "cloud"
        let manager = try manager()
        preparer(manager, coordinator()).prepareInPlaceOfCloud()
        XCTAssertTrue(manager.isDownloading)
        XCTAssertEqual(manager.currentDownloadModel, ModelBootstrap.quickModelId)
        XCTAssertEqual(AppSettings.shared.selectedModel, ModelBootstrap.quickModelId)
        XCTAssertEqual(AppSettings.shared.transcriptionEngine, "cloud", "the choice stays, so cloud comes back with Pro")
    }

    /// A model already on disk stands in as it is.
    func testAModelOnDiskStandsInForCloudWithoutADownload() throws {
        AppSettings.shared.transcriptionEngine = "cloud"
        let manager = try manager(onDisk: [ModelBootstrap.quickModelId])
        preparer(manager, coordinator()).prepareInPlaceOfCloud()
        XCTAssertFalse(manager.isDownloading)
        XCTAssertEqual(AppSettings.shared.selectedModel, ModelBootstrap.quickModelId)
    }

    /// Cloud in use — Pro, or the user's own key — needs no stand-in.
    func testCloudInUseDownloadsNothingInItsPlace() throws {
        AppSettings.shared.transcriptionEngine = "cloud"
        let withPro = try manager()
        preparer(withPro, coordinator(pro: true)).prepareInPlaceOfCloud()
        XCTAssertFalse(withPro.isDownloading, "Pro")
        AppSettings.shared.groqKey = "gsk_test"
        let withKey = try manager()
        preparer(withKey, coordinator()).prepareInPlaceOfCloud()
        XCTAssertFalse(withKey.isDownloading, "the user's own key")
    }

    /// The on-device choice is the user's own: its models are theirs to pick in Settings, as before.
    func testTheOnDeviceChoiceGetsNoDownloadInPlaceOfCloud() throws {
        let manager = try manager()
        preparer(manager, coordinator()).prepareInPlaceOfCloud()
        XCTAssertFalse(manager.isDownloading)
    }

    // MARK: - The background upgrade

    func testTheBackgroundUpgradeKeysOnTheEngineNotOnPro() throws {
        AppSettings.shared.selectedModel = ModelBootstrap.quickModelId
        AppSettings.shared.pendingBestModelUpgrade = true
        let flow = coordinator(LoadableEngine(loaded: true), pro: true)
        flow.loadedWhisperModelId = ModelBootstrap.quickModelId
        let models = preparer(try manager(onDisk: [ModelBootstrap.quickModelId]), flow)
        XCTAssertEqual(models.upgradeAction(), .startDownload, "Pro on the on-device engine keeps the plan")
        AppSettings.shared.transcriptionEngine = "cloud"
        XCTAssertEqual(models.upgradeAction(), .cancelPlan)
    }
}
