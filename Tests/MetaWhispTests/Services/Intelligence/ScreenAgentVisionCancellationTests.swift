import XCTest
@testable import MetaWhisp

/// Withdrawing consent has to stop the request, not just ignore the answer.
///
/// The frame is already on the wire by then: a JPEG of the user's screen, at
/// our proxy, on its way to a model provider. Re-checking consent after the
/// await and discarding the result leaves the picture exactly where the user
/// just said it must not go. Discarding is not cancelling.
final class ScreenAgentVisionCancellationTests: XCTestCase {

    /// A transport that takes its time and reports whether it was cancelled
    /// while doing so — which is the only thing this test is actually about.
    private final class SlowTransport: ScreenAgentVisionTransport, @unchecked Sendable {
        private(set) var wasCancelled = false
        private(set) var started = false
        let echo: ScreenAgentVisionResponse

        init(echo: ScreenAgentVisionResponse) { self.echo = echo }

        func analyze(_ request: ScreenAgentVisionRequest) async throws -> ScreenAgentVisionResponse {
            started = true
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                wasCancelled = true
                throw error
            }
            return echo
        }
    }

    @MainActor
    func testWithdrawingConsentCancelsTheRequestInFlight() async throws {
        let contextID = UUID()
        let jpeg = Data(repeating: 0xFF, count: 64)
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: contextID, jpeg: jpeg, generation: 1)
        let cached = try XCTUnwrap(cache.take(matching: contextID))
        cache.store(contextID: contextID, jpeg: jpeg, generation: 1)

        let transport = SlowTransport(echo: ScreenAgentVisionResponse(
            contextID: contextID, generation: 1, frameHash: cached.contentHash, facts: []))
        let client = ScreenAgentVisionClient(transport: transport, cache: cache)

        // Consent is live at the start and withdrawn while the model works.
        let consent = ConsentBox()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            consent.granted = false
        }

        let started = Date()
        let outcome = await client.analyzeCurrentFrame(
            contextID: contextID,
            visualConsentGranted: { consent.granted },
            isStillCurrent: { true })
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(transport.started, "the request has to have been in flight for this to mean anything")
        XCTAssertTrue(transport.wasCancelled,
                      "withdrawing consent must cancel the upload, not wait for it and bin the answer")
        XCTAssertLessThan(elapsed, 2.0,
                          "the caller must not sit through a request nobody is allowed to use")
        XCTAssertNotEqual(outcome, ScreenAgentVisionClient.Outcome.facts([]))
    }

    private final class ConsentBox: @unchecked Sendable {
        var granted = true
    }
}
