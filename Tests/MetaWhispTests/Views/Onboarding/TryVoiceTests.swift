import AppKit
import SwiftUI
import XCTest
@testable import MetaWhisp

/// D4 — "Try your voice": one sentence through the step-1 practice, shown in the window and nowhere else (US3). The
/// box shows what the practice and the speech model are doing (mockup v6 `voiceLayer`): the model wait with its %,
/// a model that could not be got with Try again, the record button, the words, no speech. Esc cancels an attempt and
/// stays (C3); leaving the screen or closing the window gives the microphone back (C4); with Accessibility off the
/// copy never promises Right ⌘ (C10). A fake microphone and the shared practice engine; nothing records or pastes.
@MainActor
final class TryVoiceTests: XCTestCase {
    private var fixture: OnboardingFixture!

    override func setUpWithError() throws {
        fixture = try OnboardingFixture()
        fixture.permissions = OnboardingPermissions(microphone: .allowed, accessibility: true)
    }

    override func tearDownWithError() throws {
        fixture.tearDown()
    }

    /// A flow on the practice screen.
    private func practiceScreen() throws -> (OnboardingFlow, PracticeRecorder) {
        fixture.defaults.removeObject(forKey: OnboardingFlow.resumeKey)
        let flow = fixture.flow()
        flow.next()
        flow.next()
        XCTAssertEqual(flow.screen, .practice)
        return (flow, try XCTUnwrap(flow.practice))
    }

    private func box(_ phase: PracticeRecorder.Phase, _ model: ModelPreparer.State = .ready,
                     rightCommand: RightCommand = .tap) -> TryVoiceScreen.Box {
        TryVoiceScreen.box(phase: phase, model: model, rightCommand: rightCommand)
    }

    // MARK: - The speech model

    /// B1 — the quick model downloads from the first screen; here the wait shows how far it is.
    func testTheModelWaitShowsItsPercentAndTheSignIn() {
        XCTAssertEqual(box(.ready, .downloading(0.4)), .preparing(percent: 40))
        XCTAssertEqual(box(.ready, .loading), .preparing(percent: nil), "loaded weights take no %")
        XCTAssertTrue(TryVoiceScreen.showsSignIn(.preparing(percent: 40)))
        XCTAssertEqual(TryVoiceScreen.preparing, "Getting dictation ready…")
    }

    /// B2 — a model that could not be got: why, Try again, and the way for a Pro user.
    func testAModelThatCouldNotBeGotSaysWhyWithTryAgainAndTheSignIn() {
        let failed = box(.ready, .failed("The speech model didn't download."))
        XCTAssertEqual(failed, .modelProblem(title: "The speech model didn't download.", detail: nil))
        XCTAssertTrue(TryVoiceScreen.showsSignIn(failed))
    }

    /// B3 — low disk is said plainly, with the space the quick model needs; Try again is the user's to press.
    func testLowDiskIsSaidPlainly() {
        let full = box(.ready, .lowDisk)
        XCTAssertEqual(full, .modelProblem(title: "Not enough disk space for the speech model.",
                                           detail: "Free up about 500 MB, then try again."))
        XCTAssertTrue(TryVoiceScreen.showsSignIn(full))
    }

    func testTheSignInIsOnlyForTheModelWaitAndItsProblems() {
        for phase in [PracticeRecorder.Phase.ready, .listening, .transcribing, .result("Hi."), .noSpeech, .failed("x")] {
            XCTAssertFalse(TryVoiceScreen.showsSignIn(box(phase)), "\(phase)")
        }
    }

    /// An attempt under way, or its outcome, is never covered by the model's line.
    func testAnAttemptUnderWayOutranksTheModelsLine() {
        XCTAssertEqual(box(.listening, .downloading(0.9)), .recorder(listening: true, hint: "or tap Right ⌘ again"))
        XCTAssertEqual(box(.result("Hi."), .loading), .result("Hi."))
    }

    /// Codex step-2 #5 — a silent attempt, then the speech model could not be got: the model's problem shows, with
    /// its Try again, Sign in and Skip — "No speech detected" hid all three while Continue stayed off. With the
    /// model ready, no speech is what the box says (C2); while it is on its way, the wait.
    func testNoSpeechGivesWayToAModelThatCouldNotBeGot() {
        XCTAssertEqual(box(.noSpeech, .ready), .noSpeech)
        for model in [ModelPreparer.State.failed("The speech model didn't download."), .lowDisk] {
            let shown = box(.noSpeech, model)
            guard case .modelProblem = shown else { return XCTFail("\(model): \(shown)") }
            XCTAssertTrue(TryVoiceScreen.showsSkip(shown), "\(model)")
            XCTAssertTrue(TryVoiceScreen.showsSignIn(shown), "\(model)")
        }
        XCTAssertEqual(box(.noSpeech, .downloading(0.5)), .preparing(percent: 50))
    }

    /// The same through the practice: Right ⌘ starts it while the model downloads, nothing is said, then the
    /// download fails — and once the model is back, the attempt's own outcome shows again.
    func testASilentAttemptThenAFailedDownloadShowsTheModelsProblem() throws {
        fixture.microphone.recording = Array(repeating: Float(0.0001), count: 16_000)
        let (flow, practice) = try practiceScreen()
        flow.record()
        flow.record()
        XCTAssertEqual(practice.phase, .noSpeech)
        let failed = box(practice.phase, .failed("The speech model didn't download."))
        XCTAssertEqual(failed, .modelProblem(title: "The speech model didn't download.", detail: nil))
        XCTAssertTrue(TryVoiceScreen.showsSkip(failed))
        XCTAssertFalse(TryVoiceScreen.continueEnabled(practice.phase), "Skip is the way on")
        XCTAssertEqual(box(practice.phase, .ready), .noSpeech)
    }

    // MARK: - The practice

    func testThePracticesStatesInTheBox() {
        XCTAssertEqual(box(.ready), .recorder(listening: false, hint: "or tap Right ⌘"))
        XCTAssertEqual(box(.listening), .recorder(listening: true, hint: "or tap Right ⌘ again"))
        XCTAssertEqual(box(.transcribing), .transcribing)
        XCTAssertEqual(box(.result("Send the notes tomorrow morning.")), .result("Send the notes tomorrow morning."))
        XCTAssertEqual(box(.noSpeech), .noSpeech)
        XCTAssertEqual(box(.failed("Couldn't start the microphone.")), .failed("Couldn't start the microphone."))
        XCTAssertEqual(box(.waiting(CaptureArbiter.finishYourDictationFirst)), .waiting("Finish your dictation first"))
    }

    func testTheApprovedWords() {
        XCTAssertEqual(TryVoiceScreen.title, "Try your voice")
        XCTAssertEqual(TryVoiceScreen.resultHeading, "Your words, ready to use.")
        XCTAssertEqual(TryVoiceScreen.noSpeech, "No speech detected.")
        XCTAssertEqual(TryVoiceScreen.closer, "Try again a little closer to the microphone.")
        XCTAssertEqual(TryVoiceScreen.tryAgain, "Try again")
        XCTAssertEqual(TryVoiceScreen.example, "For example: “Send the notes tomorrow morning.”")
        XCTAssertEqual(TryVoiceScreen.label(.recorder(listening: false, hint: nil)), "Start recording")
        XCTAssertEqual(TryVoiceScreen.label(.recorder(listening: true, hint: nil)), "Listening… tap to stop")
        XCTAssertEqual(TryVoiceScreen.label(.transcribing), "Transcribing…")
    }

    /// C10 — with Accessibility off, the copy never promises Right ⌘; the practice itself still works.
    func testWithAccessibilityOffNothingPromisesRightCommand() {
        XCTAssertEqual(TryVoiceScreen.instruction(.tap), "Press the button or Right ⌘, say a sentence, then press again.")
        XCTAssertEqual(TryVoiceScreen.instruction(.unavailable), "Press the button, say a sentence, then press again.")
        XCTAssertEqual(box(.ready, rightCommand: .unavailable), .recorder(listening: false, hint: nil))
        XCTAssertEqual(box(.listening, rightCommand: .unavailable), .recorder(listening: true, hint: nil))
    }

    /// Push-to-talk: Right ⌘ is held, not tapped — the words say so; the toggle keeps its own.
    func testPushToTalkReadsHoldAndTheToggleReadsTap() {
        XCTAssertEqual(TryVoiceScreen.instruction(.hold), "Hold Right ⌘, say a sentence, release.")
        XCTAssertEqual(box(.ready, rightCommand: .hold), .recorder(listening: false, hint: "or hold Right ⌘"))
        XCTAssertEqual(box(.listening, rightCommand: .hold), .recorder(listening: true, hint: nil),
                       "no 'tap again' while the key is held")
        XCTAssertEqual(box(.ready, rightCommand: .tap), .recorder(listening: false, hint: "or tap Right ⌘"))
        XCTAssertEqual(box(.listening, rightCommand: .tap), .recorder(listening: true, hint: "or tap Right ⌘ again"))
    }

    /// Which words: Accessibility off — none for Right ⌘; on — the hotkey mode's.
    func testTheWordsFollowAccessibilityAndTheHotkeyMode() {
        XCTAssertEqual(RightCommand.current(accessibility: true, hotkeyMode: "toggle"), .tap)
        XCTAssertEqual(RightCommand.current(accessibility: true, hotkeyMode: "pushToTalk"), .hold)
        XCTAssertEqual(RightCommand.current(accessibility: false, hotkeyMode: "toggle"), .unavailable)
        XCTAssertEqual(RightCommand.current(accessibility: false, hotkeyMode: "pushToTalk"), .unavailable)
    }

    func testContinueOpensOnlyOnTheWords() {
        XCTAssertTrue(TryVoiceScreen.continueEnabled(.result("Hi.")))
        for phase in [PracticeRecorder.Phase.ready, .listening, .transcribing, .noSpeech, .failed("x"), .waiting("x")] {
            XCTAssertFalse(TryVoiceScreen.continueEnabled(phase), "\(phase)")
        }
    }

    /// The practice takes the microphone while its screen is up and gives it back when the screen goes, either way.
    func testThePracticeHoldsTheMicrophoneOnlyWhileItsScreenIsUp() throws {
        let (flow, _) = try practiceScreen()
        XCTAssertEqual(fixture.arbiter.refusal, CaptureArbiter.finishThePracticeFirst)
        flow.back()
        XCTAssertNil(flow.practice)
        XCTAssertNil(fixture.arbiter.refusal, "Back gives it back")
        flow.next()
        XCTAssertNotNil(flow.practice)
        flow.next()
        XCTAssertNil(fixture.arbiter.refusal, "Continue gives it back")
    }

    func testResumingOnThePracticeTakesTheMicrophone() throws {
        fixture.defaults.set(OnboardingFlow.Screen.practice.rawValue, forKey: OnboardingFlow.resumeKey)
        let flow = fixture.flow()
        XCTAssertNotNil(flow.practice)
        XCTAssertEqual(fixture.arbiter.refusal, CaptureArbiter.finishThePracticeFirst)
        flow.windowClosed()
    }

    /// C1 — a sentence: the words in the box, Continue open.
    func testASentenceShowsItsWordsInTheBox() throws {
        let (flow, practice) = try practiceScreen()
        flow.record()
        flow.record()
        fixture.settle(practice)
        XCTAssertEqual(box(practice.phase), .result("what is on my screen"))
        XCTAssertTrue(TryVoiceScreen.continueEnabled(practice.phase))
    }

    /// C2 — silence: no speech, and Try again records again.
    func testSilenceSaysNoSpeechAndTryAgainRecords() throws {
        fixture.microphone.recording = Array(repeating: Float(0.0001), count: 16_000)
        let (flow, practice) = try practiceScreen()
        flow.record()
        flow.record()
        XCTAssertEqual(box(practice.phase), .noSpeech)
        flow.record()
        XCTAssertEqual(practice.phase, .listening, "Try again is a new recording")
    }

    /// C3 — Esc while recording: cancelled, nothing kept, the screen stays.
    func testEscCancelsARecordingAndStaysOnTheScreen() throws {
        let (flow, practice) = try practiceScreen()
        flow.record()
        XCTAssertTrue(fixture.microphone.isRecording)
        flow.cancelAttempt()
        XCTAssertEqual(practice.phase, .ready)
        XCTAssertFalse(fixture.microphone.isRecording)
        XCTAssertEqual(flow.screen, .practice)
        XCTAssertEqual(fixture.engine.billed, [], "nothing was transcribed")
    }

    /// Esc with nothing under way changes nothing — it is never Back.
    func testEscWithNothingUnderWayDoesNothing() throws {
        let (flow, practice) = try practiceScreen()
        flow.cancelAttempt()
        XCTAssertEqual(practice.phase, .ready)
        XCTAssertEqual(flow.screen, .practice)
    }

    /// C4 — Back or a closed window while transcribing: the result is dropped, the microphone and the busy lease
    /// come back.
    func testBackOrCloseWhileTranscribingDropsTheResultAndGivesEverythingBack() throws {
        for leave in ["back", "close"] {
            fixture.engine.holds = true
            var busy: [Bool] = []
            fixture.arbiter.onPracticeBusy = { busy.append($0) }
            let (flow, practice) = try practiceScreen()
            flow.record()
            flow.record()
            fixture.settle(practice)
            XCTAssertTrue(fixture.engine.isWaiting, leave)
            if leave == "back" { flow.back() } else { flow.windowClosed() }
            fixture.engine.finish()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if case .result = practice.phase { XCTFail("\(leave): the late result landed") }
            XCTAssertNil(fixture.arbiter.refusal, leave)
            XCTAssertEqual(busy.last, false, "\(leave): the lease is idle")
            XCTAssertFalse(fixture.microphone.isRecording, leave)
        }
    }

    /// C7 — a dictation or a meeting already on: the practice waits and says so.
    func testADictationAlreadyOnMakesThePracticeWait() throws {
        fixture.busyElsewhere = true
        let (_, practice) = try practiceScreen()
        XCTAssertEqual(box(practice.phase), .waiting("Finish your dictation first"))
    }

    /// C9 — a long text scrolls inside the box; the box keeps its size.
    func testALongTextScrollsInsideTheBox() {
        let long = String(repeating: "Send the notes tomorrow morning and the slides on Friday. ", count: 12)
        for text in ["Hi.", long] {
            let view = NSHostingView(rootView: TryVoiceScreen.BoxView(box: .result(text), level: 0, record: {},
                                                                       tryAgain: {}, retryModel: {}, signIn: {},
                                                                       skip: {}))
            XCTAssertEqual(view.fittingSize.height, TryVoiceScreen.boxSize.height, accuracy: 0.5, "\(text.count) characters")
        }
        let code = (try? OnboardingWindowTests.codeLines(of: "Views/Windows/Onboarding/TryVoiceScreen.swift")) ?? []
        XCTAssertTrue(code.contains { $0.contains("ScrollView") }, "the words scroll")
    }

    // MARK: - Skip for now (the model could not be got)

    /// Offline, a failed download or a full disk leaves no words to continue with: a quiet "Skip for now" goes on —
    /// in those states only, never while the model is on its way or once the practice can run.
    func testSkipIsOfferedOnlyWhenTheModelCouldNotBeGot() {
        XCTAssertEqual(TryVoiceScreen.skip, "Skip for now")
        XCTAssertTrue(TryVoiceScreen.showsSkip(box(.ready, .failed("The speech model didn't download."))), "failed")
        XCTAssertTrue(TryVoiceScreen.showsSkip(box(.ready, .lowDisk)), "low disk")
        for model in [ModelPreparer.State.downloading(0.4), .loading, .ready] {
            XCTAssertFalse(TryVoiceScreen.showsSkip(box(.ready, model)), "\(model)")
        }
        for phase in [PracticeRecorder.Phase.listening, .transcribing, .result("Hi."), .noSpeech, .failed("x"),
                      .waiting("x")] {
            XCTAssertFalse(TryVoiceScreen.showsSkip(box(phase)), "\(phase)")
        }
    }

    /// Skip goes to the Pro screen and the practice keeps nothing: the microphone and the lease come back, nothing
    /// was transcribed.
    func testSkipGoesToTheProScreenAndThePracticeKeepsNothing() throws {
        let (flow, _) = try practiceScreen()
        flow.skipPractice()
        XCTAssertEqual(flow.screen, .pro)
        XCTAssertNil(flow.practice)
        XCTAssertNil(fixture.arbiter.refusal, "the microphone is back")
        XCTAssertEqual(fixture.engine.billed, [], "nothing was transcribed")
        XCTAssertEqual(fixture.endings, [], "the onboarding goes on to Free or Pro")
    }

    /// The paired case: after the user's own words, Continue goes on as before.
    func testAfterTheWordsContinueGoesOnAsBefore() throws {
        let (flow, practice) = try practiceScreen()
        flow.record()
        flow.record()
        fixture.settle(practice)
        XCTAssertTrue(TryVoiceScreen.continueEnabled(practice.phase))
        XCTAssertFalse(TryVoiceScreen.showsSkip(box(practice.phase)))
        flow.next()
        XCTAssertEqual(flow.screen, .pro)
    }

    // MARK: - Already have Pro? Sign in

    func testSignInOpensTheAccountPageAndTheOnboardingGoesOn() throws {
        let (flow, _) = try practiceScreen()
        flow.signIn()
        XCTAssertEqual(fixture.accountPageOpens, 1)
        XCTAssertEqual(fixture.endings, [], "signing in does not finish the onboarding")
        XCTAssertFalse(flow.accountLinkShown)
        XCTAssertEqual(flow.screen, .practice)
    }

    /// D2 — the browser does not open: the link is shown, with Copy.
    func testABrowserThatDoesNotOpenShowsTheLink() throws {
        fixture.browserOpens = false
        let (flow, _) = try practiceScreen()
        flow.signIn()
        XCTAssertTrue(flow.accountLinkShown)
    }
}
