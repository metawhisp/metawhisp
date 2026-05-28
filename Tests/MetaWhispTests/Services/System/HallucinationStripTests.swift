import XCTest
@testable import MetaWhisp

/// Regression guards for `TranscriptionCoordinator.stripHallucinationTokens(_:)`.
///
/// Failing cases pulled from production meeting transcripts on 2026-05-28
/// (SwiftData `ZHISTORYITEM` where `ZSOURCE='meeting'`). Across the last 10
/// long meetings we saw:
///   - 14× `DimaTorzok` in final dual-stream transcripts
///   - `Субтитры сделал DimaTorzok`, `Субтитры создавал DimaTorzok`
///   - `Продолжение следует...`
///
/// Root cause of the leak (Confirmed by grep):
///   1. Meeting path (`AppDelegate.transcribeStreamChunked`) never calls
///      `stripHallucinationTokens` — only `isAlwaysHallucination`, which
///      returns false for texts >200 chars expecting the caller to strip.
///   2. The regex patterns don't cover the actual verb forms Whisper emits:
///      «создавал/сделал/делал/писал/подогнал» (only «by/от» are matched).
///   3. `Продолжение следует` lives only in `isHallucination` exact-match
///      (RMS<0.003 path), so it survives in meeting chunks with any
///      background audio.
///
/// These tests pin the post-fix behaviour so future regex tweaks don't
/// regress against real failures.
@MainActor
final class HallucinationStripTests: XCTestCase {

    // MARK: - DimaTorzok attribution variants (real production failures)

    /// Pure attribution chunk — should strip entirely.
    /// Observed: `meeting 2026-05-27 18:42:04`.
    func test_strip_subtitlesSdelalDimaTorzok_emptiesOut() {
        let result = TranscriptionCoordinator.stripHallucinationTokens("Субтитры сделал DimaTorzok")
        XCTAssertEqual(result, "", "Subtitle attribution with verb 'сделал' should be fully stripped")
    }

    /// «создавал» variant — currently leaks through because regex only covers «by/от».
    func test_strip_subtitlesSozdavalDimaTorzok_emptiesOut() {
        let result = TranscriptionCoordinator.stripHallucinationTokens("Субтитры создавал DimaTorzok")
        XCTAssertEqual(result, "", "Subtitle attribution with verb 'создавал' should be fully stripped")
    }

    /// «делал» variant.
    func test_strip_subtitlesDelalDimaTorzok_emptiesOut() {
        let result = TranscriptionCoordinator.stripHallucinationTokens("Субтитры делал DimaTorzok")
        XCTAssertEqual(result, "")
    }

    /// «подогнал» variant.
    func test_strip_subtitlesPodognalDimaTorzok_emptiesOut() {
        let result = TranscriptionCoordinator.stripHallucinationTokens("Субтитры подогнал DimaTorzok")
        XCTAssertEqual(result, "")
    }

    /// Mid-speech splicing — real speech BEFORE and AFTER the artifact stays.
    /// This is the meeting-failure pattern that strip is meant to fix.
    func test_strip_realSpeechAroundArtifact_preservesSpeech() {
        let input = "реальная речь Субтитры создавал DimaTorzok ещё речь"
        let result = TranscriptionCoordinator.stripHallucinationTokens(input)
        XCTAssertEqual(result, "реальная речь ещё речь")
    }

    // MARK: - "Продолжение следует" (Russian "to be continued" — YouTube intro)

    /// Standalone — should strip entirely.
    /// Observed: `meeting 2026-05-28 09:00:02` starts with this.
    func test_strip_prodolzhenieSleduet_emptiesOut() {
        let result = TranscriptionCoordinator.stripHallucinationTokens("Продолжение следует...")
        XCTAssertEqual(result, "")
    }

    /// With ellipsis variants.
    func test_strip_prodolzhenieSleduetEllipsis_emptiesOut() {
        let result = TranscriptionCoordinator.stripHallucinationTokens("Продолжение следует…")
        XCTAssertEqual(result, "")
    }

    /// Mid-speech splicing — strip only the artifact.
    func test_strip_prodolzhenieMidSpeech_preservesSpeech() {
        let input = "это начало Продолжение следует... это продолжение"
        let result = TranscriptionCoordinator.stripHallucinationTokens(input)
        XCTAssertEqual(result, "это начало это продолжение")
    }

    /// English equivalent.
    func test_strip_toBeContinued_emptiesOut() {
        let result = TranscriptionCoordinator.stripHallucinationTokens("To be continued")
        XCTAssertEqual(result, "")
    }

    // MARK: - YouTube boilerplate (Whisper training-data artifacts)

    func test_strip_podpisyvaitesNaKanal_emptiesOut() {
        let result = TranscriptionCoordinator.stripHallucinationTokens("Подписывайтесь на канал")
        XCTAssertEqual(result, "")
    }

    func test_strip_spasiboZaProsmotr_emptiesOut() {
        let result = TranscriptionCoordinator.stripHallucinationTokens("Спасибо за просмотр")
        XCTAssertEqual(result, "")
    }

    func test_strip_subscribePleasecLike_emptiesOut() {
        let result = TranscriptionCoordinator.stripHallucinationTokens("Please like and subscribe")
        XCTAssertEqual(result, "")
    }

    // MARK: - Regression guards — real speech MUST survive

    /// Critical: don't break clean speech.
    func test_strip_cleanSpeech_isPreserved() {
        let input = "Сегодня обсуждаем релиз и я расскажу про новый дизайн"
        let result = TranscriptionCoordinator.stripHallucinationTokens(input)
        XCTAssertEqual(result, input)
    }

    /// Words that PARTIALLY overlap hallucination patterns should NOT trigger strip.
    /// E.g. "продолжение" alone (without «следует») is a real word.
    func test_strip_realProdolzhenie_isPreserved() {
        let input = "Расскажи про продолжение проекта на следующей неделе"
        let result = TranscriptionCoordinator.stripHallucinationTokens(input)
        XCTAssertEqual(result, input)
    }

    /// «субтитры» as a real topic word — should survive when not attributing.
    /// (e.g. "Нужны субтитры на финальном видео" is real meeting content.)
    func test_strip_subtitlesAsTopic_isPreserved() {
        let input = "Нужны субтитры на финальном видео для YouTube"
        let result = TranscriptionCoordinator.stripHallucinationTokens(input)
        XCTAssertEqual(result, input)
    }

    /// Already-existing coverage (by/от form) should keep working.
    func test_strip_subtitlesByDimaTorzok_emptiesOut_existingPattern() {
        let result = TranscriptionCoordinator.stripHallucinationTokens("Subtitles by DimaTorzok")
        XCTAssertEqual(result, "")
    }
}
