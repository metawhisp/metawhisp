import Foundation

/// ITER-060.4 — cut long INTERIOR silence stretches out of meeting audio
/// BEFORE it reaches the decoder, with an exact piecewise time map back to
/// the original timeline.
///
/// Why: long silence is the substrate Whisper hallucinates over («Продолжение
/// следует…», word loops) — the 2026-08-07 audit measured the mostly-silent
/// system channel producing 2.2× the garbage. Edge trimming already exists
/// (`trimSilenceEdges`); this handles the gaps INSIDE a chunk, including the
/// digital-zero stretches `applyPauseMutes` injects into the mic channel.
///
/// Why the map (Codex design review 2026-08-08, critical): removing interior
/// audio compresses decoder time — every utterance timestamp after a cut
/// would land seconds early, silently breaking the Me/Them merge order and
/// the echo-dedup window. `TimeMap.toOriginalSeconds` restores each
/// boundary to the raw timeline; the merge and all downstream windows keep
/// working in original time.
///
/// Conservative by design so decode input stays natural speech (gate
/// calibration concern): only gaps > 2s are cut, and 0.25s of context is
/// kept on each side of every cut.
enum MeetingAudioSilenceCutter {

    struct Span: Equatable {
        /// Where this kept range starts on the COMPRESSED (decoded) timeline.
        let compressedStart: Double
        /// Where it starts on the ORIGINAL (raw recording) timeline.
        let originalStart: Double
        let duration: Double
    }

    struct TimeMap: Equatable {
        let spans: [Span]
        /// Total original duration — beyond-the-end queries clamp here.
        let originalDuration: Double

        /// Map a compressed-timeline second back to the original timeline.
        /// Monotonic; clamps at both ends; identity when nothing was cut.
        func toOriginalSeconds(_ t: Double) -> Double {
            guard let first = spans.first else { return min(max(t, 0), originalDuration) }
            if t <= first.compressedStart {
                return first.originalStart
            }
            for span in spans {
                if t < span.compressedStart + span.duration {
                    return span.originalStart + (t - span.compressedStart)
                }
            }
            let last = spans[spans.count - 1]
            return min(last.originalStart + last.duration, originalDuration)
        }
    }

    struct CutResult {
        let samples: [Float]
        let map: TimeMap
    }

    /// Frame size for the RMS scan: 100ms at 16kHz.
    private static let frameSamples = 1600
    /// Raw-RMS floor: matches the empty-room ambient ceiling used by the
    /// post-start sniff (AppDelegate) — below this a frame is «silent».
    private static let silenceRMS: Float = 0.004
    /// Only gaps LONGER than this are cut — natural inter-sentence pauses
    /// (≤2s) stay, keeping the decoder input natural speech.
    private static let minGapSec = 2.0
    /// Context kept on each side of a cut.
    private static let padSec = 0.25

    static func cut(samples: [Float], sampleRate: Double = 16000) -> CutResult {
        let total = samples.count
        let originalDuration = Double(total) / sampleRate
        guard total >= frameSamples else {
            let identity = TimeMap(
                spans: total > 0 ? [Span(compressedStart: 0, originalStart: 0, duration: originalDuration)] : [],
                originalDuration: originalDuration
            )
            return CutResult(samples: samples, map: identity)
        }

        // 1. Per-frame silence flags.
        let frameCount = total / frameSamples
        var silent = [Bool](repeating: false, count: frameCount)
        for f in 0 ..< frameCount {
            let start = f * frameSamples
            var sumSq: Float = 0
            for i in start ..< start + frameSamples {
                sumSq += samples[i] * samples[i]
            }
            silent[f] = sqrtf(sumSq / Float(frameSamples)) < silenceRMS
        }

        // 2. Silent runs longer than minGap → cut ranges (with pads kept).
        let minGapFrames = Int(minGapSec * sampleRate) / frameSamples
        let padSamples = Int(padSec * sampleRate)
        var cuts: [(start: Int, end: Int)] = []   // sample ranges to REMOVE
        var runStart: Int? = nil
        for f in 0 ... frameCount {
            let isSilent = f < frameCount ? silent[f] : false
            if isSilent {
                if runStart == nil { runStart = f }
            } else if let rs = runStart {
                let runFrames = f - rs
                if runFrames > minGapFrames {
                    // Keep pad on each side of the gap; tail frames beyond
                    // frameCount*frameSamples are never part of a run.
                    let cutStart = rs * frameSamples + padSamples
                    let cutEnd = f * frameSamples - padSamples
                    if cutEnd > cutStart {
                        cuts.append((cutStart, cutEnd))
                    }
                }
                runStart = nil
            }
        }
        // Trailing silent run reaching the end of the buffer.
        if let rs = runStart {
            let runFrames = frameCount - rs
            if runFrames > minGapFrames {
                let cutStart = rs * frameSamples + padSamples
                if total > cutStart {
                    cuts.append((cutStart, total))
                }
            }
        }

        guard !cuts.isEmpty else {
            let identity = TimeMap(
                spans: [Span(compressedStart: 0, originalStart: 0, duration: originalDuration)],
                originalDuration: originalDuration
            )
            return CutResult(samples: samples, map: identity)
        }

        // 3. Kept ranges = complement of cuts; concatenate + build the map.
        var kept: [(start: Int, end: Int)] = []
        var cursor = 0
        for c in cuts {
            if c.start > cursor { kept.append((cursor, c.start)) }
            cursor = c.end
        }
        if cursor < total { kept.append((cursor, total)) }

        var out: [Float] = []
        out.reserveCapacity(kept.reduce(0) { $0 + ($1.end - $1.start) })
        var spans: [Span] = []
        for range in kept {
            let compressedStart = Double(out.count) / sampleRate
            out.append(contentsOf: samples[range.start ..< range.end])
            spans.append(Span(
                compressedStart: compressedStart,
                originalStart: Double(range.start) / sampleRate,
                duration: Double(range.end - range.start) / sampleRate
            ))
        }
        return CutResult(samples: out, map: TimeMap(spans: spans, originalDuration: originalDuration))
    }
}
