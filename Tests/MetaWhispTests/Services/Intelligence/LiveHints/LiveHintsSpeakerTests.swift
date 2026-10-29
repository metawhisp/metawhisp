import XCTest
@testable import MetaWhisp

@MainActor
final class LiveHintsSpeakerTests: XCTestCase {
    func testSessionProjectsBothSidesThenExpiresStalledChannels() async throws {
        let fixture = FakeLiveHintsEnvironment()
        let session = LiveHintsMeeting(environment: fixture.environment())
        await session.start()
        defer { session.stop() }
        fixture.mic.append(LiveCallFixture.audio([.speech(0.2)]))
        fixture.system.append(LiveCallFixture.audio([.speech(0.2)]))
        try await waitFor { fixture.state.speaker == .both }
        try await waitFor { fixture.state.speaker == .quiet }
        XCTAssertTrue(fixture.state.recordingSurface)
    }

    func testPauseExcludesMicAndReplacementClearsSystemFreshness() async throws {
        var fixture = FakeLiveHintsEnvironment()
        fixture.pauseWindows = { [LiveSampleRange(from: 0, to: 160_000)] }
        let session = LiveHintsMeeting(environment: fixture.environment())
        await session.start()
        defer { session.stop() }
        fixture.mic.append(LiveCallFixture.audio([.speech(0.2)]))
        fixture.system.append(LiveCallFixture.audio([.speech(0.2)]))
        try await waitFor { fixture.state.speaker == .them }
        fixture.system.replaceBuffer()
        try await waitFor { fixture.state.speaker == .quiet }
    }

    func testRetiredPollCannotPublishIntoAnotherGeneration() async throws {
        let fixture = FakeLiveHintsEnvironment()
        let session = LiveHintsMeeting(environment: fixture.environment())
        await session.start()
        fixture.system.append(LiveCallFixture.audio([.speech(0.2)]))
        try await waitFor { fixture.state.speaker == .them }
        session.stop()
        fixture.state.arm(generation: 2)
        fixture.state.setSpeaker(.me)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fixture.state.speaker, .me)
        XCTAssertEqual(fixture.state.recordingGeneration, 2)
    }

    func testNewSessionInTheSameRecordingClearsItsOldAnswers() {
        let state = MeetingCoachState()
        state.arm(generation: 8)
        state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .answer, provenance: .transcript,
            action: nil, blocks: [.headline("Previous session")], createdAt: Date()))
        state.disarm()
        XCTAssertFalse(state.recordingSurface)
        state.arm(generation: 8)
        XCTAssertTrue(state.recordingSurface)
        XCTAssertEqual(state.recordingGeneration, 8)
        XCTAssertTrue(state.answers.isEmpty)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}
