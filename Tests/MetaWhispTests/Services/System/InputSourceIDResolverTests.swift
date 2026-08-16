import XCTest
@testable import MetaWhisp

final class InputSourceIDResolverTests: XCTestCase {
    func test_resolvesOnlyTheSupportedUSAndRussianInputSources() {
        XCTAssertEqual(
            InputSourceIDResolver.layout(for: "com.apple.keylayout.US"),
            .englishUS
        )
        XCTAssertEqual(
            InputSourceIDResolver.layout(for: "com.apple.keylayout.Russian"),
            .russian
        )
    }

    func test_rejectsUnsupportedInputSourcesRatherThanGuessing() {
        XCTAssertNil(InputSourceIDResolver.layout(for: "com.apple.inputmethod.Kotoeri"))
        XCTAssertNil(InputSourceIDResolver.layout(for: "com.apple.keylayout.British"))
    }
}
