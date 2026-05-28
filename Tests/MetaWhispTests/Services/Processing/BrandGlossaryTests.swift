import XCTest
@testable import MetaWhisp

/// Regression guards for `BrandGlossary`.
///
/// Strategy: ALL canonical brands ship as prompt-bias hints (sent to Whisper
/// as initial_prompt and to Deepgram as keyterm — biases the decoder toward
/// the correct spelling). Auto-correct is conservative: ONLY for Cyrillic
/// mangles of public Latin-only brand names where the mangled string is
/// provably NOT a real Russian word.
///
/// Repo policy: only publicly-known industry brands are hardcoded here.
/// Per-user portfolio / client names go into `CorrectionDictionary` via
/// the Settings → Snippets UI — never in shipped source.
final class BrandGlossaryTests: XCTestCase {

    // MARK: - Prompt biasing list

    /// Glossary must include the common public industry brands ASR mangles.
    func test_promptHint_includesPublicBrands() {
        let hint = BrandGlossary.promptHint()
        XCTAssertTrue(hint.contains("Brevo"), "Brevo missing")
        XCTAssertTrue(hint.contains("MailChimp"), "MailChimp missing")
        XCTAssertTrue(hint.contains("Claude"), "Claude missing")
        XCTAssertTrue(hint.contains("ChatGPT"), "ChatGPT missing")
        XCTAssertTrue(hint.contains("LLM"), "LLM missing")
        XCTAssertTrue(hint.contains("MetaWhisp"), "MetaWhisp missing")
    }

    /// Hint format = comma-separated for both Whisper `initial_prompt` and
    /// Deepgram `keyterm`. Length should fit within the 224-token Whisper cap.
    func test_promptHint_isCommaSeparatedAndFitsWhisperCap() {
        let hint = BrandGlossary.promptHint()
        XCTAssertTrue(hint.contains(", "), "Hint should be comma-separated")
        // Rough cap: 224 tokens ≈ 900 chars worst case for short brand tokens.
        XCTAssertLessThan(hint.count, 800, "Hint too long for Whisper prompt cap")
    }

    // MARK: - Auto-correct (conservative — only unambiguous public-brand mangles)

    /// «Бриво» — not a Russian word. Public ESP Brevo.
    func test_autoCorrect_brivoToBrevo() {
        XCTAssertEqual(BrandGlossary.applyCorrections("сравниваем с Бриво"),
                       "сравниваем с Brevo")
    }

    func test_autoCorrect_brivoLowercaseToBrevo() {
        XCTAssertEqual(BrandGlossary.applyCorrections("обсуждаем бриво на встрече"),
                       "обсуждаем Brevo на встрече")
    }

    // MARK: - Regression guards — REAL Russian words MUST survive

    /// «молчим» is a real Russian verb ("we are silent"). Do NOT auto-correct
    /// to MailChimp — even though Whisper sometimes hallucinates it for the
    /// brand name. Risk of breaking a sentence like «когда говорим, молчим…».
    func test_autoCorrect_realMolchim_isPreserved() {
        let input = "когда мы говорим, мы молчим"
        XCTAssertEqual(BrandGlossary.applyCorrections(input), input)
    }

    /// «клод» as a name (rare, but possible — e.g. Claude Debussy).
    /// Auto-correct to Claude is too risky — leave it alone.
    func test_autoCorrect_realKlod_isPreserved() {
        let input = "клод дебюсси композитор"
        XCTAssertEqual(BrandGlossary.applyCorrections(input), input)
    }

    /// Clean speech unrelated to brands.
    func test_autoCorrect_cleanSpeech_isPreserved() {
        let input = "Сегодня обсуждаем релиз и я расскажу про новый дизайн"
        XCTAssertEqual(BrandGlossary.applyCorrections(input), input)
    }

    /// Case sensitivity check — «БРИВО» all caps still becomes Brevo
    /// (some users dictate in caps for emphasis).
    func test_autoCorrect_uppercaseCyrillicIsCorrected() {
        XCTAssertEqual(BrandGlossary.applyCorrections("БРИВО растет в Q4"),
                       "Brevo растет в Q4")
    }

    /// Word-boundary check: «бриволанд» (hypothetical concatenation) should
    /// NOT be touched — only stand-alone tokens get replaced. This prevents
    /// false positives on user-coined words containing the mangle as prefix.
    func test_autoCorrect_partialWordIsNotReplaced() {
        let input = "слово бриволанд это не бренд"
        XCTAssertEqual(BrandGlossary.applyCorrections(input), input)
    }

    /// User-specific brand names (portfolio, clients, colleagues) are NOT in
    /// the built-in glossary — they live in `CorrectionDictionary`. Repo
    /// policy: open-source binary must not embed identifying names.
    func test_autoCorrect_unknownBrandIsLeftAlone() {
        let input = "Сегодня обсуждали MyPrivateBrand с командой"
        XCTAssertEqual(BrandGlossary.applyCorrections(input), input)
    }
}
