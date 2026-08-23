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
