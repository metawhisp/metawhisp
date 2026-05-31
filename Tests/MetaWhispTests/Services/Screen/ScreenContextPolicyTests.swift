import XCTest
@testable import MetaWhisp

/// AUD-021 — the user's Screen Context blacklist/whitelist choice was never
/// wired into capture. These pin the settings → policy resolution so an
/// excluded app is actually excluded.
final class ScreenContextPolicyTests: XCTestCase {

    func test_blacklistMode_parsesListIntoBlacklist() {
        let p = ScreenContextPolicy.resolve(mode: "blacklist", appList: "Banking, 1Password ,Telegram")
        XCTAssertEqual(p.blacklist, ["Banking", "1Password", "Telegram"])
        XCTAssertNil(p.whitelist)
    }

    func test_whitelistMode_parsesListIntoWhitelist() {
        let p = ScreenContextPolicy.resolve(mode: "whitelist", appList: "Xcode,Safari")
        XCTAssertEqual(p.whitelist, ["Xcode", "Safari"])
        XCTAssertTrue(p.blacklist.isEmpty)
    }

    func test_blacklistMode_emptyList_emptyBlacklistNilWhitelist() {
        let p = ScreenContextPolicy.resolve(mode: "blacklist", appList: "")
        XCTAssertTrue(p.blacklist.isEmpty)
        XCTAssertNil(p.whitelist)
    }

    /// Safety: whitelist mode with nothing listed must NOT silently capture
    /// nothing — treat it as no restriction (nil), not an all-blocking set.
    func test_whitelistMode_emptyList_treatedAsNoRestriction() {
        let p = ScreenContextPolicy.resolve(mode: "whitelist", appList: "   ")
        XCTAssertNil(p.whitelist)
        XCTAssertTrue(p.blacklist.isEmpty)
    }

    func test_trimsWhitespaceAndDropsEmptyEntries() {
        let p = ScreenContextPolicy.resolve(mode: "blacklist", appList: " A ,, B ,")
        XCTAssertEqual(p.blacklist, ["A", "B"])
    }

    func test_unknownMode_defaultsToBlacklist() {
        let p = ScreenContextPolicy.resolve(mode: "weird", appList: "X")
        XCTAssertEqual(p.blacklist, ["X"])
        XCTAssertNil(p.whitelist)
    }
}
