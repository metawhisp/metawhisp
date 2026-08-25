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
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 1, capturedAt: t0)
        cache.store(contextID: ctxB, jpeg: Data([2]), generation: 1, capturedAt: t0)
        XCTAssertNil(cache.take(matching: ctxA, at: t0),
                     "storing a new frame must forget the old one — capacity is the privacy bound")
        XCTAssertNotNil(cache.take(matching: ctxB, at: t0))
    }

    func testAFrameForADifferentContextIsNotServed() {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 1, capturedAt: t0)
        XCTAssertNil(cache.take(matching: ctxB, at: t0),
                     "a vision call about the wrong screen is worse than none")
    }

    func testAnExpiredFrameIsNotServed() {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 1, capturedAt: t0)
        let late = t0.addingTimeInterval(ScreenAgentFrameCache.maxAgeSeconds + 1)
        XCTAssertNil(cache.take(matching: ctxA, at: late))
    }

    func testInvalidateAllEmptiesTheCache() {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 1, capturedAt: t0)
        cache.invalidateAll()
        XCTAssertNil(cache.take(matching: ctxA, at: t0))
    }

    /// ITER-069 §4 — the request carries generation and frame content hash, so
    /// the frame must know both about itself.
    func testTheFrameCarriesItsGenerationAndContentHash() {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1, 2, 3]), generation: 7, capturedAt: t0)
        let frame = cache.take(matching: ctxA, at: t0)
        XCTAssertEqual(frame?.generation, 7)
        // SHA-256 of the exact bytes — stable, and different bytes differ.
        XCTAssertEqual(frame?.contentHash,
                       ScreenAgentFrameCache.contentHash(of: Data([1, 2, 3])))
        XCTAssertNotEqual(ScreenAgentFrameCache.contentHash(of: Data([1, 2, 3])),
                          ScreenAgentFrameCache.contentHash(of: Data([1, 2, 4])))
    }

    // MARK: - consent

    /// Spec case 1: text-cloud consent alone never permits an image send.
    func testTextConsentAloneNeverPermitsAnImage() async {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 1)
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
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 1)
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
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 1)
        let transport = FakeTransport(respondWith: ctxB)   // answers about the wrong frame
        let client = ScreenAgentVisionClient(transport: transport, cache: cache)
        let outcome = await client.analyzeCurrentFrame(
            contextID: ctxA, visualConsentGranted: { true }, isStillCurrent: { true })
        XCTAssertEqual(outcome, .stale)
    }

    /// ITER-069 §4 — the response is accepted only if visit ID, generation AND
    /// frame hash all still match. An answer that cannot echo the generation
    /// it was asked about is an answer to some other question.
    func testAResponseEchoingTheWrongGenerationIsRejected() async {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 3)
        let transport = FakeTransport(respondWith: ctxA, echoGeneration: 2)
        let client = ScreenAgentVisionClient(transport: transport, cache: cache)
        let outcome = await client.analyzeCurrentFrame(
            contextID: ctxA, visualConsentGranted: { true }, isStillCurrent: { true })
        XCTAssertEqual(outcome, .stale)
    }

    func testAResponseEchoingTheWrongFrameHashIsRejected() async {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 1)
        let transport = FakeTransport(respondWith: ctxA, echoHash: "not-the-frame")
        let client = ScreenAgentVisionClient(transport: transport, cache: cache)
        let outcome = await client.analyzeCurrentFrame(
            contextID: ctxA, visualConsentGranted: { true }, isStillCurrent: { true })
        XCTAssertEqual(outcome, .stale)
    }

    /// Codex: toggling the feature off (which invalidates the cache) and back
    /// on before the reply left every local check green — the client compared
    /// the echo against the frame it captured, not against the cache that was
    /// wiped mid-flight. Invalidation must win over a faithful echo.
    func testCacheInvalidationMidCallDiscardsTheAnswer() async {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 1)
        let transport = FakeTransport(respondWith: ctxA, onAnalyze: { cache.invalidateAll() })
        let client = ScreenAgentVisionClient(transport: transport, cache: cache)
        let outcome = await client.analyzeCurrentFrame(
            contextID: ctxA, visualConsentGranted: { true }, isStillCurrent: { true })
        XCTAssertEqual(outcome, .stale)
    }

    func testAFrameReplacedMidCallDiscardsTheAnswer() async {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 1)
        let ctxB = self.ctxB
        let transport = FakeTransport(respondWith: ctxA, onAnalyze: {
            cache.store(contextID: ctxB, jpeg: Data([2]), generation: 2)
        })
        let client = ScreenAgentVisionClient(transport: transport, cache: cache)
        let outcome = await client.analyzeCurrentFrame(
            contextID: ctxA, visualConsentGranted: { true }, isStillCurrent: { true })
        XCTAssertEqual(outcome, .stale)
    }

    /// Spec case 2: the user left the screen before the answer arrived.
    func testLeavingTheScreenMidCallDiscardsTheAnswer() async {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 1)
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
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 1)
        let transport = FakeTransport(respondWith: ctxA, fail: true)
        let client = ScreenAgentVisionClient(transport: transport, cache: cache)
        let outcome = await client.analyzeCurrentFrame(
            contextID: ctxA, visualConsentGranted: { true }, isStillCurrent: { true })
        XCTAssertEqual(outcome, .failed)
    }

    func testTheHappyPathReturnsFacts() async {
        let cache = ScreenAgentFrameCache()
        cache.store(contextID: ctxA, jpeg: Data([1]), generation: 1)
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

    // MARK: - fact relevance

    /// Codex: any non-empty fact list bypassed needsVision wholesale — vision
    /// saying "Logo is blue" unlocked "Submit is disabled". Only facts about
    /// the claim's own subject may license it.
    func testAnUnrelatedVisualFactDoesNotLicenseASpatialClaim() {
        let facts: [ScreenAgentVisionResponse.VisualFact] = [
            .init(evidenceID: "v1", statement: "Logo is blue"),
            .init(evidenceID: "v2", statement: "Submit button is greyed out"),
        ]
        let ids = ScreenAgentCandidateAdapter.supportingVisualIDs(
            facts: facts, claim: "Submit is disabled because Company is empty")
        XCTAssertEqual(ids, ["v2"], "only the fact about Submit speaks to the claim")

        XCTAssertEqual(
            ScreenAgentCandidateAdapter.supportingVisualIDs(
                facts: [.init(evidenceID: "v1", statement: "Logo is blue")],
                claim: "Submit is disabled because Company is empty"),
            [], "an unrelated observation leaves needsVision standing")
    }

    // MARK: - the production wire contract

    /// Codex P2: the fake transport echoes automatically, so a regression that
    /// stopped ENCODING the fields — or mapped a missing server echo back to
    /// the request's values — left every test green. This pins the real
    /// encoder and the real decoder's missing-echo mapping.
    func testTheWireCarriesTheTripleAndAMissingEchoCannotMatch() async throws {
        StubURLProtocol.reply = #"{"context_id":"\#(ctxA.uuidString)","facts":[]}"#
        defer { StubURLProtocol.reset() }

        let transport = ScreenAgentProVisionTransport(
            licenseKey: { "test-key" },
            session: {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [StubURLProtocol.self]
                return URLSession(configuration: config)
            }())
        let response = try await transport.analyze(ScreenAgentVisionRequest(
            contextID: ctxA, jpeg: Data([1, 2, 3]), generation: 9, frameHash: "cafe01"))

        // The request body carried all three fields.
        let sent = try XCTUnwrap(StubURLProtocol.capturedBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sent) as? [String: Any])
        XCTAssertEqual(payload["context_id"] as? String, ctxA.uuidString)
        XCTAssertEqual(payload["generation"] as? Int, 9)
        XCTAssertEqual(payload["frame_hash"] as? String, "cafe01")

        // The server did not echo — the mapping must be unmatchable, never
        // the request's own values reflected back.
        XCTAssertEqual(response.generation, -1)
        XCTAssertEqual(response.frameHash, "")
    }

    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var reply = ""
        nonisolated(unsafe) static var capturedBody: Data?

        static func reset() { reply = ""; capturedBody = nil }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.capturedBody = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let size = 65536
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: size)
                    guard read > 0 else { break }
                    data.append(buffer, count: read)
                }
                return data
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.reply.data(using: .utf8)!)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // MARK: - fake transport

    @MainActor
    private final class FakeTransport: ScreenAgentVisionTransport {
        private let respondWith: UUID
        private let facts: [ScreenAgentVisionResponse.VisualFact]
        private let fail: Bool
        private let onAnalyze: (@MainActor () -> Void)?
        /// nil = echo the request faithfully, like the worker does.
        private let echoGeneration: Int?
        private let echoHash: String?
        private(set) var calls = 0

        init(respondWith: UUID,
             facts: [ScreenAgentVisionResponse.VisualFact] = [],
             fail: Bool = false,
             echoGeneration: Int? = nil,
             echoHash: String? = nil,
             onAnalyze: (@MainActor () -> Void)? = nil) {
            self.respondWith = respondWith
            self.facts = facts
            self.fail = fail
            self.echoGeneration = echoGeneration
            self.echoHash = echoHash
            self.onAnalyze = onAnalyze
        }

        struct Failure: Error {}

        func analyze(_ request: ScreenAgentVisionRequest) async throws -> ScreenAgentVisionResponse {
            calls += 1
            onAnalyze?()
            if fail { throw Failure() }
            return ScreenAgentVisionResponse(
                contextID: respondWith,
                generation: echoGeneration ?? request.generation,
                frameHash: echoHash ?? request.frameHash,
                facts: facts)
        }
    }
}
