import XCTest
import Tokenizers
import Hub
@testable import MetaWhisp

/// ITER-051 F1.1 diagnostics — tokenizer-level probe (NO model load).
/// Prints the ids swift-transformers produces for a fixed prompt so they can
/// be diffed against the reference `mlx_lm`/HF tokenizer output. Garbage
/// generation can come from EITHER broken weights application OR broken
/// tokenization (wrong ids in → noise out); this isolates the tokenizer leg.
final class LocalLLMTokenizerDiagTests: XCTestCase {

    @MainActor
    func testTokenizerIdsMatchReference() async throws {
        guard ProcessInfo.processInfo.environment["MW_LOCAL_STRESS"] == "1" else {
            throw XCTSkip("diagnostic — MW_LOCAL_STRESS=1 only")
        }
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/huggingface/models/mlx-community/Phi-4-mini-instruct-4bit")
        let tokenizer = try await AutoTokenizer.from(modelFolder: dir)

        let plain = tokenizer.encode(text: "Hello world, this is a test.")
        print("[TOKDIAG] plain encode: \(plain)")

        let ruPlain = tokenizer.encode(text: "короче нужно завтра позвонить в банк")
        print("[TOKDIAG] ru encode: \(ruPlain)")

        let templated = try tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": "Hello world"]])
        print("[TOKDIAG] chat template ids: \(templated)")

        let roundtrip = tokenizer.decode(tokens: plain, skipSpecialTokens: false)
        print("[TOKDIAG] roundtrip: \(roundtrip)")

        print("[TOKDIAG] eosTokenId: \(String(describing: tokenizer.eosTokenId))")
    }
}
