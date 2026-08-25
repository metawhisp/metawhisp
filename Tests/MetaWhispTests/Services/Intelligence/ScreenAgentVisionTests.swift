import XCTest
@testable import MetaWhisp

/// The boundary around the one image vision may see.
///
/// The privacy claims here are structural: one frame, memory only, keyed to
/// the exact captured context, dead on replacement, expiry, purge or quit. And
/// the same-frame proof is checked in both directions — the answer names its
/// question, and the world has not moved on meanwhile.
@MainActor
final class ScreenAgentVisionTests: XCTestCase {

    private let ctxA = UUID()
    private let ctxB = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - frame cache

    func testTheCacheHoldsExactlyOneFrame() {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), capturedAt: t0)
        cache.store(contextID: ctxB, jpeg: Data([2]), capturedAt: t0)
        XCTAssertNil(cache.take(matching: ctxA, at: t0),
                     "storing a new frame must forget the old one — capacity is the privacy bound")
        XCTAssertNotNil(cache.take(matching: ctxB, at: t0))
    }

    func testAFrameForADifferentContextIsNotServed() {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), capturedAt: t0)
        XCTAssertNil(cache.take(matching: ctxB, at: t0),
                     "a vision call about the wrong screen is worse than none")
    }

    func testAnExpiredFrameIsNotServed() {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), capturedAt: t0)
        let late = t0.addingTimeInterval(ScreenAgentFrameCache.maxAgeSeconds + 1)
        XCTAssertNil(cache.take(matching: ctxA, at: late))
    }

    func testInvalidateAllEmptiesTheCache() {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), capturedAt: t0)
        cache.invalidateAll()
        XCTAssertNil(cache.take(matching: ctxA, at: t0))
    }

    // MARK: - consent

    /// Spec case 1: text-cloud consent alone never permits an image send.
    func testTextConsentAloneNeverPermitsAnImage() async {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]))
        let transport = FakeTransport(respondWith: ctxA)
        let client = ScreenAgentVisionClient(transport: transport, cache: cache)
        let outcome = await client.analyzeCurrentFrame(
            contextID: ctxA,
            visualConsentGranted: { false },   // text consent is not this
            isStillCurrent: { true })
        XCTAssertEqual(outcome, .notEligible)
        XCTAssertEqual(transport.calls, 0, "no image may leave the machine without visual consent")
    }

    /// Revoking consent while the model is thinking discards the result.
    func testConsentRevokedMidCallDiscardsTheAnswer() async {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]))
        var consent = true
        let transport = FakeTransport(respondWith: ctxA, onAnalyze: { consent = false })
        let client = ScreenAgentVisionClient(transport: transport, cache: cache)
        let outcome = await client.analyzeCurrentFrame(
            contextID: ctxA,
            visualConsentGranted: { consent },
            isStillCurrent: { true })
        XCTAssertEqual(outcome, .stale, "a revocation mid-flight wins over the answer")
    }

    // MARK: - same-frame proof

    /// Spec case 3: a response for a different frame is rejected.
    func testAResponseForADifferentContextIsRejected() async {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]))
        let transport = FakeTransport(respondWith: ctxB)   // answers about the wrong frame
        let client = ScreenAgentVisionClient(transport: transport, cache: cache)
        let outcome = await client.analyzeCurrentFrame(
            contextID: ctxA, visualConsentGranted: { true }, isStillCurrent: { true })
        XCTAssertEqual(outcome, .stale)
    }

    /// Spec case 2: the user left the screen before the answer arrived.
    func testLeavingTheScreenMidCallDiscardsTheAnswer() async {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]))
        var current = true
        let transport = FakeTransport(respondWith: ctxA, onAnalyze: { current = false })
        let client = ScreenAgentVisionClient(transport: transport, cache: cache)
        let outcome = await client.analyzeCurrentFrame(
            contextID: ctxA, visualConsentGranted: { true }, isStillCurrent: { current })
        XCTAssertEqual(outcome, .stale)
    }

    /// Spec case 12: provider failure is silence, not a text-only guess
    /// dressed up as vision.
    func testTransportFailureIsFailureNotAFallback() async {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]))
        let transport = FakeTransport(respondWith: ctxA, fail: true)
        let client = ScreenAgentVisionClient(transport: transport, cache: cache)
        let outcome = await client.analyzeCurrentFrame(
            contextID: ctxA, visualConsentGranted: { true }, isStillCurrent: { true })
        XCTAssertEqual(outcome, .failed)
    }

    func testTheHappyPathReturnsFacts() async {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]))
        let transport = FakeTransport(
            respondWith: ctxA,
            facts: [.init(evidenceID: "v1", statement: "Company field is empty")])
        let client = ScreenAgentVisionClient(transport: transport, cache: cache)
        let outcome = await client.analyzeCurrentFrame(
            contextID: ctxA, visualConsentGranted: { true }, isStillCurrent: { true })
        XCTAssertEqual(outcome,
                       .facts([.init(evidenceID: "v1", statement: "Company field is empty")]))
        XCTAssertEqual(transport.calls, 1)
    }

    // MARK: - fake transport

    @MainActor
    private final class FakeTransport: ScreenAgentVisionTransport {
        private let respondWith: UUID
        private let facts: [ScreenAgentVisionResponse.VisualFact]
        private let fail: Bool
        private let onAnalyze: (@MainActor () -> Void)?
        private(set) var calls = 0

        init(respondWith: UUID,
             facts: [ScreenAgentVisionResponse.VisualFact] = [],
             fail: Bool = false,
             onAnalyze: (@MainActor () -> Void)? = nil) {
            self.respondWith = respondWith
            self.facts = facts
            self.fail = fail
            self.onAnalyze = onAnalyze
        }

        struct Failure: Error {}

        func analyze(_ request: ScreenAgentVisionRequest) async throws -> ScreenAgentVisionResponse {
            calls += 1
            onAnalyze?()
            if fail { throw Failure() }
            return ScreenAgentVisionResponse(contextID: respondWith, facts: facts)
        }
    }
}
