import XCTest
@testable import MetaWhisp

/// ITER-076 stage 9d, № 21, № 23 — the agent's tabs not known closed, on disk
/// from the moment the browser made one until its close is confirmed: a crash,
/// a sleep or a close that failed leaves its id there for the next connection.
@MainActor
final class AgentTabLedgerTests: XCTestCase {
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mw-tabs-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("AgentTabs.json")
    }

    /// Listed from its making to its close, and the list outlives the app: a
    /// new ledger on the same file — the next launch — reads it.
    func testATabIsListedFromItsMakingUntilItsCloseAndTheListOutlivesTheApp() throws {
        let file = try file()
        let ledger = AgentTabLedger(file: file)
        XCTAssertEqual(ledger.open, [])
        ledger.opened("TARGET-1")
        ledger.opened("TARGET-2")
        ledger.closed("TARGET-1")
        XCTAssertEqual(AgentTabLedger(file: file).open, ["TARGET-2"], "read again, as after a crash")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600, "the owner's only")
        ledger.closed("TARGET-2")
        XCTAssertEqual(AgentTabLedger(file: file).open, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing left once every tab closed")
    }

    func testATabMadeTwiceIsListedOnce() throws {
        let ledger = AgentTabLedger(file: try file())
        ledger.opened("TARGET-1")
        ledger.opened("TARGET-1")
        XCTAssertEqual(ledger.open, ["TARGET-1"])
    }

    /// The app's link keeps the app's ledger: the tabs of one session are the
    /// next one's to close.
    func testTheAppsLinkKeepsTheAppsLedger() {
        XCTAssertEqual(ChromeLink.app(.ownWindow).tabs?.file, AgentTabLedger().file)
        XCTAssertEqual(AgentTabLedger().file.deletingLastPathComponent(), AppIdentity.current.supportDirectory,
                       "beside the records' folder, not in it: clearing MetaChat clears the user's errands only")
    }
}
