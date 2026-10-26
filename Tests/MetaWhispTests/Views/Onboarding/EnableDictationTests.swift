import XCTest
@testable import MetaWhisp

/// D3 — "Enable dictation": a row for the microphone and one for Accessibility, each asked only by its own button
/// (US2), in every combination of the two (mockup v6 `OB.enable`, `micAct`, `axAct`). The microphone is all the
/// practice needs: with Accessibility off the user still goes on (P0 4). Fakes stand in for the prompt and for
/// System Settings.
@MainActor
final class EnableDictationTests: XCTestCase {
    private var fixture: OnboardingFixture!
    private var permissions: OnboardingPermissions {
        get { fixture.permissions }
        set { fixture.permissions = newValue }
    }
    private var panes: [OnboardingPermission] { fixture.panes }
    private var asks: Int { fixture.microphoneAsks }
    private var answer: (@MainActor (Bool) -> Void)? { fixture.answerMicrophone }

    override func setUpWithError() throws {
        fixture = try OnboardingFixture()
    }

    override func tearDownWithError() throws {
        fixture.tearDown()
    }

    private func flow() -> OnboardingFlow { fixture.flow() }

    // MARK: - The rows

    func testTheMicrophoneRowForEachAnswer() {
        let notAsked = EnableDictationScreen.microphoneRow(.notAsked)
        XCTAssertEqual(notAsked.title, "Microphone")
        XCTAssertEqual(notAsked.detail, "Turn your voice into text.")
        XCTAssertEqual(notAsked.action, .button("Allow microphone", prominent: true))

        let allowed = EnableDictationScreen.microphoneRow(.allowed)
        XCTAssertEqual(allowed.detail, "Turn your voice into text.")
        XCTAssertEqual(allowed.action, .allowed)

        let denied = EnableDictationScreen.microphoneRow(.denied)
        XCTAssertEqual(denied.detail, "Microphone access is off.")
        XCTAssertEqual(denied.action, .button("Open Microphone Settings", prominent: true),
                       "macOS will not ask twice: the way is System Settings")
    }

    func testTheAccessibilityRowBeforeDuringAndAfterSettings() {
        let before = EnableDictationScreen.accessibilityRow(granted: false, step: .notAsked, microphone: .allowed)
        XCTAssertEqual(before.title, "Accessibility")
        XCTAssertEqual(before.detail, "Use the shortcut and insert text in other apps.")
        XCTAssertFalse(before.detailIsInstruction)
        XCTAssertEqual(before.action, .button("Open Accessibility Settings", prominent: true))

        let during = EnableDictationScreen.accessibilityRow(granted: false, step: .waiting, microphone: .allowed)
        XCTAssertEqual(during.detail, "Turn on MetaWhisp in Accessibility.")
        XCTAssertTrue(during.detailIsInstruction)
        XCTAssertEqual(during.action, before.action, "the way back to Settings stays")

        let notOn = EnableDictationScreen.accessibilityRow(granted: false, step: .notOnYet, microphone: .allowed)
        XCTAssertEqual(notOn.detail, "Not on yet. Right ⌘ and typing into other apps need it.")
        XCTAssertEqual(notOn.action, before.action)

        for step in [OnboardingFlow.AccessibilityStep.notAsked, .waiting, .notOnYet] {
            let granted = EnableDictationScreen.accessibilityRow(granted: true, step: step, microphone: .allowed)
            XCTAssertEqual(granted.action, .allowed, "\(step)")
            XCTAssertEqual(granted.detail, "Use the shortcut and insert text in other apps.", "\(step)")
        }
    }

    /// The Accessibility button leads once the microphone is allowed; before that the microphone's does.
    func testTheAccessibilityButtonLeadsOnceTheMicrophoneIsAllowed() {
        for microphone in [OnboardingPermissions.Microphone.notAsked, .denied] {
            XCTAssertEqual(EnableDictationScreen.accessibilityRow(granted: false, step: .notAsked, microphone: microphone).action,
                           .button("Open Accessibility Settings", prominent: false), "\(microphone)")
        }
    }

    /// P0 4 — in every combination, "Try dictation" goes on as soon as the microphone is allowed; Accessibility off
    /// only makes it the quieter of the two choices on the screen.
    func testTryDictationNeedsOnlyTheMicrophoneInEveryCombination() {
        for microphone in [OnboardingPermissions.Microphone.notAsked, .allowed, .denied] {
            for accessibility in [false, true] {
                let next = EnableDictationScreen.next(OnboardingPermissions(microphone: microphone,
                                                                            accessibility: accessibility))
                XCTAssertEqual(next.enabled, microphone == .allowed, "\(microphone), accessibility \(accessibility)")
                XCTAssertEqual(next.kind, microphone == .allowed && !accessibility ? .glass : .primary,
                               "\(microphone), accessibility \(accessibility)")
            }
        }
        XCTAssertEqual(EnableDictationScreen.next, "Try dictation")
    }

    // MARK: - The buttons

    /// US2 / A1 — nothing asks before a button: opening the screen, reading, coming back to the app.
    func testNothingAsksBeforeAButton() {
        let onboarding = flow()
        onboarding.next()
        onboarding.refreshPermissions()
        onboarding.appBecameActive()
        XCTAssertEqual(asks, 0)
        XCTAssertEqual(panes, [])
    }

    /// The microphone button goes through the first record press's one prompt; the row follows the answer.
    func testAllowMicrophoneAsksThroughTheFirstPressPromptAndTheRowFollowsTheAnswer() {
        let onboarding = flow()
        onboarding.microphoneButton()
        XCTAssertEqual(asks, 1)
        XCTAssertEqual(panes, [], "never answered: the prompt, not System Settings")
        permissions.microphone = .allowed
        answer?(true)
        XCTAssertEqual(onboarding.permissions.microphone, .allowed)
    }

    /// A no is said on the row, and the next press goes to System Settings — macOS would not ask again.
    func testANoTurnsTheButtonIntoTheWayToSettings() {
        let onboarding = flow()
        onboarding.microphoneButton()
        permissions.microphone = .denied
        answer?(false)
        XCTAssertEqual(onboarding.permissions.microphone, .denied)
        var opened: [OnboardingPermission] = []
        onboarding.onSettingsOpened = { opened.append($0) }
        onboarding.microphoneButton()
        XCTAssertEqual(asks, 1, "no second prompt")
        XCTAssertEqual(panes, [.microphone])
        XCTAssertEqual(opened, [.microphone], "the window arms its return")
    }

    /// A3 — granted in System Settings: the row turns allowed by itself, on the next read.
    func testAGrantInSettingsTurnsTheRowAllowedByItself() {
        permissions.microphone = .denied
        let onboarding = flow()
        var granted: [OnboardingPermission] = []
        onboarding.onGranted = { granted.append($0) }
        permissions.microphone = .allowed
        onboarding.refreshPermissions()
        XCTAssertEqual(onboarding.permissions.microphone, .allowed)
        XCTAssertEqual(granted, [.microphone])
    }

    /// A4 — the Accessibility button asks macOS and opens the pane (one call: PermissionsService.askForAccessibility),
    /// then the row waits; back without turning it on, it says so.
    func testTheAccessibilityButtonWaitsThenSaysNotOnYet() {
        permissions.microphone = .allowed
        let onboarding = flow()
        onboarding.accessibilityButton()
        XCTAssertEqual(panes, [.accessibility])
        XCTAssertEqual(onboarding.accessibilityStep, .waiting)
        onboarding.appBecameActive()
        XCTAssertEqual(onboarding.accessibilityStep, .notOnYet)
        XCTAssertTrue(EnableDictationScreen.next(onboarding.permissions).enabled, "and the practice is still open")
    }

    func testBackWithAccessibilityOnTheRowIsAllowed() {
        let onboarding = flow()
        onboarding.accessibilityButton()
        permissions.accessibility = true
        onboarding.appBecameActive()
        XCTAssertTrue(onboarding.permissions.accessibility)
        XCTAssertEqual(EnableDictationScreen.accessibilityRow(granted: onboarding.permissions.accessibility,
                                                              step: onboarding.accessibilityStep,
                                                              microphone: onboarding.permissions.microphone).action,
                       .allowed)
    }

    /// Coming back to the app without having pressed the button changes nothing on the row.
    func testComingBackWithoutTheButtonLeavesTheRowAlone() {
        let onboarding = flow()
        onboarding.appBecameActive()
        XCTAssertEqual(onboarding.accessibilityStep, .notAsked)
    }
}
