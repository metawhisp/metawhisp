import Security
import XCTest
@testable import MetaWhisp

/// ITER-075 step 0, US-0.4 — an item that exists but can't be read is a
/// keychain problem, never a sign-out.
final class LicenseRestoreTests: XCTestCase {

    private func reads(_ changes: [String: KeychainRead] = [:]) -> [String: KeychainRead] {
        var all: [String: KeychainRead] = [
            "com.metawhisp.sessionToken": .value("t"),
            "com.metawhisp.proEmail": .value("e"),
            "com.metawhisp.licenseKey": .value("k"),
            "com.metawhisp.proPlan": .value("p"),
            "com.metawhisp.lastVerifiedAt": .value("100"),
        ]
        for (account, read) in changes { all[account] = read }
        return all
    }

    func testReadableItemsAreRestored() {
        XCTAssertEqual(LicenseRestore.decide(reads()),
                       .restored(token: "t", email: "e", licenseKey: "k", plan: "p", stamp: "100"))
    }

    func testMissingItemsMeanSignedOutNotAProblem() {
        let none = Dictionary(uniqueKeysWithValues: LicenseRestore.accounts.map { ($0, KeychainRead.notFound) })
        XCTAssertEqual(LicenseRestore.decide(none),
                       .restored(token: nil, email: nil, licenseKey: nil, plan: nil, stamp: nil))
    }

    /// Whichever item can't be read, the answer is "unreadable" — never a
    /// state that looks signed out and can end in a sign-out that deletes it.
    func testAnUnreadableItemIsAProblemNeverASignOut() {
        for account in LicenseRestore.accounts {
            XCTAssertEqual(LicenseRestore.decide(reads([account: .failed(errSecAuthFailed)])),
                           .unreadable(account: account, status: errSecAuthFailed), account)
        }
    }

    func testTheStampAccountIsTheOneLicenseServiceWrites() {
        XCTAssertEqual(LicenseRestore.accounts.last, "com.metawhisp.lastVerifiedAt")
    }

    func testTheMessagesNameTheStatusAndTheWayOut() {
        let read = LicenseRestore.problemMessage(status: -25293)
        XCTAssertTrue(read.contains("-25293"))
        XCTAssertTrue(read.contains("Nothing was deleted"))
        XCTAssertTrue(read.contains("Keychain Access"))
        let write = LicenseRestore.writeProblemMessage(status: -25293)
        XCTAssertTrue(write.contains("-25293"))
        XCTAssertTrue(write.contains("this session only"))
        XCTAssertTrue(write.contains("Always Allow"))
        XCTAssertTrue(read.contains("Always Allow"), "the read message is shown after a denied access prompt")
    }

    // MARK: - What a launch does

    func testAnUnreadableLaunchVerifiesNothingAndSaysWhy() {
        let launch = LicenseRestore.launchPlan(.unreadable(account: "com.metawhisp.licenseKey", status: -25293),
                                               unsavedStatus: nil)
        XCTAssertNil(launch.verifyToken, "a verify could end in a sign-out that deletes what could not be read")
        XCTAssertEqual(launch.message, LicenseRestore.problemMessage(status: -25293))
        XCTAssertFalse(launch.clearUnsavedMarker)
    }

    func testAReadableLaunchVerifiesItsTokenAndEndsTheUnsavedNote() {
        let launch = LicenseRestore.launchPlan(LicenseRestore.decide(reads()), unsavedStatus: -25293)
        XCTAssertEqual(launch.verifyToken, "t")
        XCTAssertNil(launch.message)
        XCTAssertTrue(launch.clearUnsavedMarker)
    }

    /// The 2026-09-25 sequence: a sign-in the keychain refused, then a launch
    /// with nothing saved. The owner is told why they are signed out.
    func testASignOutCausedByAnUnsavedSignInIsExplained() {
        let none = Dictionary(uniqueKeysWithValues: LicenseRestore.accounts.map { ($0, KeychainRead.notFound) })
        let launch = LicenseRestore.launchPlan(LicenseRestore.decide(none), unsavedStatus: -25293)
        XCTAssertNil(launch.verifyToken)
        XCTAssertEqual(launch.message, LicenseRestore.unsavedAtLaunchMessage(status: -25293))
        XCTAssertFalse(launch.clearUnsavedMarker, "the note stays until a sign-in saves or the owner signs out")
    }

    func testNothingSavedAndNothingNotedIsAQuietSignedOutLaunch() {
        let none = Dictionary(uniqueKeysWithValues: LicenseRestore.accounts.map { ($0, KeychainRead.notFound) })
        XCTAssertEqual(LicenseRestore.launchPlan(LicenseRestore.decide(none), unsavedStatus: nil),
                       .init(verifyToken: nil, message: nil, clearUnsavedMarker: false))
    }

    /// A restored token is verified first: "you are signed out" would be wrong
    /// while the server may still confirm the session.
    func testTheUnsavedNoteWaitsWhileARestoredTokenIsVerified() {
        let tokenOnly = reads(["com.metawhisp.licenseKey": .notFound, "com.metawhisp.proPlan": .notFound])
        let launch = LicenseRestore.launchPlan(LicenseRestore.decide(tokenOnly), unsavedStatus: -25293)
        XCTAssertEqual(launch.verifyToken, "t")
        XCTAssertNil(launch.message)
        XCTAssertFalse(launch.clearUnsavedMarker)
    }

    // MARK: - What a sign-in says about its saves

    func testTheSignInMessageFollowsWhatWasGranted() {
        XCTAssertNil(LicenseRestore.activationMessage(isPro: true, failedWrite: nil))
        XCTAssertEqual(LicenseRestore.activationMessage(isPro: true, failedWrite: -25293),
                       LicenseRestore.writeProblemMessage(status: -25293))
        XCTAssertEqual(LicenseRestore.activationMessage(isPro: false, failedWrite: -25293),
                       LicenseRestore.signInNotSavedMessage(status: -25293))
        XCTAssertFalse(LicenseRestore.signInNotSavedMessage(status: -25293).contains("Pro is on"),
                       "a sign-in without Pro must not claim Pro")
    }
}
