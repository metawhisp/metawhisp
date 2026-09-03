import Foundation

/// Tells a DEAD input stream apart from a quiet room.
///
/// Why this exists (2026-08-12, founder's Mac): macOS's audio subsystem began
/// handing the process bit-exact zero samples. Eight dictations and one meeting
/// were recorded into nothing and silently discarded — the app's only reaction
/// was `Audio too quiet (RMS=0.00000)` in a log file nobody was watching. The
/// fault was below the app (a `killall coreaudiod` cleared it), but the app's
/// blindness to it was ours: every silence guard in the pipeline compares RMS
/// against a threshold, which cannot distinguish "no signal at all" from
/// "someone speaking softly".
///
/// The distinction: a LIVE microphone always carries a noise floor. On the
/// built-in mic a silent room still reads ~2e-4. An RMS of bit-exact `0`,
/// sustained, means no signal is arriving — a different failure class from
/// quiet audio, and one the user must be told about rather than shrugged off.
///
/// Deliberately pure and synchronous so the audio tap can call it inline and
/// the whole behaviour is unit-testable without CoreAudio.
struct DeadMicDetector {

    /// How long a run of bit-exact-zero audio must last before the stream is
    /// declared dead. Long enough that a momentary gap at engine start-up
    /// doesn't trip it, short enough that the user isn't left talking to a
    /// corpse for a whole sentence.
    static let deadAfterSeconds: Double = 1.0

    private var zeroSeconds: Double = 0
    private var tripped = false

    /// True while the CURRENT run of exact zeros has lasted past the window.
    /// Audio clears it: a run that ended is not a fault, and the next run can
    /// trip again — a stream that went dead, came back, and went dead for good
    /// used to be invisible after its first trip (review round eight).
    var isDead: Bool { tripped }

    /// Did ANY non-zero sample arrive since the last `reset()`?
    ///
    /// This is what separates "the microphone is dead" from "the microphone
    /// went quiet". Bluetooth headsets and interfaces with silence suppression
    /// legitimately emit runs of bit-exact zeros between phrases, so a zero-run
    /// on a stream that HAS produced audio is ambiguous and must not be thrown
    /// in the user's face. A stream that has produced nothing at all is not.
    private(set) var sawAudio = false

    /// Feed one tap buffer's RMS. Returns `true` exactly once: on the buffer
    /// that completes the dead-stream window.
    ///
    /// `rms == 0` is an intentional exact comparison. RMS is the root of a mean
    /// of squares, so it is zero if and only if every sample in the buffer is
    /// zero — precisely the "no signal" condition. Anything else, however
    /// small, means audio is flowing.
    mutating func observe(rms: Float, frames: Int, sampleRate: Double) -> Bool {
        // A buffer with no frames carries no time; a bogus sample rate is its
        // own failure and must not masquerade as a dead mic.
        guard frames > 0, sampleRate > 0 else { return false }

        guard rms == 0 else {
            // Any real signal clears the run outright, trip included: a dead
            // stream never recovers on its own, so a run that ended was never
            // one, and the next run must be able to trip on its own.
            zeroSeconds = 0
            tripped = false
            // NaN is neither zero nor evidence of a live mic — don't let it
            // vouch for the stream.
            if rms.isFinite { sawAudio = true }
            return false
        }

        guard !tripped else { return false }

        zeroSeconds += Double(frames) / sampleRate
        guard zeroSeconds >= Self.deadAfterSeconds else { return false }
        tripped = true
        return true
    }

    /// Re-arm after a recovery attempt, so a still-dead stream trips again and
    /// the failure can be escalated instead of silently retried forever.
    mutating func reset() {
        zeroSeconds = 0
        tripped = false
        sawAudio = false
    }
}
