// Vendored from ml-explore/mlx-swift-examples 2.29.1
//   Libraries/MLXLLM/Models/Phi3.swift  (MIT, Copyright © 2024 Apple Inc.)
//
// Adaptations for MetaWhisp ITER-039:
//   - `import MLXLMCommon` removed; required symbols (KVCache,
//     attentionWithCacheUpdate, createAttentionMask, SuScaledRotaryEmbedding,
//     LLMModel, LoRAModel, KVCacheDimensionProvider) provided by
//     `MLXSupport.swift` in this same module.
//   - The `LoRA` extension at the bottom is dropped — we don't ship adapter
//     training in v1.3.5.
//   - `MLXFast` import added explicitly for `ScaledDotProductAttentionMaskMode`.

import Foundation
import MLX
import MLXFast
import MLXNN

private class Attention: Module {

    let args: Phi3Configuration
    let scale: Float

    let heads: Int
    let kvHeads: Int
    let headDim: Int
    let ropeDim: Int

    @ModuleInfo(key: "qkv_proj") var wqkv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear

    enum PositionalEncoding {
        case rope(RoPE)
        case suScaledRotaryEmbedding(SuScaledRotaryEmbedding)

        func applyEncoding(_ x: MLXArray, offset: Int = 0) -> MLXArray {
            switch self {
            case .rope(let rope):
                return rope.callAsFunction(x, offset: offset)
            case .suScaledRotaryEmbedding(let suScaledRotaryEmbedding):
                return suScaledRotaryEmbedding.callAsFunction(x, offset: offset)
            }
        }
    }

    let rope: PositionalEncoding

    public init(_ args: Phi3Configuration) {
        NSLog("[Phi3 trace]   Attention.init a")
        self.args = args

        let dim = args.hiddenSize
        self.heads = args.attentionHeads
        self.kvHeads = args.kvHeads

        self.headDim = args.hiddenSize / heads
        self.ropeDim = Int(Float(headDim) * args.partialRotaryFactor)
        self.scale = pow(Float(headDim), -0.5)
        NSLog("[Phi3 trace]   Attention.init b — building Linears")
        self._wqkv.wrappedValue = Linear(dim, (heads + 2 * kvHeads) * headDim, bias: false)
        self._wo.wrappedValue = Linear(heads * headDim, dim, bias: false)
        NSLog("[Phi3 trace]   Attention.init c — Linears built, building RoPE")

        let ropeScale: Float

        if let ropeScaling = args.ropeScaling, ropeScaling.type == "linear",
            let factor = ropeScaling.factor
        {
            ropeScale = 1 / factor
        } else {
            ropeScale = 1
        }

        // ITER-039 v1.3.5 — force standard `RoPE` even when the config asks
        // for `su` / `longrope`. The vendored `SuScaledRotaryEmbedding`
        // (MLXSupport.swift) is unstable at module init — the app SIGKILLs
        // mid-construction of the 32-layer tree, likely from Module
        // introspection of the stored `invFreq: MLXArray` parameter.
        // Trade-off: long-context (>4k tokens) quality degrades; short
        // prompts (≤ original_max_position_embeddings) work identically.
        // Sufficient for our use case (structured-text cleanup is always
        // sub-2k tokens). Re-enable longrope when we can vendor MLXLMCommon's
        // `SuScaledRotaryEmbedding` verbatim instead of our minimal stub.
        self.rope = .rope(
            RoPE(
                dimensions: ropeDim, traditional: args.ropeTraditional, base: args.ropeTheta,
                scale: ropeScale))
        NSLog("[Phi3 trace]   Attention.init d — RoPE built, done")
    }

    public func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))

        let queryPos = heads * headDim
        let qkv = split(wqkv(x), indices: [queryPos, queryPos + kvHeads * headDim], axis: -1)
        var queries = qkv[0]
        var keys = qkv[1]
        var values = qkv[2]

        // prepare the queries, keys and values for the attention computation
        queries = queries.reshaped(B, L, args.attentionHeads, -1).transposed(0, 2, 1, 3)
        keys = keys.reshaped(B, L, args.kvHeads, -1).transposed(0, 2, 1, 3)
        values = values.reshaped(B, L, args.kvHeads, -1).transposed(0, 2, 1, 3)

        if let cache {
            queries = rope.applyEncoding(queries, offset: cache.offset)
            keys = rope.applyEncoding(keys, offset: cache.offset)
        } else {
            queries = rope.applyEncoding(queries)
            keys = rope.applyEncoding(keys)
        }

        let output = attentionWithCacheUpdate(
            queries: queries,
            keys: keys,
            values: values,
            cache: cache,
            scale: scale,
            mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        return wo(output)
    }
}

private class MLP: Module, UnaryLayer {

    @ModuleInfo(key: "gate_up_proj") var gate_up: Linear
    @ModuleInfo(key: "down_proj") var down: Linear

    public init(dimensions: Int, hiddenDimensions: Int) {
        self._gate_up.wrappedValue = Linear(dimensions, 2 * hiddenDimensions, bias: false)
        self._down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let gu = split(gate_up(x), parts: 2, axis: -1)
        return down(silu(gu[0]) * gu[1])
    }
}

private class TransformerBlock: Module {

    @ModuleInfo(key: "self_attn") var attention: Attention
    let mlp: MLP

    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    public init(_ args: Phi3Configuration) {
        self._attention.wrappedValue = Attention(args)
        self.mlp = MLP(dimensions: args.hiddenSize, hiddenDimensions: args.intermediateSize)
        self._inputLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize, eps: args.rmsNormEps)
        self._postAttentionLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    public func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        var r = attention(inputLayerNorm(x), mask: mask, cache: cache)
        let h = x + r
        r = mlp(postAttentionLayerNorm(h))
        let out = h + r
        return out
    }
}

private class Phi3ModelInner: Module {

    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding

    fileprivate let layers: [TransformerBlock]
    let norm: RMSNorm
    let args: Phi3Configuration

    public init(_ args: Phi3Configuration) {
        NSLog("[Phi3 trace] inner.init A — vocab=%d, hidden=%d, layers=%d",
              args.vocabularySize, args.hiddenSize, args.hiddenLayers)
        precondition(args.vocabularySize > 0)
        self.args = args
        NSLog("[Phi3 trace] inner.init B — args stashed, building embedding")
        self._embedTokens.wrappedValue = Embedding(
            embeddingCount: args.vocabularySize, dimensions: args.hiddenSize)
        NSLog("[Phi3 trace] inner.init C — embedding built, starting layers loop")
        self.layers = (0 ..< args.hiddenLayers)
            .map { idx -> TransformerBlock in
                if idx == 0 || idx == args.hiddenLayers - 1 {
                    NSLog("[Phi3 trace] inner.init D — building TransformerBlock %d", idx)
                }
                return TransformerBlock(args)
            }
        NSLog("[Phi3 trace] inner.init E — all %d layers built, building final RMSNorm", args.hiddenLayers)
        self.norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
        NSLog("[Phi3 trace] inner.init F — done")
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        var h = embedTokens(inputs)

        let mask = createAttentionMask(h: h, cache: cache)

        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache?[i])
        }

        return norm(h)
    }
}

public class Phi3Model: Module, LLMModel, KVCacheDimensionProvider {

    public let vocabularySize: Int
    public let kvHeads: [Int]

    private let model: Phi3ModelInner
    private let args: Phi3Configuration

    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    public init(_ args: Phi3Configuration) {
        self.vocabularySize = args.vocabularySize
        self.kvHeads = (0 ..< args.hiddenLayers).map { _ in args.kvHeads }
        self.model = Phi3ModelInner(args)
        self.args = args

        if !args.tieWordEmbeddings {
            self._lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabularySize, bias: false)
        }
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let out = model(inputs, cache: cache)
        if args.tieWordEmbeddings {
            return model.embedTokens.asLinear(out)
        } else if let lmHead {
            return lmHead(out)
        } else {
            fatalError(
                "Model configuration error: Neither tied embeddings nor lm_head is available")
        }
    }
}

struct RopeScalingWithFactorArrays: Codable {
    let longFactor: [Float]?
    let shortFactor: [Float]?
    let factor: Float?
    let type: String?
    let longMScale: Float?
    let shortMScale: Float?

    enum CodingKeys: String, CodingKey {
        case type
        case factor
        case longFactor = "long_factor"
        case shortFactor = "short_factor"
        case longMScale = "long_mscale"
        case shortMScale = "short_mscale"
    }
}

public struct Phi3Configuration: Codable, Sendable {
    var hiddenSize: Int
    var hiddenLayers: Int
    var intermediateSize: Int
    var attentionHeads: Int
    var rmsNormEps: Float
    var vocabularySize: Int
    var kvHeads: Int
    var ropeTheta: Float = 10_000
    var ropeTraditional: Bool = false
    var ropeScaling: RopeScalingWithFactorArrays?
    var partialRotaryFactor: Float = 1.0
    var maxPositionEmbeddings: Int
    var originalMaxPositionEmbeddings: Int
    var tieWordEmbeddings: Bool = false

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case rmsNormEps = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case kvHeads = "num_key_value_heads"
        case ropeTheta = "rope_theta"
        case ropeTraditional = "rope_traditional"
        case ropeScaling = "rope_scaling"
        case partialRotaryFactor = "partial_rotary_factor"
        case maxPositionEmbeddings = "max_position_embeddings"
        case originalMaxPositionEmbeddings = "original_max_position_embeddings"
        case tieWordEmbeddings = "tie_word_embeddings"
    }

    public init(from decoder: Decoder) throws {
        // custom implementation to handle optional keys with required values
        let container: KeyedDecodingContainer<Phi3Configuration.CodingKeys> = try decoder.container(
            keyedBy: Phi3Configuration.CodingKeys.self)

        hiddenSize = try container.decode(Int.self, forKey: Phi3Configuration.CodingKeys.hiddenSize)
        hiddenLayers = try container.decode(
            Int.self, forKey: Phi3Configuration.CodingKeys.hiddenLayers)
        intermediateSize = try container.decode(
            Int.self, forKey: Phi3Configuration.CodingKeys.intermediateSize)
        attentionHeads = try container.decode(
            Int.self, forKey: Phi3Configuration.CodingKeys.attentionHeads)
        rmsNormEps = try container.decode(
            Float.self, forKey: Phi3Configuration.CodingKeys.rmsNormEps)
        vocabularySize = try container.decode(
            Int.self, forKey: Phi3Configuration.CodingKeys.vocabularySize)
        kvHeads = try container.decode(Int.self, forKey: Phi3Configuration.CodingKeys.kvHeads)
        ropeTheta =
            try container.decodeIfPresent(
                Float.self, forKey: Phi3Configuration.CodingKeys.ropeTheta) ?? 10_000
        ropeTraditional =
            try container.decodeIfPresent(
                Bool.self, forKey: Phi3Configuration.CodingKeys.ropeTraditional) ?? false
        ropeScaling = try container.decodeIfPresent(
            RopeScalingWithFactorArrays.self, forKey: .ropeScaling)
        partialRotaryFactor =
            try container.decodeIfPresent(
                Float.self, forKey: .partialRotaryFactor) ?? 1.0
        maxPositionEmbeddings = try container.decode(Int.self, forKey: .maxPositionEmbeddings)
        originalMaxPositionEmbeddings = try container.decode(
            Int.self, forKey: .originalMaxPositionEmbeddings)
        tieWordEmbeddings =
            try container.decodeIfPresent(
                Bool.self, forKey: .tieWordEmbeddings) ?? false
    }
}

// LoRA adapter extension removed in MetaWhisp vendor (see file header).
