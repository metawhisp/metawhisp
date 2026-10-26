import XCTest
@testable import MetaWhisp

/// The app's primary trigger is Right ⌘. macOS delivers those events to a
/// global monitor only when Accessibility is granted, and a monitor installed
/// before the grant does not start working when the grant arrives — it has to
/// be installed again.
///
/// History: `register()` once ignored the grant altogether (audit, 2026-09-06,
/// P1). Its fix watched for 600 s and then gave up, so a grant made later —
/// after a re-signed build on 2026-09-25 — left Right ⌘ and the layout fix
/// dead until a relaunch. `PermissionMonitor` now watches for the life of the
/// app (ITER-075 step 0, US-0.3).
@MainActor
final class HotkeyRearmTests: XCTestCase {

    private typealias State = PermissionMonitor.State

    func testTheGrantArrivingIsWhatRearms() {
        XCTAssertEqual(PermissionMonitor.change(was: false, is: true), .granted,
                       "permission just arrived — the monitors have to be installed again")
    }

    func testNothingHappensWhileTheAnswerHasNotChanged() {
        XCTAssertNil(PermissionMonitor.change(was: false, is: false))
        XCTAssertNil(PermissionMonitor.change(was: true, is: true),
                     "re-installing working monitors would drop the keystroke in flight")
    }

    func testLosingPermissionIsARevocationNotARearm() {
        XCTAssertEqual(PermissionMonitor.change(was: true, is: false), .revoked)
    }

    /// The release of the watch is the grant itself, whenever it comes: there
    /// is no ceiling after which a grant stops counting.
    func testAGrantIsPickedUpHoweverLateItComes() {
        var granted = false
        let monitor = PermissionMonitor(read: { State(accessibility: granted, screenRecording: true) })
        var changes: [PermissionMonitor.Change] = []
        monitor.onAccessibility = { changes.append($0) }
        for _ in 0..<10_000 { monitor.check() }
        XCTAssertEqual(changes, [], "hours of checks with nothing granted change nothing")
        granted = true
        monitor.check()
        XCTAssertEqual(changes, [.granted])
    }

    /// A grant that is revoked and given again — what a re-signed build does —
    /// re-arms again, even when the app was trusted at launch.
    func testARevokedPermissionThatComesBackRearmsAgain() {
        var trusted = true
        let monitor = PermissionMonitor(read: { State(accessibility: trusted, screenRecording: true) })
        var changes: [PermissionMonitor.Change] = []
        monitor.onAccessibility = { changes.append($0) }
        trusted = false
        monitor.check()
        trusted = true
        monitor.check()
        XCTAssertEqual(changes, [.revoked, .granted])
    }

    func testScreenRecordingIsWatchedToo() {
        var screen = false
        let monitor = PermissionMonitor(read: { State(accessibility: true, screenRecording: screen) })
        var changes: [PermissionMonitor.Change] = []
        monitor.onScreenRecording = { changes.append($0) }
        screen = true
        monitor.check()
        XCTAssertEqual(changes, [.granted])
    }

    /// Often while something is missing, so a grant lands within seconds;
    /// rarely once everything is granted, so a revocation is still noticed.
    func testTheWatchIsFastWhileSomethingIsMissingAndNeverStops() {
        XCTAssertEqual(PermissionMonitor.interval(for: State(accessibility: false, screenRecording: true),
                                                  needsScreenRecording: true), 5)
        XCTAssertEqual(PermissionMonitor.interval(for: State(accessibility: true, screenRecording: false),
                                                  needsScreenRecording: true), 5)
        XCTAssertEqual(PermissionMonitor.interval(for: State(accessibility: true, screenRecording: true),
                                                  needsScreenRecording: true), 60)
    }
}
