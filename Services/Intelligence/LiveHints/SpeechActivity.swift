import Foundation

/// Which samples of one stream carry speech.
///
/// The live hints close an utterance on silence, so the detector has to be
/// right about two things at once: a quiet room must not turn every breath
/// into a sentence, and a noisy room must not hide the speaker. Both come
/// from one number — the floor, the level the room itself is at. The floor is
/// the 20th percentile of the frame levels over the last 8 s, so up to a fifth
/// of the recent audio may be speech without the floor following it up. The
/// floor bootstraps from the first second of the call: until the call holds
/// 8 s of frames, the percentile runs over the frames there are.
///
/// A frame is speech when it reaches `max(0.003, 2.5 × floor)`: twice the
/// room, and never below an absolute level, so a dead-silent room still needs
/// a real voice. Room noise at a constant level therefore never becomes
/// speech — the floor sits at that level and the speech needs twice it.
///
/// The frames are 50 ms. The samples arrive in whatever batches the recorder
/// hands over, and the answer does not depend on the batching.
struct SpeechActivity {

    // MARK: - The constants

    /// Every stream of a meeting is captured at this rate.
    static let sampleRate = 16_000
    /// One frame is 50 ms.
    static let frameSamples = 800
    /// How long one frame lasts.
    static let frameDuration: Double = 0.05
    /// The floor looks back over 8 s.
    static let floorWindowFrames = 160
    /// The floor never leaves this range, however loud or quiet the room is.
    static let floorMinimum: Float = 0.0005
    static let floorMaximum: Float = 0.02
    /// A speech frame is at least this loud, whatever the floor says.
    static let speechLevelMinimum: Float = 0.003
    /// ... and at least this many times the floor.
    static let speechLevelFactor: Float = 2.5
    /// Two speech frames in a row are an onset.
    static let onsetFrames = 2
    /// The pre-roll kept before the onset, so the first syllable survives.
    static let preRollSamples = 4_000

    // MARK: - What the detector reports

    /// The start of a speech run.
    struct Onset: Equatable {
        /// Where the utterance starts: the run's first frame minus the pre-roll.
        let startSample: Int
        /// Where the speech itself starts.
        let speechStartSample: Int
    }

    /// One frame of the stream.
    struct Frame: Equatable {
        /// The frame's number, counting from the start of the stream.
        let index: Int
        /// The first sample of the frame.
        let startSample: Int
        /// The sample after the last one of the frame.
        let endSample: Int
        /// The level of the frame.
        let rms: Float
        /// True when the frame counts as speech.
        let isSpeech: Bool
        /// Set on the frame that completes a two-frame speech run.
        let onset: Onset?
    }

    // MARK: - The state

    /// The level of the room, as the detector sees it.
    private(set) var floor: Float = SpeechActivity.floorMinimum

    /// A floor the calibration safety raised. It outranks the computed one,
    /// which would otherwise fall back to the room level on the next frame.
    private var raisedFloor: Float?

    /// The levels of the recent frames, oldest first.
    private var levels: [Float] = []
    /// Samples that did not make a frame yet.
    private var pending: [Float] = []
    /// How many samples of `pending` are already framed.
    private var pendingOffset = 0
    /// How many samples the stream holds.
    private var totalSamples = 0
    /// How many frames have been produced.
    private var frameIndex = 0
    /// Speech frames in a row.
    private var speechRun = 0
    /// The first frame of the current speech run.
    private var runStartSample: Int?

    // MARK: - The detector

    /// Feeds samples and returns the frames they completed.
    mutating func append(_ samples: [Float]) -> [Frame] {
        guard !samples.isEmpty else { return [] }
        pending.append(contentsOf: samples)

        var frames: [Frame] = []
        while pending.count - pendingOffset >= Self.frameSamples {
            let slice = pending[pendingOffset ..< pendingOffset + Self.frameSamples]
            pendingOffset += Self.frameSamples
            frames.append(makeFrame(Array(slice)))
        }
        if pendingOffset >= pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingOffset = 0
        } else if pendingOffset > 4_096 {
            pending.removeFirst(pendingOffset)
            pendingOffset = 0
        }
        return frames
    }

    /// The calibration safety: what the detector heard as speech turned out to
    /// be the room, so the floor goes up to the level that was heard.
    mutating func raiseFloor(to rms: Float) {
        let raised = min(max(rms, Self.floorMinimum), Self.floorMaximum)
        raisedFloor = max(raisedFloor ?? 0, raised)
        floor = max(floor, raisedFloor ?? 0)
    }

    // MARK: - One frame

    private mutating func makeFrame(_ samples: [Float]) -> Frame {
        let startSample = totalSamples
        let endSample = totalSamples + samples.count
        totalSamples = endSample

        let rms = Self.rootMeanSquare(samples)
        levels.append(rms)
        if levels.count > Self.floorWindowFrames {
            levels.removeFirst(levels.count - Self.floorWindowFrames)
        }
        floor = max(Self.clampFloor(Self.percentile(0.2, of: levels)), raisedFloor ?? 0)

        let isSpeech = rms >= max(Self.speechLevelMinimum, Self.speechLevelFactor * floor)

        var onset: Onset?
        if isSpeech {
            if speechRun == 0 {
                runStartSample = startSample
            }
            speechRun += 1
            // The second frame of the run completes the onset.
            if speechRun == Self.onsetFrames, let runStart = runStartSample {
                onset = Onset(startSample: max(0, runStart - Self.preRollSamples),
                              speechStartSample: runStart)
            }
        } else {
            speechRun = 0
            runStartSample = nil
        }

        let frame = Frame(index: frameIndex,
                          startSample: startSample,
                          endSample: endSample,
                          rms: rms,
                          isSpeech: isSpeech,
                          onset: onset)
        frameIndex += 1
        return frame
    }

    // MARK: - The arithmetic

    /// The level of a frame.
    static func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    /// The `p`-th percentile of the values, linearly interpolated.
    static func percentile(_ p: Double, of values: [Float]) -> Float {
        guard !values.isEmpty else { return floorMinimum }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = Float(position - Double(lower))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// Keeps the floor inside its range.
    static func clampFloor(_ value: Float) -> Float {
        min(max(value, floorMinimum), floorMaximum)
    }
}
