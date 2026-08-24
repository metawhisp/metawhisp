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

    /// ITER-064A.2 — REVERSED from the original AUD-021 decision.
    ///
    /// This used to resolve to `nil` ("no restriction") on the reasoning that an
    /// empty allowlist should not silently disable the feature. The practical
    /// effect was the opposite of what the setting promises: a user who picked
    /// "only these apps" and had not yet added one was having *every* app
    /// captured. Choosing whitelist mode is an expressed intent to restrict, so
    /// an empty list now allows nothing.
    func test_whitelistMode_emptyList_failsClosed() {
        let p = ScreenContextPolicy.resolve(mode: "whitelist", appList: "   ")
        XCTAssertEqual(p.whitelist, [], "whitelist mode must stay active, with nothing allowed")
        XCTAssertTrue(p.blacklist.isEmpty)
        XCTAssertFalse(ScreenContextPolicy.isCaptureAllowed(
            appName: "Safari", bundleID: "com.apple.Safari",
            blacklist: p.blacklist, whitelist: p.whitelist))
    }

    // MARK: - isCaptureAllowed

    func test_isCaptureAllowed_blacklistBlocksByBundleIDOrName() {
        XCTAssertFalse(ScreenContextPolicy.isCaptureAllowed(
            appName: "1Password", bundleID: "com.agilebits.onepassword",
            blacklist: ["1Password"], whitelist: nil))
        XCTAssertFalse(ScreenContextPolicy.isCaptureAllowed(
            appName: "1Password", bundleID: "com.agilebits.onepassword",
            blacklist: ["com.agilebits.onepassword"], whitelist: nil))
    }

    /// `nil` whitelist means blacklist mode — anything not excluded is allowed.
    func test_isCaptureAllowed_nilWhitelistAllowsUnlistedApp() {
        XCTAssertTrue(ScreenContextPolicy.isCaptureAllowed(
            appName: "Safari", bundleID: "com.apple.Safari",
            blacklist: ["1Password"], whitelist: nil))
    }

    func test_isCaptureAllowed_whitelistAdmitsOnlyListedApps() {
        let allow: Set<String> = ["Xcode"]
        XCTAssertTrue(ScreenContextPolicy.isCaptureAllowed(
            appName: "Xcode", bundleID: "com.apple.dt.Xcode",
            blacklist: [], whitelist: allow))
        XCTAssertFalse(ScreenContextPolicy.isCaptureAllowed(
            appName: "Safari", bundleID: "com.apple.Safari",
            blacklist: [], whitelist: allow))
    }

    /// The blacklist wins even when the same app is also whitelisted.
    func test_isCaptureAllowed_blacklistBeatsWhitelist() {
        XCTAssertFalse(ScreenContextPolicy.isCaptureAllowed(
            appName: "Terminal", bundleID: "com.apple.Terminal",
            blacklist: ["Terminal"], whitelist: ["Terminal"]))
    }

    // MARK: - effective(...)

    /// ITER-064A.5 — the capture loop used to be handed a policy once, at start,
    /// and hold it for the life of the monitor task. Switching Settings to
    /// allowlist mode then left the running loop on the old `nil` whitelist,
    /// capturing everything until relaunch — the same fail-open one layer up.
    /// The loop now asks for the effective policy on every tick, so these pin
    /// what "effective" means.
    func test_effective_mergesTheAlwaysExcludedApps() {
        let p = ScreenContextPolicy.effective(
            alwaysExcluded: ["com.apple.Passwords"],
            mode: "blacklist",
            appList: "Telegram"
        )
        XCTAssertTrue(p.blacklist.contains("com.apple.Passwords"))
        XCTAssertTrue(p.blacklist.contains("Telegram"))
        XCTAssertNil(p.whitelist)
    }

    /// The always-excluded apps survive allowlist mode, where the parsed
    /// blacklist is empty.
    func test_effective_alwaysExcludedSurvivesAllowlistMode() {
        let p = ScreenContextPolicy.effective(
            alwaysExcluded: ["com.apple.Passwords"],
            mode: "whitelist",
            appList: "Xcode"
        )
        XCTAssertEqual(p.whitelist, ["Xcode"])
        XCTAssertTrue(p.blacklist.contains("com.apple.Passwords"))
        XCTAssertFalse(ScreenContextPolicy.isCaptureAllowed(
            appName: "Passwords", bundleID: "com.apple.Passwords",
            blacklist: p.blacklist, whitelist: p.whitelist),
            "a password manager stays excluded even if the user allowlists it")
    }

    func test_effective_emptyAllowlistStillFailsClosed() {
        let p = ScreenContextPolicy.effective(
            alwaysExcluded: [], mode: "whitelist", appList: ""
        )
        XCTAssertEqual(p.whitelist, [])
        XCTAssertFalse(ScreenContextPolicy.isCaptureAllowed(
            appName: "Safari", bundleID: "com.apple.Safari",
            blacklist: p.blacklist, whitelist: p.whitelist))
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
