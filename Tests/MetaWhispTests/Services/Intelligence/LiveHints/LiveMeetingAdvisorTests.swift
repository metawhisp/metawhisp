import XCTest
@testable import MetaWhisp

/// The advisor: one live-hints session per meeting.
///
/// The advisor owns the session and nothing else — it builds it when the
/// recording starts, stops it when the recording ends, and gives back what
/// the meeting said.
@MainActor
final class LiveMeetingAdvisorTests: XCTestCase {

    // MARK: - The fakes

    /// A session that records what the advisor did with it.
    @MainActor
    final class FakeSession: LiveHintsSession {
        private(set) var started = false
        private(set) var stopped = false
        /// What the session gives back.
        var result = LiveHintsSessionResult(text: "Them: When can you send the proposal?",
                                             lineCount: 1,
                                             micOffset: 32_000,
                                             systemOffset: 16_000)

        func start() async { started = true }
        func stop() { stopped = true }
        func finalize() -> LiveHintsSessionResult {
            stopped = true
            return result
        }
    }

    /// The hints' switch, as the advisor reads it.
    private func setHintsEnabled(_ enabled: Bool) {
        let key = "liveMeetingAdviceEnabled"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(enabled, forKey: key)
        // The test puts the defaults back the way it found them.
        addTeardownBlock {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// An advisor with a fake session and an environment of fakes.
    private func makeAdvisor() -> (advisor: LiveMeetingAdvisor, session: FakeSession) {
        let advisor = LiveMeetingAdvisor()
        let session = FakeSession()
        advisor.environment = FakeLiveHintsEnvironment().environment()
        advisor.sessionBuilder = { _ in session }
        return (advisor, session)
    }

    /// Waits until the condition holds.
    private func waitUntil(_ condition: () -> Bool, timeout: Double = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - The lifecycle

    /// With the hints off, nothing is armed.
    func testWithTheHintsOffNothingIsArmed() async {
        setHintsEnabled(false)
        let (advisor, session) = makeAdvisor()

        await advisor.arm()

        XCTAssertFalse(advisor.isActive, "the advisor armed itself although the hints are off")
        XCTAssertFalse(session.started, "the session was started although the hints are off")
    }

    /// With the hints on, the session goes up.
    func testWithTheHintsOnTheSessionIsBuiltAndStarted() async {
        setHintsEnabled(true)
        let (advisor, session) = makeAdvisor()

        await advisor.arm()

        XCTAssertTrue(advisor.isActive, "the advisor did not arm")
        XCTAssertTrue(session.started, "the session was not started")
    }

    /// The recording stops: the session goes down.
    func testTheRecordingStoppingTakesTheSessionDown() async {
        setHintsEnabled(true)
        let (advisor, session) = makeAdvisor()
        await advisor.arm()

        advisor.disarm()

        XCTAssertFalse(advisor.isActive, "the advisor is still active")
        XCTAssertTrue(session.stopped, "the session was not stopped")
    }

    /// The meeting ends: the advisor gives back what the session heard.
    func testTheMeetingEndingGivesBackWhatTheSessionHeard() async {
        setHintsEnabled(true)
        let (advisor, session) = makeAdvisor()
        await advisor.arm()

        let result = advisor.finalize()

        XCTAssertEqual(result?.text, "Them: When can you send the proposal?")
        XCTAssertEqual(result?.partialCount, 1, "the line count is not the number of lines")
        XCTAssertEqual(result?.micOffsetAtFinalize, 32_000)
        XCTAssertEqual(result?.sysOffsetAtFinalize, 16_000)
        XCTAssertTrue(session.stopped, "the session was not stopped")
        XCTAssertFalse(advisor.isActive, "the advisor is still active")
    }

    /// A meeting that never ran has nothing to give back.
    func testAMeetingThatNeverRanHasNothingToGiveBack() async {
        setHintsEnabled(true)
        let (advisor, _) = makeAdvisor()

        XCTAssertNil(advisor.finalize(), "the advisor invented a transcript")
    }

    /// Arming twice does not build a second session.
    func testArmingTwiceDoesNotBuildASecondSession() async {
        setHintsEnabled(true)
        let (advisor, session) = makeAdvisor()

        await advisor.arm()
        await advisor.arm()

        XCTAssertTrue(advisor.isActive)
        XCTAssertTrue(session.started)
    }

    // MARK: - The switch in the middle of the meeting

    /// The hints are turned off while the meeting runs: the session goes down
    /// at once (§6.16).
    func testTurningTheHintsOffDuringTheMeetingStopsTheSession() async {
        setHintsEnabled(true)
        let (advisor, session) = makeAdvisor()
        await advisor.arm()
        XCTAssertTrue(advisor.isActive, "the advisor did not arm")

        setHintsEnabled(false)
        await waitUntil { !advisor.isActive }

        XCTAssertFalse(advisor.isActive, "the hints stayed on after they were turned off")
        XCTAssertTrue(session.stopped, "the session was not stopped")
    }

    /// The same switch, seen from the session: the shortcut is taken back and
    /// the card goes away.
    func testTurningTheHintsOffDuringTheMeetingTakesTheShortcutBackAndHidesTheCard() async {
        setHintsEnabled(true)
        let fakes = FakeLiveHintsEnvironment()
        let advisor = LiveMeetingAdvisor()
        advisor.environment = fakes.environment()
        await advisor.arm()
        XCTAssertEqual(fakes.hotkey.registrations.count, 1, "the shortcut was not registered")

        setHintsEnabled(false)
        await waitUntil { fakes.hotkey.unregistered == 1 }

        XCTAssertEqual(fakes.hotkey.unregistered, 1, "the shortcut stayed registered")
        XCTAssertFalse(fakes.state.isVisible, "the card stayed up")
    }

    /// The hints are turned on while the meeting runs: they come up (§6.16).
    func testTurningTheHintsOnDuringTheMeetingArmsTheSession() async {
        setHintsEnabled(false)
        let (advisor, session) = makeAdvisor()
        await advisor.arm()
        XCTAssertFalse(advisor.isActive, "the advisor armed itself although the hints are off")

        setHintsEnabled(true)
        await waitUntil { advisor.isActive }

        XCTAssertTrue(advisor.isActive, "the hints did not come on during the meeting")
        XCTAssertTrue(session.started, "the session was not started")
    }

    /// The hints are turned on while no meeting runs: nothing is armed.
    func testTurningTheHintsOnOutsideAMeetingArmsNothing() async {
        setHintsEnabled(false)
        let (advisor, session) = makeAdvisor()

        setHintsEnabled(true)
        await waitUntil { advisor.isActive }
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(advisor.isActive, "the hints came up without a meeting")
        XCTAssertFalse(session.started, "the session was started without a meeting")
    }
}
