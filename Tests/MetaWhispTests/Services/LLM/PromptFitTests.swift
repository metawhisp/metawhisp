import XCTest
@testable import MetaWhisp

/// ITER-081 — a prompt fitted to the proxy's limit is measured in the units
/// the proxy counts (UTF-16), never splits a Character, keeps the ending, and
/// returns for every input.
final class PromptFitTests: XCTestCase {

    private let marker = PromptFit.omissionMarker

    func testAPromptThatFitsIsExactlyHeaderNewlineTranscript() {
        let transcript = String(repeating: "a", count: 100)
        XCTAssertEqual(PromptFit.fit(header: "H", transcript: transcript, unitLimit: 102), "H\n" + transcript)
    }

    func testOneUnitOverKeepsTheHeaderTheStartAndTheEnd() {
        let transcript = "START" + String(repeating: "a", count: 200) + "END"
        let fitted = PromptFit.fit(header: "H", transcript: transcript, unitLimit: transcript.utf16.count + 1)
        XCTAssertLessThanOrEqual(fitted.utf16.count, transcript.utf16.count + 1)
        XCTAssertTrue(fitted.hasPrefix("H\nSTART"))
        XCTAssertTrue(fitted.hasSuffix("END"))
        XCTAssertTrue(fitted.contains(marker))
    }

    func testAHeaderAtOrNearTheLimitStillReturnsWithinIt() {
        let limit = 300
        for headerUnits in [limit + 50, limit, limit - 1, limit - marker.utf16.count, limit - marker.utf16.count - 3] {
            let header = String(repeating: "h", count: headerUnits)
            let fitted = PromptFit.fit(header: header, transcript: String(repeating: "t", count: 1_000), unitLimit: limit)
            XCTAssertLessThanOrEqual(fitted.utf16.count, limit, "header \(headerUnits)")
        }
    }

    func testANonPositiveLimitReturnsNothing() {
        XCTAssertEqual(PromptFit.fit(header: "H", transcript: "text", unitLimit: 0), "")
        XCTAssertEqual(PromptFit.fit(header: "H", transcript: "text", unitLimit: -5), "")
        XCTAssertEqual(PromptFit.headAndTail("text", unitLimit: -5), "")
    }

    func testEmojiAreCountedAsTheirUnitsAndNeverSplit() {
        let text = String(repeating: "\u{1F600}", count: 100)   // 200 units
        let cut = PromptFit.headAndTail(text, unitLimit: 51)
        XCTAssertLessThanOrEqual(cut.utf16.count, 51)
        XCTAssertTrue(cut.replacingOccurrences(of: marker, with: "").allSatisfy { $0 == "\u{1F600}" })
    }

    func testOneOversizedCharacterAtTheStartDoesNotCostTheEnding() {
        let heavy = "a" + String(repeating: "\u{0301}", count: 50_000)   // one Character, 50,001 units
        let text = heavy + String(repeating: "b", count: 1_000) + "END"
        let cut = PromptFit.headAndTail(text, unitLimit: 600)
        XCTAssertLessThanOrEqual(cut.utf16.count, 600)
        XCTAssertTrue(cut.hasSuffix("END"))
        XCTAssertFalse(cut.contains(heavy))
    }

    func testZeroWidthJoinerSequencesStayWhole() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"   // one Character, 11 units
        let cut = PromptFit.headAndTail(String(repeating: family, count: 100), unitLimit: 200)
        XCTAssertLessThanOrEqual(cut.utf16.count, 200)
        XCTAssertTrue(cut.replacingOccurrences(of: marker, with: "").allSatisfy { String($0) == family })
    }

    func testCJKStaysWithinTheLimit() {
        let cut = PromptFit.headAndTail(String(repeating: "\u{4F1A}\u{8BAE}", count: 50_000), unitLimit: 1_000)
        XCTAssertLessThanOrEqual(cut.utf16.count, 1_000)
        XCTAssertTrue(cut.contains(marker))
    }

    func testPrefixAndSuffixTakeWholeCharactersOnly() {
        XCTAssertEqual(PromptFit.prefix("ab\u{1F600}c", units: 3), "ab")
        XCTAssertEqual(PromptFit.suffix("a\u{1F600}bc", units: 3), "bc")
        XCTAssertEqual(PromptFit.suffix("a\u{1F600}bc", units: 4), "\u{1F600}bc")
    }
}
