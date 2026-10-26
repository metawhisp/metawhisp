import XCTest
@testable import MetaWhisp

/// ITER-058.3 — quick-start / background-upgrade decision logic.
final class ModelBootstrapTests: XCTestCase {

    private let plentyOfDisk: Int64 = 50_000_000_000

    // MARK: - shouldQuickStart

    func test_quickStart_freshInstall_starts() {
        XCTAssertTrue(ModelBootstrap.shouldQuickStart(
            anyModelDownloaded: false, isDownloading: false, engineIsCloud: false, freeBytes: plentyOfDisk))
    }

    func test_quickStart_modelAlreadyPresent_noop() {
        XCTAssertFalse(ModelBootstrap.shouldQuickStart(
            anyModelDownloaded: true, isDownloading: false, engineIsCloud: false, freeBytes: plentyOfDisk))
    }

    func test_quickStart_downloadInFlight_noop() {
        XCTAssertFalse(ModelBootstrap.shouldQuickStart(
            anyModelDownloaded: false, isDownloading: true, engineIsCloud: false, freeBytes: plentyOfDisk))
    }

    /// C5 — the cloud engine needs no local model. Pro is not asked: a Pro user
    /// on the on-device engine gets the quick model (ModelPreparerTests).
    func test_quickStart_cloudEngine_noop() {
        XCTAssertFalse(ModelBootstrap.shouldQuickStart(
            anyModelDownloaded: false, isDownloading: false, engineIsCloud: true, freeBytes: plentyOfDisk))
    }

    func test_quickStart_fullDisk_noop() {
        XCTAssertFalse(ModelBootstrap.shouldQuickStart(
            anyModelDownloaded: false, isDownloading: false, engineIsCloud: false, freeBytes: 100_000_000))
    }

    // MARK: - upgradeAction

    private func action(
        pending: Bool = true,
        selectedModel: String = ModelBootstrap.quickModelId,
        quickModelLoaded: Bool = true,
        bestDownloaded: Bool = false,
        isDownloading: Bool = false,
        engineIsCloud: Bool = false,
        freeBytes: Int64 = 50_000_000_000
    ) -> ModelBootstrap.UpgradeAction {
        ModelBootstrap.upgradeAction(
            pending: pending, selectedModel: selectedModel,
            quickModelLoaded: quickModelLoaded, bestDownloaded: bestDownloaded,
            isDownloading: isDownloading,
            engineIsCloud: engineIsCloud, freeBytes: freeBytes)
    }

    func test_upgrade_notPending_none() {
        XCTAssertEqual(action(pending: false, bestDownloaded: true), .none)
    }

    func test_upgrade_userMovedOffQuickModel_none() {
        XCTAssertEqual(action(selectedModel: "small"), .none)
    }

    /// Review P1: a user on the cloud engine must never get an unrequested
    /// ~1 GB download or a false "upgraded" notification. Keyed on the engine
    /// (C5): Pro on the on-device engine keeps the plan (ModelPreparerTests).
    func test_upgrade_cloud_cancelsPlan() {
        XCTAssertEqual(action(engineIsCloud: true), .cancelPlan)
        XCTAssertEqual(action(bestDownloaded: true, engineIsCloud: true), .cancelPlan,
                       "cancel wins even with the best model on disk")
    }

    func test_upgrade_bestReady_swapsNow() {
        XCTAssertEqual(action(bestDownloaded: true), .swapNow)
    }

    func test_upgrade_bestReady_swapsEvenWhileAnotherDownloadRuns() {
        XCTAssertEqual(action(bestDownloaded: true, isDownloading: true), .swapNow)
    }

    /// Review P3 + Codex: the upgrade waits until the quick model is actually
    /// LOADED — not merely downloaded. A corrupt Base that fails to load must
    /// not hand the download slot to the 950 MB model.
    func test_upgrade_quickModelNotWorkingYet_waits() {
        XCTAssertEqual(action(quickModelLoaded: false), .none)
    }

    func test_upgrade_needsDownload_starts() {
        XCTAssertEqual(action(), .startDownload)
    }

    func test_upgrade_downloadInFlight_waits() {
        XCTAssertEqual(action(isDownloading: true), .none)
    }

    func test_upgrade_lowDisk_skips() {
        XCTAssertEqual(action(freeBytes: 1_000_000_000), .skipLowDisk)
    }

    // MARK: - Cancellation ownership when cloud/Pro wins (Codex)

    func test_cancel_bestModelAlwaysDies() {
        XCTAssertTrue(ModelBootstrap.shouldCancelDownload(
            currentDownloadModel: ModelBootstrap.bestModelId, quickStartOwned: false))
    }

    func test_cancel_quickStartOwnedBaseDies() {
        XCTAssertTrue(ModelBootstrap.shouldCancelDownload(
            currentDownloadModel: ModelBootstrap.quickModelId, quickStartOwned: true))
    }

    /// A model the user picked by hand keeps downloading — going cloud is not
    /// permission to throw away their explicit choice.
    func test_cancel_manualBaseSurvives() {
        XCTAssertFalse(ModelBootstrap.shouldCancelDownload(
            currentDownloadModel: ModelBootstrap.quickModelId, quickStartOwned: false))
    }

    func test_cancel_otherModelSurvives() {
        XCTAssertFalse(ModelBootstrap.shouldCancelDownload(
            currentDownloadModel: "small", quickStartOwned: true))
    }

    func test_cancel_nothingDownloading_noop() {
        XCTAssertFalse(ModelBootstrap.shouldCancelDownload(
            currentDownloadModel: nil, quickStartOwned: true))
    }

    // MARK: - Load-failure marker is independent of the download phase (Codex)

    @MainActor
    func test_loadFailure_survivesUnrelatedDownloadFinishing() {
        let mgr = ModelManagerService()
        mgr.downloadedModels = ["openai_whisper-base"]
        mgr.failedToLoadModelId = "base"
        // An unrelated download runs and completes — the phase pipeline moves on,
        // but the base load failure must still be visible (it used to be erased).
        mgr.phase = .downloading
        mgr.phase = .done
        XCTAssertEqual(mgr.failedToLoadModelId, "base")
    }

    @MainActor
    func test_loadFailure_clearedByRetryingThatModel() {
        let mgr = ModelManagerService()
        mgr.failedToLoadModelId = "base"
        mgr.startDownload("base")          // RETRY re-runs the download
        XCTAssertNil(mgr.failedToLoadModelId)
        mgr.cancelDownload()
    }

    @MainActor
    func test_loadFailure_restoredWhenRetryDownloadFails() {
        let mgr = ModelManagerService()
        mgr.failedToLoadModelId = "base"
        mgr.startDownload("base")                    // RETRY clears the marker
        XCTAssertNil(mgr.failedToLoadModelId)
        mgr.restoreLoadFailureAfterFailedRetry()     // …and the retry failed
        XCTAssertEqual(mgr.failedToLoadModelId, "base",
                       "a failed retry must leave RETRY reachable on the broken model")
        mgr.cancelDownload()
    }

    @MainActor
    func test_loadFailure_notRestoredAfterASuccessfulRetry() {
        let mgr = ModelManagerService()
        mgr.failedToLoadModelId = "base"
        mgr.startDownload("base")
        mgr.downloadedModels = ["openai_whisper-base"]
        mgr.noteRetryDownloadSucceeded()             // the files landed
        mgr.restoreLoadFailureAfterFailedRetry()     // must now be a no-op
        XCTAssertNil(mgr.failedToLoadModelId)
        mgr.cancelDownload()
    }

    // MARK: - isDownloaded exact match (review: substring bug)

    @MainActor
    func test_isDownloaded_exactVariantMatch_noSubstringFalsePositive() {
        let mgr = ModelManagerService()
        // Only the TURBO variant is on disk; its dir name CONTAINS the plain
        // large-v3 variant name — the old contains-match reported both.
        mgr.downloadedModels = ["openai_whisper-large-v3_turbo"]
        XCTAssertTrue(mgr.isDownloaded("large-v3-turbo"))
        XCTAssertFalse(mgr.isDownloaded("large-v3"),
                       "substring of another variant's dir must not count as downloaded")
        XCTAssertFalse(mgr.isDownloaded("base"))
    }

    /// ITER-075 step 0 (0.4) — a test never downloads into the owner's shared
    /// model folder: under XCTest a download waits, offline, until it is
    /// cancelled.
    @MainActor
    func test_downloadsStayOfflineUnderTests() async {
        final class Box { var finished = false }
        let box = Box()
        let task = Task { @MainActor in
            defer { box.finished = true }
            _ = try await ModelManagerService.defaultDownload("openai_whisper-base",
                                                                 FileManager.default.temporaryDirectory, { _ in })
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(box.finished, "the offline download waits until it is cancelled")
        task.cancel()
        do {
            try await task.value
            XCTFail("an offline download never completes")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// ITER-075 step 0 (0.4) — a speech model that keeps failing to load is
    /// deleted from the shared Documents folder only by the owner's app; any
    /// other copy leaves it alone. A copy's own folder (F1) is its to clean.
    /// On temp folders, never the owner's.
    @MainActor
    func test_aBrokenModelIsDeletedOnlyByTheOwnersApp() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mw-hub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let shared = ModelFolder(kind: .documents, home: home, supportDirectory: home.appendingPathComponent("support"))
        let own = ModelFolder(kind: .applicationSupport, home: home, supportDirectory: home.appendingPathComponent("support"))
        let variant = "openai_whisper-test"
        let dev = AppIdentity(bundleIdentifier: "com.metawhisp.app.dev")
        for folder in [shared, own] {
            try FileManager.default.createDirectory(at: folder.speechModels.appendingPathComponent(variant, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }

        XCTAssertFalse(ModelManagerService.removeBrokenModel(variant: variant, identity: dev, folder: shared))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.speechModels.appendingPathComponent(variant).path),
                      "a non-owner copy leaves the shared model alone")

        XCTAssertTrue(ModelManagerService.removeBrokenModel(
            variant: variant, identity: AppIdentity(bundleIdentifier: "com.metawhisp.app"), folder: shared))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.speechModels.appendingPathComponent(variant).path),
                       "the owner's app deletes it, as before")

        XCTAssertTrue(ModelManagerService.removeBrokenModel(variant: variant, identity: dev, folder: own))
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.speechModels.appendingPathComponent(variant).path),
                       "any copy cleans its own folder")
    }
}
