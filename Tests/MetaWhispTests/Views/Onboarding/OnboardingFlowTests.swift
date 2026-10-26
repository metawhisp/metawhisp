import XCTest
@testable import MetaWhisp

/// D1 — the four-screen first run as a state machine: which screen is up, where a closed window or a quit resumes
/// (F4), how it ends (E1), and the permission watch the window's return latch listens to. A defaults suite of the
/// test's own; nothing here opens System Settings or shows a prompt.
@MainActor
final class OnboardingFlowTests: XCTestCase {
    private var fixture: OnboardingFixture!
    private var suite: String { fixture.suite }
    private var defaults: UserDefaults { fixture.defaults }
    private var permissions: OnboardingPermissions {
        get { fixture.permissions }
        set { fixture.permissions = newValue }
    }
    private var panes: [OnboardingPermission] { fixture.panes }
    private var endings: [OnboardingFlow.Ending] { fixture.endings }

    override func setUpWithError() throws {
        fixture = try OnboardingFixture()
    }

    override func tearDownWithError() throws {
        fixture.tearDown()
    }

    private func flow(_ store: UserDefaults? = nil) -> OnboardingFlow { fixture.flow(store) }

    // MARK: - The screens

    func testTheFourScreensInOrderWithTheirSteps() {
        XCTAssertEqual(OnboardingFlow.Screen.allCases, [.welcome, .enable, .practice, .pro])
        XCTAssertEqual(OnboardingFlow.Screen.allCases.map(\.step), ["1 of 4", "2 of 4", "3 of 4", "4 of 4"])
    }

    func testANewInstallStartsOnTheWelcome() {
        XCTAssertEqual(flow().screen, .welcome)
    }

    func testNextAndBackMoveOneScreenAndStopAtTheEnds() {
        let onboarding = flow()
        onboarding.back()
        XCTAssertEqual(onboarding.screen, .welcome, "nothing before the welcome")
        onboarding.next()
        XCTAssertEqual(onboarding.screen, .enable)
        onboarding.next()
        onboarding.next()
        XCTAssertEqual(onboarding.screen, .pro)
        onboarding.next()
        XCTAssertEqual(onboarding.screen, .pro, "the Pro screen ends only through its own buttons")
        XCTAssertEqual(endings, [], "moving never finishes the onboarding")
        onboarding.back()
        XCTAssertEqual(onboarding.screen, .practice)
    }

    // MARK: - Finish later (F4, E2, E5)

    /// The red close button means "finish later", and a quit is the same: the next launch opens on the screen the
    /// user left — the screen is kept the moment it changes, not when the window goes.
    func testTheNextLaunchOpensOnTheScreenTheUserLeft() {
        let first = flow()
        first.next()
        first.next()
        XCTAssertEqual(flow().screen, .practice, "a new flow, as the next launch makes one")
        first.back()
        XCTAssertEqual(flow().screen, .enable)
    }

    func testAStoredScreenThatIsNoScreenStartsOnTheWelcome() {
        defaults.set(9, forKey: OnboardingFlow.resumeKey)
        XCTAssertEqual(flow().screen, .welcome)
    }

    // MARK: - The end (E1)

    /// Completion writes the language the user runs on before `hasCompletedOnboarding` (C7), and the resume point
    /// goes: a later "Show onboarding" starts on the welcome.
    func testCompletionWritesTheLanguageThenTheFinishAndForgetsTheResumePoint() throws {
        let recorded = try XCTUnwrap(OrderRecordingDefaults(suiteName: suite))
        let onboarding = flow(recorded)
        onboarding.next()
        onboarding.next()
        onboarding.next()
        onboarding.complete(.free)
        XCTAssertEqual(endings, [.free])
        XCTAssertEqual(recorded.string(forKey: "transcriptionLanguage"), "auto")
        XCTAssertTrue(recorded.bool(forKey: "hasCompletedOnboarding"))
        let language = try XCTUnwrap(recorded.keys.firstIndex(of: "transcriptionLanguage"))
        let finished = try XCTUnwrap(recorded.keys.firstIndex(of: "hasCompletedOnboarding"))
        XCTAssertLessThan(language, finished, "the language is written first")
        XCTAssertNil(recorded.object(forKey: OnboardingFlow.resumeKey))
        XCTAssertEqual(flow(recorded).screen, .welcome)
    }

    // MARK: - The permission watch (the return latch's source)

    /// Each grant is reported once, when it happens — the window's return listens to it.
    func testAGrantIsReportedOnceWhenItHappens() {
        let onboarding = flow()
        var granted: [OnboardingPermission] = []
        onboarding.onGranted = { granted.append($0) }
        onboarding.refreshPermissions()
        XCTAssertEqual(granted, [])
        permissions.accessibility = true
        onboarding.refreshPermissions()
        onboarding.refreshPermissions()
        XCTAssertEqual(granted, [.accessibility])
        permissions.microphone = .allowed
        onboarding.refreshPermissions()
        XCTAssertEqual(granted, [.accessibility, .microphone])
        XCTAssertEqual(onboarding.permissions, OnboardingPermissions(microphone: .allowed, accessibility: true))
    }

    /// A permission already granted when the flow begins is no grant: nothing comes back for it.
    func testAPermissionHeldFromTheStartIsNoGrant() {
        permissions = OnboardingPermissions(microphone: .allowed, accessibility: true)
        let onboarding = flow()
        var granted: [OnboardingPermission] = []
        onboarding.onGranted = { granted.append($0) }
        onboarding.refreshPermissions()
        XCTAssertEqual(granted, [])
    }

    /// A Settings-opening button opens its pane and says which, so the window can arm its return.
    func testOpeningSettingsOpensThePaneAndSaysWhich() {
        let onboarding = flow()
        var opened: [OnboardingPermission] = []
        onboarding.onSettingsOpened = { opened.append($0) }
        onboarding.openSettings(for: .accessibility)
        onboarding.openSettings(for: .microphone)
        XCTAssertEqual(panes, [.accessibility, .microphone])
        XCTAssertEqual(opened, [.accessibility, .microphone])
    }
}

/// A defaults suite that remembers the order of its writes.
private final class OrderRecordingDefaults: UserDefaults {
    private(set) var keys: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        keys.append(defaultName)
        super.set(value, forKey: defaultName)
    }
}
