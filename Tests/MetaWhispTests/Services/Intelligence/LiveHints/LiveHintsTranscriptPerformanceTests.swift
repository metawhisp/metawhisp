import XCTest
@testable import MetaWhisp

@MainActor
final class LiveHintsTranscriptPerformanceTests: XCTestCase {
    func testThreeHourSessionKeepsAcceptedLinesChronologicalWithoutBackgroundRendering() async {
        let harness = LiveHintsSessionTests.Harness()
        await harness.session.start()
        defer { harness.session.stop() }
        let startedAt = harness.clock.value
        let originalLastText = "Delivery topic 1079 needs a decision before the planned review."
        let updatedLastText = "Delivery topic 1079 needs a decision before the pending review."
        let lastStart = 1079 * 160_000

        // One accepted line every ten seconds spans a three-hour meeting.
        for index in 0..<1080 {
            harness.clock.value = startedAt.addingTimeInterval(Double(index * 10))
            harness.session.remember(line(
                "Delivery topic \(index) needs a decision before the planned review.",
                at: index * 160_000))
        }
        // A delayed batch can add two sentences at the same earlier sample.
        harness.session.remember(line("I own delivery.", at: 80_000, speaker: .me))
        harness.session.remember(line("The scope is fixed.", at: 80_000, speaker: .me))
        XCTAssertEqual(harness.session.transcriptRenderCount, 0)

        // Equal-length edits replace the accepted text without a full render.
        XCTAssertEqual(originalLastText.count, updatedLastText.count)
        harness.clock.value = harness.clock.value.addingTimeInterval(1)
        harness.session.remember(line(updatedLastText, at: lastStart))
        harness.clock.value = harness.clock.value.addingTimeInterval(1)
        XCTAssertEqual(harness.session.transcriptRenderCount, 0)

        // Timing-only updates do not add another accepted line.
        harness.clock.value = harness.clock.value.addingTimeInterval(0.5)
        var timingUpdate = line(updatedLastText, at: lastStart)
        timingUpdate.endSample += 100
        harness.session.remember(timingUpdate)
        harness.clock.value = harness.clock.value.addingTimeInterval(0.5)
        XCTAssertTrue(harness.pro.requests.isEmpty)
        XCTAssertEqual(harness.session.transcriptRenderCount, 0)

        // A continuation replaces its original line in place.
        let newestStart = 1080 * 160_000
        harness.clock.value = harness.clock.value.addingTimeInterval(20)
        harness.session.remember(line(String(repeating: "x", count: 112), at: newestStart))
        harness.clock.value = harness.clock.value.addingTimeInterval(2)
        XCTAssertEqual(harness.session.transcriptRenderCount, 0)
        harness.session.remember(line(String(repeating: "x", count: 113), at: newestStart))
        harness.clock.value = harness.clock.value.addingTimeInterval(2)
        XCTAssertTrue(harness.pro.requests.isEmpty)
        XCTAssertEqual(harness.session.transcriptRenderCount, 0)

        let result = harness.session.finalize()
        let finalLines = result.text.components(separatedBy: "\n")
        XCTAssertEqual(harness.session.transcriptRenderCount, 1)
        XCTAssertEqual(result.lineCount, 1083)
        XCTAssertEqual(finalLines.count, 1083)
        XCTAssertEqual(finalLines.first,
                       "Them: Delivery topic 0 needs a decision before the planned review.")
        XCTAssertEqual(Set(finalLines[1...2]), ["Me: I own delivery.", "Me: The scope is fixed."])
        XCTAssertEqual(finalLines[1081], "Them: " + updatedLastText)
        XCTAssertEqual(finalLines.last, "Them: " + String(repeating: "x", count: 113))
        XCTAssertFalse(result.text.contains(originalLastText))
    }

    private func line(_ text: String, at start: Int,
                      speaker: LiveMeetingTranscript.Line.Speaker = .them) -> LiveMeetingTranscript.Line {
        .init(speaker: speaker, text: text, startSample: start, endSample: start + 16_000)
    }
}
