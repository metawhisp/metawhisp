import XCTest
@testable import MetaWhisp

/// C4 — launch no longer asks for Accessibility (PRD P0 1), and the prompting
/// API is what puts MetaWhisp in the list under Privacy → Accessibility. So the
/// button that sends the user there asks first: a pane that opened without it
/// could have no MetaWhisp to switch on.
@MainActor
final class AccessibilityButtonTests: XCTestCase {

    func testTheButtonAsksMacOSFirstThenOpensThePane() {
        var steps: [String] = []
        PermissionsService.askForAccessibility(PermissionAsk(), prompt: { _ in steps.append("prompt") },
                                               openPane: { steps.append("pane") })
        XCTAssertEqual(steps, ["prompt", "pane"])
    }
}
