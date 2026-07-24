import XCTest
@testable import MetaWhisp

/// ITER-058.3 — quick-start / background-upgrade decision logic.
final class ModelBootstrapTests: XCTestCase {

    private let plentyOfDisk: Int64 = 50_000_000_000

    // MARK: - shouldQuickStart

    func test_quickStart_freshInstall_starts() {
        XCTAssertTrue(ModelBootstrap.shouldQuickStart(
            anyModelDownloaded: false, isDownloading: false, isPro: false, freeBytes: plentyOfDisk))
    }

    func test_quickStart_modelAlreadyPresent_noop() {
        XCTAssertFalse(ModelBootstrap.shouldQuickStart(
            anyModelDownloaded: true, isDownloading: false, isPro: false, freeBytes: plentyOfDisk))
    }

    func test_quickStart_downloadInFlight_noop() {
        XCTAssertFalse(ModelBootstrap.shouldQuickStart(
            anyModelDownloaded: false, isDownloading: true, isPro: false, freeBytes: plentyOfDisk))
    }

    func test_quickStart_proUser_noop() {
        XCTAssertFalse(ModelBootstrap.shouldQuickStart(
            anyModelDownloaded: false, isDownloading: false, isPro: true, freeBytes: plentyOfDisk))
    }

    func test_quickStart_fullDisk_noop() {
        XCTAssertFalse(ModelBootstrap.shouldQuickStart(
            anyModelDownloaded: false, isDownloading: false, isPro: false, freeBytes: 100_000_000))
    }

    // MARK: - upgradeAction

    private func action(
        pending: Bool = true,
        selectedModel: String = ModelBootstrap.quickModelId,
        quickModelLoaded: Bool = true,
        bestDownloaded: Bool = false,
        isDownloading: Bool = false,
        isPro: Bool = false,
        engineIsCloud: Bool = false,
        freeBytes: Int64 = 50_000_000_000
    ) -> ModelBootstrap.UpgradeAction {
        ModelBootstrap.upgradeAction(
            pending: pending, selectedModel: selectedModel,
            quickModelLoaded: quickModelLoaded, bestDownloaded: bestDownloaded,
            isDownloading: isDownloading, isPro: isPro,
            engineIsCloud: engineIsCloud, freeBytes: freeBytes)
    }

    func test_upgrade_notPending_none() {
        XCTAssertEqual(action(pending: false, bestDownloaded: true), .none)
    }

    func test_upgrade_userMovedOffQuickModel_none() {
        XCTAssertEqual(action(selectedModel: "small"), .none)
    }

    /// Review P1: a user who went Pro or validated a cloud key must never get
    /// an unrequested ~1 GB download or a false "upgraded" notification.
    func test_upgrade_proOrCloud_cancelsPlan() {
        XCTAssertEqual(action(isPro: true), .cancelPlan)
        XCTAssertEqual(action(engineIsCloud: true), .cancelPlan)
        XCTAssertEqual(action(bestDownloaded: true, isPro: true), .cancelPlan,
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
}
