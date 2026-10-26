import XCTest
@testable import MetaWhisp

/// Onboarding's setup notes. Readiness itself moved to `ModelPreparer` (C5),
/// pinned in `ModelPreparerTests`.
final class OnboardingReadinessTests: XCTestCase {

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
