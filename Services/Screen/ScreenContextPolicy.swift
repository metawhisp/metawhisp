import Foundation

/// AUD-021 fix — resolve the user's Screen Context app filter into the
/// `(blacklist, whitelist)` pair that `ScreenContextService.startMonitoring`
/// expects.
///
/// Before this, every `startMonitoring` call site passed only `interval`, so
/// `Settings → screenContextMode` + `screenContextAppList` had NO effect: an app
/// the user explicitly excluded (or a whitelist-only choice) was still captured.
///
/// Pure + unit-tested so the privacy decision is verifiable without ScreenCaptureKit.
enum ScreenContextPolicy {

    /// - `mode == "whitelist"`: only the listed apps may be captured →
    ///   `whitelist` = parsed set, `blacklist` = [].
    ///   ITER-064A.2 — an EMPTY whitelist now fails CLOSED. It used to resolve
    ///   to `nil` so the feature would not silently stop working, but `nil`
    ///   means "no restriction", so a user who chose "only these apps" and had
    ///   not yet added one was having every app captured. Picking whitelist
    ///   mode is an expressed intent to restrict; an empty list allows nothing.
    /// - any other mode (default `"blacklist"`): listed apps are excluded →
    ///   `blacklist` = parsed set, `whitelist` = nil.
    static func resolve(mode: String, appList: String) -> (blacklist: Set<String>, whitelist: Set<String>?) {
        let items = appList
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let set = Set(items)

        if mode == "whitelist" {
            return (blacklist: [], whitelist: set)
        }
        return (blacklist: set, whitelist: nil)
    }

    /// ITER-064A.5 — the whole policy, resolved from current settings.
    ///
    /// The monitor loop used to be handed `(blacklist, whitelist)` once, when it
    /// started, and hold that for its lifetime. Nothing restarted it when the
    /// user changed mode or edited the app list, so switching to allowlist mode
    /// left the running loop on the old `nil` whitelist and it kept capturing
    /// everything until relaunch — the same fail-open as an empty allowlist, one
    /// layer up. Callers now ask for this per tick instead of storing it.
    ///
    /// `alwaysExcluded` are the built-in privacy exclusions (password managers,
    /// Keychain). They are merged into the blacklist, which beats the allowlist,
    /// so allowlisting a password manager cannot expose it.
    static func effective(
        alwaysExcluded: Set<String>,
        mode: String,
        appList: String
    ) -> (blacklist: Set<String>, whitelist: Set<String>?) {
        let resolved = resolve(mode: mode, appList: appList)
        return (blacklist: alwaysExcluded.union(resolved.blacklist),
                whitelist: resolved.whitelist)
    }

    /// Windows that are another assistant's output rather than the user's own
    /// work. Reading them feeds a model's text back into the agent that is
    /// meant to be commenting on what the user is doing: 24 of 62 cards and
    /// 1853 of 7157 captures in the week to 2026-08-29 came from here.
    ///
    /// Both bundle identifiers and display names, following `defaultBlacklist`
    /// — the Settings field holds whatever the user typed, so both sides of the
    /// comparison have to speak both.
    ///
    /// Unlike the password list this is a default, not a law: it applies to
    /// ambient capture and yields to an explicit allowlist entry. An AI-branded
    /// browser is NOT here — the user works in a browser, whoever built it.
    static let assistantWindows: Set<String> = [
        "com.anthropic.claudefordesktop", "Claude",
        "com.openai.chat", "com.openai.codex", "ChatGPT",
        "com.moonshot.kimichat", "Kimi",
        "com.metawhisp.app", "MetaWhisp",
    ]

    /// The rule for capture that nobody asked for — the polling loop.
    ///
    /// `defaultExcluded` is skipped unless the user named the app in an active
    /// allowlist, because picking "only these apps" and typing one in is an
    /// expressed intent and beats a default we chose on their behalf. In
    /// blacklist mode there is no vocabulary for "include this", so the default
    /// stands; that is the known limit of this rule.
    ///
    /// The on-demand path (a voice question about the screen) passes an empty
    /// set and so reduces to `isCaptureAllowed`: asking out loud is not ambient
    /// capture, and answering "I can't see it" to a question about the window
    /// in front of you is a different feature breaking.
    static func isAmbientCaptureAllowed(
        appName: String,
        bundleID: String,
        blacklist: Set<String>,
        whitelist: Set<String>?,
        defaultExcluded: Set<String>
    ) -> Bool {
        guard isCaptureAllowed(appName: appName, bundleID: bundleID,
                               blacklist: blacklist, whitelist: whitelist)
        else { return false }
        if let whitelist,
           whitelist.contains(bundleID) || whitelist.contains(appName) { return true }
        return !(defaultExcluded.contains(bundleID) || defaultExcluded.contains(appName))
    }

    /// The single capture-permission decision. Both `ScreenContextService`
    /// checkpoints (the change detector and the actual window grab) used to
    /// carry their own copy of this rule, which is how the empty-whitelist
    /// fail-open survived in two places at once.
    ///
    /// An app is matched by either its bundle identifier or its display name,
    /// because the Settings list holds whatever the user typed.
    static func isCaptureAllowed(
        appName: String,
        bundleID: String,
        blacklist: Set<String>,
        whitelist: Set<String>?
    ) -> Bool {
        // Exclusion always wins — being on both lists means excluded.
        if blacklist.contains(bundleID) || blacklist.contains(appName) { return false }
        // `nil` = blacklist mode, no allowlist configured. A non-nil set is an
        // active allowlist, and an empty one admits nothing.
        guard let whitelist else { return true }
        return whitelist.contains(bundleID) || whitelist.contains(appName)
    }
}
