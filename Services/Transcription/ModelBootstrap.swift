import Foundation

/// ITER-058.3 — quick-start model bootstrap: «the user must never wait for 950 MB».
///
/// Mechanism: when onboarding's model page appears, Base (~80 MB, 10–30 s on
/// typical Wi-Fi) starts downloading automatically — the user dictates within a
/// minute. Large V3 Turbo then installs in the background and hot-swaps in when
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
        /// Cloud/Pro became the active path — the local upgrade plan is moot.
        case cancelPlan
        case startDownload
        case swapNow
        case skipLowDisk
    }

    /// Should the onboarding model page auto-start the quick model?
    /// No for Pro (cloud path needs no local model), no when any model already
    /// exists or a download is in flight, no on a nearly-full disk.
    static func shouldQuickStart(
        anyModelDownloaded: Bool,
        isDownloading: Bool,
        isPro: Bool,
        freeBytes: Int64
    ) -> Bool {
        guard !isPro else { return false }
        guard !anyModelDownloaded, !isDownloading else { return false }
        return freeBytes >= minFreeBytesForQuick
    }

    /// What to do about the background best-model upgrade right now.
    /// `pending` = the user is on the quick model awaiting the silent upgrade
    /// (cleared by an explicit model pick, cloud/Pro path, low disk, or a
    /// successful swap).
    ///
    /// Review-hardened invariants:
    /// - Pro / cloud engine active → `.cancelPlan` (never download ~1 GB for a
    ///   user who doesn't transcribe locally, never a false success note).
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
        isPro: Bool,
        engineIsCloud: Bool,
        freeBytes: Int64
    ) -> UpgradeAction {
        guard pending, selectedModel == quickModelId else { return .none }
        if isPro || engineIsCloud { return .cancelPlan }
        if bestDownloaded { return .swapNow }
        guard quickModelLoaded else { return .none }
        if isDownloading { return .none }   // a download is already in flight
        if freeBytes < minFreeBytesForBest { return .skipLowDisk }
        return .startDownload
    }

    /// Free bytes on the user's home volume (the models land under ~/Documents).
    static func freeDiskBytes() -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
