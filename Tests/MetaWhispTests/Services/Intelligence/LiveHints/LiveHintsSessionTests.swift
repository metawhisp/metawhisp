import Carbon.HIToolbox
import XCTest
@testable import MetaWhisp

/// The live hints of one meeting, wired to fakes.
///
/// These are the wiring tests: the session reads the two streams, the
/// shortcut is registered and taken back, the monthly minutes can run out,
/// and the advice service hears the meeting once a window — not once a line.
@MainActor
final class LiveHintsSessionTests: XCTestCase {

    /// Everything one test needs.
    @MainActor
    final class Harness {
        var fakes = FakeLiveHintsEnvironment()
        /// The session under test.
        lazy var session: LiveHintsMeeting = LiveHintsMeeting(environment: fakes.environment())

        var mic: FakeLiveHintsStream { fakes.mic }
        var system: FakeLiveHintsStream { fakes.system }
        var hotkey: FakeLiveHintsHotkey { fakes.hotkey }
        var advice: FakeLiveHintsAdvice { fakes.advice }
        var state: MeetingCoachState { fakes.state }
        var pro: FakeRoute { fakes.pro }
        var combo: LiveValueBox<MeetingHelpCombo> { fakes.combo }
        /// Turns the automatic answers on or off.
        ///
        /// The switch lives in the defaults, and the session watches it
        /// there: the change is seen as it happens.
        func setAutoOn(_ isOn: Bool) {
            fakes.defaults.set(isOn, forKey: fakes.autoAnswerKey)
        }
        /// Whether the app may take a shortcut at all.
        var globalInputEnabled: LiveValueBox<Bool> { fakes.globalInputEnabled }
        /// The time now. The tests move it by hand.
        var clock: LiveValueBox<Date> { fakes.clock }

        /// The engine the fake answers with.
        var engine: FakeLiveEngine {
            get { fakes.engine }
            set { fakes.engine = newValue }
        }

        /// How often the advice service hears the meeting.
        var adviceInterval: Duration {
            get { fakes.adviceInterval }
            set { fakes.adviceInterval = newValue }
        }

        /// The dictation pause windows.
        var pauseWindows: @MainActor @Sendable () -> [LiveSampleRange] {
            get { fakes.pauseWindows }
            set { fakes.pauseWindows = newValue }
        }

        /// The other side says something.
        func themSay(_ segments: [LiveCallFixture.Segment]) {
            system.append(LiveCallFixture.audio(segments))
        }

        /// The user says something.
        func meSay(_ segments: [LiveCallFixture.Segment]) {
            mic.append(LiveCallFixture.audio(segments))
        }

        /// Waits until the condition holds.
        func waitUntil(_ condition: () -> Bool, timeout: Double = 10) async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    /// A harness whose engine answers with the given text.
    private func makeHarness(text: String = "When can you send the proposal?",
                              adviceInterval: Duration = .seconds(30)) -> Harness {
        let harness = Harness()
        harness.engine = FakeLiveEngine(responder: { _ in FakeLiveEngine.result(text) })
        harness.adviceInterval = adviceInterval
        return harness
    }

    /// Two lines of the other side, far enough apart to be two lines.
    private let twoLines: [LiveCallFixture.Segment] = [
        .silence(1), .speech(1), .silence(3), .speech(1), .silence(2),
    ]

    // MARK: - The shortcut

    /// The session registers the shortcut with the combo the settings hold,
    /// and the overlay shows it.
    func testTheSessionRegistersTheShortcutAndTheOverlayShowsIt() async {
        let harness = makeHarness()
        await harness.session.start()

        XCTAssertEqual(harness.hotkey.registrations.count, 1, "the shortcut was not registered")
        XCTAssertEqual(harness.hotkey.registrations.first?.keyCode, 36)
        XCTAssertEqual(harness.hotkey.registrations.first?.modifiers, controlKey)
        XCTAssertEqual(harness.state.shortcutLabel, "⌃↩", "the overlay shows no shortcut")
    }

    /// The session takes the shortcut back when the meeting ends.
    func testTheSessionTakesTheShortcutBackWhenItStops() async {
        let harness = makeHarness()
        await harness.session.start()

        harness.session.stop()

        XCTAssertEqual(harness.hotkey.unregistered, 1, "the shortcut stayed registered")
        XCTAssertNil(harness.state.shortcutLabel, "the overlay still shows a shortcut")
        XCTAssertFalse(harness.state.isVisible, "the card stayed up")
    }

    /// A combo that changes while the meeting runs takes the old one back and
    /// registers the new one.
    func testAComboThatChangesWhileTheMeetingRunsIsRegisteredAgain() async {
        let harness = makeHarness()
        await harness.session.start()

        harness.combo.value = MeetingHelpCombo(keyCode: 31, modifiers: optionKey)
        await harness.waitUntil { harness.hotkey.registrations.count == 2 }

        XCTAssertEqual(harness.hotkey.registrations.count, 2, "the new combo was not registered")
        XCTAssertEqual(harness.hotkey.registrations.last?.keyCode, 31)
        XCTAssertEqual(harness.hotkey.registrations.last?.modifiers, optionKey)
        XCTAssertEqual(harness.hotkey.unregistered, 1, "the old combo was not taken back")
    }

    // MARK: - The global input

    /// The global input switch decides whether the app may take a shortcut
    /// at all: with it off, nothing is registered and the overlay shows no
    /// shortcut (§3.9).
    func testTheShortcutIsNotRegisteredWhenTheGlobalInputIsOff() async {
        let harness = makeHarness()
        harness.globalInputEnabled.value = false
        await harness.session.start()

        XCTAssertEqual(harness.hotkey.registrations.count, 0,
                       "the shortcut was registered although the global input is off")
        XCTAssertNil(harness.state.shortcutLabel,
                     "the overlay shows a shortcut although the global input is off")
    }

    /// The global input is turned off while the meeting runs: the shortcut
    /// goes back.
    func testTheShortcutIsTakenBackWhenTheGlobalInputGoesOff() async {
        let harness = makeHarness()
        await harness.session.start()
        XCTAssertEqual(harness.hotkey.registrations.count, 1)

        harness.globalInputEnabled.value = false
        await harness.waitUntil { harness.hotkey.unregistered == 1 }

        XCTAssertEqual(harness.hotkey.unregistered, 1, "the shortcut stayed registered")
        XCTAssertNil(harness.state.shortcutLabel, "the overlay still shows a shortcut")
    }

    /// The global input comes back while the meeting runs: the shortcut is
    /// registered again (§3.9).
    func testTheShortcutIsRegisteredAgainWhenTheGlobalInputComesBack() async {
        let harness = makeHarness()
        await harness.session.start()
        XCTAssertEqual(harness.hotkey.registrations.count, 1)

        harness.globalInputEnabled.value = false
        await harness.waitUntil { harness.hotkey.unregistered == 1 }

        harness.globalInputEnabled.value = true
        await harness.waitUntil { harness.hotkey.registrations.count == 2 }

        XCTAssertEqual(harness.hotkey.registrations.count, 2,
                       "the shortcut was not registered again")
        XCTAssertEqual(harness.state.shortcutLabel, "⌃↩",
                       "the overlay shows no shortcut")
    }

    /// The global input is off when the meeting starts, and comes back while
    /// it runs: the shortcut is registered then (§3.9).
    func testTheShortcutIsRegisteredWhenTheGlobalInputComesBackWhileTheMeetingRuns() async {
        let harness = makeHarness()
        harness.globalInputEnabled.value = false
        await harness.session.start()
        XCTAssertEqual(harness.hotkey.registrations.count, 0)

        harness.globalInputEnabled.value = true
        await harness.waitUntil { harness.hotkey.registrations.count == 1 }

        XCTAssertEqual(harness.hotkey.registrations.count, 1,
                       "the shortcut was not registered")
        XCTAssertEqual(harness.state.shortcutLabel, "⌃↩",
                       "the overlay shows no shortcut")
    }

    /// The registration failed: the session holds no shortcut, and the
    /// global input coming back tries again (§3.9).
    func testTheShortcutIsTakenAgainAfterAFailedRegistration() async {
        let harness = makeHarness()
        // The first registration fails: the shortcut is taken by another app.
        harness.hotkey.failuresLeft = 1
        await harness.session.start()

        XCTAssertEqual(harness.hotkey.registrations.count, 0,
                       "the shortcut was registered although the registration failed")
        XCTAssertNil(harness.state.shortcutLabel,
                     "the overlay shows a shortcut that was never taken")

        // The global input goes off, and it comes back: the shortcut is taken
        // again.
        harness.globalInputEnabled.value = false
        try? await Task.sleep(nanoseconds: 400_000_000)
        harness.globalInputEnabled.value = true
        await harness.waitUntil { harness.hotkey.registrations.count >= 1 }

        XCTAssertEqual(harness.hotkey.registrations.count, 1,
                       "the shortcut was not taken again after the failed registration")
        XCTAssertEqual(harness.state.shortcutLabel, "⌃↩",
                       "the overlay shows no shortcut")
    }

    /// The shortcut of the user changes while the automatic answers are
    /// paused: the line that names it shows the new shortcut at once (§3.6).
    func testThePausedLineFollowsTheShortcutOfTheUser() async {
        let harness = makeHarness()
        // The backend refuses: the automatic answers are paused.
        harness.pro.replies = [MeetingAnswerReply(status: 503, retryAfter: 30, text: nil)]
        await harness.session.start()

        harness.themSay([.silence(1), .speech(1), .silence(2)])
        await harness.waitUntil { harness.state.status?.contains("Automatic answers paused") == true }

        // The user sets another shortcut while the backoff runs.
        harness.combo.value = MeetingHelpCombo(keyCode: 31, modifiers: optionKey)
        await harness.waitUntil { harness.hotkey.registrations.count == 2 }
        await harness.waitUntil { harness.state.status == "Automatic answers paused — press ⌥O" }

        XCTAssertEqual(harness.state.status, "Automatic answers paused — press ⌥O",
                       "the line still names the shortcut of before")
    }

    /// The capture is restarted and the new buffer already holds a second of
    /// audio: the first sample of that buffer is the meeting minus that
    /// second, and the words of the question keep the time they were said
    /// at (§3.2).
    ///
    /// The words the user said after the question answer it — and they said
    /// them after the question, not before.
    func testTheReplacementBufferThatHoldsAudioKeepsTheTimeOfItsFirstSample() async {
        let harness = makeHarness()
        harness.setAutoOn(false)
        // The meeting is eight seconds old: the microphone carries it, and
        // the other side's channel is there from the start.
        harness.mic.append([Float](repeating: 0, count: 128_000))
        harness.system.append(LiveCallFixture.audio([.speech(3), .silence(2)]))
        await harness.session.start()
        // The other side's words are read: the tracker has them.
        await harness.waitUntil { harness.engine.callCount >= 1 }

        // The capture is restarted: the new buffer holds a second of audio
        // already.
        harness.system.replaceBuffer(leadingSilence: 0, alreadyHolding: 16_000)
        // The session sees the replacement and starts over with the new
        // buffer.
        await harness.waitUntil {
            harness.system.reads.contains { $0.from == 0 && $0.count == 16_000 }
        }

        // The other side asks a question, in the new buffer.
        harness.system.append(LiveCallFixture.audio([.speech(1), .silence(2)]))
        // The user answers it: three seconds of their own words.
        harness.mic.append(LiveCallFixture.audio([.speech(3)]))
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        harness.hotkey.press()
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        XCTAssertEqual(harness.pro.requests.count, 1, "the shortcut asked nobody")
        XCTAssertTrue(harness.pro.requests.first?.user.contains(MeetingAnswerPrompts.whatShouldISayPrompt) == true,
                      "the words of the user did not answer the question of the new buffer")
    }

    // MARK: - The answers

    /// A question of the other side is answered with the gated ask.
    func testAQuestionOfTheOtherSideIsAnsweredWithTheGatedAsk() async {
        let harness = makeHarness()
        await harness.session.start()

        harness.themSay([.silence(1), .speech(1), .silence(2)])
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        let request = harness.pro.requests.first
        XCTAssertNotNil(request, "the question called nobody")
        XCTAssertTrue(request?.user.contains("Heard in the meeting: \"When can you send the proposal?\"") == true,
                      "the gated ask did not quote the line")
        XCTAssertTrue(request?.user.contains("If this asks the user something") == true,
                      "the automatic check did not use the gated ask")
    }

    /// The shortcut asks for an answer to the line that was not answered.
    func testTheShortcutAsksForAnAnswerToTheLineThatWasNotAnswered() async {
        let harness = makeHarness()
        // Only the shortcut asks, so the request the test reads is its own.
        harness.setAutoOn(false)
        await harness.session.start()

        harness.themSay([.silence(1), .speech(1), .silence(2)])
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        harness.hotkey.press()
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        XCTAssertEqual(harness.pro.requests.count, 1, "the shortcut called nobody")
        XCTAssertTrue(harness.pro.requests.first?.user.contains("The user wants an answer to this:") == true,
                      "the shortcut did not answer the line")
    }

    // MARK: - The balance

    /// The monthly meeting minutes are gone: the live hints stop for this
    /// meeting and the card says why (§3.2).
    func testTheMonthlyMinutesRunningOutStopsTheLiveHintsAndSaysWhy() async {
        let harness = Harness()
        harness.engine = FakeLiveEngine(responder: { _ in
            throw FakeEngineError(description: "Monthly limit reached")
        })
        await harness.session.start()

        harness.themSay([.silence(1), .speech(1), .silence(2)])
        await harness.waitUntil { harness.state.status == MeetingAnswerStatus.balanceSpent }

        XCTAssertEqual(harness.state.status, MeetingAnswerStatus.balanceSpent,
                       "the card does not say that the minutes are gone")
        XCTAssertEqual(harness.hotkey.unregistered, 1, "the shortcut stayed registered")
        XCTAssertTrue(harness.state.isVisible, "the card went away — the line would be unseen")
    }

    func testBalanceHaltRejectsEveryManualAnswerEntryPoint() async {
        let harness = balanceHaltHarness()
        await harness.session.start()
        defer { harness.session.stop() }
        harness.meSay([.silence(1), .speech(21, rms: 0.08), .silence(2)])
        await harness.waitUntil { harness.advice.calls.count == 1 }
        XCTAssertEqual(harness.advice.calls.count, 1)
        harness.state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .action,
            provenance: .transcript, action: .questions,
            blocks: [.paragraph("What is the delivery deadline?")], createdAt: harness.clock.value))
        XCTAssertTrue(harness.state.canExpandLatest)
        let shortcut = harness.hotkey.onPress
        let help = harness.state.onHelp
        let action = harness.state.onAction
        let question = harness.state.onQuestion

        harness.meSay([.silence(1), .speech(21, rms: 0.08), .silence(2)])
        await harness.waitUntil { harness.state.status == MeetingAnswerStatus.balanceSpent }
        XCTAssertEqual(harness.state.status, MeetingAnswerStatus.balanceSpent)
        let engineCalls = harness.engine.callCount
        let proCalls = harness.pro.requests.count
        let cards = harness.state.answers
        let entries: [() -> Void] = [
            { shortcut?() }, { harness.hotkey.press() },
            { help?() }, { harness.state.helpPressed() },
            { action?(.questions) }, { harness.state.actionPressed(.questions) },
            { action?(.recap) }, { harness.state.actionPressed(.recap) },
            { action?(.more) }, { harness.state.actionPressed(.more) },
            { question?("What is already known?") },
            { harness.state.updateQuestionText("What is already known?"); harness.state.submitQuestion() }
        ]
        for entry in entries {
            harness.clock.value = harness.clock.value.addingTimeInterval(2)
            entry()
            try? await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(harness.engine.callCount, engineCalls)
            XCTAssertEqual(harness.pro.requests.count, proCalls)
            XCTAssertEqual(harness.state.status, MeetingAnswerStatus.balanceSpent)
        }
        XCTAssertEqual(harness.state.answers, cards)
        XCTAssertTrue(harness.state.isVisible)
        XCTAssertFalse(harness.state.canRequestAnswers)
        XCTAssertFalse(harness.state.canExpandLatest)
        harness.state.beginQuestionEditing()
        XCTAssertFalse(harness.state.isQuestionEditing)
        // A halted meeting cannot be rearmed by calling start again.
        await harness.session.start()
        XCTAssertEqual(harness.state.status, MeetingAnswerStatus.balanceSpent)
        XCTAssertEqual(harness.hotkey.registrations.count, 1)
    }

    func testBalanceHaltCancelsRunningAndPendingAutomaticAnswers() async {
        let harness = Harness()
        harness.adviceInterval = .milliseconds(50)
        harness.engine = FakeLiveEngine(responder: { index in
            if index < 2 { return FakeLiveEngine.result("Which deadline should the release follow?") }
            throw FakeEngineError(description: "Monthly limit reached")
        })
        let latch = FakeLatch()
        harness.pro.gate = { await latch.wait() }
        await harness.session.start()
        defer { latch.open(); harness.session.stop() }
        harness.themSay([.silence(1), .speech(1), .silence(3)])
        await harness.waitUntil { harness.pro.requests.count == 1 }
        XCTAssertEqual(harness.pro.requests.count, 1)
        harness.themSay([.silence(1), .speech(1), .silence(3)])
        await harness.waitUntil { harness.advice.calls.count == 2 }
        XCTAssertEqual(harness.advice.calls.count, 2)
        harness.themSay([.silence(1), .speech(1), .silence(3)])
        await harness.waitUntil { harness.state.status == MeetingAnswerStatus.balanceSpent }
        XCTAssertEqual(harness.state.status, MeetingAnswerStatus.balanceSpent)
        latch.open()
        harness.clock.value = harness.clock.value.addingTimeInterval(61)
        await harness.waitUntil({ harness.pro.requests.first?.wasCancelled == true }, timeout: 1)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.pro.requests.first?.wasCancelled, true)
        XCTAssertEqual(harness.pro.requests.count, 1)
        XCTAssertTrue(harness.state.answers.isEmpty)
        XCTAssertNil(harness.state.draft)
        XCTAssertFalse(harness.state.isThinking)
        XCTAssertEqual(harness.state.status, MeetingAnswerStatus.balanceSpent)
    }

    /// A memo already in flight must not launch its queued successor when
    /// the monthly balance halts the session before the first fold returns.
    func testBalanceHaltCancelsRunningMemoAndItsQueuedSuccessor() async {
        let harness = Harness()
        harness.setAutoOn(false)
        harness.adviceInterval = .milliseconds(50)
        let text = String(repeating: "The release checklist includes review and rollout steps. ", count: 80)
        harness.engine = FakeLiveEngine(responder: { index in
            guard index < 3 else { throw FakeEngineError(description: "Monthly limit reached") }
            return FakeLiveEngine.result("Update \(index). " + text)
        })
        harness.pro.replies = [
            MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The review is ready.**"),
            MeetingAnswerReply(status: 200, retryAfter: nil, text: "The release review is ready.")
        ]
        let gate = RequestGate()
        let unexpectedFold = expectation(description: "no memo model call after balance halt")
        unexpectedFold.isInverted = true
        await harness.session.start()
        defer { gate.open(); harness.session.stop() }

        harness.themSay([.silence(1), .speech(1), .silence(3)])
        await harness.waitUntil { harness.advice.calls.count == 1 }
        XCTAssertEqual(harness.advice.calls.count, 1)
        harness.state.updateQuestionText("What is ready for review?")
        harness.state.submitQuestion()
        await harness.waitUntil { harness.state.answers.count == 1 }
        XCTAssertEqual(harness.state.answers.count, 1, "the answer must establish the memo boundary")

        harness.pro.gate = {
            if harness.pro.requests.count == 2 {
                await gate.wait()
            } else {
                unexpectedFold.fulfill()
            }
        }
        // Each line exceeds the transcript window: the second starts a fold
        // of the first, and the third queues another while that fold waits.
        harness.themSay([.silence(1), .speech(1), .silence(3)])
        await harness.waitUntil { gate.waiterCount == 1 }
        XCTAssertEqual(gate.waiterCount, 1, "the first memo never reached the gate")
        harness.themSay([.silence(1), .speech(1), .silence(3)])
        await harness.waitUntil { harness.advice.calls.count == 3 }
        XCTAssertEqual(harness.advice.calls.count, 3, "the queued fold must have new transcript lines")
        XCTAssertEqual(harness.pro.requests.count, 2)

        harness.themSay([.silence(1), .speech(1), .silence(3)])
        await harness.waitUntil { harness.state.status == MeetingAnswerStatus.balanceSpent }
        XCTAssertEqual(harness.state.status, MeetingAnswerStatus.balanceSpent)
        gate.open()
        await fulfillment(of: [unexpectedFold], timeout: 0.3)

        XCTAssertEqual(harness.pro.requests.count, 2, "the queued memo reached the model after halt")
        XCTAssertEqual(harness.pro.requests.dropFirst().first?.wasCancelled, true,
                       "the running memo was not cancelled by the balance halt")
        XCTAssertEqual(harness.session.finalize().lineCount, 3, "halting must retain the accepted transcript")
    }

    func testBalanceHaltStartsNoStream() async {
        let harness = Harness()
        harness.setAutoOn(false)
        harness.engine = FakeLiveEngine(responder: { _ in
            throw FakeEngineError(description: "Monthly limit reached")
        })
        let route = HaltStreamRoute()
        var environment = harness.fakes.environment()
        environment.routes.pro = route
        let session = LiveHintsMeeting(environment: environment)
        await session.start()
        defer { session.stop() }
        let question = harness.state.onQuestion
        harness.themSay([.silence(1), .speech(1), .silence(2)])
        await harness.waitUntil { harness.state.status == MeetingAnswerStatus.balanceSpent }
        XCTAssertEqual(harness.state.status, MeetingAnswerStatus.balanceSpent)
        question?("What is the next step?")
        harness.state.updateQuestionText("What is the next step?")
        harness.state.submitQuestion()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(route.streams, 0)
        XCTAssertNil(harness.state.draft)
        XCTAssertEqual(harness.state.status, MeetingAnswerStatus.balanceSpent)
    }

    func testBalanceHaltStartsNoScreenCapture() async {
        let harness = Harness()
        harness.setAutoOn(false)
        harness.engine = FakeLiveEngine(responder: { _ in
            throw FakeEngineError(description: "Monthly limit reached")
        })
        var captures = 0
        var environment = harness.fakes.environment()
        environment.screenEnabled = { true }
        environment.captureScreen = { captures += 1; return "Private screen text" }
        let session = LiveHintsMeeting(environment: environment)
        await session.start()
        defer { session.stop() }
        let screen = harness.state.onScreen
        harness.themSay([.silence(1), .speech(1), .silence(2)])
        await harness.waitUntil { harness.state.status == MeetingAnswerStatus.balanceSpent }
        XCTAssertEqual(harness.state.status, MeetingAnswerStatus.balanceSpent)
        screen?()
        harness.clock.value = harness.clock.value.addingTimeInterval(2)
        harness.state.screenPressed()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(captures, 0)
        XCTAssertTrue(harness.pro.requests.isEmpty)
        XCTAssertEqual(harness.state.status, MeetingAnswerStatus.balanceSpent)
    }

    private func balanceHaltHarness() -> Harness {
        let harness = Harness()
        harness.adviceInterval = .milliseconds(50)
        harness.engine = FakeLiveEngine(responder: { index in
            if index == 0 {
                return FakeLiveEngine.result("The team is preparing the release checklist, the review schedule, and a detailed rollout plan for the next milestone.")
            }
            throw FakeEngineError(description: "Monthly limit reached")
        })
        return harness
    }

    // MARK: - The advice

    /// The advice service hears the lines of the window once — not once a
    /// line (§3.10).
    func testTheAdviceServiceHearsTheWindowOnceAndNotEveryLine() async {
        let harness = makeHarness(adviceInterval: .milliseconds(600))
        await harness.session.start()

        // Two lines of the other side, both finished inside one window.
        harness.themSay(twoLines)
        await harness.waitUntil { harness.advice.calls.count >= 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(harness.advice.calls.count, 1, "the advice service was called once per line")
        let text = harness.advice.calls.first?.text ?? ""
        XCTAssertEqual(text.components(separatedBy: "Them:").count - 1, 2,
                       "the advice service did not hear both lines")
        XCTAssertEqual(harness.advice.calls.first?.source, "meeting-live")

        // The next window has nothing new in it: nothing is sent.
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(harness.advice.calls.count, 1, "the advice service was called for an empty window")
    }

    /// Nothing was said: the advice service is not called at all.
    func testTheAdviceServiceIsNotCalledWhenNothingWasSaid() async {
        let harness = makeHarness(adviceInterval: .milliseconds(300))
        await harness.session.start()

        try? await Task.sleep(nanoseconds: 900_000_000)

        XCTAssertTrue(harness.advice.calls.isEmpty, "the advice service was called for nothing")
    }

    // MARK: - The shortcut waits for the question that is still coming

    /// The user presses the shortcut while the last words of the question are
    /// still being transcribed: the answer is for that question (§3.4).
    func testTheShortcutAnswersTheQuestionThatIsStillBeingTranscribed() async {
        let harness = makeHarness()
        harness.setAutoOn(false)
        // The engine is slow: the question's text comes two seconds in.
        harness.engine = FakeLiveEngine(responder: { _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return FakeLiveEngine.result("When can you send the proposal?")
        })
        await harness.session.start()

        harness.themSay([.silence(1), .speech(1), .silence(2)])
        // The question is closed acoustically after a second and a half; the
        // press comes before its text is known.
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        harness.hotkey.press()
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        XCTAssertTrue(harness.pro.requests.first?.user.contains("The user wants an answer to this:") == true,
                      "the shortcut did not answer the question that was still being transcribed")
    }

    // MARK: - The shortcut never waits for the microphone

    /// The user's own words are slow to come back — eight seconds of engine.
    /// The shortcut must not wait for them (§3.4).
    func testTheShortcutDoesNotWaitForTheMicrophone() async {
        let harness = makeHarness()
        harness.setAutoOn(false)
        // The first call is the other side's question; every call after it is
        // the user's own side, and it takes eight seconds.
        harness.engine = FakeLiveEngine(responder: { index in
            if index == 0 { return FakeLiveEngine.result("When can you send the proposal?") }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            return FakeLiveEngine.result("the user's own words")
        })
        await harness.session.start()

        // The other side asks something, and the user answers.
        harness.themSay([.silence(1), .speech(1), .silence(2)])
        harness.meSay([.silence(1), .speech(1), .silence(2)])
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        harness.hotkey.press()
        await harness.waitUntil({ harness.pro.requests.count >= 1 }, timeout: 3)

        XCTAssertEqual(harness.pro.requests.count, 1,
                       "the shortcut waited for the user's own words")
    }

    // MARK: - A transcription that was rejected

    /// A transcription the gate dropped is not a line: the question before it
    /// is not asked again.
    func testARejectedTranscriptionDoesNotAskThePreviousQuestionAgain() async {
        let harness = Harness()
        // The first question is a question; everything after it is an
        // artifact of the decoder, and the gate drops it.
        harness.engine = FakeLiveEngine(responder: { index in
            if index == 0 { return FakeLiveEngine.result("When can you send the proposal?") }
            return FakeLiveEngine.result("To be continued.")
        })
        await harness.session.start()

        harness.themSay([.silence(1), .speech(1), .silence(2)])
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        // The other side says something else, and the decoder answers with
        // an artifact.
        harness.themSay([.silence(3), .speech(1), .silence(2)])
        await harness.waitUntil { harness.engine.callCount >= 2 }
        try? await Task.sleep(nanoseconds: 300_000_000)

        // The spacing passes: the question before the artifact would be
        // checked again now.
        harness.clock.value = harness.clock.value.addingTimeInterval(MeetingAnswerService.automaticSpacing + 1)

        await harness.waitUntil({ harness.pro.requests.count >= 2 }, timeout: 3)

        XCTAssertEqual(harness.pro.requests.count, 1,
                       "the previous question was asked again after a rejected transcription")
    }

    // MARK: - The advice and the sentences

    /// Every sentence of the user's own side reaches the advice service: two
    /// sentences of one utterance are two lines (§3.10).
    func testEverySentenceOfTheUserReachesTheAdviceService() async {
        let harness = makeHarness(adviceInterval: .milliseconds(800))
        harness.setAutoOn(false)
        // One utterance, two sentences.
        harness.engine = FakeLiveEngine(responder: { _ in
            FakeLiveEngine.result("The budget is approved. Send the contract.",
                                  segments: [
                                    TranscriptionResult.Segment(text: "The budget is approved.",
                                                                start: 0, end: 1),
                                    TranscriptionResult.Segment(text: "Send the contract.",
                                                                start: 1.5, end: 2),
                                  ])
        })
        await harness.session.start()

        harness.meSay([.silence(1), .speech(2), .silence(2)])
        try? await Task.sleep(nanoseconds: 700_000_000)
        // The shortcut sends the batch of the user's own side out.
        harness.hotkey.press()

        await harness.waitUntil {
            harness.advice.calls.contains { $0.text.contains("Send the contract.") }
        }
        guard let call = harness.advice.calls.first(where: { $0.text.contains("Send the contract.") }) else {
            return XCTFail("the advice service did not hear the sentence")
        }
        XCTAssertTrue(call.text.contains("The budget is approved."),
                      "the first sentence of the utterance did not reach the advice service")
    }

    /// The fold of an old session is released after a new session started: it
    /// makes no call at all, and the new session's request still goes out
    /// (§6.15).
    ///
    /// The routes outlive a session: they hold no session state of their own,
    /// and the token of a request travels with the request. A fold of a
    /// meeting that is over must not borrow the token of the meeting that
    /// runs now.
    func testTheFoldOfAnOldSessionMakesNoCallAfterANewSessionStarted() async {
        let fakes = FakeLiveHintsEnvironment()
        let environment = fakes.environment()
        let gate = RequestGate()

        // The transcript of the old session: its fold waits at the gate
        // before it calls its provider.
        let oldToken = LiveHintsStopToken()
        let provider = environment.routes.makeMemoProvider()
        let oldTranscript = LiveMeetingTranscript(memoProvider: { previous, lines, token in
            await gate.wait()
            return await provider(previous, lines, token)
        }, stopToken: oldToken)

        // Fifteen lines of 400 rendered characters: the window is full, and
        // more than 2,000 characters fell out of it — a fold is due.
        let text = String(repeating: "a", count: 400)
        for index in 0..<15 {
            await oldTranscript.appendThem(text: text,
                                           startSample: index * 16_000,
                                           endSample: index * 16_000 + 16_000,
                                           rms: 0.05,
                                           isContinuation: false)
        }
        await oldTranscript.markAnswered()

        // The fold is on its way and waits at the gate.
        let deadline = Date().addingTimeInterval(5)
        while gate.waiterCount == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(gate.waiterCount, 1, "the fold of the old session never started")

        // The old meeting ends.
        oldToken.stop()

        // The new session starts on the same routes.
        let session = LiveHintsMeeting(environment: environment)
        await session.start()
        fakes.system.append(LiveCallFixture.audio([.silence(1), .speech(1), .silence(2)]))
        let waitDeadline = Date().addingTimeInterval(10)
        while fakes.pro.requests.count == 0, Date() < waitDeadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(fakes.pro.requests.count, 1, "the new session asked nobody")

        // The old fold is released now.
        gate.open()
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(fakes.pro.requests.count, 1,
                       "the fold of the old session reached the backend")
    }

    // MARK: - The end of the meeting

    /// The meeting ends: the session gives back what it heard.
    func testTheSessionGivesBackTheTranscriptOfTheMeeting() async {
        let harness = makeHarness()
        await harness.session.start()

        harness.themSay([.silence(1), .speech(1), .silence(2)])
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        let result = harness.session.finalize()

        XCTAssertEqual(result.lineCount, 1, "the meeting was not heard")
        XCTAssertTrue(result.text.contains("Them: When can you send the proposal?"),
                      "the transcript does not hold the question")
        XCTAssertEqual(harness.hotkey.unregistered, 1, "the shortcut stayed registered")
    }

    // MARK: - The channel that joined late

    /// The system audio joins the meeting a minute late: the silence of the
    /// minute it missed sits at the front of its buffer. The request for the
    /// question must read the question — not the silence before it (§3.2).
    func testALateSystemChannelReadsTheQuestionAndNotTheSilenceBeforeIt() async {
        let harness = makeHarness()
        // The channel joined a minute late.
        harness.system.joinLate(afterSamples: 960_000)
        await harness.session.start()

        harness.system.append(LiveCallFixture.audio([.speech(1), .silence(2)]))
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        XCTAssertFalse(harness.system.reads.isEmpty, "the system stream was never read")
        for read in harness.system.reads {
            XCTAssertGreaterThan(read.rms, 0,
                                 "a read of the system stream brought the silence of the minute it missed")
        }
    }

    /// The same channel: the question keeps the timestamps of the meeting, so
    /// the words the user said before the channel joined do not answer it
    /// (§3.2).
    func testALateSystemChannelKeepsTheTimestampsOfTheMeeting() async {
        let harness = makeHarness()
        harness.setAutoOn(false)
        // The channel joined a minute late.
        harness.system.joinLate(afterSamples: 960_000)
        await harness.session.start()

        // The user says something at the 30th second of the meeting — a
        // minute before the other side's question.
        harness.mic.append(LiveCallFixture.audio([.silence(30), .speech(2), .silence(2)]))
        // The other side asks at the 60th second.
        harness.system.append(LiveCallFixture.audio([.speech(1), .silence(2)]))
        await harness.waitUntil { harness.pro.requests.count >= 1 || harness.system.reads.count >= 1 }
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        harness.hotkey.press()
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        XCTAssertTrue(harness.pro.requests.first?.user.contains("The user wants an answer to this:") == true,
                      "the question of a late channel was answered by words said before it")
    }

    // MARK: - A stopped session owns nothing any more
    /// A session that was stopped never starts again: it does not take the
    /// shortcut and it does not arm the card (§6.15).
    func testAStoppedSessionDoesNotStartAgain() async {
        let harness = makeHarness()
        await harness.session.start()
        XCTAssertEqual(harness.hotkey.registrations.count, 1, "the shortcut was not registered")

        harness.session.stop()
        await harness.session.start()

        XCTAssertEqual(harness.hotkey.registrations.count, 1,
                       "a stopped session started again and took the shortcut")
        XCTAssertFalse(harness.state.isVisible, "a stopped session armed the card again")
    }

    /// An answer that comes back after the meeting ended belongs to no
    /// meeting: it must not land in the card the next meeting uses (§6.15).
    func testAnAnswerThatComesBackAfterTheSessionStoppedIsNotPublished() async {
        let harness = makeHarness()
        harness.setAutoOn(false)
        let latch = FakeLatch()
        harness.pro.gate = { await latch.wait() }
        await harness.session.start()

        harness.themSay([.silence(1), .speech(1), .silence(2)])
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        harness.hotkey.press()
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        // The meeting ends while the answer is still on its way.
        harness.session.stop()
        latch.open()
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(harness.state.answers.isEmpty,
                      "a stopped session published an answer into the card")
    }

    // MARK: - The dictation pause

    /// The words the user dictated are not the user answering: they never
    /// mark a question as answered (§3.4).
    func testTheDictationPauseIsNotCountedAsTheUserSpeaking() async {
        // The user's words are inside a dictation pause.
        let pause = LiveSampleRange(from: 0, to: 64_000)
        let harness = makeHarness()
        harness.setAutoOn(false)
        harness.pauseWindows = { [pause] }
        await harness.session.start()

        harness.meSay([.silence(1), .speech(3), .silence(2)])
        try? await Task.sleep(nanoseconds: 500_000_000)
        harness.themSay([.silence(1), .speech(1), .silence(2)])
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        harness.hotkey.press()
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        XCTAssertTrue(harness.pro.requests.first?.user.contains("The user wants an answer to this:") == true,
                      "the dictated words answered the question")
    }

    /// The same words outside a dictation pause do answer the question.
    func testTheUsersOwnSpeechOutsideAPauseAnswersTheQuestion() async {
        let harness = makeHarness()
        harness.setAutoOn(false)
        await harness.session.start()

        harness.meSay([.silence(1), .speech(3), .silence(2)])
        try? await Task.sleep(nanoseconds: 500_000_000)
        harness.themSay([.silence(1), .speech(1), .silence(2)])
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        harness.hotkey.press()
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        XCTAssertTrue(harness.pro.requests.first?.user.contains(MeetingAnswerPrompts.whatShouldISayPrompt) == true,
                      "the user's own speech did not answer the question")
    }

    // MARK: - A stopped session starts no new work

    /// The system capture is restarted in the middle of the meeting: the
    /// buffer and its padding are replaced. The other side has to go on, with
    /// the audio of the new buffer and the time of the meeting (§3.2).
    func testTheOtherSideGoesOnAfterTheSystemCaptureIsRestarted() async {
        let harness = makeHarness()
        harness.setAutoOn(false)
        await harness.session.start()

        // The channel joined a minute late: the silence of the minute it
        // missed sits at the front of its buffer. The microphone carries the
        // same minute — both sides of the transcript speak of one meeting.
        harness.system.joinLate(afterSamples: 960_000)
        harness.mic.append([Float](repeating: 0, count: 960_000))

        // The other side asks: the question is read from the buffer.
        harness.system.append(LiveCallFixture.audio([.speech(1), .silence(2)]))
        try? await Task.sleep(nanoseconds: 600_000_000)
        harness.hotkey.press()
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        // The user speaks while the capture is down.
        harness.mic.append(LiveCallFixture.audio([.silence(1), .speech(2), .silence(2)]))
        try? await Task.sleep(nanoseconds: 300_000_000)

        // The capture is restarted: the buffer and its padding are replaced.
        harness.system.replaceBuffer()
        // The other side asks again, in the new buffer.
        harness.system.append(LiveCallFixture.audio([.speech(1), .silence(2)]))
        try? await Task.sleep(nanoseconds: 600_000_000)

        harness.clock.value = harness.clock.value.addingTimeInterval(1.1)
        harness.hotkey.press()
        await harness.waitUntil { harness.pro.requests.count >= 2 }
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(harness.pro.requests.count, 2, "the shortcut did not ask again")
        // The newest question is the one of the new buffer, and the words the
        // user said before it do not answer it.
        XCTAssertTrue(harness.pro.requests.last?.user.contains("The user wants an answer to this:") == true,
                      "the other side did not go on after the capture was restarted")
    }

    /// The automatic answers go off and come back while a check runs: the
    /// line that waited goes away with the switch (§6.16).
    func testTheAutomaticAnswersThatGoOffAndOnAgainDropTheLineThatWaited() async {
        let harness = makeHarness()
        let latch = FakeLatch()
        harness.pro.gate = { await latch.wait() }
        await harness.session.start()

        // The other side asks: the check runs.
        harness.themSay([.silence(1), .speech(1), .silence(2)])
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        // The other side asks again: the line waits for the running check.
        harness.themSay([.silence(3), .speech(1), .silence(2)])
        try? await Task.sleep(nanoseconds: 800_000_000)

        // The switch goes off, and it comes back before the check is over.
        harness.setAutoOn(false)
        await harness.waitUntil { harness.state.autoAnswerOn == false }
        harness.setAutoOn(true)
        await harness.waitUntil { harness.state.autoAnswerOn == true }

        // The check is over: the line that waited must not be checked.
        harness.clock.value = harness.clock.value.addingTimeInterval(MeetingAnswerService.automaticSpacing + 1)
        latch.open()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(harness.pro.requests.count, 1,
                       "the waiting line was checked although the automatic answers went off")
    }

    /// The automatic answers go off and come back inside one poll, while a
    /// check runs: the line that waited goes away with the switch (§6.16).
    ///
    /// The switch is watched, not polled: the change is seen as it happens,
    /// so a switch that goes off and comes back before the next poll still
    /// drops the line that waits.
    func testTheAutomaticAnswersThatGoOffAndOnAgainInsideOnePollDropTheLineThatWaited() async {
        let harness = makeHarness()
        let latch = FakeLatch()
        harness.pro.gate = { await latch.wait() }
        await harness.session.start()

        // The other side asks: the check runs.
        harness.themSay([.silence(1), .speech(1), .silence(2)])
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        // The other side asks again: the line waits for the running check.
        harness.themSay([.silence(3), .speech(1), .silence(2)])
        try? await Task.sleep(nanoseconds: 800_000_000)

        // The switch goes off and comes back at once — inside one poll, and
        // well inside fifty milliseconds.
        harness.setAutoOn(false)
        harness.setAutoOn(true)
        // The change is seen: the card shows the switch as it is now.
        await harness.waitUntil { harness.state.autoAnswerOn == true }

        // The check is over: the line that waited must not be checked.
        harness.clock.value = harness.clock.value.addingTimeInterval(MeetingAnswerService.automaticSpacing + 1)
        latch.open()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(harness.pro.requests.count, 1,
                       "the waiting line was checked although the automatic answers went off")
    }

    /// The shortcut waits for the text of a question that is still being
    /// transcribed. The meeting ends while it waits: the answer never goes
    /// out (§6.15).
    func testAShortcutThatWaitsForTheTextOfAQuestionMakesNoCallAfterTheStop() async {
        let harness = makeHarness()
        await harness.session.start()

        // The first question is over: the transcript holds it.
        harness.themSay([.silence(1), .speech(1), .silence(2)])
        await harness.waitUntil { harness.pro.requests.count >= 1 }

        // The other side starts a new question: its text is not known yet.
        harness.themSay([.silence(3), .speech(3)])
        try? await Task.sleep(nanoseconds: 600_000_000)

        // The shortcut is pressed while the question is still being
        // transcribed: it waits for the words.
        harness.hotkey.press()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // The meeting ends while the shortcut waits.
        harness.session.stop()
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertEqual(harness.pro.requests.count, 1,
                       "the shortcut of a stopped session asked the model")
    }

    /// The monthly minutes of the old meeting run out after the new meeting
    /// took the shortcut: the new registration stays (§6.15).
    func testTheLateBalanceFailureOfAnOldSessionDoesNotTakeTheNewSessionsShortcutAway() async {
        var fakes = FakeLiveHintsEnvironment()
        let gate = RequestGate()
        // The first call hangs and then reports that the monthly minutes are
        // gone. Every call after it is the next session's, and it answers.
        fakes.engine = FakeLiveEngine(responder: { index in
            if index == 0 {
                await gate.wait()
                throw FakeEngineError(description: "Monthly limit reached")
            }
            return FakeLiveEngine.result("When can you send the proposal?")
        })
        let environment = fakes.environment()

        let first = LiveHintsMeeting(environment: environment)
        await first.start()
        XCTAssertEqual(fakes.hotkey.registrations.count, 1, "the shortcut was not registered")

        // The other side asks: the engine call hangs.
        fakes.system.append(LiveCallFixture.audio([.silence(1), .speech(1), .silence(2)]))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, fakes.engine.callCount < 1 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        // The meeting ends, and the next one takes the shortcut.
        first.stop()
        let second = LiveHintsMeeting(environment: environment)
        await second.start()
        XCTAssertEqual(fakes.hotkey.registrations.count, 2, "the new session did not register")

        // The balance of the old meeting runs out now — far too late.
        gate.open()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(fakes.hotkey.unregistered, 1,
                       "the old session took the new session's shortcut away")
        XCTAssertNotNil(fakes.hotkey.shortcutLabel,
                        "the new session's shortcut is gone")
    }

    /// After the stop, every part keeps the count it had: nothing is asked
    /// any more (§6.15).
    func testAfterTheStopEveryPartKeepsTheCountItHad() async {
        let harness = makeHarness()
        await harness.session.start()

        // The other side asks, and the user answers: the engine is asked for
        // both sides, and the model for the question.
        harness.themSay([.silence(1), .speech(1), .silence(2)])
        harness.meSay([.silence(1), .speech(1), .silence(2)])
        await harness.waitUntil { harness.pro.requests.count >= 1 }
        await harness.waitUntil { harness.engine.callCount >= 1 }

        harness.session.stop()
        let engineCalls = harness.engine.callCount
        let requests = harness.pro.requests.count

        try? await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(harness.engine.callCount, engineCalls,
                       "the engine was asked after the stop")
        XCTAssertEqual(harness.pro.requests.count, requests,
                       "the model was asked after the stop")
    }
}

@MainActor
private final class HaltStreamRoute: MeetingAnswerRoute {
    let routeName = "halt-stream"
    let isAvailable = true
    private(set) var streams = 0

    func answer(system: String, user: String, deadlineMs: Int,
                stopToken: LiveHintsStopToken) async throws -> MeetingAnswerReply {
        XCTFail("The halted session must not call the completion route")
        return .init(status: 500, retryAfter: nil, text: nil)
    }

    func stream(system: String, user: String, deadlineMs: Int,
                stopToken: LiveHintsStopToken, handle: LiveHintsRequestHandle)
        -> AsyncStream<MeetingAnswerStreamEvent> {
        streams += 1
        return AsyncStream { continuation in
            continuation.yield(.delta("**A late answer.**"))
            continuation.yield(.end(.init(status: 200, retryAfter: nil, text: nil)))
            continuation.finish()
        }
    }
}
