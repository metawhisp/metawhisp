import Foundation

/// ITER-085 — the Target window after the update, and "turn it on once Pro is active", as values a test can drive.
enum TargetIntro {
    /// Set when the window is shown, and when the onboarding is completed: a new user meets Target on its Pro screen.
    static let seenKey = "targetIntroSeen"
    /// When a Free user pressed Turn on Target (and so went to the Pro screen).
    static let wantedAtKey = "targetWantedAt"
    /// The press turns Target on only within 7 days of it, so Target never comes on out of the blue.
    static let wantedLife: TimeInterval = 7 * 24 * 60 * 60
    /// The window waits this long after launch.
    static let launchQuiet: TimeInterval = 10

    enum Gate: Equatable {
        case show, wait, never
    }

    /// Whether the window shows now. At most once (`seen`), and only to someone who finished the onboarding. It waits
    /// for the launch to settle, and while a recording, a meeting, an errand or the onboarding window is busy — the end
    /// of that is the wait's release: the next idle check shows the window.
    static func gate(seen: Bool, onboarded: Bool, sinceLaunch: TimeInterval, busy: Bool) -> Gate {
        if seen || !onboarded { return .never }
        if sinceLaunch < launchQuiet || busy { return .wait }
        return .show
    }

    /// Whether Pro being active turns Target on now: the press is there and at most `wantedLife` old.
    static func turnsOn(wantedAt: Date?, isPro: Bool, now: Date) -> Bool {
        guard isPro, let wantedAt else { return false }
        let age = now.timeIntervalSince(wantedAt)
        return age >= 0 && age <= wantedLife
    }

    // MARK: - Kept in the user's defaults

    static func isSeen(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: seenKey)
    }

    static func markSeen(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }

    static func wantedAt(_ defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: wantedAtKey) as? Date
    }

    static func rememberWanted(_ defaults: UserDefaults = .standard, now: Date) {
        defaults.set(now, forKey: wantedAtKey)
    }

    /// Any choice of a mode in Settings, Not now, and the turning on itself end the press.
    static func forgetWanted(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: wantedAtKey)
    }
}

/// What a tap on a processing mode in Settings does: Target without Pro opens the Pro screen instead of choosing it.
enum ProcessingModePick: Equatable {
    case select, showPro

    static func tap(_ mode: ProcessingMode, isPro: Bool) -> ProcessingModePick {
        mode.needsPro && !isPro ? .showPro : .select
    }
}
