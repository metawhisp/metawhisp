import Combine
import CoreGraphics
import Foundation

/// ITER-078 — drives the Island over time: the stage it is in, its shape, the
/// frame its characters show, how far the question has decoded, and the
/// recent levels of the voice. The window sizes itself from `shape`; the view
/// draws from all of it.
@MainActor
final class VoiceIslandPresenter: ObservableObject {
    @Published private(set) var stage: VoiceIsland.Stage?
    /// Nil while the island is hidden.
    @Published private(set) var shape: VoiceIsland.Shape?
    @Published private(set) var frame = 0
    /// 0...1: how much of the question has decoded out of the bits.
    @Published private(set) var decodeProgress: Double = 0
    /// The last `VoiceIsland.waveColumns` levels of the voice, oldest first.
    @Published private(set) var levels: [Float] = []
    /// The answer panel's content height at its width, measured by the view;
    /// each answer is measured afresh.
    @Published var answerContentHeight: CGFloat = 0 {
        didSet { if answerContentHeight != oldValue { refresh() } }
    }
    /// The error panel's content height, measured by the view the same way.
    @Published var errorContentHeight: CGFloat = 0 {
        didSet { if errorContentHeight != oldValue { refresh() } }
    }

    private var phase: VoiceQuestionState.Phase = .idle
    private var phaseStart: Date
    /// The island appeared with this phase: a question then grows out of a seed.
    private var appearing = false
    private let level: () -> Float
    private let reduceMotion: () -> Bool
    private let now: () -> Date
    private let runsClock: Bool
    private var clock: Timer?
    private var subscription: AnyCancellable?

    /// `level` is the recorder's current level, 0...1; `runsClock` false
    /// leaves the ticking to the caller (tests).
    init(phases: AnyPublisher<VoiceQuestionState.Phase, Never>, level: @escaping () -> Float,
         reduceMotion: @escaping () -> Bool, now: @escaping () -> Date = Date.init, runsClock: Bool = true) {
        self.level = level
        self.reduceMotion = reduceMotion
        self.now = now
        self.runsClock = runsClock
        phaseStart = now()
        subscription = phases.sink { [weak self] phase in
            MainActor.assumeIsolated { self?.phaseChanged(to: phase) }
        }
    }

    /// One tick of the island's clock, 12.5 a second while it shows: the
    /// voice's level while listening, then the stage, shape and frame.
    func tick() {
        if case .listening = phase {
            levels = Array((levels + [level()]).suffix(VoiceIsland.waveColumns))
        }
        refresh()
    }

    private func phaseChanged(to next: VoiceQuestionState.Phase) {
        guard next != phase || stage == nil else { return }
        appearing = stage == nil
        phase = next
        phaseStart = now()
        if case .listening = next { levels = [] }
        if case .answered = next {} else if answerContentHeight != 0 { answerContentHeight = 0 }
        if case .error = next {} else if errorContentHeight != 0 { errorContentHeight = 0 }
        refresh()
        runClockWhileShown()
    }

    private func refresh() {
        let elapsed = now().timeIntervalSince(phaseStart)
        let still = reduceMotion()
        let stage = VoiceIsland.stage(for: phase, elapsed: elapsed, appearing: appearing)
        if self.stage != stage { self.stage = stage }
        let shape = stage.map {
            VoiceIsland.shape(for: $0, answerContentHeight: answerContentHeight, errorContentHeight: errorContentHeight)
        }
        if self.shape != shape { self.shape = shape }
        // Only a stage that draws bits moves its frame: the others are not
        // redrawn for nothing.
        let frame = VoiceIsland.drawsBits(stage) ? VoiceIsland.frame(at: elapsed, reduceMotion: still) : 0
        if self.frame != frame { self.frame = frame }
        let decoded = still ? 1 : min(max(elapsed / VoiceIsland.decodeDuration, 0), 1)
        if case .thinking = phase, decodeProgress != decoded { decodeProgress = decoded }
    }

    private func runClockWhileShown() {
        guard runsClock else { return }
        if stage == nil {
            clock?.invalidate()
            clock = nil
        } else if clock == nil {
            clock = Timer.scheduledTimer(withTimeInterval: 1 / VoiceIsland.framesPerSecond, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }
}
