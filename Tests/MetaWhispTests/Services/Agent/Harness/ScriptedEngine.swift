import Foundation
@testable import MetaWhisp

/// A decision engine that follows a script (ITER-074 §12.1): no model, and the
/// same answer to the same question every time.
final class ScriptedEngine: DecisionEngine, @unchecked Sendable {
    let name = "scripted"
    let worstCaseUSD = 0.001
    private let choice: @Sendable (ChooseRequest) -> ChooseAnswer
    private let irreversible: @Sendable (AgentAction) -> Double
    private let grant: @Sendable (AgentAction) -> Double?
    private let riskFails: @Sendable (AgentAction) -> Bool
    private let lock = NSLock()
    private var risks: [(action: AgentAction, page: PageSummary, goal: String)] = []

    /// By default the script answers both risk questions — C "reversible",
    /// E "no grant" — as Jev does; a test leaves E out with `grant: nil`, or
    /// fails the whole call with `riskFails` (review of A3d, round 2, P1-6).
    init(choice: @escaping @Sendable (ChooseRequest) -> ChooseAnswer,
         irreversible: @escaping @Sendable (AgentAction) -> Double = { _ in 0.05 },
         grant: @escaping @Sendable (AgentAction) -> Double? = { _ in 0.0 },
         riskFails: @escaping @Sendable (AgentAction) -> Bool = { _ in false }) {
        self.choice = choice
        self.irreversible = irreversible
        self.grant = grant
        self.riskFails = riskFails
    }

    /// The risk call a script fails, as a timeout or a 503 would.
    struct RiskUnavailable: Error {}

    /// Every risk question asked, in order.
    var riskQuestions: [(action: AgentAction, page: PageSummary, goal: String)] {
        lock.lock()
        defer { lock.unlock() }
        return risks
    }

    func choose(_ request: ChooseRequest) async throws -> ChooseAnswer { choice(request) }

    func risk(of action: AgentAction, on page: PageSummary, goal: String) async throws -> RiskAnswer {
        lock.lock()
        risks.append((action, page, goal))
        lock.unlock()
        if riskFails(action) { throw RiskUnavailable() }
        return RiskAnswer(irreversible: irreversible(action), grant: grant(action), usage: EngineUsage(costUSD: 0.0005))
    }

    /// The candidate a script picks, as an answer.
    static func pick(_ candidate: Candidate?, confidence: Double = 0.95, goalMet: Double = 0,
                     stuck: Double? = nil) -> ChooseAnswer {
        ChooseAnswer(candidateID: candidate?.id ?? "none", confidence: confidence, goalMet: goalMet, stuck: stuck,
                     usage: EngineUsage(costUSD: 0.0005))
    }

    /// J1 on the fixtures: on the results page — the one with the search
    /// engine's own links — open the next site not yet collected; on a site,
    /// say the subgoal is met and go back.
    static func collectSites() -> ScriptedEngine {
        ScriptedEngine(choice: { request in
            let onResults = request.candidates.contains {
                ($0.action.destination ?? "").hasPrefix("https://search.test/") && !$0.action.isPlannedSearch
            }
            let next = "https://site-\(request.rowsCollected + 1).test/"
            if onResults, let open = request.candidates.first(where: {
                $0.action.operation == .open && $0.action.destination == next
            }) {
                return pick(open)
            }
            return pick(request.candidates.first { $0.action.operation == .back }, goalMet: onResults ? 0 : 0.95)
        })
    }
}

/// A writer that writes a row from the excerpt it is given, the same way
/// every time: the title, the address and the start of the text.
struct FakeWriter: TextWriter {
    let name = "fake-writer"
    let worstCaseUSD = 0.002

    func row(columns: [String], subgoal: AgentPlan.Subgoal, excerpt: PageExcerpt) async throws -> WriterRow {
        let known = [excerpt.title, excerpt.url, String(excerpt.text.prefix(60))]
        let cells = columns.indices.map { $0 < known.count ? known[$0] : "" }
        return WriterRow(cells: cells, usage: EngineUsage(costUSD: 0.001))
    }
}
