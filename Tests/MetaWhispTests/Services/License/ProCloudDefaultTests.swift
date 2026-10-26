import XCTest
@testable import MetaWhisp

/// A1 (owner, 2026-10-25) — a Pro user keeps their engine choice. Cloud is the engine Pro starts on, set once: at the
/// first Pro activation on this Mac. A launch, a restored session, a verification and a later sign-in never set it
/// again, so a Pro user who picks on-device keeps it through a relaunch, a sign-out and sign-in, and an update. The
/// flag lives in this Mac's defaults: a second Mac gets cloud at its own first activation. The app's settings, put
/// back after each test.
@MainActor
final class ProCloudDefaultTests: XCTestCase {
    private var savedEngine: Any?
    private var savedApplied = false
    private var savedChecked: Any?

    override func setUp() {
        let settings = AppSettings.shared
        let defaults = UserDefaults.standard
        savedEngine = defaults.object(forKey: ProCloudDefault.engineKey)
        savedApplied = settings.proCloudDefaultApplied
        savedChecked = defaults.object(forKey: ProCloudDefault.legacyCheckedKey)
        settings.transcriptionEngine = "ondevice"
        settings.proCloudDefaultApplied = false
        defaults.removeObject(forKey: ProCloudDefault.legacyCheckedKey)   // this build has not launched here yet
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for (key, value) in [(ProCloudDefault.engineKey, savedEngine), (ProCloudDefault.legacyCheckedKey, savedChecked)] {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        AppSettings.shared.proCloudDefaultApplied = savedApplied
    }

    private var engine: String { AppSettings.shared.transcriptionEngine }

    // MARK: - The first activation

    /// A new buyer's first activation on this Mac turns cloud on, once.
    func testANewBuyersFirstActivationSetsCloud() {
        ProCloudDefault.activated()
        XCTAssertEqual(engine, "cloud")
        XCTAssertTrue(AppSettings.shared.proCloudDefaultApplied, "remembered on this Mac")
    }

    /// The gate: a Pro user who then picks on-device keeps it — a sign-out and sign-in is another activation, and it
    /// leaves the choice alone.
    func testALaterActivationDoesNotFireOverThePick() {
        ProCloudDefault.activated()
        AppSettings.shared.transcriptionEngine = "ondevice"      // the user's pick in Settings
        ProCloudDefault.activated()                                // signed out, signed in again
        XCTAssertEqual(engine, "ondevice")
    }

    /// Its release: the flag lives in this Mac's own defaults, so a second Mac — no flag in its defaults yet — gets
    /// cloud at its own first activation, whatever this Mac's user picked.
    func testASecondMacFiresAnywayAtItsOwnFirstActivation() {
        ProCloudDefault.activated()
        AppSettings.shared.transcriptionEngine = "ondevice"      // this Mac's user picked on-device
        XCTAssertTrue(UserDefaults.standard.bool(forKey: ProCloudDefault.key), "kept in this Mac's own defaults")
        AppSettings.shared.proCloudDefaultApplied = false        // the second Mac's defaults: no flag
        ProCloudDefault.activated()
        XCTAssertEqual(engine, "cloud", "its own first activation")
    }

    // MARK: - Pro found on, not turned on

    /// A launch that restores a Pro session, or a verification that confirms it, is no activation: Pro was activated
    /// on this Mac before. The choice stays — on-device here — and is never set again by a later sign-in (the update
    /// from 1.3.x: those builds set cloud at that earlier activation).
    func testARestoreOrAVerificationNeverChangesTheChoice() {
        ProCloudDefault.confirmed()
        XCTAssertEqual(engine, "ondevice", "a launch or a verification")
        XCTAssertTrue(AppSettings.shared.proCloudDefaultApplied, "Pro was activated here before")
        ProCloudDefault.activated()                                // signed out, signed in again
        XCTAssertEqual(engine, "ondevice")
    }

    /// A Pro user already on cloud stays on cloud after the update.
    func testAProUserOnCloudStaysOnCloud() {
        AppSettings.shared.transcriptionEngine = "cloud"
        ProCloudDefault.confirmed()
        ProCloudDefault.activated()
        XCTAssertEqual(engine, "cloud")
    }

    // MARK: - An update while signed out (Codex P1, 1.4.0 review)

    /// A Pro user on 1.3.x picked on-device, signed out, then updated: no session to restore, so nothing confirmed an
    /// earlier activation and the flag was never set — their next sign-in set cloud over the pick. The first launch of
    /// this build records an engine stored as on-device as the user's own choice, whatever the licence says now; a
    /// sign-in after it keeps it.
    func testAnOnDevicePickKeptThroughASignedOutUpdateSurvivesTheNextSignIn() {
        ProCloudDefault.launched(proRestored: false)          // the update's first launch, signed out
        ProCloudDefault.activated()                           // then the sign-in
        XCTAssertEqual(engine, "ondevice", "the pick stays")
        XCTAssertTrue(AppSettings.shared.proCloudDefaultApplied)
    }

    /// The brother: a brand-new Mac stores no engine, so the launch records nothing and its first activation still
    /// sets cloud, once.
    func testABrandNewMacsFirstActivationStillSetsCloudOnce() {
        UserDefaults.standard.removeObject(forKey: ProCloudDefault.engineKey)   // nothing stored: a new install
        ProCloudDefault.launched(proRestored: false)
        XCTAssertFalse(AppSettings.shared.proCloudDefaultApplied, "nothing to record")
        ProCloudDefault.activated()
        XCTAssertEqual(engine, "cloud")
        AppSettings.shared.transcriptionEngine = "ondevice"
        ProCloudDefault.activated()
        XCTAssertEqual(engine, "ondevice", "once")
    }

    /// The check's ceiling: it runs at this build's first launch only. A new install whose user then taps on-device
    /// before ever buying — stored at a later launch — still gets cloud at its first activation, as A1 says.
    func testTheCheckRunsAtThisBuildsFirstLaunchOnly() {
        UserDefaults.standard.removeObject(forKey: ProCloudDefault.engineKey)
        ProCloudDefault.launched(proRestored: false)          // the first launch: nothing stored
        AppSettings.shared.transcriptionEngine = "ondevice"   // a tap in Settings, later
        ProCloudDefault.launched(proRestored: false)          // a later launch
        ProCloudDefault.activated()
        XCTAssertEqual(engine, "cloud")
    }

    /// An engine stored as cloud is not a pick of on-device: the first activation goes through the default (cloud,
    /// which it already is).
    func testAStoredCloudIsNoOnDevicePick() {
        AppSettings.shared.transcriptionEngine = "cloud"
        ProCloudDefault.launched(proRestored: false)
        XCTAssertFalse(AppSettings.shared.proCloudDefaultApplied)
        ProCloudDefault.activated()
        XCTAssertEqual(engine, "cloud")
    }

    /// The key the check reads is the one the settings store the engine under.
    func testTheCheckReadsTheEnginesOwnKey() {
        AppSettings.shared.transcriptionEngine = "cloud"
        XCTAssertEqual(UserDefaults.standard.string(forKey: ProCloudDefault.engineKey), "cloud")
    }

    // MARK: - Who writes the engine

    /// The launch writes no engine: neither the app's launch nor the licence's restore and verification may set it.
    /// A Free user with their own key — never activated — is never touched; only an activation goes through the
    /// default, and only the user's pick in Settings writes the engine besides it.
    func testOnlyTheFirstActivationWritesTheEngineAutomatically() throws {
        let assignment = try NSRegularExpression(pattern: #"\btranscriptionEngine\s*=[^=]"#)
        for path in ["App/AppDelegate.swift", "Services/License/LicenseService.swift"] {
            for (number, line) in try codeLines(of: path).enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                XCTAssertNil(assignment.firstMatch(in: line, range: range), "\(path):\(number + 1) writes the engine")
            }
        }
        let license = try codeLines(of: "Services/License/LicenseService.swift")
        let activated = license.indices.filter { license[$0].contains("ProCloudDefault.activated(") }
        XCTAssertEqual(activated.count, 1, "one activation")
        XCTAssertTrue(body(of: "func activate(token: String)", in: license).contains { $0.contains("ProCloudDefault.activated(") },
                      "the sign-in is the activation")
        for (function, call) in [("private init()", "ProCloudDefault.launched("),
                                 ("private func verify(token: String)", "ProCloudDefault.confirmed(")] {
            let lines = body(of: function, in: license)
            XCTAssertFalse(lines.isEmpty, "\(function) not found — update the guard")
            XCTAssertTrue(lines.contains { $0.contains(call) }, "\(function) confirms, never activates")
        }
    }

    // MARK: - Helpers

    /// …/Tests/MetaWhispTests/Services/License/ProCloudDefaultTests.swift → the repository's root.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// A source file's lines with line comments stripped: only code counts.
    private func codeLines(of path: String) throws -> [String] {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8).components(separatedBy: "\n")
            .map { raw in raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw }
    }

    /// A declaration's lines, from the one that declares it to the brace that closes it; braces in strings don't
    /// count.
    private func body(of declaration: String, in lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { $0.contains(declaration) }) else { return [] }
        var depth = 0
        var opened = false
        var out: [String] = []
        for line in lines[start...] {
            out.append(line)
            var inString = false
            var escaped = false
            for character in line {
                if inString {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                    opened = true
                } else if character == "}" {
                    depth -= 1
                }
            }
            if opened, depth == 0 { break }
        }
        return out
    }
}
