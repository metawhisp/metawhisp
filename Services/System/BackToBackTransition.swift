import Foundation

/// Decision returned by `BackToBackTransition.decide(...)`. Pure value type
/// so the AppDelegate fast-tick can switch on it without holding any state
/// inside the decider.
enum BackToBackDecision: Equatable {
    /// Most common case — the active recording stays as-is. Either no
    /// transition occurred, the recording is in manual mode, or there's
    /// no comparable calendar baseline.
    case keepRecording
    /// User has clearly transitioned from one calendar meeting to another.
    /// Caller stops the active recording; next gate tick will re-fire the
    /// countdown for the new event.
    case stopAndRestart(newEventID: String, newName: String)
}

/// Pure-function back-to-back transition decision (ITER-028.2, 2026-05-06).
///
/// Replaces the window-title heuristic that misfired daily because Google
/// Meet tab titles mutate from generic ("Meet - Google Chrome - …") through
/// several stages including "Meet – ROOM-NAME - Camera and microphone
/// recording - …". Lazy-capture caught one stage; later ticks compared
/// against another stage; back-to-back killed the recording. See
/// `specs/health-reports/2026-05-05.md` and `2026-05-06-morning.md` for the
/// 100% kill rate that motivated this rewrite.
///
/// New approach: compare `EKEvent.eventIdentifier`. Stable for the entire
/// duration of a calendar meeting, stable across browser/locale, stable
/// across tab refreshes. The signal we actually want.
enum BackToBackTransition {
    /// Decide whether the active recording should be stopped because the
    /// user transitioned from calendar event A to calendar event B.
    ///
    /// - Parameters:
    ///   - currentRecordingEventID: the `EKEvent.eventIdentifier` captured
    ///     when the active recording started. `nil` if the recording was
    ///     started without a calendar source (fallback path or manual).
    ///   - gateDecision: latest output of `MeetingAutoStartGate.evaluate(...)`
    ///     from the AppDelegate fast-tick loop.
    ///   - isManualMode: `true` if the active recording was started by the
    ///     user pressing RECORD; manual recordings are user-controlled and
    ///     never auto-killed regardless of gate signals.
    /// - Returns: `.keepRecording` (most cases) or `.stopAndRestart` when
    ///   gate is `.calendarReady` for a different stable eventID than the
    ///   one currently being recorded.
    static func decide(
        currentRecordingEventID: String?,
        gateDecision: MeetingAutoStartGate.Decision,
        isManualMode: Bool
    ) -> BackToBackDecision {
        // Manual recordings — user-controlled. Never killed by the gate.
        if isManualMode { return .keepRecording }

        // Only `.calendarReady` carries the stable eventID we compare
        // against. Other states (.idle, .tracking, .fallbackReady) cannot
        // trigger a transition decision.
        guard case let .calendarReady(name, eventID) = gateDecision else {
            return .keepRecording
        }

        // No baseline to compare against (fallback recording or pre-pivot
        // state) — leave the recording alone. Silence guard / 2h heartbeat
        // own the stop decision in those cases.
        guard let currentID = currentRecordingEventID else {
            return .keepRecording
        }

        // Same event — overrunning a meeting or gate re-emitting the same
        // calendar event for several adjacent ticks. Keep recording.
        if currentID == eventID { return .keepRecording }

        // Different calendar event detected → user has moved to a new
        // meeting. Stop A so the next tick can countdown + start B.
        return .stopAndRestart(newEventID: eventID, newName: name)
    }
}
