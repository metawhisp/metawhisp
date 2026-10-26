import Foundation

// The loop's collaborators (ITER-074 §5): the decision engine that picks
// each step, the writer that writes text only, and the Sheet the rows go to.
// How the engines' questions are put into words belongs to the engines — the
// owner approves those words before they are committed (I-0.4); here they
// are data.

/// What a paid call really cost, when the engine says.
struct EngineUsage: Equatable {
    let costUSD: Double
}

/// What a step's questions read of the page (ITER-076 1.3b), as
/// jev-ultrafast sends `state.page`: its address, its title and its text.
struct PageSummary: Equatable, Sendable {
    let url: String
    let title: String
    let text: String
}

/// One of the last actions, as jev-ultrafast's `recent_actions` keeps it: the
/// action's label, its kind, the text typed, and whether the page changed —
/// nil until the next look tells. Held for the questions only: the errand's
/// record never carries page words.
struct RecentAction: Equatable, Sendable {
    let label: String
    let kind: String
    let typed: String?
    var pageChanged: Bool?
    /// What it visibly did (`StepEffect`), nil until the next look tells:
    /// what the verifier and the recovery read with the step, and Jev with
    /// the last six (`JevDecisionEngine.effectsShown`).
    var effect: String? = nil
}

/// The last actions a step reads, oldest first: at most ten, as jev-ultrafast
/// sends `history[-10:]`.
struct RecentActions: Equatable {
    static let limit = 10
    private(set) var all: [RecentAction] = []

    mutating func append(_ action: RecentAction) {
        all.append(action)
        if all.count > Self.limit { all.removeFirst(all.count - Self.limit) }
    }

    /// Whether the last action changed the page, and what it visibly did,
    /// once the next look tells.
    mutating func settleLast(pageChanged: Bool, effect: String? = nil) {
        guard let last = all.indices.last, all[last].pageChanged == nil else { return }
        all[last].pageChanged = pageChanged
        all[last].effect = effect
    }
}

/// The Choose question of one step (§6.3).
struct ChooseRequest: Equatable {
    let candidates: [Candidate]
    let subgoal: AgentPlan.Subgoal
    let rowsCollected: Int
    let rowsWanted: Int
    /// What the step works toward, as question A and the watchers read it:
    /// the user's own words — jev-ultrafast asks every step about the whole
    /// goal — or, in an answer errand, the sub-goal the text model named
    /// (ITER-076 brain).
    let goal: String
    let page: PageSummary
    let recentActions: [RecentAction]
}

struct ChooseAnswer: Equatable {
    /// One of the candidates' ids — anything else is no action (§6.3).
    let candidateID: String
    let confidence: Double
    /// The `goal_met` noul; nil when the engine gave none.
    let goalMet: Double?
    /// The `stuck` noul (ITER-076 1.3, B); nil when the engine gave none.
    var stuck: Double? = nil
    let usage: EngineUsage?
    /// The engine's own confidences — the operation's, and its target's when
    /// it has one — and how many targets the operation was offered: numbers
    /// the errand's record keeps beside the step (ITER-076 stage 4a); nil
    /// when the engine gave none.
    var operationConfidence: Double? = nil
    var targetConfidence: Double? = nil
    var targets: Int? = nil
}

struct RiskAnswer: Equatable {
    /// The `irreversible` noul; nil when the engine gave none.
    let irreversible: Double?
    /// The `grant` noul (ITER-076 1.3, E); nil when the engine gave none.
    var grant: Double? = nil
    let usage: EngineUsage?
}

/// Picks every step; no LLM ever does (decision 12).
protocol DecisionEngine: Sendable {
    var name: String { get }
    /// The most one call can cost, reserved before it is sent (§8); 0 for a
    /// local engine.
    var worstCaseUSD: Double { get }
    func choose(_ request: ChooseRequest) async throws -> ChooseAnswer
    /// C and E read the errand's goal as `task`, the page, and the control.
    func risk(of action: AgentAction, on page: PageSummary, goal: String) async throws -> RiskAnswer
}

/// Writes an errand's plan from the user's own words (ITER-074 §3.1): once,
/// before any page is read. A text model's call, paid for like the writer's;
/// `TextPlanner` is the app's (ITER-076 brain).
protocol ErrandPlanner: Sendable {
    /// The most the plan of `goal` can cost, reserved before it is asked for
    /// (§8): a text model's call costs what its own request may (ITER-076
    /// stage 10b). With no usage reported, the whole of it counts as spent.
    func worstCaseUSD(goal: String) -> Double
    func plan(goal: String) async throws -> AgentPlan
}

/// One row the writer extracted, in the plan's column order.
struct WriterRow: Equatable {
    let cells: [String]
    let usage: EngineUsage?
}

/// Writes text and never decides a step (decision 12). Its output is data:
/// every cell is canonicalised and escaped before the paste (§6.6).
protocol TextWriter: Sendable {
    var name: String { get }
    var worstCaseUSD: Double { get }
    func row(columns: [String], subgoal: AgentPlan.Subgoal, excerpt: PageExcerpt) async throws -> WriterRow
}

/// The page's own words the writer gets (§6.6): the visible text of its main
/// content, bounded, without anything someone wrote there.
struct PageExcerpt: Decodable, Equatable {
    let url: String
    let title: String
    let text: String

    /// The excerpt script caps its own text far below this; a bigger answer is
    /// a page tampering with it, and is refused unread.
    static let maxBytes = 100_000

    static func decode(_ json: String) throws -> PageExcerpt {
        guard json.utf8.count <= maxBytes else { throw ObservationError.tooLarge }
        return try JSONDecoder().decode(PageExcerpt.self, from: Data(json.utf8))
    }
}

/// What a Sheet shows after the paste (§6.6): its cells as displayed, and
/// whether any of them holds a formula.
struct SheetReadBack: Equatable {
    let cells: [[String]]
    let holdsFormula: Bool
}

/// Where the rows go: a new Sheet the errand creates (decision 11). In the
/// app this is Google Sheets in the user's browser; in tests, a fixture. Like
/// the bridge, every call ends by its own deadline; the paste also owns the
/// user's consent to take the screen for it (§4, §7.5).
@MainActor
protocol SheetDestination {
    /// Creates a new, titled Sheet and returns its address. `made` gets the
    /// address — a receipt — the moment the Sheet exists, before this returns
    /// and whatever happens to the caller after (ITER-076 I-05, review round
    /// 2): a Sheet that exists is never lost.
    func create(title: String, made: @escaping @MainActor (URL) -> Void) async throws -> URL
    /// Pastes tab-separated rows into a Sheet this destination created.
    func paste(_ text: String, into sheet: URL) async throws
    func readBack(_ sheet: URL) async throws -> SheetReadBack
    /// Closes what it opened for the Sheet — its tab — whatever came of it
    /// (ITER-076 stage 6).
    func close() async
}

/// A destination that opens nothing has nothing to close.
extension SheetDestination {
    func close() async {}
}

/// The way to a new Sheet passed a page only the user may get past — Google's
/// sign-in, its consent page — in the Sheet's own tab (ITER-076 stage 6, №
/// 175): the run waits for them there, as at any part of theirs, and asks for
/// the Sheet again once they said Continue.
struct SheetWall: Error, Equatable {
    let handover: ErrandHandover
    let tab: BrowserTab
}
