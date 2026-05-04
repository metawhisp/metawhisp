import XCTest
import AppKit
@testable import MetaWhisp

/// Retroactive coverage for `TextInsertionService.writeToClipboardVerified`
/// — the root-cause fix for the "ничего не вставляется ⌘V" bug
/// (2026-05-01). Previously `pasteboard.setString` was called and its Bool
/// return discarded; on lost-ownership races the clipboard was silently
/// empty after the user thought their dictation had been saved. The new
/// helper writes + reads back + retries.
@MainActor
final class TextInsertionClipboardTests: XCTestCase {

    /// Save and restore the system pasteboard so tests don't clobber the
    /// developer's clipboard while running.
    private var savedClipboard: String?

    override func setUp() {
        super.setUp()
        savedClipboard = NSPasteboard.general.string(forType: .string)
    }

    override func tearDown() {
        if let saved = savedClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(saved, forType: .string)
        }
        super.tearDown()
    }

    /// Happy path: verified write puts the text on the system clipboard.
    func test_writeToClipboardVerified_writesText() {
        let text = "hello-clipboard-test-\(UUID().uuidString)"
        let ok = TextInsertionService.writeToClipboardVerified(text)
        XCTAssertTrue(ok)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
    }

    /// Empty string is a legitimate write — caller might want to clear
    /// (although in practice we never pass empty). Verify it doesn't crash
    /// and the read-back matches.
    func test_writeToClipboardVerified_handlesEmptyString() {
        let ok = TextInsertionService.writeToClipboardVerified("")
        XCTAssertTrue(ok)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "")
    }

    /// Multi-line / unicode payload survives round-trip (the user's
    /// dictation often has Cyrillic + emoji).
    func test_writeToClipboardVerified_unicodeRoundTrip() {
        let text = "Привет, как дела? 🤖\nLine two с emoji 🇷🇺"
        let ok = TextInsertionService.writeToClipboardVerified(text)
        XCTAssertTrue(ok)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
    }

    /// Sequential writes overwrite cleanly — last writer wins. Sanity
    /// check on `clearContents()` doing what we think.
    func test_writeToClipboardVerified_lastWriteWins() {
        XCTAssertTrue(TextInsertionService.writeToClipboardVerified("first"))
        XCTAssertTrue(TextInsertionService.writeToClipboardVerified("second"))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "second")
    }
}
