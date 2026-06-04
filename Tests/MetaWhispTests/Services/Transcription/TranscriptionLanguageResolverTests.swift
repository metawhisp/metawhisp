import XCTest
@testable import MetaWhisp

/// Pins the language/prompt decisions that drive the Russian→English bug AND
/// the follow-up empty-transcript regression:
/// - the English brand glossary is gated to English only;
/// - for `auto`, WhisperKit DETECTS the language (paired with usePrefillPrompt:
///   true) instead of either forcing `<|en|>` (RU→EN) or running with prefill
///   off (empty results).
final class TranscriptionLanguageResolverTests: XCTestCase {

    // MARK: - resolveLanguage

    func testResolveLanguage_autoEmptyAndNilBecomeNil() {
        XCTAssertNil(TranscriptionLanguageResolver.resolveLanguage("auto"))
        XCTAssertNil(TranscriptionLanguageResolver.resolveLanguage("AUTO"))
        XCTAssertNil(TranscriptionLanguageResolver.resolveLanguage(""))
        XCTAssertNil(TranscriptionLanguageResolver.resolveLanguage("   "))
        XCTAssertNil(TranscriptionLanguageResolver.resolveLanguage(nil))
    }

    func testResolveLanguage_explicitCodePassesThrough() {
        XCTAssertEqual(TranscriptionLanguageResolver.resolveLanguage("ru"), "ru")
        XCTAssertEqual(TranscriptionLanguageResolver.resolveLanguage("en"), "en")
        XCTAssertEqual(TranscriptionLanguageResolver.resolveLanguage("  ru  "), "ru")
    }

    // MARK: - resolveTranslateTarget (Right ⌥ path)

    func testTranslateTarget_offByDefault() {
        XCTAssertNil(TranscriptionLanguageResolver.resolveTranslateTarget(translateFlag: false, configuredTarget: "en"))
    }

    func testTranslateTarget_onWithConfiguredTarget() {
        XCTAssertEqual(TranscriptionLanguageResolver.resolveTranslateTarget(translateFlag: true, configuredTarget: "en"), "en")
    }

    func testTranslateTarget_onButEmptyTargetIsNil() {
        XCTAssertNil(TranscriptionLanguageResolver.resolveTranslateTarget(translateFlag: true, configuredTarget: ""))
        XCTAssertNil(TranscriptionLanguageResolver.resolveTranslateTarget(translateFlag: true, configuredTarget: "   "))
    }

    // MARK: - whisperDetectLanguage (RU→EN fix, paired with usePrefillPrompt: true)

    func testDetectLanguage_onWhenAuto() {
        // No pinned language → detect it (instead of prefill defaulting to <|en|>).
        XCTAssertTrue(TranscriptionLanguageResolver.whisperDetectLanguage(language: nil))
    }

    func testDetectLanguage_offWhenPinned() {
        // Language is known → no detection needed; prefill straight to it.
        XCTAssertFalse(TranscriptionLanguageResolver.whisperDetectLanguage(language: "ru"))
        XCTAssertFalse(TranscriptionLanguageResolver.whisperDetectLanguage(language: "en"))
    }

    // MARK: - shouldIncludeBrandGlossary (RU→EN fix)

    func testGlossary_injectedOnlyForEnglish() {
        XCTAssertTrue(TranscriptionLanguageResolver.shouldIncludeBrandGlossary(language: "en"))
        XCTAssertTrue(TranscriptionLanguageResolver.shouldIncludeBrandGlossary(language: "EN"))
    }

    func testGlossary_notInjectedForNonEnglishOrAuto() {
        XCTAssertFalse(TranscriptionLanguageResolver.shouldIncludeBrandGlossary(language: "ru"))
        XCTAssertFalse(TranscriptionLanguageResolver.shouldIncludeBrandGlossary(language: "de"))
        XCTAssertFalse(TranscriptionLanguageResolver.shouldIncludeBrandGlossary(language: nil))
    }
}
