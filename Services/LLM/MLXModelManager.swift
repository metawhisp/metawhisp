import Foundation
import Hub

/// Coordinator for HuggingFace Hub downloads of MLX-format LLM weights
/// (ITER-039 Step 3). Each `ModelSpec` in `ModelRegistry` knows its HF repo
/// (e.g. `mlx-community/Phi-4-mini-instruct-4bit`); this service pulls the
/// weight shards + tokenizer + config into the system Hub cache and exposes
/// the local path back to `LocalLLMService` for the inference loop.
///
/// **Why we use `swift-transformers/Hub` instead of a hand-rolled URLSession**
///   - Already in our dependency graph (transitively via WhisperKit at
///     1.1.9, plus we expose `Hub` as an explicit product in Package.swift).
///   - Free integrity verification (ETag + commit-hash checks vs the remote
///     manifest) — protects against partial downloads.
///   - Resumable: re-running `snapshot(...)` on an existing folder is a
///     metadata-only check, doesn't re-download finished shards.
///   - Standard HF cache layout (`~/.cache/huggingface/hub/<repo>/...`) so
///     other tools (the user's own `huggingface-cli`, our future Apple
///     Foundation Models adapter probe) see the same files.
///
/// **Single-flight invariant.** At most ONE download is active at a time
/// across the whole app — concurrent downloads of multi-GB weight files
/// would saturate the user's network and disk. Subsequent `download(...)`
/// calls while one is in progress throw `ManagerError.downloadInProgress`.
/// The UI greys out other Download buttons while `activeDownloadID != nil`.
///
/// **Background-safe.** Downloads continue while the Settings window is
/// closed because MetaWhisp is a menu-bar-resident app — the process stays
/// alive even when no SwiftUI window is visible. The download Task is owned
/// by this singleton, not by any View, so it's not torn down on view
/// disappear. App quit DOES kill the download, but `Hub.snapshot` is
/// resumable via ETag check so re-running picks up where it left off.
@MainActor
final class MLXModelManager: ObservableObject {
    static let shared = MLXModelManager()

    // MARK: - Public state

    /// `ModelSpec.id` of the currently-downloading model, or nil when idle.
    /// SwiftUI uses this to grey out other cards' Download buttons.
    @Published private(set) var activeDownloadID: String?

    /// Fractional progress 0.0…1.0 of the in-flight download. Updated on
    /// each Hub progress callback. Reset to 0 when no download is active.
    @Published private(set) var progress: Double = 0.0

    /// Bytes downloaded so far for the active job — used to show "X.X / Y.Y
    /// GB" alongside the percentage in the model card.
    @Published private(set) var bytesCompleted: Int64 = 0

    /// Last download error per `ModelSpec.id`. Cleared on the next attempt
    /// for that model. Survives `cancelActiveDownload()` so the UI can show
    /// "Last attempt failed: <reason> — retry?" on the card.
    @Published private(set) var lastError: [String: String] = [:]

    /// `ModelSpec.id` set for every model whose weights are fully present
    /// on disk. Drives the "Make active" vs "Download" branch in the
    /// model-card action button.
    @Published private(set) var downloadedIDs: Set<String> = []

    /// Retry attempt counter for the in-flight download (1-based, max 3).
    /// Shown in the progress label ("Retry 2/3") so users know we're
    /// auto-retrying on transient network errors instead of failing hard.
    @Published private(set) var retryAttempt: Int = 0

    // MARK: - Tunables

    /// Maximum retry attempts on network failures. Total bandoff cap:
    /// initial + 3 retries with exponential delay = up to ~14 s overhead
    /// before user-visible failure.
    private let maxRetries: Int = 3

    /// Base backoff in seconds for retry. Actual wait = base × 2^(attempt-1).
    private let retryBackoffSeconds: Double = 2.0

    /// Multiplier on `ModelSpec.downloadSizeBytes` for the disk-space
    /// precheck headroom. We want roughly 2× the download size free at the
    /// time of download because Hub stages files into `.cache/` before
    /// moving them into place — peak disk use is ~2× the final footprint.
    private let diskHeadroomMultiplier: Double = 2.0

    // MARK: - Internal

    private let hub = HubApi.shared
    /// In-flight Task — keeping a handle lets us cancel via
    /// `cancelActiveDownload()` if the user picks a different model
    /// mid-download.
    private var activeTask: Task<URL, Error>?

    private init() {
        // Warm-load: on launch, mark every ModelSpec.id whose weights are
        // already on disk so the UI renders "Make active" instead of
        // "Download" for past sessions.
        for spec in ModelRegistry.allModels where !spec.isFoundationModels {
            if isOnDisk(spec) {
                downloadedIDs.insert(spec.id)
            }
        }
    }

    // MARK: - API

    /// Where the resolved repo files live, IFF already downloaded.
    /// Used by `LocalLLMService.loadModel(id:)` to find `config.json`,
    /// `tokenizer.json`, and the `*.safetensors` shards.
    func localPath(for spec: ModelSpec) -> URL? {
        guard !spec.hfRepoID.isEmpty else { return nil }
        let repo = Hub.Repo(id: spec.hfRepoID)
        let location = hub.localRepoLocation(repo)
        return FileManager.default.fileExists(atPath: location.path) ? location : nil
    }

    /// True if every required file for this spec is on disk. We don't yet
    /// verify byte-level integrity — Hub already does ETag checks on each
    /// snapshot. We only check the presence of `config.json` + at least one
    /// `.safetensors` shard, which is enough to distinguish "downloaded" from
    /// "interrupted at byte 0".
    private func isOnDisk(_ spec: ModelSpec) -> Bool {
        guard let dir = localPath(for: spec) else { return false }
        let fm = FileManager.default
        let configExists = fm.fileExists(atPath: dir.appending(path: "config.json").path)
        guard configExists else { return false }
        if let contents = try? fm.contentsOfDirectory(atPath: dir.path) {
            return contents.contains { $0.hasSuffix(".safetensors") }
        }
        return false
    }

    /// Free disk space at the Hub cache root, in bytes. Returns 0 if the
    /// query fails — caller treats that as "unknown, allow download".
    func freeDiskBytes() -> Int64 {
        let dir = hub.localRepoLocation(Hub.Repo(id: "_probe"))
            .deletingLastPathComponent()  // strip repo id back to cache root
        do {
            let values = try dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        } catch {
            // Fall back to home volume.
            let home = FileManager.default.homeDirectoryForCurrentUser
            if let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) {
                return Int64(v.volumeAvailableCapacityForImportantUsage ?? 0)
            }
            return 0
        }
    }

    /// Pre-flight check: do we have enough disk + RAM to safely fetch and
    /// later run this model? Throws a descriptive `ManagerError` if not.
    /// Called by `download(_:)` before kicking off Hub.snapshot.
    private func validatePreflight(_ spec: ModelSpec) throws {
        // Disk: need 2× the download size to handle staging.
        let required = Int64(Double(spec.downloadSizeBytes) * diskHeadroomMultiplier)
        let free = freeDiskBytes()
        if free > 0 && free < required {
            let needGB = Double(required) / 1_073_741_824
            let freeGB = Double(free) / 1_073_741_824
            throw ManagerError.insufficientDiskSpace(
                String(format: "Need ~%.1f GB free (you have %.1f GB). Free some space and try again.", needGB, freeGB)
            )
        }

        // RAM: we let the compatibility verdict gate downloads, but if the
        // user somehow taps Download on an incompatible card (shouldn't be
        // possible — button is hidden) we'd rather refuse here than after
        // a 2 GB download.
        let verdict = ModelCompatibility.verdict(for: spec)
        if case .incompatible(let reason) = verdict {
            throw ManagerError.incompatibleHost(reason)
        }
    }

    /// Start downloading `spec`'s weight shards + tokenizer from HF Hub.
    ///
    /// Resolves to the on-disk repo directory once every file is in place.
    /// Throws if another download is in flight, disk space is too low, or
    /// `spec.hfRepoID` is empty (Apple Foundation Models — built into macOS,
    /// not downloadable).
    ///
    /// **Auto-retry.** Network failures (timeouts, DNS hiccups, transient
    /// 5xx) retry up to `maxRetries` times with exponential backoff. The
    /// `retryAttempt` published property surfaces the current attempt in
    /// the UI so the user knows we're not stuck.
    @discardableResult
    func download(_ spec: ModelSpec) async throws -> URL {
        guard !spec.hfRepoID.isEmpty else {
            throw ManagerError.notDownloadable("\(spec.displayName) is built into macOS — no download needed.")
        }
        guard activeDownloadID == nil else {
            throw ManagerError.downloadInProgress(activeDownloadID ?? "?")
        }

        try validatePreflight(spec)

        activeDownloadID = spec.id
        progress = 0
        bytesCompleted = 0
        retryAttempt = 0
        lastError.removeValue(forKey: spec.id)

        let repo = Hub.Repo(id: spec.hfRepoID)
        // Match the file set MLX inference needs:
        //   - `config.json` (model architecture hyperparams)
        //   - `tokenizer.json` + `tokenizer_config.json` (BPE rules + chat template)
        //   - `*.safetensors` shards (the actual weights — usually 1-2 files
        //     for a 4-bit-quantized model at this scale).
        //   - `special_tokens_map.json` if present (BOS/EOS/PAD overrides).
        // We intentionally don't pull `*.bin` or `*.pth` — those are the
        // unquantized fallbacks and would double the download size.
        let globs = [
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "*.safetensors",
        ]

        var lastNetworkError: Error?
        for attempt in 1...maxRetries {
            retryAttempt = attempt
            let task = Task<URL, Error> { [hub] in
                try await hub.snapshot(
                    from: repo,
                    matching: globs,
                    progressHandler: { [weak self] p in
                        Task { @MainActor [weak self] in
                            self?.progress = p.fractionCompleted
                            self?.bytesCompleted = p.completedUnitCount
                        }
                    }
                )
            }
            activeTask = task

            do {
                let url = try await task.value
                activeDownloadID = nil
                activeTask = nil
                progress = 1.0
                retryAttempt = 0
                downloadedIDs.insert(spec.id)
                return url
            } catch is CancellationError {
                // User cancellation — don't retry, surface as-is.
                activeDownloadID = nil
                activeTask = nil
                progress = 0
                retryAttempt = 0
                throw ManagerError.cancelled
            } catch {
                lastNetworkError = error
                NSLog("[ITER-039] download attempt %d/%d failed: %@", attempt, maxRetries, error.localizedDescription)
                if attempt < maxRetries {
                    // Exponential backoff: 2s, 4s, 8s.
                    let delay = retryBackoffSeconds * pow(2.0, Double(attempt - 1))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    if Task.isCancelled {
                        activeDownloadID = nil
                        activeTask = nil
                        progress = 0
                        retryAttempt = 0
                        throw ManagerError.cancelled
                    }
                }
            }
        }

        // All retries exhausted.
        activeDownloadID = nil
        activeTask = nil
        progress = 0
        retryAttempt = 0
        let msg = lastNetworkError?.localizedDescription ?? "Unknown network error"
        lastError[spec.id] = msg
        throw ManagerError.networkFailure(msg)
    }

    /// Cancel the in-flight download, if any. Partial files stay on disk —
    /// next `download(...)` call resumes via Hub's metadata check.
    func cancelActiveDownload() {
        activeTask?.cancel()
        activeTask = nil
        activeDownloadID = nil
        progress = 0
        bytesCompleted = 0
        retryAttempt = 0
    }

    /// Delete the on-disk copy of a downloaded model. Frees the ~2-4 GB of
    /// weight shards from the user's drive. If `LocalLLMService` has this
    /// model loaded, it must be `unloadModel()`'d first — caller's
    /// responsibility (the Settings UI does this in `removeModel(_:)`).
    func remove(_ spec: ModelSpec) throws {
        guard let dir = localPath(for: spec) else { return }
        try FileManager.default.removeItem(at: dir)
        downloadedIDs.remove(spec.id)
        lastError.removeValue(forKey: spec.id)
    }

    // MARK: - Errors

    enum ManagerError: LocalizedError {
        case notDownloadable(String)
        case downloadInProgress(String)
        case insufficientDiskSpace(String)
        case incompatibleHost(String)
        case networkFailure(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notDownloadable(let msg): return msg
            case .downloadInProgress(let id): return "Another model is already downloading: \(id)"
            case .insufficientDiskSpace(let msg): return msg
            case .incompatibleHost(let msg): return "This Mac can't run this model: \(msg)"
            case .networkFailure(let msg): return "Download failed after retries: \(msg)"
            case .cancelled: return "Download cancelled."
            }
        }
    }
}
