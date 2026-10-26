import XCTest
@testable import MetaWhisp

/// 2026-10-20 — the advice gate was given the same block as the model,
/// "PREVIOUS ADVICE (do NOT repeat)" included, and read that list as live
/// commitments: in the owner's log 77 of 108 advice fires scored exactly
/// 0.95, two reasons cite the "prior advice" outright, and of the 63 advices
/// saved that day one subject recurs in 15. The gate now judges the context
/// without that list; the model still reads it; and a repeat is dropped after
/// the model, where the advice path had no check at all.
@MainActor
final class AdviceGateInputTests: XCTestCase {

    private let earlierAdvice = "Fill the KPI table before 5 PM"

    private func screen(_ app: String, _ title: String, _ ocr: String) -> ScreenContextService.ScreenContextSnapshot {
        .init(timestamp: Date(timeIntervalSince1970: 1_760_970_000), appName: app, windowTitle: title,
              ocrText: ocr, bundleID: "test.\(app)", windowID: nil, windowFrame: nil)
    }

    private func input() -> AdviceService.AdviceInput {
        AdviceService.assembleInput(
            memories: ["Sam runs the weekly sync"],
            previousAdvice: [earlierAdvice],
            contexts: [screen("Mail", "Inbox - Alex", "Lunch on Friday?")],
            transcripts: ["the deck goes out tomorrow"],
            extraContext: "Recent transcription (mic): the deck is ready")
    }

    /// The gate is shown the context of the moment — memories, screen, voice,
    /// the trigger — and not the list of what was already said.
    func testTheGateIsNotShownThePreviousAdvice() {
        let gate = input().forGate
        XCTAssertFalse(gate.contains("PREVIOUS ADVICE"), "no do-not-repeat list")
        XCTAssertFalse(gate.contains(earlierAdvice), "no do-not-repeat list")
        XCTAssertTrue(gate.contains("Sam runs the weekly sync"))
        XCTAssertTrue(gate.contains("Mail — Inbox - Alex"))
        XCTAssertTrue(gate.contains("Lunch on Friday?"))
        XCTAssertTrue(gate.contains("the deck goes out tomorrow"))
        XCTAssertTrue(gate.contains("Recent transcription (mic): the deck is ready"))
    }

    /// The model still reads the list, where it always sat — between the
    /// memories and the screen; the gate's input is exactly that minus it.
    func testTheModelStillReadsThePreviousAdviceAndTheGateGetsTheRest() {
        let both = input()
        let block = "PREVIOUS ADVICE (do NOT repeat):\n- \"\(earlierAdvice)\"\n\n"
        XCTAssertTrue(both.forModel.contains("weekly sync\n\n" + block + "CURRENT SCREEN"))
        XCTAssertEqual(both.forModel.replacingOccurrences(of: block, with: ""), both.forGate)
    }

    /// After the model: the same advice again is dropped.
    func testTheSameAdviceAgainDoesNotRepeat() {
        XCTAssertTrue(AdviceService.repeatsRecentAdvice(
            "Fill the KPI table before 5 PM!", recent: ["Sam's standup is at 3", earlierAdvice]))
    }

    /// The pair to the test above: a new subject fires anyway.
    func testAdviceFiresAnywayForANewSubject() {
        XCTAssertFalse(AdviceService.repeatsRecentAdvice(
            "Replying to the group thread, not the DM - check the recipient", recent: [earlierAdvice]))
    }

    /// The wiring, read off the source: the gate gets `forGate`, every model
    /// route gets `forModel`, and the repeat check runs before the advice is
    /// saved or shown.
    func testGenerateAdviceGatesOnTheGateInputAndDropsRepeatsBeforeSaving() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Services/Intelligence/AdviceService.swift").standardized
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("context: input.forGate,"), "the gate reads the input without the list")
        XCTAssertFalse(source.contains("context: contextBlock"))
        XCTAssertEqual(source.components(separatedBy: "user: input.forModel").count - 1, 3,
                       "local, Pro proxy and direct API all read the full input")
        let check = try XCTUnwrap(source.range(of: "Self.repeatsRecentAdvice(advice.content,"))
        let save = try XCTUnwrap(source.range(of: "ctx.insert(advice)"))
        let notify = try XCTUnwrap(source.range(of: "routes.show(advice)"))
        XCTAssertLessThan(check.lowerBound, save.lowerBound, "a repeat is dropped before it is saved")
        XCTAssertLessThan(check.lowerBound, notify.lowerBound, "and before it is shown")
    }
}
