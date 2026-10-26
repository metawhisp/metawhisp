import CoreGraphics
import Foundation

/// ITER-078 — the Island: what the voice window shows in each phase, as pure
/// data — its stage, its shape and the characters that move inside it — so
/// the view only draws. Ported from the design the owner chose on 2026-09-28
/// (canvas "Jev agent interface", board 7 "Form factor: Island").
enum VoiceIsland {
    enum Stage: Equatable {
        /// The island has just appeared: a small seed before it grows.
        case seed
        case listening
        case transcribing
        /// The transcript is in: the question decodes out of the bits.
        case decoding
        case thinking
        case answer
        case error
    }

    /// The island's outline, in points.
    struct Shape: Equatable {
        let width: CGFloat
        let height: CGFloat
        let cornerRadius: CGFloat

        /// The shape no wider than `limit`.
        func fitting(width limit: CGFloat) -> Shape {
            Shape(width: min(width, limit), height: height, cornerRadius: cornerRadius)
        }
    }

    /// How long the seed shows before the island grows.
    static let seedDuration: TimeInterval = 0.35
    /// How long the question takes to decode out of the bits.
    static let decodeDuration: TimeInterval = 0.9
    /// The characters move at 12.5 frames a second, as in the design.
    static let framesPerSecond = 12.5

    /// The answer panel is this wide, and as tall as its content within
    /// `answerHeights`; past the top it scrolls.
    static let answerWidth: CGFloat = 480
    static let answerHeights: ClosedRange<CGFloat> = 88...360
    /// The error panel grows with its message, up to five lines and the hint.
    static let errorHeights: ClosedRange<CGFloat> = 60...120

    /// Where the island's top edge sits: `gap` under the menu bar, and clear
    /// of the notch when a full-screen app hides the menu bar and the visible
    /// area reaches the top of the screen.
    static func top(visibleTop: CGFloat, screenTop: CGFloat, safeAreaTop: CGFloat, gap: CGFloat) -> CGFloat {
        min(visibleTop, screenTop - safeAreaTop) - gap
    }

    /// The stages whose characters move: the others need no clock.
    static func drawsBits(_ stage: Stage?) -> Bool {
        stage == .transcribing || stage == .decoding || stage == .thinking
    }

    /// The stage `elapsed` seconds into `phase`. A new question grows out of
    /// a seed only when the island `appearing`; nil means hidden.
    static func stage(for phase: VoiceQuestionState.Phase, elapsed: TimeInterval, appearing: Bool) -> Stage? {
        switch phase {
        case .idle: return nil
        case .listening: return appearing && elapsed < seedDuration ? .seed : .listening
        case .transcribing: return .transcribing
        case .thinking: return elapsed < decodeDuration ? .decoding : .thinking
        case .answered: return .answer
        case .error: return .error
        }
    }

    static func shape(for stage: Stage, answerContentHeight: CGFloat = 0, errorContentHeight: CGFloat = 0) -> Shape {
        switch stage {
        case .seed: return Shape(width: 44, height: 14, cornerRadius: 7)
        case .listening: return Shape(width: 300, height: 44, cornerRadius: 22)
        case .transcribing, .decoding: return Shape(width: 668, height: 56, cornerRadius: 28)
        case .thinking: return Shape(width: 200, height: 40, cornerRadius: 20)
        case .answer:
            let content = answerContentHeight.isFinite ? answerContentHeight : 0
            let height = min(max(content, answerHeights.lowerBound), answerHeights.upperBound)
            return Shape(width: answerWidth, height: height, cornerRadius: 28)
        case .error:
            let content = errorContentHeight.isFinite ? errorContentHeight : 0
            let height = min(max(content, errorHeights.lowerBound), errorHeights.upperBound)
            return Shape(width: 480, height: height, cornerRadius: 30)
        }
    }

    // MARK: - Characters

    static let waveGlyphs = Array("▁▂▃▄▅▆▇")
    static let waveColumns = 12
    /// The error's flat line: the wave with nothing in it.
    static let flatLine = "────────"

    /// The wave: the last `waveColumns` levels of the voice, oldest first,
    /// each 0...1 as one glyph. What is missing — before the first level, or
    /// not a number — is silence.
    static func wave(levels: [Float]) -> String {
        let recent = levels.suffix(waveColumns)
        let silence = String(repeating: waveGlyphs[0], count: waveColumns - recent.count)
        return silence + String(recent.map { level in
            let value = level.isFinite ? min(max(level, 0), 1) : 0
            return waveGlyphs[Int((value * Float(waveGlyphs.count - 1)).rounded())]
        })
    }

    /// The frame the characters show `seconds` into a stage. With Reduce
    /// Motion they do not cycle: always the first frame.
    static func frame(at seconds: TimeInterval, reduceMotion: Bool) -> Int {
        guard !reduceMotion, seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * framesPerSecond).rounded(.down))
    }

    /// The transcribing stream: `count` bits that move with `frame`.
    static func bitStream(count: Int, frame: Int) -> String {
        String((0..<max(0, count)).map { bit($0 + frame * 7, 29) })
    }

    /// The question decoding out of bits: the first `progress` of it is the
    /// text, the rest 0 and 1; spaces stay spaces, and a frame always shows
    /// the same bits.
    static func decode(_ text: String, progress: Double, frame: Int) -> String {
        let characters = Array(text)
        let share = progress.isFinite ? min(max(progress, 0), 1) : 1
        let resolved = Int((Double(characters.count) * share).rounded(.down))
        return String(characters.enumerated().map { index, character in
            index < resolved || character.isWhitespace ? character : bit(index, frame)
        })
    }

    /// The thinking ticker: twelve bits with a gap after the 4th and the 9th.
    static func ticker(frame: Int) -> String {
        String((0..<12).map { $0 == 4 || $0 == 9 ? " " : bit($0 + frame, 3) })
    }

    /// A bit fixed for `(a, b)`: the design's own hash, so a frame always
    /// shows the same bits.
    static func bit(_ a: Int, _ b: Int) -> Character {
        var h = (Int32(truncatingIfNeeded: a) &* 374_761_393) ^ (Int32(truncatingIfNeeded: b) &* 668_265_263)
        h = (h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 13)) &* 1_274_126_177
        h ^= Int32(bitPattern: UInt32(bitPattern: h) >> 16)
        return Double(UInt32(bitPattern: h)) / 4_294_967_296 < 0.5 ? "0" : "1"
    }
}
