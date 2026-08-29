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
    // MARK: - Assistant windows (Stage 2.1-ter)

    /// 24 of 62 cards and 1853 of 7157 captures in the last week came from
    /// windows belonging to another AI assistant, so the agent has been reading
    /// a model's output and handing it back as an observation about the user's
    /// work. Ambient capture skips those windows.
    func test_ambient_skipsAnotherAssistantsWindow() {
        for (name, bundle) in [("Claude", "com.anthropic.claudefordesktop"),
                               ("ChatGPT", "com.openai.codex"),
                               ("Kimi", "com.moonshot.kimichat")] {
            XCTAssertFalse(ScreenContextPolicy.isAmbientCaptureAllowed(
                appName: name, bundleID: bundle,
                blacklist: [], whitelist: nil,
                defaultExcluded: ScreenContextPolicy.assistantWindows),
                "\(name) is another assistant's output, not the user's work")
        }
    }

    /// Reading our own window is the same loop with one fewer step in it.
    func test_ambient_skipsOurOwnWindow() {
        XCTAssertFalse(ScreenContextPolicy.isAmbientCaptureAllowed(
            appName: "MetaWhisp", bundleID: "com.metawhisp.app",
            blacklist: [], whitelist: nil,
            defaultExcluded: ScreenContextPolicy.assistantWindows))
    }

    /// The rule is about whose text is on the screen, not about the word "AI".
    /// A browser is where the user works, including AI-flavoured ones.
    func test_ambient_doesNotSkipABrowser() {
        for (name, bundle) in [("Safari", "com.apple.Safari"),
                               ("Dia", "company.thebrowser.dia"),
                               ("Telegram", "ru.keepcoder.Telegram")] {
            XCTAssertTrue(ScreenContextPolicy.isAmbientCaptureAllowed(
                appName: name, bundleID: bundle,
                blacklist: [], whitelist: nil,
                defaultExcluded: ScreenContextPolicy.assistantWindows),
                "\(name) is where the user works")
        }
    }

    /// Naming an app in allowlist mode is an expressed intent, and it beats a
    /// default we chose for them. Matching by display name has to work too:
    /// the Settings field holds whatever the user typed.
    func test_ambient_anExplicitlyAllowlistedAssistantIsWatched() {
        for typed in ["Claude", "com.anthropic.claudefordesktop"] {
            XCTAssertTrue(ScreenContextPolicy.isAmbientCaptureAllowed(
                appName: "Claude", bundleID: "com.anthropic.claudefordesktop",
                blacklist: [], whitelist: [typed],
                defaultExcluded: ScreenContextPolicy.assistantWindows),
                "the user asked for this one by typing \(typed)")
        }
    }

    /// The default must not be able to rescue an app the user excluded, and the
    /// password list must not be weakened by the new rule sitting next to it.
    func test_ambient_userExclusionAndPasswordListStillWin() {
        XCTAssertFalse(ScreenContextPolicy.isAmbientCaptureAllowed(
            appName: "Xcode", bundleID: "com.apple.dt.Xcode",
            blacklist: ["Xcode"], whitelist: nil,
            defaultExcluded: ScreenContextPolicy.assistantWindows))
        XCTAssertFalse(ScreenContextPolicy.isAmbientCaptureAllowed(
            appName: "Passwords", bundleID: "com.apple.Passwords",
            blacklist: ["com.apple.Passwords"], whitelist: ["com.apple.Passwords"],
            defaultExcluded: ScreenContextPolicy.assistantWindows))
    }

    /// With no default set the ambient rule must be exactly the plain one —
    /// this is what the on-demand voice path passes.
    func test_ambient_withNoDefaultsMatchesThePlainRule() {
        XCTAssertTrue(ScreenContextPolicy.isAmbientCaptureAllowed(
            appName: "Claude", bundleID: "com.anthropic.claudefordesktop",
            blacklist: [], whitelist: nil, defaultExcluded: []),
            "asking out loud what is on screen is not ambient capture")
    }
}
