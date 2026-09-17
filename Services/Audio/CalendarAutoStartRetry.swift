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

    static func shouldRetry(attempts: Int, ticksSinceLast: Int,
                            isRecording: Bool, eventInProgress: Bool) -> Bool {
        eventInProgress
            && !isRecording
            && attempts < maxAttempts
            && ticksSinceLast >= cooldownTicks
    }
}
