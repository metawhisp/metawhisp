import XCTest
@testable import MetaWhisp

/// Every API key in Settings is typed into `APIKeyField`, and a stored key is drawn only through its mask.
/// The bug this pins: two fields saved each keystroke into the keychain-backed setting, so the first character
/// became the stored key and the field switched to its masked label; that label repeated "•" `key.count - 4`
/// times, a negative count for a key shorter than four characters, and Swift traps on a negative repeat count.
/// The keys here are made-up letters, in no provider's shape.
final class APIKeyFieldTests: XCTestCase {
    private let bullet: Character = "\u{2022}"

    // MARK: - The mask

    /// The crash: a key of 0 to 5 characters is masked without trapping, all bullets, one per character.
    func testAShortKeyIsAllBulletsAndNeverTraps() {
        for length in 0...5 {
            let key = String("abcdef".prefix(length))
            XCTAssertEqual(APIKeyField.masked(key), String(repeating: bullet, count: length), "length \(length)")
        }
    }

    /// The tail is shown only when at least as many characters stay hidden: a short key shows nothing of itself.
    func testTheLastFourShowOnlyWhenAsManyStayHidden() {
        XCTAssertEqual(APIKeyField.masked("abcdefg"), String(repeating: bullet, count: 7))
        XCTAssertEqual(APIKeyField.masked("abcdefgh"), String(repeating: bullet, count: 4) + "efgh")
    }

    /// A real-length key: twenty bullets at most, then its last four characters.
    func testALongKeyShowsTwentyBulletsAndItsLastFour() {
        let key = String(repeating: "x", count: 52) + "wxyz"
        XCTAssertEqual(APIKeyField.masked(key), String(repeating: bullet, count: 20) + "wxyz")
    }

    // MARK: - What a draft commits

    /// A draft is committed trimmed; one with nothing but spaces or line breaks commits nothing.
    func testADraftCommitsTrimmedAndABlankDraftCommitsNothing() {
        XCTAssertEqual(APIKeyField.committed("  abcdefgh \n"), "abcdefgh")
        XCTAssertNil(APIKeyField.committed(""))
        XCTAssertNil(APIKeyField.committed(" \n\t "))
    }
}
