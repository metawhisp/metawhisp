import XCTest
@testable import MetaWhisp

/// Measured before this existed: 36 comments shipped, 34 citing only the screen
/// in front of the user, 2 citing nothing, and none citing a task or a fact —
/// across roughly ninety-five model turns in which `search_tasks` and
/// `search_memories` were never called once. The work here is to stop asking.
final class InsightContextPackTests: XCTestCase {

    private func entries(_ prefix: String, _ count: Int, chars: Int = 20) -> [InsightContextPack.Entry] {
        (0..<count).map {
            .init(id: "\(prefix)\($0)", text: String(repeating: "x", count: chars))
        }
    }

    /// A prompt is a budget. Two thousand seven hundred stored facts would push
    /// out the screen the comment is supposed to be about.
    func testTheBudgetIsSpentOnTasksFirst() {
        var pack = InsightContextPack()
        pack.tasks = entries("t", 30, chars: 200)
        pack.stated = entries("s", 40, chars: 200)
        pack.inferred = entries("i", 40, chars: 200)

        let bounded = pack.bounded()
        let total = bounded.allEntries.reduce(0) { $0 + $1.text.count + $1.id.count + 4 }
        XCTAssertLessThanOrEqual(total, InsightContextPack.maxTotalChars)
        XCTAssertFalse(bounded.tasks.isEmpty, "a promise with a deadline outranks a trait")
        XCTAssertGreaterThan(bounded.tasks.count, bounded.inferred.count)
    }

    /// Row caps hold independently of the character budget, so a thousand
    /// one-word facts cannot get in on cheapness alone.
    func testRowCapsHoldEvenWhenEverythingIsShort() {
        var pack = InsightContextPack()
        pack.tasks = entries("t", 500, chars: 1)
        pack.stated = entries("s", 500, chars: 1)
        let bounded = pack.bounded()
        XCTAssertLessThanOrEqual(bounded.tasks.count, InsightContextPack.maxTasks)
        XCTAssertLessThanOrEqual(bounded.stated.count, InsightContextPack.maxMemories)
    }

    /// One pasted paragraph filed as a "fact" must not eat the budget alone.
    func testASingleHugeRecordIsClippedNotDropped() {
        let long = String(repeating: "long ", count: 400)
        let clipped = InsightContextPack.clip(long)
        XCTAssertLessThanOrEqual(clipped.count, InsightContextPack.maxEntryChars + 1)
        XCTAssertTrue(clipped.hasSuffix("…"))
    }

    /// Newlines would break the one-record-per-line shape the model reads.
    func testARecordIsOneLine() {
        XCTAssertEqual(InsightContextPack.clip("first\nsecond\n\nthird"), "first second  third")
    }

    /// Every injected record carries the id the evidence check knows it by.
    /// Without this the grounding check sees a claim about a real open task,
    /// finds nothing in the allowlist that matches, and kills the comment as
    /// ungrounded — B would then be strictly worse than doing nothing.
    func testEveryInjectedRecordIsCitable() {
        var pack = InsightContextPack()
        pack.tasks = [.init(id: "t0", text: "Send the deck")]
        pack.inferred = [.init(id: "m0", text: "Works on ProjectAlpha")]
        let block = pack.promptBlock()
        for entry in pack.allEntries {
            XCTAssertTrue(block.contains("[\(entry.id)]"),
                          "\(entry.id) is in the prompt but cannot be cited")
        }
        XCTAssertEqual(pack.allEntries.count, 2)
    }

    /// Nothing to say means nothing added — an empty heading in the prompt is
    /// an invitation to invent rows to put under it.
    func testAnEmptyPackAddsNothingToThePrompt() {
        XCTAssertTrue(InsightContextPack().promptBlock().isEmpty)
        XCTAssertTrue(InsightContextPack().isEmpty)
    }

    /// What the user stated and what the app inferred stay in separate
    /// sections. Flattening them lets a guess the app made be quoted back with
    /// the authority of something the user said.
    func testStatedAndInferredAreNotMerged() {
        var pack = InsightContextPack()
        pack.stated = [.init(id: "s0", text: "I do not use Jira")]
        pack.inferred = [.init(id: "i0", text: "Uses Jira daily")]
        let block = pack.promptBlock()
        let statedLine = block.range(of: "THE USER SAID THIS ABOUT THEMSELVES:")
        let inferredLine = block.range(of: "CONFIRMED FACTS ABOUT THE USER:")
        XCTAssertNotNil(statedLine)
        XCTAssertNotNil(inferredLine)
        XCTAssertTrue(statedLine!.lowerBound < inferredLine!.lowerBound,
                      "what the user said comes first")
    }
}
