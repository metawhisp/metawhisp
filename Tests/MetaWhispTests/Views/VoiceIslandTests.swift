import AppKit
import Combine
import XCTest
@testable import MetaWhisp

/// ITER-078: the Island — what the voice window shows in each phase, as pure
/// data. The shapes and characters come from the design the owner chose on
/// 2026-09-28 (canvas "Jev agent interface", board 7).
final class VoiceIslandTests: XCTestCase {

    // MARK: - Stages and shapes

    /// A new question grows out of a seed; one asked while the island is
    /// already open goes straight to listening.
    func testListeningGrowsOutOfASeedOnlyWhenTheIslandAppears() {
        XCTAssertEqual(VoiceIsland.stage(for: .listening, elapsed: 0.1, appearing: true), .seed)
        XCTAssertEqual(VoiceIsland.stage(for: .listening, elapsed: VoiceIsland.seedDuration, appearing: true),
                       .listening)
        XCTAssertEqual(VoiceIsland.stage(for: .listening, elapsed: 0.1, appearing: false), .listening)
    }

    /// The question decodes out of the bits once it is transcribed, and then
    /// the island pinches into the thinking capsule.
    func testTheQuestionDecodesBeforeTheIslandThinks() {
        XCTAssertEqual(VoiceIsland.stage(for: .transcribing, elapsed: 5, appearing: false), .transcribing)
        XCTAssertEqual(VoiceIsland.stage(for: .thinking, elapsed: 0.2, appearing: false), .decoding)
        XCTAssertEqual(VoiceIsland.stage(for: .thinking, elapsed: VoiceIsland.decodeDuration, appearing: false),
                       .thinking)
        XCTAssertEqual(VoiceIsland.stage(for: .answered(text: "Yes."), elapsed: 0, appearing: false), .answer)
        XCTAssertEqual(VoiceIsland.stage(for: .error(text: "Too quiet."), elapsed: 0, appearing: false), .error)
        XCTAssertNil(VoiceIsland.stage(for: .idle, elapsed: 0, appearing: false))
    }

    /// The shapes of the design, in points.
    func testEachStageHasTheShapeOfTheDesign() {
        XCTAssertEqual(VoiceIsland.shape(for: .seed), VoiceIsland.Shape(width: 44, height: 14, cornerRadius: 7))
        XCTAssertEqual(VoiceIsland.shape(for: .listening), VoiceIsland.Shape(width: 300, height: 44, cornerRadius: 22))
        XCTAssertEqual(VoiceIsland.shape(for: .transcribing),
                       VoiceIsland.Shape(width: 668, height: 56, cornerRadius: 28))
        XCTAssertEqual(VoiceIsland.shape(for: .decoding), VoiceIsland.shape(for: .transcribing),
                       "the question decodes in the transcribing shape")
        XCTAssertEqual(VoiceIsland.shape(for: .thinking), VoiceIsland.Shape(width: 200, height: 40, cornerRadius: 20))
        XCTAssertEqual(VoiceIsland.shape(for: .error), VoiceIsland.Shape(width: 480, height: 60, cornerRadius: 30))
    }

    /// The answer panel is 480 wide and as tall as its content, within its
    /// bounds; past the top it scrolls.
    func testTheAnswerPanelFitsItsContentWithinItsBounds() {
        XCTAssertEqual(VoiceIsland.shape(for: .answer, answerContentHeight: 10).height, 88)
        XCTAssertEqual(VoiceIsland.shape(for: .answer, answerContentHeight: 200).height, 200)
        XCTAssertEqual(VoiceIsland.shape(for: .answer, answerContentHeight: 5_000).height, 360)
        XCTAssertEqual(VoiceIsland.shape(for: .answer, answerContentHeight: .nan).height, 88)
        XCTAssertEqual(VoiceIsland.shape(for: .answer, answerContentHeight: 200).width, 480)
    }

    /// Review of ITER-078: an error panel grows with its message — up to
    /// five lines — within its bounds, so the way to fix it is never cut.
    func testAnErrorPanelFitsItsMessage() {
        XCTAssertEqual(VoiceIsland.shape(for: .error, errorContentHeight: 10).height, 60)
        XCTAssertEqual(VoiceIsland.shape(for: .error, errorContentHeight: 92).height, 92)
        XCTAssertEqual(VoiceIsland.shape(for: .error, errorContentHeight: 1_000).height, 120)
        XCTAssertEqual(VoiceIsland.shape(for: .error, errorContentHeight: 92).width, 480)
    }

    /// Review of ITER-078: the island sits under the menu bar, and clear of
    /// the notch when a full-screen app hides the menu bar.
    func testTheIslandSitsUnderTheMenuBarAndClearOfTheNotch() {
        XCTAssertEqual(VoiceIsland.top(visibleTop: 1_000, screenTop: 1_037, safeAreaTop: 37, gap: 10), 990)
        XCTAssertEqual(VoiceIsland.top(visibleTop: 1_037, screenTop: 1_037, safeAreaTop: 32, gap: 10), 995)
        XCTAssertEqual(VoiceIsland.top(visibleTop: 1_037, screenTop: 1_037, safeAreaTop: 0, gap: 10), 1_027)
    }

    /// No shape is wider than the screen allows.
    func testAShapeFitsANarrowScreen() {
        XCTAssertEqual(VoiceIsland.shape(for: .transcribing).fitting(width: 600).width, 600)
        XCTAssertEqual(VoiceIsland.shape(for: .thinking).fitting(width: 600).width, 200)
    }

    // MARK: - The characters

    /// The wave is the last twelve levels of the voice, oldest first, each as
    /// one of seven glyphs; what is missing is silence.
    func testTheWaveFollowsTheVoice() {
        XCTAssertEqual(VoiceIsland.wave(levels: []), String(repeating: "▁", count: 12))
        XCTAssertEqual(VoiceIsland.wave(levels: [0, 0.5, 1]), String(repeating: "▁", count: 9) + "▁▄▇")
        let long = (0..<20).map { Float($0) / 19 }
        XCTAssertEqual(VoiceIsland.wave(levels: long).count, 12, "only the last twelve")
        XCTAssertEqual(VoiceIsland.wave(levels: long).last, "▇")
        XCTAssertEqual(VoiceIsland.wave(levels: [-1, 2, .nan]), String(repeating: "▁", count: 9) + "▁▇▁")
    }

    /// The question decodes out of bits: the part already resolved is the
    /// text, the rest is 0 and 1, spaces stay spaces, and a frame always shows
    /// the same bits.
    func testTheQuestionDecodesOutOfBits() {
        let text = "find five café apps"
        let none = VoiceIsland.decode(text, progress: 0, frame: 3)
        XCTAssertEqual(none.count, text.count)
        for (shown, original) in zip(none, text) {
            if original == " " { XCTAssertEqual(shown, " ") } else { XCTAssertTrue(shown == "0" || shown == "1") }
        }
        XCTAssertEqual(VoiceIsland.decode(text, progress: 1, frame: 3), text)
        let half = VoiceIsland.decode(text, progress: 0.5, frame: 3)
        XCTAssertTrue(half.hasPrefix("find five"), half)
        XCTAssertEqual(half, VoiceIsland.decode(text, progress: 0.5, frame: 3), "the same frame, the same bits")
        XCTAssertEqual(VoiceIsland.decode(text, progress: 2, frame: 3), text, "past the end is the text")
    }

    /// The transcribing stream and the thinking ticker are bits; the ticker
    /// has a gap after its 4th and 9th.
    func testTheStreamAndTheTickerAreBits() {
        let stream = VoiceIsland.bitStream(count: 40, frame: 7)
        XCTAssertEqual(stream.count, 40)
        XCTAssertTrue(stream.allSatisfy { $0 == "0" || $0 == "1" })
        XCTAssertNotEqual(stream, VoiceIsland.bitStream(count: 40, frame: 8), "the stream moves")
        let ticker = Array(VoiceIsland.ticker(frame: 5))
        XCTAssertEqual(ticker.count, 12)
        XCTAssertEqual(ticker[4], " ")
        XCTAssertEqual(ticker[9], " ")
        XCTAssertTrue(ticker.enumerated().allSatisfy { index, bit in [4, 9].contains(index) || bit == "0" || bit == "1" })
    }

    /// With Reduce Motion the characters do not cycle: the same frame is used
    /// whatever the time.
    func testReduceMotionStillsTheCharacters() {
        XCTAssertEqual(VoiceIsland.frame(at: 0.08, reduceMotion: false), 1)
        XCTAssertEqual(VoiceIsland.frame(at: 4.0, reduceMotion: false), 50)
        XCTAssertEqual(VoiceIsland.frame(at: 4.0, reduceMotion: true), 0)
    }
}

/// ITER-078: the presenter drives the Island over time — its stage, shape,
/// frame and the recent levels of the voice — from the voice question's
/// phases, a clock and the recorder's level.
@MainActor
final class VoiceIslandPresenterTests: XCTestCase {

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private func presenter(_ phases: CurrentValueSubject<VoiceQuestionState.Phase, Never>, clock: Clock,
                           level: @escaping () -> Float = { 0.5 },
                           reduceMotion: Bool = false) -> VoiceIslandPresenter {
        VoiceIslandPresenter(phases: phases.eraseToAnyPublisher(), level: level, reduceMotion: { reduceMotion },
                             now: { clock.now }, runsClock: false)
    }

    /// Hidden while idle; a question grows out of a seed, then listens and
    /// keeps the last twelve levels of the voice.
    func testAQuestionGrowsOutOfASeedAndFollowsTheVoice() {
        let phases = CurrentValueSubject<VoiceQuestionState.Phase, Never>(.idle)
        let clock = Clock()
        var level: Float = 0.2
        let island = presenter(phases, clock: clock, level: { level })
        XCTAssertNil(island.stage)
        XCTAssertNil(island.shape)
        phases.send(.listening)
        XCTAssertEqual(island.stage, .seed)
        XCTAssertEqual(island.shape, VoiceIsland.shape(for: .seed))
        clock.advance(0.4)
        island.tick()
        XCTAssertEqual(island.stage, .listening)
        for _ in 0..<20 {
            level = 0.9
            island.tick()
        }
        XCTAssertEqual(island.levels.count, VoiceIsland.waveColumns)
        XCTAssertEqual(island.levels.last, 0.9)
    }

    /// The question decodes out of the bits, then the island thinks; the
    /// answer panel is as tall as the answer the view measured.
    func testTheQuestionDecodesThenTheIslandThinksThenAnswers() {
        let phases = CurrentValueSubject<VoiceQuestionState.Phase, Never>(.listening)
        let clock = Clock()
        let island = presenter(phases, clock: clock)
        phases.send(.transcribing)
        XCTAssertEqual(island.stage, .transcribing)
        phases.send(.thinking)
        XCTAssertEqual(island.stage, .decoding)
        XCTAssertEqual(island.decodeProgress, 0, accuracy: 0.001)
        clock.advance(VoiceIsland.decodeDuration / 2)
        island.tick()
        XCTAssertEqual(island.decodeProgress, 0.5, accuracy: 0.01)
        clock.advance(VoiceIsland.decodeDuration)
        island.tick()
        XCTAssertEqual(island.stage, .thinking)
        phases.send(.answered(text: "Yes."))
        island.answerContentHeight = 150
        XCTAssertEqual(island.shape, VoiceIsland.shape(for: .answer, answerContentHeight: 150))
        phases.send(.idle)
        XCTAssertNil(island.shape)
    }

    /// Review of ITER-078: each answer is measured afresh — the panel never
    /// heads for the last answer's height first.
    func testEachAnswerIsMeasuredAfresh() {
        let phases = CurrentValueSubject<VoiceQuestionState.Phase, Never>(.answered(text: "First."))
        let island = presenter(phases, clock: Clock())
        island.answerContentHeight = 300
        phases.send(.listening)
        XCTAssertEqual(island.answerContentHeight, 0)
        phases.send(.answered(text: "Second."))
        XCTAssertEqual(island.shape?.height, VoiceIsland.answerHeights.lowerBound)
    }

    /// Review of ITER-078: the characters' frame moves only while bits are
    /// drawn, so the answer and the error are not redrawn for nothing.
    func testTheFrameMovesOnlyWhileBitsAreDrawn() {
        let phases = CurrentValueSubject<VoiceQuestionState.Phase, Never>(.answered(text: "Yes."))
        let clock = Clock()
        let island = presenter(phases, clock: clock)
        clock.advance(2)
        island.tick()
        XCTAssertEqual(island.frame, 0, "the answer draws no bits")
        phases.send(.transcribing)
        clock.advance(2)
        island.tick()
        XCTAssertGreaterThan(island.frame, 0)
    }

    /// A second question asked while the answer is still open does not start
    /// from a seed again.
    func testASecondQuestionInAnOpenIslandDoesNotStartFromASeed() {
        let phases = CurrentValueSubject<VoiceQuestionState.Phase, Never>(.answered(text: "Yes."))
        let island = presenter(phases, clock: Clock())
        phases.send(.listening)
        XCTAssertEqual(island.stage, .listening)
    }

    /// With Reduce Motion the question is shown at once and the characters do
    /// not cycle.
    func testReduceMotionShowsTheQuestionAtOnce() {
        let phases = CurrentValueSubject<VoiceQuestionState.Phase, Never>(.transcribing)
        let clock = Clock()
        let island = presenter(phases, clock: clock, reduceMotion: true)
        phases.send(.thinking)
        XCTAssertEqual(island.decodeProgress, 1)
        clock.advance(3)
        island.tick()
        XCTAssertEqual(island.frame, 0)
    }
}

/// Review of ITER-078: whether speaking again can help is decided where a
/// voice question fails, and the island says "Hold Right ⌘ to try again" only
/// then.
@MainActor
final class VoiceQuestionRetryTests: XCTestCase {
    func testOnlyAFailureThatSpeakingAgainCanFixSaysSo() {
        let state = VoiceQuestionState.shared
        defer { state.dismiss() }
        let first = state.startListening()
        state.failed(first, "Audio too quiet for voice question.", retryByVoice: true)
        XCTAssertTrue(state.errorRetriesByVoice)
        let second = state.startListening()
        XCTAssertFalse(state.errorRetriesByVoice, "a new question starts without it")
        state.failed(second, "Chat not available")
        XCTAssertFalse(state.errorRetriesByVoice)
    }
}

/// Review of ITER-078 (P1): the shadow window reaches above the menu bar by
/// its padding, and macOS would move it down; its frame is taken as given.
@MainActor
final class IslandShadowPanelTests: XCTestCase {
    func testTheShadowPanelKeepsItsFrame() {
        let panel = IslandShadowPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: true)
        let aboveTheScreen = NSRect(x: 100, y: 10_000, width: 400, height: 160)
        XCTAssertEqual(panel.constrainFrameRect(aboveTheScreen, to: NSScreen.main), aboveTheScreen)
    }
}

/// Review of ITER-078, round 2 (P1): the island's real windows. An error's
/// shake no longer fights the move to the error's shape, and a shake still
/// running never moves the next question. These tests show the island for a
/// moment on the main screen.
@MainActor
final class IslandWindowTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The island moves by animation. With the display asleep and the screen
    /// locked it never left its first shape (a gate run at night, 2026-09-28),
    /// so these tests need a screen that is awake and unlocked.
    private func requireAScreenInView() throws {
        try XCTSkipIf(NSScreen.main == nil, "needs a screen")
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        try XCTSkipIf(CGDisplayIsAsleep(CGMainDisplayID()) != 0 || session["CGSSessionScreenIsLocked"] as? Bool == true,
                      "needs a screen that is awake and unlocked")
    }

    func testAnErrorLandsWhereItBelongs() throws {
        try requireAScreenInView()
        let state = VoiceQuestionState.shared
        let controller = FloatingVoiceWindowController()
        defer { state.dismiss(); spin(0.2) }
        let question = state.startListening()
        spin(0.6)
        state.thinking(question, transcript: "find five apps")
        spin(1.2)
        state.failed(question, "Audio too quiet for voice question.", retryByVoice: true)
        spin(1.4)
        let shape = try XCTUnwrap(controller.presenter.shape)
        let card = try XCTUnwrap(controller.islandFrame)
        XCTAssertEqual(card, try XCTUnwrap(controller.targetFrame(for: shape)), "under the menu bar, centred")
        // The shadow window is the island with its 60 pt padding on every side.
        XCTAssertEqual(controller.shadowFrame, card.insetBy(dx: -60, dy: -60))
    }

    /// Review of ITER-078, round 3: a move that grows the island lands on its
    /// target before it formally ends. An error arriving then must not be
    /// shaken by that older move's end — only the latest move may shake.
    func testAnErrorRightAfterAMoveLandsWhereItBelongs() throws {
        try requireAScreenInView()
        let state = VoiceQuestionState.shared
        let controller = FloatingVoiceWindowController()
        defer { state.dismiss(); spin(0.2) }
        let question = state.startListening()
        spin(0.6)
        state.transcribing(question)
        let transcribing = try XCTUnwrap(controller.presenter.shape)
        let landed = Date().addingTimeInterval(1)
        while controller.islandFrame != controller.targetFrame(for: transcribing), Date() < landed { spin(0.005) }
        state.failed(question, "Transcription returned empty.", retryByVoice: true)
        try assertLandsOnTarget(controller, within: 1.4)
    }

    func testAShakeStillRunningNeverMovesTheNextQuestion() throws {
        try requireAScreenInView()
        let state = VoiceQuestionState.shared
        let controller = FloatingVoiceWindowController()
        defer { state.dismiss(); spin(0.2) }
        let question = state.startListening()
        spin(0.6)
        state.failed(question, "Too short — try holding longer.", retryByVoice: true)
        spin(0.55)
        state.dismiss()
        spin(0.05)
        state.startListening()
        // The new question's first shape is where it belongs at once, not at
        // the corner a shake left behind.
        spin(0.15)
        let seed = try XCTUnwrap(controller.presenter.shape)
        XCTAssertEqual(controller.islandFrame, try XCTUnwrap(controller.targetFrame(for: seed)))
        try assertLandsOnTarget(controller, within: 2)
    }

    /// Review of ITER-079, round 2 (P2-B): the window's own auto-dismiss is set
    /// for one question; a newer one that started in the meantime stays open.
    func testAnAutoDismissSetForAnOldQuestionLeavesTheNewOne() throws {
        try XCTSkipIf(NSScreen.main == nil, "needs a screen")
        let state = VoiceQuestionState.shared
        let controller = FloatingVoiceWindowController()
        defer { state.dismiss(); spin(0.2) }
        let old = state.startListening()
        state.failed(old, "Too short — try holding longer.", retryByVoice: true)
        spin(0.1)
        let new = state.startListening()
        spin(0.1)
        controller.scheduleAutoDismiss(seconds: 0.05, question: old)
        spin(0.3)
        XCTAssertTrue(state.isOpen(new), "the old question's timer leaves the new one open")
    }

    /// Waits until the island rests on its shape's target, or fails.
    private func assertLandsOnTarget(_ controller: FloatingVoiceWindowController, within seconds: TimeInterval,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(seconds)
        var card: NSRect?
        var target: NSRect?
        repeat {
            spin(0.05)
            card = controller.islandFrame
            target = controller.presenter.shape.flatMap { controller.targetFrame(for: $0) }
        } while card != target && Date() < deadline
        // Then it stays there: a late shake would still move it.
        spin(0.7)
        let shape = try XCTUnwrap(controller.presenter.shape, file: file, line: line)
        let final = try XCTUnwrap(controller.islandFrame, file: file, line: line)
        XCTAssertEqual(final, try XCTUnwrap(controller.targetFrame(for: shape), file: file, line: line),
                       "under the menu bar, centred", file: file, line: line)
        XCTAssertEqual(controller.shadowFrame, final.insetBy(dx: -60, dy: -60), file: file, line: line)
    }
}
