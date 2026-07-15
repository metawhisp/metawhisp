import XCTest
@testable import MetaWhisp

/// ITER-056 — pins the GET /api/usage response contract for the Account meter.
final class LicenseUsageParseTests: XCTestCase {

    func test_parse_fullResponse() {
        let json = #"{"balance":996.1,"used":4404.8,"limit":5400,"period_start":"2026-06-25","history":[]}"#
        let u = LicenseService.parseUsage(json.data(using: .utf8)!)
        XCTAssertEqual(u?.used ?? 0, 4404.8, accuracy: 0.01)
        XCTAssertEqual(u?.limit ?? 0, 5400, accuracy: 0.01)
        XCTAssertEqual(u?.balance ?? 0, 996.1, accuracy: 0.01)
        XCTAssertEqual(u?.periodStart, "2026-06-25")
    }

    /// Older worker without period_start still parses (meter shows no reset day).
    func test_parse_withoutPeriodStart() {
        let json = #"{"balance":100,"used":5300,"limit":5400}"#
        let u = LicenseService.parseUsage(json.data(using: .utf8)!)
        XCTAssertNotNil(u)
        XCTAssertNil(u?.periodStart)
    }

    func test_parse_garbage_returnsNil() {
        XCTAssertNil(LicenseService.parseUsage(Data("not json".utf8)))
        XCTAssertNil(LicenseService.parseUsage(Data("{\"error\":\"Missing key\"}".utf8)))
    }
}
