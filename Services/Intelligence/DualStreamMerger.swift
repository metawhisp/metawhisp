import Foundation

/// Pseudo-diarization helper for meeting recordings.
///
/// Reference adaptation: instead of multichannel Deepgram (channels=2 with
/// per-channel `speaker` labels), we transcribe mic and system audio in two
/// separate Whisper passes, label each segment by its source channel, then
/// merge by timestamp. Mic = .me, system = .them. mic and system samples are
/// never summed, so no mix-in artifacts.
enum Speaker: Equatable {
    case me
    case them
}

struct StreamSegment: Equatable {
    let text: String
    let startSec: Double
    let endSec: Double
    let speaker: Speaker
}

enum DualStreamMerger {
    /// Merge two channel-labeled segment lists into a single time-sorted list.
    static func mergeStreams(mic: [StreamSegment], system: [StreamSegment]) -> [StreamSegment] {
        return (mic + system).sorted { $0.startSec < $1.startSec }
    }

    /// Render merged segments as a `Me: …` / `Them: …` transcript.
    /// Consecutive same-speaker segments share a single prefix and are joined
    /// by a space; a speaker switch starts a new line.
    static func renderTranscript(_ segments: [StreamSegment]) -> String {
        guard !segments.isEmpty else { return "" }
        var lines: [String] = []
        var currentSpeaker = segments[0].speaker
        var currentTexts: [String] = []
        func flush() {
            guard !currentTexts.isEmpty else { return }
            let prefix = currentSpeaker == .me ? "Me" : "Them"
            lines.append("\(prefix): \(currentTexts.joined(separator: " "))")
        }
        for seg in segments {
            if seg.speaker != currentSpeaker {
                flush()
                currentSpeaker = seg.speaker
                currentTexts = []
            }
            currentTexts.append(seg.text)
        }
        flush()
        return lines.joined(separator: "\n")
    }
}
