import AppKit
import XCTest
@testable import MetaWhisp

/// PRD P1 15 — "Move MetaWhisp to Applications?" when the owner's build runs from anywhere else (the disk image,
/// Downloads, a translocated copy), with "Move and Open" and "Not now"; a move that fails is explained in one plain
/// line. The move comes first at launch, before anything asks for a permission, so the grants go to the copy that
/// stays. Files in a folder of the test's own; nothing is opened, quit or installed.
@MainActor
final class ApplicationsMoveTests: XCTestCase {
    private var temp: URL!
    private let home = URL(fileURLWithPath: "/Users/sam", isDirectory: true)
    private let production = AppIdentity(bundleIdentifier: "com.metawhisp.app")

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("mw-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.appendingPathComponent("Applications").path)
        try? FileManager.default.removeItem(at: temp)
    }

    private func offers(_ path: String, identity: AppIdentity? = nil, anotherCopyRuns: Bool = false,
                        declined: String? = nil) -> Bool {
        ApplicationsMove.shouldOffer(bundle: URL(fileURLWithPath: path, isDirectory: true), identity: identity ?? production,
                                     home: home, anotherCopyRuns: anotherCopyRuns, declined: declined)
    }

    private func location(_ path: String) -> String {
        ApplicationsMove.location(of: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// A bundle of the test's own: `marker` in its Resources, the given extended attribute on its executable.
    private func makeApp(at url: URL, marker: String, quarantined: Bool = false) throws {
        let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true)
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: resources.appendingPathComponent("marker"))
        let executable = macOS.appendingPathComponent("MetaWhisp")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        if quarantined {
            let value = Data("0083;00000000;Safari;".utf8)
            let status = value.withUnsafeBytes { setxattr(executable.path, "com.apple.quarantine", $0.baseAddress, value.count, 0, 0) }
            XCTAssertEqual(status, 0, "the test's quarantine was set")
        }
    }

    private func marker(in app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8)
    }

    private func isQuarantined(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    /// …/Tests/MetaWhispTests/Services/System/ApplicationsMoveTests.swift → the repository's root.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// A source file's lines with line comments stripped: only code counts.
    private func codeLines(of path: String) throws -> [String] {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8).components(separatedBy: "\n")
            .map { raw in raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw }
    }

    private func delegateCode() throws -> [String] {
        try codeLines(of: "App/AppDelegate.swift")
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

    /// `/bin/sh` with `arguments`, run to its end: what it printed, and what it said on its error output.
    private func shell(_ arguments: [String]) throws -> (output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: printed, as: UTF8.self), String(decoding: said, as: UTF8.self))
    }

    // MARK: - When it asks

    /// Outside Applications — the disk image, Downloads, a translocated copy — it asks.
    func testItAsksFromAnywhereButApplications() {
        XCTAssertTrue(offers("/Volumes/Install Disk/MetaWhisp.app"), "the disk image")
        XCTAssertTrue(offers("/Users/sam/Downloads/MetaWhisp.app"), "Downloads")
        XCTAssertTrue(offers("/private/var/folders/xy/abc/T/AppTranslocation/1234/d/MetaWhisp.app"), "translocated")
    }

    /// The gate: in Applications — the Mac's or the user's, a subfolder included — it never asks.
    func testInApplicationsItDoesNotAsk() {
        XCTAssertFalse(offers("/Applications/MetaWhisp.app"))
        XCTAssertFalse(offers("/Applications/Utilities/MetaWhisp.app"))
        XCTAssertFalse(offers("/Users/sam/Applications/MetaWhisp.app"))
        XCTAssertTrue(offers("/Applications Old/MetaWhisp.app"), "a folder merely named like it is elsewhere")
    }

    /// A Dev build never asks, and neither does a copy that finds another MetaWhisp already running — replacing the
    /// bundle under a running app is not this question's to do.
    func testADevBuildOrASecondRunningCopyDoesNotAsk() {
        XCTAssertFalse(offers("/Users/sam/Downloads/MetaWhisp.app", identity: AppIdentity(bundleIdentifier: "com.metawhisp.app.dev")))
        XCTAssertFalse(offers("/Users/sam/Downloads/MetaWhisp.app", anotherCopyRuns: true))
    }

    // MARK: - Not now

    /// "Not now" is remembered for this copy's location: launched from there again, it does not ask again.
    func testNotNowIsRememberedForThisCopysLocation() {
        for path in ["/Volumes/Install Disk/MetaWhisp.app", "/Users/sam/Downloads/MetaWhisp.app"] {
            XCTAssertFalse(offers(path, declined: location(path)), path)
        }
    }

    /// The paired case: run from a different location outside Applications, it asks again.
    func testADifferentLocationOutsideApplicationsAsksAgain() {
        XCTAssertTrue(offers("/Users/sam/Downloads/MetaWhisp.app", declined: location("/Volumes/Install Disk/MetaWhisp.app")))
        XCTAssertTrue(offers("/Users/sam/Desktop/MetaWhisp.app", declined: location("/Users/sam/Downloads/MetaWhisp.app")))
    }

    /// macOS runs a quarantined copy from a new random folder at every launch: those launches are one location, or
    /// "Not now" would be asked again each time.
    func testATranslocatedCopyIsOneLocationWhateverItsRandomPath() {
        let first = "/private/var/folders/xy/abc/T/AppTranslocation/1111/d/MetaWhisp.app"
        let next = "/private/var/folders/xy/abc/T/AppTranslocation/2222/d/MetaWhisp.app"
        XCTAssertEqual(location(first), location(next))
        XCTAssertFalse(offers(next, declined: location(first)))
        XCTAssertTrue(offers("/Users/sam/Downloads/MetaWhisp.app", declined: location(first)), "a copy run as it is")
    }

    /// What "Not now" keeps: this copy's location, in the app's defaults, read at the next launch.
    func testNotNowKeepsTheLocationForTheNextLaunch() throws {
        let suite = "mw-move-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let downloads = URL(fileURLWithPath: "/Users/sam/Downloads/MetaWhisp.app", isDirectory: true)
        XCTAssertNil(ApplicationsMove.declinedLocation(in: defaults))
        ApplicationsMove.rememberNotNow(for: downloads, in: defaults)
        XCTAssertEqual(ApplicationsMove.declinedLocation(in: try XCTUnwrap(UserDefaults(suiteName: suite))),
                       location(downloads.path))
    }

    /// The launch passes what was declined to the decision, and "Not now" remembers it. Read from the source: the
    /// launch's question has no harness here.
    func testTheLaunchAsksWithWhatWasDeclinedAndRemembersNotNow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent("Services/System/ApplicationsMove.swift"),
                              encoding: .utf8).components(separatedBy: "\n")
        let launch = try XCTUnwrap(code.firstIndex { $0.contains("static func offerAtLaunch(") })
        let body = code[launch...].prefix { !$0.hasPrefix("    }") }
        XCTAssertTrue(body.contains { $0.contains("declined: declinedLocation(in: .standard)") })
        let notNow = try XCTUnwrap(body.firstIndex { $0.contains("Not now — this launch stays") })
        XCTAssertTrue(code[(notNow - 1)...(notNow + 1)].contains { $0.contains("rememberNotNow(for: bundle, in: .standard)") })
    }

    // MARK: - The move

    /// Move: a copy lands in Applications as MetaWhisp.app — the original is left where it was — and it carries no
    /// quarantine, so macOS opens it from there instead of a translocated copy.
    func testTheMoveCopiesTheAppIntoApplicationsWithoutQuarantine() throws {
        let source = temp.appendingPathComponent("Volume/MetaWhisp.app", isDirectory: true)
        try makeApp(at: source, marker: "new", quarantined: true)
        let applications = temp.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)

        let moved = try ApplicationsMove.move(source, into: applications)

        XCTAssertEqual(moved, applications.appendingPathComponent("MetaWhisp.app"))
        XCTAssertEqual(marker(in: moved), "new")
        XCTAssertFalse(isQuarantined(moved.appendingPathComponent("Contents/MacOS/MetaWhisp").path))
        XCTAssertEqual(marker(in: source), "new", "the original stays")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["MetaWhisp.app"],
                       "nothing left behind")
    }

    /// An older MetaWhisp in Applications is replaced by this one.
    func testTheMoveReplacesTheCopyInApplications() throws {
        let source = temp.appendingPathComponent("Downloads/MetaWhisp.app", isDirectory: true)
        try makeApp(at: source, marker: "new")
        let applications = temp.appendingPathComponent("Applications", isDirectory: true)
        try makeApp(at: applications.appendingPathComponent("MetaWhisp.app"), marker: "old")

        let moved = try ApplicationsMove.move(source, into: applications)

        XCTAssertEqual(marker(in: moved), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["MetaWhisp.app"])
    }

    /// A move that fails — Applications can't be written — throws, leaves the copy there untouched and nothing
    /// half-made beside it.
    func testAFailedMoveLeavesApplicationsAsItWas() throws {
        let source = temp.appendingPathComponent("Downloads/MetaWhisp.app", isDirectory: true)
        try makeApp(at: source, marker: "new")
        let applications = temp.appendingPathComponent("Applications", isDirectory: true)
        try makeApp(at: applications.appendingPathComponent("MetaWhisp.app"), marker: "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications.path)

        XCTAssertThrowsError(try ApplicationsMove.move(source, into: applications))

        XCTAssertEqual(marker(in: applications.appendingPathComponent("MetaWhisp.app")), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["MetaWhisp.app"])
    }

    /// The moved copy opens once this one has quit: the process id and the path go to the shell as its positional
    /// arguments, never into its script. `sh -c SCRIPT A B` binds A to `$0` — the shell's own name — and B to `$1`,
    /// so the binding is read back from a real shell: the script swapped for one that prints `$1` and `$2`, the
    /// arguments exactly as the move hands them.
    func testTheShellGetsTheProcessIdAsOneAndThePathAsTwo() throws {
        let path = "/Applications/Meta Whisp's \"copy\".app"     // spaces and quotes: still one argument
        var arguments = ApplicationsMove.reopenArguments(pid: 4242, app: URL(fileURLWithPath: path))
        XCTAssertEqual(arguments.first, "-c")
        let script = try XCTUnwrap(arguments.dropFirst().first)
        XCTAssertTrue(script.contains(#"/bin/kill -0 "$1""#), "waits while $1 lives")
        XCTAssertTrue(script.contains(#"/usr/bin/open "$2""#), "then opens $2")
        XCTAssertFalse(script.contains("4242") || script.contains("Whisp's"), "nothing interpolated")
        arguments[1] = #"printf '%s\n%s\n' "$1" "$2""#
        XCTAssertEqual(try shell(arguments).output, "4242\n\(path)\n")
    }

    /// End to end with the real script, harmlessly: it waits while the process with that id lives — one that launchd
    /// reaps, as it reaps this app — and then hands the path to `open`: a path where nothing is, so `open` only says so.
    func testTheReopenWaitsWhileTheProcessLivesThenOpensThePath() throws {
        let stillRunning = try shell(["-c", "/bin/sleep 0.8 >/dev/null 2>&1 & echo $!"]).output
        let pid = try XCTUnwrap(Int32(stillRunning.trimmingCharacters(in: .whitespacesAndNewlines)))
        let nowhere = temp.appendingPathComponent("Nowhere/MetaWhisp.app")
        let started = Date()
        let reopen = try shell(ApplicationsMove.reopenArguments(pid: pid, app: nowhere))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.5, "it waited while the process lived")
        XCTAssertTrue(reopen.errors.contains(nowhere.path), "open was handed the path: \(reopen.errors)")
    }

    // MARK: - A launch opened by a link (Codex, 1.4.0 review)

    /// A sign-in link that opens the app is delivered while it launches. Its handler is registered as the launch begins
    /// (applicationWillFinishLaunching), so the link is held, not lost; the move question, which can end the launch,
    /// comes after — and is put off for a launch a link opened; the links are handed on only after the question and
    /// once the keychain is ready, where the handler used to be registered. Read from the source: the launch has no
    /// harness here.
    func testTheLinkHandlerComesBeforeTheMoveQuestionAndLinksAfterIt() throws {
        let code = try delegateCode()
        let willFinish = body(of: "func applicationWillFinishLaunching(", in: code)
        XCTAssertTrue(willFinish.contains { $0.contains("andEventID: AEEventID(kAEGetURL)") },
                      "the handler is registered as the launch begins")
        XCTAssertEqual(code.filter { $0.contains("andEventID: AEEventID(kAEGetURL)") }.count, 1, "and only there")
        let move = try XCTUnwrap(code.firstIndex { $0.contains("if ApplicationsMove.offerAtLaunch(openedByLink:") })
        XCTAssertTrue(code[move].contains("linkInbox.openedByLink"), "the question knows whether a link opened the launch")
        let migrate = try XCTUnwrap(code.firstIndex { $0.contains("KeychainHelper.migrateLegacySecretsIfNeeded()") })
        let delivered = try XCTUnwrap(code.firstIndex { $0.contains("linkInbox.open {") })
        let coordinator = try XCTUnwrap(code.firstIndex { $0.contains("coordinator = TranscriptionCoordinator(") })
        XCTAssertLessThan(move, delivered, "links are handed on after the question")
        XCTAssertLessThan(migrate, delivered, "and after the keychain is ready")
        XCTAssertLessThan(delivered, coordinator, "where the handler used to be registered")
        let handler = body(of: "private func handleURLEvent(", in: code)
        XCTAssertTrue(handler.contains { $0.contains("linkInbox.receive(") }, "every link goes to the inbox")
        XCTAssertFalse(handler.contains { $0.contains("SignInLink(") }, "and is handled only once handed on")
    }

    /// A launch a link opened is not asked: "Move and Open" ends the launch, and the link with it. The question comes
    /// at a later launch — the brother: the same copy, launched without a link, is asked as before.
    func testALaunchOpenedByALinkIsAskedAtALaterLaunch() {
        XCTAssertFalse(ApplicationsMove.shouldOffer(bundle: URL(fileURLWithPath: "/Users/sam/Downloads/MetaWhisp.app"),
                                                    identity: production, home: home, anotherCopyRuns: false,
                                                    openedByLink: true))
        XCTAssertTrue(ApplicationsMove.shouldOffer(bundle: URL(fileURLWithPath: "/Users/sam/Downloads/MetaWhisp.app"),
                                                   identity: production, home: home, anotherCopyRuns: false,
                                                   openedByLink: false))
    }

    /// Putting the question off is no "Not now": nothing is remembered, so the next launch from there asks. And a
    /// link that comes while the question is up keeps this launch too: the move is checked against it after the
    /// answer. Read from the source.
    func testAPutOffQuestionRemembersNothingAndALinkDuringTheQuestionKeepsTheLaunch() throws {
        let code = try codeLines(of: "Services/System/ApplicationsMove.swift")
        let launch = body(of: "static func offerAtLaunch(", in: code)
        XCTAssertEqual(launch.filter { $0.contains("rememberNotNow(") }.count, 1, "only Not now remembers")
        let asked = try XCTUnwrap(launch.firstIndex { $0.contains("CurrentSpaceAlert.ask(questionAlert())") })
        let recheck = try XCTUnwrap(launch.lastIndex { $0.contains("openedByLink()") })
        let moved = try XCTUnwrap(launch.firstIndex { $0.contains("try move(bundle, into: applications)") })
        XCTAssertTrue(asked < recheck && recheck < moved, "a link during the question is checked before the move")
    }

    // MARK: - What it says

    /// The question and the failure, in the mockup's words; "Not now" answers Escape too. Both on the Space the user
    /// is on.
    func testTheQuestionAndTheFailureInPlainWords() {
        let question = ApplicationsMove.questionAlert()
        XCTAssertEqual(question.messageText, "Move MetaWhisp to Applications?")
        XCTAssertEqual(question.buttons.map(\.title), ["Move and Open", "Not now"])
        XCTAssertEqual(question.buttons.last?.keyEquivalent, "\u{1b}", "Escape is Not now")
        XCTAssertEqual(question.window.collectionBehavior, MWWindowBehavior.main)
        let failure = ApplicationsMove.failureAlert()
        XCTAssertEqual(failure.messageText, "Couldn't move MetaWhisp. Drag it to Applications in Finder.")
        XCTAssertEqual(failure.buttons.map(\.title), ["OK"])
        XCTAssertEqual(failure.window.collectionBehavior, MWWindowBehavior.main)
    }

    /// The question comes first at launch — before the window, the services and any permission — and a move ends
    /// this launch. Read from the source: the launch has no test harness here.
    func testTheQuestionComesFirstAtLaunch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent("App/AppDelegate.swift"), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { raw in raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw }
        let launch = try XCTUnwrap(code.firstIndex { $0.contains("func applicationDidFinishLaunching(") })
        let move = try XCTUnwrap(code.firstIndex { $0.contains("if ApplicationsMove.offerAtLaunch(openedByLink:") })
        let coordinator = try XCTUnwrap(code.firstIndex { $0.contains("coordinator = TranscriptionCoordinator(") })
        let services = try XCTUnwrap(code.firstIndex { $0.contains("await setupServices()") })
        XCTAssertLessThan(launch, move)
        XCTAssertLessThan(move, coordinator, "before the coordinator")
        XCTAssertLessThan(move, services, "before the services and the onboarding")
    }
}
