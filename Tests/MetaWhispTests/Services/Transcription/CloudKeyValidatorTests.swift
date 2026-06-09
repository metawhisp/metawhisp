import XCTest
@testable import MetaWhisp

/// Pins the provider→endpoint mapping used to validate BYOK cloud keys, and the
/// empty-key short-circuit. (The live HTTP probe isn't unit-tested.)
final class CloudKeyValidatorTests: XCTestCase {

    func testEndpoint_groqIsDefault() {
        XCTAssertEqual(CloudKeyValidator.endpoint(provider: "groq").absoluteString,
                       "https://api.groq.com/openai/v1/models")
        // Unknown providers fall back to groq, matching CloudWhisperEngine's default.
        XCTAssertEqual(CloudKeyValidator.endpoint(provider: "whatever").absoluteString,
                       "https://api.groq.com/openai/v1/models")
    }

    func testEndpoint_openai() {
        XCTAssertEqual(CloudKeyValidator.endpoint(provider: "openai").absoluteString,
                       "https://api.openai.com/v1/models")
    }

    func testValidate_emptyKeyIsFalseWithoutNetwork() async {
        let ok = await CloudKeyValidator.validate(key: "   ", provider: "groq")
        XCTAssertFalse(ok)
    }

    // FREE-6 — provider auto-detect by key prefix.
    func testDetectProvider_openAIPrefixes() {
        XCTAssertEqual(CloudKeyValidator.detectProvider(key: "sk-abc123"), "openai")
        XCTAssertEqual(CloudKeyValidator.detectProvider(key: "sk-proj-abc123"), "openai")
    }

    func testDetectProvider_groqPrefix() {
        XCTAssertEqual(CloudKeyValidator.detectProvider(key: "gsk_abc123"), "groq")
        XCTAssertEqual(CloudKeyValidator.detectProvider(key: "  gsk_xyz  "), "groq")
    }

    func testDetectProvider_unknownDefaultsToGroq() {
        XCTAssertEqual(CloudKeyValidator.detectProvider(key: "weirdkey"), "groq")
    }
}
