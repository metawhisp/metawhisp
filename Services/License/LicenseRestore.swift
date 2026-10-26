import Foundation
import Security

/// ITER-075 step 0, US-0.4 — the saved Pro session, read back from the
/// keychain. An item that exists but can't be read is a keychain problem,
/// never "signed out": nothing is cleared, nothing deleted, nothing verified,
/// and the owner is told what to do.
enum LicenseRestore: Equatable {
    case restored(token: String?, email: String?, licenseKey: String?, plan: String?, stamp: String?)
    case unreadable(account: String, status: OSStatus)

    /// The Pro session items, in the order they are read.
    static let accounts = [
        "com.metawhisp.sessionToken",
        "com.metawhisp.proEmail",
        "com.metawhisp.licenseKey",
        "com.metawhisp.proPlan",
        "com.metawhisp.lastVerifiedAt",
    ]

    static func decide(_ reads: [String: KeychainRead]) -> LicenseRestore {
        var values: [String: String] = [:]
        for account in accounts {
            switch reads[account] ?? .notFound {
            case .value(let text): values[account] = text
            case .notFound: continue
            case .failed(let status): return .unreadable(account: account, status: status)
            }
        }
        return .restored(token: values[accounts[0]], email: values[accounts[1]],
                         licenseKey: values[accounts[2]], plan: values[accounts[3]],
                         stamp: values[accounts[4]])
    }

    /// Shown in Settings → Account while the saved session can't be read.
    static func problemMessage(status: OSStatus) -> String {
        "MetaWhisp can't read your Pro session from the keychain (error \(status)). Nothing was deleted. "
            + "If macOS asks for keychain access, choose Always Allow; otherwise unlock the login keychain "
            + "in Keychain Access, then restart MetaWhisp."
    }

    /// Shown when a Pro sign-in succeeded but the keychain refused to save it.
    static func writeProblemMessage(status: OSStatus) -> String {
        "Pro is on for this session only: the keychain refused to save it (error \(status)). "
            + "If macOS asks for keychain access, choose Always Allow; otherwise unlock the login keychain "
            + "in Keychain Access, then sign in again."
    }

    /// Shown when a sign-in without an active subscription could not be saved.
    static func signInNotSavedMessage(status: OSStatus) -> String {
        "Signed in, but the keychain refused to save it (error \(status)). "
            + "If macOS asks for keychain access, choose Always Allow; otherwise unlock the login keychain "
            + "in Keychain Access, then sign in again."
    }

    /// Shown at launch when nothing is saved because the last sign-in could not be.
    static func unsavedAtLaunchMessage(status: OSStatus) -> String {
        "Your last sign-in couldn't be saved to the keychain (error \(status)), so you are signed out. "
            + "Sign in again; if macOS asks for keychain access, choose Always Allow."
    }

    /// What a sign-in tells the owner about its keychain writes: nothing when
    /// they all went through, and never a claim of Pro the server didn't grant.
    static func activationMessage(isPro: Bool, failedWrite: OSStatus?) -> String? {
        guard let failedWrite else { return nil }
        return isPro ? writeProblemMessage(status: failedWrite) : signInNotSavedMessage(status: failedWrite)
    }

    /// What a launch does with the restored session.
    struct LaunchPlan: Equatable {
        /// The session token to verify with the server; nil verifies nothing.
        let verifyToken: String?
        /// Shown in Settings → Account; nil shows nothing.
        let message: String?
        /// A readable license key ends the "last sign-in couldn't be saved" note.
        let clearUnsavedMarker: Bool
    }

    static func launchPlan(_ decision: LicenseRestore, unsavedStatus: OSStatus?) -> LaunchPlan {
        switch decision {
        case .unreadable(_, let status):
            return LaunchPlan(verifyToken: nil, message: problemMessage(status: status), clearUnsavedMarker: false)
        case .restored(let token, _, let licenseKey, _, _):
            if let licenseKey, !licenseKey.isEmpty {
                return LaunchPlan(verifyToken: token, message: nil, clearUnsavedMarker: true)
            }
            if let unsavedStatus, token == nil {
                return LaunchPlan(verifyToken: token, message: unsavedAtLaunchMessage(status: unsavedStatus),
                                  clearUnsavedMarker: false)
            }
            return LaunchPlan(verifyToken: token, message: nil, clearUnsavedMarker: false)
        }
    }
}
