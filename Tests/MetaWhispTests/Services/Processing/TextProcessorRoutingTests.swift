import XCTest
@testable import MetaWhisp

/// ITER-051 F1.1 — pins the LLM routing priority for dictation processing
/// (structured / translate). The Settings copy promises "Run AI features
/// on-device ... INSTEAD of through Pro proxy / API key", so a ready local
/// model must win over both cloud paths; without it the old order applies
/// (Pro proxy, then direct BYOK call).
final class TextProcessorRoutingTests: XCTestCase {

    func testLocalModelWinsOverEverything() {
        XCTAssertEqual(TextProcessor.resolveRoute(localReady: true, isPro: true, hasLicenseKey: true), .local)
        XCTAssertEqual(TextProcessor.resolveRoute(localReady: true, isPro: false, hasLicenseKey: false), .local)
    }

    func testProProxyWhenNoLocal() {
        XCTAssertEqual(TextProcessor.resolveRoute(localReady: false, isPro: true, hasLicenseKey: true), .proxy)
    }

    func testDirectByokWhenNoLocalNoPro() {
        XCTAssertEqual(TextProcessor.resolveRoute(localReady: false, isPro: false, hasLicenseKey: false), .direct)
        // Pro flag without a usable license key can't use the proxy.
        XCTAssertEqual(TextProcessor.resolveRoute(localReady: false, isPro: true, hasLicenseKey: false), .direct)
    }
}
