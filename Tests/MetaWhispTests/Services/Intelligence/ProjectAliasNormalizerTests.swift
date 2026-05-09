import XCTest
@testable import MetaWhisp

/// Pure-function tests for `ProjectAliasNormalizer.canonicalize(_:)`.
///
/// Background (2026-05-08): user had ~52 ProjectAlias rows where ~46 were
/// near-duplicates: `Голосок`/`VoiceSnack` (transliteration), `ChatApp`/
/// `🚀 ChatApp` (emoji prefix), `CHATAPP`/`chatapp` (case). The
/// pre-fix `resolveCanonical` did `localizedCaseInsensitiveCompare` only —
/// missing transliteration, punctuation, and emoji.
///
/// `canonicalize` returns a normalized form that is purely for COMPARISON —
/// the original casing/script/punctuation of the user-visible alias is
/// preserved unchanged in storage. Two aliases whose canonical forms are
/// equal are treated as the same project.
final class ProjectAliasNormalizerTests: XCTestCase {

    /// Cyrillic ↔ Latin via Apple's `.toLatin` transform. ICU romanization
    /// is deterministic but specific: `й → j`, `ц → c`, `ш → sh`. Two
    /// inputs collapse to the same canonical form when they map through
    /// Apple's transform identically. (Free-form romanizations like LLM-
    /// generated `VoiceSnack` for `Голосок` are NOT caught here — those need
    /// the embedding-cosine merge stage downstream.)
    func test_cyrillicMatchesLatinTranslit() {
        XCTAssertEqual(
            ProjectAliasNormalizer.canonicalize("Голосок"),
            ProjectAliasNormalizer.canonicalize("Golosok")
        )
    }

    /// Case is folded — `CHATAPP` and `chatapp` collapse.
    func test_caseFolding() {
        XCTAssertEqual(
            ProjectAliasNormalizer.canonicalize("CHATAPP"),
            ProjectAliasNormalizer.canonicalize("chatapp")
        )
    }

    /// Trailing/leading whitespace stripped.
    func test_whitespaceStripped() {
        XCTAssertEqual(
            ProjectAliasNormalizer.canonicalize("  ChatApp  "),
            ProjectAliasNormalizer.canonicalize("ChatApp")
        )
    }

    /// Internal whitespace runs collapsed.
    func test_collapseInternalWhitespace() {
        XCTAssertEqual(
            ProjectAliasNormalizer.canonicalize("Atomic    Wallet"),
            ProjectAliasNormalizer.canonicalize("Acme Wallet")
        )
    }

    /// Punctuation and emoji stripped — `🚀 ChatApp!` matches `ChatApp`.
    func test_emojiAndPunctuationStripped() {
        XCTAssertEqual(
            ProjectAliasNormalizer.canonicalize("🚀 ChatApp!"),
            ProjectAliasNormalizer.canonicalize("ChatApp")
        )
    }

    /// Empty / whitespace-only → empty canonical (caller decides what to do).
    func test_emptyInput() {
        XCTAssertEqual(ProjectAliasNormalizer.canonicalize(""), "")
        XCTAssertEqual(ProjectAliasNormalizer.canonicalize("   "), "")
        XCTAssertEqual(ProjectAliasNormalizer.canonicalize("!!!"), "")
    }
}
