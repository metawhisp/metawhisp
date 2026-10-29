import Carbon.HIToolbox
import XCTest
@testable import MetaWhisp

/// ITER-076 P5 — the settings of the in-call hints.
///
/// The automatic answers cost money, so they are off until the user asks for
/// them; the shortcut starts as ⌃↩, the combo that needs no second key.
final class AppSettingsMeetingHintsTests: XCTestCase {

    func testTheDefaultsAreAutomaticOffAndControlReturn() {
        let settings = AppSettings.shared
        XCTAssertFalse(settings.meetingAutoAnswer,
                       "automatic answers cost money — the user has to ask for them")
        XCTAssertEqual(settings.meetingHelpKeyCode, 36, "Return")
        XCTAssertEqual(settings.meetingHelpModifiers, controlKey, "⌃")
    }
}
