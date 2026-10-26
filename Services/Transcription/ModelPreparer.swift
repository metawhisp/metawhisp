import Combine
import Foundation

/// C5 — whether this Mac can transcribe now, read from the engine the app
/// actually uses, and the one owner of the download that gets it there.
///
/// The onboarding used to call itself ready only when the SELECTED model was
/// loaded, and skipped the quick start and the best-model upgrade for anyone
/// with Pro. The engine is what transcribes: a loaded Base serves while Large
/// is the pick, and a Pro user who keeps the on-device engine still needs a
/// model on disk.
@MainActor
final class ModelPreparer: ObservableObject {
    enum State: Equatable {
        case downloading(Double)
        case loading
        case ready
        case failed(String)
        case lowDisk
    }

    /// What the state is read from.
    struct Facts: Equatable {
        /// The engine in use is the cloud one — chosen, with the Pro proxy or the user's own key behind it
        /// (`TranscriptionCoordinator.usesCloud`, A4). Cloud chosen without either runs on-device.
        var engineIsCloud: Bool
        /// The on-device engine holds a model — Base, Large or another pick.
        var modelLoaded: Bool
        var selectedModelOnDisk: Bool
        /// Set while a download runs.
        var downloadProgress: Double?
        var failure: String?
        var freeBytes: Int64
    }

    /// A full disk, as the practice's box and the Dashboard's card say it (B3).
    nonisolated static let lowDiskTitle = "Not enough disk space for the speech model."
    nonisolated static let lowDiskDetail =
        "Free up about \(ModelBootstrap.minFreeBytesForQuick / 1_000_000) MB, then try again."

    nonisolated static func state(_ facts: Facts) -> State {
        if facts.engineIsCloud { return .ready }
        if facts.modelLoaded { return .ready }
        if let progress = facts.downloadProgress { return .downloading(progress) }
        // A full disk is the plain reason a model can't be got, before any failure: Try again starts no download on
        // it (B3). A model on disk that did not load needs no room, and says so.
        if !facts.selectedModelOnDisk, facts.freeBytes < ModelBootstrap.minFreeBytesForQuick { return .lowDisk }
        if let failure = facts.failure { return .failed(failure) }
        if facts.selectedModelOnDisk { return .loading }
        return .failed("No speech model on this Mac yet.")
    }

    private let modelManager: ModelManagerService
    private let coordinator: TranscriptionCoordinator
    private let settings: AppSettings
    private let freeBytes: () -> Int64
    private var forwarding: AnyCancellable?
    private var statusWatch: AnyCancellable?

    init(modelManager: ModelManagerService,
         coordinator: TranscriptionCoordinator,
         settings: AppSettings = .shared,
         freeBytes: @escaping () -> Int64 = ModelBootstrap.freeDiskBytes) {
        self.modelManager = modelManager
        self.coordinator = coordinator
        self.settings = settings
        self.freeBytes = freeBytes
        // The state is read live; its sources say when it may have changed.
        forwarding = Publishers.Merge3(modelManager.objectWillChange, coordinator.objectWillChange,
                                       settings.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Never cached: a download, a load or an engine switch changes it underneath.
    var state: State {
        let failure: String?
        if case .failed = modelManager.phase {
            failure = "The speech model didn't download."
        } else if modelManager.failedToLoadModelId != nil {
            failure = "The speech model didn't load."
        } else {
            failure = nil
        }
        return Self.state(Facts(
            engineIsCloud: coordinator.usesCloud,
            modelLoaded: holdsModel,
            selectedModelOnDisk: modelManager.isDownloaded(settings.selectedModel),
            downloadProgress: modelManager.isDownloading ? modelManager.downloadProgress : nil,
            failure: failure,
            freeBytes: freeBytes()))
    }

    /// The engine's standing line for the popover: what the user must do
    /// before dictation can run, or the download's progress (A4) — nil while
    /// it is ready or loading. Only the on-device engine is ever unready.
    var statusLine: String? {
        switch state {
        case .downloading(let progress):
            return TranscriptionCoordinator.preparingModel(progress)
        case .failed, .lowDisk:
            return TranscriptionCoordinator.noModelLoaded
        case .loading, .ready:
            return nil
        }
    }

    /// Step-1 review #11 — keeps the coordinator's red line on the engine's
    /// real state: gives it this line, and has it recomputed whenever
    /// readiness may have changed — a download, a load, an engine switch, a
    /// key, Pro.
    func feedStatusLine() {
        coordinator.engineStatusLine = { [weak self] in self?.statusLine }
        statusWatch = Publishers.Merge4(modelManager.objectWillChange.map { _ in () },
                                        settings.objectWillChange.map { _ in () },
                                        coordinator.$loadedWhisperModelId.map { _ in () },
                                        LicenseService.shared.$isPro.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.coordinator.refreshStatusLine() }
        coordinator.refreshStatusLine()
    }

    /// The on-device engine dictation uses holds a model — not merely an id
    /// recorded for one (step-1 review #7).
    private var holdsModel: Bool {
        coordinator.loadedWhisperModelId != nil && coordinator.whisperEngine?.isModelLoaded == true
    }

    /// The onboarding opened. On the first run the on-device engine gets its model (B1). A replay — Settings → Show
    /// onboarding on an install that completed it — prepares nothing: the model pick, the engine and the upgrade
    /// plan are the user's (E3; Codex step-2 #1: the replay switched a Large pick to the Base on disk and could plan
    /// the background upgrade). What ends that: the user's own Try again (`retry`).
    func prepareForOnboarding() {
        guard !settings.hasCompletedOnboarding else {
            NSLog("[ModelPreparer] the onboarding is replayed — nothing prepared; the pick, engine and upgrade plan stay")
            return
        }
        prepareOnDeviceModel()
    }

    /// A4 — cloud is chosen but can't be used (Pro ended, no key of the user's
    /// own), so the on-device engine transcribes in its place and gets its
    /// model now. The on-device choice is left alone: its models are the
    /// user's to pick in Settings.
    func prepareInPlaceOfCloud() {
        guard settings.transcriptionEngine == "cloud", !coordinator.usesCloud else { return }
        NSLog("[ModelPreparer] cloud is chosen but can't be used — the on-device engine stands in")
        prepareOnDeviceModel()
    }

    /// On the on-device engine with no speech model on disk the quick model
    /// starts downloading now; a model already on disk is used as it is —
    /// after a reinstall the pick resets to Large while the files of Base stay.
    private func prepareOnDeviceModel() {
        modelManager.refreshDownloaded()   // launch may not have listed them yet
        let onDisk = ModelManagerService.models.map(\.id).filter(modelManager.isDownloaded)
        if !onDisk.isEmpty {
            if !modelManager.isDownloaded(settings.selectedModel), let model = onDisk.first {
                settings.selectedModel = model   // loaded by the selected-model observer
                NSLog("[ModelPreparer] the pick was not on disk — using %@", model)
            }
            return
        }
        guard ModelBootstrap.shouldQuickStart(anyModelDownloaded: false,
                                              isDownloading: modelManager.isDownloading,
                                              engineIsCloud: coordinator.usesCloud,
                                              freeBytes: freeBytes()) else { return }
        settings.selectedModel = ModelBootstrap.quickModelId
        settings.pendingBestModelUpgrade = true
        modelManager.startDownload(ModelBootstrap.quickModelId)
        NSLog("[ModelBootstrap] ⚡️ Quick start: Base downloading, best model queued for background install")
    }

    /// The practice screen's Try again, after the model could not be got (B2, B3). A model on disk that did not
    /// load downloads again — its files are there, so that takes seconds — and the auto-load after the download
    /// loads it, as Settings' RETRY does. A download that failed is started again by name — part of the model may
    /// be in its folder, and the download goes on from what is there (Codex step-2 #2) — but not on a full disk, as
    /// the quick start would not start one. Otherwise the quick start runs again, which starts nothing on a full
    /// disk — on a completed install too: the press is the user's, where a replay's opening prepares nothing.
    /// Every try is the user's press; nothing here retries by itself.
    func retry() {
        if let model = modelManager.failedToLoadModelId {
            modelManager.startDownload(model)
        } else if let model = modelManager.failedDownloadModel {
            guard freeBytes() >= ModelBootstrap.minFreeBytesForQuick else {
                NSLog("[ModelPreparer] %@ did not download and the disk is full — not started again", model)
                return
            }
            modelManager.startDownload(model)
        } else {
            prepareOnDeviceModel()
        }
    }

    /// The background best-model upgrade's next step, keyed on the engine.
    func upgradeAction() -> ModelBootstrap.UpgradeAction {
        ModelBootstrap.upgradeAction(
            pending: settings.pendingBestModelUpgrade,
            selectedModel: settings.selectedModel,
            // LOADED, not just on disk (Codex): a corrupt quick model must not
            // hand the download slot to the 950 MB upgrade.
            quickModelLoaded: holdsModel && coordinator.loadedWhisperModelId == ModelBootstrap.quickModelId,
            bestDownloaded: modelManager.isDownloaded(ModelBootstrap.bestModelId),
            isDownloading: modelManager.isDownloading,
            engineIsCloud: coordinator.usesCloud,
            freeBytes: freeBytes())
    }
}
