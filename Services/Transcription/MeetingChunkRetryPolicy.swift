import Foundation

/// Who pays when a meeting chunk has to be sent twice.
///
/// The finalize pass retries a failed chunk once, re-sending the identical
/// audio. `CloudWhisperEngine.isTransientTransportError` documents why that is
/// risky for precisely the errors this path hits: a timed-out or
/// connection-lost POST may already have been accepted, transcribed and metered
/// server-side, and these requests carry no idempotency key. The engine's own
/// ladder refuses to replay those; the meeting layer above it replayed
/// everything, so the hazard the lower layer avoided was reintroduced above it.
///
/// Removing the retry would put chunk loss back, so the meter moves instead:
/// attempt 1 is billable, replays are not. If the server did process the
/// attempt that vanished, the user is billed once. If it never arrived, the
/// user is billed nothing for that chunk — the wrong direction is the harmless
/// one.
enum MeetingChunkRetryPolicy {

    static func shouldMeter(attempt: Int, callerWantsMetering: Bool) -> Bool {
        callerWantsMetering && attempt == 1
    }
}
