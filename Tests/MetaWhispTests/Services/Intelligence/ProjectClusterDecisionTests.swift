import XCTest
@testable import MetaWhisp

/// Pure-function tests for `ProjectClusterDecision.canMerge(_:_:)`.
///
/// **ITER-032.1 (2026-05-08): conservative auto-merge — canonical-equality
/// only.** The earlier Lev-based typo tolerance produced false positives in
/// production (`HallucinatedName` LLM hallucination absorbing the real
/// `ExampleProject.ai` cluster). Typo merges now go through user-approval UI in
/// `ProjectDetailView`, not auto-decision.
final class ProjectClusterDecisionTests: XCTestCase {

    // MARK: - SHOULD merge (canonical-equality cases)

    /// Cyrillic vs Apple's deterministic Latin romanization (`Голосок` → `Golosok`).
    /// Free-form LLM romanizations (`VoiceSnack`) are too lexically far —
    /// they merge through Stage 2 embedding-cosine in `mergeAliases()`.
    func test_cyrillicLatinTranslit_merges() {
        XCTAssertTrue(ProjectClusterDecision.canMerge("Голосок", "Golosok"))
    }

    /// Case-only difference.
    func test_caseOnly_merges() {
        XCTAssertTrue(ProjectClusterDecision.canMerge("ChatApp", "CHATAPP"))
    }

    /// Emoji prefix vs clean — canonical strips emoji.
    func test_emojiPrefix_merges() {
        XCTAssertTrue(ProjectClusterDecision.canMerge("🚀 ChatApp", "ChatApp"))
    }

    /// Punctuation only difference — both canonicalize to `chatapp`.
    /// (Note: `AcmeProject.ai` vs `AcmeProject ai` does NOT merge here — period is
    /// dropped without inserting a space, so canonicals are `acmeprojectai`
    /// vs `acmeproject ai` which differ. That case is a typo merge candidate
    /// and goes through user-approval UI, not auto-decision.)
    func test_punctuationOnly_merges() {
        XCTAssertTrue(ProjectClusterDecision.canMerge("ChatApp.", "ChatApp,"))
    }

    // MARK: - SHOULD NOT merge

    /// REGRESSION GUARD (ITER-032.1): single-char typo no longer auto-
    /// merges. The prior `Lev ≤ 2` rule caused `HallucinatedName` (one-shot
    /// LLM hallucination) to swallow `ExampleProject`/`ExampleProject.ai`/`Example Project`
    /// in production. Typos now require user-approval via UI rename/split.
    func test_singleTypo_isNotAutoMerged() {
        XCTAssertFalse(ProjectClusterDecision.canMerge("Island Expand", "Island Expend"))
    }

    /// REGRESSION GUARD: HallucinatedName vs Example Project — different
    /// canonicals, don't merge. Pinned against a real production incident
    /// where an LLM-hallucinated alias swallowed an existing canonical
    /// cluster (see WAL ITER-032.1 «HallucinatedName regression»).
    func test_hallucinatedAliasNotMergedWithExampleProject() {
        XCTAssertFalse(ProjectClusterDecision.canMerge("HallucinatedName", "Example Project"))
        XCTAssertFalse(ProjectClusterDecision.canMerge("HallucinatedName", "ExampleProject.ai"))
    }

    /// Distinct projects with same word stem.
    func test_distinctProjects_dontMerge() {
        XCTAssertFalse(ProjectClusterDecision.canMerge("Acme Wallet", "Acme Mail"))
    }

    /// Short acronyms — different canonicals.
    func test_shortAcronyms_dontMerge() {
        XCTAssertFalse(ProjectClusterDecision.canMerge("API", "AWS"))
    }

    /// Version / quarter / year markers — different canonicals via digits.
    func test_versionMarkers_dontMerge() {
        XCTAssertFalse(ProjectClusterDecision.canMerge("Q3 Planning", "Q4 Planning"))
        XCTAssertFalse(ProjectClusterDecision.canMerge("Acme Wallet 2.0", "Acme Wallet 3.0"))
        XCTAssertFalse(ProjectClusterDecision.canMerge("ChatApp 2026", "ChatApp"))
    }

    /// Empty strings — never merge.
    func test_emptyInputs_dontMerge() {
        XCTAssertFalse(ProjectClusterDecision.canMerge("", "ChatApp"))
        XCTAssertFalse(ProjectClusterDecision.canMerge("ChatApp", ""))
        XCTAssertFalse(ProjectClusterDecision.canMerge("", ""))
    }
}
