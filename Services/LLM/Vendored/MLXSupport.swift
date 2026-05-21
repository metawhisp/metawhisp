// Minimal MLXLMCommon-equivalent shims for ITER-039 Phi-3 inference.
//
// We vendor `Phi3.swift` from mlx-swift-examples (Apple Inc., MIT) but cannot
// vendor the full `MLXLMCommon` library because (a) it pulls a transitive
// `swift-transformers 1.3.x` that conflicts with WhisperKit's pin at 1.1.x,
// and (b) it brings ~50 KB of KVCache variants + ~32 KB of generation
// machinery + Chat/Tool/Adapter scaffolding we don't need for our single
// task (structured-text cleanup via one model).
//
// This file provides ONLY the types `Phi3.swift` references:
//   - `KVCache`               — running key/value buffer per attention layer
//   - `KVCacheDimensionProvider` — protocol Phi3Model conforms to
//   - `attentionWithCacheUpdate(...)` — extends cache + runs SDPA in one call
//   - `createAttentionMask(...)` — causal mask for the autoregressive decode
//   - `SuScaledRotaryEmbedding` — Phi-3/4 long-context RoPE variant
//   - `LLMModel`, `LoRAModel`, `LoRALinearLayers` — marker protocols (stubs)
//
// Apple-style attribution kept at file top for files copied verbatim
// (`Phi3.swift`). This file is original MetaWhisp code modelled on the
// MLXLMCommon API surface; no verbatim copying.

import Foundation
import MLX
import MLXFast
import MLXNN

// MARK: - KV Cache

/// Append-only key/value buffer for one attention layer. The decode loop
/// grows `keys` and `values` along the sequence axis as each token is
/// generated. `offset` tracks the current sequence position so RoPE knows
/// the right rotation angle for new tokens.
///
/// We use a plain class (not actor) — generation runs on one task at a time
/// and KVCache instances are not shared across tasks.
public final class KVCache {
    /// Accumulated keys, shape `(batch, kvHeads, seqLen, headDim)`. Nil
    /// until the first token of a sequence is processed.
    var keys: MLXArray?
    /// Accumulated values, same shape as `keys`.
    var values: MLXArray?
    /// Current sequence length — number of tokens already in `keys`.
    var offset: Int = 0

    public init() {}

    /// Concatenate `newKeys` / `newValues` (shape `(B, kvH, L, headDim)`)
    /// into the running buffers along the seq-len axis, returning the full
    /// post-update tensors for the SDPA call.
    public func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let nextK: MLXArray
        let nextV: MLXArray
        if let k = keys, let v = values {
            nextK = concatenated([k, newKeys], axis: 2)
            nextV = concatenated([v, newValues], axis: 2)
        } else {
            nextK = newKeys
            nextV = newValues
        }
        self.keys = nextK
        self.values = nextV
        self.offset += newKeys.dim(2)
        return (nextK, nextV)
    }
}

/// Marker conformance Phi3Model uses to advertise the per-layer KV-head
/// count for cache allocation. We don't actually use this for allocation
/// (we allocate caches lazily inside `update(...)`), but the conformance
/// stays so the vendored Phi3.swift compiles unchanged.
public protocol KVCacheDimensionProvider {
    var kvHeads: [Int] { get }
}

// MARK: - Attention helpers

/// Append `keys`/`values` to the layer's `cache` (if present), then run
/// scaled dot-product attention against the full post-update K/V. Matches
/// the MLXLMCommon helper of the same name.
///
/// - Parameters:
///   - queries: shape `(B, H, L, headDim)` — current step's queries
///   - keys, values: shape `(B, kvH, L_new, headDim)` — new tokens' K/V
///   - cache: per-layer KVCache, mutated in place
///   - scale: 1/√headDim
///   - mask: causal mask (`.array` or `.none` for decode steps)
public func attentionWithCacheUpdate(
    queries: MLXArray,
    keys: MLXArray,
    values: MLXArray,
    cache: KVCache?,
    scale: Float,
    mask: MLXFast.ScaledDotProductAttentionMaskMode
) -> MLXArray {
    let kFull: MLXArray
    let vFull: MLXArray
    if let cache {
        (kFull, vFull) = cache.update(keys: keys, values: values)
    } else {
        kFull = keys
        vFull = values
    }
    return MLXFast.scaledDotProductAttention(
        queries: queries,
        keys: kFull,
        values: vFull,
        scale: scale,
        mask: mask
    )
}

/// Build a causal attention mask for the prefill or decode step. Mirrors
/// MLXLMCommon's `createAttentionMask` semantics: returns `.none` for the
/// trivial L=1 decode step (a single new token can only attend to itself
/// plus the cache — no mask needed) and a triangular causal mask for the
/// L>1 prefill step.
///
/// - Parameters:
///   - h: hidden states, shape `(B, L, dim)`. We use `L` to decide masking.
///   - cache: per-layer cache list (or nil for prefill on a fresh sequence)
public func createAttentionMask(
    h: MLXArray, cache: [KVCache]?
) -> MLXFast.ScaledDotProductAttentionMaskMode {
    let L = h.dim(1)
    if L <= 1 {
        return .none
    }
    // Causal mask for prefill: lower triangular ones, upper triangular
    // -inf. Output broadcasts to (1, 1, L, L) for SDPA.
    let offset = cache?.first?.offset ?? 0
    let totalLen = L + offset
    var mask = MLXArray.zeros([L, totalLen], dtype: h.dtype)
    // Position-aware: row i attends to columns ≤ (i + offset).
    let rowPos = MLXArray.arange(L).reshaped([L, 1]) + offset
    let colPos = MLXArray.arange(totalLen).reshaped([1, totalLen])
    let causal = rowPos .< colPos  // upper triangle == "future" == masked
    mask = MLX.where(causal, MLXArray(-Float.infinity, dtype: h.dtype), mask)
    return .array(mask)
}

// MARK: - SuScaledRotaryEmbedding (Phi-3 long-context RoPE)

/// Phi-3's "SU scaled" rotary embedding for the long-context (128k) variant.
/// Standard 4k Phi-3 uses the base `RoPE` instead. We implement only the
/// short-factor path (= `longFactor` since most Phi-3-mini variants have
/// equal short/long factors at 4k inference).
///
/// This is intentionally minimal — if the user activates a Phi-3 variant
/// whose rope_scaling.type == "su" and the long-factor mismatch matters
/// at runtime, output quality drops. For Phi-4 Mini Instruct (the only
/// model shipped in v1.3.5) the config uses standard `RoPE` so this class
/// stays dormant; we ship it so the vendored `Phi3.swift` compiles
/// unchanged.
public final class SuScaledRotaryEmbedding: Module {
    public let dimensions: Int
    public let maxPositionEmbeddings: Int
    public let originalMaxPositionEmbeddings: Int
    public let scale: Float
    public let invFreq: MLXArray

    public init(
        dimensions: Int,
        base: Float,
        maxPositionEmbeddings: Int,
        originalMaxPositionEmbeddings: Int,
        longFactor: [Float]
    ) {
        self.dimensions = dimensions
        self.maxPositionEmbeddings = maxPositionEmbeddings
        self.originalMaxPositionEmbeddings = originalMaxPositionEmbeddings
        // Compute the inverse frequency from longFactor.
        let inv = (0 ..< (dimensions / 2)).map { i -> Float in
            let exponent = Float(2 * i) / Float(dimensions)
            return 1.0 / (pow(base, exponent) * longFactor[i])
        }
        self.invFreq = MLXArray(inv)
        // Scale factor — log-interpolated between original and max context.
        let ratio = Float(maxPositionEmbeddings) / Float(originalMaxPositionEmbeddings)
        self.scale = sqrt(1.0 + log(ratio) / log(Float(originalMaxPositionEmbeddings)))
        super.init()
    }

    /// Apply RoPE to `x` at position offset `offset`. Input shape
    /// `(B, H, L, headDim)`. Only the first `dimensions` columns are
    /// rotated — Phi-3/4 use partial rotary embedding (`partial_rotary_factor`
    /// < 1.0, e.g. 0.75 → rotate 96 of 128 dims, pass the last 32
    /// untouched). The pass-through columns are concatenated back so
    /// the output shape matches the input.
    public func callAsFunction(_ x: MLXArray, offset: Int = 0) -> MLXArray {
        let L = x.dim(2)
        let headDim = x.dim(-1)

        // Split: rotary slice (first `dimensions` cols) + pass-through tail.
        let rotPart = x[.ellipsis, 0 ..< dimensions]
        let passPart: MLXArray? = dimensions < headDim
            ? x[.ellipsis, dimensions ..< headDim]
            : nil

        // Inside the rotary slice: split in half along last dim, rotate.
        let half = dimensions / 2
        let x1 = rotPart[.ellipsis, 0 ..< half]
        let x2 = rotPart[.ellipsis, half ..< dimensions]

        let positions = MLXArray.arange(offset, offset + L).asType(.float32)
        // freqs shape after broadcast: (L, half). Expand to (1, 1, L, half)
        // so multiply broadcasts against (B, H, L, half).
        let baseFreqs = positions.expandedDimensions(axis: 1) * invFreq.expandedDimensions(axis: 0)
        let cos = (MLX.cos(baseFreqs) * scale).expandedDimensions(axes: [0, 1])
        let sin = (MLX.sin(baseFreqs) * scale).expandedDimensions(axes: [0, 1])

        let rotated = concatenated(
            [x1 * cos - x2 * sin, x1 * sin + x2 * cos],
            axis: -1
        )
        if let passPart {
            return concatenated([rotated, passPart], axis: -1)
        }
        return rotated
    }
}

// MARK: - LLMModel / LoRA marker protocols

/// Marker protocol — vendored `Phi3Model` conforms but we don't use the
/// distinction; kept so Phi3.swift compiles unchanged.
public protocol LLMModel: Module {}

/// Stub for LoRA-related types Phi3.swift's bottom `extension` references.
/// We strip the LoRA extension in our copy of Phi3.swift, but keep the
/// types around in case future vendored models need them.
public typealias LoRALinearLayers = [(Module, [String])]
public protocol LoRAModel {
    func loraLinearLayers() -> LoRALinearLayers
}
