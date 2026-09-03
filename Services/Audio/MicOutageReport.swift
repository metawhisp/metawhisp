import Foundation

/// What the app says after a meeting about its microphone — pure, so every
/// wording a review round argued over is a test. `nil` means the log keeps it
/// and the user is not interrupted.
///
/// Worded without a bare "microphone" in the menu-bar note unless the problem
/// IS the permission: the menu bar routes a note that mentions the permission
/// (or carries 🎤) to the Privacy pane on click.
enum MicOutageReport {

    /// Shorter than this is a blip, not an outage worth interrupting for.
    static let cardFloorSeconds: Double = 3
    /// An external input delivering exact zeros for this long after it had
    /// delivered audio is reported — not restarted: a headset's hardware mute
    /// is the same zeros, and restarting it three times would move the
    /// meeting to the built-in microphone while its wearer believes they are
    /// muted (independent review, v16; the restart was rejected). Reported as
    /// a NOTE, not a card, and as an observation: a headset with silence
    /// suppression produces the same zeros while its wearer listens, and a
    /// card after every long listen would be a nag for a non-event
    /// (independent review, v17).
    static let silentRunFloorSeconds: Double = 300

    struct Input: Equatable {
        var outages: Int
        var outageSeconds: Double
        var micDownAtStop: Bool
        var tapSamples: Int
        var noPermission = false
        var noInputDevice = false
        var silentRunSeconds: Double = 0
        var discarded = false
        /// The tap still carried audio in the last seconds before stop.
        var audioAtStop = false
    }

    struct Wording: Equatable {
        /// The menu-bar note; sticky until the next meeting.
        var note: String
        /// The card, when the event deserves an announcement.
        var title: String?
        var body: String?
    }

    /// "12s" under a minute, "50 min" from there: nobody reads "3000s".
    static func span(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds.rounded()))s" : "\(Int((seconds / 60).rounded())) min"
    }

    static func wording(_ i: Input) -> Wording? {
        // A Mac with no input device at all: nothing to fix, and a card after
        // every meeting would be nagging.
        if i.noInputDevice { return nil }

        if i.noPermission {
            if i.tapSamples == 0 {
                return Wording(note: i.discarded
                    ? "🎤 Microphone permission is off — nothing was heard for a minute, so the recording was not kept"
                    : "🎤 Microphone permission is off — only the other side was recorded",
                    title: nil, body: nil)
            }
            // The system says the permission is off, yet audio was still
            // arriving: nothing is known to be missing, and the card must
            // not claim it is (independent review, v17).
            if i.audioAtStop {
                return Wording(
                    note: "🎤 Microphone permission is off, but audio was still arriving — turn it back on before the next meeting",
                    title: "Microphone permission turned off",
                    body: "macOS reports the microphone permission as off, yet audio was still arriving when the meeting ended. Nothing appears to have been lost. Turn it back on in System Settings → Privacy & Security → Microphone before the next meeting.")
            }
            // Revoked while the meeting was on: an event, announced.
            return Wording(
                note: "🎤 Microphone permission was turned off during the meeting — your side is missing from then on",
                title: "Microphone permission turned off",
                body: i.discarded
                    ? "Microphone access was revoked while the meeting was on, and nothing was heard for a minute, so the recording was not kept."
                    : "Microphone access was revoked while the meeting was on. Your side is missing from that point; the other side is complete. Turn it back on in System Settings → Privacy & Security → Microphone.")
        }

        let silentMinutes = i.silentRunSeconds >= silentRunFloorSeconds
            ? Int((i.silentRunSeconds / 60).rounded()) : 0
        let silentSentence = silentMinutes > 0
            ? " It also carried no signal for \(silentMinutes) min after having worked — if you weren't muted, check the input device."
            : ""

        // A mic that produced NOTHING the whole meeting has no seconds to
        // measure (its buffer stayed empty by design) and is the plainest
        // case of "one side only" there is: reported regardless of the
        // floor. Otherwise a floor: taking the headphones off a second
        // before pressing Stop is not worth a warning card — and a blip
        // falls through to the silent run rather than muting it
        // (independent review, v18).
        let neverProduced = i.tapSamples == 0 && i.micDownAtStop
        let outageWorthTelling = i.outages > 0
            && (neverProduced || i.outageSeconds >= cardFloorSeconds || (i.micDownAtStop && i.outageSeconds >= 1))
        if outageWorthTelling {
            let secs = span(i.outageSeconds)
            let times = i.outages == 1 ? "once" : "\(i.outages) times"
            let ending = i.micDownAtStop
                ? "and had not come back when the meeting ended"
                : "and was brought back"
            // A discarded recording gets its own words: nothing was saved, and
            // "your side is missing" would describe a transcript that does
            // not exist.
            if neverProduced {
                return Wording(
                    note: "⚠️ No mic input for this whole meeting — only the other side was recorded",
                    title: "No microphone input during the meeting",
                    body: i.discarded
                        ? "Your microphone never delivered audio and nothing was heard for a minute, so the recording was not kept."
                        : "Your microphone never delivered audio during this meeting. Only the other side was recorded; check the input device in Settings.")
            }
            if i.discarded {
                return Wording(
                    note: "⚠️ Recording discarded: mic input was down \(secs) and no audio was heard for a minute",
                    title: "Recording discarded — microphone was down",
                    body: "Your microphone went down \(times) for \(secs) \(ending), and no audio was heard for a minute, so the recording was not kept. Start the meeting again if it is still on.")
            }
            return Wording(
                note: "⚠️ Mic input was down \(secs) during this meeting — your side is missing for that stretch",
                title: "Microphone dropped during the meeting",
                body: "Your microphone went down \(times) for \(secs) in total \(ending). Your side is missing for that stretch; the other side is complete." + silentSentence)
        }

        if silentMinutes > 0 {
            return Wording(
                note: "⚠️ Mic input carried no signal for \(silentMinutes) min of this meeting — if you weren't muted, check the input device",
                title: nil, body: nil)
        }
        return nil
    }
}
