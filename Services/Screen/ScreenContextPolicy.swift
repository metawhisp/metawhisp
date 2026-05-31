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
    ///   An EMPTY whitelist must NOT silently disable all capture, so it is
    ///   treated as "no whitelist configured" (`nil`).
    /// - any other mode (default `"blacklist"`): listed apps are excluded →
    ///   `blacklist` = parsed set, `whitelist` = nil.
    static func resolve(mode: String, appList: String) -> (blacklist: Set<String>, whitelist: Set<String>?) {
        let items = appList
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let set = Set(items)

        if mode == "whitelist" {
            return (blacklist: [], whitelist: set.isEmpty ? nil : set)
        }
        return (blacklist: set, whitelist: nil)
    }
}
