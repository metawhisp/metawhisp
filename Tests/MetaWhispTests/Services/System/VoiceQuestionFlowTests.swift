import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-079 — a voice question from the long press to its answer or its error,
/// through the real coordinator with a fake microphone, a fake engine and the
/// test's own island state. Each test is a way the island used to hang, bring a
/// closed question back, or keep what Esc cancelled.
@MainActor
final class VoiceQuestionFlowTests: XCTestCase {
    private var savedEngine = ""
    private var savedAutoSubmit = true
    private var savedSpeech = true
    private var settingsOpened = 0
    private var state = VoiceQuestionState()

    override func setUpWithError() throws {
        savedEngine = AppSettings.shared.transcriptionEngine
        savedAutoSubmit = AppSettings.shared.autoSubmit
        savedSpeech = AppSettings.shared.ttsVoiceQuestions
        // The fake engine stands in for the cloud one, and nothing is ever pasted.
        AppSettings.shared.transcriptionEngine = "cloud"
        AppSettings.shared.autoSubmit = false
        state = VoiceQuestionState()
    }

    override func tearDownWithError() throws {
        state.dismiss()
        AppSettings.shared.transcriptionEngine = savedEngine
        AppSettings.shared.autoSubmit = savedAutoSubmit
        AppSettings.shared.ttsVoiceQuestions = savedSpeech
    }

    private func coordinator(_ microphone: FakeMicrophone, _ engine: HeldEngine) -> TranscriptionCoordinator {
        TranscriptionCoordinator(recorder: microphone, whisperEngine: nil, textInserter: TextInsertionService(),
                                 soundService: SoundService(enabled: { false }), settings: AppSettings.shared,
                                 voiceQuestions: state, cloudEngine: engine,
                                 openMicrophoneSettings: { [weak self] in self?.settingsOpened += 1 },
                                 proxyAvailable: { true })   // A4: cloud in use needs Pro or a key
    }

    private func spin(until done: () -> Bool, within seconds: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private var errorText: String? {
        if case .error(let text) = state.phase { return text }
        return nil
    }

    // MARK: - An errand started

    /// ITER-076 I-06: a question whose errand started, while the model's
    /// closing words did not come, is no error: the island shows no failure
    /// and says nothing; the errand's result comes later in MetaChat.
    func testAnErrandThatStartedIsNoError() {
        XCTAssertEqual(VoiceQuestionState.ending(of: .errandStarted), .answer("", speaks: false))
        XCTAssertEqual(VoiceQuestionState.ending(of: .failed("timed out")), .error("timed out", retryByVoice: false))
    }

    // MARK: - The microphone delivered nothing

    /// A dictation whose microphone delivered nothing says so: not "too short", and not nothing at all (the owner's
    /// three headset dictations of 2026-10-13 ended in silence on screen).
    func testADictationWhoseMicrophoneDeliveredNothingSaysSo() {
        let microphone = FakeMicrophone()
        microphone.recording = []
        microphone.micHealthError = AudioRecordingService.deadMicMessage
        let flow = coordinator(microphone, HeldEngine(answersAtOnce: true))
        flow.startPTT()
        flow.stopPTT()
        XCTAssertEqual(flow.lastError, AudioRecordingService.deadMicMessage)
        XCTAssertEqual(flow.stage, .idle)
    }

    /// The microphone stopped delivering before the end, after speech: what it captured is still transcribed, and
    /// the user is told the rest was lost (independent review, 2026-10-13).
    func testADictationWhoseMicrophoneDiedAfterSpeechKeepsTheTextAndSaysSo() {
        let microphone = FakeMicrophone()
        microphone.micHealthError = AudioRecordingService.deadMicMessage
        let flow = coordinator(microphone, HeldEngine(answersAtOnce: true))
        flow.startPTT()
        flow.stopPTT()
        spin(until: { flow.lastResult != nil })
        XCTAssertEqual(flow.lastResult?.text, "what is on my screen")
        XCTAssertEqual(flow.lastError, AudioRecordingService.deadMicMessage)
    }

    /// Whatever then becomes of the text, the microphone's loss is still said — the outcome joins it instead of
    /// replacing it (independent review, 2026-10-13: "Copied to clipboard" overwrote it).
    func testTheOutcomeOfARecordingWhoseMicrophoneDiedJoinsTheWarning() {
        let microphone = FakeMicrophone()
        microphone.micHealthError = AudioRecordingService.deadMicMessage
        let flow = coordinator(microphone, HeldEngine(text: "", answersAtOnce: true))
        flow.startPTT()
        flow.stopPTT()
        spin(until: { flow.stage == .idle })
        XCTAssertEqual(flow.lastError, AudioRecordingService.deadMicMessage
                           + " Transcription returned empty — try again louder/closer.")
    }

    func testAnOutcomeWithoutAMicrophoneLossReadsAsBefore() {
        let flow = coordinator(FakeMicrophone(), HeldEngine(text: "", answersAtOnce: true))
        flow.startPTT()
        flow.stopPTT()
        spin(until: { flow.stage == .idle })
        XCTAssertEqual(flow.lastError, "Transcription returned empty — try again louder/closer.")
        XCTAssertEqual(TranscriptionCoordinator.withMicLoss(nil, "Copied to clipboard — press ⌘V to paste"),
                       "Copied to clipboard — press ⌘V to paste")
    }

    /// A tap too short to record is still only too short: the recorder judged nothing wrong with the microphone.
    func testATapTooShortToRecordStaysQuiet() {
        let microphone = FakeMicrophone()
        microphone.recording = []
        let flow = coordinator(microphone, HeldEngine(answersAtOnce: true))
        flow.startPTT()
        flow.stopPTT()
        XCTAssertNil(flow.lastError)
        XCTAssertEqual(flow.stage, .idle)
    }

    func testAVoiceQuestionWhoseMicrophoneDeliveredNothingSaysSo() {
        let microphone = FakeMicrophone()
        microphone.recording = []
        microphone.micHealthError = AudioRecordingService.deadMicMessage
        let flow = coordinator(microphone, HeldEngine(answersAtOnce: true))
        flow.startVoiceQuestion()
        flow.stopVoiceQuestion()
        XCTAssertEqual(errorText, AudioRecordingService.deadMicMessage)
    }

    // MARK: - The recording cannot start

    func testAQuestionWithoutMicrophoneAccessEndsInAnError() {
        let microphone = FakeMicrophone()
        microphone.hasPermission = false
        let flow = coordinator(microphone, HeldEngine(answersAtOnce: true))
        flow.startVoiceQuestion()
        XCTAssertEqual(settingsOpened, 1, "System Settings opens at Microphone, as for a dictation")
        XCTAssertEqual(flow.stage, .idle)
        XCTAssertTrue(errorText?.contains("Microphone") == true, "not Listening… forever: \(state.phase)")
        XCTAssertFalse(state.errorRetriesByVoice, "asking again cannot fix it")
    }

    func testAQuestionWhoseMicrophoneWillNotStartEndsInAnError() {
        let microphone = FakeMicrophone()
        microphone.startError = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "device busy"])
        let flow = coordinator(microphone, HeldEngine(answersAtOnce: true))
        flow.startVoiceQuestion()
        XCTAssertEqual(flow.stage, .idle)
        XCTAssertTrue(errorText?.contains("device busy") == true, "not Listening… forever: \(state.phase)")
    }

    // MARK: - Esc

    func testEscWhileSpeakingStopsTheMicrophoneAndTheQuestionStaysClosed() {
        let microphone = FakeMicrophone()
        let engine = HeldEngine(answersAtOnce: true)
        let flow = coordinator(microphone, engine)
        flow.startVoiceQuestion()
        XCTAssertTrue(microphone.isRecording)
        state.dismiss()
        XCTAssertFalse(microphone.isRecording, "Esc stops the microphone at once, not at the key's release")
        XCTAssertEqual(flow.stage, .idle)
        // Right ⌘ is released after the Esc.
        flow.stopVoiceQuestion()
        spin(until: { self.state.phase != .idle }, within: 0.3)
        XCTAssertEqual(state.phase, .idle, "a closed question never comes back")
        XCTAssertEqual(engine.calls, 0, "nothing was transcribed")
    }

    func testEscWhileTranscribingDropsTheQuestion() {
        let microphone = FakeMicrophone()
        let engine = HeldEngine(answersAtOnce: false)
        let flow = coordinator(microphone, engine)
        flow.startVoiceQuestion()
        flow.stopVoiceQuestion()
        XCTAssertEqual(state.phase, .transcribing)
        spin(until: { engine.isWaiting })
        XCTAssertTrue(engine.isWaiting)
        state.dismiss()
        engine.finish()
        spin(until: { engine.isWaiting }, within: 0.3)
        XCTAssertEqual(flow.stage, .idle)
        XCTAssertEqual(state.phase, .idle, "the transcript of a closed question is dropped")
        XCTAssertNil(flow.lastResult, "nothing of it is kept")
    }

    /// Review of ITER-079 (P2-1): Esc frees the coordinator at once, so the
    /// next question records right away, and the old transcription's end
    /// changes nothing of it.
    func testEscWhileTranscribingFreesTheCoordinatorAtOnce() {
        let microphone = FakeMicrophone()
        let engine = HeldEngine(answersAtOnce: false)
        let flow = coordinator(microphone, engine)
        flow.startVoiceQuestion()
        flow.stopVoiceQuestion()
        spin(until: { engine.isWaiting })
        state.dismiss()
        XCTAssertEqual(flow.stage, .idle, "free at once, not when the transcription ends")
        flow.startVoiceQuestion()
        XCTAssertEqual(flow.stage, .recording)
        XCTAssertTrue(microphone.isRecording)
        engine.finish()
        spin(until: { flow.stage != .recording }, within: 0.3)
        XCTAssertEqual(flow.stage, .recording, "the old transcription's end leaves the new recording alone")
        XCTAssertEqual(state.phase, .listening)
    }

    /// Review of ITER-079 (P2-1): a long press while a voice question is
    /// transcribed replaces it.
    func testALongPressWhileTranscribingReplacesTheQuestion() {
        let microphone = FakeMicrophone()
        let engine = HeldEngine(answersAtOnce: false)
        let flow = coordinator(microphone, engine)
        let chat = ChatService()
        flow.chatService = chat
        flow.startVoiceQuestion()
        flow.stopVoiceQuestion()
        spin(until: { engine.isWaiting })
        flow.startVoiceQuestion()
        XCTAssertEqual(state.phase, .listening, "the new question listens")
        XCTAssertTrue(microphone.isRecording)
        engine.finish()
        spin(until: { self.state.phase != .listening }, within: 0.3)
        XCTAssertEqual(state.phase, .listening, "the old question's transcript never lands")
        XCTAssertNil(flow.lastResult)
    }

    /// Review of ITER-079 (P2-1): a dictation is never cut short, and a long
    /// press while one is transcribed says so instead of doing nothing.
    func testALongPressWhileADictationIsTranscribedSaysSo() {
        let microphone = FakeMicrophone()
        let engine = HeldEngine(answersAtOnce: false)
        let flow = coordinator(microphone, engine)
        flow.toggle()
        spin(until: { false }, within: 0.05)   // the toggle's debounce
        flow.toggle()
        XCTAssertEqual(flow.stage, .processing)
        flow.startVoiceQuestion()
        XCTAssertTrue(errorText?.contains("dictation") == true, "\(state.phase)")
        XCTAssertTrue(state.errorRetriesByVoice)
        XCTAssertFalse(microphone.isRecording)
        spin(until: { engine.isWaiting })
        engine.finish()
        spin(until: { flow.stage == .idle })
        XCTAssertEqual(flow.lastResult?.text, "what is on my screen", "the dictation finished")
    }

    /// Review of ITER-079, round 2 (P2-A): a long press refused because a
    /// dictation is being transcribed leaves the question the island shows —
    /// here one still waiting for its answer — alone.
    func testARefusedLongPressLeavesTheShownQuestionAlone() {
        let microphone = FakeMicrophone()
        let engine = HeldEngine(answersAtOnce: true)
        let flow = coordinator(microphone, engine)
        let answerer = HeldAnswerer()
        flow.voiceAnswerer = answerer.voiceAnswerer
        flow.startVoiceQuestion()
        flow.stopVoiceQuestion()
        spin(until: { self.state.phase == .thinking })
        XCTAssertEqual(state.phase, .thinking)
        // A dictation now, held in its transcription.
        engine.answersAtOnce = false
        flow.toggle()
        spin(until: { false }, within: 0.05)   // the toggle's debounce
        flow.toggle()
        XCTAssertEqual(flow.stage, .processing)
        flow.startVoiceQuestion()
        XCTAssertEqual(state.phase, .thinking, "the shown question is left alone")
        answerer.answer("It is noon.")
        spin(until: { self.state.phase != .thinking })
        XCTAssertEqual(state.phase, .answered(text: "It is noon."), "its answer still lands")
        spin(until: { engine.isWaiting })
        engine.finish()
        spin(until: { flow.stage == .idle })
    }

    func testEscBeforeTheTranscriptionStartsCostsNoTranscription() {
        let microphone = FakeMicrophone()
        let engine = HeldEngine(answersAtOnce: true)
        let flow = coordinator(microphone, engine)
        flow.startVoiceQuestion()
        flow.stopVoiceQuestion()
        state.dismiss()
        flow.startVoiceQuestion()
        spin(until: { engine.calls > 0 }, within: 0.3)
        XCTAssertEqual(engine.calls, 0)
        XCTAssertEqual(flow.stage, .recording, "the new recording goes on")
    }

    /// Review of ITER-079 (P2-2): the result and a post-processing error are
    /// recorded only once the question is known to be open.
    func testEscWhilePostProcessingKeepsNothing() {
        let microphone = FakeMicrophone()
        let flow = coordinator(microphone, HeldEngine(answersAtOnce: true))
        let processor = HeldProcessor()
        flow.textProcessor = processor
        flow.startVoiceQuestion()
        flow.stopVoiceQuestion()
        spin(until: { processor.isWaiting })
        XCTAssertEqual(flow.stage, .postProcessing)
        state.dismiss()
        XCTAssertEqual(flow.stage, .idle)
        flow.startVoiceQuestion()
        processor.fail()
        spin(until: { flow.lastResult != nil || flow.lastError != nil }, within: 0.3)
        XCTAssertNil(flow.lastResult, "the popover shows nothing of it")
        XCTAssertNil(flow.lastError)
        XCTAssertEqual(flow.stage, .recording, "the new recording goes on")
        XCTAssertEqual(state.phase, .listening)
    }

    func testAFailedTranscriptionOfAClosedQuestionLeavesNoTrace() {
        let microphone = FakeMicrophone()
        let engine = HeldEngine(answersAtOnce: false)
        let flow = coordinator(microphone, engine)
        var recoverySaves = 0
        flow.saveRecoveryAudio = { _ in
            recoverySaves += 1
            return nil
        }
        flow.startVoiceQuestion()
        flow.stopVoiceQuestion()
        spin(until: { engine.isWaiting })
        state.dismiss()
        engine.answersAtOnce = true
        flow.startVoiceQuestion()
        engine.fail()
        spin(until: { flow.lastError != nil }, within: 0.3)
        XCTAssertNil(flow.lastError)
        XCTAssertEqual(recoverySaves, 0, "no recovery audio for a question the user closed")
        XCTAssertEqual(flow.stage, .recording, "the new recording goes on")
    }

    /// Review of ITER-079 (P3-4): whichever control stops a voice recording,
    /// the island shows it transcribing.
    func testAVoiceRecordingStoppedElsewhereStillShowsTranscribing() {
        let microphone = FakeMicrophone()
        let engine = HeldEngine(answersAtOnce: false)
        let flow = coordinator(microphone, engine)
        flow.startVoiceQuestion()
        spin(until: { false }, within: 0.05)   // the toggle's debounce
        flow.toggle()   // the menu bar's Stop
        XCTAssertEqual(state.phase, .transcribing)
        spin(until: { engine.isWaiting })
        engine.finish()
    }

    // MARK: - A question is no dictation (ITER-076 stage 3, № 2)

    /// History on a store of its own, in memory: never the app's.
    private func history() throws -> HistoryService {
        HistoryService(container: try ModelContainer(for: Schema(versionedSchema: MetaWhispSchemaV9.self),
                                                     configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func dictations(in history: HistoryService) throws -> Int {
        try history.modelContainer.mainContext.fetchCount(FetchDescriptor<HistoryItem>())
    }

    /// A voice question goes to MetaChat, which keeps it: it is never saved
    /// as a dictation first — no item in the Library, no conversation, no
    /// export — as a dictation still is (ITER-075 plan, step 4.2).
    func testAVoiceQuestionIsNeverSavedAsADictation() throws {
        let flow = coordinator(FakeMicrophone(), HeldEngine(answersAtOnce: true))
        let kept = try history()
        flow.historyService = kept
        let answerer = FakeAnswerer(outcome: .answered("Four.", pendingTool: false))
        flow.voiceAnswerer = answerer.voiceAnswerer
        flow.startVoiceQuestion()
        flow.stopVoiceQuestion()
        spin(until: { self.state.phase == .answered(text: "Four.") })
        XCTAssertEqual(answerer.asked, ["what is on my screen"], "the question reached MetaChat")
        XCTAssertEqual(try dictations(in: kept), 0, "and no dictation was saved of it")

        spin(until: { false }, within: 0.05)   // the toggle's debounce
        flow.toggle()
        spin(until: { flow.stage == .recording })
        spin(until: { false }, within: 0.05)
        flow.toggle()
        spin(until: { flow.stage == .idle && (try? self.dictations(in: kept)) == 1 })
        XCTAssertEqual(try dictations(in: kept), 1, "a dictation is saved as before")
    }

    // MARK: - The answer

    func testABusyMetaChatEndsTheQuestionInAnError() {
        let microphone = FakeMicrophone()
        let flow = coordinator(microphone, HeldEngine(answersAtOnce: true))
        let chat = ChatService()
        chat.isSending = true   // a typed MetaChat message is being answered
        flow.chatService = chat
        flow.startVoiceQuestion()
        flow.stopVoiceQuestion()
        spin(until: { self.errorText != nil })
        XCTAssertTrue(errorText?.contains("MetaChat") == true, "not thinking forever: \(state.phase)")
        XCTAssertTrue(state.errorRetriesByVoice, "asking again in a moment fixes it")
    }

    /// ITER-076 B2 review, P2-7: MetaChat is told which island question it
    /// answers, so an errand that question starts carries the island's id.
    func testTheAnswererIsToldWhichQuestionItAnswers() {
        let flow = coordinator(FakeMicrophone(), HeldEngine(answersAtOnce: true))
        let answerer = FakeAnswerer(outcome: .answered("Four.", pendingTool: false))
        flow.voiceAnswerer = answerer.voiceAnswerer
        flow.startVoiceQuestion()
        let question = state.question
        flow.stopVoiceQuestion()
        spin(until: { self.state.phase == .answered(text: "Four.") })
        XCTAssertNotNil(question)
        XCTAssertEqual(answerer.questions, question.map { [$0] })
    }

    func testTheAnswerIsSpokenOnlyWhenVoiceAnswersAreOn() {
        for speechOn in [true, false] {
            AppSettings.shared.ttsVoiceQuestions = speechOn
            state = VoiceQuestionState()
            let flow = coordinator(FakeMicrophone(), HeldEngine(answersAtOnce: true))
            let answerer = FakeAnswerer(outcome: .answered("Four.", pendingTool: false))
            flow.voiceAnswerer = answerer.voiceAnswerer
            flow.startVoiceQuestion()
            flow.stopVoiceQuestion()
            spin(until: { self.state.phase == .answered(text: "Four.") })
            XCTAssertEqual(state.phase, .answered(text: "Four."))
            XCTAssertEqual(answerer.spoken, speechOn ? ["Four."] : [], "speech on: \(speechOn)")
            XCTAssertEqual(answerer.asked, ["what is on my screen"])
        }
    }

    /// Review of ITER-079, round 2 (P3-D): a typed reply read aloud while the
    /// island is idle stops too before the microphone starts.
    func testAnyAnswerReadAloudStopsBeforeTheMicrophoneStarts() {
        let flow = coordinator(FakeMicrophone(), HeldEngine(answersAtOnce: true))
        let answerer = FakeAnswerer(outcome: .answered("Unused.", pendingTool: false))
        flow.voiceAnswerer = answerer.voiceAnswerer
        XCTAssertEqual(state.phase, .idle)
        flow.startVoiceQuestion()
        XCTAssertEqual(answerer.stops, 1)
    }

    /// Review of ITER-079 (P2-3): a new question silences the old answer, so
    /// the microphone never records it.
    func testANewQuestionStopsTheOldAnswersSpeech() {
        let flow = coordinator(FakeMicrophone(), HeldEngine(answersAtOnce: true))
        let answerer = FakeAnswerer(outcome: .answered("A long answer.", pendingTool: false))
        flow.voiceAnswerer = answerer.voiceAnswerer
        flow.startVoiceQuestion()
        flow.stopVoiceQuestion()
        spin(until: { self.state.phase == .answered(text: "A long answer.") })
        XCTAssertEqual(answerer.spoken, ["A long answer."])
        let stopsBefore = answerer.stops
        flow.startVoiceQuestion()
        XCTAssertGreaterThan(answerer.stops, stopsBefore, "the old answer stops before the microphone starts")
        XCTAssertEqual(state.phase, .listening)
    }
}

/// ITER-079 — the question's owner: a closed or replaced question changes
/// nothing, every outcome of the ask ends the question, and so does no answer
/// in time.
@MainActor
final class VoiceQuestionStateTests: XCTestCase {
    private func spin(until done: () -> Bool, within seconds: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testAStepForAClosedQuestionChangesNothing() {
        let state = VoiceQuestionState()
        let question = state.startListening()
        state.dismiss()
        state.transcribing(question)
        state.thinking(question, transcript: "what is on my screen")
        XCTAssertFalse(state.answered(question, "Late."))
        state.failed(question, "Late too.")
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.transcript, "")
    }

    /// Review of ITER-079 (P2-5): the id, not only the idle phase, keeps a
    /// replaced question out.
    func testAStepForAReplacedQuestionChangesNothing() {
        let state = VoiceQuestionState()
        let first = state.startListening()
        _ = state.startListening()
        state.transcribing(first)
        state.thinking(first, transcript: "first")
        XCTAssertFalse(state.answered(first, "The first answer."))
        state.failed(first, "The first error.")
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(state.transcript, "")
    }

    func testANewQuestionCancelsTheOldAskAndItsAnswerNeverLands() {
        let state = VoiceQuestionState()
        let first = state.startListening()
        state.thinking(first, transcript: "first")
        let record = AskRecord()
        state.answer(first, transcript: "first", within: .seconds(5), ask: { text in
            record.asked(text)
            // A slow model: it answers only once it is cancelled.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            record.cancelled()
            return .answered("The first answer.", pendingTool: false)
        }, speak: nil)
        spin(until: { record.asks == ["first"] })
        let second = state.startListening()
        spin(until: { record.sawCancel })
        XCTAssertTrue(record.sawCancel, "the first send stops")
        spin(until: { state.phase != .listening }, within: 0.2)
        XCTAssertEqual(state.phase, .listening, "the first answer never lands under the second question")
        state.thinking(second, transcript: "second")
        state.answer(second, transcript: "second", within: .seconds(5),
                     ask: { _ in .answered("The second answer.", pendingTool: false) }, speak: nil)
        spin(until: { state.phase != .thinking })
        XCTAssertEqual(state.phase, .answered(text: "The second answer."))
    }

    /// Review of ITER-079 (P2-5): MetaChat answers one message at a time, so a
    /// new question's send waits for the one it replaced to finish unwinding —
    /// it is never refused as busy by it.
    func testANewQuestionsSendWaitsForTheReplacedOneToUnwind() {
        let state = VoiceQuestionState()
        let chat = OneAtATimeChat()
        let first = state.startListening()
        state.thinking(first, transcript: "first")
        state.answer(first, transcript: "first", within: .seconds(5),
                     ask: { text in await chat.send(text, unwindsFor: 0.15) }, speak: nil)
        spin(until: { chat.texts == ["first"] })
        let second = state.startListening()
        state.thinking(second, transcript: "second")
        state.answer(second, transcript: "second", within: .seconds(5),
                     ask: { text in await chat.send(text, unwindsFor: 0) }, speak: nil)
        spin(until: { state.phase != .thinking })
        XCTAssertEqual(state.phase, .answered(text: "The answer to second."))
    }

    /// Review of ITER-079 (P2-5): a send closed while it still waits for the
    /// one before it never goes out.
    func testASendClosedWhileItWaitsNeverGoesOut() {
        let state = VoiceQuestionState()
        let chat = OneAtATimeChat()
        let first = state.startListening()
        state.thinking(first, transcript: "first")
        state.answer(first, transcript: "first", within: .seconds(5),
                     ask: { text in await chat.send(text, unwindsFor: 0.2) }, speak: nil)
        spin(until: { chat.texts == ["first"] })
        let second = state.startListening()
        state.thinking(second, transcript: "second")
        state.answer(second, transcript: "second", within: .seconds(5),
                     ask: { text in await chat.send(text, unwindsFor: 0) }, speak: nil)
        state.dismiss()
        spin(until: { chat.texts.count > 1 }, within: 0.6)
        XCTAssertEqual(chat.texts, ["first"], "the second question never reached MetaChat")
    }

    func testEveryOutcomeOfTheAskEndsTheQuestion() {
        let cases: [(outcome: ChatService.SendOutcome, phase: VoiceQuestionState.Phase, spoken: [String], retry: Bool)] = [
            (.answered("Yes.", pendingTool: false), .answered(text: "Yes."), ["Yes."], false),
            // A change waits for its confirm in MetaChat: shown with where to
            // confirm it, not spoken.
            (.answered("Add it to your tasks?", pendingTool: true),
             .answered(text: "Add it to your tasks?\n\nOpen MetaChat to confirm."), [], false),
            (.answered("", pendingTool: true), .answered(text: "Open MetaChat to confirm."), [], false),
            (.busy, .error(text: "MetaChat is still answering another message."), [], true),
            (.noAccess, .error(text: "No AI is set up to answer. Sign in to Pro, add an API key, or turn on the local model in Settings."), [], false),
            (.failed("Chat-with-tools HTTP 500"), .error(text: "Chat-with-tools HTTP 500"), [], false),
            (.empty, .error(text: "Nothing was heard."), [], true),
        ]
        for item in cases {
            let state = VoiceQuestionState()
            let question = state.startListening()
            state.thinking(question, transcript: "a question")
            var spoken: [String] = []
            let outcome = item.outcome
            state.answer(question, transcript: "a question", within: .seconds(5), ask: { _ in outcome },
                         speak: { spoken.append($0) })
            spin(until: { state.phase != .thinking })
            XCTAssertEqual(state.phase, item.phase, "\(item.outcome)")
            XCTAssertEqual(spoken, item.spoken, "\(item.outcome)")
            XCTAssertEqual(state.errorRetriesByVoice, item.retry, "\(item.outcome)")
        }
    }

    /// Review of ITER-079, round 2 (P3-C): the island ends at the limit, but
    /// the send goes on, so its reply still lands in MetaChat.
    func testAnAnswerThatNeverComesEndsInAnErrorAtTheLimit() {
        let state = VoiceQuestionState()
        let question = state.startListening()
        state.thinking(question, transcript: "a question")
        let record = AskRecord()
        state.answer(question, transcript: "a question", within: .milliseconds(100), ask: { text in
            record.asked(text)
            // Answers after 0.4 s, unless it is cancelled first.
            let end = ContinuousClock.now + .milliseconds(400)
            while ContinuousClock.now < end, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            if Task.isCancelled { record.cancelled() }
            record.asked("finished")
            return .answered("Too late.", pendingTool: false)
        }, speak: nil)
        spin(until: { state.phase != .thinking })
        XCTAssertEqual(state.phase, .error(text: "No answer came in time."))
        spin(until: { record.asks.contains("finished") })
        XCTAssertFalse(record.sawCancel, "a late send is not cancelled: its reply still reaches MetaChat")
        XCTAssertEqual(state.phase, .error(text: "No answer came in time."), "a late answer never replaces the error")
    }

    /// Review of ITER-079, round 2 (P3-C): a new question stops a send left
    /// running after its question ran out of time.
    func testANewQuestionStopsALateSend() {
        let state = VoiceQuestionState()
        let question = state.startListening()
        state.thinking(question, transcript: "a question")
        let record = AskRecord()
        state.answer(question, transcript: "a question", within: .milliseconds(100), ask: { _ in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            record.cancelled()
            return .answered("Too late.", pendingTool: false)
        }, speak: nil)
        spin(until: { state.phase != .thinking })
        XCTAssertEqual(state.phase, .error(text: "No answer came in time."))
        XCTAssertFalse(record.sawCancel)
        _ = state.startListening()
        spin(until: { record.sawCancel })
        XCTAssertTrue(record.sawCancel)
    }

    /// Codex review round 1 (P1-2): Esc after the island ran out of time
    /// stops the send still running for its question, so a late reply starts
    /// nothing — no errand the user already closed.
    func testEscAfterTheLimitStopsTheLateSend() {
        let state = VoiceQuestionState()
        let question = state.startListening()
        state.thinking(question, transcript: "a question")
        let record = AskRecord()
        state.answer(question, transcript: "a question", within: .milliseconds(100), ask: { _ in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            record.cancelled()
            return .answered("Too late.", pendingTool: false)
        }, speak: nil)
        spin(until: { state.phase != .thinking })
        XCTAssertEqual(state.phase, .error(text: "No answer came in time."))
        XCTAssertFalse(record.sawCancel)
        state.dismiss()
        spin(until: { record.sawCancel })
        XCTAssertTrue(record.sawCancel, "Esc stops the late send")
    }

    /// Review of ITER-079, round 2 (P3-C), kept: the island closing itself
    /// after the error leaves the late send to land in MetaChat.
    func testTheIslandClosingItselfAfterTheLimitLeavesTheLateSend() {
        let state = VoiceQuestionState()
        let question = state.startListening()
        state.thinking(question, transcript: "a question")
        let record = AskRecord()
        state.answer(question, transcript: "a question", within: .milliseconds(100), ask: { _ in
            let end = ContinuousClock.now + .milliseconds(400)
            while ContinuousClock.now < end, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            if Task.isCancelled { record.cancelled() }
            record.asked("finished")
            return .answered("Too late.", pendingTool: false)
        }, speak: nil)
        spin(until: { state.phase != .thinking })
        state.dismiss(ifStill: question)
        spin(until: { record.asks.contains("finished") })
        XCTAssertEqual(record.asks, ["finished"])
        XCTAssertFalse(record.sawCancel, "its reply still reaches MetaChat")
    }

    /// Codex review round 1 (P2-1): a question is asked once. A second
    /// delivery of the same question, before or after its answer, sends
    /// nothing — a new question still does.
    func testAQuestionIsAskedOnce() {
        let state = VoiceQuestionState()
        let question = state.startListening()
        state.thinking(question, transcript: "a question")
        let record = AskRecord()
        let ask: @Sendable (String) async -> ChatService.SendOutcome = { text in
            record.asked(text)
            return .answered("Yes.", pendingTool: false)
        }
        state.answer(question, transcript: "a question", within: .seconds(5), ask: ask, speak: nil)
        state.answer(question, transcript: "a question", within: .seconds(5), ask: ask, speak: nil)
        spin(until: { state.phase != .thinking })
        state.answer(question, transcript: "a question", within: .seconds(5), ask: ask, speak: nil)
        spin(until: { false }, within: 0.1)
        XCTAssertEqual(record.asks, ["a question"])
        let next = state.startListening()
        state.thinking(next, transcript: "another question")
        state.answer(next, transcript: "another question", within: .seconds(5), ask: ask, speak: nil)
        spin(until: { record.asks.count == 2 })
        XCTAssertEqual(record.asks, ["a question", "another question"])
    }

    func testClosingOrReplacingAQuestionTellsItsOwner() {
        let state = VoiceQuestionState()
        var closed: [UUID] = []
        state.onQuestionClosed = { closed.append($0) }
        let first = state.startListening()
        let second = state.startListening()
        XCTAssertEqual(closed, [first], "a replaced question is closed")
        state.dismiss()
        XCTAssertEqual(closed, [first, second])
        state.dismiss()
        XCTAssertEqual(closed, [first, second], "closing nothing tells nobody")
    }

    /// Review of ITER-079 (P2-6): a timer set for an old question never
    /// closes a newer one.
    func testAnAutoDismissForAnOldQuestionLeavesTheNewOne() {
        let state = VoiceQuestionState()
        let first = state.startListening()
        state.failed(first, "Too short — try holding longer.", retryByVoice: true)
        let second = state.startListening()
        state.dismiss(ifStill: first)
        XCTAssertEqual(state.phase, .listening)
        XCTAssertTrue(state.isOpen(second))
        state.dismiss(ifStill: second)
        XCTAssertEqual(state.phase, .idle)
    }
}

/// ITER-079 — `send` says what happened instead of returning in silence, and
/// refuses before it saves anything.
@MainActor
final class ChatSendOutcomeTests: XCTestCase {
    private func chatWithStore() throws -> (ChatService, ModelContainer) {
        let container = try ModelContainer(for: ChatMessage.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let chat = ChatService()
        chat.configure(modelContainer: container)
        return (chat, container)
    }

    private func savedMessages(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<ChatMessage>())
    }

    func testABusyChatSaysSoInsteadOfDroppingTheMessage() async throws {
        let (chat, container) = try chatWithStore()
        chat.isSending = true
        let outcome = await chat.send("hello", source: .typed)
        XCTAssertEqual(outcome, .busy)
        XCTAssertEqual(try savedMessages(container), 0, "nothing was saved, so MetaChat gives it back")
    }

    func testAChatWithNoAISaysSoAndSavesNothing() async throws {
        let (chat, container) = try chatWithStore()
        chat.hasLLMAccess = { false }
        let outcome = await chat.send("hello", source: .typed)
        XCTAssertEqual(outcome, .noAccess)
        XCTAssertNotNil(chat.lastError)
        XCTAssertFalse(chat.isSending)
        XCTAssertEqual(try savedMessages(container), 0, "nothing was saved, so MetaChat gives it back")
    }

    func testABlankMessageIsNotSent() async {
        let chat = ChatService()
        chat.hasLLMAccess = { true }
        let outcome = await chat.send("   \n", source: .typed)
        XCTAssertEqual(outcome, .empty)
    }
}

/// A microphone that records whatever it is told to.
@MainActor
final class FakeMicrophone: AudioSource {
    var isRecording = false
    var audioLevel: Float = 0
    var audioBars: [Float] = []
    var hasPermission = true
    /// Never answered: a request shows the prompt, which answers `grantsOnRequest`.
    var permissionUndetermined = false
    var grantsOnRequest = true
    private(set) var permissionRequests = 0
    var startError: Error?
    var micHealthError: String?

    func requestPermission(_ ask: PermissionAsk) async -> Bool {
        permissionRequests += 1
        if permissionUndetermined {
            permissionUndetermined = false
            hasPermission = grantsOnRequest
        }
        return hasPermission
    }

    func start() throws {
        if let startError { throw startError }
        captureSession += 1
        isRecording = true
    }

    /// What `stop` hands back: one second, loud enough to pass the silence checks.
    var recording: [Float] = Array(repeating: 0.1, count: 16_000)
    private(set) var stops = 0
    private(set) var captureSession = 0

    func stop() -> [Float] {
        stops += 1
        captureSession += 1
        isRecording = false
        return recording
    }
}

/// A transcription engine that answers at once, or when the test says so.
final class HeldEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "Held engine"
    let isModelLoaded = true
    private var answersAtOnceValue: Bool
    private let text: String
    private let lock = NSLock()
    private var waiting: CheckedContinuation<TranscriptionResult, Error>?
    private var callCount = 0

    init(text: String = "what is on my screen", answersAtOnce: Bool) {
        self.text = text
        self.answersAtOnceValue = answersAtOnce
    }

    /// Whether the next transcription answers at once; the test may change it.
    var answersAtOnce: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return answersAtOnceValue
        }
        set {
            lock.lock()
            answersAtOnceValue = newValue
            lock.unlock()
        }
    }

    func loadModel(_ modelName: String, progressHandler: (@Sendable (Double) -> Void)?) async throws {}
    func unloadModel() async {}

    func transcribe(audioSamples: [Float], language: String?, promptWords: [String],
                    countUsage: Bool) async throws -> TranscriptionResult {
        lock.lock()
        callCount += 1
        lock.unlock()
        if answersAtOnce { return result }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiting = continuation
            lock.unlock()
        }
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiting != nil
    }

    func finish() {
        take()?.resume(returning: result)
    }

    func fail() {
        take()?.resume(throwing: URLError(.networkConnectionLost))
    }

    private func take() -> CheckedContinuation<TranscriptionResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = waiting
        waiting = nil
        return continuation
    }

    private var result: TranscriptionResult {
        TranscriptionResult(text: text, language: "en", duration: 1, processingTime: 0.1, segments: [])
    }
}

/// Post-processing that waits until the test lets it end.
@MainActor
final class HeldProcessor: TranscriptPostProcessor {
    var needsProcessing: Bool { true }
    private var waiting: CheckedContinuation<(String, Bool), Error>?

    var isWaiting: Bool { waiting != nil }

    func process(_ text: String, translate: Bool) async throws -> (String, Bool) {
        try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func fail() {
        let continuation = waiting
        waiting = nil
        continuation?.resume(throwing: URLError(.timedOut))
    }
}

/// Answers every voice question with one outcome, and records what it was
/// asked, what it said and how often it was told to stop saying it.
@MainActor
final class FakeAnswerer {
    private let outcome: ChatService.SendOutcome
    private(set) var asked: [String] = []
    private(set) var questions: [UUID] = []
    private(set) var spoken: [String] = []
    private(set) var stops = 0

    init(outcome: ChatService.SendOutcome) {
        self.outcome = outcome
    }

    var voiceAnswerer: TranscriptionCoordinator.VoiceAnswerer {
        let outcome = outcome
        return TranscriptionCoordinator.VoiceAnswerer(
            ask: { [weak self] text, question in
                await MainActor.run {
                    self?.asked.append(text)
                    self?.questions.append(question)
                }
                return outcome
            },
            speak: { [weak self] text in self?.spoken.append(text) },
            stopSpeaking: { [weak self] in self?.stops += 1 })
    }
}

/// Answers a voice question only when the test says so.
@MainActor
final class HeldAnswerer {
    private var waiting: CheckedContinuation<ChatService.SendOutcome, Never>?

    var voiceAnswerer: TranscriptionCoordinator.VoiceAnswerer {
        TranscriptionCoordinator.VoiceAnswerer(
            ask: { [weak self] _, _ in
                await withCheckedContinuation { continuation in
                    Task { @MainActor in self?.waiting = continuation }
                }
            },
            speak: { _ in },
            stopSpeaking: {})
    }

    func answer(_ text: String) {
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: .answered(text, pendingTool: false))
    }
}

/// A chat that answers one message at a time, as MetaChat does: a send that
/// arrives while another is still running — or still unwinding after it was
/// cancelled — is refused as busy.
final class OneAtATimeChat: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var received: [String] = []

    var texts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// Works until cancelled, then takes `unwindsFor` seconds to unwind — a
    /// wait cancellation cannot cut short — and answers at once when
    /// `unwindsFor` is 0 and nothing cancels it.
    func send(_ text: String, unwindsFor seconds: Double) async -> ChatService.SendOutcome {
        lock.lock()
        received.append(text)
        let refused = busy
        if !refused { busy = true }
        lock.unlock()
        if refused { return .busy }
        defer {
            lock.lock()
            busy = false
            lock.unlock()
        }
        guard seconds > 0 else { return .answered("The answer to \(text).", pendingTool: false) }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
        return .failed("Cancelled")
    }
}

/// What a fake ask saw, readable from the test.
final class AskRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var wasCancelled = false

    func asked(_ text: String) {
        lock.lock()
        texts.append(text)
        lock.unlock()
    }

    func cancelled() {
        lock.lock()
        wasCancelled = true
        lock.unlock()
    }

    var asks: [String] {
        lock.lock()
        defer { lock.unlock() }
        return texts
    }

    var sawCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasCancelled
    }
}
