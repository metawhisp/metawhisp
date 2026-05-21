import XCTest
@testable import MetaWhisp

/// User-story-oriented tests for ITER-039 (local LLM).
/// Pure functions only — no MLX inference (that's behind a Metal toolchain
/// dependency tested via the runtime smoke test, not unit tests).
@MainActor
final class LocalLLMTests: XCTestCase {

    // MARK: - US-1 «as a Free user I want to see only models that actually work»

    /// v1.3.5 catalog is intentionally 2 cards: Phi-4 Mini (working) +
    /// Apple Foundation Models (info for Tahoe users). Other 3 MLX models
    /// were removed because their architecture adapters haven't shipped —
    /// user feedback 2026-05-13 «зачем они нам там нужны если не работают».
    func test_modelRegistry_v135CatalogHasExactlyTwoCards() {
        XCTAssertEqual(ModelRegistry.allModels.count, 2,
            "v1.3.5 ships Phi-4 Mini + Apple Foundation Models only — extra cards confuse users")
    }

    /// Phi-4 Mini renders first so Settings UI promotes it as the default.
    func test_modelRegistry_phi4MiniIsFirstAndDefault() {
        XCTAssertEqual(ModelRegistry.allModels.first?.id, "phi-4-mini")
        XCTAssertTrue(ModelRegistry.allModels.first?.bestForTagline.lowercased().contains("default") ?? false,
            "Phi-4 Mini's tagline should advertise it as the default choice")
    }

    /// Apple Foundation Models card stays for discoverability on macOS 26
    /// Tahoe upgrades (zero-download path).
    func test_modelRegistry_includesAppleFoundationModels() {
        XCTAssertTrue(ModelRegistry.allModels.contains { $0.id == "apple-foundation-models" })
    }

    /// Lookup by id resolves to the right spec.
    func test_modelRegistry_lookupByID_returnsCorrectSpec() {
        let spec = ModelRegistry.model(byID: "phi-4-mini")
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.displayName, "Phi-4 Mini Instruct")
        XCTAssertEqual(spec?.hfRepoID, "mlx-community/Phi-4-mini-instruct-4bit")
    }

    /// Removed models (Gemma 4 / Qwen 3 4B / Qwen 3 7B) return nil so any
    /// stale `localLLMActiveModelID` from a previous build won't reference
    /// a phantom card.
    func test_modelRegistry_deferredModelIDs_returnNil() {
        XCTAssertNil(ModelRegistry.model(byID: "gemma-4-e2b"))
        XCTAssertNil(ModelRegistry.model(byID: "qwen3-4b"))
        XCTAssertNil(ModelRegistry.model(byID: "qwen3-7b"))
    }

    // MARK: - US-2 «as a Sequoia user I'm told why Apple Foundation Models doesn't work»

    /// On macOS 15.x (Sequoia) the Foundation Models verdict is incompatible
    /// with a human-readable «Requires macOS Tahoe (26+). You have Sequoia (15.6).»
    /// reason — not the cryptic «requires macOS 26» that confused user 2026-05-13.
    func test_modelCompatibility_foundationModels_onSequoia_clearlyExplainsNeed() {
        let foundation = ModelRegistry.model(byID: "apple-foundation-models")!
        let verdict = ModelCompatibility.verdict(
            for: foundation,
            systemRAMGB: 48,
            systemChipGen: 4,
            macOSMajor: 15,
            macOSMinor: 6,
            isAppleSilicon: true
        )
        if case .incompatible(let reason) = verdict {
            XCTAssertTrue(reason.contains("Tahoe"),
                "Foundation Models error must name Tahoe — saying just «macOS 26» confused user")
            XCTAssertTrue(reason.contains("Sequoia"),
                "Foundation Models error must name user's current macOS (Sequoia) for clarity")
        } else {
            XCTFail("Expected .incompatible on Sequoia, got \(verdict)")
        }
    }

    /// On macOS 26 Tahoe the same model is recommended (no download needed).
    func test_modelCompatibility_foundationModels_onTahoe_isRecommended() {
        let foundation = ModelRegistry.model(byID: "apple-foundation-models")!
        let verdict = ModelCompatibility.verdict(
            for: foundation,
            systemRAMGB: 16,
            systemChipGen: 2,
            macOSMajor: 26,
            macOSMinor: 0,
            isAppleSilicon: true
        )
        XCTAssertEqual(verdict, .recommended)
    }

    /// Intel Mac users see a clear incompatible verdict for MLX models.
    /// MLX requires Apple Silicon — must be obvious in the card badge.
    func test_modelCompatibility_phi4_onIntelMac_isIncompatible() {
        let phi = ModelRegistry.model(byID: "phi-4-mini")!
        let verdict = ModelCompatibility.verdict(
            for: phi,
            systemRAMGB: 16,
            systemChipGen: 0,
            macOSMajor: 15,
            macOSMinor: 0,
            isAppleSilicon: false
        )
        if case .incompatible(let reason) = verdict {
            XCTAssertTrue(reason.lowercased().contains("apple silicon"))
        } else {
            XCTFail("Expected .incompatible on Intel, got \(verdict)")
        }
    }

    // MARK: - US-3 «as a user with low RAM I'm warned before I try»

    /// 8 GB user picking Phi-4 Mini (recommended for 8 GB) → recommended.
    func test_modelCompatibility_phi4_on8GBM1_isRecommended() {
        let phi = ModelRegistry.model(byID: "phi-4-mini")!
        let verdict = ModelCompatibility.verdict(
            for: phi,
            systemRAMGB: 8,
            systemChipGen: 1,
            macOSMajor: 14,
            macOSMinor: 0,
            isAppleSilicon: true
        )
        XCTAssertEqual(verdict, .recommended)
    }
}

/// User-story-oriented tests for the Dictionary / Snippets preset flow
/// added 2026-05-13 («моя почта», «my LinkedIn», etc.).
@MainActor
final class SnippetPresetTests: XCTestCase {

    // MARK: - US-4 «as a user I want preset templates so I know what's possible»

    /// `defaultSnippetPresets` ships both RU and EN variants. Whisper
    /// occasionally translates «мой LinkedIn» → «my LinkedIn» mid-stream,
    /// so we need BOTH triggers mapped to the same user-supplied URL.
    func test_defaultSnippetPresets_includesRussianAndEnglishPairs() {
        let presets = CorrectionDictionary.defaultSnippetPresets
        // Russian
        XCTAssertNotNil(presets["мой LinkedIn"])
        XCTAssertNotNil(presets["моя почта"])
        XCTAssertNotNil(presets["мой телефон"])
        XCTAssertNotNil(presets["мой GitHub"])
        // English counterparts
        XCTAssertNotNil(presets["my LinkedIn"])
        XCTAssertNotNil(presets["my email"])
        XCTAssertNotNil(presets["my phone"])
        XCTAssertNotNil(presets["my GitHub"])
    }

    /// All presets ship with EMPTY expansions so the user knows they're
    /// templates to fill in. `apply(...)` must skip empties — otherwise an
    /// unfilled preset would clobber the trigger phrase with nothing.
    func test_defaultSnippetPresets_allHaveEmptyExpansions() {
        for (trigger, expansion) in CorrectionDictionary.defaultSnippetPresets {
            XCTAssertTrue(expansion.isEmpty,
                "Preset «\(trigger)» should ship empty so the UI shows «tap to fill in» — got «\(expansion)»")
        }
    }

    /// Preset coverage covers the canonical «say-this-want-that» roster.
    /// Adjust if/when the preset list changes; the test just sets a floor.
    func test_defaultSnippetPresets_minimumCount() {
        XCTAssertGreaterThanOrEqual(CorrectionDictionary.defaultSnippetPresets.count, 16,
            "v1.3.5 ships at least 16 presets (8 RU + 8 EN); shrinking this is a UX regression")
    }
}
