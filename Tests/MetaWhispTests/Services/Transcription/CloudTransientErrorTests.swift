import XCTest
@testable import MetaWhisp

/// ITER-060.4 — dictation's cloud path had ZERO retries: a single DNS blip
/// (Tailscale MagicDNS hiccup, 2026-08-08: «A server with the specified
/// hostname could not be found») failed the whole dictation instantly.
/// Fast-fail transport errors get a quick retry; slow or hopeless ones don't.
final class CloudTransientErrorTests: XCTestCase {

    private func urlError(_ code: URLError.Code) -> Error { URLError(code) }

    func test_fastFailTransportErrors_retryable() {
        XCTAssertTrue(CloudWhisperEngine.isTransientTransportError(urlError(.cannotFindHost)))
        XCTAssertTrue(CloudWhisperEngine.isTransientTransportError(urlError(.dnsLookupFailed)))
        XCTAssertTrue(CloudWhisperEngine.isTransientTransportError(urlError(.cannotConnectToHost)))
        XCTAssertTrue(CloudWhisperEngine.isTransientTransportError(urlError(.networkConnectionLost)))
    }

    func test_slowOrHopelessErrors_notRetryable() {
        // timedOut already burned the full timeout — retrying doubles the wait.
        XCTAssertFalse(CloudWhisperEngine.isTransientTransportError(urlError(.timedOut)))
        // Offline is not transient — fail fast so Recovery-save fires.
        XCTAssertFalse(CloudWhisperEngine.isTransientTransportError(urlError(.notConnectedToInternet)))
        XCTAssertFalse(CloudWhisperEngine.isTransientTransportError(urlError(.cancelled)))
    }

    func test_nonURLErrors_notRetryable() {
        XCTAssertFalse(CloudWhisperEngine.isTransientTransportError(
            TranscriptionError.transcriptionFailed("HTTP 500")))
    }
}
