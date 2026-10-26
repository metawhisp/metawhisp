import Foundation

/// ITER-058.3 — quick-start model bootstrap: «the user must never wait for 950 MB».
///
/// Mechanism: when the onboarding opens (`ModelPreparer`), Base (~80 MB, 10–30 s
/// on typical Wi-Fi) starts downloading automatically — the user dictates within
/// a minute. Large V3 Turbo then installs in the background and hot-swaps in when
/// ready (driven by `AppDelegate.driveModelUpgrade()` off the download-phase
/// sink + a launch-time resume).
///
/// Swap safety: `WhisperKitEngine.loadModel` builds the new kit first and
/// replaces the old one atomically under its lock — dictation during the
/// background load keeps using Base, so no idle-gating is needed.
///
/// This enum holds the PURE decision logic (tested); orchestration lives at the
/// call sites.
enum ModelBootstrap {
    static let quickModelId = "base"
    static let bestModelId = "large-v3-turbo"

    /// Large V3 Turbo is ~950 MB on disk plus unpack headroom.
    static let minFreeBytesForBest: Int64 = 2_500_000_000
    /// Base is ~80 MB; refuse quick-start only on a truly full disk.
    static let minFreeBytesForQuick: Int64 = 500_000_000

    enum UpgradeAction: Equatable {
        case none
        /// The cloud engine became the active path — the local upgrade plan is moot.
        case cancelPlan
        case startDownload
        case swapNow
        case skipLowDisk
    }

    /// Should the onboarding auto-start the quick model?
    /// Only for the on-device engine — the cloud one needs no local model, and
    /// Pro alone is no reason to skip (C5: a Pro user may keep transcribing on
    /// the Mac). No when any model already exists or a download is in flight,
    /// no on a nearly-full disk.
    static func shouldQuickStart(
        anyModelDownloaded: Bool,
        isDownloading: Bool,
        engineIsCloud: Bool,
        freeBytes: Int64
    ) -> Bool {
        guard !engineIsCloud else { return false }
        guard !anyModelDownloaded, !isDownloading else { return false }
        return freeBytes >= minFreeBytesForQuick
    }

    /// What to do about the background best-model upgrade right now.
    /// `pending` = the user is on the quick model awaiting the silent upgrade
    /// (cleared by an explicit model pick, cloud/Pro path, low disk, or a
    /// successful swap).
    ///
    /// Review-hardened invariants:
    /// - Cloud engine active → `.cancelPlan` (never download ~1 GB for a user
    ///   who doesn't transcribe locally, never a false success note). Keyed on
    ///   the engine, not on Pro (C5): Pro alone used to cancel it, leaving a
    ///   Pro user who kept the on-device engine on Base for good.
    /// - Quick model not WORKING yet → `.none`: Base always comes first. Not
    ///   merely "on disk" (Codex review): a corrupt Base that fails to load
    ///   used to let the 950 MB download start, putting the user right back
    ///   behind the wall the quick start exists to remove.
    static func upgradeAction(
        pending: Bool,
        selectedModel: String,
        quickModelLoaded: Bool,
        bestDownloaded: Bool,
        isDownloading: Bool,
        engineIsCloud: Bool,
        freeBytes: Int64
    ) -> UpgradeAction {
        guard pending, selectedModel == quickModelId else { return .none }
        if engineIsCloud { return .cancelPlan }
        if bestDownloaded { return .swapNow }
        guard quickModelLoaded else { return .none }
        if isDownloading { return .none }   // a download is already in flight
        if freeBytes < minFreeBytesForBest { return .skipLowDisk }
        return .startDownload
    }

    /// Cloud/Pro just won — which in-flight download must die?
    ///
    /// The best model always: nobody transcribing in the cloud needs ~1 GB more.
    /// The quick model only when the quick-start bootstrap owns it (Codex: the
    /// old check named the best model alone, so an auto-started Base kept
    /// downloading after the user had explicitly opted out of local). A local
    /// model the user picked by hand in Settings is theirs to keep.
    static func shouldCancelDownload(currentDownloadModel: String?, quickStartOwned: Bool) -> Bool {
        guard let model = currentDownloadModel else { return false }
        if model == bestModelId { return true }
        return quickStartOwned && model == quickModelId
    }

    /// Free bytes on the user's home volume, where the model folder is (`ModelFolder`).
    static func freeDiskBytes() -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
