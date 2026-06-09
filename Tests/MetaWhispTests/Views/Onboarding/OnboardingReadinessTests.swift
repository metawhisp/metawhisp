import XCTest
@testable import MetaWhisp

/// Pins the rule that onboarding only counts a path as ready when a real engine
/// can transcribe — so completion can be gated and the free user never finishes
/// with a dead engine.
final class OnboardingReadinessTests: XCTestCase {

    // MARK: - Local (on-device model)

    func testLocal_readyOnlyWhenModelDownloaded() {
        XCTAssertTrue(OnboardingReadiness.isReady(path: .local, localModelReady: true, cloudKeyValidated: false, isPro: false))
        XCTAssertFalse(OnboardingReadiness.isReady(path: .local, localModelReady: false, cloudKeyValidated: false, isPro: false))
    }

    func testLocal_proOrKeyDoNotSubstituteForModel() {
        // Local path needs the on-device model regardless of Pro/key.
        XCTAssertFalse(OnboardingReadiness.isReady(path: .local, localModelReady: false, cloudKeyValidated: true, isPro: true))
    }

    // MARK: - Cloud (BYOK)

    func testCloud_readyWithValidatedKey() {
        XCTAssertTrue(OnboardingReadiness.isReady(path: .cloud, localModelReady: false, cloudKeyValidated: true, isPro: false))
    }

    func testCloud_readyWhenProCoversCloud() {
        XCTAssertTrue(OnboardingReadiness.isReady(path: .cloud, localModelReady: false, cloudKeyValidated: false, isPro: true))
    }

    func testCloud_notReadyWithoutKeyOrPro() {
        XCTAssertFalse(OnboardingReadiness.isReady(path: .cloud, localModelReady: false, cloudKeyValidated: false, isPro: false))
    }

    // MARK: - Pro

    func testPro_readyOnlyWhenActive() {
        XCTAssertTrue(OnboardingReadiness.isReady(path: .pro, localModelReady: false, cloudKeyValidated: false, isPro: true))
        XCTAssertFalse(OnboardingReadiness.isReady(path: .pro, localModelReady: false, cloudKeyValidated: false, isPro: false))
    }
}
