import Foundation

/// Pure, truthful mapping from post-sign-in license state to the banner shown
/// after the `metawhisp://auth` deep link returns from the browser.
///
/// Extracted from `AppDelegate.handleURLEvent` so the wording is unit-testable
/// and can never claim "Pro activated" when activation didn't actually grant Pro
/// (Rule 13 — no fabricated state). Returns `nil` when there is genuinely
/// nothing to report (no Pro, no error, no email — e.g. a malformed return), so
/// the handler stays silent instead of surfacing an empty banner.
enum SignInBannerDecision {

    struct Banner: Equatable {
        let title: String
        let body: String
    }

    static func resolve(isPro: Bool, lastError: String?, email: String?) -> Banner? {
        if isPro {
            return Banner(
                title: "Pro activated",
                body: email.map { "Signed in as \($0)" } ?? "Your Pro subscription is now active."
            )
        }
        if let error = lastError, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Banner(title: "Sign-in failed", body: error)
        }
        if let email = email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Banner(title: "Signed in", body: "\(email) — no active subscription.")
        }
        return nil
    }
}
