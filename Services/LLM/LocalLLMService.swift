import Foundation
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
    private var eosTokenId: Int = 0

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
    static func prewarmMLX() {
        NSLog("[ITER-039] pre-warming MLX on main thread")
        MLXRandom.seed(0x4D575F50484934)
        let probe = MLXArray.zeros([1], dtype: .float32)
        eval(probe)
        NSLog("[ITER-039] ✅ MLX warmed up (Metal context initialized)")
    }

    // MARK: - Load

    func loadModel(id: String) async throws {
        guard let spec = ModelRegistry.model(byID: id) else {
            throw LocalLLMError.unknownModelID(id)
        }
        if spec.isFoundationModels {
            throw LocalLLMError.notSupportedYet(
                "Apple Foundation Models adapter ships separately — requires macOS Tahoe."
            )
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
        let resolvedEos = tokenizer.eosTokenId ?? buildResult.fallbackEos

        self.model = buildResult.model
        self.tokenizer = tokenizer
        self.eosTokenId = resolvedEos
        self.currentModelID = id
        self.isReady = true
        self.lastError = nil
        NSLog("[ITER-039] ✅ %@ ready (eos=%d)", spec.displayName, resolvedEos)
    }

    /// Result of the synchronous MLX build phase. Crossed back to MainActor
    /// after the dispatch-queue work completes.
    private struct MLXBuildResult: @unchecked Sendable {
        let model: Phi3Model
        let fallbackEos: Int    // From tokenizer_config.json — used if Tokenizer's own eosTokenId is nil.
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

        // 6. EOS hint from config (tokenizer's own resolution happens on main).
        var fallbackEos = 0
        let tcURL = modelDir.appending(path: "tokenizer_config.json")
        if let tcData = try? Data(contentsOf: tcURL),
           let tcDict = try? JSONSerialization.jsonObject(with: tcData) as? [String: Any],
           let n = tcDict["eos_token_id"] as? Int {
            fallbackEos = n
        }

        return MLXBuildResult(model: model, fallbackEos: fallbackEos)
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
        eosTokenId = 0
        NSLog("[ITER-039] model unloaded")
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
        AsyncStream { continuation in
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
                isGenerating = true

                let eosId = self.eosTokenId
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
                            eosId: eosId,
                            model: model,
                            tokenizer: tokenizer,
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
    private nonisolated static func runGenerationSync(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        eosId: Int,
        model: Phi3Model,
        tokenizer: any Tokenizer,
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

        // 2. KV cache (one per attention layer).
        let numLayers = model.kvHeads.count
        let cache: [KVCache] = (0..<numLayers).map { _ in KVCache() }

        // 3. Prefill — single forward over the entire prompt.
        var input = MLXArray(inputIds.map { Int32($0) }).expandedDimensions(axis: 0)
        var logits = model(input, cache: cache)
        eval(logits)
        var lastLogit = logits[0..., -1, 0...]

        // 4. Decode loop.
        for _ in 0..<maxTokens {
            let next = Self.sampleTokenSync(logits: lastLogit, temperature: temperature)
            if next == eosId { break }
            let piece = tokenizer.decode(tokens: [next], skipSpecialTokens: true)
            if !piece.isEmpty {
                yield(piece)
            }
            input = MLXArray([Int32(next)]).expandedDimensions(axis: 0)
            logits = model(input, cache: cache)
            eval(logits)
            lastLogit = logits[0..., -1, 0...]
        }
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
        let combined = system + "\n\n" + cappedUser
        var collected = ""
        for await chunk in generate(
            prompt: combined,
            maxTokens: maxTokens,
            temperature: temperature
        ) {
            collected += chunk
        }
        if collected.isEmpty {
            throw NSError(domain: "LocalLLM", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Local model returned no tokens. Check Settings → AI Models."
            ])
        }
        return collected
    }

    /// Sample one token — sync variant used by the GCD loop.
    private nonisolated static func sampleTokenSync(logits: MLXArray, temperature: Float) -> Int {
        if temperature <= 0 {
            return logits.argMax().item(Int.self)
        }
        let scaled = logits / temperature
        let probs = MLX.softmax(scaled, axis: -1)
        let sample = MLXRandom.categorical(probs)
        return sample.item(Int.self)
    }

    /// Sample one token from the final-step logits. Temp=0 → argmax (greedy
    /// decoding, deterministic). Temp>0 → softmax + categorical sample.
    private func sampleToken(logits: MLXArray, temperature: Float) -> Int {
        if temperature <= 0 {
            return logits.argMax().item(Int.self)
        }
        let scaled = logits / temperature
        let probs = MLX.softmax(scaled, axis: -1)
        let sample = MLXRandom.categorical(probs)
        return sample.item(Int.self)
    }
}

// MARK: - Errors

enum LocalLLMError: LocalizedError, Equatable {
    case unknownModelID(String)
    case modelNotDownloaded(String)
    case notSupportedYet(String)
    case mlxFailure(String)

    var errorDescription: String? {
        switch self {
        case .unknownModelID(let id):  return "Unknown model ID: \(id)"
        case .modelNotDownloaded(let msg): return msg
        case .notSupportedYet(let msg):    return msg
        case .mlxFailure(let msg):         return "MLX failure: \(msg)"
        }
    }
}
