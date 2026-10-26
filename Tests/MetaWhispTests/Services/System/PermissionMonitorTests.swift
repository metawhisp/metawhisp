import XCTest
@testable import MetaWhisp

/// ITER-075 step 0, US-0.3 — the timed watch keeps itself going at the right
/// rate, and a change gets the right reaction, whatever noticed it.
@MainActor
final class PermissionMonitorTests: XCTestCase {

    private typealias State = PermissionMonitor.State

    /// Records every scheduled check instead of running a timer.
    private final class FakeClock {
        var delays: [TimeInterval] = []
        var actions: [@MainActor () -> Void] = []

        func schedule(_ after: TimeInterval, _ action: @escaping @MainActor () -> Void) {
            delays.append(after)
            actions.append(action)
        }
    }

    func testEveryTimedCheckSchedulesTheNextOneAtTheRecomputedRate() {
        var state = State(accessibility: false, screenRecording: true)
        let clock = FakeClock()
        let monitor = PermissionMonitor(read: { state }, needsScreenRecording: { true }, schedule: clock.schedule)
        monitor.start()
        XCTAssertEqual(clock.delays, [5])
        clock.actions[0]()
        XCTAssertEqual(clock.delays, [5, 5], "each timed check schedules the next one")
        state.accessibility = true
        clock.actions[1]()
        XCTAssertEqual(clock.delays.last, 60, "once everything is granted the watch slows down, and goes on")
    }

    /// A revocation seen on an app switch is watched fast at once, and the old
    /// timer, now stale, neither checks nor schedules.
    func testAChangeSeenOnAnAppSwitchRestartsTheTimerAtTheNewRate() {
        var state = State(accessibility: true, screenRecording: true)
        let clock = FakeClock()
        let monitor = PermissionMonitor(read: { state }, needsScreenRecording: { true }, schedule: clock.schedule)
        monitor.start()
        XCTAssertEqual(clock.delays, [60])
        var changes: [PermissionMonitor.Change] = []
        monitor.onAccessibility = { changes.append($0) }
        state.accessibility = false
        monitor.check()
        XCTAssertEqual(changes, [.revoked])
        XCTAssertEqual(clock.delays, [60, 5])
        clock.actions[0]()
        XCTAssertEqual(clock.delays, [60, 5], "a stale timer schedules nothing")
        XCTAssertEqual(changes, [.revoked], "and reports nothing")
    }

    func testScreenRecordingKeepsTheWatchFastOnlyWhileSomethingNeedsIt() {
        let missingScreen = State(accessibility: true, screenRecording: false)
        XCTAssertEqual(PermissionMonitor.interval(for: missingScreen, needsScreenRecording: true), 5)
        XCTAssertEqual(PermissionMonitor.interval(for: missingScreen, needsScreenRecording: false), 60)
        XCTAssertEqual(PermissionMonitor.interval(for: State(accessibility: false, screenRecording: true),
                                                  needsScreenRecording: false), 5)
    }

    func testStartReadsThePermissionsAsTheyAreNow() {
        var state = State(accessibility: false, screenRecording: false)
        let clock = FakeClock()
        let monitor = PermissionMonitor(read: { state }, needsScreenRecording: { true }, schedule: clock.schedule)
        state = State(accessibility: true, screenRecording: true)
        monitor.start()
        XCTAssertEqual(monitor.state, state, "a change between creation and start is the new baseline")
    }

    // MARK: - What the app does on a change

    private final class Calls {
        var names: [String] = []
    }

    private func reactions(_ calls: Calls, screenContextShouldStart: Bool) -> PermissionReactions {
        PermissionReactions(
            rearmGlobalKeys: { calls.names.append("rearmGlobalKeys") },
            rearmLayoutFix: {
                calls.names.append("rearmLayoutFix")
                return "active"
            },
            refreshSettings: { calls.names.append("refreshSettings") },
            screenContextShouldStart: { screenContextShouldStart },
            startScreenContext: { calls.names.append("startScreenContext") }
        )
    }

    func testAnAccessibilityGrantRearmsEveryGlobalKeyOwnerAndTheLayoutFix() {
        let calls = Calls()
        reactions(calls, screenContextShouldStart: false).accessibility(.granted)
        XCTAssertEqual(calls.names, ["rearmGlobalKeys", "rearmLayoutFix", "refreshSettings"])
    }

    func testARevocationReinstallsNothingButLetsTheLayoutFixStop() {
        let calls = Calls()
        reactions(calls, screenContextShouldStart: false).accessibility(.revoked)
        XCTAssertEqual(calls.names, ["rearmLayoutFix", "refreshSettings"])
    }

    func testAScreenRecordingGrantStartsScreenContextOnlyWhenItShould() {
        let willStart = Calls()
        reactions(willStart, screenContextShouldStart: true).screenRecording(.granted)
        XCTAssertEqual(willStart.names, ["refreshSettings", "startScreenContext"])
        let wontStart = Calls()
        reactions(wontStart, screenContextShouldStart: false).screenRecording(.granted)
        XCTAssertEqual(wontStart.names, ["refreshSettings"])
        let revoked = Calls()
        reactions(revoked, screenContextShouldStart: true).screenRecording(.revoked)
        XCTAssertEqual(revoked.names, ["refreshSettings"])
    }
}
