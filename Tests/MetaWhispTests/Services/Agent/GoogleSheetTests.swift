import AppKit
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 6 (№ 163, 26, 170-172) — the Sheet in the user's own Chrome: a new Google Sheet made in a
/// background tab of the errand's own, named after the user's words, pasted into and read back there — as the live
/// probe of 2026-10-06 found Sheets takes it — and closed with that tab. On the fixture browser that plays Sheets
/// as the probe saw it (`SheetTabBridge`).
@MainActor
final class GoogleSheetTests: XCTestCase {

    /// `sheets.new` opens in a new tab the destination owns; once the tab shows the new Sheet's editor, its address
    /// is the receipt — given before the name is set — and the Sheet is named after the user's words.
    func testANewSheetIsMadeInATabOfItsOwnAndNamed() async throws {
        let bridge = SheetTabBridge()
        let sheet = GoogleSheet(bridge: bridge)
        var receipts: [URL] = []
        let address = try await sheet.create(title: "Find 10 competitors", made: { receipts.append($0) })

        XCTAssertEqual(address, URL(string: "https://docs.google.com/spreadsheets/d/SHEET-1/edit"))
        XCTAssertEqual(receipts, [address], "the receipt, once")
        XCTAssertEqual(bridge.sheetTabs.count, 1)
        XCTAssertEqual(bridge.names, ["Find 10 competitors"])
        XCTAssertEqual(bridge.ran.map(\.kind).last, "name", "named once the Sheet exists")
        XCTAssertEqual(bridge.inner.openTabCount, 0, "no other tab is opened")
    }

    /// The rows go into the Sheet's own tab by a paste its cell editor takes — the probe's method: no key, no
    /// clipboard — and its TSV export, fetched in that tab, is read back cell by cell.
    func testThePasteGoesIntoTheSheetsOwnTabAndIsReadBackFromItsExport() async throws {
        let bridge = SheetTabBridge()
        let sheet = GoogleSheet(bridge: bridge)
        let address = try await sheet.create(title: "Jokes", made: { _ in })
        let text = SheetCells.pasteText(rows: [["Result", "Source"], ["He said \"hi\", then left.", "https://a.test/1"],
                                               ["1.50", "=1+1"]], empty: "")
        let clipboard = NSPasteboard.general.changeCount
        try await sheet.paste(text, into: address)
        let shown = try await sheet.readBack(address)

        let tab = try XCTUnwrap(bridge.sheetTabs.first)
        XCTAssertEqual(bridge.pastedText(in: tab), text)
        XCTAssertEqual(shown.cells, [["Result", "Source"], ["He said \"hi\", then left.", "https://a.test/1"],
                                     ["1.50", "=1+1"]])
        XCTAssertFalse(shown.holdsFormula)
        XCTAssertTrue(bridge.ran.allSatisfy { $0.tab == tab }, "every script ran in the Sheet's own tab")
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboard, "the user's clipboard is never touched")
    }

    /// Another Sheet's address is not this destination's: nothing is pasted, nothing read.
    func testOnlyItsOwnSheetIsPastedIntoOrRead() async throws {
        let bridge = SheetTabBridge()
        let sheet = GoogleSheet(bridge: bridge)
        _ = try await sheet.create(title: "Jokes", made: { _ in })
        let other = URL(string: "https://docs.google.com/spreadsheets/d/OTHER/edit")!
        do {
            try await sheet.paste("'a", into: other)
            XCTFail("pasted into another Sheet")
        } catch {}
        do {
            _ = try await sheet.readBack(other)
            XCTFail("read another Sheet")
        } catch {}
        XCTAssertFalse(bridge.ran.contains { $0.kind == "paste" || $0.kind == "export" })
    }

    /// Google's sign-in where the Sheet should be is the user's part, in the Sheet's own tab: it is said — with
    /// the tab — not waited out. Asked again, the Sheet is made in a new tab, the old one closed.
    func testASignInOnTheWayIsTheUsersPartInTheSheetsOwnTab() async throws {
        let bridge = SheetTabBridge()
        bridge.landings = [.signIn, .editor]
        let sheet = GoogleSheet(bridge: bridge)
        do {
            _ = try await sheet.create(title: "Jokes", made: { _ in XCTFail("no Sheet yet") })
            XCTFail("a sign-in is no Sheet")
        } catch let wall as SheetWall {
            XCTAssertEqual(wall.handover, ErrandHandover(kind: .signIn, host: "accounts.google.com"))
            XCTAssertEqual(wall.tab, bridge.sheetTabs.first)
        }
        let address = try await sheet.create(title: "Jokes", made: { _ in })
        XCTAssertEqual(address.path, "/spreadsheets/d/SHEET-2/edit")
        XCTAssertEqual(bridge.closed.map(\.tab), [bridge.sheetTabs[0]], "the sign-in tab closed for the new one")
    }

    /// A tab that never shows a Sheet's editor in time is no Sheet: no receipt, and an error.
    func testNoEditorInTimeIsNoSheet() async throws {
        let bridge = SheetTabBridge()
        bridge.landings = [.nowhere]
        let sheet = GoogleSheet(bridge: bridge, editorLimit: .milliseconds(600))
        do {
            _ = try await sheet.create(title: "Jokes", made: { _ in XCTFail("no receipt without a Sheet") })
            XCTFail("no Sheet")
        } catch {
            XCTAssertEqual(error as? GoogleSheet.Failure, .notMade)
        }
    }

    /// Its tab closes with it, once.
    func testCloseClosesItsTab() async throws {
        let bridge = SheetTabBridge()
        let sheet = GoogleSheet(bridge: bridge)
        _ = try await sheet.create(title: "Jokes", made: { _ in })
        await sheet.close()
        await sheet.close()
        XCTAssertEqual(bridge.closed.map(\.tab), bridge.sheetTabs)
    }

    /// The Sheet's own path, from where the tab landed: only docs.google.com, only an id of Google's letters.
    func testTheSheetsPathIsReadOnlyFromAnEditorOnDocsGoogleCom() {
        XCTAssertEqual(GoogleSheet.base(host: "docs.google.com", path: "/spreadsheets/d/1K0l_PQ-z9/edit"),
                       "/spreadsheets/d/1K0l_PQ-z9")
        XCTAssertNil(GoogleSheet.base(host: "evil.test", path: "/spreadsheets/d/1K0l/edit"))
        XCTAssertNil(GoogleSheet.base(host: "docs.google.com", path: "/spreadsheets/u/0/create"))
        XCTAssertNil(GoogleSheet.base(host: "docs.google.com", path: "/spreadsheets/d/a'b/edit"))
        XCTAssertNil(GoogleSheet.base(host: "docs.google.com", path: "/document/d/1K0l/edit"))
    }
}
