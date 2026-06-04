import XCTest
@testable import MetaWhisp

/// Pins the on-device Whisper model catalog: the id→variant mapping that feeds
/// WhisperKit, and the recommended set. Guards against typos in the HuggingFace
/// variant names (a wrong variant = "downloaded a model but it won't load") and
/// against silently regressing to an English-only `.en` build.
@MainActor
final class WhisperModelCatalogTests: XCTestCase {

    func testCatalogHasExpectedModelIDs() {
        let ids = ModelManagerService.models.map(\.id)
        XCTAssertEqual(ids, ["large-v3-turbo", "large-v3", "small", "base", "tiny"])
    }

    func testIdToVariantMapping() {
        let map = Dictionary(uniqueKeysWithValues: ModelManagerService.models.map { ($0.id, $0.variant) })
        XCTAssertEqual(map["large-v3-turbo"], "openai_whisper-large-v3_turbo")
        XCTAssertEqual(map["large-v3"], "openai_whisper-large-v3")
        XCTAssertEqual(map["small"], "openai_whisper-small")
        XCTAssertEqual(map["base"], "openai_whisper-base")
        XCTAssertEqual(map["tiny"], "openai_whisper-tiny")
    }

    func testAllVariantsAreMultilingual() {
        // None of the offered variants are the English-only ".en" builds — all
        // can transcribe Russian. A regression to a ".en" variant would silently
        // break every non-English user.
        for m in ModelManagerService.models {
            XCTAssertFalse(m.variant.contains(".en"), "\(m.id) must not be an English-only variant")
            XCTAssertTrue(m.variant.hasPrefix("openai_whisper-"), "\(m.id) unexpected variant prefix")
        }
    }

    func testRecommendedModelsMatchCatalog() {
        XCTAssertEqual(ModelManagerService.recommendedModels, ModelManagerService.models.map(\.id))
    }

    /// The first/recommended catalog entry should be the strong multilingual
    /// model, not a weak one — a free non-English user picking the top option
    /// must get usable accuracy. (`base`/`tiny` are weak for Russian.)
    func testTopRecommendationIsStrongModel() {
        XCTAssertEqual(ModelManagerService.models.first?.id, "large-v3-turbo")
    }
}
