import XCTest
@testable import MetaWhisp

/// 2026-08-12 — a meeting whose MIC channel was digital silence.
///
/// The founder recorded a call. It transcribed fine and saved a readable
/// transcript — containing only the other side. His own microphone had
/// delivered 758 400 samples that were every one of them bit-exact zero, and
/// nothing in the pipeline noticed, because:
///   • every count-based guard saw 758 400 samples and said "captured";
///   • every silence guard reads `max(mic, system)`, and the call was playing
///     loudly through the system channel;
///   • the empty-transcript reporter never ran, since the transcript was not
///     empty.
/// These cases pin the two behaviours that close that hole.
final class MeetingMicSilenceTests: XCTestCase {

    private typealias R = MeetingRecorder.EmptyTranscriptReason

    /// The incident's exact shape: 47.4 s of mic at 16 kHz, all zeros.
    private var incidentBuffer: [Float] { [Float](repeating: 0, count: 758_400) }

    // MARK: - isDigitalSilence

    func test_theIncidentBuffer_isDigitalSilence() {
        XCTAssertTrue(MeetingRecorder.isDigitalSilence(incidentBuffer),
                      "A full-length mic channel of bit-exact zeros must be recognised")
    }

    func test_oneNonZeroSample_meansTheMicWasAlive() {
        // A single non-zero sample anywhere proves signal reached the app.
        // Anything weaker than this is a judgement about loudness, not liveness.
        var samples = incidentBuffer
        samples[samples.count - 1] = .leastNonzeroMagnitude
        XCTAssertFalse(MeetingRecorder.isDigitalSilence(samples))
    }

    func test_quietRoomNoiseFloor_isNotDigitalSilence() {
        // A real silent room on the built-in mic. Must never be reported as a
        // dead mic — that false positive would fire on every quiet meeting.
        let samples = (0 ..< 758_400).map { i in Float(i % 2 == 0 ? 0.0002 : -0.0002) }
        XCTAssertFalse(MeetingRecorder.isDigitalSilence(samples))
    }

    func test_tooShortToJudge_isNotReportedAsSilence() {
        // Under half a second the capture was broken, not silent — that is
        // `micNeverCaptured`'s job, and double-reporting would be wrong.
        XCTAssertFalse(MeetingRecorder.isDigitalSilence([Float](repeating: 0, count: 7999)))
        XCTAssertFalse(MeetingRecorder.isDigitalSilence([]))
    }

    func test_exactlyAtTheSampleFloor_isJudged() {
        XCTAssertTrue(MeetingRecorder.isDigitalSilence([Float](repeating: 0, count: 8000)))
    }

    // MARK: - emptyTranscriptReason

    func test_digitalSilence_outranksGenuineSilence() {
        // Same inputs as a genuinely silent room, except the mic peaked at zero.
        XCTAssertEqual(
            MeetingRecorder.emptyTranscriptReason(
                failedChunks: 0, micSamples: 758_400, systemSamples: 760_314,
                micPeakWasZero: true
            ),
            R.micDeliveredSilence
        )
        XCTAssertEqual(
            MeetingRecorder.emptyTranscriptReason(
                failedChunks: 0, micSamples: 758_400, systemSamples: 760_314,
                micPeakWasZero: false
            ),
            R.genuinelySilent
        )
    }

    func test_failedChunksStillWin_overDigitalSilence() {
        // A transcription failure is more specific and more actionable.
        XCTAssertEqual(
            MeetingRecorder.emptyTranscriptReason(
                failedChunks: 2, micSamples: 758_400, systemSamples: 0, micPeakWasZero: true
            ),
            R.chunksFailed(2)
        )
    }

    func test_micNeverCaptured_stillWins_whenThereIsNoBufferAtAll() {
        // No samples at all is a start-up failure, not a silent stream.
        XCTAssertEqual(
            MeetingRecorder.emptyTranscriptReason(
                failedChunks: 0, micSamples: 0, systemSamples: 480_000, micPeakWasZero: true
            ),
            R.micNeverCaptured
        )
    }

    func test_defaultArgument_preservesLegacyBehaviour() {
        // Callers that don't measure the peak must get exactly what they got
        // before this parameter existed.
        XCTAssertEqual(
            MeetingRecorder.emptyTranscriptReason(
                failedChunks: 0, micSamples: 758_400, systemSamples: 0
            ),
            R.genuinelySilent
        )
    }

    // MARK: - The message

    func test_deadMicMessage_namesTheRemedyThatWorked() {
        let message = R.micDeliveredSilence.userMessage
        XCTAssertTrue(message.contains("coreaudiod"),
                      "The message must carry the fix that actually cleared this in the field")
        XCTAssertNotEqual(message, R.genuinelySilent.userMessage,
                          "A dead mic must not be reported as the user having said nothing")
        XCTAssertNotEqual(message, R.micNeverCaptured.userMessage)
    }
}
