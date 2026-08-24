import XCTest
@testable import MetaWhisp

/// The transcribe request used a flat 60-second timeout no matter how much
/// audio it carried. Short dictations fit; meeting chunks did not, and the log
/// from 2026-08-24 shows six failures in a row at exactly the 60-second mark —
/// a 167.9s chunk, then a 104.8s chunk, then a 149.4s chunk, each twice.
/// Every one of those chunks was dropped from the saved transcript.
///
/// The budget now scales with the audio, so a long chunk gets proportionally
/// long to come back. These pin the shape of that budget.
final class CloudRequestTimeoutTests: XCTestCase {

    /// Dictation is interactive — the user is waiting and wants a fast, honest
    /// failure. Short audio must keep the old 60-second budget exactly.
    func testShortDictationKeepsTheSixtySecondFloor() {
        XCTAssertEqual(CloudWhisperEngine.requestTimeout(forAudioSeconds: 1.5), 60, accuracy: 0.01)
        XCTAssertEqual(CloudWhisperEngine.requestTimeout(forAudioSeconds: 15.8), 60, accuracy: 0.01)
    }

    /// The exact chunk lengths that failed must now get more than 60 seconds.
    func testTheChunkLengthsThatFailedNowGetRoom() {
        for seconds in [104.8, 149.4, 167.9] {
            XCTAssertGreaterThan(
                CloudWhisperEngine.requestTimeout(forAudioSeconds: seconds), 120,
                "\(seconds)s of audio timed out at 60s in production")
        }
    }

    /// Budget grows with the audio, never shrinks.
    func testBudgetIsMonotonic() {
        var previous = 0.0
        for seconds in stride(from: 0.0, through: 400.0, by: 20.0) {
            let t = CloudWhisperEngine.requestTimeout(forAudioSeconds: seconds)
            XCTAssertGreaterThanOrEqual(t, previous)
            previous = t
        }
    }

    /// A dead server must not hold a meeting finalize open forever.
    func testBudgetIsCapped() {
        XCTAssertLessThanOrEqual(CloudWhisperEngine.requestTimeout(forAudioSeconds: 100_000), 600)
    }

    /// Nonsense input cannot produce a zero or negative timeout, which
    /// URLSession would read as "use the default".
    func testDegenerateInputStillGetsTheFloor() {
        XCTAssertEqual(CloudWhisperEngine.requestTimeout(forAudioSeconds: 0), 60, accuracy: 0.01)
        XCTAssertEqual(CloudWhisperEngine.requestTimeout(forAudioSeconds: -5), 60, accuracy: 0.01)
        XCTAssertEqual(CloudWhisperEngine.requestTimeout(forAudioSeconds: .nan), 60, accuracy: 0.01)
        XCTAssertEqual(CloudWhisperEngine.requestTimeout(forAudioSeconds: .infinity), 600, accuracy: 0.01)
    }
}
