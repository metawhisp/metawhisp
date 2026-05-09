import XCTest
@testable import MetaWhisp

/// Pure-function tests for `WindowTitleNormalizer.normalize(_:)` and
/// `WindowTitleNormalizer.didContextChange(fromApp:fromTitle:toApp:toTitle:)`.
///
/// Ported verbatim from reference Omi `ContextDetection.swift` (ITER-027.1,
/// 2026-05-09). Background: many apps (Toggl, code editors, terminals,
/// web browsers with unread counts) update their window title on every
/// frame refresh — spinner glyphs, timer counters, dimension changes,
/// notification count badges. Without normalization the proactive
/// surface re-analyzes every 100 ms and floods the user with garbage.
/// Normalization strips the cosmetic noise so that "Toggl ⠋ 00:05:23"
/// and "Toggl ⠹ 00:05:24" collapse to the same canonical title.
final class WindowTitleNormalizerTests: XCTestCase {

    // MARK: - normalize

    /// Spinner glyphs (Braille block U+2800-U+28FF + common arrow/dot
    /// spinners) are stripped — even when they update every frame.
    func test_brailleSpinnerStripped() {
        let a = WindowTitleNormalizer.normalize("Toggl ⠋ work")
        let b = WindowTitleNormalizer.normalize("Toggl ⠹ work")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "Toggl work")
    }

    /// Counter timers `HH:MM`, `H:MM:SS` are removed.
    func test_timerPatternStripped() {
        let a = WindowTitleNormalizer.normalize("Toggl 00:05:23 work")
        let b = WindowTitleNormalizer.normalize("Toggl 00:05:24 work")
        XCTAssertEqual(a, b)
        XCTAssertFalse(a?.contains(":") ?? true)
    }

    /// Terminal dimensions like "80×24" or "60x88" are removed.
    func test_terminalDimensionStripped() {
        XCTAssertEqual(
            WindowTitleNormalizer.normalize("zsh — 80×24"),
            WindowTitleNormalizer.normalize("zsh — 100×40")
        )
    }

    /// Parenthetical / bracketed unread counts `(2)`, `[16]` removed.
    func test_unreadCountStripped() {
        XCTAssertEqual(
            WindowTitleNormalizer.normalize("(2) Inbox"),
            WindowTitleNormalizer.normalize("(99) Inbox")
        )
        XCTAssertEqual(
            WindowTitleNormalizer.normalize("[3] Slack"),
            WindowTitleNormalizer.normalize("[12] Slack")
        )
    }

    /// Multiple whitespace characters collapse to single space.
    func test_whitespaceCollapsed() {
        XCTAssertEqual(
            WindowTitleNormalizer.normalize("Code     Editor"),
            "Code Editor"
        )
    }

    /// Empty / nil input returns nil; pure-spinner input returns nil.
    func test_emptyInputs() {
        XCTAssertNil(WindowTitleNormalizer.normalize(nil))
        XCTAssertNil(WindowTitleNormalizer.normalize(""))
        XCTAssertNil(WindowTitleNormalizer.normalize("   "))
        XCTAssertNil(WindowTitleNormalizer.normalize("⠋⠙⠹"))
    }

    // MARK: - didContextChange

    /// Same app, same normalized title → no change.
    func test_didContextChange_sameAppSameTitle() {
        XCTAssertFalse(WindowTitleNormalizer.didContextChange(
            fromApp: "Code", fromTitle: "Project — Main.swift",
            toApp: "Code", toTitle: "Project — Main.swift"
        ))
    }

    /// Same app, only spinner/timer differs → still no change.
    func test_didContextChange_sameAppSpinnerNoise() {
        XCTAssertFalse(WindowTitleNormalizer.didContextChange(
            fromApp: "Toggl", fromTitle: "⠋ work 00:05:23",
            toApp: "Toggl", toTitle: "⠹ work 00:05:24"
        ))
    }

    /// App changed → context changed.
    func test_didContextChange_appChange() {
        XCTAssertTrue(WindowTitleNormalizer.didContextChange(
            fromApp: "Code", fromTitle: "Main.swift",
            toApp: "Slack", toTitle: "general channel"
        ))
    }

    /// Same app, real title change (not just noise) → context changed.
    func test_didContextChange_realTitleChange() {
        XCTAssertTrue(WindowTitleNormalizer.didContextChange(
            fromApp: "Code", fromTitle: "Main.swift",
            toApp: "Code", toTitle: "OtherFile.swift"
        ))
    }
}
