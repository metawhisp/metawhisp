import XCTest
@testable import MetaWhisp

/// Whether the user can tell a working agent from a broken one.
///
/// The feature's normal state is silence, so an empty allowlist, a revoked
/// permission and a pause from three days ago all look exactly like a healthy
/// agent with nothing to say. The user concludes it does not work and turns it
/// off — and they are not wrong to, because nothing told them otherwise.
final class ScreenAgentHealthTests: XCTestCase {

    private func health(
        featureEnabled: Bool = true,
        paused: Bool = false,
        hasPermission: Bool = true,
        allowlistIsActiveAndEmpty: Bool = false,
        currentAppAllowed: Bool = true,
        currentApp: String? = "Slack",
        captureOutcome: ScreenCaptureOutcome = .captured(ocrCharacters: 500)
    ) -> ScreenAgentHealth {
        .evaluate(featureEnabled: featureEnabled, paused: paused,
                  hasPermission: hasPermission,
                  allowlistIsActiveAndEmpty: allowlistIsActiveAndEmpty,
                  currentAppAllowed: currentAppAllowed, currentApp: currentApp,
                  captureOutcome: captureOutcome)
    }

    func testAWorkingAgentSaysWhatItIsWatching() {
        XCTAssertEqual(health().state, .watching(app: "Slack"))
        XCTAssertNil(health().action, "nothing is wrong, so there is nothing to do")
    }

    /// The exact case that makes people give up on the feature.
    func testAnEmptyAllowlistSaysSoInsteadOfLookingHealthy() {
        let h = health(allowlistIsActiveAndEmpty: true)
        XCTAssertEqual(h.state, .nothingAllowed)
        XCTAssertTrue(h.isSilentlyIdle)
        XCTAssertNotNil(h.action, "a dead end has to name the way out")
    }

    func testARevokedPermissionIsNamed() {
        let h = health(hasPermission: false)
        XCTAssertEqual(h.state, .noPermission)
        XCTAssertTrue(h.isSilentlyIdle)
        XCTAssertTrue(h.action?.contains("System Settings") == true)
    }

    /// Telling someone to grant a permission for a feature they switched off is
    /// noise. States are ordered by what they would have to change first.
    func testOffOutranksEveryOtherComplaint() {
        XCTAssertEqual(
            health(featureEnabled: false, paused: true, hasPermission: false,
                   allowlistIsActiveAndEmpty: true).state,
            .off)
    }

    func testPauseOutranksPermission() {
        XCTAssertEqual(health(paused: true, hasPermission: false).state, .paused)
    }

    /// An excluded app is the user's own setting working. It is not a fault,
    /// and reporting it as one teaches people to ignore the status line.
    func testAnExcludedAppIsNotAFault() {
        let h = health(currentAppAllowed: false, currentApp: "1Password")
        XCTAssertEqual(h.state, .excludedHere(app: "1Password"))
        XCTAssertFalse(h.isSilentlyIdle)
        XCTAssertNil(h.action)
        XCTAssertTrue(h.summary.contains("1Password"))
    }

    func testAFailedCaptureIsReportedAsBrokenNotAsQuiet() {
        let h = health(captureOutcome: .captureFailed)
        XCTAssertTrue(h.isSilentlyIdle)
        XCTAssertTrue(h.summary.lowercased().contains("not working"))
    }

    func testAFailedSaveSaysWhatFailed() {
        let h = health(captureOutcome: .persistenceFailed)
        XCTAssertTrue(h.summary.contains("could not be saved"))
    }

    /// A blank screen is a successful read, not a fault.
    func testAnEmptyScreenIsStillWatching() {
        XCTAssertEqual(health(captureOutcome: .captured(ocrCharacters: 0)).state,
                       .watching(app: "Slack"))
    }

    /// Every summary is a sentence a person could say out loud.
    func testEveryStateReadsAsPlainLanguage() {
        let states: [ScreenAgentHealth] = [
            health(featureEnabled: false), health(paused: true),
            health(hasPermission: false), health(allowlistIsActiveAndEmpty: true),
            health(currentAppAllowed: false, currentApp: "Terminal"),
            health(), health(captureOutcome: .captureFailed),
        ]
        for h in states {
            XCTAssertFalse(h.summary.isEmpty)
            XCTAssertFalse(h.summary.contains("_"))
            XCTAssertFalse(h.summary.lowercased().contains("nil"))
        }
    }

    /// Anything that leaves the user with nothing has to say what to do.
    func testEverySilentlyIdleStateOffersAWayOut() {
        for h in [health(allowlistIsActiveAndEmpty: true), health(hasPermission: false),
                  health(captureOutcome: .captureFailed)] {
            XCTAssertTrue(h.isSilentlyIdle)
            XCTAssertNotNil(h.action, "\(h.summary) leaves the user stuck with no next step")
        }
    }
}
