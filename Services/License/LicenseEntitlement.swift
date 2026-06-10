import Foundation

/// LIC-1 (ITER-045 Iter 3) — pure decision for how long a CACHED Pro state may be
/// trusted without a fresh server confirmation.
///
/// The bug: on launch `isPro` is set purely from the presence of a Keychain
/// license key, and `verify()`'s offline catch keeps Pro forever — so a stale or
/// planted key unlocks Pro indefinitely offline. This bounds that trust with a
/// grace TTL, behind a feature flag so legit offline Pro users aren't cut off
/// abruptly. (Defence-in-depth: the Pro proxy also validates the key server-side.)
enum LicenseEntitlement {

    /// Default offline grace before a cached Pro must be re-confirmed by the server.
    static let defaultGraceTTL: TimeInterval = 72 * 60 * 60  // 72 hours

    /// Whether a cached Pro state should still be trusted right now.
    ///
    /// - `enforce == false` (feature flag off, the default) → a present key is
    ///   enough; behaviour is identical to today.
    /// - `enforce == true` → trust only if the server confirmed within `ttl`.
    ///   Fails CLOSED when `lastVerifiedAt` is nil (never confirmed, e.g. a planted
    ///   key), so the grace can't be bypassed by simply omitting the timestamp.
    static func cachedProIsTrusted(
        hasActiveKey: Bool,
        lastVerifiedAt: Date?,
        now: Date,
        ttl: TimeInterval = defaultGraceTTL,
        enforce: Bool
    ) -> Bool {
        guard hasActiveKey else { return false }
        guard enforce else { return true }
        guard let last = lastVerifiedAt else { return false }
        return now.timeIntervalSince(last) < ttl
    }
}
