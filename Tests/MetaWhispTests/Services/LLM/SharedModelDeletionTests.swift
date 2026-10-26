import XCTest
@testable import MetaWhisp

/// ITER-075 step 0 (0.4) — installs from before 1.4 keep the speech and
/// local-LLM models in a folder the owner's app shares with every other copy
/// (~/Documents/huggingface). Only the owner's app may delete them there.
///
/// The model here cannot exist, so no answer of the gate can touch the owner's
/// disk: a broken gate fails the test, never deletes a real model.
@MainActor
final class SharedModelDeletionTests: XCTestCase {

    private let missing = ModelSpec(
        id: "test-missing", hfRepoID: "metawhisp-tests/model-that-does-not-exist",
        displayName: "Missing", vendor: "Test", paramsDisplay: "0", quantization: "none",
        downloadSizeBytes: 0, ramPeakGB: 0, speedM1TokPerSec: 0, quality: 0, languages: [],
        minRecommendedRAMGB: 0, hardMinRAMGB: 0, minChipGen: 0, bestForTagline: "", isFoundationModels: false)

    private let home = URL(fileURLWithPath: "/tmp/mw-shared-model-deletion", isDirectory: true)

    func testOnlyTheOwnersAppMayDeleteALocalModel() {
        let shared = ModelFolder(kind: .documents, home: home, supportDirectory: home)
        XCTAssertThrowsError(try MLXModelManager.shared.remove(missing, identity: AppIdentity(bundleIdentifier: "com.metawhisp.app.dev"),
                                                               folder: shared)) { error in
            XCTAssertEqual(error as? SharedModelError, .notTheOwnersApp)
        }
        XCTAssertNoThrow(try MLXModelManager.shared.remove(missing, identity: AppIdentity(bundleIdentifier: "com.metawhisp.app"),
                                                           folder: shared),
                         "the owner's app may delete; a model that is not there is simply not there")
    }

    /// F1 — a copy's own Application Support folder is shared with no one.
    func testACopyMayDeleteFromItsOwnFolder() {
        let own = ModelFolder(kind: .applicationSupport, home: home, supportDirectory: home)
        XCTAssertNoThrow(try MLXModelManager.shared.remove(missing, identity: AppIdentity(bundleIdentifier: "com.metawhisp.app.dev"),
                                                           folder: own))
    }
}
