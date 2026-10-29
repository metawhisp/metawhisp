import Foundation
import XCTest
@testable import MetaWhisp

/// The replay of two recorded clips (T14).
///
/// The clips were spoken by the machine and are in the repository: a question
/// and a statement. They go through the real detector and the real tracker,
/// and the answers come from the real transcript and the real answer service
/// with a fake backend.
///
/// The question gives one gated request whose ask quotes the question. The
/// statement gives one gated request too, and the backend answers
/// `[no-answer]` — so nothing is shown (§3.5).
///
/// The second test runs the same clip through the real WhisperKit engine,
/// when its base model is on disk. It is skipped otherwise.
@MainActor
final class LiveHintsReplayTests: XCTestCase {

    // MARK: - The clips

    /// What the machine said in the question.
    static let question = "When can you send the proposal?"
    /// What the machine said in the statement.
    static let statement = "The weather was nice this weekend."

    // MARK: - The helpers

    /// The samples of a fixture, with a second of silence after them: an
    /// utterance closes on silence, so the clip needs one.
    static func samples(of fixture: String) throws -> [Float] {
        let url = fixtures
            .appendingPathComponent("Fixtures/LiveHints/\(fixture).wav")
        let data = try Data(contentsOf: url)
        let spoken = try Self.wavSamples(data)
        return spoken + [Float](repeating: 0, count: 32_000)
    }

    /// The samples of a 16-bit mono WAV file.
    static func wavSamples(_ data: Data) throws -> [Float] {
        var offset = 12
        while offset + 8 <= data.count {
            let identifier = String(data: data.subdata(in: offset ..< offset + 4),
                                    encoding: .ascii) ?? ""
            let size = Int(data.subdata(in: offset + 4 ..< offset + 8)
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            if identifier == "data" {
                let start = offset + 8
                let end = min(start + size, data.count)
                var values: [Float] = []
                values.reserveCapacity((end - start) / 2)
                var index = start
                while index + 2 <= end {
                    let raw = Int16(littleEndian: data.subdata(in: index ..< index + 2)
                        .withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
                    values.append(Float(raw) / 32_768)
                    index += 2
                }
                return values
            }
            offset += 8 + size + (size % 2)
        }
        throw NSError(domain: "LiveHintsReplay", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "the WAV file holds no audio"])
    }

    /// The repository's root — the fixtures live beside the tests, and
    /// SwiftPM does not copy them into a bundle.
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LiveHints
            .deletingLastPathComponent()   // Intelligence
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // MetaWhispTests
    }

    /// Feeds the samples the way the recorder hands them over.
    private func feed(_ tracker: UtteranceTracker, _ samples: [Float], chunk: Int = 800) async {
        var index = 0
        while index < samples.count {
            let end = min(index + chunk, samples.count)
            await tracker.append(Array(samples[index ..< end]))
            index = end
        }
    }

    /// Waits until the tracker has closed `count` utterances.
    private func waitForUtterances(_ count: Int,
                                   in tracker: UtteranceTracker,
                                   timeout: Double = 20) async -> [UtteranceTracker.ClosedUtterance] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let closed = await tracker.closedUtterances
            if closed.count >= count { return closed }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await tracker.closedUtterances
    }

    // MARK: - The replay

    /// The question gives one gated request whose ask quotes the question.
    func testTheQuestionGivesOneGatedRequestThatQuotesIt() async throws {
        let harness = makeAnswerHarness(isAutoOn: { true })
        let samples = try Self.samples(of: "question")

        let tracker = UtteranceTracker(speaker: .them,
                                       transcriber: FakeLiveTranscriber(responder: { _, _ in Self.question }),
                                       audioSource: FakeLiveAudioSource(samples: samples))
        await feed(tracker, samples)
        let closed = await waitForUtterances(1, in: tracker)
        let text = try XCTUnwrap(closed.first?.text, "the question was never heard")

        XCTAssertEqual(text, Self.question)
        XCTAssertEqual(closed.count, 1, "the clip was cut into more than one utterance")

        // The line goes into the transcript, and the answers hear about it.
        await appendThemLine(harness.transcript, text: text, from: 0)
        await harness.service.themLineEnded(themLine(text: text, from: 0))
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.requestCount, 1, "the question called the model more than once")
        let request = try XCTUnwrap(harness.pro.requests.first)
        XCTAssertTrue(request.user.contains("If this asks the user something"),
                      "the automatic check did not use the gated ask")
        XCTAssertTrue(request.user.contains("Heard in the meeting: \"\(Self.question)\""),
                      "the gated ask did not quote the question")
    }

    /// The statement gives one gated request, and the backend answers
    /// `[no-answer]`: nothing is shown.
    func testTheStatementGivesOneRequestAndNothingIsShown() async throws {
        let harness = makeAnswerHarness(isAutoOn: { true })
        harness.pro.replies = [MeetingAnswerReply(status: 200, retryAfter: nil, text: "[no-answer]")]
        let samples = try Self.samples(of: "statement")

        let tracker = UtteranceTracker(speaker: .them,
                                       transcriber: FakeLiveTranscriber(responder: { _, _ in Self.statement }),
                                       audioSource: FakeLiveAudioSource(samples: samples))
        await feed(tracker, samples)
        let closed = await waitForUtterances(1, in: tracker)
        let text = try XCTUnwrap(closed.first?.text, "the statement was never heard")

        XCTAssertEqual(text, Self.statement)

        await appendThemLine(harness.transcript, text: text, from: 0)
        await harness.service.themLineEnded(themLine(text: text, from: 0))
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.requestCount, 1, "the statement called the model more than once")
        XCTAssertTrue(harness.state.answers.isEmpty, "a statement was shown as an answer")
    }

    // MARK: - The real engine

    /// The same question, through the real WhisperKit engine. It is skipped
    /// when the base model is not on disk.
    func testTheQuestionThroughTheRealEngineOnDisk() async throws {
        guard let base = Self.baseModelFolder() else {
            throw XCTSkip("the WhisperKit base model is not on disk")
        }
        let engine = WhisperKitEngine(downloadBase: base)
        try await engine.loadModel("openai_whisper-base", progressHandler: nil)
        let samples = try Self.samples(of: "question")

        let transcriber = LiveEngineTranscriber(engineProvider: { engine },
                                                languageProvider: { "en" },
                                                promptWordsProvider: { _ in [] },
                                                generationProvider: { 1 })
        let tracker = UtteranceTracker(speaker: .them,
                                       transcriber: transcriber,
                                       audioSource: FakeLiveAudioSource(samples: samples))
        await feed(tracker, samples)
        let closed = await waitForUtterances(1, in: tracker, timeout: 60)
        let text = try XCTUnwrap(closed.first?.text, "the engine heard nothing")

        XCTAssertFalse(text.isEmpty, "the engine heard nothing")
        XCTAssertTrue(text.lowercased().contains("proposal"),
                      "the engine heard «\(text)»")
    }

    /// The folder the WhisperKit base model is in, if it is on disk.
    static func baseModelFolder() -> URL? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates = [
            home.appendingPathComponent("Documents/huggingface"),
            home.appendingPathComponent("Library/Application Support/MetaWhisp/huggingface"),
        ]
        for base in candidates {
            let model = base
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-base")
            if FileManager.default.fileExists(atPath: model.path) { return base }
        }
        return nil
    }
}
