import Foundation

/// Where planned searches go. The app builds every address from a query the
/// plan holds; a model never writes a URL (§6.2).
struct SearchEngine: Equatable {
    let base: URL
    let queryName: String

    /// The search for `query`, which stays one parameter value whatever it
    /// holds. Nil for an empty query.
    func url(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: queryName, value: trimmed)]
        components.fragment = nil
        return components.url
    }
}

/// What an errand is for (ITER-074 §3.1, §4, §5): written once, from the
/// user's words only, before any page is read — and never changed after. A
/// rows plan names a Sheet's columns; an answer plan (ITER-076 brain) names
/// what the user asked for, each requirement checkable.
struct AgentPlan: Equatable {
    /// One step towards the goal, and the words that mark a page serving it.
    struct Subgoal: Equatable {
        let description: String
        let terms: [String]
    }

    /// One outcome the user asked for, as the planner's schema names it: a
    /// fact to find, or a change to make (ITER-076 brain).
    struct Requirement: Equatable {
        enum Kind: String, Equatable { case action, information }
        let id: String
        let text: String
        let kind: Kind
    }

    /// Far above J1's ten rows and J2's five; a bigger number is a misread
    /// request, not an errand.
    static let maxRows = 50

    let goal: String
    let subgoals: [Subgoal]
    /// Web addresses only.
    let searches: [URL]
    let columns: [String]
    let sheetTitle: String
    let rowsWanted: Int
    /// What a cell the agent could not fill says, in the request's language.
    let emptyCell: String
    /// An answer plan's requirements, at least one, each id once; none in a
    /// rows plan.
    let requirements: [Requirement]
    /// The user expects an answer in words.
    let answerExpected: Bool
    /// What writing the plan cost, when the model said (§8).
    var usage: EngineUsage? = nil

    /// Nil for a plan the loop cannot run: no subgoal, no column, no web
    /// search, or a number of rows outside 1…`maxRows`. Searches that are
    /// not web addresses are dropped (§6.2).
    init?(goal: String, subgoals: [Subgoal], searches: [URL], columns: [String], sheetTitle: String,
          rowsWanted: Int, emptyCell: String) {
        let webSearches = searches.filter(DiaScript.isOpenable)
        guard !subgoals.isEmpty, !columns.isEmpty, !webSearches.isEmpty, (1...Self.maxRows).contains(rowsWanted) else {
            return nil
        }
        self.goal = goal
        self.subgoals = subgoals
        self.searches = webSearches
        self.columns = columns
        self.sheetTitle = sheetTitle
        self.rowsWanted = rowsWanted
        self.emptyCell = emptyCell
        requirements = []
        answerExpected = false
    }

    /// An answer plan (ITER-076 brain): nil without a requirement, or with an
    /// id two requirements share — a reference browser agent's check
    /// (`planner.py` 39-43, MIT), and one more: every task has at least one.
    init?(goal: String, requirements: [Requirement], answerExpected: Bool) {
        guard !requirements.isEmpty, Set(requirements.map(\.id)).count == requirements.count else { return nil }
        self.goal = goal
        subgoals = []
        searches = []
        columns = []
        sheetTitle = ""
        rowsWanted = 0
        emptyCell = ""
        self.requirements = requirements
        self.answerExpected = answerExpected
    }

    /// The plan wants rows for a Sheet; an answer plan wants none.
    var asksForRows: Bool { !columns.isEmpty }

    /// The subgoal a row serves: one per row in order, the last one
    /// repeated — J1 has one for all its rows, J2 one per service.
    func subgoal(forRow index: Int) -> Subgoal {
        subgoals[min(max(index, 0), subgoals.count - 1)]
    }
}
