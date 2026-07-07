import XCTest
@testable import MetaWhisp

/// ITER-051 F1.2 — pins the sentence-boundary chunker feeding
/// `completeChunked`: no characters lost, every chunk within the limit,
/// short input passes through as a single chunk.
final class ChunkSplitterTests: XCTestCase {

    func testShortInputSingleChunk() {
        let out = LocalLLMService.splitBySentences("Привет. Как дела?", limit: 100)
        XCTAssertEqual(out, ["Привет. Как дела?"])
    }

    func testNoCharactersLostAndLimitsRespected() {
        let sentence = "Это предложение номер раз, в нём есть смысл и длина. "
        let text = String(repeating: sentence, count: 40)  // ~2160 chars
        let chunks = LocalLLMService.splitBySentences(text, limit: 500)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text, "chunker must not lose or reorder characters")
        for (i, c) in chunks.enumerated() {
            XCTAssertLessThanOrEqual(c.count, 500, "chunk \(i) exceeds limit")
        }
    }

    func testDegenerateSingleSentenceHardSplit() {
        let text = String(repeating: "а", count: 1200)  // no boundaries at all
        let chunks = LocalLLMService.splitBySentences(text, limit: 500)
        XCTAssertEqual(chunks.joined(), text)
        for c in chunks { XCTAssertLessThanOrEqual(c.count, 500) }
    }

    func testMixedBoundaries() {
        let text = "Первое!\nВторое? Третье. " + String(repeating: "х", count: 600) + ". Конец."
        let chunks = LocalLLMService.splitBySentences(text, limit: 300)
        XCTAssertEqual(chunks.joined(), text)
        for c in chunks { XCTAssertLessThanOrEqual(c.count, 300) }
    }
}
