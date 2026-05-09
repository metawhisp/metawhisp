import XCTest
@testable import MetaWhisp

/// Pure-function tests for `AliasCanonicalPicker.pickByConversationCount(...)`.
///
/// History (ITER-032.2, 2026-05-08): user observed `HallucinatedName` (LLM
/// hallucination) sitting as the canonical for a cluster that also contained
/// `Example Project`/`ExampleProject`/`ExampleProject.ai`. The previous heuristic picked
/// canonical by `aliases.count` (the number of variant strings accumulated)
/// — which made garbage variants WIN if they happened to collect more dupes
/// over time. Real signal: how many CONVERSATIONS reference each variant.
/// "Example Project" with 24 conversations should win over "HallucinatedName" with 0.
final class AliasCanonicalPickerTests: XCTestCase {

    /// The variant with the most conversation references wins.
    func test_pickByConversationCount_highestWins() {
        let result = AliasCanonicalPicker.pickByConversationCount(
            variants: ["HallucinatedName", "ExampleProject.ai", "Example Project", "ExampleProject"],
            counts: [
                "HallucinatedName": 0,
                "ExampleProject.ai": 2,
                "Example Project": 24,
                "ExampleProject": 3
            ]
        )
        XCTAssertEqual(result, "Example Project")
    }

    /// Tie on count → alphabetical for determinism (test is stable across runs).
    func test_pickByConversationCount_tieBreakAlphabetical() {
        let result = AliasCanonicalPicker.pickByConversationCount(
            variants: ["Beta", "Alpha", "Charlie"],
            counts: ["Beta": 5, "Alpha": 5, "Charlie": 5]
        )
        XCTAssertEqual(result, "Alpha")
    }

    /// Variants missing from counts dict are treated as 0.
    func test_pickByConversationCount_missingTreatedAsZero() {
        let result = AliasCanonicalPicker.pickByConversationCount(
            variants: ["HallucinatedName", "Example Project"],
            counts: ["Example Project": 12]   // HallucinatedName absent → counted as 0
        )
        XCTAssertEqual(result, "Example Project")
    }

    /// Empty variants → returns empty string. Caller must guard.
    func test_pickByConversationCount_emptyVariants() {
        let result = AliasCanonicalPicker.pickByConversationCount(
            variants: [],
            counts: [:]
        )
        XCTAssertEqual(result, "")
    }

    /// Single variant trivially wins.
    func test_pickByConversationCount_singleVariant() {
        let result = AliasCanonicalPicker.pickByConversationCount(
            variants: ["Solo"],
            counts: ["Solo": 0]
        )
        XCTAssertEqual(result, "Solo")
    }

    /// Case-insensitive count lookup — "Example Project" and "atomic bot" should
    /// be treated as the same key when summing counts. (LLM may emit either
    /// case; conversation count sources may store either case.)
    func test_pickByConversationCount_caseInsensitiveCounts() {
        let result = AliasCanonicalPicker.pickByConversationCount(
            variants: ["Example Project", "HallucinatedName"],
            counts: ["atomic bot": 24, "atomicbata": 0]   // lowercase keys
        )
        XCTAssertEqual(result, "Example Project")
    }
}
