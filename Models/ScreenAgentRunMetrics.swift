import Foundation
import SwiftData

/// What one Screen Agent run actually cost and actually did.
///
/// Every one of these numbers used to go to the unified log, and the log is not
/// readable from every place this app is worked on — which turned "no lines
/// matched" into "it never happened" more than once. Claims made on that basis
/// («zero vision calls in a day», «the cheap gate is filtering») were not
/// measurements; they were an empty grep read as a clean result. A counter that
/// cannot be queried is not a counter.
///
/// A separate row rather than more columns on `ScreenAgentRun`: that model is
/// shared by V6, V7 and V8, and widening a shape three shipped versions already
/// pin is how the frozen-copy lesson gets learned twice.
///
/// Content-free by construction. No OCR, no titles, no headline — counts,
/// outcomes and durations only, so the answer to "what did the agent do today"
/// never requires reading what the user had on screen.
@Model
final class ScreenAgentRunMetrics {

    /// The analysis this describes — `ScreenAgentRun.id`, one row per run.
    @Attribute(.unique) var runID: UUID
    var recordedAt: Date

    // MARK: - The cheap gate

    /// `notRun` | `fired` | `skipped` | `failedOpen`.
    ///
    /// The gate exists to keep most screens away from the expensive model. Its
    /// skip rate is the single number that says whether it earns its keep, and
    /// until now it was unanswerable.
    var gateOutcome: String
    /// The score the gate returned, or -1 when it never ran.
    var gateScore: Double
    var gateMilliseconds: Int

    // MARK: - What was spent

    var textModelCallCount: Int
    /// Turns around the investigation tool loop. One run can take several.
    var toolTurnCount: Int
    var visionModelCallCount: Int
    /// Transport or provider errors, including the ones a fallback recovered
    /// from — a fallback that always fires is an outage nobody noticed.
    var providerFailureCount: Int
    var fallbackCount: Int

    // MARK: - What was looked at

    var screenHistorySearchCount: Int
    var screenTextReadCount: Int
    var taskSearchCount: Int
    var memorySearchCount: Int

    // MARK: - Money

    /// Zero means NOT MEASURED, never "free". The proxy does not return usage
    /// yet, and inventing a number from an estimate would be the same mistake
    /// in a new place.
    var promptTokenCount: Int
    var completionTokenCount: Int
    var costMicroUSD: Int

    /// Wall time from the run opening to its terminal outcome.
    var totalMilliseconds: Int

    init(runID: UUID,
         recordedAt: Date = Date(),
         gateOutcome: String = "notRun",
         gateScore: Double = -1,
         gateMilliseconds: Int = 0,
         textModelCallCount: Int = 0,
         toolTurnCount: Int = 0,
         visionModelCallCount: Int = 0,
         providerFailureCount: Int = 0,
         fallbackCount: Int = 0,
         screenHistorySearchCount: Int = 0,
         screenTextReadCount: Int = 0,
         taskSearchCount: Int = 0,
         memorySearchCount: Int = 0,
         promptTokenCount: Int = 0,
         completionTokenCount: Int = 0,
         costMicroUSD: Int = 0,
         totalMilliseconds: Int = 0) {
        self.runID = runID
        self.recordedAt = recordedAt
        self.gateOutcome = gateOutcome
        self.gateScore = gateScore
        self.gateMilliseconds = gateMilliseconds
        self.textModelCallCount = textModelCallCount
        self.toolTurnCount = toolTurnCount
        self.visionModelCallCount = visionModelCallCount
        self.providerFailureCount = providerFailureCount
        self.fallbackCount = fallbackCount
        self.screenHistorySearchCount = screenHistorySearchCount
        self.screenTextReadCount = screenTextReadCount
        self.taskSearchCount = taskSearchCount
        self.memorySearchCount = memorySearchCount
        self.promptTokenCount = promptTokenCount
        self.completionTokenCount = completionTokenCount
        self.costMicroUSD = costMicroUSD
        self.totalMilliseconds = totalMilliseconds
    }

    /// Gate outcomes, spelled once.
    enum Gate: String, CaseIterable {
        case notRun
        case fired
        case skipped
        /// The gate errored and the run went ahead anyway. Deliberate — an
        /// outage must not silence real signals — but it has to be visible,
        /// because a gate that fails open all day looks exactly like a gate
        /// that is passing everything.
        case failedOpen

        /// The vocabulary is a contract with every query written against this
        /// column; a silently added case makes old totals mean something else.
        static var allCasesForTests: [Gate] { allCases }
    }

    /// A tally a run fills in as it goes, then hands over once. Kept out of
    /// SwiftData so the hot path never touches a context.
    struct Tally {
        var gateOutcome: Gate = .notRun
        var gateScore: Double = -1
        var gateMilliseconds: Int = 0
        var textModelCallCount = 0
        var toolTurnCount = 0
        var visionModelCallCount = 0
        var providerFailureCount = 0
        var fallbackCount = 0
        var screenHistorySearchCount = 0
        var screenTextReadCount = 0
        var taskSearchCount = 0
        var memorySearchCount = 0
        var totalMilliseconds = 0
    }
}
