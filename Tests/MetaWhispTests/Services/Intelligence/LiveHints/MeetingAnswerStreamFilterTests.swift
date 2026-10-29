import XCTest
@testable import MetaWhisp

final class MeetingAnswerStreamFilterTests: XCTestCase {
    func testEverySplitOfThinkTagsHidesReasoningAndRetainsTheRawReply() {
        let raw = "<think>Private analysis.</think>\n**The answer is ready.**\n- Check the date"
        for split in 0...raw.count {
            var filter = MeetingAnswerStreamFilter(kind: .answer)
            let first = filter.append(String(raw.prefix(split)))
            let last = filter.append(String(raw.dropFirst(split)))
            filter.finish()
            XCTAssertFalse(first.contains("Private"), "split \(split)")
            XCTAssertFalse(first.contains("<thi"), "split \(split)")
            XCTAssertFalse(first.contains("</th"), "split \(split)")
            XCTAssertEqual(last, "**The answer is ready.**\n- Check the date", "split \(split)")
            XCTAssertEqual(filter.raw, raw)
            XCTAssertEqual(filter.blocks, [.headline("**The answer is ready.**"), .bullet("Check the date")])
        }
    }

    func testUnclosedThinkNeverDrawsItsContentsAtAnyChunkSize() {
        let raw = "<think>**Private analysis must remain hidden.**\n- Hidden detail"
        for size in 1...5 {
            var filter = MeetingAnswerStreamFilter(kind: .answer)
            let states = chunks(raw, size: size).map { filter.append($0) }
            filter.finish()
            XCTAssertEqual(states, Array(repeating: "", count: states.count), "chunk size \(size)")
            XCTAssertEqual(filter.visibleText, "")
            XCTAssertEqual(filter.raw, raw)
        }
    }

    func testTextBeforeUnclosedThinkStaysVisibleButEveryFollowingStateHidesReasoning() {
        var filter = MeetingAnswerStreamFilter(kind: .answer)
        XCTAssertEqual(filter.append("**The answer is ready.**\n"), "**The answer is ready.**")
        let states = chunks("<think>Private analysis and **private answer**", size: 1).map { filter.append($0) }
        filter.finish()
        XCTAssertTrue(states.allSatisfy { $0 == "**The answer is ready.**" })
        XCTAssertEqual(filter.visibleText, "**The answer is ready.**")
    }

    func testEverySplitOfOpeningAndClosingFenceHidesFenceLines() {
        let raw = " \n```markdown\n**The answer is ready.**\n- Check the date\n```"
        for split in 0...raw.count {
            var filter = MeetingAnswerStreamFilter(kind: .answer)
            let states = [filter.append(String(raw.prefix(split))), filter.append(String(raw.dropFirst(split)))]
            filter.finish()
            XCTAssertTrue(states.allSatisfy { !$0.contains("`") && !$0.contains("markdown") }, "split \(split)")
            XCTAssertEqual(filter.visibleText, "**The answer is ready.**\n- Check the date")
        }
    }

    func testEverySkipCompositionAndBoundaryLatchesSuppressionForAnswersAndActions() {
        let replies = ["[no-answer]", "[no-answer] extra", "**[no-answer]**", " _`[no-answer] extra",
                       " \n```text\n[no-answer] extra\n```", "<think>private</think>\n[no-answer] extra"]
        for kind in [MeetingAnswerKind.answer, .action] {
            for raw in replies {
                for split in 0...raw.count {
                    var filter = MeetingAnswerStreamFilter(kind: kind, action: kind == .action ? .questions : nil)
                    let states = [filter.append(String(raw.prefix(split))), filter.append(String(raw.dropFirst(split)))]
                    filter.finish()
                    XCTAssertEqual(states, ["", ""], "\(raw), split \(split)")
                    XCTAssertTrue(filter.isSuppressed, "\(raw), split \(split)")
                    XCTAssertEqual(filter.append("\n**A later answer cannot undo suppression.**"), "")
                    XCTAssertTrue(filter.blocks.isEmpty)
                }
            }
        }
    }

    func testIncompleteSkipPrefixesRemainHeld() {
        for raw in ["", " ", "**", "[", "[no", "[no-answer"] {
            var filter = MeetingAnswerStreamFilter(kind: .answer)
            XCTAssertEqual(filter.append(raw), "")
            XCTAssertFalse(filter.isSuppressed)
            XCTAssertFalse(filter.isRejected)
        }
    }

    func testAnActionEndingOnAnIncompleteSkipPrefixCannotPublishIt() {
        for raw in ["", " ", "**", "[", "[no", "[no-answer"] {
            var filter = MeetingAnswerStreamFilter(kind: .action, action: .questions)
            XCTAssertEqual(filter.append(raw), "")
            filter.finish()
            XCTAssertTrue(filter.isRejected)
            XCTAssertFalse(filter.isSuppressed)
        }
    }

    func testJSONObjectsAndArraysAreRejectedAtEveryBoundaryForEveryKind() {
        for kind in [MeetingAnswerKind.answer, .action] {
            for raw in ["{\"a\":1}", "[1,2]", " \n```json\n[\"a\"]\n```", "<think>private</think>\n{\"a\":1}"] {
                for split in 0...raw.count {
                    var filter = MeetingAnswerStreamFilter(kind: kind, action: kind == .action ? .screen : nil)
                    let states = [filter.append(String(raw.prefix(split))), filter.append(String(raw.dropFirst(split)))]
                    filter.finish()
                    XCTAssertEqual(states, ["", ""])
                    XCTAssertTrue(filter.isRejected, "\(raw), split \(split)")
                }
            }
        }
    }

    func testEveryIntermediateReasoningDrawStateIsRecordedForChunkSizesOneThroughFive() {
        let fixture = "We need a deep insight. They discuss the roadmap and nothing else."
        for size in 1...5 {
            var filter = MeetingAnswerStreamFilter(kind: .answer)
            let states = chunks(fixture, size: size).map { filter.append($0) }
            XCTAssertEqual(states.count, (fixture.count + size - 1) / size)
            XCTAssertEqual(states, Array(repeating: "", count: states.count), "Recorded states for chunk size \(size): \(states)")
            filter.finish()
            XCTAssertEqual(filter.visibleText, "")
        }
    }

    func testAnswerWaitsForAClosedBoldRunOfAtLeastThreeCharacters() {
        var filter = MeetingAnswerStreamFilter(kind: .answer)
        let states = [filter.append("**a"), filter.append("b*"), filter.append("*"), filter.append(" plain")]
        XCTAssertEqual(states, ["", "", "", ""])

        var valid = MeetingAnswerStreamFilter(kind: .answer)
        XCTAssertEqual(valid.append("**abc*"), "")
        XCTAssertEqual(valid.append("*"), "**abc**")
        XCTAssertEqual(valid.blocks, [.headline("**abc**")])
    }

    func testFirstLineOver220CharactersStopsDrawingAndRejects() {
        var filter = MeetingAnswerStreamFilter(kind: .answer)
        XCTAssertEqual(filter.append(String(repeating: "x", count: 220)), "")
        XCTAssertFalse(filter.isRejected)
        XCTAssertEqual(filter.append("x"), "")
        XCTAssertTrue(filter.isRejected)
        XCTAssertEqual(filter.append("**Valid later text**"), "")

        var valid = MeetingAnswerStreamFilter(kind: .answer)
        let headline = "**" + String(repeating: "x", count: 216) + "**"
        XCTAssertEqual(valid.append(headline), headline)
        XCTAssertEqual(valid.append("x"), headline)
        XCTAssertTrue(valid.isRejected)
    }

    func testLengthLimitFreezesTheLastSafeDraftAndKeepsRawForFinalRejection() {
        var filter = MeetingAnswerStreamFilter(kind: .answer)
        let atLimit = "**Ready**\n" + String(repeating: "x", count: 890)
        XCTAssertEqual(atLimit.count, 900)
        XCTAssertEqual(filter.append(atLimit), atLimit)
        XCTAssertEqual(filter.append("x"), atLimit)
        XCTAssertTrue(filter.isRejected)
        XCTAssertEqual(filter.raw.count, 901)
        XCTAssertEqual(MeetingAnswerContract.evaluate(filter.raw), .reject)
    }

    func testPartialBlocksKeepTheHeadlineCompleteBulletsAndTheLineBeingWritten() {
        var filter = MeetingAnswerStreamFilter(kind: .answer)
        filter.append("**Ready answer**\n- First detail\n• Second detail\n- Par")
        XCTAssertEqual(filter.blocks, [.headline("**Ready answer**"), .bullet("First detail"),
                                       .bullet("Second detail"), .bullet("Par")])
        filter.append("tial detail")
        XCTAssertEqual(filter.blocks.last, .bullet("Partial detail"))
    }

    func testCompletedNonListProseDoesNotBecomeAnUnfinishedLastBlock() {
        var filter = MeetingAnswerStreamFilter(kind: .answer)
        filter.append("**Ready answer**\n- First detail\nThe line still being written")
        XCTAssertEqual(filter.blocks.last, .paragraph("The line still being written"))
        filter.append("\n")
        XCTAssertEqual(filter.blocks, [.headline("**Ready answer**"), .bullet("First detail")])
        XCTAssertEqual(filter.visibleText, "**Ready answer**\n- First detail")
    }

    func testEveryActionDrawStateIsRecordedAndEmptyBeforeAndAfterFinish() {
        let reply = "Overview\n- First detail\nA complete paragraph."
        for action in [MeetingAnswerAction.questions, .recap, .more, .screen] {
            for size in 1...5 {
                var filter = MeetingAnswerStreamFilter(kind: .action, action: action)
                let states = chunks(reply, size: size).map { filter.append($0) }
                XCTAssertEqual(states, Array(repeating: "", count: states.count), "\(action), chunk size \(size)")
                filter.finish()
                XCTAssertEqual(filter.visibleText, "")
                XCTAssertTrue(filter.blocks.isEmpty)
                XCTAssertFalse(filter.isRejected)
                XCTAssertNotNil(MeetingActionContract.evaluate(filter.raw, action: action))
            }
        }
    }

    func testEachActionHasItsOwnRejectionLimitWithoutDrawing() {
        for (action, limit) in [(MeetingAnswerAction.questions, 1_200), (.more, 1_200), (.recap, 2_000), (.screen, 1_500)] {
            var filter = MeetingAnswerStreamFilter(kind: .action, action: action)
            XCTAssertEqual(filter.append(String(repeating: "x", count: limit)), "")
            XCTAssertFalse(filter.isRejected)
            XCTAssertEqual(filter.append("x"), "")
            XCTAssertTrue(filter.isRejected)
        }
    }

    private func chunks(_ text: String, size: Int) -> [String] {
        stride(from: 0, to: text.count, by: size).map { String(text.dropFirst($0).prefix(size)) }
    }
}
