import XCTest
@testable import MetaWhisp

/// D2 — the welcome, variant 1 (owner 2026-10-24): the approved words and five chips, and the MW mark forming from
/// a voice — a flat line, a wave that grows, the wave settling into M and W (mockup v6 `mwIntro`). Reduce Motion
/// shows the finished mark at once, and nothing moves, it only fades (H3).
final class WelcomeScreenTests: XCTestCase {

    // MARK: - The words

    func testTheWelcomeSaysVariantOne() {
        XCTAssertEqual(WelcomeScreen.title, "Speak instead of typing.")
        XCTAssertEqual(WelcomeScreen.subtitle, "Your words appear in the text field you’re in.")
        XCTAssertEqual(WelcomeScreen.chips.map(\.title), ["Dictation", "Translation", "Meeting notes", "MetaChat", "Tasks"])
        XCTAssertEqual(Set(WelcomeScreen.chips.map(\.symbol)).count, 5, "five different icons")
        XCTAssertEqual(WelcomeScreen.start, "Get started")
    }

    // MARK: - The mark

    /// The finished line runs through the points measured on the app icon.
    func testTheFinishedLineRunsThroughTheMeasuredPoints() {
        for point in MWMark.points {
            XCTAssertEqual(MWMark.y(atX: point.x), point.y, accuracy: 0.001)
        }
        XCTAssertEqual(MWMark.y(atX: (16.5 + 56.75) / 2), (180 + 15.9) / 2, accuracy: 0.001, "straight between two points")
    }

    func testTheMarkStartsAsAFlatLineThatFadesIn() {
        let frame = MWMark.frame(at: 0, reduceMotion: false)
        XCTAssertFalse(frame.done)
        XCTAssertEqual(frame.width, 2)
        XCTAssertEqual(frame.opacity, 0)
        XCTAssertLessThanOrEqual(frame.points.map { abs($0.y - 100) }.max() ?? 1, 0.6, "silence: a flat line")
        XCTAssertEqual(MWMark.frame(at: 0.3, reduceMotion: false).opacity, 1, accuracy: 0.001)
    }

    /// The voice: a wave that grows and thickens…
    func testAVoiceWaveGrowsOutOfTheLine() {
        let wave = MWMark.frame(at: 0.9, reduceMotion: false)
        XCTAssertFalse(wave.done)
        XCTAssertGreaterThan(wave.points.map { abs($0.y - 100) }.max() ?? 0, 60, "a wave of some height")
        XCTAssertGreaterThan(wave.width, 2)
        XCTAssertLessThanOrEqual(wave.width, 7)
    }

    /// …settling into the finished mark, which it reaches at 1.8 s.
    func testTheWaveSettlesIntoTheMark() {
        let settling = MWMark.frame(at: 1.79, reduceMotion: false)
        XCTAssertFalse(settling.done)
        XCTAssertGreaterThan(settling.width, 20)
        for point in settling.points {
            XCTAssertEqual(point.y, MWMark.y(atX: point.x), accuracy: 1, "x \(point.x)")
        }
        let done = MWMark.frame(at: MWMark.duration, reduceMotion: false)
        XCTAssertTrue(done.done)
        XCTAssertEqual(done.width, MWMark.strokeWidth)
        XCTAssertEqual(done.opacity, 1)
    }

    /// H3 — Reduce Motion: the finished mark from the first frame.
    func testWithReduceMotionTheMarkIsFinishedAtOnce() {
        let frame = MWMark.frame(at: 0, reduceMotion: true)
        XCTAssertTrue(frame.done)
        XCTAssertEqual(frame.width, MWMark.strokeWidth)
        XCTAssertEqual(frame.opacity, 1)
    }

    /// H3 — Reduce Motion: what arrives fades in where it stands; nothing slides.
    func testWithReduceMotionNothingMovesItOnlyFades() {
        XCTAssertEqual(OnboardingMotion.offset(6, reduceMotion: true), 0)
        XCTAssertEqual(OnboardingMotion.offset(6, reduceMotion: false), 6)
    }

    /// The mark and the waves are pictures of a voice: VoiceOver skips them and reads the words.
    func testTheMarkAndTheWavesAreHiddenFromVoiceOver() throws {
        let code = try OnboardingWindowTests.codeLines(of: "Views/Windows/Onboarding/WelcomeScreen.swift")
        XCTAssertEqual(code.filter { $0.contains(".accessibilityHidden(true)") }.count, 2, "the mark and the waves")
    }
}
