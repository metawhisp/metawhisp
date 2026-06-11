import Foundation

/// TR-12 (ITER-046 E3) — durable log of meeting text the pipeline DROPPED
/// (hallucination pattern filter, confidence gate, strip-emptied chunks).
///
/// Dictation already has a recovery path for suspect text (clipboard + ⌘V hint);
/// the meeting finalize pass had only NSLog — a filter false-positive lost real
/// speech with no recoverable trace. Dropped text now also lands in
/// `Application Support/MetaWhisp/suspect-transcripts.log`, newest at the end,
/// with a one-file `.old` rotation at ~2 MB so it can't grow unbounded.
enum SuspectTranscriptLog {

    static let maxBytes = 2 * 1024 * 1024
    private static let queue = DispatchQueue(label: "com.metawhisp.suspect-log", qos: .utility)

    private static var fileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MetaWhisp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("suspect-transcripts.log")
    }

    /// Append one dropped-text record. Fire-and-forget off the transcription
    /// path; never throws into it.
    static func append(_ text: String, reason: String, context: String) {
        queue.async { write(text, reason: reason, context: context, to: fileURL) }
    }

    /// Synchronous core — separated so tests can drive it against a temp file.
    static func write(_ text: String, reason: String, context: String, to url: URL) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] [\(reason)] [\(context)] \(trimmed)\n"
        rotateIfNeeded(url)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes else { return }
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
