import Foundation

/// Whether a dictation's microphone is delivering, judged by the clock: a capture that never delivers, or stops
/// delivering, sends no buffer to judge it by.
///
/// A dictation is seconds long, so the answer comes in seconds. A fresh bind that has delivered nothing by its
/// deadline, or a bind that delivered and then sent nothing, is bound once more; when that does not bring buffers
/// back, the user is told the microphone delivered nothing — instead of "too short", or nothing at all, which is how
/// the owner's headset dictations of 2026-10-13 ended.
///
/// Pure, so the numbers are arguable without a microphone.
enum MicReadiness {

    /// How often the clock is read.
    static let checkEverySeconds: Double = 0.25

    /// A fresh bind delivers its first buffer within this. The built-in microphone takes a few dozen milliseconds;
    /// a Bluetooth headset first brings up its call link.
    static func firstBufferSeconds(bluetooth: Bool) -> Double { bluetooth ? 2.5 : 1.0 }

    /// Buffers arrive every few milliseconds, silence included: none for this long means the stream stopped.
    static let stalledAfterSeconds: Double = 1.5

    /// Binds one recording may add before the user is told — the ceiling of this check.
    static let rebindsPerRecording = 1

    enum Verdict: Equatable { case fine, rebind, tellUser }

    /// `sinceLastBuffer` is nil while the bind has delivered nothing. `bound` is false when the recording lost its
    /// microphone and nothing is bringing it back (a follow failed or gave up): no deadline is left to wait for.
    static func judge(bound: Bool, sinceBind: Double, sinceLastBuffer: Double?, bluetooth: Bool,
                      rebindsSpent: Int) -> Verdict {
        if bound {
            let quiet = sinceLastBuffer ?? sinceBind
            let limit = sinceLastBuffer == nil ? firstBufferSeconds(bluetooth: bluetooth) : stalledAfterSeconds
            if quiet < limit { return .fine }
        }
        return rebindsSpent < rebindsPerRecording ? .rebind : .tellUser
    }
}
