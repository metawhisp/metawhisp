import XCTest
@testable import MetaWhisp

/// D5 — the Pro screen, once, after the first words (US4): the yearly price as the site shows it, the eight things
/// Pro adds from one list — no screen hints and no browser agent (owner 2026-10-24, U1) — and Back | Continue with
/// Free | Get Pro. Get Pro opens metawhisp.com/account/ and finishes the onboarding; a Pro user sees "You have Pro"
/// with Continue (P1.10). The account page is a fake that opens or not as told.
@MainActor
final class ProScreenTests: XCTestCase {
    private var fixture: OnboardingFixture!

    override func setUpWithError() throws {
        fixture = try OnboardingFixture()
        fixture.permissions = OnboardingPermissions(microphone: .allowed, accessibility: true)
    }

    override func tearDownWithError() throws {
        fixture.tearDown()
    }

    private func proScreen() -> OnboardingFlow {
        fixture.defaults.set(OnboardingFlow.Screen.pro.rawValue, forKey: OnboardingFlow.resumeKey)
        let flow = fixture.flow()
        XCTAssertEqual(flow.screen, .pro)
        return flow
    }

    // MARK: - The words

    /// D5 — the price as the site has it: $30 a year, and the saving. Nothing under it: the billing line and
    /// "Included with Pro" were filler (owner 2026-10-25) — the tiles say what Pro includes.
    func testThePriceAndItsSaving() {
        XCTAssertEqual(ProScreen.price, "$30")
        XCTAssertEqual(ProScreen.per, "a year")
        XCTAssertEqual(ProScreen.save, "Save 68%")
    }

    /// The saving is what the words say: twelve months at the site's $7.77 are $93.24, and $30 is 67.8 % less — 68 %.
    func testTheSavingIsTheMonthlyPriceAgainstTheYearly() {
        XCTAssertEqual(ProScreen.monthly, 7.77, "the site's monthly price")
        let twelveMonths = ProScreen.monthly * 12
        XCTAssertEqual(twelveMonths, 93.24, accuracy: 0.001)
        XCTAssertEqual(Int(((1 - 30 / twelveMonths) * 100).rounded()), 68)
    }

    // MARK: - The price's arrival

    /// Owner 2026-10-25: the price counts down to $30, then the saving appears. It starts at a year at the monthly
    /// price, in whole dollars so the digits keep their width: $93 (12 × $7.77 = $93.24), never more than that.
    func testThePriceCountsDownFromAYearAtTheMonthlyPriceToTheYearlyOne() {
        XCTAssertEqual(ProScreen.Count.from, 93)
        XCTAssertLessThanOrEqual(ProScreen.Count.from, ProScreen.monthly * 12, "never more than a year at $7.77")
        XCTAssertEqual(ProScreen.Count.label(ProScreen.Count.from), "$93")
        XCTAssertEqual(ProScreen.Count.label(ProScreen.Count.to), ProScreen.price, "it lands on the price")
        XCTAssertEqual(ProScreen.Count.label(61.6), "$62", "whole dollars while it counts")
    }

    /// The chip comes first, then the price at $93, which counts down; the saving appears once the price is $30.
    /// With Reduce Motion there is no count — the price is $30 from the start — and the parts fade in together.
    func testTheChipComesFirstAndTheSavingOnceThePriceHasLanded() {
        let moving = ProScreen.Reveal(reduceMotion: false)
        XCTAssertLessThan(moving.chip, moving.price, "the chip, then the price")
        XCTAssertLessThan(moving.price, moving.count, "the price is seen at $93 before it counts")
        XCTAssertGreaterThanOrEqual(moving.counting, 1, "a count the eye can follow")
        XCTAssertGreaterThanOrEqual(moving.save, moving.count + moving.counting, "the saving once it has landed")
        XCTAssertLessThan(moving.save, 2.5, "all of it within the first seconds")
        let still = ProScreen.Reveal(reduceMotion: true)
        XCTAssertEqual(still.counting, 0, "no count")
        XCTAssertEqual([still.chip, still.price, still.count, still.save], [0, 0, 0, 0], "everything at once")
    }

    /// D6 — eight tiles, from one list; screen hints and the browser agent are not part of Pro.
    func testEightTilesFromOneListWithoutScreenHintsOrTheAgent() {
        XCTAssertEqual(ProScreen.tiles.map(\.title), ["Cloud dictation", "AI polish", "Translation", "MetaChat",
                                                      "Meeting notes", "Day and week summaries", "Search by meaning",
                                                      "Natural voices"])
        XCTAssertEqual(ProScreen.tiles.map(\.detail), ["5,400 minutes a month", "Clean, structured text",
                                                       "Into 11 languages, by voice or selection",
                                                       "Ask about your notes and meetings", "Summaries, tasks and memories",
                                                       "A short recap of each day and week",
                                                       "Find what you said, not just the words",
                                                       "Spoken answers in a natural voice"])
        let words = ProScreen.tiles.map { "\($0.title) \($0.detail)".lowercased() }
        XCTAssertFalse(words.contains { $0.contains("screen") || $0.contains("agent") || $0.contains("hint") })
        XCTAssertEqual(Set(ProScreen.tiles.map(\.symbol)).count, 8, "eight different icons")
    }

    func testTheFooterWords() {
        XCTAssertEqual(ProScreen.free, "Continue with Free")
        XCTAssertEqual(ProScreen.getPro, "Get Pro")
        XCTAssertEqual(ProScreen.youHavePro, "You have Pro")
        XCTAssertEqual(ProScreen.proceed, "Continue")
    }

    // MARK: - Free or Pro

    /// D3 / P1.10 — a Pro user is not offered Pro: "You have Pro" with Continue.
    func testAProUserSeesYouHaveProWithContinueAndNoGetPro() {
        XCTAssertEqual(ProScreen.offer(isPro: false), .plans)
        XCTAssertEqual(ProScreen.offer(isPro: true), .youHavePro)
    }

    /// D1 / D8 — Get Pro opens the site and finishes the onboarding. The app asks no network for it: offline, the
    /// browser opens all the same with its own page, and the onboarding finishes as well.
    func testGetProOpensTheSiteAndFinishesTheOnboarding() {
        let flow = proScreen()
        flow.getPro()
        XCTAssertEqual(fixture.accountPageOpens, 1)
        XCTAssertEqual(fixture.endings, [.getPro])
        XCTAssertTrue(fixture.defaults.bool(forKey: "hasCompletedOnboarding"))
    }

    /// D2 — the browser does not open: the link is shown with Copy, and the onboarding stays so it can be read.
    func testABrowserThatDoesNotOpenShowsTheLinkAndTheOnboardingStays() {
        fixture.browserOpens = false
        let flow = proScreen()
        flow.getPro()
        XCTAssertTrue(flow.accountLinkShown)
        XCTAssertEqual(fixture.endings, [])
        XCTAssertEqual(flow.screen, .pro)
        XCTAssertFalse(fixture.defaults.bool(forKey: "hasCompletedOnboarding"))
    }

    /// D7 — Continue with Free finishes, and opens nothing of Pro.
    func testContinueWithFreeFinishesAndOpensNothing() {
        let flow = proScreen()
        flow.complete(.free)
        XCTAssertEqual(fixture.endings, [.free])
        XCTAssertEqual(fixture.accountPageOpens, 0)
    }

    /// "Already have Pro? Sign in" opens the same page; the user comes back to "You have Pro" once the site's
    /// "Open in MetaWhisp" signs the app in.
    func testSignInOpensTheSamePageAndTheOnboardingStays() {
        let flow = proScreen()
        flow.signIn()
        XCTAssertEqual(fixture.accountPageOpens, 1)
        XCTAssertEqual(fixture.endings, [])
        XCTAssertEqual(flow.screen, .pro)
    }
}
