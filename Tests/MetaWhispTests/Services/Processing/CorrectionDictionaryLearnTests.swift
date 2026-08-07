import XCTest
@testable import MetaWhisp

/// Pins the 2026-08-06 root fix: one user edit is NOT a rule.
///
/// `learn(original:corrected:)` used to promote a single context-specific edit
/// («ссылка на сайт» → «ссылка в сайт») into a GLOBAL replacement («на»→«в»)
/// that then rewrote every «на» in every later transcript. Now the first
/// sighting only stores a candidate; the rule activates when the SAME
/// correction is observed a second time.
@MainActor
final class CorrectionDictionaryLearnTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("correction-dict-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeDict() -> CorrectionDictionary {
        let d = CorrectionDictionary(directory: dir)
        // Brands seed defaults on first launch; drop them so apply() output
        // reflects learned corrections only.
        d.removeAllBrands()
        return d
    }

    func test_learnOnce_doesNotActivateRule() {
        let dict = makeDict()
        dict.learn(original: "ссылка на сайт", corrected: "ссылка в сайт")
        XCTAssertEqual(dict.apply("поставь на стол"), "поставь на стол",
                       "a single edit must not become a global replacement")
    }

    func test_learnSameEditTwice_activatesRule() {
        let dict = makeDict()
        dict.learn(original: "включи легбилдинг сюда", corrected: "включи линкбилдинг сюда")
        dict.learn(original: "про легбилдинг помни", corrected: "про линкбилдинг помни")
        XCTAssertEqual(dict.apply("обсудим легбилдинг завтра"), "обсудим линкбилдинг завтра")
    }

    func test_learnConflictingEdits_doNotActivate() {
        let dict = makeDict()
        dict.learn(original: "скинь на почту", corrected: "скинь в почту")
        dict.learn(original: "скинь на диск", corrected: "скинь под диск")
        XCTAssertEqual(dict.apply("положи на стол"), "положи на стол",
                       "conflicting candidates must not activate either variant")
    }

    func test_candidateSurvivesRestart() {
        makeDict().learn(original: "включи легбилдинг сюда", corrected: "включи линкбилдинг сюда")
        let reloaded = makeDict()
        reloaded.learn(original: "про легбилдинг помни", corrected: "про линкбилдинг помни")
        XCTAssertEqual(reloaded.apply("обсудим легбилдинг завтра"), "обсудим линкбилдинг завтра",
                       "1st sighting before restart + 2nd after must still activate")
    }

    func test_manualAdd_activatesImmediately() {
        let dict = makeDict()
        dict.add(original: "легбилдинг", replacement: "линкбилдинг")
        XCTAssertEqual(dict.apply("обсудим легбилдинг завтра"), "обсудим линкбилдинг завтра",
                       "explicit UI adds are intentional — no threshold")
    }
}
