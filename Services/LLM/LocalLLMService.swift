import Foundation
import FoundationModels   // ITER-044 — Apple on-device LLM. Symbols used ONLY under @available(macOS 26); weak-linked (deployment target macOS 14).
import MLX
import MLXNN
import MLXRandom
import Tokenizers

/// Singleton bridge between MetaWhisp services and an MLX-hosted local LLM.
///
/// ITER-039 Phase 4 wiring: `loadModel(id:)` reads a downloaded MLX
/// checkpoint from `MLXModelManager.shared.localPath(for: spec)`, builds the
/// `Phi3Model` (vendored from `mlx-swift-examples 2.29.1`), applies 4-bit
/// quantization to match the on-disk weights, loads the safetensors shards
/// into the module tree, and initializes the BPE tokenizer via
/// `swift-transformers` (already in our graph at 1.1.x).
///
/// `generate(prompt:)` streams tokens via an `AsyncStream<String>`. Caller
/// iterates the stream and concatenates — typical use:
///
/// ```swift
/// var out = ""
/// for await chunk in LocalLLMService.shared.generate(prompt: "...") {
///     out += chunk
/// }
/// ```
///
/// **Threading.** Class is `@MainActor` for two reasons: (1) MLX inference
/// runs synchronously on the calling thread (the model's tensor ops dispatch
/// to the Metal command queue but the host call returns immediately); (2)
/// SwiftUI observes the `@Published` props directly. Running inference on
/// `MainActor` does NOT block the UI thread visibly because each forward
/// pass is dominated by GPU work — we hand the host thread back via
/// `await Task.yield()` between sampled tokens.
@MainActor
final class LocalLLMService: ObservableObject {
    static let shared = LocalLLMService()

    // MARK: - Public state

    /// `true` iff a model is loaded and ready to serve tokens.
    @Published private(set) var isReady: Bool = false
    /// Currently active model's `ModelSpec.id`, or nil if none loaded.
    @Published private(set) var currentModelID: String?
    /// ITER-051 F1.4 — true while a model build/load is in flight; drives the
    /// Settings card's «Loading…» state and the re-entrancy guard.
    @Published private(set) var isLoading: Bool = false
    /// `true` while a `generate(...)` call is mid-stream. Single-stream
    /// guarantee: a `ModelContainer` is single-tenant for MLX inference.
    @Published private(set) var isGenerating: Bool = false
    /// Last load/generate error surfaced to UI ("Failed to load: <msg>").
    @Published private(set) var lastError: LocalLLMError?

    // MARK: - Internal storage

    private var model: Phi3Model?
    private var tokenizer: (any Tokenizer)?
    /// EOS token id sniffed from `tokenizer_config.json` (Phi-3 uses 32007;
    /// Phi-4 uses 200020 or similar — varies). Filled in during loadModel.
    private var stopTokens: Set<Int> = []

    /// ITER-044 — which backend the currently-loaded model uses. `.mlx` for the
    /// vendored Phi models, `.foundationModels` for Apple's on-device LLM. Set
    /// on load; reset on unload. A plain enum with no availability annotation,
    /// so it never drags an FM symbol below macOS 26 (I2).
    private var backend: LocalLLMBackend = .mlx

    /// Serialization fence for `generate(...)`. MLX is a single-tenant
    /// process-wide context — running two prefills/decode loops in parallel
    /// corrupts state. Previously we DROPPED the second concurrent caller
    /// with `guard !isGenerating else { return }`, which made advice / coach
    /// silently fail (`Local model returned no tokens`) when meeting +
    /// dictation overlapped. Now we QUEUE: each new caller awaits the
    /// previous task's completion before starting its own MLX work. The
    /// queue is effectively a linked list of pending Tasks; ordering is
    /// FIFO (oldest predecessor first).
    private var pendingGeneration: Task<Void, Never>?

    private init() {}

    /// MAIN-THREAD MLX initialization. Call from `applicationDidFinishLaunching`.
    /// First-touch of MLX / MLXRandom on a non-main thread (verified
    /// 2026-05-13 via traces sync.0 → silence) SIGKILLs the process; the
    /// Metal context init has main-thread affinity. Doing one trivial
    /// allocation here teaches the process-wide MLX state to use the
    /// already-initialized Metal device on subsequent background-thread
    /// calls. Cheap (~10 ms) and idempotent — safe to call multiple times.
    ///
    /// **Memory bounds.** MLX defaults `cacheLimit = memoryLimit` (uncapped
    /// on Macs with plenty of RAM). This means every `eval()` accretes
    /// Metal command-buffer arenas into a reuse pool that never shrinks.
    /// On 2026-05-21 the user's app climbed to 35 GB resident after six
    /// 3000-token Phi-4 prefills back-to-back — system froze. Root cause:
    /// uncapped MLX buffer pool. Fix: bound both limits to sane values
    /// matching Phi-4 mini's working set (model ~2 GB + KV cache ~500 MB
    /// + activations ~500 MB + headroom).
    ///
    /// Cache 512 MB — Metal kernel cache for buffer reuse; small but real
    ///   perf win on repeated shapes. 0 would disable reuse entirely.
    /// MemoryLimit 6 GB — hard ceiling for all MLX allocations. Beyond
    ///   this the next allocation triggers cache eviction first; if
    ///   still over, MLX may abort. 6 GB comfortably fits the working
    ///   set with overhead, well below user pressure even on 16 GB Macs.
    static func prewarmMLX() {
        NSLog("[ITER-039] pre-warming MLX on main thread")
        MLXRandom.seed(0x4D575F50484934)

        // Bound memory BEFORE the first allocation so the limits are in
        // effect for prewarm itself. `Memory` is top-level in mlx-swift
        // (the `GPU` namespace has deprecated forwarders only).
        MLX.Memory.cacheLimit = 512 * 1024 * 1024            // 512 MB buffer reuse pool
        MLX.Memory.memoryLimit = 6 * 1024 * 1024 * 1024      // 6 GB total ceiling
        NSLog("[ITER-039] MLX memory bounds: cacheLimit=512MB, memoryLimit=6GB")

        let probe = MLXArray.zeros([1], dtype: .float32)
        eval(probe)
        NSLog("[ITER-039] ✅ MLX warmed up (Metal context initialized)")
    }

    // MARK: - Load

    /// ITER-051 F1.4 — re-entrancy-safe wrapper. A second click on «Load now»
    /// during the ~12 s load used to spawn a concurrent build; loading the
    /// already-ready model was a full silent reload. Both are no-ops now, and
    /// failures land in `lastError` so the Settings card can show WHY.
    func loadModel(id: String) async throws {
        if isLoading {
            NSLog("[ITER-039] loadModel(%@) ignored — a load is already in flight", id)
            return
        }
        if isReady, currentModelID == id { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await performLoad(id: id)
        } catch {
            lastError = (error as? LocalLLMError) ?? .mlxFailure(error.localizedDescription)
            NSLog("[ITER-039] ❌ loadModel(%@) failed: %@", id, error.localizedDescription)
            throw error
        }
    }

    private func performLoad(id: String) async throws {
        guard let spec = ModelRegistry.model(byID: id) else {
            throw LocalLLMError.unknownModelID(id)
        }
        // ITER-044 — Apple Foundation Models is a distinct backend: no download,
        // no MLX build, served on-device by the OS. Route it here BEFORE the
        // MLX weight-loading path.
        switch FoundationModelsSupport.backend(for: spec) {
        case .foundationModels:
            guard #available(macOS 26, *) else {
                throw LocalLLMError.notSupportedYet(
                    "Apple Foundation Models requires macOS 26 (Tahoe). Update macOS or pick a downloadable model."
                )
            }
            try loadFoundationModels(id: id)
            return
        case .mlx:
            break   // fall through to the MLX weight-loading path below
        }
        guard let dir = MLXModelManager.shared.localPath(for: spec) else {
            throw LocalLLMError.modelNotDownloaded(
                "\(spec.displayName) weights not on disk. Tap Download in Settings → AI Models first."
            )
        }

        NSLog("[ITER-039] loading model from %@ (MLX on GCD, tokenizer on main)", dir.path)

        // MLX work (Phi3Model init + quantize + weight load + eval) runs
        // SYNCHRONOUSLY on a real Foundation `DispatchQueue.global` thread.
        // Tried `Task.detached` first — failed: MLX's first allocation
        // crashes on Swift Concurrency's cooperative pool (likely Metal-
        // context / TLS init issue). Real GCD threads inherit the
        // process-wide MLX state correctly.
        //
        // Tokenizer init is async (URL-aware), so it runs back on MainActor
        // after MLX work returns. Process-wide: ~12 s total — UI may show
        // a brief stall on the MLX shard load step but doesn't trip the
        // AppKit watchdog (verified: dispatch-queue work does not block
        // the main runloop).
        let capturedDir = dir
        let buildResult = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<MLXBuildResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let r = try Self.buildModelSync(modelDir: capturedDir)
                    cont.resume(returning: r)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        // Tokenizer load — back on MainActor, async-friendly.
        NSLog("[ITER-039 trace] step 6 — loading tokenizer (main)")
        let tokenizer: any Tokenizer
        do {
            tokenizer = try await AutoTokenizer.from(modelFolder: dir)
        } catch {
            throw LocalLLMError.mlxFailure(
                "Tokenizer init failed: \(error.localizedDescription)"
            )
        }
        // ITER-051 F1.1 fix — a single eos id is NOT enough. Phi-4's chat
        // template ends every turn with `<|end|>` (200020, config.json's
        // eos_token_id) while the tokenizer reports `<|endoftext|>` (199999).
        // The old code stopped only on the tokenizer's id, so chat-formatted
        // generations never hit EOS and always ran to maxTokens. Collect ALL
        // plausible stop ids and stop on any of them.
        var stops = buildResult.configEos
        if let tokEos = tokenizer.eosTokenId { stops.insert(tokEos) }
        if let endId = tokenizer.convertTokenToId("<|end|>") { stops.insert(endId) }
        stops.remove(0)  // never treat id 0 as a stop (parse-failure sentinel)

        self.model = buildResult.model
        self.tokenizer = tokenizer
        self.stopTokens = stops
        self.backend = .mlx
        self.currentModelID = id
        self.isReady = true
        self.lastError = nil
        NSLog("[ITER-039] ✅ %@ ready (stops=%@)", spec.displayName, stops.sorted().description)
    }

    /// Result of the synchronous MLX build phase. Crossed back to MainActor
    /// after the dispatch-queue work completes.
    private struct MLXBuildResult: @unchecked Sendable {
        let model: Phi3Model
        let configEos: Set<Int>  // eos_token_id from config.json (Int or [Int])
    }

    /// Synchronous MLX build — runs on a `DispatchQueue.global` thread.
    /// No async / await inside. Does Phi3Model construction + quantize +
    /// safetensors load + eval. Returns the materialized model.
    private nonisolated static func buildModelSync(modelDir: URL) throws -> MLXBuildResult {
        NSLog("[ITER-039 trace] sync.0 — buildModelSync on thread %@",
              Thread.isMainThread ? "MAIN ⚠️" : "background ✓")

        // Pre-warm MLX state on this thread.
        MLXRandom.seed(0x4D575F50484934)
        let warmup = MLXArray.zeros([1], dtype: .float32)
        eval(warmup)
        NSLog("[ITER-039 trace] sync.0.5 — MLX warmed up")

        // 1. Config.
        let configURL = modelDir.appending(path: "config.json")
        let configData = try Data(contentsOf: configURL)
        let phiConfig = try JSONDecoder().decode(Phi3Configuration.self, from: configData)
        let rawConfig = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any] ?? [:]
        let quantization = rawConfig["quantization"] as? [String: Any]
        let qGroupSize = quantization?["group_size"] as? Int ?? 64
        let qBits = quantization?["bits"] as? Int ?? 4
        let isQuantized = (quantization != nil)
        NSLog("[ITER-039 trace] sync.1 — config decoded")

        // 2. Build model.
        NSLog("[ITER-039 trace] sync.2a — building Phi3Model")
        let model = Phi3Model(phiConfig)
        NSLog("[ITER-039 trace] sync.2b — Phi3Model built")

        // 3. Quantize.
        if isQuantized {
            NSLog("[ITER-039 trace] sync.3a — quantizing bits=%d group=%d", qBits, qGroupSize)
            quantize(model: model, groupSize: qGroupSize, bits: qBits)
            NSLog("[ITER-039 trace] sync.3b — quantize done")
        }

        // 4. Load safetensors.
        let fm = FileManager.default
        let allFiles = try fm.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
        let shards = allFiles
            .filter { $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !shards.isEmpty else {
            throw LocalLLMError.mlxFailure("No .safetensors shards in \(modelDir.lastPathComponent)")
        }
        var weights: [String: MLXArray] = [:]
        for shard in shards {
            let arrays = try MLX.loadArrays(url: shard)
            for (k, v) in arrays { weights[k] = v }
        }
        NSLog("[ITER-039 trace] sync.4 — loaded %d weight tensors", weights.count)

        // 5. Apply + eval.
        let params = ModuleParameters.unflattened(weights)
        _ = model.update(parameters: params)
        NSLog("[ITER-039 trace] sync.5a — model.update done")
        eval(model)
        NSLog("[ITER-039 trace] sync.5b — eval(model) done")

        // 6. EOS ids from config.json — the authoritative source (the old
        // code read `eos_token_id` from tokenizer_config.json, which doesn't
        // carry that key for Phi-4 → fallback was always 0). HF configs use
        // either a single Int or an array of Ints here.
        var configEos: Set<Int> = []
        if let n = rawConfig["eos_token_id"] as? Int {
            configEos.insert(n)
        } else if let arr = rawConfig["eos_token_id"] as? [Int] {
            configEos.formUnion(arr)
        }

        return MLXBuildResult(model: model, configEos: configEos)
    }

    // (Old `performHeavyLoad` removed 2026-05-13: it ran on Swift
    // Concurrency's cooperative pool which MLX cannot initialize against.
    // Replaced by `buildModelSync` running on `DispatchQueue.global`. See
    // `loadModel`.)

    func unloadModel() {
        model = nil
        tokenizer = nil
        currentModelID = nil
        isReady = false
        lastError = nil
        stopTokens = []
        backend = .mlx   // ITER-044 — back to the default backend
        NSLog("[ITER-039] model unloaded")
    }

    /// ITER-044 (Codex review) — drop the in-memory loaded-model state so the
    /// app falls back to the cloud path (`isReady == false`) instead of leaving
    /// a stale backend serving requests. Unlike `unloadModel()` it preserves
    /// `lastError` (the caller sets a meaningful one) and doesn't log a
    /// misleading "model unloaded".
    private func resetLoadedModelState() {
        model = nil
        tokenizer = nil
        stopTokens = []
        backend = .mlx
        currentModelID = nil
        isReady = false
    }

    // MARK: - Apple Foundation Models backend (ITER-044, macOS 26+)

    /// Bring the on-device Apple model online. Checks
    /// `SystemLanguageModel.default.availability`: `.available` flips us into
    /// the FM backend (`isReady = true`, no weights, no download); any
    /// `.unavailable(reason)` throws a recoverable, human-readable error so the
    /// auto-loader / Settings fall back to cloud (I3) while telling the user why.
    @available(macOS 26, *)
    private func loadFoundationModels(id: String) throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            // Drop any stale MLX model so the two backends never coexist.
            self.model = nil
            self.tokenizer = nil
            self.stopTokens = []
            self.backend = .foundationModels
            self.currentModelID = id
            self.isReady = true
            self.lastError = nil
            NSLog("[ITER-044] ✅ Apple Foundation Models ready (on-device)")
        case .unavailable(let reason):
            // Codex review — the user just made FM their active model. If FM
            // can't serve, don't keep silently serving a previously-loaded MLX
            // model under the new selection: drop to cloud (isReady = false)
            // and report why (I3). loadModel's catch then records lastError.
            resetLoadedModelState()
            let mapped = FoundationModelsSupport.message(for: Self.fmReason(from: reason))
            NSLog("[ITER-044] ❌ Foundation Models unavailable: %@", mapped)
            throw LocalLLMError.foundationModelsUnavailable(mapped)
        }
    }

    /// Translate Apple's availability reason into our OS-independent mirror so
    /// the user-facing copy lives in the pure, testable `FoundationModelsSupport`.
    @available(macOS 26, *)
    private static func fmReason(
        from reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> FMUnavailableReason {
        switch reason {
        case .deviceNotEligible:            return .deviceNotEligible
        case .appleIntelligenceNotEnabled:  return .appleIntelligenceNotEnabled
        case .modelNotReady:                return .modelNotReady
        @unknown default:                   return .modelNotReady
        }
    }

    /// One-shot FM completion. `system` becomes the session instructions (empty
    /// → none, used by the `generate` bridge whose prompt already carries the
    /// system block). Any `GenerationError` (guardrail, context overflow, rate
    /// limit, …) is rethrown as a recoverable `LocalLLMError` — the consumer's
    /// catch treats it exactly like an MLX failure (I1).
    @available(macOS 26, *)
    private func fmComplete(
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Float
    ) async throws -> String {
        let instructions: String? = system.isEmpty ? nil : system
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(
            temperature: Double(temperature),
            maximumResponseTokens: maxTokens
        )
        do {
            let response = try await session.respond(to: user, options: options)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("[ITER-044] FM response: %d chars out (user=%d chars, maxTokens=%d)", text.count, user.count, maxTokens)
            guard !text.isEmpty else {
                throw LocalLLMError.foundationModelsFailure("Apple model returned an empty response.")
            }
            return text
        } catch let error as LocalLLMError {
            throw error
        } catch {
            // Codex review (I3) — if FM as a whole just went unavailable (Apple
            // Intelligence toggled off mid-session, on-device assets pulled),
            // drop to cloud globally so subsequent requests stop hammering a
            // dead backend. A prompt-specific failure (guardrail / context
            // overflow) leaves FM ready and fails only this request —
            // consistent with an MLX failure (the failedAttempt cap bounds it).
            NSLog("[ITER-044] ❌ FM request failed: %@", error.localizedDescription)
            if case .unavailable = SystemLanguageModel.default.availability {
                NSLog("[ITER-044] FM became unavailable mid-session — falling back to cloud")
                resetLoadedModelState()
            }
            throw LocalLLMError.foundationModelsFailure(error.localizedDescription)
        }
    }

    /// Bridge `fmComplete` into the `AsyncStream<String>` shape `generate`
    /// promises. FM output isn't token-streamed here (all `generate` consumers
    /// concatenate to a final string anyway — StructuredGenerator.callLocalLLM
    /// and completeBlocking's MLX path): we run one `respond` and yield it as a
    /// single chunk. Still honours the FIFO queue (avoid concurrent on-device
    /// requests) and consumer cancellation (Esc on the pill).
    @available(macOS 26, *)
    private func fmGenerate(
        prompt: String,
        maxTokens: Int,
        temperature: Float
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            let cancelFlag = CancelFlag()
            continuation.onTermination = { _ in cancelFlag.set() }

            let predecessor = self.pendingGeneration
            let myTask = Task { @MainActor in
                await predecessor?.value
                guard isReady, backend == .foundationModels, !cancelFlag.isSet() else {
                NSLog("[ITER-044] FM generate skipped — empty stream (ready=%@, backendIsFM=%@, cancelled=%@)", isReady ? "yes" : "no", backend == .foundationModels ? "yes" : "no", cancelFlag.isSet() ? "yes" : "no")
                    continuation.finish()
                    return
                }
                isGenerating = true
                do {
                    let text = try await fmComplete(
                        system: "", user: prompt,
                        maxTokens: maxTokens, temperature: temperature)
                    if !cancelFlag.isSet() { continuation.yield(text) }
                } catch {
                    NSLog("[ITER-044] FM generate error: %@", error.localizedDescription)
                }
                isGenerating = false
                continuation.finish()
            }
            self.pendingGeneration = myTask
        }
    }

    // MARK: - Generation

    /// Stream tokens for `prompt` via Phi-3/4's chat template. Yields each
    /// newly-decoded text chunk (typically 1-3 chars per token after
    /// detokenization). Finishes when EOS is sampled OR `maxTokens` is hit.
    func generate(
        prompt: String,
        maxTokens: Int = 512,
        temperature: Float = 0.7
    ) -> AsyncStream<String> {
        // ITER-044 — Foundation Models path. The prompt already has system+user
        // combined by the caller, so it goes to a session with no separate
        // instructions. FM has no in-process/Metal state, so no GCD hop is
        // needed — but we still queue behind any in-flight generation to avoid
        // hammering the shared on-device model with concurrent requests.
        if backend == .foundationModels, #available(macOS 26, *) {
            return fmGenerate(prompt: prompt, maxTokens: maxTokens, temperature: temperature)
        }
        return AsyncStream { continuation in
            // Capture the current pending generation (if any) so the new
            // request queues BEHIND it — first-come-first-served. MLX is a
            // single-tenant context; running two prefills/decode loops
            // simultaneously corrupts state. We used to DROP the second
            // caller, which made advice/coach silently fail when calls
            // overlapped. Now we wait.
            //
            // Grab actor state up front so we can hop to GCD thread for the
            // actual MLX work. Like `loadModel`, MLX inference cannot run on
            // Swift Concurrency's cooperative pool; running it directly on
            // MainActor froze the user's Mac for 30+ s on a 3k-prompt
            // (2026-05-13 incident).
            // ITER-051 F1.9 — consumer-driven cancellation. When the caller
            // stops iterating the stream (task cancelled, Esc on the pill,
            // popup dismissed), `onTermination` fires and the decode loop
            // exits within one token instead of burning through maxTokens
            // into the void while the next caller waits in the FIFO queue.
            let cancelFlag = CancelFlag()
            continuation.onTermination = { _ in cancelFlag.set() }

            let predecessor = self.pendingGeneration
            let myTask = Task { @MainActor in
                // Wait for the prior generation (if any) to finish before
                // touching MLX. `Task.value` returns immediately when the
                // predecessor is already complete.
                await predecessor?.value

                guard isReady, let model = self.model, let tokenizer = self.tokenizer else {
                    NSLog("[ITER-039] generate called but model not ready")
                    continuation.finish()
                    return
                }
                // Cancelled while queued behind a predecessor — skip the MLX
                // work entirely.
                guard !cancelFlag.isSet() else {
                    continuation.finish()
                    return
                }
                isGenerating = true

                let stops = self.stopTokens
                // Hop to a real GCD thread for the inference loop. To make
                // the @MainActor task block until that work completes (so
                // the next queued caller sees us as still in-flight via
                // `predecessor?.value`), wrap the dispatch in
                // `withCheckedContinuation`.
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        Self.runGenerationSync(
                            prompt: prompt,
                            maxTokens: maxTokens,
                            temperature: temperature,
                            stopTokens: stops,
                            model: model,
                            tokenizer: tokenizer,
                            isCancelled: { cancelFlag.isSet() },
                            yield: { continuation.yield($0) }
                        )
                        cont.resume()
                    }
                }
                continuation.finish()
                isGenerating = false
            }
            self.pendingGeneration = myTask
        }
    }

    /// Synchronous inference loop — must run on a Foundation GCD thread,
    /// NOT on MainActor (would freeze UI) and NOT on Swift Concurrency
    /// cooperative pool (MLX state init issue). Mirrors the same pattern
    /// as `buildModelSync`.
    /// Thread-safe cancellation flag bridged from the AsyncStream's
    /// `onTermination` (arbitrary thread) into the GCD decode loop.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private nonisolated static func runGenerationSync(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        stopTokens: Set<Int>,
        model: Phi3Model,
        tokenizer: any Tokenizer,
        isCancelled: @escaping @Sendable () -> Bool,
        yield: @escaping @Sendable (String) -> Void
    ) {
        // 1. Apply chat template (wraps in <|user|>…<|assistant|> for Phi).
        let messages: [[String: String]] = [["role": "user", "content": prompt]]
        let inputIds: [Int]
        do {
            inputIds = try tokenizer.applyChatTemplate(messages: messages)
        } catch {
            NSLog("[ITER-039] chat template failed: %@", error.localizedDescription)
            return
        }
        NSLog("[ITER-039] prompt tokens: %d (on GCD)", inputIds.count)

        // Memory diagnostic — before generation. Useful for spotting cache
        // creep. Logged as activeMB/cacheMB pair.
        let memBefore = MLX.Memory.snapshot()

        // 2. KV cache (one per attention layer).
        let numLayers = model.kvHeads.count
        let cache: [KVCache] = (0..<numLayers).map { _ in KVCache() }

        // 3. Prefill — single forward over the entire prompt.
        var input = MLXArray(inputIds.map { Int32($0) }).expandedDimensions(axis: 0)
        var logits = model(input, cache: cache)
        eval(logits)
        var lastLogit = logits[0..., -1, 0...]

        // 4. Decode loop. F1.9 — cancellation checked every token so a
        // dismissed consumer stops costing GPU time within ~1 token.
        var generated = 0
        for _ in 0..<maxTokens {
            if isCancelled() {
                NSLog("[ITER-039] generation cancelled after %d tokens", generated)
                break
            }
            let next = Self.sampleTokenSync(logits: lastLogit, temperature: temperature)
            if stopTokens.contains(next) { break }
            let piece = tokenizer.decode(tokens: [next], skipSpecialTokens: true)
            if !piece.isEmpty {
                yield(piece)
            }
            generated += 1
            input = MLXArray([Int32(next)]).expandedDimensions(axis: 0)
            logits = model(input, cache: cache)
            eval(logits)
            lastLogit = logits[0..., -1, 0...]
        }

        // 5. Release the MLX buffer pool. Without this, mlx-swift retains
        // Metal arenas from intermediate compute across calls. On 2026-05-21
        // six 3000-token Phi-4 prefills with DIFFERENT prompt sizes (3426,
        // 3607, 2768, 3582, 3250, 3245) accreted ~35 GB of "recently used"
        // buffers because MLX's reuse heuristic only matches identical
        // shapes — and our prompt sizes vary per Insight tick. The
        // `Memory.cacheLimit = 512MB` cap set in `prewarmMLX` already
        // bounds growth, but explicit `clearCache()` here drops cached
        // buffers immediately so each generation returns to a clean
        // baseline. mlx-swift docs (Memory.swift:355) confirm this is
        // the supported reclaim path.
        MLX.Memory.clearCache()
        NSLog("[ITER-039] generation finished: %d tokens out, %d prompt tokens, cap hit=%@", generated, inputIds.count, generated >= maxTokens ? "yes" : "no")

        let memAfter = MLX.Memory.snapshot()
        NSLog("[ITER-039 mem] active=%dMB→%dMB  cache=%dMB→%dMB  peak=%dMB",
              memBefore.activeMemory / (1024 * 1024),
              memAfter.activeMemory / (1024 * 1024),
              memBefore.cacheMemory / (1024 * 1024),
              memAfter.cacheMemory / (1024 * 1024),
              memAfter.peakMemory / (1024 * 1024))
    }

    /// Blocking convenience wrapper used by services that need a single
    /// concatenated response (StructuredGenerator, AdviceService,
    /// MemoryExtractor, TaskExtractor, MeetingCoachService, ChatService,
    /// RealtimeScreenReactor — anyone with a Pro-proxy → BYOK → LocalLLM
    /// branch). Truncates the user prompt to keep the Mac responsive (3k+
    /// token prefill prefill froze user's machine 2026-05-13 — see
    /// `callLocalLLM` comment in StructuredGenerator).
    ///
    /// - Parameters:
    ///   - system: instruction / role-setting block; shipped verbatim
    ///   - user: variable content (transcript / context); truncated to
    ///     `maxUserChars` if longer
    ///   - maxUserChars: cap on user content. 2000 chars ≈ 600-700 tokens
    ///     on Phi tokenizers — fits comfortably in Phi-4-mini's 4k base
    ///     context, leaves room for system + output without OOMing the
    ///     KV cache.
    ///   - maxTokens: response token budget (default 384 — enough for
    ///     structured JSON, short advice, single memory extraction).
    ///   - temperature: 0.3 for structured tasks (consistency), higher
    ///     for creative.
    func completeBlocking(
        system: String,
        user: String,
        maxUserChars: Int = 2000,
        maxTokens: Int = 384,
        temperature: Float = 0.3
    ) async throws -> String {
        let cappedUser = user.count > maxUserChars
            ? String(user.prefix(maxUserChars)) + "\n[local-LLM truncation]"
            : user
            NSLog("[ITER-039] completeBlocking: system=%d chars, user=%d chars%@, maxTokens=%d, backend=%@", system.count, cappedUser.count, user.count > maxUserChars ? " (truncated from \(user.count))" : "", maxTokens, backend == .foundationModels ? "fm" : "mlx")

        // ITER-044 — Apple Foundation Models backend: one out-of-process
        // `respond` call, no MLX/GCD dance. `system` maps to the session's
        // instructions (Apple treats it specially). On FM failure the thrown
        // error propagates exactly like an MLX failure — the consumer's
        // existing catch handles fallback (I1/I3).
        if backend == .foundationModels {
            if #available(macOS 26, *) {
                return try await fmComplete(
                    system: system, user: cappedUser,
                    maxTokens: maxTokens, temperature: temperature)
            }
            // Unreachable: `backend` is only set to `.foundationModels` under
            // an `#available(macOS 26)` guard in `loadFoundationModels`.
            throw LocalLLMError.notSupportedYet("Apple Foundation Models requires macOS 26 (Tahoe).")
        }

        let combined = system + "\n\n" + cappedUser
        var collected = ""
        for await chunk in generate(
            prompt: combined,
            maxTokens: maxTokens,
            temperature: temperature
        ) {
            collected += chunk
        }
        // F1.9 — the consuming task being cancelled ends stream iteration
        // (and cancels the decode loop via onTermination). Report that as
        // CancellationError, not a scary "no tokens" failure.
        try Task.checkCancellation()
        NSLog("[ITER-039] completeBlocking: %d chars out%@", collected.count, collected.isEmpty ? " — NO TOKENS" : "")
        if collected.isEmpty {
            throw NSError(domain: "LocalLLM", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Local model returned no tokens. Check Settings → AI Models."
            ])
        }
        return collected
    }

    /// ITER-051 F1.2 — chunked processing of long inputs so on-device results
    /// cover the WHOLE text instead of the first `chunkChars` characters.
    /// ≤1 chunk short-circuits to a single `completeBlocking` call.
    ///
    /// Two modes:
    ///   - `concatPartials: false` (default) — map-reduce for SYNTHESIS tasks
    ///     (action plan, summary): map each chunk, fold, final reduce pass.
    ///     Review fix: map outputs are capped tight (≤512 tokens) so the fold
    ///     shrinks geometrically and converges within the round bound even on
    ///     repetitive hour-long transcripts; a failed/empty chunk is skipped,
    ///     not fatal.
    ///   - `concatPartials: true` — map-and-JOIN for TRANSFORM tasks (cleanup,
    ///     translation) where the output IS the processed text: one map round,
    ///     partials joined in order, no reduce (re-processing already-processed
    ///     text degrades it).
    func completeChunked(
        system: String,
        user: String,
        chunkChars: Int = 6000,
        maxTokensPerChunk: Int = 1024,
        temperature: Float = 0.3,
        concatPartials: Bool = false
    ) async throws -> String {
        // The fold itself lives in `ChunkedCompletion` — the Pro proxy runs
        // the same one, so a long transcript is handled identically wherever
        // it is processed (2026-09-04).
        let folded = try await ChunkedCompletion.fold(
            system: system, user: user, chunkChars: chunkChars, concatPartials: concatPartials
        ) { sys, usr, pass in
            // Map outputs are capped tight so the fold shrinks geometrically
            // and converges within the round bound even on repetitive
            // hour-long transcripts.
            let maxTokens: Int
            switch pass {
            case .map: maxTokens = min(512, maxTokensPerChunk)
            // A transform's output IS the answer — capping it tighter than a
            // whole prompt would truncate every cleaned-up chunk.
            case .transform, .whole, .reduce: maxTokens = maxTokensPerChunk
            }
            return try await self.completeBlocking(
                system: sys, user: usr,
                maxUserChars: chunkChars, maxTokens: maxTokens,
                temperature: temperature)
        }
        // A chunk that failed used to be dropped in silence here, while the
        // Pro path refused to hand over a partial answer as a whole one
        // (audit, 2026-09-06, P1).
        if folded.isPartial {
            NSLog("[LocalLLM] ⚠️ chunked result is PARTIAL — %d of %d chunk(s) failed and were left out",
                  folded.skipped, folded.outOf ?? folded.skipped)
        }
        return folded.text
    }

    /// Sample one token — sync variant used by the GCD loop.
    private nonisolated static func sampleTokenSync(logits: MLXArray, temperature: Float) -> Int {
        if temperature <= 0 {
            return logits.argMax().item(Int.self)
        }
        // ITER-051 F1.1 ROOT-CAUSE FIX — `MLXRandom.categorical` expects RAW
        // (unnormalized log-) LOGITS and exponentiates internally. The old
        // code fed it softmax PROBABILITIES [0…1], so the effective
        // distribution was ∝ exp(p): the best token outweighed any of the
        // 200k garbage tokens by at most e ≈ 2.7× — i.e. near-uniform
        // sampling over the whole vocabulary. Every temperature>0 generation
        // produced multilingual noise and never reached EOS. Verified against
        // reference mlx_lm on the same checkpoint (2026-07-07).
        let scaled = logits / temperature
        let sample = MLXRandom.categorical(scaled)
        return sample.item(Int.self)
    }

    /// Sample one token from the final-step logits. Temp=0 → argmax (greedy
    /// decoding, deterministic). Temp>0 → softmax + categorical sample.
    private func sampleToken(logits: MLXArray, temperature: Float) -> Int {
        if temperature <= 0 {
            return logits.argMax().item(Int.self)
        }
        let scaled = logits / temperature
        // Same categorical-expects-logits fix as sampleTokenSync above.
        let sample = MLXRandom.categorical(scaled)
        return sample.item(Int.self)
    }
}

// MARK: - Errors

enum LocalLLMError: LocalizedError, Equatable {
    case unknownModelID(String)
    case modelNotDownloaded(String)
    case notSupportedYet(String)
    case mlxFailure(String)
    /// ITER-044 — Apple Foundation Models can't serve (device ineligible,
    /// Apple Intelligence off, model still downloading). Message is already
    /// user-facing (from `FoundationModelsSupport.message(for:)`).
    case foundationModelsUnavailable(String)
    /// ITER-044 — an FM request failed at runtime (guardrail, context overflow,
    /// empty response, …). Recoverable — consumers fall back like any local fail.
    case foundationModelsFailure(String)

    var errorDescription: String? {
        switch self {
        case .unknownModelID(let id):  return "Unknown model ID: \(id)"
        case .modelNotDownloaded(let msg): return msg
        case .notSupportedYet(let msg):    return msg
        case .mlxFailure(let msg):         return "MLX failure: \(msg)"
        case .foundationModelsUnavailable(let msg): return msg
        case .foundationModelsFailure(let msg):     return msg
        }
    }
}
