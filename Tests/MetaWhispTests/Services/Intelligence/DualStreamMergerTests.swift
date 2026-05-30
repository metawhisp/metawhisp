import XCTest
@testable import MetaWhisp

/// Pseudo-diarization merger tests. Reference adaptation: mic = .me,
/// system = .them; no mixing, no multichannel — just two segment lists
/// merged by timestamp. Pure functions, TDD red-first.
final class DualStreamMergerTests: XCTestCase {

    // MARK: - mergeStreams

    func test_merge_emptyMicReturnsSystem() {
        let system = [
            StreamSegment(text: "Hello there", startSec: 0.0, endSec: 1.5, speaker: .them),
            StreamSegment(text: "How are you", startSec: 2.0, endSec: 3.0, speaker: .them),
        ]
        let merged = DualStreamMerger.mergeStreams(mic: [], system: system)
        XCTAssertEqual(merged, system)
    }

    /// Both streams populated → merged output sorted ascending by startSec,
    /// regardless of which list each segment came from.
    func test_merge_interleavesByStartTime() {
        let mic = [
            StreamSegment(text: "first", startSec: 1.0, endSec: 2.0, speaker: .me),
            StreamSegment(text: "third", startSec: 5.0, endSec: 6.0, speaker: .me),
        ]
        let system = [
            StreamSegment(text: "second", startSec: 3.0, endSec: 4.0, speaker: .them),
        ]
        let merged = DualStreamMerger.mergeStreams(mic: mic, system: system)
        XCTAssertEqual(merged.map { $0.text }, ["first", "second", "third"])
        XCTAssertEqual(merged.map { $0.speaker }, [.me, .them, .me])
    }

    // MARK: - renderTranscript

    /// Each segment becomes a prefixed line: `Me: ...` / `Them: ...`.
    /// Different speakers in adjacent positions produce separate lines.
    func test_render_meAndThemPrefixes() {
        let segs = [
            StreamSegment(text: "hi", startSec: 0.0, endSec: 1.0, speaker: .me),
            StreamSegment(text: "hello", startSec: 1.5, endSec: 2.5, speaker: .them),
        ]
        let rendered = DualStreamMerger.renderTranscript(segs)
        XCTAssertEqual(rendered, "Me: hi\nThem: hello")
    }

    /// Consecutive same-speaker segments get a SINGLE prefix and are joined
    /// by a space. A switch to a different speaker starts a new line.
    /// This avoids transcripts that read like
    ///   Me: hello
    ///   Me: world
    /// when really the user just spoke through two adjacent chunks.
    func test_render_collapsesConsecutiveSameSpeaker() {
        let segs = [
            StreamSegment(text: "hello", startSec: 1.0, endSec: 2.0, speaker: .me),
            StreamSegment(text: "world", startSec: 2.0, endSec: 3.0, speaker: .me),
            StreamSegment(text: "hi", startSec: 5.0, endSec: 6.0, speaker: .them),
        ]
        let rendered = DualStreamMerger.renderTranscript(segs)
        XCTAssertEqual(rendered, "Me: hello world\nThem: hi")
    }

    func test_render_empty_isEmptyString() {
        XCTAssertEqual(DualStreamMerger.renderTranscript([]), "")
    }

    func test_render_single() {
        let segs = [StreamSegment(text: "solo", startSec: 0, endSec: 1, speaker: .them)]
        XCTAssertEqual(DualStreamMerger.renderTranscript(segs), "Them: solo")
    }

    /// The user's real daily pattern: the facilitator (Me) announces a name,
    /// then the named person (Them) reports. The "Me announces → Them reports"
    /// ORDER must survive merge+render — it's the foundation for later
    /// attributing the report's tasks to the announced person (2026-05-31).
    func test_render_dailyHandoff_preservesOrder() {
        let merged = DualStreamMerger.mergeStreams(
            mic: [StreamSegment(text: "Катя, твои задачи?", startSec: 0, endSec: 2, speaker: .me)],
            system: [StreamSegment(text: "Я закончила лендинг, сегодня API", startSec: 3, endSec: 6, speaker: .them)]
        )
        XCTAssertEqual(
            DualStreamMerger.renderTranscript(merged),
            "Me: Катя, твои задачи?\nThem: Я закончила лендинг, сегодня API"
        )
    }
}
