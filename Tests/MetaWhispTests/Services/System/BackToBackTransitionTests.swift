import XCTest
@testable import MetaWhisp

/// Pure-function tests for `BackToBackTransition.decide(...)` — the back-to-
/// back A→B transition decision lifted out of `AppDelegate` so it can be
/// reasoned about without runtime state.
///
/// History (specs/health-reports/2026-05-05.md, 2026-05-06-morning.md):
/// the previous implementation compared `NSWorkspace` window titles. Google
/// Meet tab titles evolve from generic ("Meet - Google Chrome - …") to
/// specific ("Meet – ROOM-NAME - Camera and microphone recording - …") in
/// the first ~1s after the page mounts, plus they vary across browsers and
/// locales. Lazy-capture grabbed one stage; the next tick saw a different
/// stage; back-to-back killed the recording. Daily 100% kill rate on the
/// user's morning calls.
///
/// Pivot (ITER-028.2): compare `EKEvent.eventIdentifier` instead. Calendar
/// IDs are stable across the entire meeting and across UI evolution.
final class BackToBackTransitionTests: XCTestCase {

    // MARK: - Same calendar event → keep

    /// Gate re-emits `.calendarReady` for the same event whose recording is
    /// already in flight (this happens because the gate's calendar window is
    /// `(now-65s, now]` and may match the current event for several ticks).
    /// Decision: keep recording. No restart.
    func test_sameEventIDKeepsRecording() {
        let decision = BackToBackTransition.decide(
            currentRecordingEventID: "evt-A",
            gateDecision: .calendarReady(name: "Daily Sync", eventID: "evt-A"),
            isManualMode: false
        )
        XCTAssertEqual(decision, .keepRecording)
    }

    // MARK: - Different calendar event → stop and restart

    /// User had call A running and now calendar fires for event B. Different
    /// `eventIdentifier` → stop A so the next tick can fire B's countdown.
    func test_differentEventIDStopsAndRestarts() {
        let decision = BackToBackTransition.decide(
            currentRecordingEventID: "evt-A",
            gateDecision: .calendarReady(name: "Performance", eventID: "evt-B"),
            isManualMode: false
        )
        XCTAssertEqual(
            decision,
            .stopAndRestart(newEventID: "evt-B", newName: "Performance")
        )
    }

    // MARK: - No baseline eventID → keep

    /// Recording was started without a calendar source (fallback path —
    /// "Meet window sustained 10s + fullscreen") so we have no eventID to
    /// compare. Decision: leave the recording alone. Gate firing
    /// `.calendarReady` for some unrelated event during a fallback recording
    /// is rare; if it happens, silence guard / 2h heartbeat will eventually
    /// stop the fallback recording cleanly.
    func test_nilCurrentEventIDKeepsRecording() {
        let decision = BackToBackTransition.decide(
            currentRecordingEventID: nil,
            gateDecision: .calendarReady(name: "Daily Sync", eventID: "evt-A"),
            isManualMode: false
        )
        XCTAssertEqual(decision, .keepRecording)
    }

    // MARK: - Gate state .idle / .tracking → keep

    /// Gate sees no call signal at all. Nothing to do.
    func test_idleGateKeepsRecording() {
        let decision = BackToBackTransition.decide(
            currentRecordingEventID: "evt-A",
            gateDecision: .idle,
            isManualMode: false
        )
        XCTAssertEqual(decision, .keepRecording)
    }

    /// Gate is mid-streak on weak fallback signal. Not a transition trigger.
    func test_trackingGateKeepsRecording() {
        let decision = BackToBackTransition.decide(
            currentRecordingEventID: "evt-A",
            gateDecision: .tracking(name: "Meet", secondsLeft: 5),
            isManualMode: false
        )
        XCTAssertEqual(decision, .keepRecording)
    }

    // MARK: - Fallback ready → keep

    /// Fallback path doesn't carry a stable eventID, so we can't safely
    /// kill the current recording even if names mismatch. Keep.
    func test_fallbackReadyKeepsRecording() {
        let decision = BackToBackTransition.decide(
            currentRecordingEventID: "evt-A",
            gateDecision: .fallbackReady(name: "Some Other Call"),
            isManualMode: false
        )
        XCTAssertEqual(decision, .keepRecording)
    }

    // MARK: - Manual mode → keep, regardless

    /// User pressed RECORD manually. Even if calendar fires for a totally
    /// different event, the manual recording must NOT be auto-killed —
    /// the user owns the stop decision.
    func test_manualModeKeepsRecordingEvenWithDifferentEventID() {
        let decision = BackToBackTransition.decide(
            currentRecordingEventID: "evt-A",
            gateDecision: .calendarReady(name: "Performance", eventID: "evt-B"),
            isManualMode: true
        )
        XCTAssertEqual(decision, .keepRecording)
    }

    /// Manual mode with no eventID stored — common case (manual start
    /// doesn't capture eventID at all). Still keep.
    func test_manualModeNilEventIDKeepsRecording() {
        let decision = BackToBackTransition.decide(
            currentRecordingEventID: nil,
            gateDecision: .calendarReady(name: "Performance", eventID: "evt-B"),
            isManualMode: true
        )
        XCTAssertEqual(decision, .keepRecording)
    }
}
