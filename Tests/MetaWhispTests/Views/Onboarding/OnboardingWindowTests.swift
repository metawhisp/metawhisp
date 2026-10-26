import AppKit
import XCTest
@testable import MetaWhisp

/// D1 — the onboarding window: 720 × 600, normal level, on the Space the user is on (H1, E6); closed means
/// released, never kept hidden (the window invariant); and the permission-return latch (A4, A5): a button that
/// opens System Settings arms one return, the grant spends it within 10 minutes, a closed window never comes back.
/// No test here shows a window — the decisions are pure, the AppKit side is pinned on its source.
@MainActor
final class OnboardingWindowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - The return latch

    func testASettingsButtonArmsOneReturnThatTheGrantSpends() {
        var latch = PermissionReturnLatch()
        latch.arm(.accessibility, now: start)
        XCTAssertTrue(latch.granted(.accessibility, now: start.addingTimeInterval(90)), "comes back once")
        XCTAssertFalse(latch.granted(.accessibility, now: start.addingTimeInterval(91)), "and only once")
    }

    func testNothingComesBackWithoutASettingsButton() {
        var latch = PermissionReturnLatch()
        XCTAssertFalse(latch.granted(.microphone, now: start), "a prompt's Allow brings no window back")
    }

    /// A5 — granted more than 10 minutes later: no window jump, and the latch is gone.
    func testAGrantAfterTenMinutesBringsNothing() {
        var latch = PermissionReturnLatch()
        latch.arm(.accessibility, now: start)
        XCTAssertFalse(latch.granted(.accessibility, now: start.addingTimeInterval(PermissionReturnLatch.limit + 1)))
        XCTAssertNil(latch.pending, "the expired return is dropped")
    }

    /// The grant at the deadline itself still counts; the ceiling is ten minutes, not less.
    func testAGrantInsideTheTenMinutesStillComesBack() {
        var latch = PermissionReturnLatch()
        latch.arm(.microphone, now: start)
        XCTAssertTrue(latch.granted(.microphone, now: start.addingTimeInterval(PermissionReturnLatch.limit)))
    }

    func testTheOtherPermissionsGrantLeavesTheReturnArmed() {
        var latch = PermissionReturnLatch()
        latch.arm(.accessibility, now: start)
        XCTAssertFalse(latch.granted(.microphone, now: start))
        XCTAssertTrue(latch.granted(.accessibility, now: start), "still waiting for its own permission")
    }

    /// A newer Settings button replaces the older return and restarts the ten minutes.
    func testTheLatestSettingsButtonDecides() {
        var latch = PermissionReturnLatch()
        latch.arm(.microphone, now: start)
        latch.arm(.accessibility, now: start.addingTimeInterval(500))
        XCTAssertFalse(latch.granted(.microphone, now: start.addingTimeInterval(501)))
        XCTAssertTrue(latch.granted(.accessibility, now: start.addingTimeInterval(500 + PermissionReturnLatch.limit)))
    }

    /// A5 — the window closed: the return is forgotten with it.
    func testAClosedWindowForgetsTheReturn() {
        var latch = PermissionReturnLatch()
        latch.arm(.accessibility, now: start)
        latch.clear()
        XCTAssertFalse(latch.granted(.accessibility, now: start))
    }

    // MARK: - Where the window goes

    func testShowMakesTheWindowOrBringsItToTheUser() {
        XCTAssertEqual(OnboardingWindowPlacement.show(hasWindow: false, isVisible: false, isOnActiveSpace: false), .create)
        XCTAssertEqual(OnboardingWindowPlacement.show(hasWindow: true, isVisible: true, isOnActiveSpace: true),
                       .bringForward)
        XCTAssertEqual(OnboardingWindowPlacement.show(hasWindow: true, isVisible: true, isOnActiveSpace: false),
                       .reopenHere, "a window on another Space is never a reason to take the user there")
    }

    /// A permission's return brings back only a window that is open — a closed one stays closed (A5).
    func testAReturnBringsBackOnlyAnOpenWindowToTheCurrentSpace() {
        XCTAssertEqual(OnboardingWindowPlacement.comeBack(hasWindow: false, isVisible: false, isOnActiveSpace: false),
                       .nothing)
        XCTAssertEqual(OnboardingWindowPlacement.comeBack(hasWindow: true, isVisible: true, isOnActiveSpace: true),
                       .bringForward)
        XCTAssertEqual(OnboardingWindowPlacement.comeBack(hasWindow: true, isVisible: true, isOnActiveSpace: false),
                       .reopenHere)
    }

    /// Checked on the next run loop turn: on the user's Space it stays; visible elsewhere it is made again here,
    /// once; a second miss is logged and nothing more — never a loop.
    func testAWindowThatLandsOffTheUsersSpaceIsMadeAgainOnce() {
        XCTAssertEqual(OnboardingWindowPlacement.afterOrderFront(isVisible: true, isOnActiveSpace: true,
                                                                 alreadyMadeAgain: false), .landed)
        XCTAssertEqual(OnboardingWindowPlacement.afterOrderFront(isVisible: true, isOnActiveSpace: false,
                                                                 alreadyMadeAgain: false), .makeAgain)
        XCTAssertEqual(OnboardingWindowPlacement.afterOrderFront(isVisible: true, isOnActiveSpace: false,
                                                                 alreadyMadeAgain: true), .logOnly)
        XCTAssertEqual(OnboardingWindowPlacement.afterOrderFront(isVisible: false, isOnActiveSpace: false,
                                                                 alreadyMadeAgain: false), .logOnly,
                       "a window that is not up at all is not made again in a loop")
    }

    /// Each way the window comes to the user — a show and a permission's return — has its own one remake: a show
    /// that needed it does not leave the return with none (Codex 2026-10-25, P2).
    func testAPermissionReturnHasItsOwnRemake() throws {
        let code = try Self.codeLines(of: "Views/Windows/OnboardingWindowController.swift")
        for function in ["func show()", "private func granted("] {
            let start = try XCTUnwrap(code.firstIndex { $0.contains(function) }, function)
            let body = code[start...].prefix { !$0.hasPrefix("    }") }
            let reset = try XCTUnwrap(body.firstIndex { $0.contains("madeAgain = false") }, "\(function) resets it")
            let placement = try XCTUnwrap(body.firstIndex { $0.contains("OnboardingWindowPlacement.") }, function)
            XCTAssertLessThan(reset, placement, "\(function): reset before the window is placed")
        }
    }

    /// The app is never activated for the onboarding window: activation is what threw the user to another Space
    /// (MainWindowController's history); on the owner's Mac, 2026-10-25, ten presses of "Show onboarding" made the
    /// window ten times, each one off the user's Space. Where it lands is logged in the main window's format.
    func testTheWindowNeverActivatesTheAppAndLogsWhereItLands() throws {
        let code = try Self.codeLines(of: "Views/Windows/OnboardingWindowController.swift")
        XCTAssertFalse(code.contains { $0.contains(".activate(") }, "no NSApp.activate()")
        XCTAssertTrue(code.contains { $0.contains("[SpaceTrace]") }, "where it landed is in the log")
    }

    // MARK: - The window itself (H1, E6)

    func testTheWindowIs720By600AtTheNormalLevel() {
        XCTAssertEqual(OnboardingWindowController.size, NSSize(width: 720, height: 600))
        XCTAssertEqual(OnboardingWindowController.level, .normal, "never floating over System Settings")
    }

    /// No window of the app is ever kept hidden: the red button closes it for real and the controller lets it go.
    /// It comes to the Space the user is on by the window invariant (2026-10-19): `MWWindowBehavior.main`, set once
    /// at creation and never changed — no transient join, no park; the park is what threw the user to another Space.
    func testTheWindowIsNeverKeptHiddenAndComesToTheUsersSpace() throws {
        let code = try Self.codeLines(of: "Views/Windows/OnboardingWindowController.swift")
        XCTAssertFalse(code.contains { $0.contains("orderOut(") }, "a closed window is released, never hidden")
        XCTAssertFalse(code.contains { $0.contains("windowShouldClose") }, "a close is never turned into a hide")
        XCTAssertTrue(code.contains { $0.contains("func windowWillClose(") }, "the closed window is released")
        XCTAssertFalse(code.contains { $0.contains(".floating") })
        let behaviors = code.filter { $0.contains("collectionBehavior =") }
        XCTAssertEqual(behaviors.count, 1, "set once, at creation: \(behaviors)")
        XCTAssertTrue(behaviors.allSatisfy { $0.contains("= MWWindowBehavior.main") }, "the shared constant: \(behaviors)")
        XCTAssertFalse(code.contains { $0.contains("mainParked") }, "never parked")
    }

    /// A source file of the app, comments stripped.
    nonisolated static func codeLines(of path: String) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { raw in raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw }
    }
}
