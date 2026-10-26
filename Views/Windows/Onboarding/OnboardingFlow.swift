import AppKit
import Combine
import Foundation

/// The two permissions the first run asks for.
enum OnboardingPermission: Equatable {
    case microphone, accessibility
}

/// The two permissions as macOS has them now. Reading them asks nothing.
struct OnboardingPermissions: Equatable {
    enum Microphone: Equatable {
        /// Nobody has answered the prompt yet: the button asks.
        case notAsked
        case allowed
        /// A standing no: only System Settings can change it.
        case denied
    }

    var microphone: Microphone
    var accessibility: Bool

    /// What `microphone` says, and whether this process is trusted for Accessibility.
    @MainActor
    static func reading(_ microphone: any AudioSource) -> OnboardingPermissions {
        OnboardingPermissions(microphone: microphone.hasPermission ? .allowed
                                  : microphone.permissionUndetermined ? .notAsked : .denied,
                              accessibility: AXIsProcessTrusted())
    }
}

/// D1 — the first run's four screens as one state machine: which screen is up, where a closed window or a quit
/// resumes (F4), how it ends, and the permission watch the window's return latch listens to.
@MainActor
final class OnboardingFlow: ObservableObject {
    enum Screen: Int, CaseIterable {
        case welcome, enable, practice, pro

        /// "1 of 4" … "4 of 4", above every screen.
        var step: String { "\(rawValue + 1) of \(Self.allCases.count)" }
    }

    /// How the onboarding ended: Continue with Free, Get Pro (the site is open in the browser), or Continue as a
    /// Pro user.
    enum Ending: Equatable {
        case free, getPro, pro
    }

    /// The Accessibility row after its button (mockup v6 "helper" and "off").
    enum AccessibilityStep: Equatable {
        case notAsked
        /// The user is in System Settings.
        case waiting
        /// They came back without turning it on.
        case notOnYet
    }

    /// What the flow does outside itself. The defaults are macOS itself; tests pass their own.
    struct Environment {
        /// The permissions now; reading asks nothing.
        var permissions: @MainActor () -> OnboardingPermissions
        /// The microphone prompt — the first record press's own (TranscriptionCoordinator.askForMicrophone).
        var askForMicrophone: @MainActor (_ answered: @escaping @MainActor (Bool) -> Void) -> Void
        /// A practice on the app's own microphone, the engine dictation uses and the capture arbiter (C6).
        var makePractice: @MainActor () -> PracticeRecorder
        /// Opens System Settings at the permission's pane. Accessibility asks macOS first, which is what lists
        /// MetaWhisp there (C4).
        var openPane: @MainActor (OnboardingPermission) -> Void = { permission in
            switch permission {
            case .microphone: PermissionsService.shared.openMicrophoneSettings()
            case .accessibility: PermissionsService.askForAccessibility(PermissionAsk())
            }
        }
        /// The site's account page in the browser; false when it did not open.
        var openAccountPage: @MainActor () -> Bool = { AccountPage.open() }
    }

    /// The screen a closed window or a quit left; the next show opens on it.
    static let resumeKey = "onboardingResumeScreen"

    @Published private(set) var screen: Screen
    @Published private(set) var permissions: OnboardingPermissions
    @Published private(set) var accessibilityStep = AccessibilityStep.notAsked
    /// The practice, while its screen is up: it holds the microphone for that long and no longer.
    @Published private(set) var practice: PracticeRecorder?
    /// The browser did not open the account page: the link is shown, with Copy.
    @Published private(set) var accountLinkShown = false

    /// A button opened System Settings for this permission — the window arms its return.
    var onSettingsOpened: ((OnboardingPermission) -> Void)?
    /// The permission was just granted — the window comes back if a Settings button armed it.
    var onGranted: ((OnboardingPermission) -> Void)?

    private let defaults: UserDefaults
    private let environment: Environment
    private let finish: @MainActor (Ending) -> Void

    init(defaults: UserDefaults = .standard, environment: Environment, finish: @escaping @MainActor (Ending) -> Void) {
        self.defaults = defaults
        self.environment = environment
        self.finish = finish
        screen = Screen(rawValue: defaults.integer(forKey: Self.resumeKey)) ?? .welcome
        permissions = environment.permissions()
        if screen == .practice { beginPractice() }
    }

    func next() { move(to: screen.rawValue + 1) }
    func back() { move(to: screen.rawValue - 1) }

    /// Kept the moment it changes, so a quit resumes here as a closed window does.
    private func move(to index: Int) {
        guard let target = Screen(rawValue: index) else { return }
        if target != .practice { endPractice() }
        screen = target
        defaults.set(target.rawValue, forKey: Self.resumeKey)
        if target == .practice { beginPractice() }
    }

    /// The window closed — "finish later": the practice gives the microphone back (C4).
    func windowClosed() {
        endPractice()
    }

    /// The last button. The language is written before the finish (C7), and the resume point goes.
    func complete(_ ending: Ending) {
        endPractice()
        AppSettings.recordOnboardingCompleted(in: defaults)
        defaults.removeObject(forKey: Self.resumeKey)
        NSLog("[Onboarding] completed — %@", "\(ending)")
        finish(ending)
    }

    // MARK: - Permissions

    /// Reads both permissions again, and reports each one granted since the last read.
    func refreshPermissions() {
        let was = permissions
        let now = environment.permissions()
        guard now != was else { return }
        permissions = now
        if was.microphone != .allowed, now.microphone == .allowed { onGranted?(.microphone) }
        if !was.accessibility, now.accessibility { onGranted?(.accessibility) }
    }

    /// A button that sends the user to System Settings.
    func openSettings(for permission: OnboardingPermission) {
        environment.openPane(permission)
        onSettingsOpened?(permission)
    }

    /// The microphone row's button: the prompt while nobody has answered it; System Settings for a standing no,
    /// since macOS will not ask twice.
    func microphoneButton() {
        switch permissions.microphone {
        case .notAsked: environment.askForMicrophone { [weak self] _ in self?.refreshPermissions() }
        case .denied: openSettings(for: .microphone)
        case .allowed: break
        }
    }

    /// The Accessibility row's button: macOS is asked, the pane opens, and the row waits for the user.
    func accessibilityButton() {
        openSettings(for: .accessibility)
        if !permissions.accessibility { accessibilityStep = .waiting }
    }

    // MARK: - The practice

    private func beginPractice() {
        guard practice == nil else { return }
        let practice = environment.makePractice()
        practice.begin()
        self.practice = practice
    }

    /// Back, Continue, the window closing, the finish: the attempt is dropped and the microphone given back.
    private func endPractice() {
        practice?.end()
        practice = nil
    }

    /// The record button and Space: start, or stop and transcribe.
    func record() {
        practice?.toggle()
    }

    /// Esc: an attempt under way is cancelled and nothing is kept; the screen stays (C3).
    func cancelAttempt() {
        guard let practice, practice.phase == .listening || practice.phase == .transcribing else { return }
        practice.cancel()
    }

    /// "Skip for now", when the speech model could not be got: on to the Pro screen; the practice ends and keeps
    /// nothing.
    func skipPractice() {
        guard screen == .practice else { return }
        next()
    }

    /// "Already have Pro? Sign in": the site's account page; the onboarding goes on.
    func signIn() {
        accountLinkShown = !environment.openAccountPage()
    }

    /// Get Pro: the site's account page, where the user signs in and pays; the onboarding is done (PLAN-v6 §5.2).
    /// When the browser does not open, the link is shown and the onboarding stays, so it can be read.
    func getPro() {
        guard environment.openAccountPage() else {
            accountLinkShown = true
            return
        }
        complete(.getPro)
    }

    /// MetaWhisp is in front again — back from System Settings or a prompt.
    func appBecameActive() {
        refreshPermissions()
        if accessibilityStep == .waiting, !permissions.accessibility { accessibilityStep = .notOnYet }
    }
}
