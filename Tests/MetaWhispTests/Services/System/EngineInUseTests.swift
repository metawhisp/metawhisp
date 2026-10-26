import XCTest
@testable import MetaWhisp

/// A4 (owner, 2026-10-25) — dictation keeps working when Pro ends. The engine in use is cloud only while cloud is
/// chosen and can be used — the Pro proxy or a key of the user's own; otherwise the on-device engine transcribes. The
/// stored choice stays, so cloud comes back with Pro. It used to be cloud whenever the setting said cloud, and every
/// dictation after Pro ended failed with "API key not set for cloud transcription".
/// Through the real coordinator with a fake microphone and two fake engines; the app's settings, put back after.
@MainActor
final class EngineInUseTests: XCTestCase {
    private struct Saved {
        let engine, provider, groq, openai: String
        let autoSubmit: Bool
    }

    private var saved: Saved!
    private let onDevice = HeldEngine(text: "said on this Mac", answersAtOnce: true)
    private let cloud = HeldEngine(text: "said through the cloud", answersAtOnce: true)

    override func setUp() {
        let settings = AppSettings.shared
        saved = Saved(engine: settings.transcriptionEngine, provider: settings.cloudTranscriptionProvider,
                      groq: settings.groqKey, openai: settings.openaiKey, autoSubmit: settings.autoSubmit)
        settings.transcriptionEngine = "cloud"
        settings.cloudTranscriptionProvider = "groq"
        settings.groqKey = ""
        settings.openaiKey = ""
        settings.autoSubmit = false        // nothing is pasted
    }

    override func tearDown() {
        let settings = AppSettings.shared
        settings.transcriptionEngine = saved.engine
        settings.cloudTranscriptionProvider = saved.provider
        settings.groqKey = saved.groq
        settings.openaiKey = saved.openai
        settings.autoSubmit = saved.autoSubmit
    }

    /// The coordinator as the app wires it: `pro` says whether the Pro proxy is there.
    private func coordinator(pro: @escaping @MainActor () -> Bool,
                             onDevice: (any TranscriptionEngine)? = nil) -> TranscriptionCoordinator {
        TranscriptionCoordinator(recorder: FakeMicrophone(), whisperEngine: onDevice ?? self.onDevice,
                                 textInserter: TextInsertionService(), soundService: SoundService(enabled: { false }),
                                 settings: AppSettings.shared, voiceQuestions: VoiceQuestionState(),
                                 cloudEngine: cloud, openMicrophoneSettings: {}, proxyAvailable: pro)
    }

    private func spin(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The audio a coordinator kept in its Recovery folder — in memory: nothing is written.
    private final class Kept {
        var recordings: [[Float]] = []
    }

    /// The coordinator as the app wires it with cloud chosen, `onDevice` the on-device engine as the engine switch has
    /// left it (nil: not made yet), and its Recovery folder the test's own.
    private func standIn(pro: @escaping @MainActor () -> Bool, onDevice: (any TranscriptionEngine)?,
                         island: VoiceQuestionState? = nil) -> (TranscriptionCoordinator, Kept) {
        let flow = TranscriptionCoordinator(recorder: FakeMicrophone(), whisperEngine: onDevice,
                                            textInserter: TextInsertionService(),
                                            soundService: SoundService(enabled: { false }), settings: AppSettings.shared,
                                            voiceQuestions: island ?? VoiceQuestionState(), cloudEngine: cloud,
                                            openMicrophoneSettings: {},
                                            proxyAvailable: pro)
        let kept = Kept()
        flow.saveRecoveryAudio = { samples in
            kept.recordings.append(samples)
            return URL(fileURLWithPath: "/tmp/kept.wav")
        }
        return (flow, kept)
    }

    /// One dictation, from the key press to its transcript.
    private func dictate(_ flow: TranscriptionCoordinator, meanwhile: () -> Void = {}) {
        flow.startPTT()
        XCTAssertEqual(flow.stage, .recording)
        meanwhile()
        flow.stopPTT()
        spin(until: { flow.stage == .idle })
    }

    // MARK: - Cloud can't be used

    /// Pro ended, no key of the user's own (case 1): the next dictation works, on this Mac. The choice stays cloud.
    func testCloudChosenWithoutProOrAKeyTranscribesOnDevice() {
        let flow = coordinator(pro: { false })
        XCTAssertFalse(flow.usesCloud)
        XCTAssertTrue(flow.activeEngine === onDevice)
        dictate(flow)
        XCTAssertEqual(flow.lastResult?.text, "said on this Mac")
        XCTAssertEqual(onDevice.calls, 1)
        XCTAssertEqual(cloud.calls, 0, "nothing goes to a cloud it can't use")
        XCTAssertNil(flow.lastError)
        XCTAssertEqual(AppSettings.shared.transcriptionEngine, "cloud", "the stored choice stays")
    }

    /// The on-device engine stand-in fails like the on-device engine — the model's line (case 2), never the key
    /// error — and the recording is kept.
    func testCloudChosenWithoutProOrAKeyNeverSaysTheKeyError() {
        let (flow, kept) = standIn(pro: { false }, onDevice: LoadableEngine())   // no model loaded yet…
        flow.engineStatusLine = { TranscriptionCoordinator.noModelLoaded }      // …and none to load: the owner's line
        dictate(flow)
        XCTAssertEqual(flow.lastError, TranscriptionCoordinator.notTranscribed(
            savedAt: URL(fileURLWithPath: "/tmp/kept.wav"), TranscriptionCoordinator.noModelLoaded))
        XCTAssertFalse(flow.lastError?.contains("API key") ?? true)
        XCTAssertEqual(cloud.calls, 0)
        XCTAssertEqual(kept.recordings.count, 1)
    }

    /// Its release: Pro comes back (case 4), and cloud is in use again — read at each ask, no relaunch.
    func testProComingBackFiresCloudAnyway() {
        var pro = false
        let flow = coordinator(pro: { pro })
        XCTAssertFalse(flow.usesCloud)
        pro = true
        XCTAssertTrue(flow.usesCloud)
        XCTAssertTrue(flow.activeEngine === cloud)
        dictate(flow)
        XCTAssertEqual(cloud.calls, 1)
        XCTAssertEqual(onDevice.calls, 0)
    }

    /// A key of the user's own (case 3): cloud with the key, no Pro needed — the key of the provider chosen.
    func testAKeyOfTheUsersOwnKeepsCloudInUse() {
        let flow = coordinator(pro: { false })
        AppSettings.shared.groqKey = "gsk_test"
        XCTAssertTrue(flow.usesCloud)
        XCTAssertTrue(flow.activeEngine === cloud)
        AppSettings.shared.cloudTranscriptionProvider = "openai"
        XCTAssertFalse(flow.usesCloud, "the key is for the other provider")
    }

    /// The on-device choice is on-device, Pro or not.
    func testOnDeviceChosenStaysOnDeviceWithPro() {
        AppSettings.shared.transcriptionEngine = "ondevice"
        let flow = coordinator(pro: { true })
        XCTAssertFalse(flow.usesCloud)
        XCTAssertTrue(flow.activeEngine === onDevice)
    }

    // MARK: - Pro changes while a recording runs

    /// Pro ends mid-recording (case 5): the recording is transcribed by the engine that works when it is transcribed.
    func testProEndingDuringARecordingTranscribesItOnDevice() {
        var pro = true
        let flow = coordinator(pro: { pro })
        dictate(flow, meanwhile: { pro = false })
        XCTAssertEqual(flow.lastResult?.text, "said on this Mac")
        XCTAssertEqual(cloud.calls, 0)
    }

    /// …and Pro coming back mid-recording sends it to cloud.
    func testProReturningDuringARecordingTranscribesItThroughTheCloud() {
        var pro = false
        let flow = coordinator(pro: { pro })
        dictate(flow, meanwhile: { pro = true })
        XCTAssertEqual(flow.lastResult?.text, "said through the cloud")
        XCTAssertEqual(onDevice.calls, 0)
    }

    // MARK: - Pro ends during a recording, the on-device engine not ready yet

    /// Pro ends mid-dictation while cloud is the engine, so no on-device engine exists yet: the engine switch makes it
    /// and its model loads a moment later. The recording waits for it and is transcribed on this Mac — its samples
    /// were dropped at "engine not ready" (Codex P1, 1.4.0 review).
    func testProEndingDuringADictationWaitsForTheOnDeviceEngineAndTranscribesIt() {
        var pro = true
        let late = LateEngine()
        let (flow, kept) = standIn(pro: { pro }, onDevice: nil)
        flow.startPTT()
        pro = false
        flow.stopPTT()
        wait(0.3)
        XCTAssertEqual(flow.stage, .processing, "the recording waits")
        flow.whisperEngine = late                                     // the engine switch makes it…
        wait(0.3)
        Task { try? await late.loadModel("base", progressHandler: nil) }   // …and its model loads
        spin(until: { flow.stage == .idle })
        XCTAssertEqual(flow.lastResult?.text, "said on this Mac")
        XCTAssertEqual(late.calls, 1)
        XCTAssertEqual(cloud.calls, 0)
        XCTAssertTrue(kept.recordings.isEmpty, "transcribed, so nothing needed keeping")
        XCTAssertNil(flow.lastError)
    }

    /// The same for a voice question: its engine is there but its model still loads; once it has, the transcript goes
    /// to MetaChat.
    func testProEndingDuringAVoiceQuestionWaitsForTheOnDeviceEngineAndAsksTheTranscript() {
        var pro = true
        let late = LateEngine()
        let island = VoiceQuestionState()
        defer { island.dismiss() }
        let (flow, kept) = standIn(pro: { pro }, onDevice: late, island: island)
        let answerer = FakeAnswerer(outcome: .answered("Here it is.", pendingTool: false))
        flow.voiceAnswerer = answerer.voiceAnswerer
        flow.startVoiceQuestion()
        pro = false
        flow.stopVoiceQuestion()
        wait(0.3)
        Task { try? await late.loadModel("base", progressHandler: nil) }
        spin(until: { !answerer.asked.isEmpty })
        XCTAssertEqual(answerer.asked, ["said on this Mac"])
        XCTAssertEqual(cloud.calls, 0)
        XCTAssertTrue(kept.recordings.isEmpty)
    }

    /// The wait's ceiling: an engine still getting ready — a download that never ends — holds the recording only until
    /// `engineWaitLimit`; then its audio is kept anyway and the line says where.
    func testTheWaitForTheOnDeviceEngineKeepsTheAudioAnywayAfterItsCeiling() {
        var pro = true
        let (flow, kept) = standIn(pro: { pro }, onDevice: LateEngine())
        flow.engineStatusLine = { TranscriptionCoordinator.preparingModel(0.4) }
        flow.engineWaitLimit = .milliseconds(600)
        flow.startPTT()
        pro = false
        flow.stopPTT()
        wait(0.3)
        XCTAssertEqual(flow.stage, .processing, "within the ceiling it waits")
        XCTAssertTrue(kept.recordings.isEmpty)
        spin(until: { flow.stage == .idle })
        XCTAssertEqual(kept.recordings.count, 1, "past it, kept")
        XCTAssertEqual(flow.lastError, TranscriptionCoordinator.notTranscribed(
            savedAt: URL(fileURLWithPath: "/tmp/kept.wav"), TranscriptionCoordinator.preparingModel(0.4)))
    }

    /// Esc while a voice question waits for its engine closes it as at any other point: the coordinator is free at
    /// once, and nothing of it is kept.
    func testAVoiceQuestionClosedWhileItWaitsKeepsNothing() {
        var pro = true
        let island = VoiceQuestionState()
        let (flow, kept) = standIn(pro: { pro }, onDevice: LateEngine(), island: island)
        flow.startVoiceQuestion()
        pro = false
        flow.stopVoiceQuestion()
        wait(0.3)
        island.dismiss()
        XCTAssertEqual(flow.stage, .idle)
        wait(0.5)
        XCTAssertTrue(kept.recordings.isEmpty)
    }

    /// Esc as the engine becomes ready (Codex P2, 1.4.0 review): its model loads — or Pro comes back — and Esc closes
    /// the question between two looks of the wait, so the next look finds the engine ready and the question closed. A
    /// closed question costs no transcription: none is made, nothing is asked, nothing kept. The wait looks at the
    /// engine before its cancel, and handed it back: the closed question went to transcription.
    func testAVoiceQuestionClosedAsItsEngineBecomesReadyIsNotTranscribed() {
        for readiness in ["its model loads", "Pro comes back"] {
            var pro = true
            let late = LateEngine()
            let island = VoiceQuestionState()
            let (flow, kept) = standIn(pro: { pro }, onDevice: late, island: island)
            let answerer = FakeAnswerer(outcome: .answered("Here it is.", pendingTool: false))
            flow.voiceAnswerer = answerer.voiceAnswerer
            flow.startVoiceQuestion()
            pro = false
            flow.stopVoiceQuestion()
            wait(0.3)
            XCTAssertEqual(flow.stage, .processing, "the recording waits for its engine: \(readiness)")
            if readiness == "Pro comes back" { pro = true } else { late.loadNow() }
            island.dismiss()                                    // both before the wait looks again
            wait(0.5)
            XCTAssertEqual(late.calls + cloud.calls, 0, "no transcription: \(readiness)")
            XCTAssertTrue(answerer.asked.isEmpty, readiness)
            XCTAssertTrue(kept.recordings.isEmpty, readiness)
            XCTAssertEqual(flow.stage, .idle, readiness)
        }
    }

    /// Nothing can get it ready — the readiness owner says no model can be had: the dictation's audio is kept in the
    /// Recovery folder and the line says where, with the engine's own line. It used to be dropped.
    func testAnOnDeviceEngineThatCannotBeReadyKeepsTheDictationsAudio() {
        var pro = true
        let (flow, kept) = standIn(pro: { pro }, onDevice: LateEngine())
        flow.engineStatusLine = { TranscriptionCoordinator.noModelLoaded }
        dictate(flow, meanwhile: { pro = false })
        XCTAssertEqual(kept.recordings.map(\.count), [16_000], "the recording itself")
        XCTAssertEqual(flow.lastError, "Not transcribed — audio saved to /tmp/kept.wav. "
                           + TranscriptionCoordinator.noModelLoaded)
        XCTAssertNil(flow.lastResult)
        XCTAssertEqual(flow.stage, .idle)
    }

    /// …and a voice question's: kept, and the island ends in an error.
    func testAnOnDeviceEngineThatCannotBeReadyKeepsTheVoiceQuestionsAudio() {
        var pro = true
        let island = VoiceQuestionState()
        defer { island.dismiss() }
        let (flow, kept) = standIn(pro: { pro }, onDevice: LateEngine(), island: island)
        flow.engineStatusLine = { TranscriptionCoordinator.noModelLoaded }
        flow.startVoiceQuestion()
        pro = false
        flow.stopVoiceQuestion()
        spin(until: { flow.stage == .idle })
        XCTAssertEqual(kept.recordings.count, 1)
        XCTAssertEqual(island.phase, .error(text: "Transcription engine not ready."))
    }

    // MARK: - Every reader reads the engine in use

    /// Meetings (case 6) take the engine in use from the coordinator at every chunk (`engineSource`, over
    /// `activeEngine`), the live meeting advisor and the practice take `activeEngine`; the launch load, the engine
    /// switch, the model upgrade and readiness ask `usesCloud`. Nothing but the coordinator decides which engine
    /// runs from the stored choice: the Settings picker shows the choice, and the model preparer asks it only to
    /// know that on-device stands in for cloud.
    func testOnlyTheCoordinatorDecidesWhichEngineRunsFromTheChoice() throws {
        let comparison = try NSRegularExpression(pattern: #"transcriptionEngine\s*[!=]="#)
        let allowed: Set<String> = ["Services/System/TranscriptionCoordinator.swift",
                                    "Services/Transcription/ModelPreparer.swift",
                                    "Views/Windows/MainSettingsView.swift"]
        var found: Set<String> = []
        for (path, lines) in try sources(under: ["App", "Models", "Services", "Views", "Helpers"]) {
            for (number, line) in lines.enumerated()
            where comparison.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                found.insert(path)
                XCTAssertTrue(allowed.contains(path), "\(path):\(number + 1) decides from the stored choice: \(line)")
            }
        }
        XCTAssertTrue(found.contains("Services/System/TranscriptionCoordinator.swift"), "the guard reads the owner")
        let delegate = try sources(under: ["App"]).first { $0.path == "App/AppDelegate.swift" }?.lines ?? []
        XCTAssertTrue(delegate.contains { $0.contains("coordinator.engineSource(") }, "meetings take the engine in use")
        XCTAssertTrue(delegate.contains { $0.contains("coordinator.usesCloud") }, "the launch and the switch ask it")
    }

    // MARK: - Helpers

    /// …/Tests/MetaWhispTests/Services/System/EngineInUseTests.swift → the repository's root.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every Swift file under `folders`, as code lines (line comments stripped), by its path from the root.
    private func sources(under folders: [String]) throws -> [(path: String, lines: [String])] {
        var out: [(String, [String])] = []
        for folder in folders {
            let base = repoRoot.appendingPathComponent(folder)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                    .map { raw in raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw }
                out.append(("\(folder)/" + url.path.dropFirst(base.path.count + 1), lines))
            }
        }
        XCTAssertFalse(out.isEmpty, "the guard reads the sources")
        return out
    }
}

/// An on-device engine that holds no model until it is loaded — as WhisperKit, which the engine switch makes when
/// cloud goes out of reach — and then says what it heard.
final class LateEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "Late engine"
    private let lock = NSLock()
    private var loaded = false
    private var count = 0
    private let text: String

    init(text: String = "said on this Mac") {
        self.text = text
    }

    var isModelLoaded: Bool { lock.withLock { loaded } }
    var calls: Int { lock.withLock { count } }

    func loadModel(_ modelName: String, progressHandler: (@Sendable (Double) -> Void)?) async throws {
        loadNow()
    }

    /// Its model is loaded from now on — at once, where the test says, not when a task gets to it.
    func loadNow() {
        lock.withLock { loaded = true }
    }

    func unloadModel() async {
        lock.withLock { loaded = false }
    }

    func transcribe(audioSamples: [Float], language: String?, promptWords: [String],
                    countUsage: Bool) async throws -> TranscriptionResult {
        guard isModelLoaded else { throw TranscriptionError.modelNotLoaded }
        lock.withLock { count += 1 }
        return TranscriptionResult(text: text, language: "en", duration: 1, processingTime: 0.1, segments: [])
    }
}
