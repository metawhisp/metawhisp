import Foundation

/// How much undoing an action would cost (§6.3–§6.4).
enum ActionRisk: Equatable { case alwaysReversible, otherReversible, irreversible }

/// What the loop does with a chosen action (§6.4).
enum StepDecision: Equatable { case act, askUser, reconsider, stuck }

/// The loop's rules that need no model (ITER-074 §6.3–§6.5, §8). Every
/// number is a placeholder until phase 0 measures it on real pages (§6.4).
enum AgentPolicy {
    /// A choice from here acts, unless it is irreversible, which asks the
    /// user at any confidence; below it, every choice is reconsidered. A
    /// reference browser agent's `recover_below`, measured there (MIT) — taken
    /// under the owner's copy-first rule, 2026-10-06 (ITER-076 stage 4a, F1).
    static let actFrom = 0.55
    /// Jev's BLOCKED ends a sub-goal from here; below it, it is reconsidered
    /// (ITER-076 brain). DONE ends one at any confidence (2026-10-16).
    static let subgoalEndsFrom = 0.80
    /// The `irreversible` noul counts as yes from here, so anything short of
    /// clearly safe goes to the user.
    static let irreversibleFrom = 0.20
    /// The `goal_met` noul counts as yes from here.
    static let goalMetFrom = 0.80
    /// jkudish/jev-browser (ITER-076 1.3, B): `stuck` above this stops the
    /// errand, counted from the third step.
    static let stuckAbove = 0.85
    static let stuckCountsFromStep = 3
    /// E (ITER-076 1.3): a grant answer from here hands the step to the user;
    /// the action is never taken.
    static let grantFrom = 0.20
    /// The watchers' source (ITER-076 A2, P2-4): `goal_done` above this ends
    /// a sub-goal before its step acts.
    static let goalDoneAbove = 0.85

    /// Whether the `stuck` noul ends the errand at this step (1-based). A
    /// missing or malformed answer does not.
    static func isStuck(noul: Double?, step: Int) -> Bool {
        guard let noul, (0...1).contains(noul), step >= stuckCountsFromStep else { return false }
        return noul > stuckAbove
    }

    /// Whether the `grant` noul hands the step to the user. Nil — a missing
    /// or malformed answer — means no action: the step is neither asked
    /// about nor taken, whatever structure or the lexicon said (review of
    /// A3d, round 2, P1-6). A Yes is never spent on a step nobody cleared of
    /// granting access.
    static func grants(noul: Double?) -> Bool? {
        guard let noul, (0...1).contains(noul) else { return nil }
        return noul >= grantFrom
    }

    /// §6.4's table, at one line (`actFrom`). A confidence outside 0…1 is a
    /// malformed answer, which means no action (§6.3).
    static func decide(confidence: Double, risk: ActionRisk) -> StepDecision {
        guard (0...1).contains(confidence), confidence >= actFrom else { return .reconsider }
        switch risk {
        case .alwaysReversible, .otherReversible: return .act
        case .irreversible: return .askUser
        }
    }

    /// Whether the current subgoal is met. Nil — a missing or malformed
    /// answer — means no action (§6.3).
    static func goalMet(noul: Double?) -> Bool? {
        guard let noul, (0...1).contains(noul) else { return nil }
        return noul >= goalMetFrom
    }

    /// Whether the `goal_done` noul ends the sub-goal before the step acts
    /// (ITER-076 brain). A missing or malformed answer does not.
    static func subgoalDone(noul: Double?) -> Bool {
        guard let noul, (0...1).contains(noul) else { return false }
        return noul > goalDoneAbove
    }

    /// The checks of §7.1 are independent: the page's structure (ITER-076
    /// 2.1) and a lexicon hit each need a Yes whatever else is true. Otherwise
    /// an always-reversible action needs no risk answer, and any other needs
    /// a valid one: nil means no action, never an assumed "safe".
    /// An edit's risk (`SafetyGuard.editsOnly`, the brain's errand): Jev's answer alone. The page's structure and the
    /// lexicon read what the edit's form sends when its button is pressed — that press is asked about by them — not
    /// what the edit's own change may do, which only Jev reads: a box whose change unsubscribes is irreversible by
    /// its words (Codex review 2 of 2026-10-19, P1). Nil with no answer: neither asked about nor taken.
    static func editRisk(irreversibleNoul noul: Double?) -> ActionRisk? {
        guard let noul, (0...1).contains(noul) else { return nil }
        return noul >= irreversibleFrom ? .irreversible : .otherReversible
    }

    static func risk(of action: AgentAction, irreversibleNoul: Double?, pageURL: String? = nil) -> ActionRisk? {
        if SafetyGuard.structuralReason(of: action, pageURL: pageURL) != nil { return .irreversible }
        if SafetyGuard.lexiconRequiresConfirmation(action) { return .irreversible }
        // A control whose words name a payment — "Pay now", "Place order" — is asked about before it goes, whatever
        // Jev says: the payment the user must make is a page asking card details (owner decision of 2026-10-19).
        if SafetyGuard.namesPaymentByItsWords(action) { return .irreversible }
        if SafetyGuard.isAlwaysReversible(action) { return .alwaysReversible }
        guard let noul = irreversibleNoul, (0...1).contains(noul) else { return nil }
        return noul >= irreversibleFrom ? .irreversible : .otherReversible
    }
}

/// Two «ask again» in a row for the same step mean stuck (§6.4): the errand
/// stops with what it has, and no model decides the step instead.
struct StepAttempts {
    private var reconsiderations = 0

    mutating func after(_ decision: StepDecision) -> StepDecision {
        guard decision == .reconsider else {
            reconsiderations = 0
            return decision
        }
        reconsiderations += 1
        return reconsiderations >= 2 ? .stuck : .reconsider
    }
}

/// An errand's ceilings (§8): 40 steps, 600 seconds of work and $0.50 of
/// cloud spend, whichever comes first — and 30 minutes after the start,
/// whatever the pauses.
struct AgentBudget {
    enum Ceiling: Equatable { case steps, activeTime, spend, expiry }

    /// A paid call's worst case, held back until its usage is known.
    struct Reservation: Equatable { fileprivate let id: Int }

    /// The ceilings themselves: §8's values in the app; tests may lower them.
    struct Limits: Equatable {
        let steps: Int
        let activeSeconds: TimeInterval
        /// Millionths of a dollar, so sums land exactly on the ceiling.
        let spendMicros: Int
        let expiry: Duration
        static let standard = Limits(steps: 40, activeSeconds: 600, spendMicros: 500_000, expiry: .seconds(30 * 60))
    }

    static let maxSteps = Limits.standard.steps
    static let maxActiveSeconds = Limits.standard.activeSeconds
    static let expirySeconds: TimeInterval = 30 * 60

    let startedAt: ContinuousClock.Instant
    let limits: Limits
    private var steps = 0
    private var activeSeconds: TimeInterval = 0
    private var spentMicros = 0
    private var reservedMicros: [Int: Int] = [:]
    private var nextReservationID = 0

    init(startedAt: ContinuousClock.Instant, limits: Limits = .standard) {
        self.startedAt = startedAt
        self.limits = limits
    }

    var spentUSD: Double { Double(spentMicros) / 1_000_000 }
    /// What is spent, and the worst case of every call still out (ITER-076
    /// I-05, review round 2): what an errand has committed until each call
    /// settles.
    var committedUSD: Double { Double(spentMicros + reservedMicros.values.reduce(0, +)) / 1_000_000 }

    /// A call's worst case: its maximum input and output at the model's price.
    static func worstCaseUSD(maxInputTokens: Int, maxOutputTokens: Int,
                             inputUSDPerMillion: Double, outputUSDPerMillion: Double) -> Double {
        (Double(maxInputTokens) * inputUSDPerMillion + Double(maxOutputTokens) * outputUSDPerMillion) / 1_000_000
    }

    /// Holds back a paid call's worst case before it is sent. Nil means the
    /// call would cross the spend ceiling, or its cost is nonsense: it is not
    /// sent, and the errand stops at `.spend`.
    mutating func reserve(worstCaseUSD: Double) -> Reservation? {
        guard let micros = Self.micros(worstCaseUSD),
              spentMicros + reservedMicros.values.reduce(0, +) + micros <= limits.spendMicros else { return nil }
        nextReservationID += 1
        reservedMicros[nextReservationID] = micros
        return Reservation(id: nextReservationID)
    }

    /// Counts what a call really cost and releases the rest of its
    /// reservation. With no usage reported — or nonsense — the whole
    /// reservation counts as spent (§8). A reservation settles once.
    mutating func settle(_ reservation: Reservation, actualUSD: Double?) {
        guard let reserved = reservedMicros.removeValue(forKey: reservation.id) else { return }
        spentMicros += actualUSD.flatMap(Self.micros) ?? reserved
    }

    /// One Choose request (§6.3).
    mutating func countStep() { steps += 1 }

    /// A stretch of work, measured by the run; waits for the user are left
    /// out (§8).
    mutating func addActive(seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        activeSeconds += seconds
    }

    /// The first ceiling reached, or nil. The step ceiling is about starting
    /// a new step, so a check made inside a step passes `countingSteps: false`.
    func ceiling(now: ContinuousClock.Instant, countingSteps: Bool = true) -> Ceiling? {
        if countingSteps, steps >= limits.steps { return .steps }
        if activeSeconds >= limits.activeSeconds { return .activeTime }
        if spentMicros >= limits.spendMicros { return .spend }
        if now - startedAt >= limits.expiry { return .expiry }
        return nil
    }

    /// Whether a wait of `wait` from `now` ends before both time ceilings —
    /// the work's and the expiry (ITER-076 I-05).
    func fits(_ wait: Duration, now: ContinuousClock.Instant) -> Bool {
        let seconds = Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18
        return activeSeconds + seconds < limits.activeSeconds && now - startedAt + wait < limits.expiry
    }

    /// What is left of the work's time (ITER-076 I-05); zero once it has run
    /// out. With `timeLeft`, what bounds a paid call.
    var activeTimeLeft: Duration {
        let left = limits.activeSeconds - activeSeconds
        return left > 0 ? .milliseconds(Int64((left * 1_000).rounded(.down))) : .zero
    }

    /// Time left before the absolute expiry; zero once it has passed.
    func timeLeft(now: ContinuousClock.Instant) -> Duration {
        let left = limits.expiry - (now - startedAt)
        return left > .zero ? left : .zero
    }

    /// Whole millionths of a dollar, rounded up so a call that would cross
    /// the ceiling by any amount is refused; nil for a negative or
    /// non-finite amount.
    private static func micros(_ usd: Double) -> Int? {
        guard usd.isFinite, usd >= 0 else { return nil }
        return Int((min(usd, 1_000_000) * 1_000_000).rounded(.up))
    }
}

/// Whether the errand is still getting somewhere (§6.5). Since the last new
/// row or finished subgoal, any of these means stuck: the same action three
/// times, an A-B-A-B cycle, or 8 steps — since the last page state never
/// reached, too (`reachedNewState`). Once stuck, it stays stuck.
struct ProgressTracker {
    static let repeatLimit = 3
    static let stepsWithoutProgressLimit = 8

    /// An action as the loop would repeat it: the operation, the target's
    /// fingerprint and the parameters — the same control with another
    /// option is another action.
    private struct Step: Hashable {
        let operation: AgentOperation
        let fingerprint: String?
        let destination: String?
        let payload: String?
    }

    private var recent: [Step] = []
    private var repeats: [Step: Int] = [:]
    private var stepsWithoutProgress = 0
    private(set) var isStuck = false

    mutating func record(_ action: AgentAction, newRow: Bool, subgoalFinished: Bool) {
        guard !newRow, !subgoalFinished else {
            recent = []
            repeats = [:]
            stepsWithoutProgress = 0
            return
        }
        let step = Step(operation: action.operation, fingerprint: action.target?.fingerprint,
                        destination: action.destination, payload: action.payload)
        stepsWithoutProgress += 1
        recent = Array((recent + [step]).suffix(4))
        // Back, scroll, wait and «more» have no identity of their own; going
        // back after every site is how a list gets collected.
        if ![.back, .scroll, .wait, .more].contains(action.operation) { repeats[step, default: 0] += 1 }
        let cycle = recent.count == 4 && recent[0] == recent[2] && recent[1] == recent[3] && recent[0] != recent[1]
        if repeats[step, default: 0] >= Self.repeatLimit || cycle
            || stepsWithoutProgress >= Self.stepsWithoutProgressLimit {
            isStuck = true
        }
    }

    /// The last step brought a page state the errand never reached: it made progress, whatever it brought (a
    /// reference browser agent's no-progress count, `agent.py` 1081-1094, MIT). The steps without progress start
    /// again; the same step three times, or two in turn, is still a loop. Counted as steps without a row, a walk
    /// over a list's pages ended at its eighth next page, unread (quotes.toscrape, 2026-10-16).
    mutating func reachedNewState() { stepsWithoutProgress = 0 }
}
