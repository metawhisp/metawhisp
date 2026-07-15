import XCTest
@testable import MetaWhisp

/// ITER-054 — pins the Pro-proxy transcribe URL contract, especially the
/// `count_usage=false` flag that fixes meeting double-billing (mic channel
/// bills the meeting once; the system channel rides free).
final class ProxyTranscribeURLTests: XCTestCase {

    private func url(language: String? = nil, promptWords: [String] = [], countUsage: Bool) -> String {
        CloudWhisperEngine.proxyTranscribeURLString(language: language, promptWords: promptWords, countUsage: countUsage)
    }

    /// The un-metered channel MUST carry count_usage=false — that's the whole fix.
    func test_countUsageFalse_emitsFlag() {
        XCTAssertTrue(url(countUsage: false).contains("count_usage=false"))
    }

    /// The metered path (dictations, mic channel) must NOT emit the flag —
    /// absence means "bill it", matching the worker default. Emitting
    /// count_usage=true would be harmless but the contract is «absent = bill».
    func test_countUsageTrue_omitsFlag() {
        XCTAssertFalse(url(countUsage: true).contains("count_usage"))
    }

    /// A metered dictation with no language/prompt is the bare endpoint — no
    /// stray query string.
    func test_metered_bare_isPlainEndpoint() {
        XCTAssertEqual(url(countUsage: true), "https://api.metawhisp.com/api/pro/transcribe")
    }

    /// Flag composes with the existing language + prompt params.
    func test_countUsageFalse_composesWithLanguageAndPrompt() {
        let s = url(language: "ru", promptWords: ["Brevo", "Claude"], countUsage: false)
        XCTAssertTrue(s.contains("language=ru"))
        XCTAssertTrue(s.contains("prompt="))
        XCTAssertTrue(s.contains("count_usage=false"))
        XCTAssertTrue(s.hasPrefix("https://api.metawhisp.com/api/pro/transcribe?"))
    }

    /// language="auto" is a sentinel for «detect» — never sent as a param.
    func test_autoLanguage_notSent() {
        XCTAssertFalse(url(language: "auto", countUsage: true).contains("language"))
    }
}
