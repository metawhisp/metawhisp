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

    private var downloadTask: Task<Void, Never>?

    static let models: [ModelInfo] = [
        ModelInfo(id: "large-v3-turbo", variant: "openai_whisper-large-v3_turbo", displayName: "Large V3 Turbo", size: "~950 MB", description: "Best speed/accuracy (recommended)"),
        ModelInfo(id: "large-v3", variant: "openai_whisper-large-v3", displayName: "Large V3", size: "~950 MB", description: "Highest accuracy, slower"),
        ModelInfo(id: "small", variant: "openai_whisper-small", displayName: "Small", size: "~250 MB", description: "Good accuracy, fast"),
        ModelInfo(id: "base", variant: "openai_whisper-base", displayName: "Base", size: "~80 MB", description: "Basic accuracy, very fast"),
        ModelInfo(id: "tiny", variant: "openai_whisper-tiny", displayName: "Tiny", size: "~40 MB", description: "Lowest accuracy, fastest"),
    ]

    static let recommendedModels: [String] = models.map(\.id)

    func fetchAvailableModels() async {
        refreshDownloaded()
    }

    /// Default location where WhisperKit / HubApi stores downloaded models.
    static let defaultHubPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")

    func refreshDownloaded() {
        var allModels: [String] = []

        // 1. WhisperKit default: ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/
        let hubDir = Self.defaultHubPath
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

        let variant = info.variant
        Self.log.info("Starting download: \(variant)")

        // Capture self strongly — ModelManagerService is held by AppDelegate for app lifetime
        let manager = self

        downloadTask = Task.detached(priority: .userInitiated) {
            do {
                let url = try await WhisperKit.download(
                    variant: variant,
                    progressCallback: { progress in
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
                    manager.phase = .done
                    manager.isDownloading = false
                    manager.currentDownloadModel = nil
                    manager.downloadSpeed = ""
                    manager.refreshDownloaded()
                }
            } catch {
                await MainActor.run {
                    Self.log.error("Download failed: \(error)")
                    manager.phase = .failed("\(error)")
                    manager.isDownloading = false
                    manager.downloadSpeed = ""
                    // Keep currentDownloadModel so the error row stays visible
                }
            }
        }
    }

    func isDownloaded(_ modelId: String) -> Bool {
        guard let info = Self.models.first(where: { $0.id == modelId }) else { return false }
        return downloadedModels.contains { $0.contains(info.variant) || $0 == info.variant }
    }

    func variantName(_ modelId: String) -> String? {
        Self.models.first(where: { $0.id == modelId })?.variant
    }
}
