import Combine
import XCTest
@testable import MetaWhisp

@MainActor
final class LiveHintsTranscriptTailTests: XCTestCase {
    func testFinalizeKeepsSameTimeMeSentencesInAcceptanceOrder() async {
        let h = LiveHintsSessionTests.Harness()
        await h.session.start()
        h.session.remember(line("The final checkpoint.", at: 48_000))
        h.session.remember(line("I own the delivery.", at: 16_000, speaker: .me))
        h.session.remember(line("I will send the report.", at: 16_000, speaker: .me))
        h.session.remember(line("The review begins.", at: 0))

        let result = h.session.finalize()

        XCTAssertEqual(result.lineCount, 4)
        XCTAssertEqual(result.text, """
            Them: The review begins.
            Me: I own the delivery.
            Me: I will send the report.
            Them: The final checkpoint.
            """)
        XCTAssertEqual(h.session.transcriptRenderCount, 1)
    }

    func testTailTakesTheLastFourByStartTimeRatherThanAcceptanceOrder() async {
        let h = LiveHintsSessionTests.Harness()
        await h.session.start()
        defer { h.session.stop() }
        XCTAssertTrue(h.state.transcriptTail.isEmpty)

        for index in [0, 5, 2, 4, 3, 1] {
            h.session.remember(line("Statement \(index).", at: index * 16_000))
        }

        XCTAssertEqual(h.state.transcriptTail.map(\.text), [
            "Statement 2.", "Statement 3.", "Statement 4.", "Statement 5."
        ])
        XCTAssertEqual(h.session.transcriptRenderCount, 0)
    }

    func testSameTimeMeSentencesRemainSeparateAndAContinuationReplacesOneLine() async {
        let h = LiveHintsSessionTests.Harness()
        await h.session.start()
        defer { h.session.stop() }
        h.session.remember(line("The review starts soon.", at: 0))
        h.session.remember(line("I own delivery.", at: 16_000, speaker: .me))
        h.session.remember(line("The scope is fixed.", at: 16_000, speaker: .me))
        h.session.remember(line("The next step", at: 32_000))
        h.session.remember(line("The next step is testing.", at: 32_000))

        XCTAssertEqual(h.state.transcriptTail.map(\.text), [
            "The review starts soon.", "I own delivery.", "The scope is fixed.", "The next step is testing."
        ])
        XCTAssertEqual(h.state.transcriptTail.map(\.speaker), [.them, .me, .me, .them])
    }

    func testAcceptanceNotifiesTheCardAndReadsTheUpdatedTailWithoutRenderingHistory() async {
        let h = LiveHintsSessionTests.Harness()
        await h.session.start()
        defer { h.session.stop() }
        var changes = 0
        let observation = h.state.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        h.session.remember(line("The release is ready.", at: 0))

        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(h.state.transcriptTail.map(\.text), ["The release is ready."])
        XCTAssertEqual(h.session.transcriptRenderCount, 0)
    }

    func testAcceptedThemUtteranceUpdatesTheTailThroughTheRealSession() async {
        let h = LiveHintsSessionTests.Harness()
        h.engine = FakeLiveEngine { _ in FakeLiveEngine.result("The review is complete.") }
        h.setAutoOn(false)
        await h.session.start()
        defer { h.session.stop() }
        h.themSay([.silence(1), .speech(1), .silence(2)])
        await h.waitUntil({ !h.state.transcriptTail.isEmpty }, timeout: 3)

        XCTAssertEqual(h.state.transcriptTail.map(\.text), ["The review is complete."])
        XCTAssertEqual(h.state.transcriptTail.first?.speaker, .them)
        XCTAssertTrue(h.engine.calls.allSatisfy { !$0.countUsage })
    }

    func testAcceptedMeBatchUpdatesTheTailThroughTheRealSession() async {
        let h = LiveHintsSessionTests.Harness()
        h.engine = FakeLiveEngine { _ in FakeLiveEngine.result("I will send the report.") }
        h.setAutoOn(false)
        await h.session.start()
        defer { h.session.stop() }
        h.meSay([.silence(1), .speech(21, rms: 0.08), .silence(2)])
        await h.waitUntil({ !h.state.transcriptTail.isEmpty }, timeout: 3)

        XCTAssertEqual(h.state.transcriptTail.map(\.text), ["I will send the report."])
        XCTAssertEqual(h.state.transcriptTail.first?.speaker, .me)
        XCTAssertTrue(h.engine.calls.allSatisfy { !$0.countUsage })
    }

    func testPublicationResumingAfterRetirementCannotNotifyOrChangeTheNextSession() async {
        let fakes = FakeLiveHintsEnvironment()
        let old = LiveHintsMeeting(environment: fakes.environment())
        await old.start()
        old.remember(line("The previous session.", at: 0))
        let gate = RequestGate()
        let stale = line("Late words from the previous session.", at: 16_000)
        let publication = Task {
            await gate.wait()
            old.remember(stale)
        }
        await waitUntil { gate.waiterCount == 1 }
        XCTAssertEqual(gate.waiterCount, 1)
        old.stop()
        let fresh = LiveHintsMeeting(environment: fakes.environment())
        await fresh.start()
        defer { fresh.stop() }
        fresh.remember(line("The current session.", at: 0))
        var changes = 0
        let observation = fakes.state.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        gate.open()
        await publication.value

        XCTAssertEqual(changes, 0)
        XCTAssertEqual(fakes.state.transcriptTail.map(\.text), ["The current session."])
    }

    func testAChangedRecordingGenerationRejectsAcceptedLinePublication() async {
        let fakes = FakeLiveHintsEnvironment()
        let generation = LiveValueBox(1)
        var environment = fakes.environment()
        environment.generation = { generation.value }
        let session = LiveHintsMeeting(environment: environment)
        await session.start()
        defer { session.stop() }
        session.remember(line("The accepted line.", at: 0))
        generation.value = 2
        var changes = 0
        let observation = fakes.state.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        session.remember(line("The stale line.", at: 16_000))

        XCTAssertEqual(changes, 0)
        XCTAssertEqual(fakes.state.transcriptTail.map(\.text), ["The accepted line."])
    }

    func testGlobalHelpShowsAnswersBeforeRequesting() async {
        let h = LiveHintsSessionTests.Harness()
        await h.session.start()
        defer { h.session.stop() }
        h.state.selectTab(.transcript)
        h.state.hidePanel()
        XCTAssertTrue(h.state.panelHidden)

        h.hotkey.press()

        XCTAssertFalse(h.state.panelHidden)
        XCTAssertEqual(h.state.selectedTab, .answers)
        XCTAssertTrue(h.state.canRequestAnswers)
    }

    private func line(_ text: String, at start: Int,
                      speaker: LiveMeetingTranscript.Line.Speaker = .them) -> LiveMeetingTranscript.Line {
        .init(speaker: speaker, text: text, startSample: start, endSample: start + 16_000)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
    }
}
