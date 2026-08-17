import XCTest
@testable import MetaWhisp

/// 2026-08-16 — why the automatic path stopped using the clipboard.
///
/// The old protocol selected the word, proved it with ⌘C and replaced it with
/// ⌘V. That left a LIVE SELECTION in the user's document for ~180 ms. Typing a
/// phrase — the entire point of this feature — put the next character inside
/// that window, so the correction either corrupted the text or (after the
/// timing guard) aborted. Net effect for anyone typing without pausing: no
/// correction at all.
///
/// The reference implementations split along exactly this line. The one that
/// corrects per word as you type re-sends keystrokes; the one that uses the
/// clipboard only ever fires on an explicit gesture, when the user is not
/// typing. So the automatic path now deletes the word with backspaces and
/// types the replacement: no selection, no clipboard, ~1 ms instead of 180.
final class LayoutKeystrokeReplacementTests: XCTestCase {

    private typealias Plan = LayoutKeystrokeReplacementPlan

    // MARK: - The separator has to be re-typed

    func test_deletesTheWordAndItsSeparator_thenTypesBoth() {
        // The caret sits after "ghbdtn ", so reaching the word means deleting
        // the separator too — and putting it back, or the user's next character
        // would run into the corrected word.
        let plan = Plan.plan(token: "ghbdtn", trailingText: " ", replacement: "привет")
        XCTAssertEqual(plan, Plan(backspaces: 7, insertion: "привет "))
    }

    func test_punctuationSeparatorIsPreserved() {
        XCTAssertEqual(
            Plan.plan(token: "ghbdtn", trailingText: ",", replacement: "привет"),
            Plan(backspaces: 7, insertion: "привет,")
        )
    }

    func test_newlineSeparatorIsPreserved() {
        XCTAssertEqual(
            Plan.plan(token: "cjj,otybt", trailingText: "\n", replacement: "сообщение"),
            Plan(backspaces: 10, insertion: "сообщение\n")
        )
    }

    // MARK: - Counts are in characters, because backspace deletes characters

    func test_replacementLongerThanTheOriginal_stillDeletesOnlyTheOriginal() {
        // Backspace count follows the text ON SCREEN, never the replacement.
        let plan = Plan.plan(token: "ghbdtn", trailingText: " ", replacement: "приветствие")
        XCTAssertEqual(plan?.backspaces, 7)
        XCTAssertEqual(plan?.insertion, "приветствие ")
    }

    func test_cyrillicSourceCountsAsCharactersNotBytes() {
        // RU→EN: the word on screen is Cyrillic. UTF-8 bytes would be double.
        let plan = Plan.plan(token: "руддщ", trailingText: " ", replacement: "hello")
        XCTAssertEqual(plan, Plan(backspaces: 6, insertion: "hello "))
    }

    func test_theUsersOwnListOfWords() {
        let cases: [(String, String, Int)] = [
            ("ghbdtn", "привет", 7),
            ("cjj,otybt", "сообщение", 10),
            (";bpym", "жизнь", 6),
            ("k.,jdm", "любовь", 7),
            ("hfcrkflrf", "раскладка", 10),
            ("руддщ", "hello", 6),
            ("цщкдв", "world", 6),
            ("ьфсршту", "machine", 8),
        ]
        for (token, replacement, backspaces) in cases {
            let plan = Plan.plan(token: token, trailingText: " ", replacement: replacement)
            XCTAssertEqual(plan?.backspaces, backspaces, "backspaces for \(token)")
            XCTAssertEqual(plan?.insertion, replacement + " ", "insertion for \(token)")
        }
    }

    // MARK: - Refuse anything whose on-screen length we cannot count

    func test_composedCharacters_areRefused() {
        // A combining sequence may be one character or several depending on the
        // editor, so the backspace count is not knowable. Refusing means the
        // correction is skipped — never that the wrong number of characters is
        // deleted.
        XCTAssertNil(Plan.plan(token: "e\u{0301}cole", trailingText: " ", replacement: "test"))
    }

    func test_emptyTokenIsRefused() {
        XCTAssertNil(Plan.plan(token: "", trailingText: " ", replacement: "привет"))
    }

    func test_emptyReplacementIsRefused() {
        // Deleting the user's word and typing nothing back is data loss.
        XCTAssertNil(Plan.plan(token: "ghbdtn", trailingText: " ", replacement: ""))
    }

    func test_emptyTrailingTextIsAllowed() {
        // Double Shift style: no separator was typed, the caret is on the word.
        XCTAssertEqual(
            Plan.plan(token: "ghbdtn", trailingText: "", replacement: "привет"),
            Plan(backspaces: 6, insertion: "привет")
        )
    }

    func test_absurdlyLongTokenIsRefused() {
        // A runaway backspace burst would eat text we never validated.
        let long = String(repeating: "a", count: Plan.maximumBackspaces + 1)
        XCTAssertNil(Plan.plan(token: long, trailingText: "", replacement: "x"))
    }

    func test_tokenAtTheBackspaceLimitIsAllowed() {
        let atLimit = String(repeating: "a", count: Plan.maximumBackspaces)
        XCTAssertEqual(
            Plan.plan(token: atLimit, trailingText: "", replacement: "x")?.backspaces,
            Plan.maximumBackspaces
        )
    }
}
