import XCTest
@testable import MetaWhisp

/// Pure state-machine tests for `CallSessionMachine`. No UI, no
/// notifications — just the (input, current-state) → (new-state, decision)
/// transitions. Adapted from Omi's session-state pattern: one event in,
/// one decision out, all locks collapsed into the session struct.
final class CallSessionMachineTests: XCTestCase {

    // MARK: - First detect

    /// First time we detect "Zoom" with auto-start enabled → fresh session,
    /// fire notify, arm countdown.
    func test_firstDetect_firesNotify_andCountdownIfAutoStart() {
        let (session, decision) = CallSessionMachine.onDetect(
            name: "Zoom", current: nil, autoStartEnabled: true
        )
        XCTAssertEqual(session.name, "Zoom")
        XCTAssertTrue(session.didAnnounce)
        XCTAssertFalse(session.userDeclinedRecording)
        XCTAssertEqual(decision, .fireNotify(name: "Zoom", armCountdown: true))
    }

    /// First detect with auto-start OFF → notify but no countdown.
    func test_firstDetect_firesNotify_butNoCountdownIfAutoStartOff() {
        let (_, decision) = CallSessionMachine.onDetect(
            name: "Zoom", current: nil, autoStartEnabled: false
        )
        XCTAssertEqual(decision, .fireNotify(name: "Zoom", armCountdown: false))
    }

    // MARK: - Re-detect dedup

    /// Same call context detected again (e.g. user tabs Slack → Zoom while
    /// Zoom call is still up) → suppress duplicate notify.
    func test_redetect_sameName_suppressesDuplicate() {
        let existing = CallSession(name: "Zoom", didAnnounce: true, userDeclinedRecording: false)
        let (session, decision) = CallSessionMachine.onDetect(
            name: "Zoom", current: existing, autoStartEnabled: true
        )
        XCTAssertEqual(session, existing)
        XCTAssertEqual(decision, .suppressDuplicate)
    }

    /// Different call app detected (Zoom → Teams) → new session, fire notify.
    func test_redetect_differentName_firesNotify() {
        let existing = CallSession(name: "Zoom", didAnnounce: true, userDeclinedRecording: false)
        let (session, decision) = CallSessionMachine.onDetect(
            name: "Teams", current: existing, autoStartEnabled: true
        )
        XCTAssertEqual(session.name, "Teams")
        XCTAssertTrue(session.didAnnounce)
        XCTAssertFalse(session.userDeclinedRecording)
        XCTAssertEqual(decision, .fireNotify(name: "Teams", armCountdown: true))
    }

    // MARK: - User-declined behavior

    /// After user manually stops recording, re-detects of the same call name
    /// must NOT re-announce or re-arm a countdown — the user said no for
    /// THIS call session.
    func test_userStopped_blocksFutureCountdown_onSameSession() {
        var session: CallSession? = CallSession(name: "Zoom", didAnnounce: true, userDeclinedRecording: false)
        session = CallSessionMachine.onUserStopped(session)
        XCTAssertNotNil(session)
        XCTAssertTrue(session!.userDeclinedRecording)

        let (newSession, decision) = CallSessionMachine.onDetect(
            name: "Zoom", current: session, autoStartEnabled: true
        )
        XCTAssertTrue(newSession.userDeclinedRecording)
        XCTAssertEqual(decision, .suppressBecauseDeclined)
    }

    /// After session is cleared (180s nil-debounce expired), even a previously
    /// declined call name produces a brand-new session on next detect.
    func test_userStopped_doesNotBlockNewCallAfterEnd() {
        let declined = CallSession(name: "Zoom", didAnnounce: true, userDeclinedRecording: true)
        let cleared = CallSessionMachine.onSessionEnd(declined)
        XCTAssertNil(cleared)

        let (newSession, decision) = CallSessionMachine.onDetect(
            name: "Zoom", current: nil, autoStartEnabled: true
        )
        XCTAssertEqual(newSession.name, "Zoom")
        XCTAssertFalse(newSession.userDeclinedRecording)
        XCTAssertEqual(decision, .fireNotify(name: "Zoom", armCountdown: true))
    }

    /// `onUserStopped(nil)` → still nil (no session to mark).
    func test_userStopped_onNilSession_returnsNil() {
        XCTAssertNil(CallSessionMachine.onUserStopped(nil))
    }
}
