import XCTest
@testable import MetaWhisp

/// Pure-function tests for `ExistingProjectCatalog.promptHint(from:...)`.
///
/// History (ITER-032.1, 2026-05-08): user observed `HallucinatedName` (LLM
/// hallucination) absorb `Example Project` cluster because the LLM had no
/// awareness of existing canonical names when classifying a fresh
/// conversation. The fix gives the LLM a list of established projects
/// (with conv counts) at prompt-build time so it can reuse exact names
/// instead of inventing variants.
final class ExistingProjectCatalogTests: XCTestCase {

    /// No qualifying projects → empty hint (caller skips appending it).
    func test_emptyInput_returnsEmpty() {
        XCTAssertEqual(ExistingProjectCatalog.promptHint(from: []), "")
    }

    /// Singletons (convCount < 2) are excluded — they're noise candidates,
    /// not established projects.
    func test_singletonsExcluded() {
        let hint = ExistingProjectCatalog.promptHint(from: [
            ("HallucinatedName", 1),
            ("OneOff Idea", 1)
        ])
        XCTAssertEqual(hint, "")
    }

    /// Single qualifying project formats correctly.
    func test_singleProject_formatsCorrectly() {
        let hint = ExistingProjectCatalog.promptHint(from: [("Example Project", 24)])
        XCTAssertTrue(hint.contains("EXISTING PROJECTS"))
        XCTAssertTrue(hint.contains("- Example Project (24 conversations)"))
    }

    /// Multiple projects sorted by convCount descending.
    /// Uses unique names that don't appear in the prompt's preamble warning
    /// (which mentions 'Example Project' / 'HallucinatedName' as the example) so
    /// `range(of:)` finds the entry in the bullet list, not the warning.
    func test_sortsByConvCountDescending() {
        let hint = ExistingProjectCatalog.promptHint(from: [
            ("ZetaProject", 8),
            ("YankeeProject", 24),
            ("AlphaProject", 52)
        ])
        // AlphaProject (52) should appear before YankeeProject (24) before ZetaProject (8)
        let alphaIdx = hint.range(of: "AlphaProject")!.lowerBound
        let yankeeIdx = hint.range(of: "YankeeProject")!.lowerBound
        let zetaIdx = hint.range(of: "ZetaProject")!.lowerBound
        XCTAssertLessThan(alphaIdx, yankeeIdx)
        XCTAssertLessThan(yankeeIdx, zetaIdx)
    }

    /// Hint trims to maxRows entries to keep prompt token cost bounded.
    func test_capsAtMaxRows() {
        let many = (1...50).map { ("Project\($0)", 100 - $0) }
        let hint = ExistingProjectCatalog.promptHint(from: many, maxRows: 10)
        // Project1..Project10 should appear (they have highest convCount), Project11+ should not.
        XCTAssertTrue(hint.contains("Project1 ("))
        XCTAssertTrue(hint.contains("Project10 ("))
        XCTAssertFalse(hint.contains("Project11 ("))
    }
}
