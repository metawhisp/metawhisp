import Foundation

/// ITER-083 — the one rule for "is this meeting over", asked by both the
/// silence stop (`MeetingRecorder.endsOnQuiet`) and the calendar-end hard stop
/// (`CalendarEndStopDecision`). Before, both ended a recording on quiet alone:
/// on 2026-11-04 the calendar-end check cut a call 76 min in, 24 s after the
/// call detector had seen it, and the call was recorded again 14 s later.
///
/// A call the detector saw lately holds the recording through a quiet stretch.
/// The detector sees a window, not a connection, so a tab left open after the
/// call looks the same as a silent call: 15 minutes with nobody saying
/// anything on either channel ends the recording anyway. That is the accepted
/// trade-off, and the ceiling of the hold; the 240-minute cap stays above it.
enum MeetingEndPolicy {
    /// A sighting this recent counts as "the call is on" (the calendar-end
    /// check's re-check interval).
    static let callSeenWithinSeconds: TimeInterval = 300
    /// Quiet this long ends a recording whatever the detector says.
    static let quietCeilingSeconds: TimeInterval = 900

    /// - Parameters:
    ///   - quietFor: how long both channels have been continuously quiet.
    ///   - quietNeeded: the quiet a stop asks for when no call is seen.
    static func quietEnds(quietFor: TimeInterval, quietNeeded: TimeInterval,
                          lastCallSeenAt: Date?, now: Date) -> Bool {
        if quietFor >= quietCeilingSeconds { return true }
        guard quietFor >= quietNeeded else { return false }
        return !callSeen(lastCallSeenAt, now: now)
    }

    static func callSeen(_ lastCallSeenAt: Date?, now: Date) -> Bool {
        lastCallSeenAt.map { now.timeIntervalSince($0) <= callSeenWithinSeconds } ?? false
    }
}

/// ITER-083 — what a stop was, from its reason. It decides what may start next
/// (`MeetingAutoStartGate`): a person's stop holds the call for good, the next
/// event's start begins that event, and the app's own end holds only the window
/// still in front.
enum StopOutcome: Equatable {
    /// A person stopped it: the record button, the card, the dictation card.
    case refusal
    /// The next calendar event began (`BackToBackTransition`).
    case transition
    /// The app's end rule: the calendar-end check, the silence stop, the cap.
    case ended

    static func of(stopReason: String) -> StopOutcome {
        if CalendarAutoStartRetry.isRefusal(stopReason: stopReason) { return .refusal }
        if stopReason.hasPrefix("back-to-back") { return .transition }
        return .ended
    }
}
