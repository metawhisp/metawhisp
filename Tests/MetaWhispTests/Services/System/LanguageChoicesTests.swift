import XCTest
@testable import MetaWhisp

/// The languages you can dictate in, in one place.
///
/// The list lived privately inside the settings window, which is why picking a
/// language meant opening that window at all. It is shared now so the menu-bar
/// switcher and Settings cannot offer different sets.
final class LanguageChoicesTests: XCTestCase {

    func testEveryCodeAppearsOnce() {
        let codes = LanguageChoices.all.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count, "a language offered twice is a bug in the list")
    }

    func testCodesAreWhatTheTranscriberExpects() {
        for choice in LanguageChoices.all {
            XCTAssertEqual(choice.code, choice.code.lowercased(), "\(choice.code) must be a lowercase ISO code")
            XCTAssertFalse(choice.code.isEmpty)
            XCTAssertFalse(choice.label.isEmpty)
        }
    }

    func testTheListIsNotEmptyAndCarriesTheObviousOnes() {
        XCTAssertGreaterThanOrEqual(LanguageChoices.all.count, 8)
        XCTAssertTrue(LanguageChoices.all.contains { $0.code == "ru" })
        XCTAssertTrue(LanguageChoices.all.contains { $0.code == "en" })
    }

    func testALabelIsFoundForACodeAndInventedForAnUnknownOne() {
        XCTAssertEqual(LanguageChoices.label(for: "ru"), "RU")
        XCTAssertEqual(LanguageChoices.label(for: "sv"), "SV",
                       "a language the list does not carry still shows as itself, never blank")
    }
}
