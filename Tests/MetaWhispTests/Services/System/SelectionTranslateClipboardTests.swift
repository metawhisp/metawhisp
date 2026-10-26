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

    private let targetPID: pid_t = 4101
    private let telegramType = NSPasteboard.PasteboardType("TelegramTextPboardType")

    private func borrow(from bundleID: String = "ru.keepcoder.Telegram",
                        readText: (() -> String?)? = nil) -> SelectionTranslator.ClipboardBorrow {
        SelectionTranslator.ClipboardBorrow(pasteboard: pasteboard, targetPID: targetPID,
                                             targetBundleIdentifier: bundleID, readText: readText)
    }

    /// The native composer's copy handler clears, declares rich types, then
    /// publishes its representations. This private pasteboard exercises those
    /// AppKit calls without opening an app or reading the general pasteboard.
    private func publishRichSelection(_ text: String = "A sample draft",
                                      includeCustomPayload: Bool = true) {
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.declareTypes([.rtf, telegramType], owner: nil)
        if includeCustomPayload {
            XCTAssertTrue(pasteboard.setData(Data("{}".utf8), forType: telegramType))
        }
        XCTAssertTrue(pasteboard.setData(Data("{\\rtf1 A sample draft}".utf8), forType: .rtf))
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
        XCTAssertEqual(pasteboard.changeCount - before, 2,
                       "One rich copy publishes through two ownership changes")
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        XCTAssertTrue(pasteboard.types?.contains(.rtf) == true)
        XCTAssertTrue(pasteboard.types?.contains(telegramType) == true)
    }

    func testNativeTelegramRichSelectionIsAcceptedAndReturnsTheBorrowedClipboard() {
        writeString("original")
        let borrow = borrow()
        borrow.begin()
        publishRichSelection()

        let copy = borrow.readCopiedText { targetPID }
        XCTAssertTrue(copy.owned, "A native rich copy must reach translation")
        XCTAssertEqual(copy.text, "A sample draft")
        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testNativeTelegramRichSelectionWithoutCustomPayloadIsAccepted() {
        writeString("original")
        let borrow = borrow()
        borrow.begin()
        publishRichSelection(includeCustomPayload: false)

        let copy = borrow.readCopiedText { targetPID }
        XCTAssertTrue(copy.owned, "The rich copy declares its custom type even without encoded data")
        XCTAssertEqual(copy.text, "A sample draft")
        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testGenericDoublePublicationIsRejectedWithoutReplacingIt() {
        writeString("original")
        let borrow = borrow(from: "com.example.Editor")
        borrow.begin()
        writeString("first copy")
        writeString("newer copy")

        XCTAssertFalse(borrow.readCopiedText { targetPID }.owned)
        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "newer copy")
    }

    func testRichMarkerFromAnotherAppDoesNotGrantClipboardOwnership() {
        writeString("original")
        let borrow = borrow(from: "com.example.Editor")
        borrow.begin()
        publishRichSelection()

        XCTAssertFalse(borrow.readCopiedText { targetPID }.owned)
        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "A sample draft")
    }

    func testTelegramDoublePublicationWithoutBothRichTypesIsRejected() {
        for types: [NSPasteboard.PasteboardType] in [[.rtf], [telegramType], [.string]] {
            writeString("original")
            let borrow = borrow()
            borrow.begin()
            let before = pasteboard.changeCount
            pasteboard.clearContents()
            pasteboard.declareTypes(types, owner: nil)
            XCTAssertTrue(pasteboard.setString("another copy", forType: .string))
            XCTAssertEqual(pasteboard.changeCount - before, 2)

            XCTAssertFalse(borrow.readCopiedText { targetPID }.owned)
            borrow.giveBack()
            XCTAssertEqual(pasteboard.string(forType: .string), "another copy")
        }
    }

    func testAnotherCopyAfterTelegramRichPublicationIsRejected() {
        writeString("original")
        let borrow = borrow()
        borrow.begin()
        publishRichSelection()
        writeString("newer user copy")

        XCTAssertFalse(borrow.readCopiedText { targetPID }.owned)
        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "newer user copy")
    }

    func testTelegramWithoutACopyIsRejectedAndReturnsTheOriginalClipboard() {
        writeString("original")
        let borrow = borrow()
        borrow.begin()

        XCTAssertFalse(borrow.readCopiedText { targetPID }.owned)
        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testSinglePublicationFromAnOrdinaryEditorRemainsAccepted() {
        writeString("original")
        let borrow = borrow(from: "com.example.Editor")
        borrow.begin()
        writeString("A plain draft")

        let copy = borrow.readCopiedText { targetPID }
        XCTAssertTrue(copy.owned)
        XCTAssertEqual(copy.text, "A plain draft")
        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testSinglePublicationFromTelegramWithoutRichTypesRemainsAccepted() {
        writeString("original")
        let borrow = borrow()
        borrow.begin()
        writeString("A plain draft")

        let copy = borrow.readCopiedText { targetPID }
        XCTAssertTrue(copy.owned)
        XCTAssertEqual(copy.text, "A plain draft")
        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testSelectionFromAChangedAppIsRejectedWithoutTakingItsClipboard() {
        writeString("original")
        let borrow = borrow()
        borrow.begin()
        writeString("A copy from the other app")

        XCTAssertFalse(borrow.readCopiedText { targetPID + 1 }.owned)
        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "A copy from the other app")
    }

    func testSelectionIsRejectedIfTheClipboardChangesWhileItsTextIsRead() {
        writeString("original")
        let borrow = borrow(readText: { [self] in
            let copied = pasteboard.string(forType: .string)
            writeString("A newer user copy")
            return copied
        })
        borrow.begin()
        writeString("A draft")

        XCTAssertFalse(borrow.readCopiedText { targetPID }.owned)
        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "A newer user copy")
    }

    func testSelectionIsRejectedIfTheTargetChangesWhileItsTextIsRead() {
        writeString("original")
        var currentPID = targetPID
        let borrow = borrow(readText: { [self] in
            currentPID += 1
            return pasteboard.string(forType: .string)
        })
        borrow.begin()
        writeString("A draft")

        XCTAssertFalse(borrow.readCopiedText { currentPID }.owned)
        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "A draft")
    }

    func testUserCopyAfterRichSelectionAcknowledgementIsPreserved() {
        writeString("original")
        let borrow = borrow()
        borrow.begin()
        publishRichSelection()
        XCTAssertTrue(borrow.readCopiedText { targetPID }.owned)

        writeString("A newer user copy")
        borrow.giveBack()
        XCTAssertEqual(pasteboard.string(forType: .string), "A newer user copy")
    }

    func testSharedTransactionDoesNotAcceptTheRichDoublePublicationByDefault() {
        writeString("original")
        let transaction = PasteboardReplacementTransaction(pasteboard: pasteboard)
        transaction.beginSelectionCopy()
        publishRichSelection()

        XCTAssertFalse(transaction.acknowledgeSelectionCopy())
        transaction.restoreIfOwned()
        XCTAssertEqual(pasteboard.string(forType: .string), "A sample draft")
    }

    private func copiedDraft(_ text: String = "A draft") -> SelectionTranslator.ClipboardBorrow {
        let borrow = borrow(from: "com.example.Editor")
        borrow.begin()
        writeString(text)
        XCTAssertTrue(borrow.readCopiedText { targetPID }.owned)
        return borrow
    }

    private func paste(_ text: String, using borrow: SelectionTranslator.ClipboardBorrow,
                       frontmostPID: (() -> pid_t?)? = nil,
                       waitBeforePaste: () async -> Void = {}, postPaste: () -> Bool,
                       settlePaste: () async -> Void = {}) async -> Bool {
        await borrow.pasteTranslation(
            text, frontmostPID: frontmostPID ?? { self.targetPID },
            waitBeforePaste: waitBeforePaste, postPaste: postPaste, settlePaste: settlePaste)
    }

    func testAUserCopyDuringModelWaitIsNotOverwrittenByTheTranslation() async {
        writeString("original")
        let borrow = copiedDraft()
        await Task.yield()
        writeString("A newer user copy")
        var posts = 0

        let sent = await paste("Translated draft", using: borrow, postPaste: { posts += 1; return true })

        XCTAssertFalse(sent)
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "A newer user copy")
    }

    func testAChangedAppDuringModelWaitPreventsWritingAndPastingTheTranslation() async {
        writeString("original")
        let borrow = copiedDraft()
        var posts = 0

        let sent = await paste("Translated draft", using: borrow,
                               frontmostPID: { self.targetPID + 1 },
                               postPaste: { posts += 1; return true })

        XCTAssertFalse(sent)
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testAUserCopyBeforeThePasteEventIsPreservedAndCancelsThePaste() async {
        writeString("original")
        let borrow = copiedDraft()
        var posts = 0
        var prepared = false

        let sent = await paste("Translated draft", using: borrow, waitBeforePaste: {
            prepared = true
            XCTAssertEqual(self.pasteboard.string(forType: .string), "Translated draft")
            self.writeString("A newer user copy")
        }, postPaste: { posts += 1; return true })

        XCTAssertTrue(prepared)
        XCTAssertFalse(sent)
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "A newer user copy")
    }

    func testAChangedAppBeforeThePasteEventCancelsThePasteAndRestoresTheClipboard() async {
        writeString("original")
        let borrow = copiedDraft()
        var currentPID = targetPID
        var posts = 0

        let sent = await paste("Translated draft", using: borrow,
                               frontmostPID: { currentPID },
                               waitBeforePaste: { currentPID += 1 },
                               postPaste: { posts += 1; return true })

        XCTAssertFalse(sent)
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCancellationBeforeThePasteEventRestoresWithoutPosting() async {
        writeString("original")
        let borrow = copiedDraft()
        var posts = 0
        let operation = Task { @MainActor in
            await paste("Translated draft", using: borrow, waitBeforePaste: {
                withUnsafeCurrentTask { $0?.cancel() }
            }, postPaste: { posts += 1; return true })
        }

        let sent = await operation.value
        XCTAssertFalse(sent)
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testARejectedPasteEventDoesNotReportSuccess() async {
        writeString("original")
        let borrow = copiedDraft()
        var attempted = false
        var settled = false

        let sent = await paste("Translated draft", using: borrow,
                               postPaste: { attempted = true; return false },
                               settlePaste: { settled = true })

        XCTAssertTrue(attempted)
        XCTAssertFalse(sent)
        XCTAssertFalse(settled)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testTheOriginalClipboardReturnsOnlyAfterThePasteHasSettled() async {
        writeImageLike()
        let originalImage = pasteboard.data(forType: .png)
        let borrow = copiedDraft()
        var events: [String] = []
        var returned = false

        let sent = await paste("Translated draft", using: borrow, waitBeforePaste: {
            events.append("prepared")
            XCTAssertEqual(self.pasteboard.string(forType: .string), "Translated draft")
        }, postPaste: {
            events.append("posted")
            XCTAssertEqual(self.pasteboard.string(forType: .string), "Translated draft")
            return true
        }, settlePaste: {
            await Task.yield()
            XCTAssertFalse(returned, "The operation must await the paste's settling period")
            XCTAssertEqual(self.pasteboard.string(forType: .string), "Translated draft")
            events.append("settled")
        })
        returned = true

        XCTAssertTrue(sent)
        XCTAssertEqual(events, ["prepared", "posted", "settled"])
        XCTAssertEqual(pasteboard.data(forType: .png), originalImage)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testCancellationAfterPostingStillWaitsBeforeRestoringTheClipboard() async {
        writeString("original")
        let borrow = copiedDraft()
        var settled = false
        let operation = Task { @MainActor in
            await paste("Translated draft", using: borrow, postPaste: {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }, settlePaste: {
                XCTAssertTrue(Task.isCancelled)
                await Task.yield()
                XCTAssertEqual(self.pasteboard.string(forType: .string), "Translated draft")
                settled = true
            })
        }

        let sent = await operation.value
        XCTAssertTrue(sent, "Cancellation cannot retract a paste event that was already posted")
        XCTAssertTrue(settled)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testWhitespaceAroundTheCopiedSelectionDoesNotLoseOwnership() async {
        writeString("original")
        let borrow = copiedDraft("  A draft\n")
        var posts = 0

        let sent = await paste("Translated draft", using: borrow, postPaste: { posts += 1; return true })

        XCTAssertTrue(sent)
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testAnUnacknowledgedCopyCannotBeReplacedByATranslation() async {
        writeString("original")
        let borrow = borrow()
        borrow.begin()
        var posts = 0

        let sent = await paste("Translated draft", using: borrow, postPaste: { posts += 1; return true })

        XCTAssertFalse(sent)
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testAnotherHoldCannotBorrowUntilCleanupAndTheNextHoldCanProceed() {
        writeString("original")
        var gate = SelectionTranslator.OperationGate()
        var snapshots = 0
        func start() -> SelectionTranslator.ClipboardBorrow? {
            guard gate.begin() else { return nil }
            snapshots += 1
            let borrow = borrow()
            borrow.begin()
            return borrow
        }

        let first = start()
        XCTAssertNotNil(first)
        writeString("A draft")
        XCTAssertTrue(first!.readCopiedText { targetPID }.owned)
        let whileBusy = start()
        XCTAssertNil(whileBusy, "Another hold must not snapshot the borrowed selection")
        XCTAssertEqual(snapshots, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "A draft")
        first?.giveBack()
        gate.finish()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")

        let next = start()
        XCTAssertNotNil(next, "Completion must admit the next hold")
        XCTAssertEqual(snapshots, 2)
        next?.giveBack()
        gate.finish()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }
}
