import AppKit
import SwiftUI

/// D1 — a button that sends the user to System Settings arms one return: the grant brings the onboarding window
/// back once (A4). The ceiling is ten minutes from the press, and a closed window clears it (A5).
struct PermissionReturnLatch {
    static let limit: TimeInterval = 10 * 60

    private(set) var pending: (permission: OnboardingPermission, deadline: Date)?

    mutating func arm(_ permission: OnboardingPermission, now: Date) {
        pending = (permission, now.addingTimeInterval(Self.limit))
    }

    /// `permission` was just granted: true once, for the armed permission inside its ten minutes.
    mutating func granted(_ permission: OnboardingPermission, now: Date) -> Bool {
        guard let pending else { return false }
        guard now <= pending.deadline else {
            self.pending = nil
            return false
        }
        guard pending.permission == permission else { return false }
        self.pending = nil
        return true
    }

    mutating func clear() { pending = nil }
}

/// Where the onboarding window goes. It comes to the user — never the user to it: a window open on another Space
/// is closed and made again on this one (the window invariant; the screen is kept by the flow).
enum OnboardingWindowPlacement: Equatable {
    case create, bringForward, reopenHere, nothing

    static func show(hasWindow: Bool, isVisible: Bool, isOnActiveSpace: Bool) -> Self {
        guard hasWindow else { return .create }
        return isVisible && isOnActiveSpace ? .bringForward : .reopenHere
    }

    /// A permission's return: only an open window comes back.
    static func comeBack(hasWindow: Bool, isVisible: Bool, isOnActiveSpace: Bool) -> Self {
        hasWindow ? show(hasWindow: true, isVisible: isVisible, isOnActiveSpace: isOnActiveSpace) : .nothing
    }

    /// Where a window just ordered front landed, checked on the next run loop turn as the main window checks its own
    /// (`[SpaceTrace]`): on the user's Space; or visible on another one — made again here, once; a second miss is
    /// only logged, so a window that will not land never loops.
    enum Landing: Equatable {
        case landed, makeAgain, logOnly
    }

    static func afterOrderFront(isVisible: Bool, isOnActiveSpace: Bool, alreadyMadeAgain: Bool) -> Landing {
        if isVisible && isOnActiveSpace { return .landed }
        return isVisible && !alreadyMadeAgain ? .makeAgain : .logOnly
    }
}

/// The onboarding window: 720 × 600 at the normal level, on the Space the user is on. The red close button means
/// "finish later" — the window is closed and released, and the next launch opens on the screen the user left.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 720, height: 600)
    static let level: NSWindow.Level = .normal

    /// What the onboarding works with; the app sets it before `show()`.
    struct Dependencies {
        let coordinator: TranscriptionCoordinator
        let modelPreparer: ModelPreparer
        let captureArbiter: CaptureArbiter
        /// The app's own microphone for the practice; the permissions are read from it.
        let microphone: AudioRecordingService
        let openMainWindow: () -> Void
    }

    var dependencies: Dependencies?
    /// The window was made again after landing on another Space, in this show (`afterOrderFront`).
    private var madeAgain = false

    private(set) var window: NSWindow?
    private(set) var flow: OnboardingFlow?
    private var latch = PermissionReturnLatch()
    /// The permissions, read every second while the window is open; and MetaWhisp coming back to the front.
    private var watch: Timer?
    private var returned: NSObjectProtocol?

    func show() {
        guard let dependencies else {
            NSLog("[Onboarding] not set up by the app — nothing shown")
            return
        }
        // C5 — the quick model starts as the onboarding opens.
        dependencies.modelPreparer.prepareForOnboarding()
        madeAgain = false
        let placement = OnboardingWindowPlacement.show(hasWindow: window != nil, isVisible: window?.isVisible == true,
                                                       isOnActiveSpace: window?.isOnActiveSpace == true)
        Self.trace(window, "show:\(placement)")
        switch placement {
        case .create: create(dependencies)
        case .bringForward: bringForward()
        case .reopenHere: reopenHere(dependencies)
        case .nothing: break
        }
    }

    private func create(_ dependencies: Dependencies) {
        let microphone = dependencies.microphone
        let coordinator = dependencies.coordinator
        let arbiter = dependencies.captureArbiter
        let flow = OnboardingFlow(
            environment: .init(
                permissions: { .reading(microphone) },
                askForMicrophone: { answered in coordinator.askForMicrophone(PermissionAsk(), answered: answered) },
                makePractice: {
                    PracticeRecorder(microphone: microphone, engine: { [weak coordinator] in coordinator?.activeEngine },
                                     arbiter: arbiter)
                }),
            finish: { [weak self] ending in self?.finished(ending) })
        flow.onSettingsOpened = { [weak self] permission in self?.latch.arm(permission, now: Date()) }
        flow.onGranted = { [weak self] permission in self?.granted(permission) }

        let window = Self.makeWindow(rootView: OnboardingContainer(flow: flow, preparer: dependencies.modelPreparer,
                                                                   microphone: microphone))
        window.delegate = self
        window.center()
        self.window = window
        self.flow = flow
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak flow] _ in
            Task { @MainActor in flow?.refreshPermissions() }
        }
        returned = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { [weak flow] _ in
            Task { @MainActor in flow?.appBecameActive() }
        }
        bringForward()
        NSLog("[Onboarding] window opened on screen %@", flow.screen.step)
    }

    /// The window itself, not yet shown: 720 × 600 in all, the transparent title bar over the content, at the normal
    /// level. The window is sized by its frame, and only the window sizes the screens: sized from its content, the
    /// title bar's 32 pt were added on top — a 632 pt window with an empty band under the footer (owner 2026-10-25).
    /// Under the app's SwiftUI lifecycle that happens to any window whose content view is a hosting view, whatever its
    /// sizing options (600 → 632 on the turn after ordering front, measured in a SwiftUI app); held in the window's
    /// own plain view, the screens stay 600. The render tests draw the screens in this same window.
    static func makeWindow<Content: View>(rootView: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Welcome to MetaWhisp"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = level
        window.isReleasedWhenClosed = false
        // macOS 26 Tahoe — same restoration-crash guard as MainWindowController.
        window.isRestorable = false
        // Set once, for the window's whole life: ordered front, it moves to the Space the user is on — never sticky,
        // never parked (the window invariant, `MWWindowBehavior.main`).
        window.collectionBehavior = MWWindowBehavior.main
        let own = NSView(frame: NSRect(origin: .zero, size: size))
        let screens = NSHostingView(rootView: rootView)
        screens.sizingOptions = []
        screens.frame = own.bounds
        screens.autoresizingMask = [.width, .height]
        own.addSubview(screens)
        window.contentView = own
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        return window
    }

    /// Brought to the front on the user's Space (E6): its behaviour, set at creation, moves it there. The app is
    /// never activated for it — `NSApp.activate()` is what threw the owner to another Space (MainWindowController's
    /// history); on 2026-10-25 "Show onboarding" pressed ten times in three seconds made the window ten times, each
    /// one off the user's Space. Where it landed is checked on the next run loop turn and written to the log.
    private func bringForward() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window === self.window else { return }
            let landing = OnboardingWindowPlacement.afterOrderFront(isVisible: window.isVisible,
                                                                    isOnActiveSpace: window.isOnActiveSpace,
                                                                    alreadyMadeAgain: self.madeAgain)
            Self.trace(window, "after-order-front:\(landing)")
            switch landing {
            case .landed:
                break
            case .makeAgain:
                NSLog("[SpaceTrace] VIOLATION — the onboarding window is not on the user's Space; made again here")
                self.madeAgain = true
                if let dependencies = self.dependencies { self.reopenHere(dependencies) }
            case .logOnly:
                NSLog("[SpaceTrace] VIOLATION — the onboarding window is still not on the user's Space")
            }
        }
    }

    /// One line on where the window is — the main window's `[SpaceTrace]` format, so both read alike.
    private static func trace(_ window: NSWindow?, _ phase: String) {
        guard let window else {
            NSLog("[SpaceTrace] onboarding %@ — no window", phase)
            return
        }
        let screens = NSScreen.screens
        let index = window.screen.flatMap { screen in screens.firstIndex { $0 == screen } }.map(String.init) ?? "-"
        NSLog("[SpaceTrace] onboarding %@ — winFrame=%@ winScreen=%@ onActiveSpace=%@ visible=%@ key=%@ screens=%d",
              phase, NSStringFromRect(window.frame), index, window.isOnActiveSpace ? "yes" : "no",
              window.isVisible ? "yes" : "no", window.isKeyWindow ? "yes" : "no", screens.count)
    }

    /// Open on another Space: closed there, made again here, on the screen the flow kept.
    private func reopenHere(_ dependencies: Dependencies) {
        window?.close()
        create(dependencies)
    }

    /// A grant the latch was armed for brings the window back once, to the current Space.
    private func granted(_ permission: OnboardingPermission) {
        guard latch.granted(permission, now: Date()) else { return }
        NSLog("[Onboarding] %@ granted — the window comes back", "\(permission)")
        // A return of its own: the show's one remake is not spent for it (Codex 2026-10-25, P2).
        madeAgain = false
        switch OnboardingWindowPlacement.comeBack(hasWindow: window != nil, isVisible: window?.isVisible == true,
                                                  isOnActiveSpace: window?.isOnActiveSpace == true) {
        case .bringForward: bringForward()
        case .reopenHere: if let dependencies { reopenHere(dependencies) }
        case .create, .nothing: break
        }
    }

    private func finished(_ ending: OnboardingFlow.Ending) {
        window?.close()
        dependencies?.openMainWindow()
    }

    // MARK: - NSWindowDelegate

    /// The red button, a reopen and the finish all end here: the window is released with everything it held.
    func windowWillClose(_ notification: Notification) {
        watch?.invalidate()
        watch = nil
        if let returned { NotificationCenter.default.removeObserver(returned) }
        returned = nil
        latch.clear()
        if let screen = flow?.screen { NSLog("[Onboarding] window closed on screen %@", screen.step) }
        flow?.windowClosed()
        flow = nil
        window = nil
    }
}
