import Combine
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachCapsuleTests: XCTestCase {
    func testTimerUsesAuthoritativeStartAndNeverGoesNegative() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(MeetingCoachCapsuleView.elapsed(startedAt: start, now: start.addingTimeInterval(758)), "12:38")
        XCTAssertEqual(MeetingCoachCapsuleView.elapsed(startedAt: start, now: start.addingTimeInterval(-1)), "0:00")
        XCTAssertEqual(MeetingCoachCapsuleView.elapsed(startedAt: nil, now: start), "0:00")
    }

    func testRecordingSurfaceSurvivesBalanceHaltAndEndsOnDisarm() {
        let state = MeetingCoachState()
        state.arm(generation: 7)
        state.setSpeaker(.them)
        XCTAssertTrue(state.recordingSurface)
        XCTAssertTrue(state.canRequestAnswers)
        state.haltForBalance()
        XCTAssertTrue(state.recordingSurface)
        XCTAssertFalse(state.canRequestAnswers)
        XCTAssertEqual(state.speaker, .unavailable)
        state.disarm()
        XCTAssertFalse(state.recordingSurface)
        state.arm(generation: 8)
        XCTAssertTrue(state.recordingSurface)
        XCTAssertEqual(state.recordingGeneration, 8)
    }

    func testSpeakerCombinesBothSidesAndHidesUnavailable() {
        XCTAssertEqual(MeetingCoachSpeaker.project(me: true, them: false), .me)
        XCTAssertEqual(MeetingCoachSpeaker.project(me: false, them: true), .them)
        XCTAssertEqual(MeetingCoachSpeaker.project(me: true, them: true), .both)
        XCTAssertEqual(MeetingCoachSpeaker.project(me: false, them: false), .quiet)
        XCTAssertNil(MeetingCoachSpeaker.unavailable.label)
    }

    func testWaveCoalescesAtTwentyHzAndNeverPublishesPanelState() {
        let state = MeetingCoachState()
        let wave = MeetingCoachWaveModel()
        var panelPublications = 0
        var wavePublications = 0
        let panelToken = state.objectWillChange.sink { panelPublications += 1 }
        let waveToken = wave.objectWillChange.sink { wavePublications += 1 }
        for tick in 0..<1000 {
            wave.receive(me: Float(tick % 50) / 50, them: Float(tick % 70) / 70,
                         speaker: .both, at: Double(tick) / 1000)
        }
        XCTAssertLessThanOrEqual(wavePublications, 20)
        XCTAssertGreaterThan(wavePublications, 10)
        XCTAssertEqual(panelPublications, 0)
        XCTAssertEqual(wave.bars.count, 6)
        withExtendedLifetime((panelToken, waveToken)) {}
    }

    func testWaveDeliversTheFinalCoalescedUnavailableValue() async throws {
        let wave = MeetingCoachWaveModel()
        let now = ProcessInfo.processInfo.systemUptime
        wave.receive(me: 1, them: 1, speaker: .both, at: now)
        XCTAssertFalse(wave.bars.isEmpty)
        wave.receive(me: 0, them: 0, speaker: .unavailable, at: now + 0.001)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(wave.bars.isEmpty)
    }

    func testBoundAudioPublishersDoNotRepublishAnswerStateAndRetainLatest() async throws {
        let state = MeetingCoachState()
        state.setSpeaker(.both)
        let me = CurrentValueSubject<Float, Never>(0)
        let them = CurrentValueSubject<Float, Never>(0)
        let wave = MeetingCoachWaveModel()
        wave.bind(me: me.eraseToAnyPublisher(), them: them.eraseToAnyPublisher(), state: state)
        var panelPublications = 0
        let token = state.objectWillChange.sink { panelPublications += 1 }
        for tick in 0..<100 { me.send(Float(tick) / 100); them.send(1) }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(wave.bars.max(), 14)
        XCTAssertEqual(panelPublications, 0)
        state.setSpeaker(.unavailable)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(wave.bars.isEmpty)
        withExtendedLifetime(token) {}
    }

    func testWaveFollowsLouderSideAndQuietIsFlat() {
        let wave = MeetingCoachWaveModel()
        wave.receive(me: 0.2, them: 0.9, speaker: .both, at: 0)
        let both = wave.bars
        wave.receive(me: 0, them: 0.9, speaker: .them, at: 1)
        XCTAssertEqual(wave.bars, both)
        wave.receive(me: 1, them: 1, speaker: .quiet, at: 2)
        XCTAssertEqual(Set(wave.bars), [2])
        wave.receive(me: 1, them: 1, speaker: .unavailable, at: 3)
        XCTAssertTrue(wave.bars.isEmpty)
    }
}
