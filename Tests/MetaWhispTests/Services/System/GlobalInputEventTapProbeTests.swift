import XCTest
@testable import MetaWhisp

final class GlobalInputEventTapProbeTests: XCTestCase {
    func test_state_requiresAccessibilityBeforeStartingEventTap() {
        XCTAssertEqual(
            GlobalInputEventTapProbe.State.resolve(
                isAccessibilityTrusted: false,
                didCreateEventTap: true
            ),
            .needsAccessibility
        )
    }

    func test_state_isUnavailableWhenTrustedButEventTapCannotBeCreated() {
        XCTAssertEqual(
            GlobalInputEventTapProbe.State.resolve(
                isAccessibilityTrusted: true,
                didCreateEventTap: false
            ),
            .unavailable
        )
    }

    func test_state_isActiveOnlyWhenAccessibilityAndEventTapAreAvailable() {
        XCTAssertEqual(
            GlobalInputEventTapProbe.State.resolve(
                isAccessibilityTrusted: true,
                didCreateEventTap: true
            ),
            .active
        )
    }
}
