import Foundation
@testable import MetaWhisp

/// A fake engine: it records every call and answers from a handler the test
/// controls, so a call can hang, fail, or come back with segments.
final class FakeLiveEngine: TranscriptionEngine, @unchecked Sendable {

    /// One call the engine received.
    struct Call: Equatable {
        let sampleCount: Int
        let language: String?
        let promptWords: [String]
        let countUsage: Bool
    }

    /// Answers a call. The index is the call's number, starting at zero.
    typealias Responder = @Sendable (Int) async throws -> TranscriptionResult

    let name = "Fake live engine"
    let isModelLoaded = true

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var responder: Responder?

    init(responder: Responder? = nil) {
        self.responder = responder
    }

    func setResponder(_ responder: @escaping Responder) {
        lock.withLock { self.responder = responder }
    }

    func loadModel(_ modelName: String, progressHandler: (@Sendable (Double) -> Void)?) async throws {}
    func unloadModel() async {}

    func transcribe(audioSamples: [Float], language: String?, promptWords: [String],
                    countUsage: Bool) async throws -> TranscriptionResult {
        let index = lock.withLock { () -> Int in
            recorded.append(Call(sampleCount: audioSamples.count,
                                 language: language,
                                 promptWords: promptWords,
                                 countUsage: countUsage))
            return recorded.count - 1
        }
        let responder = lock.withLock { self.responder }
        guard let responder else { return Self.result("the text") }
        return try await responder(index)
    }

    /// Every call, in order.
    var calls: [Call] { lock.withLock { recorded } }

    /// How many calls the engine received.
    var callCount: Int { lock.withLock { recorded.count } }

    /// A result with the given text.
    static func result(_ text: String,
                       segments: [TranscriptionResult.Segment] = []) -> TranscriptionResult {
        TranscriptionResult(text: text, language: "en", duration: 1, processingTime: 0.1, segments: segments)
    }
}

/// The error the live worker answers with when the monthly meeting minutes
/// are used up.
struct FakeEngineError: Error, CustomStringConvertible, Equatable {
    let description: String
}
