import XCTest
@testable import MetaWhisp

/// The brain's reads on the page's text, and the check's verdict.
final class BrainReadsTests: XCTestCase {
    func testSearchFindsEveryMatchWithItsContext() {
        let text = "Alpha costs $5.\nBeta costs $7.\nGamma is free."
        XCTAssertEqual(BrainScripts.search(text, pattern: "costs", caseSensitive: false, contextChars: 6, maxResults: 25),
                       "2 match(es):\n1. ...Alpha costs $5. B...\n2. ...Beta costs $7. G...")
        XCTAssertEqual(BrainScripts.search(text, pattern: "costs $", caseSensitive: false, contextChars: 0, maxResults: 1),
                       "2 match(es), first 1 shown:\n1. ...costs $...")
        XCTAssertEqual(BrainScripts.search(text, pattern: "delta", caseSensitive: false, contextChars: 5, maxResults: 5),
                       "No matches.")
        XCTAssertEqual(BrainScripts.search(text, pattern: "", caseSensitive: false, contextChars: 5, maxResults: 5),
                       "Invalid pattern.")
    }

    /// A pattern is plain text: a regular expression's own characters are read as themselves, and one that would
    /// backtrack without end finds nothing at once.
    func testAPatternIsPlainText() {
        let text = String(repeating: "a", count: 5_000) + "!"
        let started = Date()
        XCTAssertEqual(BrainScripts.search(text, pattern: "^(a+)+$", caseSensitive: false, contextChars: 5, maxResults: 5),
                       "No matches.")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(BrainScripts.search("Price [USD]: 5", pattern: "[USD]", caseSensitive: true, contextChars: 0,
                                           maxResults: 5), "1 match(es):\n1. ...[USD]...")
    }

    func testPartSaysWhereItStands() {
        XCTAssertEqual(BrainScripts.part(of: "abcdefgh", from: 2, chars: 3), "Characters 2 to 5 of 8\ncde")
        XCTAssertEqual(BrainScripts.part(of: "abc", from: 10, chars: 3), "Characters 3 to 3 of 3\n")
    }

    func testTheChecksVerdictIsReadFromItsJSON() {
        XCTAssertEqual(BrainJudge.verdict(in: #"{"verdict": false, "failure_reason": " Not sent. "}"#),
                       BrainJudge.Verdict(passed: false, reason: "Not sent."))
        XCTAssertEqual(BrainJudge.verdict(in: "Sure. {\"reasoning\": \"r\", \"verdict\": true} done"),
                       BrainJudge.Verdict(passed: true, reason: ""))
        XCTAssertNil(BrainJudge.verdict(in: "no json"))
        XCTAssertNil(BrainJudge.verdict(in: #"{"verdict": "yes"}"#))
        XCTAssertTrue(BrainJudge.instruction(today: "2026-10-19").contains("current date is 2026-10-19"))
    }


}
