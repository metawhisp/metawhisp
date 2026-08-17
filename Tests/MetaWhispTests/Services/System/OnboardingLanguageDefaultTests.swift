import XCTest
@testable import MetaWhisp

/// 2026-08-17 — dropping the language question from onboarding.
///
/// `transcriptionLanguage` shipped hard-coded to `"ru"` and the first-run flow
/// never mentioned it, so an English speaker's first dictation came back in
/// Russian with nothing on screen explaining why. Whisper detects the language
/// itself, so the fix is not to ask — it is to default to `auto`.
///
/// The catch: `@AppStorage` only writes a key once something sets it. Someone
/// who has used the app for months and never opened that setting has NO stored
/// value, so flipping the code default would silently change THEIR behaviour
/// too. This decides who gets pinned to the old value before the default moves.
final class OnboardingLanguageDefaultTests: XCTestCase {

    private typealias D = OnboardingLanguageDefault

    // MARK: - Existing users must not notice

    func test_longTimeUserWhoNeverTouchedTheSetting_isPinnedToRussian() {
        // No stored value, but they are past onboarding: they have been living
        // with "ru" as the effective value. Write it down before the default moves.
        XCTAssertEqual(
            D.valueToPersist(storedLanguage: nil, hasCompletedOnboarding: true),
            "ru"
        )
    }

    func test_userWithAnExplicitChoice_isNeverTouched() {
        for stored in ["ru", "en", "auto", "de", ""] {
            XCTAssertNil(
                D.valueToPersist(storedLanguage: stored, hasCompletedOnboarding: true),
                "an explicit \(stored.isEmpty ? "<empty>" : stored) must be left alone"
            )
            XCTAssertNil(
                D.valueToPersist(storedLanguage: stored, hasCompletedOnboarding: false)
            )
        }
    }

    // MARK: - Fresh installs get the new behaviour

    func test_freshInstall_isLeftToTheNewDefault() {
        // Nothing stored and onboarding not done — the new `auto` default applies
        // on its own, so there is nothing to write.
        XCTAssertNil(
            D.valueToPersist(storedLanguage: nil, hasCompletedOnboarding: false)
        )
    }

    func test_theNewDefaultIsAuto() {
        XCTAssertEqual(D.freshInstallDefault, "auto")
    }

    // MARK: - Idempotence

    func test_runningTheMigrationTwice_changesNothingTheSecondTime() {
        let first = D.valueToPersist(storedLanguage: nil, hasCompletedOnboarding: true)
        XCTAssertEqual(first, "ru")
        // Second launch: the value it wrote is now the stored value.
        XCTAssertNil(D.valueToPersist(storedLanguage: first, hasCompletedOnboarding: true))
    }
}
