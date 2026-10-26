import XCTest
@testable import MetaWhisp

/// The loop's rules that need no browser and no model (ITER-074 §6.3–§6.5,
/// §8): what a confidence allows, when a risk needs the user, what the
/// budget lets through, and when the run is stuck or out of time.
///
/// Every limit is tested on both sides: quiet just below it, and firing
/// anyway once it is reached.
final class AgentPolicyTests: XCTestCase {

    private func action(_ operation: AgentOperation, on name: String? = nil, role: String = "button",
                        destination: String? = nil, payload: String? = nil) -> AgentAction {
        let target = name.map {
            ObservedElement(index: 0, role: role, name: $0, text: $0, href: role == "link" ? destination : nil,
                            inputType: nil, heading: nil, region: .main, inViewport: true, context: nil,
                            formAction: nil, formMethod: nil, formSubmitLabel: nil, options: nil,
                            checked: nil)
        }
        return AgentAction(operation: operation, target: target, destination: destination, payload: payload,
                           isPlannedSearch: false)
    }

    private func plannedSearch(_ address: String) -> AgentAction {
        AgentAction(operation: .open, target: nil, destination: address, payload: nil, isPlannedSearch: true)
    }

    // MARK: - Thresholds (§6.4)

    func testAConfidentChoiceActsUnlessItIsIrreversible() {
        XCTAssertEqual(AgentPolicy.decide(confidence: 0.80, risk: .alwaysReversible), .act)
        XCTAssertEqual(AgentPolicy.decide(confidence: 0.80, risk: .otherReversible), .act)
        XCTAssertEqual(AgentPolicy.decide(confidence: 1.00, risk: .irreversible), .askUser)
    }

    /// ITER-076 stage 4a (F1, the owner's copy-first rule, 2026-10-06): one line
    /// for every choice — a reference browser agent's measured
    /// `recover_below`, 0.55. From it a reversible choice acts and an
    /// irreversible one asks the user; below it every choice is reconsidered.
    func testEveryChoiceActsOrAsksFromPointFiveFiveAndIsReconsideredBelow() {
        XCTAssertEqual(AgentPolicy.actFrom, 0.55)
        let atTheLine: [(ActionRisk, StepDecision)] = [(.alwaysReversible, .act), (.otherReversible, .act),
                                                        (.irreversible, .askUser)]
        for (risk, decision) in atTheLine {
            XCTAssertEqual(AgentPolicy.decide(confidence: 0.549, risk: risk), .reconsider, "\(risk) at 0.549")
            XCTAssertEqual(AgentPolicy.decide(confidence: 0.55, risk: risk), decision, "\(risk) at 0.55")
        }
    }

    /// An irreversible step is the user's Yes at any confidence: however sure
    /// Jev is, it is asked about, never taken.
    func testAnIrreversibleChoiceAsksAtAnyConfidence() {
        for confidence in [0.55, 0.8, 0.9, 0.95, 0.99, 1.0] {
            XCTAssertEqual(AgentPolicy.decide(confidence: confidence, risk: .irreversible), .askUser, "\(confidence)")
        }
    }

    func testAWeakChoiceIsAlwaysReconsidered() {
        for risk in [ActionRisk.alwaysReversible, .otherReversible, .irreversible] {
            XCTAssertEqual(AgentPolicy.decide(confidence: 0.49, risk: risk), .reconsider)
        }
    }

    /// A malformed answer means no action (§6.3) — never an assumed yes.
    func testAMalformedConfidenceIsReconsidered() {
        for confidence in [Double.nan, .infinity, -0.1, 1.01] {
            XCTAssertEqual(AgentPolicy.decide(confidence: confidence, risk: .alwaysReversible), .reconsider)
        }
    }

    func testGoalMetCountsFromPointEight() {
        XCTAssertEqual(AgentPolicy.goalMet(noul: 0.79), false)
        XCTAssertEqual(AgentPolicy.goalMet(noul: 0.80), true)
        XCTAssertNil(AgentPolicy.goalMet(noul: nil))
        XCTAssertNil(AgentPolicy.goalMet(noul: .nan))
        XCTAssertNil(AgentPolicy.goalMet(noul: 1.2))
    }

    /// A sub-goal ends before its step acts when `goal_done` is above 0.85
    /// (ITER-076 brain, A2 P2-4) — not at it; a missing or malformed answer
    /// ends nothing.
    func testGoalDoneEndsASubgoalOnlyAboveTheLine() {
        XCTAssertTrue(AgentPolicy.subgoalDone(noul: 0.86))
        XCTAssertFalse(AgentPolicy.subgoalDone(noul: 0.85))
        XCTAssertFalse(AgentPolicy.subgoalDone(noul: nil))
        XCTAssertFalse(AgentPolicy.subgoalDone(noul: .nan))
        XCTAssertFalse(AgentPolicy.subgoalDone(noul: 1.2))
    }

    /// A second "ask again" in a row for the same step ends the run as stuck;
    /// no model decides a step instead (§6.4).
    func testTheSecondReconsiderationInARowIsStuck() {
        var step = StepAttempts()
        XCTAssertEqual(step.after(.reconsider), .reconsider)
        XCTAssertEqual(step.after(.reconsider), .stuck)
    }

    func testAnyOtherDecisionBetweenReconsiderationsResetsTheCount() {
        var step = StepAttempts()
        XCTAssertEqual(step.after(.reconsider), .reconsider)
        XCTAssertEqual(step.after(.act), .act)
        XCTAssertEqual(step.after(.reconsider), .reconsider)
        XCTAssertEqual(step.after(.askUser), .askUser)
        XCTAssertEqual(step.after(.reconsider), .reconsider)
    }

    // MARK: - Risk (§6.3, §7.1)

    func testTheLexiconAloneRequiresAYes() {
        XCTAssertEqual(AgentPolicy.risk(of: action(.click, on: "Delete account"), irreversibleNoul: 0.01),
                       .irreversible)
    }

    /// The two checks are independent (§7.1): even a planned search needs a
    /// Yes when its words are on the list.
    func testTheLexiconOutranksAlwaysReversible() {
        let search = plannedSearch("https://search.test/?q=buy+a+voice+recorder")
        XCTAssertTrue(SafetyGuard.isAlwaysReversible(search))
        XCTAssertEqual(AgentPolicy.risk(of: search, irreversibleNoul: nil), .irreversible)
    }

    func testTheRiskAnswerCountsAsYesFromPointTwo() {
        let pricing = action(.open, on: "Pricing", role: "link", destination: "https://a.test/pricing")
        XCTAssertEqual(AgentPolicy.risk(of: pricing, irreversibleNoul: 0.19), .otherReversible)
        XCTAssertEqual(AgentPolicy.risk(of: pricing, irreversibleNoul: 0.20), .irreversible)
    }

    /// A missing or malformed risk answer is never read as "safe".
    func testAMissingRiskAnswerMeansNoAction() {
        let pricing = action(.open, on: "Pricing", role: "link", destination: "https://a.test/pricing")
        for noul in [nil, Double.nan, -0.01, 1.5] {
            XCTAssertNil(AgentPolicy.risk(of: pricing, irreversibleNoul: noul))
        }
    }

    /// ITER-076 2.1: structure outranks the risk answer. Sending a POST form
    /// needs a Yes even when the model calls it safe, and even with no answer.
    func testSendingAPostFormNeedsAYesWhateverTheModelSays() {
        let target = ObservedElement(index: 0, role: "button", name: "Weiter", text: "Weiter", href: nil, inputType: nil,
                                     heading: nil, region: .main, inViewport: true, context: nil,
                                     formAction: "https://a.test/cart/step-2", formMethod: "post", formSubmitLabel: "Weiter",
                                     options: nil, checked: nil, submits: true)
        let send = AgentAction(operation: .click, target: target, destination: nil, payload: nil, isPlannedSearch: false)
        XCTAssertFalse(SafetyGuard.lexiconRequiresConfirmation(send), "structure alone decides here")
        XCTAssertEqual(AgentPolicy.risk(of: send, irreversibleNoul: 0.01, pageURL: "https://a.test/cart"), .irreversible)
        XCTAssertEqual(AgentPolicy.risk(of: send, irreversibleNoul: nil, pageURL: "https://a.test/cart"), .irreversible)
    }

    /// A danger in a language the lexicon does not read is never acted on
    /// without Jev's answer.
    func testADangerInAnotherLanguageWaitsForTheRiskAnswer() {
        let wipe = action(.click, on: "Supprimer toutes les données")
        XCTAssertNil(AgentPolicy.risk(of: wipe, irreversibleNoul: nil, pageURL: "https://a.test/"))
        XCTAssertEqual(AgentPolicy.risk(of: wipe, irreversibleNoul: 0.9, pageURL: "https://a.test/"), .irreversible)
    }

    func testAnAlwaysReversibleActionNeedsNoRiskAnswer() {
        XCTAssertEqual(AgentPolicy.risk(of: action(.back), irreversibleNoul: nil), .alwaysReversible)
        XCTAssertEqual(AgentPolicy.risk(of: plannedSearch("https://search.test/?q=voice+notes"), irreversibleNoul: nil),
                       .alwaysReversible)
    }

    // MARK: - Spend (§8)

    private let start = ContinuousClock.now

    func testTheWorstCaseIsReservedBeforeACall() {
        var budget = AgentBudget(startedAt: start)
        XCTAssertNotNil(budget.reserve(worstCaseUSD: 0.30))
        XCTAssertNil(budget.reserve(worstCaseUSD: 0.21), "0.30 + 0.21 would cross $0.50")
        XCTAssertNotNil(budget.reserve(worstCaseUSD: 0.20), "0.30 + 0.20 lands exactly on the ceiling")
    }

    /// A call that would cross the ceiling by any amount is refused: money is
    /// rounded up, never to the nearest millionth (review round 6).
    func testAWorstCaseAHairOverTheCeilingIsRefused() {
        var budget = AgentBudget(startedAt: start)
        XCTAssertNil(budget.reserve(worstCaseUSD: 0.5000004))
        XCTAssertNotNil(budget.reserve(worstCaseUSD: 0.50))
    }

    func testAMalformedWorstCaseIsNotReserved() {
        var budget = AgentBudget(startedAt: start)
        for worstCase in [Double.nan, .infinity, -0.01] {
            XCTAssertNil(budget.reserve(worstCaseUSD: worstCase))
        }
    }

    func testSettlingGivesBackWhatWasNotSpent() throws {
        var budget = AgentBudget(startedAt: start)
        let reservation = try XCTUnwrap(budget.reserve(worstCaseUSD: 0.40))
        budget.settle(reservation, actualUSD: 0.01)
        XCTAssertEqual(budget.spentUSD, 0.01, accuracy: 1e-9)
        XCTAssertNotNil(budget.reserve(worstCaseUSD: 0.45))
    }

    /// When an engine reports no usage — or nonsense — the whole reservation
    /// counts as spent (§8).
    func testMissingUsageCountsTheWholeReservation() throws {
        for actual in [nil, Double.nan, -1] {
            var budget = AgentBudget(startedAt: start)
            let reservation = try XCTUnwrap(budget.reserve(worstCaseUSD: 0.40))
            budget.settle(reservation, actualUSD: actual)
            XCTAssertEqual(budget.spentUSD, 0.40, accuracy: 1e-9)
        }
    }

    func testAReservationIsSettledOnlyOnce() throws {
        var budget = AgentBudget(startedAt: start)
        let reservation = try XCTUnwrap(budget.reserve(worstCaseUSD: 0.10))
        budget.settle(reservation, actualUSD: 0.10)
        budget.settle(reservation, actualUSD: 0.10)
        XCTAssertEqual(budget.spentUSD, 0.10, accuracy: 1e-9)
    }

    func testTheWorstCaseOfACall() {
        let cost = AgentBudget.worstCaseUSD(maxInputTokens: 10_000, maxOutputTokens: 1_000,
                                            inputUSDPerMillion: 0.5, outputUSDPerMillion: 2.0)
        XCTAssertEqual(cost, 0.007, accuracy: 1e-12)
    }

    // MARK: - Ceilings (§8)

    func testTheStepCeiling() {
        var budget = AgentBudget(startedAt: start)
        for _ in 0..<39 { budget.countStep() }
        XCTAssertNil(budget.ceiling(now: start))
        budget.countStep()
        XCTAssertEqual(budget.ceiling(now: start), .steps)
    }

    /// The step ceiling is about starting a new step: a check made inside a
    /// step leaves it out, and still sees every other ceiling.
    func testTheStepCeilingCanBeLeftOutInsideAStep() {
        var budget = AgentBudget(startedAt: start)
        for _ in 0..<40 { budget.countStep() }
        XCTAssertEqual(budget.ceiling(now: start), .steps)
        XCTAssertNil(budget.ceiling(now: start, countingSteps: false))
        XCTAssertEqual(budget.ceiling(now: start.advanced(by: .seconds(1_800)), countingSteps: false), .expiry)
    }

    /// Only the time the errand spends working counts towards 600 seconds;
    /// the run adds it stretch by stretch and leaves out waits for the user.
    func testTheActiveTimeCeilingCountsWorkNotTheWallClock() {
        var budget = AgentBudget(startedAt: start)
        budget.addActive(seconds: 599)
        XCTAssertNil(budget.ceiling(now: start.advanced(by: .seconds(899))))
        budget.addActive(seconds: 1)
        XCTAssertEqual(budget.ceiling(now: start.advanced(by: .seconds(900))), .activeTime)
    }

    func testANonsenseDurationIsIgnored() {
        var budget = AgentBudget(startedAt: start)
        budget.addActive(seconds: 599)
        budget.addActive(seconds: .nan)
        budget.addActive(seconds: -100)
        budget.addActive(seconds: 1)
        XCTAssertEqual(budget.ceiling(now: start), .activeTime)
    }

    func testTheSpendCeiling() throws {
        var budget = AgentBudget(startedAt: start)
        let first = try XCTUnwrap(budget.reserve(worstCaseUSD: 0.50))
        budget.settle(first, actualUSD: 0.49)
        XCTAssertNil(budget.ceiling(now: start))
        let last = try XCTUnwrap(budget.reserve(worstCaseUSD: 0.01))
        budget.settle(last, actualUSD: 0.01)
        XCTAssertEqual(budget.ceiling(now: start), .spend)
    }

    /// Whatever the pauses, an errand ends thirty minutes after it started.
    /// The deadline is on the continuous clock, so setting the wall clock back
    /// cannot postpone it (review round 6).
    func testTheAbsoluteExpiryFiresAnywayAfterThirtyMinutes() {
        var budget = AgentBudget(startedAt: start)
        budget.addActive(seconds: 10)
        XCTAssertNil(budget.ceiling(now: start.advanced(by: .seconds(1_799))))
        XCTAssertEqual(budget.ceiling(now: start.advanced(by: .seconds(1_800))), .expiry)
    }

    /// ITER-076 I-05: a wait for the service fits only when it ends before
    /// both time ceilings — the work's and the expiry.
    func testAWaitFitsOnlyBeforeBothTimeCeilings() {
        var budget = AgentBudget(startedAt: start)
        budget.addActive(seconds: 500)
        let now = start.advanced(by: .seconds(1_000))
        XCTAssertTrue(budget.fits(.seconds(60), now: now))
        XCTAssertFalse(budget.fits(.seconds(100), now: now), "the work's 600 seconds")
        XCTAssertFalse(budget.fits(.seconds(90), now: start.advanced(by: .seconds(1_750))), "the expiry")
        XCTAssertTrue(budget.fits(.zero, now: now))
    }

    /// Review round 1 (P2-5): what is left of the work's 600 seconds, which
    /// bounds a paid call as the expiry does.
    func testActiveTimeLeft() {
        var budget = AgentBudget(startedAt: start)
        XCTAssertEqual(budget.activeTimeLeft, .seconds(600))
        budget.addActive(seconds: 598.5)
        XCTAssertEqual(budget.activeTimeLeft, .milliseconds(1_500))
        budget.addActive(seconds: 5)
        XCTAssertEqual(budget.activeTimeLeft, .zero)
    }

    /// Review round 2 (P2-6): what is committed — spent, and the worst case
    /// of every call still out — until each call settles.
    func testCommittedSpendCountsCallsStillOut() throws {
        var budget = AgentBudget(startedAt: start)
        let plan = try XCTUnwrap(budget.reserve(worstCaseUSD: 0.02))
        XCTAssertEqual(budget.committedUSD, 0.02, accuracy: 1e-9)
        XCTAssertEqual(budget.spentUSD, 0)
        budget.settle(plan, actualUSD: 0.005)
        XCTAssertEqual(budget.committedUSD, 0.005, accuracy: 1e-9)
    }

    // MARK: - Progress (§6.5)

    func testTheSameActionThreeTimesIsStuck() {
        var progress = ProgressTracker()
        progress.record(action(.click, on: "Show more"), newRow: false, subgoalFinished: false)
        progress.record(action(.click, on: "Show more"), newRow: false, subgoalFinished: false)
        XCTAssertFalse(progress.isStuck)
        progress.record(action(.click, on: "Show more"), newRow: false, subgoalFinished: false)
        XCTAssertTrue(progress.isStuck)
    }

    /// Coming back to the same element again and again is a loop even with
    /// other steps in between.
    func testTheSameActionThreeTimesAnywhereInTheRunIsStuck() {
        var progress = ProgressTracker()
        let steps = [action(.click, on: "Site one"), action(.scroll), action(.click, on: "Site one"),
                     action(.wait)]
        for step in steps { progress.record(step, newRow: false, subgoalFinished: false) }
        XCTAssertFalse(progress.isStuck)
        progress.record(action(.click, on: "Site one"), newRow: false, subgoalFinished: false)
        XCTAssertTrue(progress.isStuck)
    }

    /// Back, scroll and wait have no identity of their own; going back after
    /// every site is how a list gets collected.
    func testBackScrollAndWaitMayRepeat() {
        var progress = ProgressTracker()
        for _ in 0..<5 { progress.record(action(.back), newRow: false, subgoalFinished: false) }
        XCTAssertFalse(progress.isStuck)
    }

    /// «More» shows the next candidates and touches nothing on the page.
    func testMoreIsAlwaysReversibleAndMayRepeat() {
        XCTAssertEqual(AgentPolicy.risk(of: action(.more), irreversibleNoul: nil), .alwaysReversible)
        var progress = ProgressTracker()
        for _ in 0..<5 { progress.record(action(.more), newRow: false, subgoalFinished: false) }
        XCTAssertFalse(progress.isStuck)
    }

    /// The same control with another option is another action: switching a
    /// pricing page between its billing periods is not a loop.
    func testTheSameElementWithANewPayloadIsANewAction() {
        var progress = ProgressTracker()
        for option in ["Monthly", "Yearly", "Lifetime"] {
            progress.record(action(.select, on: "Billing period", payload: option), newRow: false,
                            subgoalFinished: false)
        }
        XCTAssertFalse(progress.isStuck)
    }

    func testABABCycleIsStuck() {
        var progress = ProgressTracker()
        for name in ["A", "B", "A"] {
            progress.record(action(.click, on: name), newRow: false, subgoalFinished: false)
        }
        XCTAssertFalse(progress.isStuck)
        progress.record(action(.click, on: "B"), newRow: false, subgoalFinished: false)
        XCTAssertTrue(progress.isStuck)
    }

    func testEightStepsWithoutProgressIsStuck() {
        var progress = ProgressTracker()
        for index in 0..<7 {
            progress.record(action(.click, on: "Link \(index)"), newRow: false, subgoalFinished: false)
        }
        XCTAssertFalse(progress.isStuck)
        progress.record(action(.click, on: "Link 7"), newRow: false, subgoalFinished: false)
        XCTAssertTrue(progress.isStuck)
    }

    func testANewRowOrAFinishedSubgoalIsProgress() {
        for (newRow, subgoalFinished) in [(true, false), (false, true)] {
            var progress = ProgressTracker()
            for index in 0..<7 {
                progress.record(action(.click, on: "Link \(index)"), newRow: false, subgoalFinished: false)
            }
            progress.record(action(.click, on: "Result"), newRow: newRow, subgoalFinished: subgoalFinished)
            for index in 7..<14 {
                progress.record(action(.click, on: "Link \(index)"), newRow: false, subgoalFinished: false)
            }
            XCTAssertFalse(progress.isStuck, "seven steps on each side of the progress")
        }
    }

    /// A page state the errand never reached is progress for the count of steps without it — a walk over a list's
    /// pages is no stall — and the count fires anyway once steps stop reaching new states (a reference browser
    /// agent's no-progress count, `agent.py` 1081-1094, MIT).
    func testANewPageStateStartsTheStepsWithoutProgressAgainAndTheyFireAnywayAfter() {
        var progress = ProgressTracker()
        for page in 2...20 {
            progress.record(action(.open, on: "Next →", role: "link", destination: "https://site-481.test/page/\(page)/"),
                            newRow: false, subgoalFinished: false)
            progress.reachedNewState()
        }
        XCTAssertFalse(progress.isStuck, "nineteen pages, each a state never reached")
        for index in 0..<7 {
            progress.record(action(.click, on: "Link \(index)"), newRow: false, subgoalFinished: false)
        }
        XCTAssertFalse(progress.isStuck)
        progress.record(action(.click, on: "Link 7"), newRow: false, subgoalFinished: false)
        XCTAssertTrue(progress.isStuck)
    }

    /// A new page state starts only the count of steps without progress again: the same step three times is a
    /// loop whatever each one brought.
    func testANewPageStateLeavesTheSameStepThreeTimesALoop() {
        var progress = ProgressTracker()
        for _ in 0..<2 {
            progress.record(action(.click, on: "Load more"), newRow: false, subgoalFinished: false)
            progress.reachedNewState()
        }
        XCTAssertFalse(progress.isStuck)
        progress.record(action(.click, on: "Load more"), newRow: false, subgoalFinished: false)
        XCTAssertTrue(progress.isStuck)
    }

    func testEightStepsWithoutProgressFiresAnywayAfterEarlierProgress() {
        var progress = ProgressTracker()
        for index in 0..<7 {
            progress.record(action(.click, on: "Link \(index)"), newRow: false, subgoalFinished: false)
        }
        progress.record(action(.click, on: "Result"), newRow: true, subgoalFinished: false)
        for index in 7..<14 {
            progress.record(action(.click, on: "Link \(index)"), newRow: false, subgoalFinished: false)
        }
        XCTAssertFalse(progress.isStuck)
        progress.record(action(.click, on: "Link 14"), newRow: false, subgoalFinished: false)
        XCTAssertTrue(progress.isStuck)
    }

    /// A button pressed once per search, each search bringing a row, is not
    /// a loop: progress starts the repeat count again — and does not switch
    /// the rule off.
    func testProgressStartsTheRepeatCountAgainAndItFiresAnywayAfter() {
        var progress = ProgressTracker()
        for (index, query) in ["voice notes", "meeting notes", "dictation"].enumerated() {
            progress.record(action(.type, on: "Search", payload: query), newRow: false, subgoalFinished: false)
            progress.record(action(.click, on: "Go"), newRow: false, subgoalFinished: false)
            progress.record(action(.open, on: "Result \(index)", role: "link", destination: "https://site-\(index).test/"),
                            newRow: true, subgoalFinished: false)
        }
        XCTAssertFalse(progress.isStuck, "Go three times, a row after each")
        progress.record(action(.click, on: "Go"), newRow: false, subgoalFinished: false)
        progress.record(action(.click, on: "Go"), newRow: false, subgoalFinished: false)
        XCTAssertFalse(progress.isStuck)
        progress.record(action(.click, on: "Go"), newRow: false, subgoalFinished: false)
        XCTAssertTrue(progress.isStuck)
    }

    func testProgressBreaksACycleAndItFiresAnywayAfter() {
        var progress = ProgressTracker()
        progress.record(action(.click, on: "Monthly"), newRow: false, subgoalFinished: false)
        progress.record(action(.click, on: "Yearly"), newRow: false, subgoalFinished: false)
        progress.record(action(.click, on: "Plans table"), newRow: true, subgoalFinished: false)
        progress.record(action(.click, on: "Monthly"), newRow: false, subgoalFinished: false)
        progress.record(action(.click, on: "Yearly"), newRow: false, subgoalFinished: false)
        XCTAssertFalse(progress.isStuck, "the row came between the two halves")
        progress.record(action(.click, on: "Monthly"), newRow: false, subgoalFinished: false)
        progress.record(action(.click, on: "Yearly"), newRow: false, subgoalFinished: false)
        XCTAssertTrue(progress.isStuck)
    }
}
