import Foundation

/// What quitting owes a meeting that is still capturing.
///
/// The mic and system buffers live in RAM until `MeetingRecorder.stop()` hands
/// them to transcription, so ⌘Q — or Sparkle's Install-and-Relaunch — used to
/// drop the whole meeting: no file, no card, no line in the log (audit,
/// 2026-09-06, P1). Dictation already answers this by writing the samples to
/// `~/Library/Application Support/MetaWhisp/Recovery/`; a meeting gets the
/// same, one file per channel, so the two sides can be told apart.
///
/// Pure, so the decision is arguable without quitting an app.
enum MeetingShutdown {

    /// Under this, a "meeting" is a false start — a click, a countdown that
    /// was cancelled — and holding the quit to write it would be the bug.
    static let minimumRescuableSamples = 16_000      // one second at 16 kHz

    /// macOS waits while `applicationShouldTerminate` says `.terminateLater`.
    /// That wait must end: an hour per channel is ~330 MB, written in well
    /// under a second on an SSD, but a stuck write must not turn ⌘Q into a
    /// hang the user can only fix with Force Quit.
    static let rescueDeadlineSeconds: Double = 6

    enum Plan: Equatable {
        case nothingToDo
        /// Write what has been captured so far, both channels.
        case rescue(micSamples: Int, systemSamples: Int)
    }

    /// `isStarting` counts: system audio is already capturing while the mic is
    /// still being bound, and those seconds are as real as any others.
    static func plan(isRecording: Bool, isStarting: Bool,
                     micSamples: Int, systemSamples: Int) -> Plan {
        guard isRecording || isStarting else { return .nothingToDo }
        guard max(micSamples, systemSamples) >= minimumRescuableSamples else { return .nothingToDo }
        return .rescue(micSamples: micSamples, systemSamples: systemSamples)
    }

    /// A finalization that cannot run — the engine is not loaded, the model
    /// was never downloaded — happens AFTER `stop()` has taken the buffers,
    /// so the samples are locals and the guard's `return` was the end of them
    /// (audit, 2026-09-06, P1). There is no "still recording" to check here:
    /// audio in hand that cannot be transcribed is rescued.
    static func planForUntranscribable(micSamples: Int, systemSamples: Int) -> Plan {
        plan(isRecording: true, isStarting: false, micSamples: micSamples, systemSamples: systemSamples)
    }

    /// What a transcript owes when the store refuses it. `HistoryService.save`
    /// returns nil on a degraded store and on a failed context save; the
    /// meeting path had no `else` for that and logged success anyway.
    enum TranscriptPlan: Equatable { case nothingToWrite, writeOut }

    static func planForUnsavedTranscript(chars: Int) -> TranscriptPlan {
        chars > 0 ? .writeOut : .nothingToWrite
    }

    static func transcriptFileName(stamp: String) -> String {
        "meeting-\(stamp)-transcript.txt"
    }

    /// "me" and "them" rather than "mic" and "system": the person opening the
    /// folder is looking for their own voice or the other side's.
    static func fileNames(stamp: String) -> (mic: String, system: String) {
        ("meeting-\(stamp)-me.wav", "meeting-\(stamp)-them.wav")
    }
}
