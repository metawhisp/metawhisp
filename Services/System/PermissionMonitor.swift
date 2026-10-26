import AppKit
import ApplicationServices

/// ITER-075 step 0, US-0.3 — the one place that watches Accessibility and
/// Screen Recording, for the life of the app.
///
/// A grant made at any time — ten seconds or ten hours after launch — reaches
/// whatever needs it at once, with no restart. The watch it replaces polled
/// for 600 s and then gave up: after a re-signed build on 2026-09-25 the owner
/// granted Accessibility later, and Right ⌘ and the layout fix stayed dead
/// until a relaunch ("still not trusted after 602s").
///
/// It checks on every app switch (leaving System Settings is one), on our own
/// activation, and on a timer. It never stops: the release of this gate is the
/// grant itself, whenever it comes.
@MainActor
final class PermissionMonitor {
    struct State: Equatable {
        var accessibility: Bool
        var screenRecording: Bool
    }

    enum Change: Equatable { case granted, revoked }

    /// Runs `action` once, `after` seconds from now.
    typealias Schedule = (_ after: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void

    /// What changed between two readings of one permission, if anything.
    nonisolated static func change(was: Bool, is now: Bool) -> Change? {
        switch (was, now) {
        case (false, true): return .granted
        case (true, false): return .revoked
        default: return nil
        }
    }

    /// Seconds until the next timed check: fast while a permission something
    /// needs is missing, so a grant lands within seconds; slow otherwise, so a
    /// revocation is still noticed. Screen Recording counts only while screen
    /// context or meeting recording needs it.
    nonisolated static func interval(for state: State, needsScreenRecording: Bool) -> TimeInterval {
        let missing = !state.accessibility || (needsScreenRecording && !state.screenRecording)
        return missing ? 5 : 60
    }

    /// The system's answer now. Neither call prompts.
    nonisolated static func readSystem() -> State {
        State(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess())
    }

    /// A main-run-loop timer, with a fifth of its interval as tolerance.
    static func timerSchedule(after: TimeInterval, action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: after, repeats: false) { _ in
            Task { @MainActor in action() }
        }
        timer.tolerance = after / 5
        RunLoop.main.add(timer, forMode: .common)
    }

    var onAccessibility: ((Change) -> Void)?
    var onScreenRecording: ((Change) -> Void)?
    private(set) var state: State
    private let read: () -> State
    private let needsScreenRecording: () -> Bool
    private let schedule: Schedule
    private var observers: [NSObjectProtocol] = []
    /// Bumped by every schedule: a timed check that is no longer the latest
    /// does nothing, so a restart at a new rate never leaves two chains.
    private var generation = 0
    private var started = false

    init(read: @escaping () -> State = PermissionMonitor.readSystem,
         needsScreenRecording: @escaping () -> Bool = { true },
         schedule: @escaping Schedule = PermissionMonitor.timerSchedule) {
        self.read = read
        self.needsScreenRecording = needsScreenRecording
        self.schedule = schedule
        self.state = read()
    }

    /// Starts watching from the permissions as they are now. Called once, at
    /// launch, right before the hotkeys are installed.
    func start() {
        state = read()
        started = true
        let checkNow: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: checkNow))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: checkNow))
        NSLog("[PermissionMonitor] watching — accessibility=%@, screen=%@",
              state.accessibility ? "yes" : "no", state.screenRecording ? "yes" : "no")
        scheduleCheck()
    }

    /// Reads both permissions and reports each one that changed. A change that
    /// moves the watch to another rate restarts the timer at once.
    func check() {
        let was = state
        state = read()
        if let change = Self.change(was: was.accessibility, is: state.accessibility) {
            NSLog("[PermissionMonitor] Accessibility %@", change == .granted ? "granted" : "revoked")
            onAccessibility?(change)
        }
        if let change = Self.change(was: was.screenRecording, is: state.screenRecording) {
            NSLog("[PermissionMonitor] Screen Recording %@", change == .granted ? "granted" : "revoked")
            onScreenRecording?(change)
        }
        let needsScreen = needsScreenRecording()
        if started, Self.interval(for: was, needsScreenRecording: needsScreen)
            != Self.interval(for: state, needsScreenRecording: needsScreen) {
            scheduleCheck()
        }
    }

    private func scheduleCheck() {
        generation += 1
        let mine = generation
        schedule(Self.interval(for: state, needsScreenRecording: needsScreenRecording())) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.check()
            if self.generation == mine { self.scheduleCheck() }
        }
    }
}
