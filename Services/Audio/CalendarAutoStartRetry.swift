import Foundation

/// Whether a calendar event that already fired may fire again.
///
/// An event fired exactly once, ever. On 2026-09-17 08:30 one fired into a
/// closed lid — ScreenCaptureKit reported no displays, the microphone produced
/// nothing, and the meeting auto-stopped on silence three minutes later with
/// `mic=0 samples, system=0 samples`. The owner joined the call afterwards and
/// nothing re-armed: the event had spent its only trigger.
///
/// A retry needs a ceiling and a spacing, or a meeting nobody is holding is
/// reopened every second for an hour. Pure, so the rule is arguable without a
/// calendar.
enum CalendarAutoStartRetry {

    /// Attempts per event, the first one included.
    static let maxAttempts = 3

    /// Gate ticks between attempts — the loop runs about once a second, so
    /// this is roughly a minute.
    static let cooldownTicks = 60

    /// - Parameter declined: the person already turned this event's recording
    ///   off by hand. A retry exists for the meeting that started into an empty
    ///   room and gave up on its own — never to argue with someone who pressed
    ///   stop. Shipped without this, it restarted a meeting the owner had just
    ///   stopped, three times in four minutes (owner's log, 2026-09-22 18:31).
    /// Which stops came from the person. A meeting the recorder ended by
    /// itself — silence, the calendar event running out — may be retried; one
    /// a hand stopped may not. Matched here rather than at the call site so
    /// the list is one thing, with a test.
    static func isRefusal(stopReason: String) -> Bool {
        // `calendar-end-overrun-card-tap:<eventID>` carries the id after the
        // reason, so this matches inside the string rather than at its end.
        stopReason == "user-toggle" || stopReason.contains("card-tap")
    }

    static func shouldRetry(attempts: Int, ticksSinceLast: Int,
                            isRecording: Bool, eventInProgress: Bool,
                            declined: Bool) -> Bool {
        !declined
            && eventInProgress
            && !isRecording
            && attempts < maxAttempts
            && ticksSinceLast >= cooldownTicks
    }
}
