import Foundation

/// What a meeting does when a channel does not come up.
///
/// The two channels were not equals. A microphone that failed to start was
/// survivable: the meeting ran on system audio, the banner said the user's own
/// voice was missing, and `armMicRecovery` kept trying to bring the mic in. A
/// system channel that failed did the opposite — it aborted the whole meeting,
/// microphone included, and the user was left with a red banner and no
/// recording at all (owner's log, three calendar auto-starts: 2026-09-15
/// 08:30, 2026-09-16 08:30 and 12:00).
///
/// A meeting is abandoned only when there is nothing left to record. Pure, so
/// the rule is arguable without a meeting.
enum MeetingStartPolicy {

    enum Start: Equatable {
        /// Record with the channels named — one of them may be absent.
        case record(mic: Bool, system: Bool)
        /// Neither channel can record; there is no meeting to hold.
        case abandon
    }

    static func start(micAvailable: Bool, systemAvailable: Bool) -> Start {
        guard micAvailable || systemAvailable else { return .abandon }
        return .record(mic: micAvailable, system: systemAvailable)
    }

    /// How many times a meeting asks for the channel it started without.
    /// Bounded, because a chase that never ends is a leak wearing a recovery's
    /// clothes: system audio that is refused at 08:30 is usually refused at
    /// 08:31 too, and the banner already tells the truth.
    static let maxSystemJoinAttempts = 5

    /// Between attempts. Long enough that a stuck ScreenCaptureKit is given
    /// room to recover, short enough that a channel which comes back joins a
    /// meeting still worth joining.
    static let systemJoinDelaySeconds: Double = 10

    static func shouldChaseSystem(isRecording: Bool, systemUp: Bool, attempts: Int) -> Bool {
        isRecording && !systemUp && attempts < maxSystemJoinAttempts
    }
}
