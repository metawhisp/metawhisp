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

    // MARK: - promptWordSafeForNonEnglish (TR-3)

    func testSafeWord_asciiLatinIsUnsafe() {
        // English brand names are exactly the tokens that bias the decoder to <|en|>.
        XCTAssertFalse(TranscriptionLanguageResolver.promptWordSafeForNonEnglish("Brevo"))
        XCTAssertFalse(TranscriptionLanguageResolver.promptWordSafeForNonEnglish("MailChimp"))
        XCTAssertFalse(TranscriptionLanguageResolver.promptWordSafeForNonEnglish("ChatGPT"))
        XCTAssertFalse(TranscriptionLanguageResolver.promptWordSafeForNonEnglish(""))
        // Pure punctuation/digits are still ASCII → not a safe non-English seed.
        XCTAssertFalse(TranscriptionLanguageResolver.promptWordSafeForNonEnglish("123"))
    }

    func testSafeWord_nonAsciiIsSafe() {
        // Cyrillic and other non-ASCII words don't pull detection toward English.
        XCTAssertTrue(TranscriptionLanguageResolver.promptWordSafeForNonEnglish("Бриво"))
        XCTAssertTrue(TranscriptionLanguageResolver.promptWordSafeForNonEnglish("Озон"))
        // A single non-ASCII scalar anywhere is enough (mixed token).
        XCTAssertTrue(TranscriptionLanguageResolver.promptWordSafeForNonEnglish("Sтудия"))
    }

    // MARK: - filterPromptWords (TR-3: glossary + correction-dict gating)

    func testFilterPromptWords_englishKeepsEverything() {
        let words = ["Brevo", "MailChimp", "Бриво"]
        XCTAssertEqual(TranscriptionLanguageResolver.filterPromptWords(words, language: "en"), words)
        XCTAssertEqual(TranscriptionLanguageResolver.filterPromptWords(words, language: "EN"), words)
    }

    func testFilterPromptWords_nonEnglishDropsAsciiKeepsCyrillic() {
        let words = ["Brevo", "MailChimp", "Бриво", "Озон"]
        XCTAssertEqual(
            TranscriptionLanguageResolver.filterPromptWords(words, language: "ru"),
            ["Бриво", "Озон"]
        )
    }

    func testFilterPromptWords_autoOrNilDropsAsciiBrandTokens() {
        // The RU→EN regression path: auto-detect must NOT receive English seeds.
        let words = ["Brevo", "Claude", "Контур"]
        XCTAssertEqual(TranscriptionLanguageResolver.filterPromptWords(words, language: nil), ["Контур"])
    }

    func testFilterPromptWords_emptyStaysEmpty() {
        XCTAssertTrue(TranscriptionLanguageResolver.filterPromptWords([], language: "ru").isEmpty)
        XCTAssertTrue(TranscriptionLanguageResolver.filterPromptWords([], language: "en").isEmpty)
    }

    // MARK: - A1: integration guard against the REAL (all-English) brand glossary

    func testFilterPromptWords_realGlossaryEmptyForRussianAndAuto() {
        // The actual glossary is the production prompt source. It's 100% ASCII, so
        // gating it on RU/auto must yield an EMPTY prompt — no EN seed. This pins
        // the behavior so a future non-ASCII glossary addition can't silently leak.
        let glossary = BrandGlossary.canonicalNames()
        XCTAssertFalse(glossary.isEmpty, "precondition: glossary is non-empty")
        XCTAssertTrue(TranscriptionLanguageResolver.filterPromptWords(glossary, language: "ru").isEmpty)
        XCTAssertTrue(TranscriptionLanguageResolver.filterPromptWords(glossary, language: nil).isEmpty)
    }

    func testFilterPromptWords_realGlossaryFullForEnglish() {
        let glossary = BrandGlossary.canonicalNames()
        XCTAssertEqual(TranscriptionLanguageResolver.filterPromptWords(glossary, language: "en"), glossary)
    }

    // MARK: - enginePromptWords (2026-08-06 prompt-echo root fix)

    // The API takes NO word list — the curated glossary is the only possible
    // prompt source, so the correction dictionary structurally CANNOT leak into
    // the decoder prompt again (its values echoed back as fake «speech» on
    // silence: «линкбилдинг, Не наебывай, …»).

    func testEnginePromptWords_glossaryOnlyForEnglish() {
        XCTAssertEqual(
            TranscriptionLanguageResolver.enginePromptWords(language: "en"),
            BrandGlossary.canonicalNames()
        )
    }

    func testEnginePromptWords_emptyForNonEnglishAndAuto() {
        XCTAssertTrue(TranscriptionLanguageResolver.enginePromptWords(language: "ru").isEmpty)
        XCTAssertTrue(TranscriptionLanguageResolver.enginePromptWords(language: nil).isEmpty)
    }

    // MARK: - shouldPinDetectedLanguage (ITER-060.2: per-channel pinning)

    func testPinLanguage_substantialChunkPins() {
        XCTAssertTrue(TranscriptionLanguageResolver.shouldPinDetectedLanguage(detected: "ru", wordCount: 5))
        XCTAssertTrue(TranscriptionLanguageResolver.shouldPinDetectedLanguage(detected: "en", wordCount: 50))
    }

    func testPinLanguage_shortChunkDoesNotPin() {
        // A chunk holding a lone «Угу» must not lock the channel's language.
        XCTAssertFalse(TranscriptionLanguageResolver.shouldPinDetectedLanguage(detected: "ru", wordCount: 4))
        XCTAssertFalse(TranscriptionLanguageResolver.shouldPinDetectedLanguage(detected: "ru", wordCount: 1))
    }

    func testPinLanguage_noDetectionDoesNotPin() {
        XCTAssertFalse(TranscriptionLanguageResolver.shouldPinDetectedLanguage(detected: nil, wordCount: 20))
        XCTAssertFalse(TranscriptionLanguageResolver.shouldPinDetectedLanguage(detected: "", wordCount: 20))
    }
}
