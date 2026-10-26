import XCTest
@testable import MetaWhisp

/// ITER-076 0.1 — a test build replaces the working app, and a swap never leaves
/// it broken. The scripts run here against fake `security`, `codesign`, `open`
/// and `swift` tools and temp folders: nothing is signed, built, installed or
/// launched for real.
final class SwapInstallScriptTests: XCTestCase {

    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Scripts/SwapInstallScriptTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var libPath: String { repoRoot.appendingPathComponent("scripts/lib/app-install.sh").path }

    private var temp: URL!
    private var fakes: URL { temp.appendingPathComponent("bin", isDirectory: true) }
    private var installDir: URL { temp.appendingPathComponent("Applications", isDirectory: true) }
    private var supportDir: URL { temp.appendingPathComponent("Support", isDirectory: true) }
    private var swapDir: URL { supportDir.appendingPathComponent(".swap", isDirectory: true) }
    private var oldCopyDir: URL { temp.appendingPathComponent("HomeApplications", isDirectory: true) }
    private var app: URL { installDir.appendingPathComponent("MetaWhisp.app", isDirectory: true) }
    private var appExecutable: String { app.appendingPathComponent("Contents/MacOS/MetaWhisp").path }
    private var current: URL { swapDir.appendingPathComponent("MetaWhisp.current", isDirectory: true) }
    private var previous: URL { swapDir.appendingPathComponent("MetaWhisp.previous", isDirectory: true) }
    private var incoming: URL { swapDir.appendingPathComponent("MetaWhisp.incoming", isDirectory: true) }
    private var lockDir: URL { swapDir.appendingPathComponent("lock", isDirectory: true) }
    private var codesignLog: URL { temp.appendingPathComponent("codesign.log") }
    private var openLog: URL { temp.appendingPathComponent("open.log") }
    private var openPids: URL { temp.appendingPathComponent("open.pids") }
    private var spawned: [Process] = []

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fakes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        try fake("security", """
            if [ "${FAKE_NO_IDENTITY:-0}" = 1 ]; then echo '     0 valid identities found'; exit 0; fi
            echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Test Maker (6D6948Z4MW)"'
            echo '     1 valid identities found'
            """)
        try fake("codesign", """
            echo "$*" >> "$FAKE_CODESIGN_LOG"
            for last in "$@"; do :; done
            case " $* " in
                *" --sign "*)
                    if [ "${FAKE_SIGN_FAILS:-0}" = 1 ]; then echo "errSecInternalComponent" >&2; exit 1; fi
                    exit 0 ;;
                *" --verify "*)
                    if [ -n "${FAKE_VERIFY_FAILS_FOR:-}" ] && [ "$last" = "$FAKE_VERIFY_FAILS_FOR" ]; then exit 1; fi
                    exit 0 ;;
                *" -r- "*)
                    dr=$(cat "$last/Contents/dr.txt" 2>/dev/null) || dr='identifier "com.metawhisp.app" and anchor apple generic and certificate leaf[subject.OU] = "6D6948Z4MW"'
                    # An ad-hoc signature has no requirement line codesign would print as one.
                    case "$dr" in "#"*) echo "$dr" ;; *) echo "designated => $dr" ;; esac
                    exit 0 ;;
                *" -dvv "*)
                    printf 'Identifier=%s\\nAuthority=Developer ID Application: Test Maker (6D6948Z4MW)\\nTeamIdentifier=6D6948Z4MW\\n' "${FAKE_IDENTIFIER:-com.metawhisp.app}" >&2
                    exit 0 ;;
            esac
            exit 0
            """)
        // The fake `open` takes `open`'s own flags before the app, as the real one does. Like the real one right after
        // the installed bundle was replaced (2026-10-20, launchservicesd: the open "resolved to" the process that had
        // just quit, error -600), with FAKE_OPEN_STALE=1 it starts nothing unless asked for a new instance (-n).
        try fake("open", """
            new=0
            while [ $# -gt 1 ]; do
                if [ "$1" = -n ]; then new=1; fi
                shift
            done
            echo "$1" >> "$FAKE_OPEN_LOG"
            if [ "${FAKE_OPEN_STALE:-0}" = 1 ] && [ "$new" = 0 ]; then
                echo "_LSOpenURLsWithCompletionHandler() failed with error -600." >&2
                exit 1
            fi
            if [ -n "${FAKE_OPEN_OTHER_LEASE_PID:-}" ]; then
                mkdir -p "$MW_APP_SUPPORT_DIR"
                printf '{"pid":%s,"state":"recording","executable":"%s","since":"2026-09-26T00:00:00Z"}' "$FAKE_OPEN_OTHER_LEASE_PID" "$FAKE_OPEN_OTHER_LEASE_EXE" > "$MW_APP_SUPPORT_DIR/activity.json"
            fi
            if [ "${FAKE_OPEN_INTERRUPTS:-0}" = 1 ]; then kill -TERM "$PPID"; exit 0; fi
            if [ "${FAKE_OPEN_STARTS:-0}" = 1 ]; then
                exe="$1/Contents/MacOS/MetaWhisp"
                if [ "${FAKE_OPEN_IGNORES_TERM:-0}" = 1 ]; then
                    bash -c 'trap "" TERM; exec -a "$0" /bin/sleep "$1"' "$exe" "${FAKE_OPEN_LIFETIME:-5}" >/dev/null 2>&1 &
                else
                    bash -c 'exec -a "$0" /bin/sleep "$1"' "$exe" "${FAKE_OPEN_LIFETIME:-5}" >/dev/null 2>&1 &
                fi
                pid=$!
                echo "$pid" >> "$FAKE_OPEN_PIDS"
                if [ "${FAKE_OPEN_WRITES_LEASE:-0}" = 1 ]; then
                    mkdir -p "$MW_APP_SUPPORT_DIR"
                    printf '{"pid":%s,"state":"%s","executable":"%s","since":"2026-09-26T00:00:00Z"}' "$pid" "${FAKE_OPEN_LEASE_STATE:-idle}" "$exe" > "$MW_APP_SUPPORT_DIR/activity.json"
                fi
                if [ "${FAKE_OPEN_INTERRUPTS_AFTER_START:-0}" = 1 ]; then sleep 0.5; kill -TERM "$PPID"; fi
            fi
            exit 0
            """)
        try fake("swift", "echo FAKE-SWIFT-RAN; exit 97")
    }

    override func tearDownWithError() throws {
        for process in spawned where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        let started = (try? String(contentsOf: openPids, encoding: .utf8)) ?? ""
        for line in started.split(separator: "\n") {
            if let pid = Int32(line) { kill(pid, SIGKILL) }
        }
        _ = try? bash("/usr/bin/chflags -R nouchg \"$1\"", [temp.path])
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - Where the lease is read

    /// The script reads the lease from the folder the working app writes it to.
    func testTheScriptReadsTheLeaseWhereTheWorkingAppWritesIt() throws {
        let home = temp.appendingPathComponent("home", isDirectory: true)
        let run = try bash("unset MW_APP_SUPPORT_DIR; HOME=\"$1\"; source '\(libPath)' && echo \"$MW_APP_SUPPORT_DIR/activity.json\"",
                           [home.path])
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let production = AppIdentity(bundleIdentifier: "com.metawhisp.app")
        XCTAssertEqual(run.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       ActivityLease.fileURL(in: production.supportDirectory(applicationSupport: appSupport)).path)
    }

    // MARK: - Busy

    func testABusyLeaseCountsOnlyWhileItsProcessRunsTheSameProgram() throws {
        let lease = ActivityLease.fileURL(in: supportDir).path
        XCTAssertEqual(try runLib("mw_lease_state \"$1\"", [lease]).output, "idle\n", "no lease")

        let running = try spawn(as: appExecutable)
        try writeLease(pid: running.processIdentifier, executable: appExecutable, state: .recording)
        XCTAssertEqual(try runLib("mw_lease_state \"$1\"", [lease]).output, "recording\n")
        try writeLease(pid: running.processIdentifier, executable: appExecutable, state: .idle)
        XCTAssertEqual(try runLib("mw_lease_state \"$1\"", [lease]).output, "idle\n")

        let other = try spawn(as: "/Applications/Other.app/Contents/MacOS/Other")
        try writeLease(pid: other.processIdentifier, executable: appExecutable, state: .transcribing)
        XCTAssertEqual(try runLib("mw_lease_state \"$1\"", [lease]).output, "idle\n",
                       "the pid now runs another program, so the lease is stale")

        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        try writeLease(pid: finished.processIdentifier, executable: appExecutable, state: .recording)
        XCTAssertEqual(try runLib("mw_lease_state \"$1\"", [lease]).output, "idle\n",
                       "the process is gone: a crash never blocks swaps")
    }

    func testASwapIsRefusedWhileTheAppRecords() throws {
        try makeBundle(at: app, marker: "old")
        let running = try spawn(as: appExecutable)
        try writeLease(pid: running.processIdentifier, executable: appExecutable, state: .recording)
        let run = try bash("bash build.sh --swap")
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("is recording right now"), run.output)
        XCTAssertFalse(run.output.contains("FAKE-SWIFT-RAN"), "refused before building")
        XCTAssertEqual(marker(in: app), "old")
        XCTAssertTrue(running.isRunning, "the recording app is left alone")
        let signing = log(codesignLog).filter { $0.contains("--sign") }
        XCTAssertEqual(signing.count, 1, "only the signing test ran")
        XCTAssertTrue(signing.allSatisfy { $0.contains("--timestamp=none") },
                      "the signing test never waits on Apple's timestamp server")
    }

    /// The build takes minutes, so the swap checks again right before it quits
    /// the app.
    func testTheSwapChecksAgainThatTheAppIsNotBusy() throws {
        try makeBundle(at: app, marker: "old")
        let running = try spawn(as: appExecutable)
        try writeLease(pid: running.processIdentifier, executable: appExecutable, state: .transcribing)
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("is transcribing right now"), run.output)
        XCTAssertEqual(marker(in: app), "old")
        XCTAssertTrue(running.isRunning)
    }

    /// A build from before the lease can't say whether it is recording, so a
    /// running copy that wrote no lease is refused until the caller confirms it
    /// is idle.
    func testARunningAppWithoutItsOwnLeaseIsRefusedUntilConfirmedIdle() throws {
        try makeBundle(at: app, marker: "old")
        let running = try spawn(as: appExecutable)
        let new = try newBundle("new")
        let refused = try runLib("mw_swap_app \"$1\"", [new.path])
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertTrue(refused.output.contains("wrote no activity lease"), refused.output)
        XCTAssertTrue(refused.output.contains("--confirm-idle"), "the message says how to go on")
        XCTAssertEqual(marker(in: app), "old")
        XCTAssertTrue(running.isRunning)

        let confirmed = try runLib("mw_swap_app \"$1\"", [new.path], env: [
            "MW_CONFIRM_IDLE": "1", "FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1"])
        XCTAssertEqual(confirmed.status, 0, confirmed.output)
        XCTAssertEqual(marker(in: app), "new")
    }

    // MARK: - Signing

    func testAFailedSigningTestStopsBeforeAnythingIsBuiltOrTouched() throws {
        try makeBundle(at: app, marker: "old")
        let running = try spawn(as: appExecutable)
        let run = try bash("bash build.sh --swap", env: ["FAKE_SIGN_FAILS": "1"])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("The signing test failed"), run.output)
        XCTAssertTrue(run.output.contains("Always Allow"), "the message says how to fix it")
        XCTAssertFalse(run.output.contains("FAKE-SWIFT-RAN"), "nothing was built")
        XCTAssertEqual(marker(in: app), "old", "nothing was touched")
        XCTAssertTrue(running.isRunning, "nothing was stopped")
    }

    func testWithoutADeveloperIDNothingIsBuiltAndNothingIsSignedAdHoc() throws {
        for args in ["", "--swap"] {
            let run = try bash("bash build.sh \(args)", env: ["FAKE_NO_IDENTITY": "1"])
            XCTAssertNotEqual(run.status, 0, args)
            XCTAssertTrue(run.output.contains("No Developer ID Application identity"), run.output)
            XCTAssertFalse(run.output.contains("FAKE-SWIFT-RAN"), "nothing was built (\(args))")
        }
        XCTAssertFalse(log(codesignLog).contains { $0.contains("--sign") }, "nothing was signed at all")
    }

    func testTheSeparateTestCopyOptionIsGone() throws {
        let run = try bash("bash build.sh --dev")
        XCTAssertEqual(run.status, 2, run.output)
        XCTAssertTrue(run.output.contains("Unknown option: --dev"), run.output)
    }

    // MARK: - What may be installed

    func testOnlyTheWorkingAppIsInstalledHere() throws {
        let other = temp.appendingPathComponent("other/MetaWhisp.app", isDirectory: true)
        try makeBundle(at: other, marker: "other", bundleID: "com.metawhisp.app.dev")
        let wrongID = try runLib("mw_swap_app \"$1\"", [other.path])
        XCTAssertNotEqual(wrongID.status, 0)
        XCTAssertTrue(wrongID.output.contains("only com.metawhisp.app"), wrongID.output)

        let renamed = temp.appendingPathComponent("renamed/MetaWhisp.app", isDirectory: true)
        try makeBundle(at: renamed, marker: "renamed", executable: "MetaWhispDev")
        let wrongExecutable = try runLib("mw_swap_app \"$1\"", [renamed.path])
        XCTAssertNotEqual(wrongExecutable.status, 0)
        XCTAssertTrue(wrongExecutable.output.contains("executable 'MetaWhispDev'"), wrongExecutable.output)

        let disguised = try newBundle("disguised")
        let signed = try runLib("mw_swap_app \"$1\"", [disguised.path],
                                env: ["FAKE_IDENTIFIER": "com.metawhisp.app.dev"])
        XCTAssertNotEqual(signed.status, 0)
        XCTAssertTrue(signed.output.contains("is signed as 'com.metawhisp.app.dev'"), signed.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path), "nothing was installed")
    }

    /// macOS keys permissions and keychain access to the designated
    /// requirement, so a build that would not meet the installed app's is refused.
    func testABuildWithAnotherDesignatedRequirementIsRefused() throws {
        try makeBundle(at: app, marker: "old", requirement: #"identifier "com.metawhisp.app" and anchor apple generic and certificate leaf[subject.OU] = "6D6948Z4MW""#)
        let new = temp.appendingPathComponent("new/MetaWhisp.app", isDirectory: true)
        try makeBundle(at: new, marker: "new", requirement: #"identifier "com.metawhisp.app" and cdhash H"0123""#)
        let run = try runLib("mw_swap_app \"$1\"", [new.path])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("designated requirement differs"), run.output)
        XCTAssertTrue(run.output.contains("cdhash"), "both requirements are shown")
        XCTAssertTrue(run.output.contains("release DMG"), "the message says how to go on")
        XCTAssertEqual(marker(in: app), "old")
        XCTAssertTrue(log(openLog).isEmpty, "nothing was opened")
    }

    // MARK: - Swap

    func testASuccessfulSwapAsksTheAppToQuitAndKeepsTheReplacedOne() throws {
        try makeBundle(at: app, marker: "old")
        let running = try spawn(as: appExecutable)
        try writeLease(pid: running.processIdentifier, executable: appExecutable, state: .idle)
        let oldWorkingCopy = oldCopyDir.appendingPathComponent("MetaWhisp.app", isDirectory: true)
        try makeBundle(at: oldWorkingCopy, marker: "working")
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path],
                             env: ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1"])
        XCTAssertEqual(run.status, 0, run.output)
        running.waitUntilExit()
        XCTAssertEqual(running.terminationReason, .uncaughtSignal)
        XCTAssertEqual(running.terminationStatus, SIGTERM, "asked to quit, never forced")
        XCTAssertEqual(marker(in: app), "new")
        XCTAssertEqual(marker(in: previous), "old", "the replaced build is kept for --rollback")
        let kept = try FileManager.default.contentsOfDirectory(atPath: swapDir.path)
        XCTAssertFalse(kept.contains { $0.hasSuffix(".app") }, "no kept copy is a bundle macOS would open")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDir.path), "the swap lock is released")
        XCTAssertTrue(run.output.contains("--rollback"), "the output says how to go back")
        XCTAssertTrue(run.output.contains("An old copy of the working app"), "the old copy in ~/Applications is pointed out")
        XCTAssertEqual(marker(in: oldWorkingCopy), "working", "and left alone")
    }

    /// The new build is opened as a new instance: right after the installed bundle is replaced, macOS can still
    /// resolve the app to the process that just quit and refuse the open with -600 (2026-10-20, three swaps of eight
    /// rolled back so). A new instance is never resolved to it; the swap has already seen that process gone.
    func testTheNewBuildIsOpenedAsANewInstanceSoAQuitProcessCannotTakeTheOpen() throws {
        try makeBundle(at: app, marker: "old")
        let running = try spawn(as: appExecutable)
        try writeLease(pid: running.processIdentifier, executable: appExecutable, state: .idle)
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path],
                             env: ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1", "FAKE_OPEN_STALE": "1"])
        XCTAssertEqual(run.status, 0, run.output)
        XCTAssertEqual(marker(in: app), "new")
        XCTAssertEqual(log(openLog), [app.path], "opened once, as a new instance")
    }

    func testANewAppThatDoesNotStartPutsTheInstalledOneBackAndRelaunchesIt() throws {
        try makeBundle(at: app, marker: "old")
        let running = try spawn(as: appExecutable)
        try writeLease(pid: running.processIdentifier, executable: appExecutable, state: .idle)
        let new = try newBundle("new")
        // The fake `open` starts nothing here.
        let run = try runLib("mw_swap_app \"$1\"", [new.path])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("did not start"), run.output)
        running.waitUntilExit()
        XCTAssertEqual(running.terminationStatus, SIGTERM, "asked to quit, never forced")
        XCTAssertEqual(marker(in: app), "old", "the installed app is back")
        XCTAssertEqual(log(openLog), [app.path, app.path], "the new app was opened, then the installed one again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
    }

    func testANewAppThatWritesNoLeaseIsRolledBack() throws {
        try makeBundle(at: app, marker: "old")
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path],
                             env: ["FAKE_OPEN_STARTS": "1", "MW_HEALTH_TIMEOUT": "1"])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("did not write its activity lease"), run.output)
        XCTAssertEqual(marker(in: app), "old")
    }

    func testANewAppThatQuitsRightAfterStartingIsRolledBack() throws {
        try makeBundle(at: app, marker: "old")
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path],
                             env: ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1",
                                   "FAKE_OPEN_LIFETIME": "1.5", "MW_LAUNCH_SETTLE": "3"])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("quit within"), run.output)
        XCTAssertEqual(marker(in: app), "old")
    }

    func testAFailedFirstInstallLeavesNoHalfInstalledApp() throws {
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("did not start"), run.output)
        XCTAssertEqual(log(openLog), [app.path], "the new app was opened once; there was nothing to relaunch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: swapDir.appendingPathComponent("MetaWhisp.failed").path),
                       "the failed copy is not left behind")
    }

    /// A swap cut off half-way, by an interrupt with the terminal already gone,
    /// still puts the installed app back.
    func testAnInterruptedSwapStillPutsTheInstalledAppBack() throws {
        try makeBundle(at: app, marker: "old")
        let new = try newBundle("new")
        let run = try runLib("set -euo pipefail; mw_trap_exit ':'; exec 2>&-; mw_swap_app \"$1\"", [new.path],
                             env: ["FAKE_OPEN_INTERRUPTS": "1"])
        XCTAssertEqual(run.status, 130, run.output)
        XCTAssertEqual(marker(in: app), "old", "the installed app is back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDir.path), "the swap lock is released")
    }

    /// A swap cut off hard can leave the installed app only in the swap folder;
    /// the next swap puts it back instead of deleting it.
    func testALeftoverCopyIsPutBackBeforeTheNextSwap() throws {
        try makeBundle(at: current, marker: "old")
        let new = temp.appendingPathComponent("new/MetaWhisp.app", isDirectory: true)
        try makeBundle(at: new, marker: "new", requirement: #"identifier "com.metawhisp.app" and cdhash H"0123""#)
        // Refused right after the leftover step: the new build meets another requirement.
        let run = try runLib("mw_swap_app \"$1\"", [new.path])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("designated requirement differs"), run.output)
        XCTAssertEqual(marker(in: app), "old", "the leftover is back in place before the refusal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(log(openLog).isEmpty, "nothing was opened")
    }

    /// When a failed swap kept both copies, the next swap stops and deletes
    /// neither: which one to keep is the owner's call.
    func testTwoKeptCopiesStopTheNextSwapAndBothStay() throws {
        try makeBundle(at: app, marker: "newer")
        try makeBundle(at: current, marker: "older")
        let running = try spawn(as: appExecutable)
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("kept two copies"), run.output)
        XCTAssertEqual(marker(in: app), "newer")
        XCTAssertEqual(marker(in: current), "older")
        XCTAssertTrue(running.isRunning, "nothing was stopped")
    }

    /// One swap at a time; a lock whose swap is gone, or that never got going
    /// and is old, stops counting, so a crash never blocks swaps.
    func testOnlyOneSwapRunsAtATimeAndAStaleLockIsTakenOver() throws {
        let new = try newBundle("new")
        let starts = ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1"]
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        let other = try spawn(as: "/Applications/Other.app/Contents/MacOS/Other")
        try "\(other.processIdentifier)\n".write(to: lockDir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        let busy = try runLib("mw_swap_app \"$1\"", [new.path], env: starts)
        XCTAssertNotEqual(busy.status, 0)
        XCTAssertTrue(busy.output.contains("Another swap"), busy.output)
        XCTAssertTrue(busy.output.contains(lockDir.path), "the message names the lock to remove if no swap runs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))

        kill(other.processIdentifier, SIGKILL)
        other.waitUntilExit()
        let taken = try runLib("mw_swap_app \"$1\"", [new.path], env: starts)
        XCTAssertEqual(taken.status, 0, taken.output)
        XCTAssertEqual(marker(in: app), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDir.path), "released after the swap")

        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        let starting = try runLib("mw_swap_app \"$1\"", [new.path], env: starts)
        XCTAssertTrue(starting.output.contains("is starting"), "a lock without a pid counts while it is young")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: lockDir.path)
        let old = try runLib("mw_swap_app \"$1\"", [new.path], env: starts)
        XCTAssertEqual(old.status, 0, old.output)
    }

    func testTheAppIsAskedToQuitAndNeverForced() throws {
        let polite = try spawn(as: appExecutable)
        let quit = try runLib("mw_quit_app \"$1\"", [appExecutable])
        XCTAssertEqual(quit.status, 0, quit.output)
        polite.waitUntilExit()
        XCTAssertEqual(polite.terminationReason, .uncaughtSignal)
        XCTAssertEqual(polite.terminationStatus, SIGTERM, "asked with SIGTERM, the app's normal quit")

        let stubborn = try spawn(as: appExecutable, ignoringQuit: true)
        let run = try runLib("mw_quit_app \"$1\"", [appExecutable])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("was not force-killed"), run.output)
        XCTAssertTrue(stubborn.isRunning, "never SIGKILL")
    }

    /// A folder name with characters that mean something in a search pattern
    /// still finds the running app.
    func testAPathWithPatternCharactersStillFindsTheApp() throws {
        let odd = temp.appendingPathComponent("Apps+ (1) [x]/MetaWhisp.app/Contents/MacOS/MetaWhisp").path
        let running = try spawn(as: odd)
        let quit = try runLib("mw_quit_app \"$1\"", [odd])
        XCTAssertEqual(quit.status, 0, quit.output)
        running.waitUntilExit()
        XCTAssertEqual(running.terminationStatus, SIGTERM, "found and asked to quit")
    }

    // MARK: - Rollback

    func testRollbackPutsTheReplacedBuildBackAndCanBeUndone() throws {
        let none = try runLib("mw_restore_previous")
        XCTAssertNotEqual(none.status, 0)
        XCTAssertTrue(none.output.contains("no kept previous"), none.output)

        try makeBundle(at: app, marker: "old")
        let new = try newBundle("new")
        let env = ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1"]
        let swapped = try runLib("mw_swap_app \"$1\"", [new.path], env: env)
        XCTAssertEqual(swapped.status, 0, swapped.output)

        let back = try runLib("mw_restore_previous", env: env)
        XCTAssertEqual(back.status, 0, back.output)
        XCTAssertEqual(marker(in: app), "old", "the replaced build is installed again")
        XCTAssertEqual(marker(in: previous), "new", "and the one it replaced is kept for the next --rollback")

        let again = try runLib("mw_restore_previous", env: env)
        XCTAssertEqual(again.status, 0, again.output)
        XCTAssertEqual(marker(in: app), "new")
    }

    func testARollbackRefusedWhileTheAppRecordsTouchesNothing() throws {
        try makeBundle(at: app, marker: "new")
        try makeBundle(at: previous, marker: "old")
        let running = try spawn(as: appExecutable)
        try writeLease(pid: running.processIdentifier, executable: appExecutable, state: .recording)
        let run = try runLib("mw_restore_previous")
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("is recording right now"), run.output)
        XCTAssertEqual(marker(in: app), "new")
        XCTAssertEqual(marker(in: previous), "old", "the kept build is still kept")
        XCTAssertTrue(running.isRunning)
    }

    // MARK: - The scripts never force anything

    func testNoScriptForceKillsOrSignsAdHoc() throws {
        let banned = ["pkill", "killall", "kill -9", "-KILL", "-SIGKILL", "kill -s KILL", "kill -s 9",
                      "SIGN_IDENTITY=\"-\"", "--sign -", "--sign=-", "-s -"]
        for file in ["build.sh", "hot-swap.sh", "scripts/lib/app-install.sh"] {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(file), encoding: .utf8)
            for word in banned {
                XCTAssertFalse(text.contains(word), "\(file) contains \(word)")
            }
        }
        for file in ["release.sh", "make-dmg-manual.sh", "make-zip.sh"] {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(file), encoding: .utf8)
            for word in ["mw_swap_app", "mw_restore_previous", "$HOME/Applications", "MW_OPEN"] {
                XCTAssertFalse(text.contains(word), "\(file) contains \(word): a release never installs, quits or opens an app")
            }
        }
    }

    // MARK: - Interrupted and stubborn swaps (review of 0.1, round 1)

    /// The installed app is moved aside right after it quit. An interrupt in
    /// that moment, before the rollback is armed, still puts it back and opens
    /// it again.
    func testAnInterruptRightAfterTheMoveAsidePutsTheAppBackAndOpensIt() throws {
        try makeBundle(at: app, marker: "old")
        let running = try spawn(as: appExecutable)
        try writeLease(pid: running.processIdentifier, executable: appExecutable, state: .idle)
        try fake("mv", """
            /bin/mv "$@"; status=$?
            if [ "$1" = "$FAKE_MV_INTERRUPT_SOURCE" ] && [ ! -e "$1" ]; then kill -TERM "$PPID"; fi
            exit $status
            """)
        let new = try newBundle("new")
        let run = try runLib("mw_trap_exit ':'; mw_swap_app \"$1\"", [new.path],
                             env: ["FAKE_MV_INTERRUPT_SOURCE": app.path])
        XCTAssertEqual(run.status, 130, run.output)
        XCTAssertEqual(marker(in: app), "old", "the installed app is back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertEqual(log(openLog), [app.path], "and it was opened again, since it was running")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDir.path), "the swap lock is released")
    }

    /// A swap always opens the new build to check it: a build installed
    /// without starting it could be broken.
    func testASwapCannotSkipTheLaunchCheck() throws {
        let run = try bash("bash build.sh --swap --no-launch")
        XCTAssertEqual(run.status, 2, run.output)
        XCTAssertTrue(run.output.contains("Unknown option: --no-launch"), run.output)
        let viaHotSwap = try bash("bash hot-swap.sh --no-launch")
        XCTAssertEqual(viaHotSwap.status, 2, viaHotSwap.output)
    }

    func testHotSwapRollsBackOnItsOwnAndRefusesUnknownOptions() throws {
        let bogus = try bash("bash hot-swap.sh --rollback --bogus")
        XCTAssertEqual(bogus.status, 2, bogus.output)
        XCTAssertTrue(bogus.output.contains("Unknown option: --bogus"), bogus.output)
        try makeBundle(at: app, marker: "new")
        try makeBundle(at: previous, marker: "old")
        let back = try bash("bash hot-swap.sh --rollback", env: ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1"])
        XCTAssertEqual(back.status, 0, back.output)
        XCTAssertEqual(marker(in: app), "old")
        XCTAssertEqual(marker(in: previous), "new")
    }

    /// A rollback cut off half-way leaves the kept build staged; the next
    /// rollback finds it instead of saying there is none.
    func testAnInterruptedRollbackKeepsTheKeptBuildForTheNextOne() throws {
        try makeBundle(at: app, marker: "new")
        try makeBundle(at: previous, marker: "old")
        let cut = try runLib("mw_trap_exit ':'; mw_restore_previous", env: ["FAKE_OPEN_INTERRUPTS": "1"])
        XCTAssertEqual(cut.status, 130, cut.output)
        XCTAssertEqual(marker(in: app), "new", "the installed build is back")
        let next = try runLib("mw_restore_previous", env: ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1"])
        XCTAssertEqual(next.status, 0, next.output)
        XCTAssertEqual(marker(in: app), "old")
        XCTAssertEqual(marker(in: previous), "new")
    }

    /// A new build that started recording before the swap was cut off is not
    /// stopped: both copies are kept and the output says where.
    func testARollbackNeverStopsANewAppThatRecords() throws {
        try makeBundle(at: app, marker: "old")
        let new = try newBundle("new")
        let run = try runLib("mw_trap_exit ':'; mw_swap_app \"$1\"", [new.path], env: [
            "FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1", "FAKE_OPEN_LEASE_STATE": "recording",
            "FAKE_OPEN_INTERRUPTS_AFTER_START": "1", "FAKE_OPEN_LIFETIME": "20"])
        XCTAssertEqual(run.status, 130, run.output)
        XCTAssertTrue(run.output.contains("is recording"), run.output)
        XCTAssertEqual(marker(in: app), "new", "the recording build stays where it runs")
        XCTAssertEqual(marker(in: previous), "old", "the installed one is kept")
        let pids = log(openPids).compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 1)
        XCTAssertEqual(kill(pids[0], 0), 0, "the recording app still runs")
    }

    /// A new build that ignores the quit is never force-killed, and never left
    /// installed either: it is moved aside, the installed one is put back, and
    /// the output says to quit the stuck one.
    func testANewBuildThatIgnoresTheQuitIsMovedAsideNotLeftInstalled() throws {
        try makeBundle(at: app, marker: "old")
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path], env: [
            "FAKE_OPEN_STARTS": "1", "FAKE_OPEN_IGNORES_TERM": "1", "FAKE_OPEN_LIFETIME": "20", "MW_HEALTH_TIMEOUT": "1"])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("did not quit"), run.output)
        XCTAssertEqual(marker(in: app), "old", "the installed app is back")
        XCTAssertEqual(marker(in: swapDir.appendingPathComponent("MetaWhisp.failed")), "new", "the stuck build is kept aside")
        XCTAssertEqual(log(openLog), [app.path], "nothing is opened while the stuck one still runs")
        let pids = log(openPids).compactMap { Int32($0) }
        XCTAssertEqual(kill(pids[0], 0), 0, "never force-killed")
    }

    /// A kept copy that can't be replaced is reported; the swap never moves a
    /// build into it or promises a rollback it can't give.
    /// A kept copy that cannot even be moved aside — locked itself — is
    /// reported, and the replaced build stays where it can be found.
    func testAKeptCopyThatCannotBeReplacedIsReported() throws {
        try makeBundle(at: app, marker: "old")
        try makeBundle(at: previous, marker: "older")
        _ = try bash("/usr/bin/chflags uchg \"$1\"", [previous.path])
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path], env: ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1"])
        XCTAssertEqual(run.status, 0, run.output)
        XCTAssertEqual(marker(in: app), "new")
        XCTAssertTrue(run.output.contains("could not be kept for --rollback"), run.output)
        XCTAssertFalse(run.output.contains("--rollback puts it back"), "no promise it can't keep")
        XCTAssertEqual(marker(in: current), "old", "the replaced build stays where it can be found")
        XCTAssertEqual(marker(in: previous), "older", "the older kept build is as it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.appendingPathComponent("MetaWhisp.current").path),
                       "nothing was moved into the kept copy")
    }

    /// An older kept copy that cannot be deleted no longer blocks keeping the
    /// replaced build: it is renamed aside first, and only its removal fails.
    func testAKeptCopyThatCannotBeDeletedNoLongerBlocksKeepingTheReplacedOne() throws {
        try makeBundle(at: app, marker: "old")
        try makeBundle(at: previous, marker: "older")
        _ = try bash("/usr/bin/chflags uchg \"$1\"", [previous.appendingPathComponent("Contents/marker.txt").path])
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path], env: ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1"])
        XCTAssertEqual(run.status, 0, run.output)
        XCTAssertEqual(marker(in: app), "new")
        XCTAssertEqual(marker(in: previous), "old", "the replaced build is kept for --rollback")
        XCTAssertTrue(run.output.contains("--rollback puts it back"), run.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path), "no leftover stops the next swap")
    }

    /// An installed app with no readable requirement (ad-hoc or unsigned) is
    /// refused with the way on: install the release DMG first.
    func testAnInstalledAppWithoutARequirementSaysHowToGoOn() throws {
        try makeBundle(at: app, marker: "adhoc", requirement: #"# designated => cdhash H"abcd""#)
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("release DMG"), run.output)
        XCTAssertEqual(marker(in: app), "adhoc", "nothing was touched")
    }

    /// A swap build is put together apart from the release bundle, which
    /// release.sh and make-dmg-manual.sh package.
    func testASwapBuildIsAssembledApartFromTheReleaseBundle() throws {
        let run = try runLib("mw_bundle_path /b/release false; mw_bundle_path /b/release true")
        XCTAssertEqual(run.output, "/b/release/MetaWhisp.app\n/b/release/swap/MetaWhisp.app\n")
        let build = try String(contentsOf: repoRoot.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("APP_DIR=$(mw_bundle_path \"$BUILD_DIR\" \"$SWAP\")"), "build.sh uses it")
    }

    // MARK: - Round 2 of the review (0.1b)

    /// N1: a busy lease left by another copy of the app, running from
    /// somewhere else, does not stop a rollback of the new build.
    func testARollbackIgnoresABusyLeaseFromAnotherCopy() throws {
        try makeBundle(at: app, marker: "old")
        let elsewhere = oldCopyDir.appendingPathComponent("MetaWhisp.app/Contents/MacOS/MetaWhisp").path
        let other = try spawn(as: elsewhere)
        let new = try newBundle("new")
        // The other copy starts recording while the new build is opened; the new one never starts.
        let run = try runLib("mw_swap_app \"$1\"", [new.path], env: [
            "FAKE_OPEN_OTHER_LEASE_PID": String(other.processIdentifier), "FAKE_OPEN_OTHER_LEASE_EXE": elsewhere])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("did not start"), run.output)
        XCTAssertEqual(marker(in: app), "old", "the installed app is back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(other.isRunning, "the other copy is left alone")
    }

    /// N2: a new build left running because it records keeps the replaced one
    /// as the kept build, and once it has finished, --rollback puts that back.
    func testANewBuildLeftRecordingCanBeRolledBackWhenItHasFinished() throws {
        try makeBundle(at: app, marker: "old")
        let new = try newBundle("new")
        let run = try runLib("mw_trap_exit ':'; mw_swap_app \"$1\"", [new.path], env: [
            "FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1", "FAKE_OPEN_LEASE_STATE": "recording",
            "FAKE_OPEN_INTERRUPTS_AFTER_START": "1", "FAKE_OPEN_LIFETIME": "20"])
        XCTAssertEqual(run.status, 130, run.output)
        XCTAssertTrue(run.output.contains("--rollback"), "the output says how to get the installed one back")
        XCTAssertEqual(marker(in: app), "new")
        XCTAssertEqual(marker(in: previous), "old", "the replaced build is the kept one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path), "no leftover blocks the next swap")
        let pid = try XCTUnwrap(log(openPids).compactMap { Int32($0) }.first)
        try writeLease(pid: pid, executable: appExecutable, state: .idle)
        let back = try runLib("mw_restore_previous", env: ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1"])
        XCTAssertEqual(back.status, 0, back.output)
        XCTAssertEqual(marker(in: app), "old")
    }

    /// N2: an exit between a successful swap and keeping the replaced build
    /// still keeps it.
    func testAnExitAfterASuccessfulSwapStillKeepsTheReplacedBuild() throws {
        try makeBundle(at: app, marker: "new")
        try makeBundle(at: current, marker: "old")
        let run = try runLib("MW_SWAP_SUCCEEDED=true; mw_on_exit")
        XCTAssertEqual(run.status, 0, run.output)
        XCTAssertEqual(marker(in: previous), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertEqual(marker(in: app), "new")
    }

    /// R1: an interrupt while the replaced build is being kept still keeps it.
    func testAnInterruptWhileKeepingTheReplacedBuildStillKeepsIt() throws {
        try makeBundle(at: app, marker: "old")
        try makeBundle(at: previous, marker: "older")
        let sent = temp.appendingPathComponent("term.sent")
        // The interrupt lands in the keep's one gap: the older kept build moved
        // aside, the replaced one not yet in its place.
        try fake("mv", """
            if [ "$1" = "$FAKE_PREVIOUS" ]; then case "$2" in *.stale.*)
                /bin/mv "$@" || exit 1
                echo sent >> "$FAKE_TERM_SENT"; kill -TERM "$PPID"; exit 0 ;;
            esac; fi
            exec /bin/mv "$@"
            """)
        let new = try newBundle("new")
        let run = try runLib("mw_trap_exit ':'; mw_swap_app \"$1\"", [new.path],
                             env: ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1",
                                   "FAKE_PREVIOUS": previous.path, "FAKE_TERM_SENT": sent.path])
        XCTAssertEqual(log(sent), ["sent"], "the interrupt was sent inside the keep")
        XCTAssertEqual(marker(in: app), "new", run.output)
        XCTAssertEqual(marker(in: previous), "old", "the replaced build is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path), "no leftover blocks the next swap")
        let stale = try FileManager.default.contentsOfDirectory(atPath: swapDir.path).filter { $0.contains(".stale.") }
        XCTAssertEqual(stale, [], "the older kept build is gone")
    }

    /// Round 2, finding 1: the recording branch of the rollback keeps the
    /// installed build the same way, so a kill while the older kept build is
    /// deleted still leaves the installed one kept for --rollback.
    func testAKillWhileARecordingRollbackKeepsTheInstalledBuildStillKeepsIt() throws {
        try makeBundle(at: app, marker: "old")
        try makeBundle(at: previous, marker: "older")
        try fake("rm", """
            for arg in "$@"; do
                case "$arg" in *"/MetaWhisp.previous"*)
                    if [ "${FAKE_RM_KILLS:-0}" = 1 ]; then kill -KILL "$PPID"; sleep 2; exit 1; fi ;;
                esac
            done
            exec /bin/rm "$@"
            """)
        let new = try newBundle("new")
        _ = try runLib("mw_trap_exit ':'; mw_swap_app \"$1\"", [new.path], env: [
            "FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1", "FAKE_OPEN_LEASE_STATE": "recording",
            "FAKE_OPEN_INTERRUPTS_AFTER_START": "1", "FAKE_OPEN_LIFETIME": "20", "FAKE_RM_KILLS": "1"])
        let stale = try FileManager.default.contentsOfDirectory(atPath: swapDir.path).filter { $0.contains(".stale.") }
        XCTAssertEqual(stale.count, 1, "the kill fired while the older kept build was being deleted")
        XCTAssertEqual(marker(in: app), "new", "a new build that records is never stopped")
        XCTAssertEqual(marker(in: previous), "old", "the installed build is the kept one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path), "no leftover blocks the next swap")
    }

    /// R3: an old failed copy that can't be removed never blocks a rollback.
    func testAFailedCopyThatCannotBeRemovedDoesNotBlockTheRollback() throws {
        try makeBundle(at: app, marker: "old")
        let stale = swapDir.appendingPathComponent("MetaWhisp.failed")
        try makeBundle(at: stale, marker: "stale")
        _ = try bash("/usr/bin/chflags uchg \"$1\"", [stale.appendingPathComponent("Contents/marker.txt").path])
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("did not start"), run.output)
        XCTAssertEqual(marker(in: app), "old", "the installed app is back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
    }

    /// N4: a rollback cut off hard while it waits for the new build to quit
    /// has already put the installed one back.
    func testARollbackKilledWhileWaitingForTheQuitHasAlreadyPutTheAppBack() throws {
        try makeBundle(at: app, marker: "old")
        let new = try newBundle("new")
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/bash")
        script.arguments = ["-c", "source '\(libPath)' && mw_swap_app \"$1\"", "bash", new.path]
        script.currentDirectoryURL = repoRoot
        script.environment = environment(extra: ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_IGNORES_TERM": "1",
                                                 "FAKE_OPEN_LIFETIME": "30", "MW_HEALTH_TIMEOUT": "1",
                                                 "MW_QUIT_TIMEOUT": "20"])
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        try script.run()
        spawned.append(script)
        let failed = swapDir.appendingPathComponent("MetaWhisp.failed")
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: failed.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.3)
        kill(script.processIdentifier, SIGKILL)
        script.waitUntilExit()
        XCTAssertEqual(marker(in: app), "old", "renamed back before the wait")
        XCTAssertEqual(marker(in: swapDir.appendingPathComponent("MetaWhisp.failed")), "new")
    }

    /// N5: a first install whose new build ignores the quit names only what
    /// is there.
    func testAFirstInstallThatIgnoresTheQuitNamesOnlyWhatIsThere() throws {
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path], env: [
            "FAKE_OPEN_STARTS": "1", "FAKE_OPEN_IGNORES_TERM": "1", "FAKE_OPEN_LIFETIME": "20", "MW_HEALTH_TIMEOUT": "1"])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("did not quit"), run.output)
        XCTAssertFalse(run.output.contains(current.path), "no installed copy to name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path), "a build that failed its check is not left installed")
        XCTAssertEqual(marker(in: swapDir.appendingPathComponent("MetaWhisp.failed")), "new")
    }

    /// N7: a new SwiftData schema version breaks --rollback across it; the
    /// swap's schema check comes first (app-install.sh, known limits).
    func testTheSchemaCountIsPinnedUntilTheSwapChecksSchemas() {
        XCTAssertEqual(MetaWhispMigrationPlan.schemas.count, 9,
                       "a new schema version breaks --rollback: add the swap's schema check first")
    }

    /// N8: an interrupt while the installed app is still quitting opens it
    /// again once it is gone.
    func testAnInterruptDuringTheQuitReopensTheAppOnceItIsGone() throws {
        try makeBundle(at: app, marker: "old")
        let asked = temp.appendingPathComponent("asked-to-quit")
        let slow = try spawnSlowToQuit(as: appExecutable, seconds: 1.5, marker: asked.path)
        try writeLease(pid: slow.processIdentifier, executable: appExecutable, state: .idle)
        let new = try newBundle("new")
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/bash")
        script.arguments = ["-c", "source '\(libPath)' && mw_trap_exit ':' && mw_swap_app \"$1\"", "bash", new.path]
        script.currentDirectoryURL = repoRoot
        script.environment = environment(extra: ["MW_QUIT_TIMEOUT": "5"])
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        try script.run()
        spawned.append(script)
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: asked.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(script.processIdentifier, SIGTERM)
        script.waitUntilExit()
        XCTAssertEqual(script.terminationStatus, 130)
        XCTAssertEqual(marker(in: app), "old")
        XCTAssertEqual(log(openLog), [app.path], "opened again once the old process was gone")
    }

    /// N8, and the Kimi audit of 2026-09-27: the new build is copied beside
    /// the installed one and checked there first, so a copy that fails, or
    /// whose signature fails, never touches the installed app — it is not even
    /// asked to quit.
    func testAFailedCopyOrSignatureNeverTouchesTheInstalledApp() throws {
        for env in [["FAKE_DITTO_FAILS": "1"], ["FAKE_VERIFY_FAILS_FOR": incoming.path]] {
            try? FileManager.default.removeItem(at: installDir)
            try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
            try makeBundle(at: app, marker: "old")
            let running = try spawn(as: appExecutable)
            try writeLease(pid: running.processIdentifier, executable: appExecutable, state: .idle)
            try fake("ditto", """
                if [ "${FAKE_DITTO_FAILS:-0}" = 1 ]; then echo "ditto: No space left on device" >&2; exit 1; fi
                exec /usr/bin/ditto "$@"
                """)
            let new = try newBundle("new")
            let run = try runLib("mw_swap_app \"$1\"", [new.path], env: env)
            XCTAssertNotEqual(run.status, 0, "\(env)")
            XCTAssertEqual(marker(in: app), "old", "\(env)")
            XCTAssertTrue(running.isRunning, "the installed app was never asked to quit: \(env)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: current.path), "\(env)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path), "no copy is left behind: \(env)")
            kill(running.processIdentifier, SIGKILL)
        }
    }

    /// The Kimi audit of 2026-09-27 (P2): keeping the replaced build never
    /// deletes the older kept one before the replaced one is in its place, so
    /// a kill while the old one is being deleted still leaves the replaced
    /// build kept for --rollback.
    func testAKillWhileKeepingTheReplacedBuildStillKeepsIt() throws {
        try makeBundle(at: previous, marker: "older")
        try makeBundle(at: app, marker: "old")
        let new = try newBundle("new")
        try fake("rm", """
            for arg in "$@"; do
                case "$arg" in *"/MetaWhisp.previous"*)
                    if [ "${FAKE_RM_KILLS:-0}" = 1 ]; then kill -KILL "$PPID"; sleep 2; exit 1; fi ;;
                esac
            done
            exec /bin/rm "$@"
            """)
        let run = try runLib("mw_swap_app \"$1\"", [new.path],
                             env: ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1", "FAKE_RM_KILLS": "1"])
        XCTAssertNotEqual(run.status, 0, "the swap was killed")
        XCTAssertEqual(marker(in: app), "new")
        XCTAssertEqual(marker(in: previous), "old", "the build this swap replaced is the one kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path), "no leftover stops the next swap")

        let newer = try newBundle("newer")
        let next = try runLib("mw_swap_app \"$1\"", [newer.path],
                              env: ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1"])
        XCTAssertEqual(next.status, 0, next.output)
        let stale = try FileManager.default.contentsOfDirectory(atPath: swapDir.path).filter { $0.contains(".stale.") }
        XCTAssertEqual(stale, [], "what the kill left is cleared by the next keep")
    }

    /// Round 2, finding 3: one rename puts the copy in place only on one
    /// volume. A swap folder on another volume is refused before anything is
    /// copied or quit.
    func testASwapFolderOnAnotherVolumeIsRefusedBeforeAnythingIsTouched() throws {
        try makeBundle(at: app, marker: "old")
        let running = try spawn(as: appExecutable)
        try writeLease(pid: running.processIdentifier, executable: appExecutable, state: .idle)
        try fake("stat", """
            if [ "$1" = "-f" ] && [ "$2" = "%d" ]; then
                case "$3" in "$FAKE_INSTALL_DIR"*) echo 16777230 ;; *) echo 16777231 ;; esac
                exit 0
            fi
            exec /usr/bin/stat "$@"
            """)
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path], env: ["FAKE_INSTALL_DIR": installDir.path])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("same volume"), run.output)
        XCTAssertEqual(marker(in: app), "old")
        XCTAssertTrue(running.isRunning, "the installed app was never asked to quit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path), "nothing was copied")
    }

    /// Round 2, finding 4: an interrupt during the copy leaves the installed
    /// app whole and no copy behind.
    func testAnInterruptDuringTheCopyLeavesNoCopyBehind() throws {
        try makeBundle(at: app, marker: "old")
        let running = try spawn(as: appExecutable)
        try writeLease(pid: running.processIdentifier, executable: appExecutable, state: .idle)
        try fake("ditto", """
            mkdir -p "$2/Contents"; echo partial > "$2/Contents/marker.txt"
            kill -TERM "$PPID"; exit 1
            """)
        let new = try newBundle("new")
        let run = try runLib("mw_trap_exit ':'; mw_swap_app \"$1\"", [new.path])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertEqual(marker(in: app), "old")
        XCTAssertTrue(running.isRunning, "the installed app was never asked to quit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path), "no copy is left behind")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDir.path), "the swap lock is released")
    }

    /// Round 2, finding 5: a rename into place that fails puts the installed
    /// app back and leaves no copy behind.
    func testAFailedRenameIntoPlacePutsTheInstalledAppBack() throws {
        try makeBundle(at: app, marker: "old")
        try fake("mv", """
            if [ "$1" = "$FAKE_INCOMING" ]; then echo "mv: rename failed" >&2; exit 1; fi
            exec /bin/mv "$@"
            """)
        let new = try newBundle("new")
        let run = try runLib("mw_swap_app \"$1\"", [new.path], env: ["FAKE_INCOMING": incoming.path])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("in place failed"), run.output)
        XCTAssertEqual(marker(in: app), "old", "the installed app is back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path), "no copy is left behind")
    }

    /// The Kimi audit of 2026-09-27 (P1): a swap killed hard during the copy —
    /// a crash, a power cut — never leaves a half-copied app in /Applications.
    /// The installed app is untouched and still running, and the next swap
    /// clears the leftover copy and goes through.
    func testASwapKilledDuringTheCopyLeavesTheInstalledAppWhole() throws {
        try makeBundle(at: app, marker: "old")
        let running = try spawn(as: appExecutable)
        try writeLease(pid: running.processIdentifier, executable: appExecutable, state: .idle)
        try fake("ditto", """
            if [ "${FAKE_DITTO_KILLS:-0}" = 1 ]; then
                mkdir -p "$2/Contents"; echo partial > "$2/Contents/marker.txt"
                kill -KILL "$PPID"; sleep 2; exit 1
            fi
            exec /usr/bin/ditto "$@"
            """)
        let new = try newBundle("new")
        let killed = try runLib("mw_swap_app \"$1\"", [new.path], env: ["FAKE_DITTO_KILLS": "1"])
        XCTAssertNotEqual(killed.status, 0)
        XCTAssertEqual(marker(in: app), "old", "no half-copied app in the install folder")
        XCTAssertTrue(running.isRunning, "the installed app was never asked to quit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))

        // The kill left the swap lock behind, owned by a process that is gone.
        let next = try runLib("mw_swap_app \"$1\"", [new.path],
                              env: ["FAKE_OPEN_STARTS": "1", "FAKE_OPEN_WRITES_LEASE": "1"])
        XCTAssertEqual(next.status, 0, next.output)
        XCTAssertEqual(marker(in: app), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path), "the leftover copy is gone")
    }

    // MARK: - Self-check

    func testTheSelfCheckPassesOnlyOnTheAppsOwnOK() throws {
        let ok = try fakeApp("ok", "echo 'self-check: one ok'; echo 'SELF-CHECK OK'; exit 0")
        let failed = try fakeApp("failed", "echo 'SELF-CHECK FAILED'; exit 1")
        let silent = try fakeApp("silent", "exit 0")
        let crashed = try fakeApp("crashed", "echo 'SELF-CHECK OK'; exit 3")
        let pass = try runLib("mw_self_check \"$1\"", [ok])
        XCTAssertEqual(pass.status, 0, pass.output)
        let fail = try runLib("mw_self_check \"$1\"", [failed])
        XCTAssertNotEqual(fail.status, 0)
        XCTAssertTrue(fail.output.contains("SELF-CHECK FAILED"), "the app's own lines are shown")
        XCTAssertNotEqual(try runLib("mw_self_check \"$1\"", [silent]).status, 0,
                          "exit 0 without the OK line is not a pass")
        XCTAssertNotEqual(try runLib("mw_self_check \"$1\"", [crashed]).status, 0,
                          "the OK line with a failing exit is not a pass")
    }

    func testASelfCheckThatHangsIsStoppedAndFailsInTime() throws {
        let hangs = try fakeApp("hangs", "exec /bin/sleep 30")
        let started = Date()
        let run = try runLib("mw_self_check \"$1\"", [hangs], env: ["MW_SELF_CHECK_TIMEOUT": "1"])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("did not finish"), run.output)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "a hung check never holds up a build")
    }

    /// A check that ignores the stop is reported and left behind, never waited on.
    func testASelfCheckThatIgnoresTheStopIsReportedNotWaitedOn() throws {
        let stubborn = try fakeApp("stubborn", "echo $$ >> \"$FAKE_OPEN_PIDS\"; trap '' TERM; exec /bin/sleep 30")
        let started = Date()
        // It ignores the stop from its start — launched with TERM ignored —
        // not only once its own trap is in: a check that starts slowly (a
        // loaded Mac) is otherwise stopped by the one-second limit before it
        // can ignore anything, and the premise is gone.
        let run = try runLib("trap '' TERM; mw_self_check \"$1\"", [stubborn], env: ["MW_SELF_CHECK_TIMEOUT": "1"])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("did not stop when asked"), run.output)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "never waited on")
    }

    func testAReleaseNeverStopsTheWorkingAppOrReadsItsLog() throws {
        for file in ["release.sh", "make-dmg-manual.sh", "make-zip.sh"] {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(file), encoding: .utf8)
            for word in ["pkill", "killall", "kill -9", "-KILL", "Library/Logs/MetaWhisp.log", "/Volumes/MetaWhisp"] {
                XCTAssertFalse(text.contains(word), "\(file) contains \(word)")
            }
        }
        let release = try String(contentsOf: repoRoot.appendingPathComponent("release.sh"), encoding: .utf8)
        XCTAssertTrue(release.contains("mw_self_check"), "the smoke test is the app's self-check")
        XCTAssertTrue(release.contains("mw_trap_exit"), "an interrupted release stops a self-check still running")
    }

    // MARK: - Helpers

    /// A stand-in executable: a bash script with the given body, which runs
    /// only when it is asked for its self-check.
    private func fakeApp(_ name: String, _ body: String) throws -> String {
        let url = temp.appendingPathComponent("apps/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let guardLine = "[ \"$1\" = --self-check ] || { echo 'not asked for the self-check'; exit 3; }\n"
        try ("#!/bin/bash\n" + guardLine + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private struct Run {
        let status: Int32
        let output: String
    }

    /// Runs a bash snippet from the repo root with the fakes first on PATH and
    /// every MW_* tool and folder pointed at them; `$1…` are `args`.
    private func bash(_ script: String, _ args: [String] = [], env extra: [String: String] = [:]) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "bash"] + args
        process.currentDirectoryURL = repoRoot
        process.environment = environment(extra: extra)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// The fakes first on PATH and every MW_* tool and folder pointed at them.
    private func environment(extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = fakes.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        env["MW_SECURITY"] = fakes.appendingPathComponent("security").path
        env["MW_CODESIGN"] = fakes.appendingPathComponent("codesign").path
        env["MW_OPEN"] = fakes.appendingPathComponent("open").path
        env["MW_APP_INSTALL_DIR"] = installDir.path
        env["MW_APP_SUPPORT_DIR"] = supportDir.path
        env["MW_SWAP_DIR"] = swapDir.path
        env["MW_OLD_COPY_DIR"] = oldCopyDir.path
        env.removeValue(forKey: "MW_CONFIRM_IDLE")
        env["MW_QUIT_TIMEOUT"] = "1"
        env["MW_LAUNCH_TIMEOUT"] = "2"
        env["MW_HEALTH_TIMEOUT"] = "3"
        env["MW_LAUNCH_SETTLE"] = "1"
        env["MW_SELF_CHECK_GRACE"] = "1"
        env["FAKE_CODESIGN_LOG"] = codesignLog.path
        env["FAKE_OPEN_LOG"] = openLog.path
        env["FAKE_OPEN_PIDS"] = openPids.path
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// A stand-in that takes `seconds` to quit after SIGTERM, running under
    /// `executable` as its command line.
    private func spawnSlowToQuit(as executable: String, seconds: Double, marker: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "exec -a \"$0\" /bin/bash -c 'trap \"touch \\\"$1\\\"; sleep \(seconds); exit 0\" TERM; while :; do sleep 0.1; done' \"$0\" \"$1\"",
                             executable, marker]
        try process.run()
        spawned.append(process)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !(try runLib("mw_pids_of \"$1\"", [executable]).output.isEmpty) { return process }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("the slow stand-in for \(executable) never ran under that name")
        return process
    }

    /// Calls functions of scripts/lib/app-install.sh.
    private func runLib(_ call: String, _ args: [String] = [], env: [String: String] = [:]) throws -> Run {
        try bash("source '\(libPath)' && " + call, args, env: env)
    }

    private func fake(_ name: String, _ body: String) throws {
        let url = fakes.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The lines a fake tool logged; none if it never ran.
    private func log(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// A stand-in whose command line is exactly `executable`, the way `open`
    /// starts an app. It waits until the stand-in runs under that name.
    private func spawn(as executable: String, ignoringQuit: Bool = false) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", (ignoringQuit ? "trap '' TERM; " : "") + "exec -a \"$0\" /bin/sleep 30", executable]
        try process.run()
        spawned.append(process)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let name = try bash("ps -o comm= -p \(process.processIdentifier)").output
            if name.trimmingCharacters(in: .whitespacesAndNewlines) == executable { return process }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("the stand-in for \(executable) never ran under that name")
        return process
    }

    /// The lease written by the app's own writer, so the script is tested on
    /// exactly what the app writes.
    private func writeLease(pid: Int32, executable: String, state: ActivityLease.State) throws {
        try ActivityLease.write(ActivityLease.Record(pid: pid, executable: executable, state: state, since: Date()),
                                to: ActivityLease.fileURL(in: supportDir))
    }

    /// A new build to install, outside the install folder.
    private func newBundle(_ marker: String) throws -> URL {
        let url = temp.appendingPathComponent("\(marker)/MetaWhisp.app", isDirectory: true)
        try makeBundle(at: url, marker: marker)
        return url
    }

    /// A stand-in bundle: an Info.plist with the given bundle id and
    /// executable, a marker file, and optionally the designated requirement the
    /// fake `codesign` reports for it.
    private func makeBundle(at url: URL, marker: String, bundleID: String = "com.metawhisp.app",
                            executable: String = "MetaWhisp", requirement: String? = nil) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS", isDirectory: true),
                                                withIntermediateDirectories: true)
        try marker.write(to: contents.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": executable]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if let requirement {
            try requirement.write(to: contents.appendingPathComponent("dr.txt"), atomically: true, encoding: .utf8)
        }
    }

    private func marker(in app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
    }
}
