import Foundation

/// ITER-085 — the Target window's three screens: the film with Turn on Target, the Pro screen for a Free user, and
/// "Target is on". Turn on switches a Pro user at once; a Free user sees the Pro screen, and Get Pro or Sign in — the
/// user going to pay — keeps the press, so that paying turns Target on (`TargetIntro.turnsOn`). Any other way out
/// (Not now, Back, the red button) arms nothing. Nothing is turned on without Pro.
@MainActor
final class TargetIntroFlow: ObservableObject {
    enum Screen: Equatable {
        case intro, pro, on
    }

    /// What the flow does outside itself. The defaults are the app's; tests pass their own.
    struct Environment {
        var isPro: @MainActor () -> Bool = { LicenseService.shared.isPro && LicenseService.shared.licenseKey != nil }
        /// Target becomes the processing mode.
        var turnOn: @MainActor () -> Void = { AppSettings.shared.processingMode = ProcessingMode.target.rawValue }
        /// The site's account page in the browser; false when it did not open.
        var openAccountPage: @MainActor () -> Bool = { AccountPage.open() }
        var defaults: UserDefaults = .standard
        var now: () -> Date = Date.init
    }

    @Published private(set) var screen = Screen.intro
    /// The browser did not open the account page: the link is shown, with Copy.
    @Published private(set) var accountLinkShown = false

    private let environment: Environment
    private let close: @MainActor () -> Void

    init(environment: Environment = Environment(), close: @escaping @MainActor () -> Void) {
        self.environment = environment
        self.close = close
    }

    /// Turn on Target: at once with Pro; otherwise the Pro screen.
    func turnOn() {
        if environment.isPro() {
            environment.turnOn()
            TargetIntro.forgetWanted(environment.defaults)
            screen = .on
        } else {
            screen = .pro
        }
    }

    /// Get Pro or Sign in: the press is kept for 7 days.
    private func goingToPay() {
        TargetIntro.rememberWanted(environment.defaults, now: environment.now())
    }

    /// Not now, on the first screen: the window closes and nothing turns on — also after Turn on and Back, so the
    /// press made before is forgotten.
    func notNow() {
        TargetIntro.forgetWanted(environment.defaults)
        close()
    }

    /// "Target is on" has been read.
    func done() {
        close()
    }

    func back() {
        screen = .intro
    }

    /// The Pro screen's buttons. Not now there is the answer to the price: the press is forgotten. Get Pro keeps it —
    /// the user is paying — and closes the window; a browser that did not open shows the link and keeps the window.
    var proActions: ProScreen.Actions {
        ProScreen.Actions(
            back: { [weak self] in self?.back() },
            free: { [weak self] in
                guard let self else { return }
                TargetIntro.forgetWanted(environment.defaults)
                close()
            },
            getPro: { [weak self] in
                guard let self else { return }
                goingToPay()
                guard environment.openAccountPage() else {
                    accountLinkShown = true
                    return
                }
                close()
            },
            signIn: { [weak self] in
                guard let self else { return }
                goingToPay()
                accountLinkShown = !environment.openAccountPage()
            },
            continueAsPro: { [weak self] in self?.turnOn() },
            freeTitle: "Not now")
    }
}
