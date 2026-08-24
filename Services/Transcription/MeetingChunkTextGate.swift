import Foundation

/// What survives of one meeting chunk's text.
///
/// The finalize pass had two tools for Whisper artifacts and used the blunt one
/// first. `isAlwaysHallucination` answers "is this text ENTIRELY an artifact?",
/// and it counts any text under 200 characters carrying a known artifact token
/// as yes — a deliberate rule, because on silence Whisper emits the artifact
/// alone and stops. Its own comment says the caller is expected to run
/// `stripHallucinationTokens` for the longer case. In the meeting loop the
/// check came first and `continue`d, so a chunk holding real speech plus a
/// spliced artifact was discarded whole. The suspect log shows 45 chunks gone
/// that way, each worth up to a few minutes of a call.
///
/// So: strip first, judge what is left. The order change cannot let an artifact
/// through, because the artifact is removed before anything is decided — it can
/// only stop the speech around it from going with it.
@MainActor
enum MeetingChunkTextGate {

    /// The text to keep, or `nil` to drop this chunk.
    ///
    /// - Parameter rms: level of the decoded audio. A near-silent channel is
    ///   where Whisper invents filler, so a known filler phrase over silence is
    ///   still discarded — but quiet speech that says something real is not.
    static func keep(text: String, rms: Float) -> String? {
        let stripped = TranscriptionCoordinator
            .stripHallucinationTokens(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Nothing but the artifact was there.
        guard !stripped.isEmpty else { return nil }

        // Judge the remainder, not the original: gibberish and bare
        // subtitle-attribution lines still go.
        guard !TranscriptionCoordinator.isAlwaysHallucination(stripped) else { return nil }

        // Filler invented over a silent channel.
        if rms < 0.003, TranscriptionCoordinator.isHallucination(stripped) { return nil }

        return stripped
    }
}
