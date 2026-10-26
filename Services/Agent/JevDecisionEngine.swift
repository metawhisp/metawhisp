import Foundation

/// The decision engine the loop asks each step (ITER-076 1.3b): Jev, through
/// the Pro server, with the owner-approved questions of `JevQuestions`.
///
/// A step is asked the way jev-ultrafast asks it (`model.py` `action_space`
/// and `choose`, browser-use/jev-ultrafast 1231850, MIT): the state holds the
/// page, one entry per element and the recent actions; one choice picks the
/// operation, one choice per element operation picks its target, and
/// jkudish's two watchers are asked beside them. The target heads are
/// speculative: only the chosen operation's head is read, and only an answer
/// that passes jev-ultrafast's `validate_choice` is acted on.
struct JevDecisionEngine: DecisionEngine {
    /// Why a call gave no answer, as the server said it (ITER-076 I-05).
    enum Failure: Error, Equatable {
        /// No Pro license, or the server did not accept it (401).
        case noPro
        /// Today's Jev allowance is used up (429): it renews at the next UTC
        /// day, `retryAfter` from now when the server says.
        case dailyLimit(retryAfter: Duration?)
        /// Jev could not answer now — no network, or the server's 503 — and
        /// may after `retryAfter`, when the server says.
        case unavailable(retryAfter: Duration?)
        /// Time ran out first: the call's own limit, or the server's (504).
        case timedOut
        /// The request or the answer broke the contract: asked again the same
        /// way, it fails the same way.
        case invalid
        /// The answer broke `validate_choice`, or named no candidate.
        case invalidAnswer
        /// The owner switched the agent off on the server (ITER-076 stage 9d,
        /// № 27): the errand stops, with no wait and no report.
        case switchedOff
    }

    /// A call refused before its request left the Mac (ITER-076 stage 8a):
    /// `failure` is what it came to, and nothing was spent on it.
    struct NotSent: Error, Equatable {
        let failure: Failure
    }

    /// The engine's name as a step keeps it, and the report's contract lists it (ITER-076 I-06b).
    static let engineName = "jev"
    let name = JevDecisionEngine.engineName
    /// Jev bills input tokens only: $42 per billion (TypeSafe's models page,
    /// read 2026-09-29; OpenRouter's price, 2026-09-26).
    static let usdPerInputToken = 0.042 / 1_000_000
    /// The most one request can hold: Jev's 32,000-token context.
    static let maxInputTokens = 32_000

    /// What one step may ask Jev (2026-10-08; a reference browser agent's
    /// `TokenBudget`, `config.py` 59-74, MIT): its state with its largest
    /// question within Jev's 32,000-token context. Jev billed this JSON at
    /// 2.06 to 2.30 bytes a token over 348 decisions of the day's live runs,
    /// and refused one of 80,625 bytes; at 2 bytes a token, 56,000 bytes is
    /// about 28,000 tokens.
    static let maxStatePlusQuestionBytes = 56_000
    var worstCaseUSD: Double { Double(Self.maxInputTokens) * Self.usdPerInputToken }

    private let jev: JevEngine
    private let limit: Duration

    init(jev: JevEngine = JevEngine(), limit: Duration = AgentRun.decisionDeadline) {
        self.jev = jev
        self.limit = limit
    }

    func choose(_ request: ChooseRequest) async throws -> ChooseAnswer {
        let step = try Self.step(for: request)
        return try Self.answer(try Self.answered(await jev.ask(step.questions, state: step.state, within: limit)),
                               to: step)
    }

    func risk(of action: AgentAction, on page: PageSummary, goal: String) async throws -> RiskAnswer {
        let asked = try Self.risk(for: action, on: page, goal: goal)
        return try Self.riskAnswer(try Self.answered(await jev.ask(asked.questions, state: asked.state,
                                                                   within: limit)))
    }

    /// Jev's answer, or the failure the server said (ITER-076 I-05).
    private static func answered(_ outcome: JevEngine.Outcome) throws -> JevResponse {
        switch outcome {
        case .answered(let response): return response
        case .notSent(let refused):
            do { return try answered(refused) } catch let failure as Failure { throw NotSent(failure: failure) }
        case .refused(.noPro): throw Failure.noPro
        case .refused(.dailyLimit(let retryAfter)): throw Failure.dailyLimit(retryAfter: retryAfter)
        case .refused(.switchedOff): throw Failure.switchedOff
        case .unavailable(let retryAfter): throw Failure.unavailable(retryAfter: retryAfter)
        case .timedOut: throw Failure.timedOut
        case .invalid: throw Failure.invalid
        }
    }

    // MARK: - The step

    /// The state a step reads, as jev-ultrafast builds it.
    struct StepState: Encodable, Sendable, Equatable {
        struct Page: Encodable, Sendable, Equatable {
            let url: String
            let title: String
            let text: String
        }

        struct Option: Encodable, Sendable, Equatable {
            let index: String
            let label: String
            let value: String
        }

        struct Element: Encodable, Sendable, Equatable {
            let index: String
            let role: String
            let label: String
            let value: String
            let checked: String?
            let operations: [String]
            let options: [Option]?
            /// The row or section it sits in, when another element shares its
            /// label (ITER-076 I-10): page data, never sent otherwise.
            var context: String? = nil
        }

        struct Action: Encodable, Sendable, Equatable {
            let action: String
            let kind: String
            let text: String?
            let pageChanged: Bool?
            /// What it visibly did, for the last `effectsShown` actions (2026-10-16).
            var effect: String? = nil

            enum CodingKeys: String, CodingKey {
                case action, kind, text, effect
                case pageChanged = "page_changed"
            }

            // jev-ultrafast sends every key, a null text included.
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(action, forKey: .action)
                try container.encode(kind, forKey: .kind)
                try container.encode(text, forKey: .text)
                try container.encode(pageChanged, forKey: .pageChanged)
                try container.encode(effect, forKey: .effect)
            }
        }

        /// The errand's goal, which jkudish's two watchers read as `task`
        /// (`navigate.ts` 766-767). A carries it in its instructions instead.
        let task: String
        let page: Page
        let elements: [Element]
        let recentActions: [Action]

        enum CodingKeys: String, CodingKey {
            case task, page, elements
            case recentActions = "recent_actions"
        }
    }

    /// One step's questions, the state they read, and how an answer names a
    /// candidate.
    struct Step: Sendable {
        let questions: JevQuestionSet
        let state: StepState
        /// Every operation offered.
        let operations: [String]
        /// For an element operation: each target's key and its candidate.
        let targets: [String: [String: String]]
        /// For a control, DONE and BLOCKED: its candidate.
        let controls: [String: String]
    }

    /// What a link to the page itself is told apart by, as Jev reads a control's row (2026-10-15).
    static let thisPage = "a link to this same page"

    /// How many of the last actions reach Jev with what each did (2026-10-16).
    static let effectsShown = 6

    /// The step for this page's candidates. «More» and a planned search have no
    /// label among the approved texts, so neither is offered (ITER-076 1.3b).
    /// `rowContext`: twins carry their rows (`JevQuestions.sendsRowContext`,
    /// approved 2026-10-06); tests may turn it off.
    static func step(for request: ChooseRequest, rowContext: Bool = JevQuestions.sendsRowContext) throws -> Step {
        let whole = try built(for: request, rowContext: rowContext)
        guard try size(of: whole) > maxStatePlusQuestionBytes else { return whole }
        // A page with more controls than Jev's context holds offers fewer
        // (2026-10-08): those on screen first, then in the page's order — as
        // many as fit, found by halving; the page's own operations stay.
        let ranked = request.candidates.indices.filter { request.candidates[$0].action.target != nil }.sorted {
            let first = request.candidates[$0].action.target?.inViewport == true ? 0 : 1
            let second = request.candidates[$1].action.target?.inViewport == true ? 0 : 1
            return (first, $0) < (second, $1)
        }
        let keeping = { (count: Int) throws -> Step in
            let kept = Set(ranked.prefix(count))
            let candidates = request.candidates.indices.filter { request.candidates[$0].action.target == nil || kept.contains($0) }
                .map { request.candidates[$0] }
            return try built(for: ChooseRequest(candidates: candidates, subgoal: request.subgoal,
                                                rowsCollected: request.rowsCollected, rowsWanted: request.rowsWanted,
                                                goal: request.goal, page: request.page,
                                                recentActions: request.recentActions), rowContext: rowContext)
        }
        var fits = try keeping(0)
        var low = 0, high = ranked.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            let step = try keeping(middle)
            if try size(of: step) <= maxStatePlusQuestionBytes {
                fits = step
                low = middle
            } else {
                high = middle - 1
            }
        }
        return fits
    }

    /// The bytes of a step's state with its largest question, as the request
    /// writes them (`JevEngine`).
    private static func size(of step: Step) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let largest = try step.questions.questions.values.map { try encoder.encode($0).count }.max() ?? 0
        return try encoder.encode(step.state).count + largest
    }

    /// The step for every candidate given.
    private static func built(for request: ChooseRequest, rowContext: Bool) throws -> Step {
        // Elements keyed "1", "2", … in the order their first action comes; a
        // select's options "i:k", as jev-ultrafast keys them.
        var keys: [Int: String] = [:]
        var elements: [(key: String, element: ObservedElement, operations: [String], options: [StepState.Option])] = []
        var targets: [String: [(key: String, label: String, element: ObservedElement, candidate: String)]] = [:]
        var controls: [String: String] = [:]

        for candidate in request.candidates {
            let action = candidate.action
            if let control = controlName[action.operation] {
                if controls[control] == nil { controls[control] = candidate.id }
                continue
            }
            guard let element = action.target, !action.isPlannedSearch,
                  let operation = elementOperation[action.operation] else { continue }
            let key: String
            if let known = keys[element.index] {
                key = known
            } else {
                key = String(keys.count + 1)
                keys[element.index] = key
                elements.append((key, element, [], []))
            }
            let slot = elements.firstIndex { $0.key == key }!
            if !elements[slot].operations.contains(operation) { elements[slot].operations.append(operation) }
            if operation == "SELECT", let option = action.payload {
                let optionKey = "\(key):\(elements[slot].options.count + 1)"
                // Listed under the select's action label, "Select → Option"
                // (`model.py` 76).
                elements[slot].options.append(StepState.Option(index: optionKey, label: "\(element.name) → \(option)",
                                                               value: option))
                targets[operation, default: []].append((optionKey, "\(element.name) → \(option)", element,
                                                        candidate.id))
            } else {
                targets[operation, default: []].append((key, element.name, element, candidate.id))
            }
        }

        // Controls that share a label — "Add to cart" in three rows — are told
        // apart by their row, or their section when they sit in none (ITER-076
        // I-10; critic P1-9; a reference browser agent's `snapshot.js` 610-622,
        // MIT): data beside the label, in the target and in the state. A
        // control alone with its label is described as before
        // (`JevQuestions.sendsRowContext`).
        var named: [String: Int] = [:]
        for entry in elements { named[entry.element.name, default: 0] += 1 }
        // A link to the page the tab already shows says so (2026-10-15: a menu's "New tab link" to the page itself
        // drew Jev from the link that opened the new page; the link stays offered — "Start over" reloads a form).
        let here = AgentAction.effectAddress(request.page.url)
        let context = { (element: ObservedElement) -> String? in
            if element.role == "link", let href = element.href, AgentAction.effectAddress(href) == here {
                return Self.thisPage
            }
            return rowContext && (named[element.name] ?? 0) > 1 ? element.context ?? element.heading : nil
        }

        let orderedOperations = ["CLICK", "TYPE_TEXT", "SELECT"].filter { targets[$0] != nil }
        let orderedControls = ["SCROLL_DOWN", "WAIT", "BACK"].filter { controls[$0] != nil }
        var questions = try JevQuestions.step(
            goal: request.goal,
            targets: orderedOperations.map { operation in
                (operation, targets[operation, default: []].map { target in
                    JevQuestions.StepTarget(index: target.key, label: target.label,
                                            currentValue: target.element.value ?? "", role: target.element.role,
                                            checked: target.element.checked.map { String($0) },
                                            context: context(target.element))
                })
            },
            controls: orderedControls)
        questions.merge(try JevQuestions.watchers()) { first, _ in first }

        let state = StepState(
            task: request.goal,
            page: .init(url: request.page.url, title: request.page.title, text: request.page.text),
            elements: elements.map { entry in
                StepState.Element(index: entry.key, role: entry.element.role, label: entry.element.name,
                                  value: entry.element.value ?? "",
                                  checked: entry.element.checked.map { String($0) }, operations: entry.operations,
                                  options: entry.options.isEmpty ? nil : entry.options,
                                  context: context(entry.element))
            },
            recentActions: request.recentActions.enumerated().map { place, taken in
                // What each of the last six did, as a reference browser agent sends its recent history; older
                // ones without it, as their effects describe page states long changed (`agent.py`
                // `_history`, `config.py` history_entries, MIT).
                let recentEnough = place >= request.recentActions.count - Self.effectsShown
                return StepState.Action(action: taken.label, kind: taken.kind, text: taken.typed,
                                        pageChanged: taken.pageChanged, effect: recentEnough ? taken.effect : nil)
            })

        return Step(questions: try JevQuestionSet(questions), state: state,
                    operations: orderedOperations + orderedControls + ["DONE", "BLOCKED"],
                    targets: targets.mapValues { Dictionary(uniqueKeysWithValues: $0.map { ($0.key, $0.candidate) }) },
                    controls: controls)
    }

    /// The candidate an answer names, at the lower of the operation's and the
    /// target's confidence, with the two watchers — and, for the errand's
    /// record, the two confidences and how many targets the operation was
    /// offered (ITER-076 stage 4a).
    static func answer(_ response: JevResponse, to step: Step) throws -> ChooseAnswer {
        guard case .choice(let operation)? = response.answers["operation"],
              isValid(operation, offered: Set(step.operations)) else { throw Failure.invalidAnswer }
        let candidate: String
        var confidence = operation.confidence
        var targetConfidence: Double?
        if let targets = step.targets[operation.value] {
            guard case .choice(let target)? = response.answers[operation.value.lowercased() + "_target"],
                  isValid(target, offered: Set(targets.keys)), let chosen = targets[target.value] else {
                throw Failure.invalidAnswer
            }
            candidate = chosen
            confidence = min(confidence, target.confidence)
            targetConfidence = target.confidence
        } else if let control = step.controls[operation.value] {
            candidate = control
        } else {
            throw Failure.invalidAnswer
        }
        return ChooseAnswer(candidateID: candidate, confidence: confidence,
                            goalMet: noul(response, "goal_done"), stuck: noul(response, "stuck"),
                            usage: usage(response), operationConfidence: operation.confidence,
                            targetConfidence: targetConfidence, targets: step.targets[operation.value]?.count)
    }

    /// jev-ultrafast `model.py` `validate_choice`: probabilities over exactly
    /// the offered options, each within 0…1, summing to 1 within 0.02, and the
    /// choice the most likely.
    static func isValid(_ choice: JevAnswer.Choice, offered: Set<String>) -> Bool {
        let probabilities = choice.probabilities
        let numbers = Array(probabilities.values) + [choice.confidence]
        guard offered.contains(choice.value), Set(probabilities.keys) == offered,
              numbers.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(probabilities.values.reduce(0, +) - 1) < 0.02,
              let chosen = probabilities[choice.value], let highest = probabilities.values.max() else { return false }
        return chosen >= highest - 1e-6
    }

    // MARK: - Risk

    /// C and E about the one control the step would act on. A select names
    /// the option it would choose.
    static func risk(for action: AgentAction, on page: PageSummary, goal: String) throws
        -> (questions: JevQuestionSet, state: JevQuestions.RiskState) {
        let name = action.target?.name ?? ""
        let label = action.operation == .select ? "\(name) → \(action.payload ?? "")" : name
        let context = action.target?.context ?? action.target?.heading ?? ""
        let built = try JevQuestions.risk(task: goal, url: page.url, title: page.title,
                                          controls: [(label: label, context: context)])
        return (try JevQuestionSet(built.questions), built.state)
    }

    static func riskAnswer(_ response: JevResponse) throws -> RiskAnswer {
        guard let irreversible = noul(response, "destructive_0") else { throw Failure.invalidAnswer }
        return RiskAnswer(irreversible: irreversible, grant: noul(response, "grant_0"), usage: usage(response))
    }

    // MARK: - Private

    private static let elementOperation: [AgentOperation: String] = [
        .click: "CLICK", .open: "CLICK", .type: "TYPE_TEXT", .select: "SELECT",
    ]
    private static let controlName: [AgentOperation: String] = [
        .scroll: "SCROLL_DOWN", .wait: "WAIT", .back: "BACK", .done: "DONE", .stuck: "BLOCKED",
    ]

    private static func noul(_ response: JevResponse, _ name: String) -> Double? {
        guard case .noul(let probability)? = response.answers[name] else { return nil }
        return probability.value
    }

    private static func usage(_ response: JevResponse) -> EngineUsage? {
        response.usage.map { EngineUsage(costUSD: Double($0.inputTokens) * usdPerInputToken) }
    }
}
