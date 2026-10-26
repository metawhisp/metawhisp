import XCTest
@testable import MetaWhisp

/// ITER-076 1.2 — the Jev wire types, ported from d-date/swift-jev (MIT).
/// Questions encode the way Jev reads them, a bad question never leaves the
/// app, and an answer that breaks the contract never decodes into something
/// the agent could act on.
final class JevWireTests: XCTestCase {

    private enum Step: String, JevChoiceOptions { case click, type }
    private enum Other: String, JevChoiceOptions { case scroll }

    private static let answered = """
        {"model":"typesafe/jev-1.13-20260917","id":"gen-1",
         "usage":{"input_tokens":512,"output_tokens":64},
         "answers":{
           "done":{"type":"noul","noul":0.91},
           "next":{"type":"choice","choice":"click","probabilities":{"click":0.8,"type":0.2},"confidence":0.8},
           "risk":{"type":"score","score":0.3,"legend":{"0":"none","1":"some","2":"high"},
                   "probabilities":{"0":0.75,"1":0.2,"2":0.05},"confidence":0.75}
         }}
        """

    private func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ json: String) throws -> JevResponse {
        try JSONDecoder().decode(JevResponse.self, from: Data(json.utf8))
    }

    private func noul(_ instructions: String) throws -> JevQuestion {
        try JevQuestion(instructions: instructions, kind: .noul(whenTrue: nil, whenFalse: nil))
    }

    // MARK: - Questions

    func testANoulQuestionEncodesItsTypeInstructionsAndCriteria() throws {
        let question = try JevQuestion(instructions: "Is the goal reached?",
                                       kind: .noul(whenTrue: "The page shows the goal.", whenFalse: nil))
        let encoded = try object(question)
        XCTAssertEqual(encoded["type"] as? String, "noul")
        XCTAssertEqual(encoded["instructions"] as? String, "Is the goal reached?")
        XCTAssertEqual(encoded["criteria"] as? [String: String], ["true": "The page shows the goal."])
    }

    func testANoulQuestionWithoutCriteriaSendsNone() throws {
        XCTAssertNil(try object(noul("Is it done?"))["criteria"])
    }

    func testAChoiceQuestionSendsEveryOptionAndNullForAnUndescribedOne() throws {
        let question = try JevQuestion(instructions: "Which step is next?",
                                       kind: .choice([JevChoiceOption("click", "Press a control"), JevChoiceOption("type")]))
        let criteria = try XCTUnwrap(try object(question)["criteria"] as? [String: Any])
        XCTAssertEqual(criteria["click"] as? String, "Press a control")
        XCTAssertTrue(criteria["type"] is NSNull)
        XCTAssertEqual(Step.jevChoiceOptions.map(\.name), ["click", "type"])
    }

    /// ITER-076 1.3: instructions and descriptions may be structured, as
    /// jev-ultrafast sends its step, and blank ones are still refused.
    func testInstructionsAndDescriptionsMayBeStructured() throws {
        let question = try JevQuestion(
            instructions: .object(["goal": .string("Open pricing"), "rules": .array([.string("One"), .string("Two")])]),
            kind: .choice([JevChoiceOption("1", described: .object(["element": .string("[1] Pricing")])),
                           JevChoiceOption("2")]))
        let encoded = try object(question)
        let instructions = try XCTUnwrap(encoded["instructions"] as? [String: Any])
        XCTAssertEqual(instructions["goal"] as? String, "Open pricing")
        XCTAssertEqual(instructions["rules"] as? [String], ["One", "Two"])
        let criteria = try XCTUnwrap(encoded["criteria"] as? [String: Any])
        XCTAssertEqual(criteria["1"] as? [String: String], ["element": "[1] Pricing"])
        XCTAssertTrue(criteria["2"] is NSNull)
        for blank: JevJSON in [.string(" \n"), .array([]), .object([:])] {
            XCTAssertThrowsError(try JevQuestion(instructions: blank, kind: .noul(whenTrue: nil, whenFalse: nil)))
        }
    }

    func testAScoreQuestionSendsItsLevelsInOrder() throws {
        let question = try JevQuestion(instructions: "How risky is this step?", kind: .score(levels: ["none", "some", "high"]))
        XCTAssertEqual(try object(question)["criteria"] as? [String], ["none", "some", "high"])
    }

    func testABadQuestionIsRefusedBeforeItIsSent() {
        XCTAssertThrowsError(try noul("  "))
        XCTAssertThrowsError(try JevQuestion(instructions: "Which?", kind: .choice([])))
        XCTAssertThrowsError(try JevQuestion(instructions: "Which?", kind: .choice([JevChoiceOption("a"), JevChoiceOption("a")])))
        XCTAssertThrowsError(try JevQuestion(instructions: "How?", kind: .score(levels: ["one"])))
        XCTAssertThrowsError(try JevQuestion(instructions: "How?", kind: .score(levels: (1...11).map(String.init))))
        XCTAssertNoThrow(try JevQuestion(instructions: "How?", kind: .score(levels: ["low", "high"])))
        XCTAssertNoThrow(try JevQuestion(instructions: "How?", kind: .score(levels: (1...10).map(String.init))))
    }

    /// One web form asks two questions per field, and the Pro server takes 32.
    func testAQuestionSetHoldsOneTo32NamedQuestions() throws {
        let question = try noul("Is it done?")
        XCTAssertThrowsError(try JevQuestionSet([:]))
        XCTAssertThrowsError(try JevQuestionSet(["": question])) {
            XCTAssertEqual($0 as? JevWireError, .invalidQuestion(name: "", reason: .emptyName))
        }
        XCTAssertThrowsError(try JevQuestionSet(Dictionary(uniqueKeysWithValues: (0..<33).map { ("q\($0)", question) }))) {
            XCTAssertEqual($0 as? JevWireError, .tooManyQuestions(33))
        }
        XCTAssertEqual(try JevQuestionSet(Dictionary(uniqueKeysWithValues: (0..<32).map { ("q\($0)", question) })).count, 32)
    }

    // MARK: - Answers

    func testAnAnswerDecodesIntoTypedValues() throws {
        let response = try decode(Self.answered)
        XCTAssertEqual(response.model, "typesafe/jev-1.13-20260917")
        XCTAssertEqual(response.usage, JevUsage(inputTokens: 512, outputTokens: 64))
        XCTAssertEqual(try response.answers.noul(named: "done").value, 0.91)
        XCTAssertEqual(try response.answers.choice(named: "next", as: Step.self), .click)
        let risk = try response.answers.score(named: "risk")
        XCTAssertEqual(risk.rounded, 0)
        XCTAssertEqual(risk.legend[2], "high")
        XCTAssertEqual(response.answers["next"]?.confidence, 0.8)
    }

    func testAnAnswerWithoutUsageStillDecodes() throws {
        let response = try decode(#"{"model":"m","answers":{"done":{"type":"noul","noul":0.2}}}"#)
        XCTAssertNil(response.usage)
        XCTAssertEqual(try response.answers.noul(named: "done").decisiveness, 0.8, accuracy: 1e-9)
    }

    func testAMistypedMissingOrUnknownChoiceIsAnError() throws {
        let answers = try decode(Self.answered).answers
        XCTAssertThrowsError(try answers.noul(named: "next")) {
            XCTAssertEqual($0 as? JevWireError, .answerTypeMismatch(question: "next", expected: "noul", actual: "choice"))
        }
        XCTAssertThrowsError(try answers.score(named: "absent")) {
            XCTAssertEqual($0 as? JevWireError, .missingAnswer(question: "absent"))
        }
        XCTAssertThrowsError(try answers.choice(named: "next", as: Other.self)) {
            XCTAssertEqual($0 as? JevWireError, .unrecognizedChoice(question: "next", value: "click", expected: ["scroll"]))
        }
    }

    /// Fail closed: a probability or a confidence outside 0...1, a score with
    /// one level or off its scale, or an answer type nobody asked for never
    /// becomes an answer.
    func testAnAnswerOutsideItsBoundsNeverDecodes() {
        for broken in [
            #"{"model":"m","answers":{"done":{"type":"noul","noul":1.5}}}"#,
            #"{"model":"m","answers":{"done":{"type":"noul","noul":-0.1}}}"#,
            #"{"model":"m","answers":{"next":{"type":"choice","choice":"click","probabilities":{"click":1},"confidence":2.0}}}"#,
            #"{"model":"m","answers":{"risk":{"type":"score","score":0,"probabilities":{"0":1},"confidence":0.9}}}"#,
            #"{"model":"m","answers":{"risk":{"type":"score","score":5,"probabilities":{"0":0.5,"1":0.5},"confidence":0.9}}}"#,
            #"{"model":"m","answers":{"risk":{"type":"score","score":1,"probabilities":{"0":0.5,"00":0.5},"confidence":0.9}}}"#,
            #"{"model":"m","answers":{"risk":{"type":"score","score":1,"probabilities":{"0":0.5,"1":0.5},"confidence":1.5}}}"#,
            #"{"model":"m","answers":{"x":{"type":"essay","text":"a"}}}"#,
            #"{"model":"m"}"#,
        ] {
            XCTAssertThrowsError(try decode(broken), broken)
        }
    }

    func testAnAnswerIsCheckedAgainstTheQuestionsAsked() throws {
        let answers = try decode(Self.answered).answers
        let asked = try JevQuestionSet([
            "done": noul("Is the goal reached?"),
            "next": JevQuestion(instructions: "Which step is next?", kind: .choice(Step.jevChoiceOptions)),
        ])
        XCTAssertNil(answers.problem(answering: asked))
        XCTAssertEqual(answers.problem(answering: try JevQuestionSet(["gone": noul("Is it gone?")])), "gone",
                       "an unanswered question")
        XCTAssertEqual(answers.problem(answering: try JevQuestionSet([
            "done": JevQuestion(instructions: "Which?", kind: .choice([JevChoiceOption("a")])),
        ])), "done", "an answer of another type")
        XCTAssertEqual(answers.problem(answering: try JevQuestionSet([
            "next": JevQuestion(instructions: "Which?", kind: .choice(Other.jevChoiceOptions)),
        ])), "next", "a choice outside the options asked")
    }

    /// A score answered on other levels than the ones asked never fits: on two
    /// levels a risk could never read "high", and a level past the rubric has
    /// no name.
    func testAScoreIsCheckedAgainstTheLevelsAsked() throws {
        let asked = try JevQuestionSet(["risk": JevQuestion(instructions: "How risky is this step?",
                                                            kind: .score(levels: ["none", "some", "high"]))])
        let fits = #"{"model":"m","answers":{"risk":{"type":"score","score":0.3,"probabilities":{"0":0.75,"1":0.2,"2":0.05},"confidence":0.75}}}"#
        XCTAssertNil(try decode(fits).answers.problem(answering: asked))
        for misfit in [
            #"{"model":"m","answers":{"risk":{"type":"score","score":0.4,"probabilities":{"0":0.6,"1":0.4},"confidence":0.9}}}"#,
            #"{"model":"m","answers":{"risk":{"type":"score","score":4,"probabilities":{"0":0,"1":0,"2":0,"3":0,"4":1},"confidence":0.9}}}"#,
            #"{"model":"m","answers":{"risk":{"type":"score","score":1,"probabilities":{"0":0.5,"7":0.5},"confidence":0.9}}}"#,
        ] {
            XCTAssertEqual(try decode(misfit).answers.problem(answering: asked), "risk", misfit)
        }
    }

    func testOnlyTheAnswersToTheQuestionsAskedAreKept() throws {
        let asked = try JevQuestionSet(["done": noul("Is the goal reached?")])
        let kept = try decode(Self.answered).answers.restricted(to: asked)
        XCTAssertEqual(kept.names, ["done"])
        XCTAssertEqual(try kept.noul(named: "done").value, 0.91)
    }
}
