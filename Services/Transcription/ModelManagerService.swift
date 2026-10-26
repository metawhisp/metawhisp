import Foundation
import os
import SwiftUI
import WhisperKit

/// Model info with size for UI display.
struct ModelInfo: Identifiable {
    let id: String
    let variant: String
    let displayName: String
    let size: String
    let description: String
}

/// Download phase shown in UI.
enum DownloadPhase: Equatable {
    case idle
    case downloading
    case verifying
    case done
    case failed(String)
}

/// Manages WhisperKit model downloads and caching.
/// Models from HuggingFace repo argmaxinc/whisperkit-coreml (official WhisperKit CoreML).
@MainActor
final class ModelManagerService: ObservableObject {
    private static let log = Logger(subsystem: "com.metawhisp.app", category: "ModelManager")

    @Published var downloadedModels: [String] = []
    @Published var downloadProgress: Double = 0
    @Published var downloadSpeed: String = ""
    @Published var isDownloading = false
    @Published var currentDownloadModel: String?
    @Published var phase: DownloadPhase = .idle
    /// The model whose LOAD into the engine failed (nil = none). Deliberately
    /// separate from `phase`, which describes the DOWNLOAD pipeline: overloading
    /// `.failed` for load errors made the failure invisible while an unrelated
    /// download ran, and that download finishing then erased it — leaving a
    /// broken model showing "ACTIVE" with no reachable RETRY (Codex).
    @Published var failedToLoadModelId: String?

    private var downloadTask: Task<Void, Never>?
    /// The model whose load-failure marker a running retry-download cleared —
    /// restored if that download fails or is cancelled.
    private var loadFailureClearedForRetry: String?

    /// The retry download didn't deliver: the model is exactly as broken as it
    /// was, so put its marker back and keep RETRY reachable.
    func restoreLoadFailureAfterFailedRetry() {
        guard let id = loadFailureClearedForRetry else { return }
        failedToLoadModelId = id
        loadFailureClearedForRetry = nil
    }

    /// The files landed — the auto-loader owns the verdict from here, so the
    /// pending restore is dropped.
    func noteRetryDownloadSucceeded() {
        loadFailureClearedForRetry = nil
    }

    static let models: [ModelInfo] = [
        ModelInfo(id: "large-v3-turbo", variant: "openai_whisper-large-v3_turbo", displayName: "Large V3 Turbo", size: "~950 MB", description: "Best speed/accuracy (recommended)"),
        ModelInfo(id: "large-v3", variant: "openai_whisper-large-v3", displayName: "Large V3", size: "~950 MB", description: "Highest accuracy, slower"),
        ModelInfo(id: "small", variant: "openai_whisper-small", displayName: "Small", size: "~250 MB", description: "Good accuracy, fast"),
        ModelInfo(id: "base", variant: "openai_whisper-base", displayName: "Base", size: "~80 MB", description: "Basic accuracy, very fast"),
        ModelInfo(id: "tiny", variant: "openai_whisper-tiny", displayName: "Tiny", size: "~40 MB", description: "Lowest accuracy, fastest"),
    ]

    static let recommendedModels: [String] = models.map(\.id)

    /// Where this install's speech models are downloaded to and found (F1).
    let folder: ModelFolder

    init(folder: ModelFolder = .current) {
        self.folder = folder
    }

    func fetchAvailableModels() async {
        refreshDownloaded()
    }

    typealias Download = (_ variant: String, _ downloadBase: URL, _ progress: @escaping (Progress) -> Void) async throws -> URL

    /// The real download, into the install's model folder — or, under XCTest,
    /// one that waits offline until it is cancelled, so no test ever writes
    /// into the owner's models (ITER-075 step 0, 0.4).
    static let defaultDownload: Download = NSClassFromString("XCTestCase") != nil
        ? { _, _, _ in
            // In steps: one sleep for "forever" overflows the dispatch deadline
            // and returns at once.
            while true { try await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC) }
        }
        : { variant, downloadBase, progress in
            try await WhisperKit.download(variant: variant, downloadBase: downloadBase, progressCallback: progress)
        }

    /// What `startDownload` calls; tests may swap it.
    var download: Download = ModelManagerService.defaultDownload

    /// Deletes a speech model that keeps failing to load. The Documents folder
    /// is shared with every other copy of MetaWhisp, so only the owner's app
    /// deletes there (ITER-075 step 0, 0.4); a copy's own folder is its own.
    /// Returns whether it deleted.
    @discardableResult
    static func removeBrokenModel(variant: String, identity: AppIdentity = .current,
                                  folder: ModelFolder = .current) -> Bool {
        guard !folder.isShared || identity.mayDeleteSharedModels else {
            NSLog("[ModelBootstrap] the broken model stays — only the owner's app deletes shared models")
            return false
        }
        do {
            try FileManager.default.removeItem(at: folder.speechModels.appendingPathComponent(variant))
            return true
        } catch {
            return false
        }
    }

    func refreshDownloaded() {
        var allModels: [String] = []

        // 1. The install's model folder: ~/Documents/huggingface/… for one from
        //    before 1.4, its own Application Support folder for a new one (F1).
        let hubDir = folder.speechModels
        if let contents = try? FileManager.default.contentsOfDirectory(at: hubDir, includingPropertiesForKeys: nil) {
            allModels += contents.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }
        }

        // 2. Our custom models directory (fallback)
        let dir = AppSettings.shared.modelsDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            allModels += contents.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }
        }

        downloadedModels = Array(Set(allModels))
        Self.log.info("Downloaded models: \(self.downloadedModels)")
    }

    /// Start download. Task is owned by this service, not the calling view.
    func startDownload(_ modelId: String) {
        guard !isDownloading else { return }
        guard let info = Self.models.first(where: { $0.id == modelId }) else { return }

        isDownloading = true
        currentDownloadModel = modelId
        downloadProgress = 0
        downloadSpeed = ""
        phase = .downloading
        // Re-downloading IS the retry for a load failure — clear the marker so
        // the row stops offering RETRY while the retry is running. Remember it:
        // if the retry itself fails, the model is still broken and the marker
        // has to come back, or RETRY disappears forever (Codex).
        if failedToLoadModelId == modelId {
            failedToLoadModelId = nil
            loadFailureClearedForRetry = modelId
        }

        let variant = info.variant
        Self.log.info("Starting download: \(variant)")

        // Capture self strongly — ModelManagerService is held by AppDelegate for app lifetime
        let manager = self

        let download = self.download
        let downloadBase = folder.base
        downloadTask = Task.detached(priority: .userInitiated) {
            do {
                let url = try await download(
                    variant,
                    downloadBase,
                    { progress in
                        Task { @MainActor in
                            let frac = progress.fractionCompleted
                            manager.downloadProgress = frac
                            if frac >= 0.99 && manager.phase == .downloading {
                                manager.phase = .verifying
                            }
                            if let speed = progress.userInfo[.throughputKey] as? Double, speed > 0 {
                                manager.downloadSpeed = String(format: "%.1f MB/s", speed / 1024 / 1024)
                            }
                        }
                    }
                )
                await MainActor.run {
                    Self.log.info("Download complete: \(url.path)")
                    manager.downloadProgress = 1.0
                    manager.isDownloading = false
                    manager.currentDownloadModel = nil
                    manager.downloadSpeed = ""
                    manager.refreshDownloaded()
                    // FREE-4: only mark done if the model is actually on disk; an
                    // interrupted/partial download must surface as failed + retry,
                    // not a false "ready".
                    if manager.isDownloaded(modelId) {
                        // The files landed; the auto-loader now owns the verdict
                        // and will set or clear the load-failure marker itself.
                        manager.noteRetryDownloadSucceeded()
                        manager.phase = .done
                    } else {
                        manager.phase = .failed("Download finished but model files are missing — tap to retry")
                        manager.restoreLoadFailureAfterFailedRetry()
                        Self.log.error("Reported success but model not on disk: \(variant)")
                    }
                }
            } catch {
                await MainActor.run {
                    // ITER-058.3 — an explicit cancelDownload() already reset
                    // the state; don't overwrite .idle with .failed.
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        Self.log.info("Download task ended: cancelled")
                        manager.restoreLoadFailureAfterFailedRetry()
                        return
                    }
                    Self.log.error("Download failed: \(error)")
                    manager.phase = .failed("\(error)")
                    manager.restoreLoadFailureAfterFailedRetry()
                    manager.isDownloading = false
                    manager.downloadSpeed = ""
                    // Keep currentDownloadModel so the error row stays visible
                }
            }
        }
    }

    /// The model is installed: its folder is listed, and no download of it is running or stopped short. A download
    /// moves the model's files into its folder one by one, so the folder is there from the first file on; a
    /// download that failed after it left part of a model, which Try again then took for an installed one and
    /// did not download again (Codex step-2 #2). `currentDownloadModel` names that download until one completes or
    /// is cancelled — it stays set after a failure for the error row — so that model is not installed.
    func isDownloaded(_ modelId: String) -> Bool {
        guard let info = Self.models.first(where: { $0.id == modelId }) else { return false }
        guard currentDownloadModel != modelId else { return false }
        // Exact match (ITER-058.3 review): the old contains-match made
        // "large-v3" report downloaded whenever large-v3_TURBO was on disk
        // ("openai_whisper-large-v3" is a substring of the turbo dir name).
        return downloadedModels.contains { $0 == info.variant }
    }

    /// The model whose download failed — the network went, the disk filled — with whatever part of it its folder
    /// holds. Nil while a download runs and once one completes or is cancelled.
    var failedDownloadModel: String? {
        guard !isDownloading, case .failed = phase else { return nil }
        return currentDownloadModel
    }

    /// ITER-058.3 — cancel the in-flight download (user switched to cloud/Pro
    /// mid-download; nobody needs the remaining megabytes). State resets to
    /// idle; the task's catch recognizes cancellation and stays silent.
    func cancelDownload() {
        guard isDownloading else { return }
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        currentDownloadModel = nil
        downloadProgress = 0
        downloadSpeed = ""
        phase = .idle
        Self.log.info("Download cancelled")
    }

    func variantName(_ modelId: String) -> String? {
        Self.models.first(where: { $0.id == modelId })?.variant
    }
}
