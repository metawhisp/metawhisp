import XCTest
@testable import MetaWhisp

/// ITER-044 044.1 — unit tests for the pure Foundation Models support layer.
/// These lock the backend-routing decision and the user-facing availability
/// copy WITHOUT touching the FM framework (which needs macOS 26 + Apple
/// Intelligence, i.e. a runtime smoke test, not a unit test).
final class FoundationModelsSupportTests: XCTestCase {

    // MARK: - backend(for:) routing

    /// The Apple Foundation Models card routes to the FM backend.
    func test_backend_foundationModelsSpec_routesToFM() {
        let fm = ModelRegistry.model(byID: "apple-foundation-models")!
        XCTAssertEqual(FoundationModelsSupport.backend(for: fm), .foundationModels)
    }

    /// A downloadable MLX card (Phi-4 Mini) routes to the MLX backend.
    func test_backend_mlxSpec_routesToMLX() {
        let phi = ModelRegistry.model(byID: "phi-4-mini")!
        XCTAssertEqual(FoundationModelsSupport.backend(for: phi), .mlx)
    }

    // MARK: - message(for:) — actionable, distinct copy per reason

    /// Apple-Intelligence-off is the most common real case: the message must
    /// tell the user exactly where to switch it on.
    func test_message_appleIntelligenceOff_tellsUserToEnableIt() {
        let m = FoundationModelsSupport.message(for: .appleIntelligenceNotEnabled)
        XCTAssertTrue(m.contains("Apple Intelligence"))
        XCTAssertTrue(m.contains("System Settings"),
                      "message should point at the exact place to enable it")
    }

    /// Ineligible hardware: don't tell the user to toggle a setting they don't
    /// have — steer them to a downloadable model.
    func test_message_deviceNotEligible_steersToDownloadableModel() {
        let m = FoundationModelsSupport.message(for: .deviceNotEligible)
        XCTAssertTrue(m.lowercased().contains("downloadable"))
    }

    /// Model still downloading: reassure it's transient.
    func test_message_modelNotReady_saysTryAgainLater() {
        let m = FoundationModelsSupport.message(for: .modelNotReady)
        let lower = m.lowercased()
        XCTAssertTrue(lower.contains("downloading") || lower.contains("try again"))
    }

    /// Every reason yields a non-empty, distinct message — no accidental
    /// copy-paste collision that would confuse the Settings card.
    func test_message_allReasons_nonEmptyAndDistinct() {
        let reasons: [FMUnavailableReason] = [.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady]
        let msgs = reasons.map { FoundationModelsSupport.message(for: $0) }
        XCTAssertFalse(msgs.contains { $0.isEmpty })
        XCTAssertEqual(Set(msgs).count, reasons.count, "each reason must map to a distinct message")
    }
}
