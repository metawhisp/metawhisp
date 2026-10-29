import Foundation

/// A window of a sample buffer.
///
/// The live hints read one utterance's worth of samples at a time, so they ask
/// for a window and get that window — not the tail of the buffer behind it.
/// The copy is clamped to what the buffer holds: a start before the beginning
/// counts from the beginning, and a window that reaches past the end stops at
/// the end.
enum SampleWindow {

    /// The samples `[from, from + count)` of `samples`.
    static func slice(_ samples: [Float], from index: Int, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let start = max(0, index)
        guard start < samples.count else { return [] }
        let end = start + min(count, samples.count - start)
        return Array(samples[start..<end])
    }
}
