import Foundation

// ITER-076 1.2 — the Jev wire types: the questions the agent asks Jev and the
// answers it reads back. Ported from d-date/swift-jev (MIT, commit d5d2280;
// the notice is in THIRD_PARTY_NOTICES.md). Changes from upstream: names carry
// a `Jev` prefix, the macro and builder layer is left out, a question set holds
// at most 32 questions (the Pro server's cap), usage is optional (the server may
// leave it out), `JevAnswers.problem(answering:)` checks an answer against
// the questions asked, a score's levels included, and instructions and
// descriptions may be structured JSON, as jev-ultrafast sends them (1.3). As upstream, an answer outside its bounds never decodes,
// so a broken answer can never read as "act without asking".

/// One option of a choice question.
struct JevChoiceOption: Sendable, Hashable {
    var name: String
    /// `nil` sends a null description, which Jev reads as "the name alone
    /// specifies the choice".
    var description: JevJSON?

    init(_ name: String, _ description: String? = nil) {
        self.name = name
        self.description = description.map(JevJSON.string)
    }

    /// An option described by structured data, as jev-ultrafast describes a
    /// target: its element, current value and role.
    init(_ name: String, described description: JevJSON) {
        self.name = name
        self.description = description
    }
}

/// A JSON value: Jev reads a question's instructions and a choice's
/// descriptions as text or as structured data. jev-ultrafast sends its goal,
/// operation and rules as an object; OpenRouter took one, live, on
/// 2026-09-27 (ITER-076 1.3).
enum JevJSON: Sendable, Hashable, Encodable {
    case string(String)
    case array([JevJSON])
    case object([String: JevJSON])

    /// Nothing for Jev to read: blank text, or an empty list or object.
    var isBlank: Bool {
        switch self {
        case .string(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let items): items.isEmpty
        case .object(let fields): fields.isEmpty
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .string(let text):
            var container = encoder.singleValueContainer()
            try container.encode(text)
        case .array(let items):
            var container = encoder.unkeyedContainer()
            for item in items { try container.encode(item) }
        case .object(let fields):
            var container = encoder.container(keyedBy: JevDynamicKey.self)
            for (key, value) in fields { try container.encode(value, forKey: JevDynamicKey(key)) }
        }
    }
}

enum JevInvalidQuestionReason: Sendable, Hashable {
    /// Jev accepts 2 through 10 rubric levels.
    case scoreLevelCountOutOfRange(Int)
    case emptyChoiceOptions
    case duplicateChoiceOption(String)
    case emptyInstructions
    case emptyName
}

enum JevWireError: Error, Sendable, Equatable {
    case invalidQuestion(name: String, reason: JevInvalidQuestionReason)
    case emptyQuestionSet
    case tooManyQuestions(Int)
    case missingAnswer(question: String)
    case answerTypeMismatch(question: String, expected: String, actual: String)
    case unrecognizedChoice(question: String, value: String, expected: [String])
    case unknownAnswerType(question: String, type: String)
}

/// A question to evaluate the state against.
struct JevQuestion: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case noul(whenTrue: String?, whenFalse: String?)
        /// Options stay in an array, in the order they were written. On the
        /// wire they are an object's keys, which the engine sends sorted.
        case choice([JevChoiceOption])
        /// Levels are index-addressed, low to high. Jev accepts 2 through 10.
        case score(levels: [String])
    }

    let instructions: JevJSON
    let kind: Kind

    init(instructions: String, kind: Kind) throws {
        try self.init(instructions: .string(instructions), kind: kind)
    }

    /// Validates eagerly, so a bad rubric fails before the request is sent.
    init(instructions: JevJSON, kind: Kind) throws {
        guard !instructions.isBlank else {
            throw JevWireError.invalidQuestion(name: "", reason: .emptyInstructions)
        }
        switch kind {
        case .noul:
            break
        case .choice(let options):
            guard !options.isEmpty else {
                throw JevWireError.invalidQuestion(name: "", reason: .emptyChoiceOptions)
            }
            var seen = Set<String>()
            for option in options where !seen.insert(option.name).inserted {
                throw JevWireError.invalidQuestion(name: "", reason: .duplicateChoiceOption(option.name))
            }
        case .score(let levels):
            guard (2...10).contains(levels.count) else {
                throw JevWireError.invalidQuestion(name: "", reason: .scoreLevelCountOutOfRange(levels.count))
            }
        }
        self.instructions = instructions
        self.kind = kind
    }

    /// The wire name of this question's type.
    var typeName: String {
        switch kind {
        case .noul: "noul"
        case .choice: "choice"
        case .score: "score"
        }
    }
}

extension JevQuestion: Encodable {
    private enum CodingKeys: String, CodingKey { case type, instructions, criteria }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeName, forKey: .type)
        try container.encode(instructions, forKey: .instructions)
        switch kind {
        case let .noul(whenTrue, whenFalse):
            // Leave `criteria` out when neither side is described, rather than
            // sending an empty object.
            if whenTrue != nil || whenFalse != nil {
                var criteria = container.nestedContainer(keyedBy: JevDynamicKey.self, forKey: .criteria)
                if let whenTrue { try criteria.encode(whenTrue, forKey: JevDynamicKey("true")) }
                if let whenFalse { try criteria.encode(whenFalse, forKey: JevDynamicKey("false")) }
            }
        case .choice(let options):
            var criteria = container.nestedContainer(keyedBy: JevDynamicKey.self, forKey: .criteria)
            for option in options {
                let key = JevDynamicKey(option.name)
                if let description = option.description {
                    try criteria.encode(description, forKey: key)
                } else {
                    try criteria.encodeNil(forKey: key)
                }
            }
        case .score(let levels):
            try container.encode(levels, forKey: .criteria)
        }
    }
}

/// The questions sent in one request: 1 to 32, each with a name. One web form
/// asks two questions per field.
struct JevQuestionSet: Sendable, Hashable {
    /// The Pro server refuses more (`JEV_MAX_QUESTIONS` in the worker).
    static let maxQuestions = 32

    let questions: [String: JevQuestion]

    init(_ questions: [String: JevQuestion]) throws {
        guard !questions.isEmpty else { throw JevWireError.emptyQuestionSet }
        guard questions.count <= Self.maxQuestions else { throw JevWireError.tooManyQuestions(questions.count) }
        for name in questions.keys where name.isEmpty {
            throw JevWireError.invalidQuestion(name: name, reason: .emptyName)
        }
        self.questions = questions
    }

    var count: Int { questions.count }
    subscript(name: String) -> JevQuestion? { questions[name] }
}

extension JevQuestionSet: Encodable {
    func encode(to encoder: any Encoder) throws {
        try questions.encode(to: encoder)
    }
}

/// A `CodingKey` built from a runtime string, for the dynamic `criteria` and
/// `answers` objects.
struct JevDynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// The value a noul question returns: the probability that the statement is
/// true. It is also its confidence: near 0.5 means unsure, not "medium true".
struct JevProbability: Sendable, Hashable, Comparable {
    let value: Double

    /// Clamps into 0...1. NaN is a programmer error and traps.
    init(clamping value: Double) {
        precondition(!value.isNaN, "Probability cannot be NaN")
        self.value = min(max(value, 0), 1)
    }

    /// `nil` when the value is NaN or outside 0...1.
    init?(exactly value: Double) {
        guard !value.isNaN, (0...1).contains(value) else { return nil }
        self.value = value
    }

    static func < (lhs: JevProbability, rhs: JevProbability) -> Bool { lhs.value < rhs.value }

    /// How far from "don't know": 0.5 maps to 0.5, both extremes to 1. A
    /// confident "no" is as actionable as a confident "yes".
    var decisiveness: Double { max(value, 1 - value) }
}

extension JevProbability: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Double.self)
        guard let probability = JevProbability(exactly: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "probability must be a number within 0...1, got \(raw)")
        }
        self = probability
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// The value a score question returns. `value` is probability-weighted, so it
/// lands between levels: 0.70 on level 1 and 0.30 on level 2 gives 1.30.
struct JevScoreValue: Sendable, Hashable {
    let value: Double
    let legend: [Int: String]
    let probabilities: [Int: Double]
    let confidence: Double

    init(value: Double, legend: [Int: String], probabilities: [Int: Double], confidence: Double) {
        self.value = value
        self.legend = legend
        self.probabilities = probabilities
        self.confidence = confidence
    }

    /// The nearest whole level.
    var rounded: Int { Int(value.rounded()) }
}

extension JevScoreValue: Decodable {
    private enum CodingKeys: String, CodingKey { case score, legend, probabilities, confidence }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Double.self, forKey: .score)
        let rawLegend = try container.decodeIfPresent([String: String].self, forKey: .legend) ?? [:]
        let rawProbabilities = try container.decode([String: Double].self, forKey: .probabilities)
        let confidence = try container.decode(Double.self, forKey: .confidence)
        guard !confidence.isNaN, (0...1).contains(confidence) else {
            throw DecodingError.dataCorruptedError(
                forKey: .confidence, in: container, debugDescription: "confidence must be within 0...1, got \(confidence)")
        }
        // Levels arrive as stringified integers. Convert first, then validate:
        // "0" and "00" are two string keys but one level.
        func indexed<T>(_ source: [String: T], _ key: CodingKeys) throws -> [Int: T] {
            var result: [Int: T] = [:]
            for (rawKey, value) in source {
                guard let index = Int(rawKey) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key, in: container, debugDescription: "level key '\(rawKey)' is not an integer")
                }
                guard result.updateValue(value, forKey: index) == nil else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key, in: container, debugDescription: "level \(index) appears more than once")
                }
            }
            return result
        }
        let legend = try indexed(rawLegend, .legend)
        let probabilities = try indexed(rawProbabilities, .probabilities)
        guard !value.isNaN else {
            throw DecodingError.dataCorruptedError(forKey: .score, in: container, debugDescription: "score must not be NaN")
        }
        guard probabilities.count >= 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .probabilities, in: container,
                debugDescription: "a score needs at least two levels, got \(probabilities.count)")
        }
        let highest = probabilities.count - 1
        guard (0...Double(highest)).contains(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: .score, in: container, debugDescription: "score \(value) is outside 0...\(highest)")
        }
        self.init(value: value, legend: legend, probabilities: probabilities, confidence: confidence)
    }
}

/// A type whose cases are the options of a choice question.
protocol JevChoiceOptions: RawRepresentable<String>, CaseIterable, Hashable, Sendable {
    /// Rubric per option. An option absent here is sent with a null description.
    static var optionDescriptions: [Self: String] { get }
}

extension JevChoiceOptions {
    static var optionDescriptions: [Self: String] { [:] }

    /// Options in `allCases` order.
    static var jevChoiceOptions: [JevChoiceOption] {
        allCases.map { JevChoiceOption($0.rawValue, optionDescriptions[$0]) }
    }
}

/// Token counts for one request. Jev bills input only.
struct JevUsage: Sendable, Hashable, Decodable {
    let inputTokens: Int
    let outputTokens: Int

    init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

/// One evaluated answer.
enum JevAnswer: Sendable, Hashable {
    case noul(JevProbability)
    case choice(Choice)
    case score(JevScoreValue)

    struct Choice: Sendable, Hashable {
        /// The raw string the API returned, before it is matched to an options type.
        let value: String
        let probabilities: [String: Double]
        let confidence: Double
    }

    var typeName: String {
        switch self {
        case .noul: "noul"
        case .choice: "choice"
        case .score: "score"
        }
    }

    /// Present for choice and score. A noul's probability is its confidence.
    var confidence: Double? {
        switch self {
        case .noul: nil
        case .choice(let choice): choice.confidence
        case .score(let score): score.confidence
        }
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case type, noul, choice, score, legend, probabilities, confidence
    }

    /// Decodes the answer named `key`, so a malformed one says which it was.
    fileprivate static func decode(from container: KeyedDecodingContainer<JevDynamicKey>,
                                   forKey key: JevDynamicKey) throws -> JevAnswer {
        let nested = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: key)
        let type = try nested.decode(String.self, forKey: .type)
        switch type {
        case "noul":
            return .noul(try nested.decode(JevProbability.self, forKey: .noul))
        case "choice":
            // A confidence is a probability: bounded like one, or a confidence
            // of 2.0 would pass every threshold and read as "act without asking".
            let confidence = try nested.decode(Double.self, forKey: .confidence)
            guard !confidence.isNaN, (0...1).contains(confidence) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .confidence, in: nested, debugDescription: "confidence must be within 0...1, got \(confidence)")
            }
            return .choice(Choice(value: try nested.decode(String.self, forKey: .choice),
                                  probabilities: try nested.decode([String: Double].self, forKey: .probabilities),
                                  confidence: confidence))
        case "score":
            return .score(try container.decode(JevScoreValue.self, forKey: key))
        default:
            throw JevWireError.unknownAnswerType(question: key.stringValue, type: type)
        }
    }
}

/// The answers for one evaluation, keyed by question name.
struct JevAnswers: Sendable, Hashable {
    private let storage: [String: JevAnswer]

    init(_ answers: [String: JevAnswer]) {
        self.storage = answers
    }

    var names: Set<String> { Set(storage.keys) }
    subscript(name: String) -> JevAnswer? { storage[name] }

    func noul(named name: String) throws -> JevProbability {
        switch try require(name) {
        case .noul(let probability): probability
        case let other: throw JevWireError.answerTypeMismatch(question: name, expected: "noul", actual: other.typeName)
        }
    }

    func score(named name: String) throws -> JevScoreValue {
        switch try require(name) {
        case .score(let score): score
        case let other: throw JevWireError.answerTypeMismatch(question: name, expected: "score", actual: other.typeName)
        }
    }

    func choice<T: JevChoiceOptions>(named name: String, as type: T.Type) throws -> T {
        let answer = try require(name)
        guard case .choice(let choice) = answer else {
            throw JevWireError.answerTypeMismatch(question: name, expected: "choice", actual: answer.typeName)
        }
        // Exact rawValue match only: a near-miss would hide a rubric that no
        // longer lines up with the options type.
        guard let value = T(rawValue: choice.value) else {
            throw JevWireError.unrecognizedChoice(question: name, value: choice.value,
                                                  expected: T.allCases.map(\.rawValue))
        }
        return value
    }

    /// The first question in `asked` whose answer is missing, of another type,
    /// a choice outside the options asked, or a score on other levels than the
    /// ones asked; `nil` when every answer fits. An answer that does not fit
    /// the question is never acted on.
    func problem(answering asked: JevQuestionSet) -> String? {
        for (name, question) in asked.questions.sorted(by: { $0.key < $1.key }) {
            guard let answer = storage[name], answer.typeName == question.typeName else { return name }
            if case .choice(let options) = question.kind, case .choice(let chosen) = answer,
               !options.contains(where: { $0.name == chosen.value }) {
                return name
            }
            // The decode already keeps the value within the answer's own levels.
            if case .score(let levels) = question.kind, case .score(let score) = answer,
               Set(score.probabilities.keys) != Set(levels.indices) {
                return name
            }
        }
        return nil
    }

    /// Only the answers to the questions asked.
    func restricted(to asked: JevQuestionSet) -> JevAnswers {
        JevAnswers(storage.filter { asked[$0.key] != nil })
    }

    private func require(_ name: String) throws -> JevAnswer {
        guard let answer = storage[name] else { throw JevWireError.missingAnswer(question: name) }
        return answer
    }
}

/// One response from the Pro server's `/api/pro/decisions`.
struct JevResponse: Sendable, Hashable {
    let model: String
    let answers: JevAnswers
    let usage: JevUsage?
}

extension JevResponse: Decodable {
    private enum CodingKeys: String, CodingKey { case model, answers, usage }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let answersContainer = try container.nestedContainer(keyedBy: JevDynamicKey.self, forKey: .answers)
        var answers: [String: JevAnswer] = [:]
        for key in answersContainer.allKeys {
            answers[key.stringValue] = try JevAnswer.decode(from: answersContainer, forKey: key)
        }
        self.init(model: try container.decode(String.self, forKey: .model),
                  answers: JevAnswers(answers),
                  usage: try container.decodeIfPresent(JevUsage.self, forKey: .usage))
    }
}
