import XCTest
@testable import MetaWhisp

/// ITER-085 — the Target window after the update: shown once, to people who finished the onboarding before Target
/// existed, at the first idle moment; Turn on Target switches a Pro user at once and shows a Free user the Pro screen;
/// a Free user who goes on to pay gets Target turned on when Pro becomes active, within 7 days of the press.
@MainActor
final class TargetIntroTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "TargetIntroTests"

    override func setUpWithError() throws {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    // MARK: - When the window shows

    func testShownOnceToSomeoneWhoFinishedTheOnboardingAtTheFirstIdleMoment() {
        XCTAssertEqual(TargetIntro.gate(seen: false, onboarded: true, sinceLaunch: 12, busy: false), .show)
        XCTAssertEqual(TargetIntro.gate(seen: true, onboarded: true, sinceLaunch: 12, busy: false), .never, "once")
        XCTAssertEqual(TargetIntro.gate(seen: false, onboarded: false, sinceLaunch: 12, busy: false), .never,
                       "the onboarding shows Target on its own Pro screen")
    }

    func testWaitsForTheLaunchToSettle() {
        XCTAssertEqual(TargetIntro.gate(seen: false, onboarded: true, sinceLaunch: 3, busy: false), .wait)
    }

    func testWaitsWhileARecordingAMeetingOrAnErrandRuns() {
        XCTAssertEqual(TargetIntro.gate(seen: false, onboarded: true, sinceLaunch: 600, busy: true), .wait)
    }

    /// The wait has its release: the recording's end. The same launch, idle again, shows the window.
    func testShowsAnywayAfterTheRecordingEnds() {
        let busy = TargetIntro.gate(seen: false, onboarded: true, sinceLaunch: 30, busy: true)
        let idleAgain = TargetIntro.gate(seen: false, onboarded: true, sinceLaunch: 95, busy: false)
        XCTAssertEqual([busy, idleAgain], [.wait, .show])
    }

    func testANewUserFinishingTheOnboardingHasSeenIt() {
        XCTAssertFalse(TargetIntro.isSeen(defaults))
        AppSettings.recordOnboardingCompleted(in: defaults)
        XCTAssertTrue(TargetIntro.isSeen(defaults))
    }

    func testAnExistingUserReplayingTheOnboardingStillGetsTheWindow() {
        defaults.set(true, forKey: "hasCompletedOnboarding")
        AppSettings.recordOnboardingCompleted(in: defaults)
        XCTAssertFalse(TargetIntro.isSeen(defaults))
    }

    // MARK: - Turn on after payment

    func testPaymentTurnsTargetOnWithinSevenDaysOfThePress() {
        let press = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(TargetIntro.turnsOn(wantedAt: press, isPro: true, now: press.addingTimeInterval(3600)))
        XCTAssertTrue(TargetIntro.turnsOn(wantedAt: press, isPro: true, now: press.addingTimeInterval(TargetIntro.wantedLife)))
        XCTAssertFalse(TargetIntro.turnsOn(wantedAt: press, isPro: true,
                                           now: press.addingTimeInterval(TargetIntro.wantedLife + 1)),
                       "never out of the blue")
        XCTAssertFalse(TargetIntro.turnsOn(wantedAt: press, isPro: false, now: press.addingTimeInterval(60)))
        XCTAssertFalse(TargetIntro.turnsOn(wantedAt: nil, isPro: true, now: press))
    }

    // MARK: - The window's buttons

    private var turnedOn = 0
    private var closed = 0
    private var accountPageOpens = true

    private func flow(isPro: Bool) -> TargetIntroFlow {
        TargetIntroFlow(environment: .init(isPro: { isPro }, turnOn: { [weak self] in self?.turnedOn += 1 },
                                           openAccountPage: { [weak self] in self?.accountPageOpens ?? false },
                                           defaults: defaults, now: { Date(timeIntervalSince1970: 5_000) }),
                        close: { [weak self] in self?.closed += 1 })
    }

    func testAProUserTurnsItOnAtOnce() {
        let flow = flow(isPro: true)
        flow.turnOn()
        XCTAssertEqual(turnedOn, 1)
        XCTAssertEqual(flow.screen, .on)
        XCTAssertNil(TargetIntro.wantedAt(defaults))
    }

    func testAFreeUserSeesTheProScreenAndNothingIsArmedYet() {
        let flow = flow(isPro: false)
        flow.turnOn()
        XCTAssertEqual(turnedOn, 0, "never turned on without Pro")
        XCTAssertEqual(flow.screen, .pro)
        XCTAssertNil(TargetIntro.wantedAt(defaults), "the price is not an answer yet")
        flow.back()
        XCTAssertEqual(flow.screen, .intro)
    }

    /// Closing the window with its red button, on any screen, arms nothing: only Get Pro or Sign in — the user going
    /// to pay — keeps the press (Kimi re-review, P1).
    func testOnlyGoingToPayArmsTheTurnOn() {
        let flow = flow(isPro: false)
        flow.turnOn()
        XCTAssertNil(TargetIntro.wantedAt(defaults))
        flow.proActions.signIn()
        XCTAssertEqual(TargetIntro.wantedAt(defaults), Date(timeIntervalSince1970: 5_000))
    }

    func testGetProOpensTheAccountPageAndClosesKeepingThePress() {
        let flow = flow(isPro: false)
        flow.turnOn()
        flow.proActions.getPro()
        XCTAssertEqual(closed, 1)
        XCTAssertNotNil(TargetIntro.wantedAt(defaults))
    }

    func testABrowserThatDoesNotOpenShowsTheLinkAndTheWindowStays() {
        accountPageOpens = false
        let flow = flow(isPro: false)
        flow.turnOn()
        flow.proActions.getPro()
        XCTAssertEqual(closed, 0)
        XCTAssertTrue(flow.accountLinkShown)
    }

    func testNotNowOnTheProScreenForgetsThePress() {
        let flow = flow(isPro: false)
        flow.turnOn()
        flow.proActions.free()
        XCTAssertEqual(closed, 1)
        XCTAssertNil(TargetIntro.wantedAt(defaults))
        XCTAssertEqual(flow.proActions.freeTitle, "Not now")
    }

    /// Turn on, Back, Not now: the user said no, and paying later turns nothing on (Kimi review, P1).
    func testBackThenNotNowForgetsThePress() {
        let flow = flow(isPro: false)
        flow.turnOn()
        flow.back()
        flow.notNow()
        XCTAssertEqual(closed, 1)
        XCTAssertNil(TargetIntro.wantedAt(defaults))
    }

    func testNotNowOnTheFirstScreenTurnsNothingOn() {
        let flow = flow(isPro: true)
        flow.notNow()
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(turnedOn, 0)
    }

    // MARK: - Settings

    func testTappingTargetInSettingsAsAFreeUserOpensThePaywallInstead() {
        XCTAssertEqual(ProcessingModePick.tap(.target, isPro: false), .showPro)
        XCTAssertEqual(ProcessingModePick.tap(.target, isPro: true), .select)
        XCTAssertEqual(ProcessingModePick.tap(.structured, isPro: false), .select)
    }
}
