import XCTest
@testable import MetaWhisp

/// The app's primary trigger is Right ⌘. macOS delivers those events to a
/// global monitor only when Accessibility is granted, and a monitor installed
/// before the grant does not start working when the grant arrives — it has to
/// be installed again.
///
/// `register()` installed four monitors, never checked `AXIsProcessTrusted()`,
/// and logged "registered" either way. Grant Accessibility in the middle of a
/// session and the hotkeys stayed dead until the next launch, with a log that
/// said they were fine (audit, 2026-09-06, P1).
final class HotkeyRearmTests: XCTestCase {

    func testTheGrantArrivingIsWhatRearms() {
        XCTAssertTrue(HotkeyRearmPolicy.shouldRearm(wasTrusted: false, isTrusted: true),
                      "permission just arrived — the monitors have to be installed again")
    }

    func testNothingIsRearmedWhileTheAnswerHasNotChanged() {
        XCTAssertFalse(HotkeyRearmPolicy.shouldRearm(wasTrusted: false, isTrusted: false))
        XCTAssertFalse(HotkeyRearmPolicy.shouldRearm(wasTrusted: true, isTrusted: true),
                       "re-installing working monitors would drop the keystroke in flight")
    }

    /// Permission taken away is not a re-arm: the monitors are already there
    /// and there is nothing to install.
    func testLosingPermissionIsNotARearm() {
        XCTAssertFalse(HotkeyRearmPolicy.shouldRearm(wasTrusted: true, isTrusted: false))
    }

    /// The watch exists only until the grant arrives — a poll that runs for
    /// the life of the app is a battery cost with no purpose. This is the
    /// gate's release: granted, or the ceiling below.
    func testTheWatchStopsOnceThePermissionIsThere() {
        XCTAssertFalse(HotkeyRearmPolicy.keepWatching(isTrusted: true, elapsedSeconds: 1))
        XCTAssertTrue(HotkeyRearmPolicy.keepWatching(isTrusted: false, elapsedSeconds: 60))
    }

    /// …and a ceiling, so a user who never grants it is not polled forever.
    func testTheWatchGivesUpEventually() {
        XCTAssertFalse(HotkeyRearmPolicy.keepWatching(isTrusted: false,
                                                      elapsedSeconds: HotkeyRearmPolicy.watchCeilingSeconds + 1))
        XCTAssertGreaterThanOrEqual(HotkeyRearmPolicy.watchCeilingSeconds, 300,
                                    "long enough for a person to walk through System Settings")
    }
}
