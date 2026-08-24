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

    /// What to do with this chunk. Carries the drop reason so the suspect log
    /// keeps saying WHY a stretch of a call was discarded — a plain `nil`
    /// collapsed three different causes into one label.
    enum Decision: Equatable {
        case keep(String)
        case drop(reason: String)
    }

    /// - Parameter rms: level of the decoded audio. A near-silent channel is
    ///   where Whisper invents filler, so a known filler phrase over silence is
    ///   still discarded — but quiet speech that says something real is not.
    static func decide(text: String, rms: Float) -> Decision {
        let stripped = TranscriptionCoordinator
            .stripHallucinationTokens(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Nothing but the artifact was there.
        guard !stripped.isEmpty else { return .drop(reason: "artifact-only") }

        // Judge the remainder, not the original: gibberish and bare
        // subtitle-attribution lines still go.
        guard !TranscriptionCoordinator.isAlwaysHallucination(stripped) else {
            return .drop(reason: "always-hallucination")
        }

        // Filler invented over a silent channel.
        if rms < 0.003, TranscriptionCoordinator.isHallucination(stripped) {
            return .drop(reason: "low-rms-hallucination")
        }

        return .keep(stripped)
    }

    /// Convenience for callers that only need the surviving text.
    static func keep(text: String, rms: Float) -> String? {
        if case .keep(let kept) = decide(text: text, rms: rms) { return kept }
        return nil
    }
}
