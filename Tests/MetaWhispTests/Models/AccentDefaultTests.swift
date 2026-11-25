import XCTest
@testable import MetaWhisp

/// ITER-087, owner 2026-11-25: a new user gets the Mint accent (it was Mono, which turned the new look's glow, switches
/// and selection white or black); a user who chose an accent keeps it. The accent stays a choice in Settings.
@MainActor
final class AccentDefaultTests: XCTestCase {
    private let key = "accentColor"
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: key)
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    func testANewUserGetsMint() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(AppSettings.shared.accentColor, "mint")
    }

    // MARK: - An existing user keeps the Mono they were on (independent review, P1)

    /// `@AppStorage` never writes its default: a user who finished onboarding before this build and never chose an
    /// accent has no key, and would move from Mono to Mint. Once, at the first launch of this build, their key is
    /// written as Mono.
    func testAnOnboardedUserWhoNeverChoseKeepsMono() throws {
        let defaults = try fresh()
        defaults.set(true, forKey: "hasCompletedOnboarding")
        AppSettings.keepExistingUsersAccent(in: defaults)
        XCTAssertEqual(defaults.string(forKey: key), "mono")
    }

    func testAFreshInstallIsLeftUnsetAndGetsMint() throws {
        let defaults = try fresh()
        AppSettings.keepExistingUsersAccent(in: defaults)
        XCTAssertNil(defaults.object(forKey: key), "a new user reads the default, Mint")
    }

    func testAnExistingChoiceIsNotTouched() throws {
        let defaults = try fresh()
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set("warmOrange", forKey: key)
        AppSettings.keepExistingUsersAccent(in: defaults)
        XCTAssertEqual(defaults.string(forKey: key), "warmOrange")
    }

    /// The migration runs once: a user who later clears the key on purpose (or a reset) is not pinned to Mono again.
    func testItRunsOnceAndNeverAgain() throws {
        let defaults = try fresh()
        AppSettings.keepExistingUsersAccent(in: defaults)
        defaults.set(true, forKey: "hasCompletedOnboarding")
        AppSettings.keepExistingUsersAccent(in: defaults)
        XCTAssertNil(defaults.object(forKey: key), "the first launch of this build decided; later launches do not")
    }

    /// The app runs it at launch, before any window reads the accent.
    func testTheAppRunsItAtLaunch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("AppSettings.keepExistingUsersAccent()"))
    }

    private func fresh() throws -> UserDefaults {
        let name = "AccentDefaultTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testAChosenAccentIsKept() {
        UserDefaults.standard.set("warmOrange", forKey: key)
        XCTAssertEqual(AppSettings.shared.accentColor, "warmOrange")
        UserDefaults.standard.set("mono", forKey: key)
        XCTAssertEqual(AppSettings.shared.accentColor, "mono", "Mono chosen on purpose stays Mono")
    }
}
