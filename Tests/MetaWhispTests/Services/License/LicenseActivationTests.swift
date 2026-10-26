import Security
import XCTest
@testable import MetaWhisp

/// A3 and the keychain (Codex P1, 1.4.0 review) — a sign-in the server accepted is an authenticated one, whether or
/// not the keychain keeps it: the account is signed in for this session, so the sign-in link's press is spent and a
/// later link asks. Only a sign-in the server did not accept — refused, unreadable, or no answer — gives the press
/// back. The activation used to report its keychain failure as a failed sign-in, which gave the press back for
/// another account's link. Through the licence's real activation, the session answer the test's own and a keychain
/// that refuses every write; the licence, the engine settings, the keychain and the sign-in note are put back after.
@MainActor
final class LicenseActivationTests: XCTestCase {
    private struct Saved {
        let isPro: Bool
        let email, licenseKey, plan, billingInterval, lastError, keychainProblem: String?
        let renewalDate, lastVerifiedAt: Date?
        let cancelAtPeriodEnd: Bool
        let unsavedSignIn: OSStatus?
        let unsavedNote: Any?
        let engine: String
        let cloudApplied: Bool
    }

    private var saved: Saved!
    private static let unsavedNoteKey = "license.unsavedSignInStatus"

    override func setUp() {
        let license = LicenseService.shared
        saved = Saved(isPro: license.isPro, email: license.email, licenseKey: license.licenseKey, plan: license.plan,
                      billingInterval: license.billingInterval, lastError: license.lastError,
                      keychainProblem: license.keychainProblem, renewalDate: license.renewalDate,
                      lastVerifiedAt: license.lastVerifiedAt, cancelAtPeriodEnd: license.cancelAtPeriodEnd,
                      unsavedSignIn: license.unsavedSignIn,
                      unsavedNote: UserDefaults.standard.object(forKey: Self.unsavedNoteKey),
                      engine: AppSettings.shared.transcriptionEngine,
                      cloudApplied: AppSettings.shared.proCloudDefaultApplied)
        KeychainHelper.backend = RefusingKeychain()
    }

    override func tearDown() {
        KeychainHelper.backend = KeychainHelper.defaultBackend
        let license = LicenseService.shared
        license.sendActivation = LicenseService.networkActivation
        license.isPro = saved.isPro
        license.email = saved.email
        license.licenseKey = saved.licenseKey
        license.plan = saved.plan
        license.billingInterval = saved.billingInterval
        license.lastError = saved.lastError
        license.keychainProblem = saved.keychainProblem
        license.renewalDate = saved.renewalDate
        license.lastVerifiedAt = saved.lastVerifiedAt
        license.cancelAtPeriodEnd = saved.cancelAtPeriodEnd
        license.unsavedSignIn = saved.unsavedSignIn
        license.isActivating = false
        if let note = saved.unsavedNote {
            UserDefaults.standard.set(note, forKey: Self.unsavedNoteKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.unsavedNoteKey)
        }
        AppSettings.shared.transcriptionEngine = saved.engine
        AppSettings.shared.proCloudDefaultApplied = saved.cloudApplied
    }

    /// A keychain that has nothing and keeps nothing: every write is refused, as a locked login keychain refuses.
    private struct RefusingKeychain: KeychainBackend {
        func copy(service: String, account: String) -> (OSStatus, Data?) { (errSecItemNotFound, nil) }
        func add(service: String, account: String, data: Data) -> OSStatus { errSecInteractionNotAllowed }
        func update(service: String, account: String, data: Data) -> OSStatus { errSecInteractionNotAllowed }
        func delete(service: String, account: String) -> OSStatus { errSecSuccess }
    }

    /// The session endpoint answers `status` with `body`; the request is never sent.
    private func server(_ status: Int, _ body: String) {
        LicenseService.shared.sendActivation = { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private let activePro = #"""
    {"email":"sam@example.com","license":{"license_key":"LICENSE-1","plan":"pro","status":"active"},"subscription":null}
    """#

    // MARK: - Accepted by the server

    /// The server accepted the token and the keychain refused to keep it: still authenticated — Pro for this session,
    /// and said so — so the sign-in link's press is spent.
    func testASignInTheKeychainCannotKeepIsStillAuthenticated() async {
        server(200, activePro)
        let authenticated = await LicenseService.shared.activate(token: "token-1")
        XCTAssertTrue(authenticated, "the server signed the account in")
        let license = LicenseService.shared
        XCTAssertTrue(license.isPro)
        XCTAssertEqual(license.email, "sam@example.com")
        XCTAssertEqual(license.unsavedSignIn, errSecInteractionNotAllowed, "the keychain's refusal is still told")
        XCTAssertEqual(license.lastError, LicenseRestore.writeProblemMessage(status: errSecInteractionNotAllowed))
    }

    /// …and an account with no active subscription, signed in but not kept: authenticated too.
    func testASignInWithoutProTheKeychainCannotKeepIsStillAuthenticated() async {
        server(200, #"{"email":"sam@example.com","license":null,"subscription":null}"#)
        let authenticated = await LicenseService.shared.activate(token: "token-1")
        XCTAssertTrue(authenticated)
        XCTAssertFalse(LicenseService.shared.isPro)
        XCTAssertEqual(LicenseService.shared.lastError,
                       LicenseRestore.signInNotSavedMessage(status: errSecInteractionNotAllowed))
    }

    // MARK: - Not accepted

    /// A token the server refuses is no sign-in: the press is given back.
    func testARefusedTokenIsNotAuthenticated() async {
        server(401, "{}")
        let authenticated = await LicenseService.shared.activate(token: "token-1")
        XCTAssertFalse(authenticated)
        XCTAssertEqual(LicenseService.shared.lastError, "Activation failed. Try signing in again.")
    }

    /// An answer that cannot be read is no sign-in either.
    func testAnAnswerThatCannotBeReadIsNotAuthenticated() async {
        server(200, "not json")
        let authenticated = await LicenseService.shared.activate(token: "token-1")
        XCTAssertFalse(authenticated)
    }

    /// No answer at all — offline — is no sign-in.
    func testNoAnswerIsNotAuthenticated() async {
        LicenseService.shared.sendActivation = { _ in throw URLError(.notConnectedToInternet) }
        let authenticated = await LicenseService.shared.activate(token: "token-1")
        XCTAssertFalse(authenticated)
        XCTAssertEqual(LicenseService.shared.lastError, "Connection error. Check your internet.")
    }
}
