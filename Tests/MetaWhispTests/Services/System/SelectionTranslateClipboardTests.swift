import AppKit
import XCTest
@testable import MetaWhisp

/// Translate-selection borrows the clipboard to read what is selected. What it
/// borrows it must give back — all of it.
///
/// Before this, `translateSelection` snapshotted `pasteboard.string(forType:)`
/// alone and then called `clearContents()`, which destroys every other
/// representation: a copied image, a file, rich text. On the success path it
/// restored nothing at all, so a translate left the translation on the
/// clipboard in place of whatever the user had. The owner's report on
/// 2026-09-08 — "⌘C doesn't always copy" — is what a clipboard that quietly
/// changes underneath you feels like.
///
/// The layout-fix path already had the answer (`PasteboardReplacementTransaction`,
/// pinned by `LayoutClipboardOwnershipTests`); this suite holds the translator
/// to the same contract, and both now use the same type.
@MainActor
final class SelectionTranslateClipboardTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("MetaWhispSelectionTranslateTests"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.clearContents()
        pasteboard = nil
        super.tearDown()
    }

    private func writeString(_ s: String) {
        pasteboard.clearContents()
        pasteboard.setString(s, forType: .string)
    }

    private func writeImageLike() {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        pasteboard.writeObjects([item])
    }

    /// A copied PNG must still be a copied PNG after a translate that found
    /// nothing to translate.
    func testAnImageOnTheClipboardSurvivesATranslateThatFoundNothing() {
        writeImageLike()
        let before = pasteboard.data(forType: .png)
        XCTAssertNotNil(before)

        let borrow = SelectionTranslator.ClipboardBorrow(pasteboard: pasteboard)
        borrow.begin()                                   // clears, to detect a fresh copy
        XCTAssertNil(pasteboard.data(forType: .png), "the borrow really does clear")
        borrow.giveBack()

        XCTAssertEqual(pasteboard.data(forType: .png), before,
                       "the image must come back — it was never the translator's to destroy")
    }

    /// The success path owes the same restore as the failure path: after a
    /// translate, the clipboard is what it was before it.
    func testTheClipboardComesBackAfterASuccessfulTranslate() {
        writeString("what the user had copied")
        let borrow = SelectionTranslator.ClipboardBorrow(pasteboard: pasteboard)
        borrow.begin()
        // The target app answers our synthetic ⌘C with the selected words.
        pasteboard.clearContents(); pasteboard.setString("hello", forType: .string)
        XCTAssertTrue(borrow.acknowledgeCopy(), "one advance is ours")

        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "what the user had copied")
    }

    /// If the user copies something themselves while the translate is in
    /// flight, their copy stands. We restore only what we still own.
    func testAUserCopyDuringTheTranslateIsNotOverwritten() {
        writeString("older clipboard")
        let borrow = SelectionTranslator.ClipboardBorrow(pasteboard: pasteboard)
        borrow.begin()
        pasteboard.clearContents(); pasteboard.setString("hello", forType: .string)
        XCTAssertTrue(borrow.acknowledgeCopy())

        writeString("the user pressed ⌘C just now")   // a second advance: not ours
        borrow.giveBack()

        XCTAssertEqual(pasteboard.string(forType: .string), "the user pressed ⌘C just now",
                       "a restore must never bury a copy the user just made")
    }

    /// The synthetic ⌘C never landing is the ordinary case in a slow app, and
    /// it still ends with the user's clipboard intact.
    func testACopyThatNeverLandedStillGivesTheClipboardBack() {
        writeString("original")
        let borrow = SelectionTranslator.ClipboardBorrow(pasteboard: pasteboard)
        borrow.begin()
        XCTAssertFalse(borrow.acknowledgeCopy(), "nothing arrived, so nothing is ours to keep")
        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }
}
