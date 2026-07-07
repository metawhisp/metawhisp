import XCTest
@testable import MetaWhisp

/// ITER-051 F1.7 — pins the parse contract both extractors feed the durable
/// queue with: `nil` = the LLM response was UNPARSEABLE (truncated / garbage
/// JSON — routine for local models) and the conversation must stay queued
/// (`.retryLater`); a non-nil empty array = valid JSON that genuinely found
/// nothing (`.completed`). The old code returned `[]` for both, so one bad
/// local generation permanently dequeued the conversation with zero output.
@MainActor
final class ExtractorParseOutcomeTests: XCTestCase {

    // MARK: MemoryExtractor

    func testMemoryGarbageResponseIsNilNotEmpty() {
        let ex = MemoryExtractor()
        XCTAssertNil(ex.parseResponse("{\"memories\": [{\"content\": \"tru",
                                      sourceApp: "t", windowTitle: nil, conversationId: nil),
                     "truncated JSON must be a parse FAILURE, not 'nothing to extract'")
        XCTAssertNil(ex.parseResponse("Sure! Here are the memories you asked for.",
                                      sourceApp: "t", windowTitle: nil, conversationId: nil))
    }

    func testMemoryValidEmptyIsEmptyNotNil() {
        let ex = MemoryExtractor()
        let out = ex.parseResponse("{\"memories\": []}",
                                   sourceApp: "t", windowTitle: nil, conversationId: nil)
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.count, 0)
    }

    // MARK: TaskExtractor

    func testTaskGarbageResponseIsNilNotEmpty() {
        let ex = TaskExtractor()
        XCTAssertNil(ex.parseResponse("[not json at all",
                                      sourceTranscriptId: nil, sourceApp: "t", conversationId: nil))
    }

    func testTaskValidEmptyIsEmptyNotNil() {
        let ex = TaskExtractor()
        let out = ex.parseResponse("{\"tasks\": []}",
                                   sourceTranscriptId: nil, sourceApp: "t", conversationId: nil)
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.count, 0)
    }
}
