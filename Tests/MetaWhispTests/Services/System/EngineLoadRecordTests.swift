import XCTest
@testable import MetaWhisp

/// Step-1 review #7 — a model is recorded only for the engine dictation still
/// uses. A load runs for a long while (the CoreML weights); an engine switch
/// can replace the engine meanwhile, and the replaced one's late success or
/// failure used to be published as the live engine's — onboarding then said
/// ready while the new engine held nothing.
@MainActor
final class EngineLoadRecordTests: XCTestCase {

    private func coordinator(_ engine: LoadableEngine?) -> TranscriptionCoordinator {
        TranscriptionCoordinator(recorder: FakeMicrophone(), whisperEngine: engine, textInserter: TextInsertionService(),
                                 soundService: SoundService(enabled: { false }), settings: AppSettings.shared,
                                 voiceQuestions: VoiceQuestionState(), cloudEngine: HeldEngine(answersAtOnce: true),
                                 openMicrophoneSettings: {})
    }

    private func spin(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testALoadIntoTheLiveEngineIsRecorded() async throws {
        let engine = LoadableEngine()
        let flow = coordinator(engine)
        let recorded = try await flow.load("base", variant: "openai_whisper-base", into: engine)
        XCTAssertTrue(recorded)
        XCTAssertEqual(flow.loadedWhisperModelId, "base")
        XCTAssertTrue(engine.isModelLoaded)
    }

    func testAReplacedEnginesLateLoadIsNotRecorded() throws {
        let old = LoadableEngine(holds: true)
        let flow = coordinator(old)
        let outcome = Box<Bool>()
        Task { outcome.value = try await flow.load("large-v3-turbo", variant: "openai_whisper-large-v3_turbo", into: old) }
        spin(until: { old.isWaiting })
        let replacement = LoadableEngine(holds: true)
        flow.whisperEngine = replacement      // cloud → on-device made a new engine
        old.finish()
        spin(until: { outcome.value != nil })
        XCTAssertEqual(outcome.value, false)
        XCTAssertNil(flow.loadedWhisperModelId, "nothing is said about the engine in use")
        XCTAssertFalse(replacement.isModelLoaded)
    }

    func testAReplacedEnginesFailureIsNotReported() throws {
        let old = LoadableEngine(holds: true)
        let flow = coordinator(old)
        let outcome = Box<Result<Bool, Error>>()
        Task {
            do { outcome.value = .success(try await flow.load("base", variant: "openai_whisper-base", into: old)) }
            catch { outcome.value = .failure(error) }
        }
        spin(until: { old.isWaiting })
        flow.whisperEngine = LoadableEngine()
        old.fail()
        spin(until: { outcome.value != nil })
        guard case .success(false)? = outcome.value else { return XCTFail("\(String(describing: outcome.value))") }
    }

    func testTheLiveEnginesFailureIsThrown() async {
        let engine = LoadableEngine(failure: URLError(.cannotDecodeContentData))
        let flow = coordinator(engine)
        do {
            _ = try await flow.load("base", variant: "openai_whisper-base", into: engine)
            XCTFail("the live engine's failure must reach its caller")
        } catch {
            XCTAssertNil(flow.loadedWhisperModelId)
        }
    }
}

/// An on-device engine whose load finishes at once, or when the test says,
/// or fails; it holds a model only after a load that went through.
final class LoadableEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "Loadable engine"
    private let lock = NSLock()
    private let holds: Bool
    private let failure: Error?
    private var loaded = false
    private var held: CheckedContinuation<Void, Error>?

    init(holds: Bool = false, failure: Error? = nil, loaded: Bool = false) {
        self.holds = holds
        self.failure = failure
        self.loaded = loaded
    }

    var isModelLoaded: Bool { lock.withLock { loaded } }
    var isWaiting: Bool { lock.withLock { held != nil } }

    func loadModel(_ modelName: String, progressHandler: (@Sendable (Double) -> Void)?) async throws {
        if let failure { throw failure }
        if holds {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { held = continuation }
            }
        }
        lock.withLock { loaded = true }
    }

    func finish() { take()?.resume() }
    func fail() { take()?.resume(throwing: URLError(.cannotDecodeContentData)) }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { held = nil }
            return held
        }
    }

    func unloadModel() async { lock.withLock { loaded = false } }

    func transcribe(audioSamples: [Float], language: String?, promptWords: [String],
                    countUsage: Bool) async throws -> TranscriptionResult {
        TranscriptionResult(text: "", language: nil, duration: 0, processingTime: 0, segments: [])
    }
}
