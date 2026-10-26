import CryptoKit
import XCTest
@testable import MetaWhisp

/// ITER-076 1.3: the questions the agent asks Jev are the texts the owner
/// approved on 2026-09-27, verbatim, built the way each source builds them.
/// The three control labels, verbatim ports added after review, were
/// approved by the owner the same day.
/// A changed text fails here: it needs the owner's approval, and then a new
/// pin. The pins of built questions were computed from the upstream files at
/// their pinned commits, in each source's own shape
/// (specs/iterations/evidence/ITER-076/1.3-question-sources.md).
final class JevQuestionsTests: XCTestCase {

    private func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Sorted keys: the pins do not depend on the order Foundation writes.
    private func sha(json value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    func testEveryTextIsTheApprovedOne() {
        let approved = "changed without the owner's approval"
        XCTAssertEqual(sha(JevQuestions.nextActionRules), "e697b2dce5298e8dda5e0b75c66e3cbc2c46ad8d3490f202b336c7d26381e54d", approved)
        XCTAssertEqual(sha(JevQuestions.targetRules), "74661518f88d1bfaf219e689755b29935d08e7c1ffe04f3e2bbc35594fa02ca7", approved)
        XCTAssertEqual(sha([JevQuestions.goalDoneInstructions, JevQuestions.goalDoneTrue, JevQuestions.goalDoneFalse]
            .joined(separator: "\n")), "ae3eee60dd1358ac3cfe73e57547ff973dc3f7d9a1ab2c795eb40c47d3ab0373", approved)
        XCTAssertEqual(sha([JevQuestions.stuckInstructions, JevQuestions.stuckTrue, JevQuestions.stuckFalse]
            .joined(separator: "\n")), "bc73a41801d33a6d3eea1f7f79aaba3340e1c846146ecabf77a12ba3b8005635", approved)
        XCTAssertEqual(sha([JevQuestions.destructiveTemplate, JevQuestions.destructiveTrue, JevQuestions.destructiveFalse]
            .joined(separator: "\n")), "6649aac4da6f83b932b22cad004715ea3ea8d0cbf204db302a2f2c625d51219a", approved)
        XCTAssertEqual(sha([JevQuestions.grantTemplate, JevQuestions.grantTrue, JevQuestions.grantFalse]
            .joined(separator: "\n")), "68c99ea42b36a22484285d1e2e89982c6b3a449b6d36cf1f019cf89fc5f384bd", approved)
        XCTAssertEqual(sha(JevQuestions.operationLabels.map { "\($0.name)=\($0.label)" }.joined(separator: "\n")),
                       "999676d68ba6c06262b32d3e8c2e394f738e13c31ea973bb7d0d3ba9b1a463c5", approved)
        XCTAssertEqual(sha(JevQuestions.controlLabels.map { "\($0.name)=\($0.label)" }.joined(separator: "\n")),
                       "0a7ee5468070738523fb748a6381c058efdecdc096443843e2cf0c7cde4da9de", approved)
    }

    // MARK: - Built as the sources build them

    /// A for a fixed page equals jev-ultrafast's `choose` for that page: the
    /// goal and rules in the instructions, the operation named in each target
    /// question, and each target described by its element, value and role.
    func testTheStepIsBuiltAsJevUltrafastBuildsIt() throws {
        let questions = try JevQuestions.step(goal: "Open the pricing page", targets: [
            ("CLICK", [.init(index: "1", label: "Features", role: "link"),
                       .init(index: "2", label: "Pricing", role: "link"),
                       .init(index: "4", label: "Annual billing", role: "switch", checked: "false",
                             selected: "false", expanded: "false")]),
            ("TYPE_TEXT", [.init(index: "3", label: "Search", role: "searchbox")]),
        ], controls: ["SCROLL_DOWN", "WAIT", "BACK"])
        XCTAssertEqual(try sha(json: questions), "4b2237b6c3c9461858b56ac32e08fb8f152bc977a104ef3185e186105da439eb")
    }

    /// B equals jkudish's `stepQuestions` goal_done and stuck.
    func testTheWatchersAreBuiltAsJkudishBuildsThem() throws {
        XCTAssertEqual(try sha(json: JevQuestions.watchers()),
                       "0f83016602916bfa209fb2048e34f7e428bb9ab1cde2cdd4cb07ae3526aa02a6")
    }

    /// C equals Footwork's `judge_destructive`, questions and state, and E
    /// is asked beside it in C's form.
    func testTheRiskSetIsBuiltAsFootworkBuildsIt() throws {
        let risk = try JevQuestions.risk(task: "Buy one ticket", url: "https://shop.test/cart", title: "Cart",
                                         controls: [("Pay now", "Checkout, total 10")])
        XCTAssertEqual(try sha(json: risk.questions), "c66423d9dc19053817168c43432ed40443c0bd07584087ef0fcb8f27ec5a8a55")
        XCTAssertEqual(try sha(json: risk.state), "cd23409decdc33a3913a216c550317840166b3f34e8b05e55b6846859892b562")
    }

    // MARK: - The step

    /// Every operation the page offers is in the question, and DONE and
    /// BLOCKED always are, in jev-ultrafast's order.
    func testTheStepOffersWhatThePageOffersThenDoneAndBlocked() throws {
        let questions = try JevQuestions.step(goal: "Find the docs", targets: [
            ("SELECT", [.init(index: "4", label: "Language", role: "combobox")]),
            ("CLICK", [.init(index: "1", label: "Docs", role: "link")]),
        ], controls: ["WAIT", "BACK"])
        XCTAssertEqual(Set(questions.keys), ["operation", "select_target", "click_target"])
        guard case .choice(let offered) = questions["operation"]?.kind else { return XCTFail("a choice") }
        XCTAssertEqual(offered.map(\.name), ["SELECT", "CLICK", "WAIT", "BACK", "DONE", "BLOCKED"])
    }

    /// An operation or control this port has no label for is refused, never
    /// silently left out of the question.
    func testTheStepRefusesWhatItCannotDescribe() {
        let click = [JevQuestions.StepTarget(index: "1", label: "Docs", role: "link")]
        XCTAssertThrowsError(try JevQuestions.step(goal: "Go", targets: [("OPEN", click)], controls: [])) {
            XCTAssertEqual($0 as? JevQuestions.BuildError, .unknownOperation("OPEN"))
        }
        XCTAssertThrowsError(try JevQuestions.step(goal: "Go", targets: [("DONE", click)], controls: [])) {
            XCTAssertEqual($0 as? JevQuestions.BuildError, .unknownOperation("DONE"))
        }
        XCTAssertThrowsError(try JevQuestions.step(goal: "Go", targets: [], controls: ["SCROLL_UP"])) {
            XCTAssertEqual($0 as? JevQuestions.BuildError, .unknownOperation("SCROLL_UP"))
        }
        XCTAssertThrowsError(try JevQuestions.step(goal: "Go", targets: [("CLICK", click), ("CLICK", click)],
                                                   controls: [])) {
            XCTAssertEqual($0 as? JevQuestions.BuildError, .repeatedOperation("CLICK"))
        }
        XCTAssertThrowsError(try JevQuestions.step(goal: "Go", targets: [], controls: ["WAIT", "WAIT"])) {
            XCTAssertEqual($0 as? JevQuestions.BuildError, .repeatedOperation("WAIT"))
        }
        XCTAssertThrowsError(try JevQuestions.step(goal: " \n", targets: [("CLICK", click)], controls: [])) {
            XCTAssertEqual($0 as? JevQuestions.BuildError, .blankGoal)
        }
        XCTAssertThrowsError(try JevQuestions.step(goal: "Go", targets: [("CLICK", [])], controls: []),
                             "an operation with no target")
    }

    // MARK: - C and E

    /// Each risk question names its own control, the state holds that
    /// control at that index, and 16 controls fill the Pro server's 32.
    func testEachRiskQuestionNamesItsOwnControlInTheState() throws {
        let controls = (0..<16).map { (label: "Control \($0)", context: "Row \($0)") }
        let risk = try JevQuestions.risk(task: "Book a table", url: "https://a.test/", title: "A", controls: controls)
        XCTAssertEqual(risk.questions.count, 32)
        XCTAssertNoThrow(try JevQuestionSet(risk.questions))
        XCTAssertEqual(risk.state.targets.map(\.label), controls.map(\.label))
        for index in [0, 3, 15] {
            for kind in ["destructive", "grant"] {
                guard case .string(let text) = risk.questions["\(kind)_\(index)"]?.instructions else {
                    return XCTFail("\(kind)_\(index) is asked in words")
                }
                XCTAssertTrue(text.contains("`targets[\(index)].label`"), "\(kind)_\(index)")
                XCTAssertFalse(text.contains("{i}"), "no placeholder is left")
            }
        }
        XCTAssertThrowsError(try JevQuestions.risk(task: "T", url: "https://a.test/", title: "A", controls: [])) {
            XCTAssertEqual($0 as? JevQuestions.BuildError, .controlCount(0))
        }
        let seventeen = (0..<17).map { (label: "C\($0)", context: "") }
        XCTAssertThrowsError(try JevQuestions.risk(task: "T", url: "https://a.test/", title: "A", controls: seventeen)) {
            XCTAssertEqual($0 as? JevQuestions.BuildError, .controlCount(17))
        }
    }

    /// A control's context is cut to 300 characters, counted as Python
    /// counts them.
    func testAControlsContextIsCutTo300Characters() throws {
        let long = String(repeating: "\u{e9}", count: 250) + String(repeating: "x", count: 100)
        let risk = try JevQuestions.risk(task: "T", url: "https://a.test/", title: "A", controls: [("Pay", long)])
        XCTAssertEqual(risk.state.targets[0].context.unicodeScalars.count, 300)
        XCTAssertTrue(risk.state.targets[0].context.hasSuffix(String(repeating: "x", count: 50)))
    }

    // MARK: - Every text

    /// A linter over every text: ASCII only, and only the state paths the
    /// requests fill in (`targets[i].label`, `task`).
    func testEveryTextIsASCIIAndReadsOnlyTheStatesPaths() throws {
        let paths = try NSRegularExpression(pattern: "`([^`]+)`")
        for text in JevQuestions.allTexts {
            XCTAssertTrue(text.unicodeScalars.allSatisfy { $0.isASCII }, "not ASCII: \(text.prefix(40))")
            for match in paths.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let path = String(text[Range(match.range(at: 1), in: text)!])
                XCTAssertTrue(["targets[{i}].label", "task"].contains(path), "unknown state path: \(path)")
            }
        }
        XCTAssertEqual(JevQuestions.allTexts.count, 14 + JevQuestions.operationLabels.count
                       + JevQuestions.controlLabels.count)
    }
}
