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

    // MARK: - TR-7 (ITER-046 C2): Tiny + non-English warning

    func testTinyWarning_firesForNonEnglishAndAuto() {
        XCTAssertNotNil(OnboardingReadiness.tinyModelWarning(modelId: "tiny", transcriptionLanguage: "ru"))
        XCTAssertNotNil(OnboardingReadiness.tinyModelWarning(modelId: "tiny", transcriptionLanguage: "auto"))
        XCTAssertNotNil(OnboardingReadiness.tinyModelWarning(modelId: "tiny", transcriptionLanguage: ""))
    }

    func testTinyWarning_silentForEnglish() {
        XCTAssertNil(OnboardingReadiness.tinyModelWarning(modelId: "tiny", transcriptionLanguage: "en"))
        XCTAssertNil(OnboardingReadiness.tinyModelWarning(modelId: "tiny", transcriptionLanguage: "EN-US"))
    }

    func testTinyWarning_silentForProperModels() {
        XCTAssertNil(OnboardingReadiness.tinyModelWarning(modelId: "large-v3-turbo", transcriptionLanguage: "ru"))
        XCTAssertNil(OnboardingReadiness.tinyModelWarning(modelId: "base", transcriptionLanguage: "ru"))
    }
}
