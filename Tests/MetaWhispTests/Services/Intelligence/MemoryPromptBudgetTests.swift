import XCTest
@testable import MetaWhisp

/// The memory extractor tells the model what it already knows, so it does not
/// propose the same fact twice, and then gives it the transcript to read.
///
/// On the cloud paths the "already known" block was written UNCAPPED — every
/// stored memory, up to a thousand of them — and only the finished prompt was
/// cut, from the head, at 20 000 characters. A user with a full second brain
/// therefore sent a prompt that was all dedup list and no transcript: nothing
/// to extract from, every time, silently (audit, 2026-09-06, P1).
///
/// The budget is a decision, so it is one function and these are its rules.
final class MemoryPromptBudgetTests: XCTestCase {

    func testTheTranscriptAlwaysGetsTheLargerShare() {
        let split = MemoryPromptBudget.split(total: 20_000)
        XCTAssertGreaterThan(split.transcript, split.existing,
                             "the text being read matters more than the list of what is already known")
        XCTAssertLessThanOrEqual(split.existing + split.transcript, 20_000)
    }

    /// The number this bug is about: whatever the store holds, the transcript
    /// keeps its share.
    func testAThousandMemoriesCannotCrowdOutTheTranscript() {
        let known = (0..<1_000).map { "- memory number \($0) about the user's preferences" }
        let kept = MemoryPromptBudget.fit(existing: known, into: MemoryPromptBudget.split(total: 20_000).existing)
        XCTAssertLessThan(kept.joined(separator: "\n").count, MemoryPromptBudget.split(total: 20_000).existing + 80,
                          "the known-facts block stays inside its share")
        XCTAssertGreaterThan(kept.count, 10, "…while still saying enough for the model to dedup against")
        XCTAssertTrue(kept.last?.contains("omitted") == true, "and it admits what it left out")
    }

    func testASmallStoreIsPassedWhole() {
        let known = ["- drinks tea", "- prefers mornings"]
        XCTAssertEqual(MemoryPromptBudget.fit(existing: known, into: 10_000), known,
                       "nothing to trim, nothing to admit")
    }

    /// A budget so small that nothing fits must still not produce a lie about
    /// how much was omitted.
    func testAnImpossibleBudgetOmitsEverythingHonestly() {
        let known = ["- a fact that is far too long for the space available"]
        let kept = MemoryPromptBudget.fit(existing: known, into: 10)
        XCTAssertEqual(kept, ["(1 known fact omitted for space)"])
    }
}
