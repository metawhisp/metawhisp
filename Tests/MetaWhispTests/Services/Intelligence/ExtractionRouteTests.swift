import XCTest
@testable import MetaWhisp

/// ITER-081 — one route per extraction attempt, and the exact request the two
/// extractors send to the proxy.
final class ExtractionRouteTests: XCTestCase {

    func testTheRouteRuleIsTodays() {
        XCTAssertEqual(ExtractionRoute.current(localReady: true, isPro: true, licenseKey: "k"), .local)
        XCTAssertEqual(ExtractionRoute.current(localReady: false, isPro: true, licenseKey: "k"), .pro(licenseKey: "k"))
        XCTAssertEqual(ExtractionRoute.current(localReady: false, isPro: true, licenseKey: ""), .pro(licenseKey: ""))
        XCTAssertEqual(ExtractionRoute.current(localReady: false, isPro: true, licenseKey: nil), .byok)
        XCTAssertEqual(ExtractionRoute.current(localReady: false, isPro: false, licenseKey: "k"), .byok)
    }

    func testEachRouteHasItsLimit() {
        XCTAssertEqual(ExtractionRoute.local.unitLimit, 6_000)
        XCTAssertEqual(ExtractionRoute.pro(licenseKey: "k").unitLimit, 128_000)
        XCTAssertEqual(ExtractionRoute.byok.unitLimit, 20_000)
    }

    /// The proxy gives 128,000 units only to these two exact ids.
    @MainActor
    func testTheServiceIdsAreTheOnesTheProxyKnows() {
        XCTAssertEqual(TaskExtractor.llmServiceId, "TaskExtractor")
        XCTAssertEqual(MemoryExtractor.llmServiceId, "MemoryExtractor")
    }

    func testTheProRequestCarriesTheWholePromptAndTheDeadline() throws {
        let user = String(repeating: "We agreed to ship on Friday. ", count: 1_600)   // 46,400 units
        let request = try ExtractionRoute.proAdviceRequest(system: "SYSTEM", user: user, licenseKey: "key-1",
                                                           tier: .medium, serviceId: "TaskExtractor")
        XCTAssertEqual(request.url?.absoluteString, "https://api.metawhisp.com/api/pro/advice")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-1")
        XCTAssertEqual(request.timeoutInterval, 60)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["user"] as? String, user)
        XCTAssertEqual(body["system"] as? String, "SYSTEM")
        XCTAssertEqual(body["service_id"] as? String, "TaskExtractor")
        XCTAssertEqual(body["tier"] as? String, "medium")
        XCTAssertEqual(body["deadline_ms"] as? Int, 55_000)
    }
}
