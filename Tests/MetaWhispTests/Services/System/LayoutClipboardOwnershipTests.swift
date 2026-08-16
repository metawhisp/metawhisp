import XCTest
import AppKit
@testable import MetaWhisp

/// Release review, 2026-08-16 — the Layout Fix clipboard transaction lost the
/// user's clipboard on every aborted correction.
///
/// The replacement protocol proves the selection with a synthetic Cmd-C. That
/// copy is performed BY THE TARGET APP, so it advances `changeCount` past the
/// value `beginSelectionCopy()` had recorded. `restoreIfOwned()` then decided
/// it no longer owned the pasteboard and returned without restoring — so the
/// user's clipboard was destroyed and replaced by whatever text they had just
/// typed into the field. With Universal Clipboard on, that text left the Mac.
///
/// The distinction these cases pin: OUR OWN synthetic copy advances the count
/// by exactly one and must keep ownership; anything else is somebody else
/// copying and must be left strictly alone.
@MainActor
final class LayoutClipboardOwnershipTests: XCTestCase {

    /// A private pasteboard — unlike the pre-existing tests in this suite,
    /// these never touch the developer's real clipboard.
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.metawhisp.tests.layout-clipboard"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Stands in for the target application reacting to our synthetic Cmd-C.
    private func simulateTargetAppCopy(_ selection: String) {
        write(selection)
    }

    // MARK: - The regression

    func test_abortedCorrection_restoresTheUsersClipboard() {
        write("user's important clipboard")
        let transaction = PasteboardReplacementTransaction(pasteboard: pasteboard)

        transaction.beginSelectionCopy()
        simulateTargetAppCopy("ghbdtn")
        XCTAssertTrue(transaction.acknowledgeSelectionCopy(),
                      "Our own Cmd-C advances changeCount by exactly one and must keep ownership")

        // The correction now aborts — focus changed, validation failed, whatever.
        transaction.restoreIfOwned()

        XCTAssertEqual(pasteboard.string(forType: .string), "user's important clipboard",
                       "An aborted correction must give the user their clipboard back")
    }

    func test_abortedCorrection_doesNotLeaveTypedTextOnTheClipboard() {
        write("user's important clipboard")
        let transaction = PasteboardReplacementTransaction(pasteboard: pasteboard)

        transaction.beginSelectionCopy()
        simulateTargetAppCopy("secret-ish thing the user typed")
        _ = transaction.acknowledgeSelectionCopy()
        transaction.restoreIfOwned()

        XCTAssertNotEqual(pasteboard.string(forType: .string), "secret-ish thing the user typed",
                          "Field text copied to prove the selection must never be left on the clipboard")
    }

    // MARK: - An intervening user copy always wins

    func test_interveningUserCopy_isNeverOverwritten() {
        write("original")
        let transaction = PasteboardReplacementTransaction(pasteboard: pasteboard)

        transaction.beginSelectionCopy()
        simulateTargetAppCopy("ghbdtn")
        // The user hits Cmd-C themselves while our correction is in flight.
        write("something the user just copied")

        XCTAssertFalse(transaction.acknowledgeSelectionCopy(),
                       "Two advances means somebody else copied — we do not own this pasteboard")
        transaction.restoreIfOwned()

        XCTAssertEqual(pasteboard.string(forType: .string), "something the user just copied",
                       "The user's own copy must survive our correction untouched")
    }

    func test_userCopyAfterAcknowledgement_isStillNeverOverwritten() {
        write("original")
        let transaction = PasteboardReplacementTransaction(pasteboard: pasteboard)

        transaction.beginSelectionCopy()
        simulateTargetAppCopy("ghbdtn")
        XCTAssertTrue(transaction.acknowledgeSelectionCopy())
        // Copy lands later, after we already acknowledged our own.
        write("late user copy")

        transaction.restoreIfOwned()
        XCTAssertEqual(pasteboard.string(forType: .string), "late user copy")
    }

    // MARK: - The copy never landing

    func test_copyThatNeverLanded_isNotAcknowledged_andStillRestores() {
        write("original")
        let transaction = PasteboardReplacementTransaction(pasteboard: pasteboard)

        transaction.beginSelectionCopy()
        // Target app never responded to the synthetic Cmd-C.
        XCTAssertFalse(transaction.acknowledgeSelectionCopy(),
                       "No advance means the copy never happened")

        transaction.restoreIfOwned()
        XCTAssertEqual(pasteboard.string(forType: .string), "original",
                       "We cleared the clipboard ourselves, so we still owe the user a restore")
    }

    // MARK: - Non-string contents survive

    func test_nonStringClipboard_survivesAnAbortedCorrection() {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        item.setData(payload, forType: .tiff)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let transaction = PasteboardReplacementTransaction(pasteboard: pasteboard)
        transaction.beginSelectionCopy()
        simulateTargetAppCopy("ghbdtn")
        _ = transaction.acknowledgeSelectionCopy()
        transaction.restoreIfOwned()

        XCTAssertEqual(pasteboard.data(forType: .tiff), payload,
                       "An image on the clipboard must come back byte-for-byte")
    }

    // MARK: - The successful path still behaves

    func test_successfulReplacement_stillRestoresTheOriginal() {
        write("original")
        let transaction = PasteboardReplacementTransaction(pasteboard: pasteboard)

        transaction.beginSelectionCopy()
        simulateTargetAppCopy("ghbdtn")
        XCTAssertTrue(transaction.acknowledgeSelectionCopy())
        XCTAssertTrue(transaction.prepare(replacement: "привет"))
        XCTAssertTrue(transaction.stillOwns(contents: "привет"))

        transaction.restoreIfOwned()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }
}
