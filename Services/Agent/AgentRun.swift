import Foundation

/// Runs one errand end to end (ITER-074 §4, §6): plan, observe, build the
/// candidates, decide, guard, act, verify, record — until the plan's rows are
/// in, or a ceiling, Stop, stuck, a wall or the agent's service ends it. Then
/// the rows go into a new Sheet and are read back. The decision engine picks
/// every step — no LLM ever does — and the agent acts only in the tab it
/// opened. The errand service drives it as an `ErrandRunner` (ITER-076 I-05):
/// it reports its progress, keeps every row in its record the moment it is
/// added, and ends with the real reason.
@MainActor
final class AgentRun: ErrandRunner {
    struct Collaborators {
        let bridge: any BrowserBridge
        let engine: any DecisionEngine
        /// The rows writer and the Sheet of a rows errand; none in the app,
        /// which runs answer errands only (ITER-076 stage 1).
        let writer: (any TextWriter)?
        let sheet: (any SheetDestination)?
        /// Asks the user about one irreversible action (§7.1); nil when no
        /// answer came. The run gives it the answer window and no more.
        let confirm: @MainActor @Sendable (ConfirmationRequest) async -> ConfirmationRequest.Answer?
        /// Hears that the errand's Sheet exists, once, as soon as it does —
        /// after Stop too (review round 2, P2-1).
        var sheetMade: @MainActor @Sendable (URL) -> Void = { _ in }
        /// Where each event of the errand is said as it is kept (ITER-076
        /// I-06a): the app's log, unless the service gives its own.
        var log: @MainActor @Sendable (String) -> Void = { NSLog("%@", $0) }
        /// The text model of an answer errand (ITER-076 brain): its sub-goals
        /// and its fields' text. None in a rows errand.
        var model: ErrandModel? = nil
        /// Waits for the user to do their part in the errand's tab, within the
        /// window given (ITER-076 stage 3): true once they said Continue.
        /// Without a service, no one says it.
        var waitForUser: @MainActor @Sendable (ErrandHandover, BrowserTab, Duration) async -> Bool = { _, _, _ in false }
        /// What the user asked the errand to give (ITER-076 stage 6).
        var output: ErrandOutput = .answer
        /// Hears that the owner switched the agent off on the server
        /// (ITER-076 stage 9d, № 27): the errand ends stopped.
        var switchedOff: @MainActor @Sendable () -> Void = {}
        /// The user's own details a web form is filled from (ITER-076 stage
        /// 7), read when a form is met; none without them.
        var facts: @MainActor @Sendable () -> FormFacts = { .none }
        /// The model that decides every step itself (owner decision of 2026-10-19): with one, the errand is the
        /// brain's — no plan, no sub-goals, no step of Jev's; the rails, the eyes and the hands stay the run's own.
        var brain: (any Brain)? = nil
    }

    /// The header of an answer errand's Sheet (ITER-076 stage 6, № 169): each
    /// row under it is one item of the answer — its quote, then its page's
    /// address. The words the owner approved on 2026-10-06.
    static let sheetHeader = ["Result", "Source"]
    /// When a written Sheet is read back (ITER-076 stage 6, № 171): at once,
    /// then a few seconds apart, about 14 s in all — never a fast poll, which
    /// Google's export answers with 429 (the live probe of 2026-10-06).
    static let sheetReads: [Duration] = [.zero, .seconds(2), .seconds(4), .seconds(8)]

    /// Deadlines of §8, placeholders until phase 0 measures them.
    nonisolated static let decisionDeadline: Duration = .seconds(10)
    static let writerDeadline: Duration = .seconds(30)
    /// A plan is a text model's call, as a row is.
    nonisolated static let planDeadline: Duration = .seconds(30)
    /// The text model's other calls — a sub-goal, a field's text — as a plan
    /// (ITER-076 brain).
    nonisolated static let modelDeadline: Duration = .seconds(30)
    /// The brain's call (owner decision of 2026-10-19): a whole page and the errand's history, as one step.
    nonisolated static let brainDeadline: Duration = .seconds(90)
    /// How much of a page the brain's reads take in, at most (`search_page`, `extract`).
    static let brainReadLimit = 120_000
    /// Where an answer errand starts (ITER-076 brain, the orchestrator's
    /// default of 2026-10-05): a search engine's home page, opened by the app;
    /// the model never writes an address. DuckDuckGo since 2026-10-15: Google
    /// answered the agent's own browser with a CAPTCHA on every search of the
    /// live run (L05, L06) and the bench (the jokes, the competitors) — the
    /// user's part, and the errand stopped; DuckDuckGo's search ran (L05D).
    nonisolated static let startPage = URL(string: "https://duckduckgo.com/")!

    /// Where an answer errand begins when its goal names a website (2026-10-07; the owner: capability first): the
    /// first web address the goal names that the agent may open — a link as the user wrote it, a bare host over
    /// https — found as the system finds links in text. "Start at https://pypi.org/. …" began on the search engine
    /// and had to find the site first. Nil: the start page.
    nonisolated static func firstAddress(in goal: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for match in detector.matches(in: goal, range: NSRange(goal.startIndex..., in: goal)) {
            guard var url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let written = Range(match.range, in: goal) else { continue }
            if !goal[written].contains("://"), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                parts.scheme = "https"
                url = parts.url ?? url
            }
            if DiaScript.isOpenable(url) { return url }
        }
        return nil
    }
    /// The most sub-goals an answer errand asks the model for (ITER-076 A4).
    static let maxSubgoals = 15
    /// The most times the text model names an errand's step for Jev (2026-10-15): a reference browser agent
    /// recovers at most twice a run (`StallRules.max_recoveries`, MIT); an errand runs several sub-goals.
    static let maxRecoveries = 4
    /// The most times an errand rejects the model's end — a reply without a call while something is still to do —
    /// and asks again (2026-10-15): the 10-15 bench's model answered from memory on its first "I can't".
    static let maxRejections = 2
    /// The most steps one sub-goal takes (ITER-076 A4: the reference tool's
    /// default of 10 actions a call).
    static let actionsPerSubgoal = 10
    /// The most reads of the page an answer errand makes — one a chunk
    /// (ITER-076 A4).
    static let maxReads = 16
    /// The most next pages code opens to walk a list, an errand — a reference browser agent's `max_pages`
    /// (`config.py` 124), which counts the pages followed: the page the walk starts from is read before it, so a
    /// walk reads at most `maxPages` + 1 pages (Codex review of 2026-10-18, P1-2: the words said pages walked).
    static let maxPages = 12
    /// How long a page still loading is waited on once more when Jev is unsure on it (2026-10-16).
    static let loadingOutwait: Duration = .seconds(10)
    /// The most reads of one page state, for one set of requirements still to find, that add nothing (a
    /// reference browser agent's `StallRules.barren_reads`, MIT).
    static let barrenReads = 2
    /// How long the run waits, once, for a decision service that is down or
    /// late and did not say how long (ITER-076 I-05); a placeholder until
    /// phase 0 measures it.
    static let serviceRetryWait: Duration = .seconds(2)
    /// After Stop, `run` returns within this (ITER-076 I-05, review round 1):
    /// one call's deadline. What is left of it bounds, as a whole, the check
    /// of an action already sent and the close of the tab.
    nonisolated static let stopLimit: Duration = .seconds(10)
    /// A page that has not loaded within this is a miss (§11).
    static let pageDeadline: Duration = .seconds(15)
    /// The wait operation (§6.2).
    static let waitStep: Duration = .seconds(2)
    /// The most dialogs a page may show while one step acts and looks before
    /// the errand ends stuck: a page that shows them in a loop never holds it
    /// (ITER-076 I-09).
    static let dialogLimit = 10
    static let excerptLimit = 3_000
    /// How long the errand waits for the user's part (ITER-076 stage 3, owner
    /// decision 6): ten minutes, never past the expiry.
    nonisolated static let pauseWindow: Duration = .seconds(600)
    /// How long a check that may clear itself is waited out before it is the
    /// user's part, and how often the page is looked at meanwhile (a reference
    /// browser agent's `_INTERSTITIAL_SECONDS` and `_INTERSTITIAL_POLL_SECONDS`,
    /// `agent.py` 126-131, MIT).
    nonisolated static let checkWait: Duration = .seconds(12)
    static let checkPoll: Duration = .milliseconds(500)

    private let goal: String
    private let planner: any ErrandPlanner
    private let parts: Collaborators
    private(set) var record: ErrandRecord
    private var scratchpad: Scratchpad
    private var budget: AgentBudget
    private var progress = ProgressTracker()
    private var attempts = StepAttempts()
    private let startPage: URL
    /// The sub-goal the steps work toward in an answer errand (ITER-076
    /// brain); nil in a rows errand.
    private var named: NamedSubgoal?
    /// A read belongs to its source and the information still needed: equal
    /// text elsewhere, or for a different requirement, is not a duplicate.
    private struct ReadKey: Hashable {
        let url: String
        let text: String
        let requirements: [String]
    }
    /// How many reads of each page state, for its set of requirements still to find, added nothing: one that
    /// added a fact or a statement is never read again; a barren one may be read again, up to `barrenReads` in all
    /// (2026-10-15: the reader missed a heading its page showed, and the page, read once, was never read again).
    private var readPages: [ReadKey: Int] = [:]
    private var reads = 0
    /// The information requirements the verifier's last verdict named — or
    /// all of them, when it said not complete naming none of the plan's —
    /// which no read has given a new claim since: still to find, though facts
    /// answer them (ITER-076, live 2026-10-06 23:40).
    private var unconfirmed: Set<String> = []
    /// What the verifier's last no named beyond the information still to find (2026-10-15): the action requirements
    /// it named missing, by id in the plan's order, and the information requirements it named as read off a page that
    /// is not the one the task describes. The model hears both in its next result and in a rejected end.
    private var namedActions: [String] = []
    private var misread: Set<String> = []
    /// The run as the verifier last judged it — the facts, the statements, the steps and the page — when it said
    /// no: the same run is not asked about again, its no stands (2026-10-15).
    private var judged: [String]?
    /// How many times the model's end of the errand was rejected (2026-10-15): at most `maxRejections`, then the
    /// errand ends not finished.
    private var rejections = 0
    /// Jev unsure (2026-10-15): the page states an unsure pick was tried on, once each; every action taken, by the
    /// page state it was taken from; the times the text model named the step, and what it said each time, for the
    /// next (`_try_unsure`, `_recover`, a reference browser agent's `agent.py`, MIT).
    /// The requirements whose list the last read saw go on past its page, each with the label of the control that
    /// shows the rest when the reader named one (2026-10-15; a reference browser agent's `continuing`, MIT): still
    /// to find, whatever their facts, until a read no longer says so.
    private var continuing: [String: String?] = [:]
    /// The page the last read saw a list go on at, by its shown address: the control it named is taken there only
    /// (Codex review, P2-4).
    private var continuingAt: String?
    /// How many next pages code opened this errand (`maxPages`).
    private var pagesFollowed = 0
    private var triedUnsure: Set<String> = []
    /// The page states waited on once more because they still showed a loading indicator (2026-10-16).
    private var outwaitedLoading: Set<String> = []
    /// The page states Jev's DONE or BLOCKED was doubted on once (2026-10-15): the second doubt there asks the
    /// recovery.
    private var doubtedEnds: Set<String> = []
    private struct TakenFrom: Hashable {
        let page: String
        let effect: AgentAction.Effect
    }
    private var takenFrom: Set<TakenFrom> = []
    /// What the brain typed, by the field's fingerprint: a site's search box holding these words is the brain's
    /// search (D4, 2026-10-19).
    private var brainTyped: [String: String] = [:]
    /// The table the brain's done gave, in a table errand (2026-10-20).
    private var brainTable: BrainTable?
    /// The last step taken, till the next look tells whether its page state changed (2026-10-16).
    private var pendingIdle: TakenFrom?
    /// Steps that changed nothing from the page state they were taken on, each told to the text model once if
    /// taken from it again (2026-10-16; a reference browser agent's `attempted.idle`, `agent.py` 778-788, MIT).
    private var idleFrom: Set<TakenFrom> = []
    private var recoveries = 0
    private var recoveryMemory: [String] = []
    /// Every page the errand looked at, by the address it shows, once each,
    /// in order: the addresses the verifier reads as visited — never where
    /// the tab really is (ITER-076 stage 1, № 91).
    private var pagesSeen: [String] = []
    /// The last page a step looked at.
    private var lastPage: ObservedPage?
    /// The actions the user said No to — or let the question lapse on — by
    /// the page they were asked on, as a server sees its address: never
    /// offered there again in this errand (ITER-076 I-05).
    private var refused: [String: Set<AgentAction.Effect>] = [:]
    /// The cookie windows' controls this errand clicked, by the page each
    /// was clicked on (ITER-076 stage 3): never clicked again there.
    private var cookiesClicked: [String: Set<AgentAction.Effect>] = [:]
    /// Every search address this errand sent (D4, ITER-076 stage 3): none is
    /// sent twice.
    private var searchesSent: Set<String> = []
    /// Why the errand failed, once a failure ends it.
    private var failure: ErrandRecord.Failure?
    /// How the errand's Sheet failed, when it did (ITER-076 stage 6).
    private var sheetFailure: ErrandOutcome.SheetFailure?
    /// When the agent's service may be asked again, when it said.
    private var retryAt: Date?
    /// Hears the errand's progress while it runs.
    private var report: (@MainActor (ErrandProgress) -> Void)?
    /// Where each document the tab showed at a step's look was loaded from,
    /// as a server sees it (ITER-076 I-10): BACK goes only to an entry of the
    /// tab's own history at one of these — never to an address a page wrote
    /// into its history by itself (ITER-076 2.2, S1).
    private var loaded: Set<String> = []
    /// Every address opened with the user's Yes in this errand, and every
    /// document a step with the user's Yes led to, as a server sees it: back
    /// never asks for one again, however the loop reached it.
    private var approvedAddresses: Set<String> = []
    /// Where the document the last step with the user's Yes acted on was
    /// loaded from, until the next look: another document there is where the
    /// Yes led (ITER-076 I-10).
    private var approvedFrom: String?
    /// The option this errand chose in each select and saw held, by the
    /// select's identity on the page it was chosen on: what the loop did
    /// itself, beside the option a select reports as its value (owner decision
    /// 4). Each step checks every remembered choice again in the page, and a
    /// select offers neither.
    private var chosenOptions: [ElementIdentity: String] = [:]
    /// The forms this errand previewed (ITER-076 stage 7), by their group on
    /// the document they were met on: a field of one is typed only by its
    /// Fill (№ 57), and a click that may send one asks the Yes bound to its
    /// values (№ 93).
    private var forms: [FormKey: FormState] = [:]
    /// The tab whose sends are held from a form's Fill (`BrowserBridge
    /// .holdSends`; review rounds 1 and 2, C2, R2-2) — until the Send's
    /// approved press, the user's part, Stop or the errand's end, or until
    /// the tab shows another document than the form's — the document the
    /// form was filled on, and whether a send was held back meanwhile.
    private var heldTab: BrowserTab?
    private var heldDocument: String?
    private var sendHeld = false
    /// Every value a form of this errand showed — Fill's, and what a Send
    /// showed: never kept in an address a record, a link or a log keeps
    /// (review round 2, R2-5).
    private var shownValues: [String] = []
    private var stopRequested = false
    /// The last actions and whether each changed the page, for the step's
    /// question only (ITER-076 1.3b): the record keeps no page words.
    private var recent = RecentActions()
    /// Steps asked so far; `stuck` counts from the third (ITER-076 1.3, B).
    private var stepsAsked = 0
    /// What the engine answered this step, when it was asked: its own
    /// numbers go on record with the step (ITER-076 stage 4a).
    private var engineAnswer: ChooseAnswer?
    /// What the last look saw: its address and its elements' fingerprints.
    private var lastPageKey: String?
    /// The page states this errand's looks reached (`stateKey`): one never reached before is progress.
    private var statesReached: Set<String> = []
    private var stepCost = 0.0
    /// What the tab did on its own while this step acted and looked (ITER-076
    /// I-09): the page's dialogs, and whether a download or an address was
    /// refused.
    private var dialogsThisStep = 0
    /// The last click's check saw only a box the page brought over itself (`verify`): its answer, not the proof a send
    /// landed.
    private var answeredOnlyByABox = false
    private var refusedThisStep = false
    /// A confirm, a prompt or a "Leave the page?" came after this step's act
    /// went out and was answered Cancel, or Stay: what the act was to do did
    /// not happen (Codex review 1 of I-09, P1-3).
    private var declinedThisStep = false
    /// What a page's own dialog asked for that is the user's part, once one
    /// did (review of I-09, F4): the errand ends there, at the next look.
    private var dialogNamed: ErrandHandover.Kind?
    /// The tab the errand acts in, once it is open: Stop takes its Yes back
    /// there at once (review of I-09, F2).
    private var openTab: BrowserTab?
    private let workClock = SuspendingClock()
    private var lastCheckpoint: SuspendingClock.Instant
    private var waitedSinceCheckpoint: Duration = .zero
    private let limits: AgentBudget.Limits
    /// The errand's own task: Stop cancels it, so a call or a question in
    /// flight ends at once.
    private var work: Task<ErrandRecord.Ending, Never>?
    private let stopLimit: Duration
    private var stopLimitPassed = false
    /// A question is out to the user and no answer is on record yet: Stop
    /// closes it on record at once (ITER-076 I-06a review, round 2).
    private var questionOpen = false
    /// Waits that end once Stop's limit has run out.
    private var stopWaits: [UUID: @MainActor () -> Void] = [:]

    /// A ceiling was reached right before an effect (§8).
    private struct CeilingReached: Error {}

    /// How long a question waits for the user (§7.1): silence past it is a
    /// No, and the errand goes on without the action.
    private let answerWindow: Duration
    /// How long the user's part is waited for, and a check that may clear
    /// itself waited out (ITER-076 stage 3); tests lower them.
    private let pauseWindow: Duration
    private let checkWait: Duration

    init(goal: String, planner: any ErrandPlanner, errandID: UUID, collaborators: Collaborators,
         answerWindow: Duration = .seconds(ConfirmationRequest.answerWindow),
         limits: AgentBudget.Limits = .standard, stopLimit: Duration = AgentRun.stopLimit,
         startPage: URL = AgentRun.startPage, pauseWindow: Duration = AgentRun.pauseWindow,
         checkWait: Duration = AgentRun.checkWait) {
        self.answerWindow = answerWindow
        self.pauseWindow = pauseWindow
        self.checkWait = checkWait
        self.goal = goal
        self.planner = planner
        parts = collaborators
        record = ErrandRecord(errandID: errandID, goal: goal)
        scratchpad = Scratchpad(columns: [], emptyCell: "")
        self.limits = limits
        self.stopLimit = stopLimit
        budget = AgentBudget(startedAt: .now, limits: limits)
        lastCheckpoint = SuspendingClock.now
        self.startPage = startPage
    }

    /// The factory the app gives `AgentService`: each errand's run, made from
    /// its setup — its id, its words, its browser and its question to the
    /// user — with the planner, the engine, the writer and the Sheet, the text
    /// model of an answer errand and where it starts.
    static func factory(planner: any ErrandPlanner, engine: any DecisionEngine, writer: (any TextWriter)?,
                        sheet: (@MainActor (any BrowserBridge) -> any SheetDestination)?, model: ErrandModel? = nil,
                        startPage: URL = AgentRun.startPage, stopLimit: Duration = AgentRun.stopLimit,
                        facts: @escaping @MainActor @Sendable () -> FormFacts = { .none }) -> ErrandRunnerFactory {
        { setup in
            AgentRun(goal: setup.goal, planner: planner, errandID: setup.id,
                     collaborators: Collaborators(bridge: setup.bridge, engine: engine, writer: writer,
                                                  sheet: sheet?(setup.bridge), confirm: setup.confirm,
                                                  sheetMade: setup.sheetMade, log: setup.log, model: model,
                                                  waitForUser: setup.waitForUser, output: setup.output,
                                                  switchedOff: setup.switchedOff, facts: facts),
                     stopLimit: stopLimit, startPage: setup.start ?? startPage)
        }
    }

    /// The app's runs (ITER-076 stage 1, № 14): Jev through the Pro server
    /// picks every step; the plan, the sub-goals, a field's text, the reader
    /// and the verifier are the text model's, through the Pro client. An
    /// answer errand needs no rows writer: no plan the text model writes asks
    /// for rows. Its Sheet, when the user asked for a table, is a new Google
    /// Sheet in the errand's own browser (ITER-076 stage 6). A web form is
    /// filled from the user's confirmed memories and Pro e-mail (stage 7).
    static func answering(client: ProLLMClient = ProLLMClient(), engine: any DecisionEngine = JevDecisionEngine(),
                          startPage: URL = AgentRun.startPage,
                          sheet: @escaping @MainActor (any BrowserBridge) -> any SheetDestination = {
                              GoogleSheet(bridge: $0)
                          },
                          facts: @escaping @MainActor @Sendable () -> FormFacts = { FormFacts.app() })
        -> ErrandRunnerFactory {
        factory(planner: TextPlanner(client: client), engine: engine, writer: nil, sheet: sheet,
                model: ErrandModel(client: client), startPage: startPage, facts: facts)
    }

    /// The brain's runs (owner decision of 2026-10-19): one model decides every step through `brain`; Jev answers
    /// the risk of what is not always reversible — the second lock; the user's details come from `facts`. A table
    /// the user asked for goes to a new Google Sheet in the errand's own browser, as the step pipeline's does.
    static func thinking(brain: @escaping @MainActor () -> any Brain, engine: any DecisionEngine = JevDecisionEngine(),
                         startPage: URL = AgentRun.startPage,
                         sheet: @escaping @MainActor (any BrowserBridge) -> any SheetDestination = {
                             GoogleSheet(bridge: $0)
                         },
                         facts: @escaping @MainActor @Sendable () -> FormFacts = { FormFacts.app() })
        -> ErrandRunnerFactory {
        { setup in
            var parts = Collaborators(bridge: setup.bridge, engine: engine, writer: nil, sheet: sheet(setup.bridge),
                                      confirm: setup.confirm,
                                      sheetMade: setup.sheetMade, log: setup.log, model: nil,
                                      waitForUser: setup.waitForUser, output: setup.output,
                                      switchedOff: setup.switchedOff, facts: facts)
            parts.brain = brain()
            return AgentRun(goal: setup.goal, planner: TextPlanner(client: ProLLMClient()), errandID: setup.id,
                            collaborators: parts, startPage: setup.start ?? startPage)
        }
    }

    /// Stop (§7.4): no further call is made and nothing more is sent to a
    /// page — checked before every call and every act, and a call or a
    /// question in flight is cancelled. What follows — the check of an action
    /// already sent, the tab's close — has what is left of Stop's limit, and
    /// `run` returns by then (ITER-076 I-05). The step's Yes ends at Stop,
    /// not at the step's end: a dialog the page shows from then on is Cancel,
    /// or Stay (review of I-09, F2).
    func stop() {
        work?.cancel()
        guard !stopRequested else { return }
        stopRequested = true
        if let openTab { parts.bridge.approve(nil, in: openTab) }
        // A question open now is closed on record before this returns: the
        // service saves the record right after — and the app may exit then —
        // so it is not left for the run's task, which ends later (I-06a
        // review, round 2). That task adds no second closing.
        if questionOpen { closeQuestion(.stopped) }
        let deadline = ContinuousClock.now + stopLimit
        Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            self?.stopLimitRanOut()
        }
    }

    private func stopLimitRanOut() {
        stopLimitPassed = true
        let waits = stopWaits.values
        stopWaits = [:]
        for end in waits { end() }
    }

    /// `task`'s value — or nil once Stop's limit has run out first. Before
    /// Stop, as long as the task takes.
    private func untilStopLimit<T: Sendable>(_ task: Task<T, Never>) async -> T? {
        guard !stopLimitPassed else { return nil }
        let id = UUID()
        let once = ResumeOnce<T?>()
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            once.continuation = continuation
            stopWaits[id] = { once.resume(nil) }
            Task { @MainActor in once.resume(await task.value) }
        }
        stopWaits[id] = nil
        return value
    }

    /// Says how the errand goes — never once Stop was pressed (ITER-076
    /// I-05, review round 1).
    private func tell(_ progress: ErrandProgress) {
        guard !stopRequested else { return }
        report?(progress)
    }

    /// Runs the errand to its end and says how it ended: its ending, the
    /// answer its facts make, every row's and fact's page, the rows, the
    /// Sheet, why it failed or when the agent's service may be asked again,
    /// and how its Sheet failed — but after Stop, which is no failure.
    func run(report: @escaping @MainActor (ErrandProgress) -> Void) async -> ErrandOutcome {
        self.report = report
        defer { self.report = nil }
        budget = AgentBudget(startedAt: .now, limits: limits)
        lastCheckpoint = workClock.now
        record.spentUSD = 0
        var ending = ErrandRecord.Ending.stopped
        if !stopping {
            let body = Task { await self.errand() }
            work = body
            ending = await untilStopLimit(body) ?? .stopped
            work = nil
        }
        let final = stopRequested ? .stopped : ending
        finish(final)
        return ErrandOutcome(ending: final, answer: record.answer, sources: record.sources, sheet: record.sheet,
                             rows: record.rows.count, failure: record.failure,
                             retryAt: final == .dailyLimit || final == .unavailable ? retryAt : nil,
                             sheetFailure: final == .stopped ? nil : sheetFailure, form: record.form)
    }

    /// The errand in its own task — the plan and the Sheet included — which
    /// Stop cancels.
    private func errand() async -> ErrandRecord.Ending {
        if let brain = parts.brain { return await brainErrand(brain) }
        // The plan, written once from the user's words before any page is
        // read (ITER-074 §3.1), and paid for like any other call (§8) — on
        // record however it went (ITER-076 I-06a).
        let planning = ContinuousClock.now
        stepCost = 0
        var planned: AgentPlan?
        // What the model's service said instead of a plan is the errand's own
        // end — no Pro, the day's limit, a service down once waited for —
        // never a failed plan (ITER-076 brain, G5).
        var refused: ErrandRecord.Ending?
        let asked: ErrandRecord.Event.Plan
        do {
            switch try await askEngine(planner.worstCaseUSD(goal: goal), within: Self.planDeadline, usage: { $0.usage },
                                       { [goal, planner] in try await planner.plan(goal: goal) }) {
            case .answered(let made): (planned, asked) = (made, .ok)
            case .missed: asked = .failed
            case .ended(let ending): (refused, asked) = (ending, ending == .ceiling ? .ceiling : .failed)
            }
        } catch is CeilingReached {
            asked = .ceiling
        } catch {
            asked = stopping ? .stopped : .failed
        }
        note(.plan(asked, milliseconds: Self.milliseconds(since: planning), costUSD: stepCost))
        guard let plan = planned else {
            if let refused { return refused }
            switch asked {
            case .ceiling: return .ceiling
            case .stopped: return .stopped
            case .ok, .failed, .timedOut: return fail(.planFailed)
            }
        }
        // A rows plan starts at its first search; an answer plan at the start
        // page, its title the user's own words, with no number of rows to
        // reach (ITER-076 brain).
        let rows = plan.asksForRows
        if rows { scratchpad = Scratchpad(columns: plan.columns, emptyCell: plan.emptyCell) }
        tell(.working(title: rows ? plan.sheetTitle : goal, done: 0, wanted: rows ? plan.rowsWanted : nil))
        let start = rows ? plan.searches[0] : Self.firstAddress(in: goal) ?? startPage
        let tab: BrowserTab
        do {
            try checkpoint()
            tab = try await parts.bridge.openTab(start)
            openTab = tab
        } catch is CeilingReached {
            return .ceiling
        } catch {
            return stopping ? .stopped : fail(.openFailed)
        }
        var ending: ErrandRecord.Ending
        do {
            // A start address that lands on another site — a consent or a
            // regional page — is read as it loaded, and the rules that hold on
            // every page decide what follows (ITER-076 I-05).
            if try await settle(tab, leaving: nil, on: .anyWebPage) {
                ending = try await rows ? loop(in: tab, plan: plan) : subgoals(in: tab, plan: plan)
            } else {
                ending = stopping ? .stopped : fail(.neverSettled)
            }
            // An errand that finished on its last step still ends at a ceiling
            // reached on the way (§8).
            if ending == .done || ending == .stuck || ending == .notFinished { try checkpoint() }
        } catch is CeilingReached {
            ending = .ceiling
        } catch {
            ending = stopping ? .stopped : Self.isLost(error) ? lost(error) : fail(.neverSettled)
        }
        // The tab is closed after Stop too, within what is left of its limit —
        // its sends no longer held: a tab left open is the user's.
        await releaseSends()
        let bridge = parts.bridge
        _ = await untilStopLimit(Task { try? await bridge.closeTab(tab) })
        // The Sheet (ITER-076 stage 6): a rows plan's rows; an answer errand's
        // items under a header, only when the user asked for a table. Written
        // when the errand ended by itself with something to write — done, not
        // finished, stuck, or at a ceiling: what was collected (owner default
        // 6.1) — never after Stop. However the Sheet goes, the errand keeps its
        // ending and its answer; a failure of the Sheet is named beside (P1-7).
        let items = rows ? scratchpad.rows.map(\.cells) : parts.output == .sheet
            ? record.answerItems(endingAs: ending).map { [$0.quote, $0.url] } : []
        guard [.done, .notFinished, .stuck, .ceiling].contains(ending), !items.isEmpty else { return ending }
        sheetFailure = await writeSheet(rows ? items : [Self.sheetHeader] + items, title: rows ? plan.sheetTitle : goal,
                                        empty: plan.emptyCell)
        return ending
    }

    // MARK: - The loop

    private var stopping: Bool { stopRequested || Task.isCancelled }

    /// The rows are in the record already: each went in as it was added.
    /// A failure is kept only with the ending it caused.
    private func finish(_ ending: ErrandRecord.Ending) {
        record.end(ending, failure: ending == .failed || ending == .unavailable ? failure : nil).map(parts.log)
    }

    /// Keeps `event` in the record and says it in the log (ITER-076 I-06a).
    private func note(_ event: ErrandRecord.Event) {
        parts.log(record.note(event))
    }

    /// Keeps what the tab did on its own since it was last asked (ITER-076
    /// I-09) — of a page's dialogs, no more than one past the step's limit —
    /// and counts it toward the step; and what a dialog asked for that is the
    /// user's part, which ends the errand at the next look (review of I-09,
    /// F4).
    private func noteTabEvents(_ tab: BrowserTab) {
        for event in parts.bridge.events(in: tab) {
            switch event {
            case .dialog(let kind, let accepted):
                dialogsThisStep += 1
                if !accepted, kind != .alert { declinedThisStep = true }
                if dialogsThisStep <= Self.dialogLimit + 1 { note(.dialog(kind, accepted: accepted)) }
            case .downloadRefused:
                refusedThisStep = true
                note(.downloadRefused)
            case .addressRefused:
                refusedThisStep = true
                note(.addressRefused)
            case .dialogNamed(let kind):
                dialogNamed = dialogNamed ?? kind
            case .sendHeld:
                // Not on record: what a form's Fill met (review round 1, C2).
                sendHeld = true
            }
        }
    }

    /// The tab's sends go out as ever again (review rounds 1 and 2, C2,
    /// R2-2): at the Send's approved press, when the tab is the user's, when
    /// the errand ends — Stop too — and once the tab shows another document
    /// than the filled form's: the agent's own navigation took it away.
    private func releaseSends() async {
        guard let tab = heldTab else { return }
        (heldTab, heldDocument) = (nil, nil)
        _ = await parts.bridge.holdSends(false, in: tab)
    }

    /// The agent's own act that takes the tab to `address` — an open, Back, a
    /// link, a window's address — goes while the tab's sends are held
    /// (review round 2, R2-2); the rest of what the tab sends stays held.
    private func navigatesAway(to address: String?, in tab: BrowserTab) {
        guard heldTab != nil, let address else { return }
        parts.bridge.letNavigate(to: address, in: tab)
    }

    /// The errand fails for `kind`.
    private func fail(_ kind: ErrandRecord.Failure) -> ErrandRecord.Ending {
        failure = kind
        return .failed
    }

    /// How the errand ends with the browser gone for it (`isLost`): its own
    /// tab closed is the user's stop (ITER-076 stage 8a, № 117) — the bridge
    /// says `tabNotFound` of that tab alone, a frame gone being a failed
    /// script — and the connection gone is a failure.
    private func lost(_ error: any Error) -> ErrandRecord.Ending {
        error as? BrowserBridgeError == .tabNotFound ? .stopped : fail(.bridgeLost)
    }

    /// The browser is gone for this errand: the connection, or its tab.
    static func isLost(_ error: any Error) -> Bool {
        error as? BrowserBridgeError == .connectionLost || error as? BrowserBridgeError == .tabNotFound
    }

    private func loop(in tab: BrowserTab, plan: AgentPlan) async throws -> ErrandRecord.Ending {
        while scratchpad.rows.count < plan.rowsWanted {
            try checkpoint(countingSteps: true)
            switch try await stepOrMiss(in: tab, plan: plan) {
            case nil: continue
            case .errand(let ending)?: return ending
            // What a step works toward in a rows errand is the errand itself.
            case .subgoal(.done)?: return .done
            case .subgoal?: return .stuck
            }
        }
        return .done
    }

    /// What a step came to when the work does not go on with the next one
    /// (ITER-076 brain): the errand's end; or the end of what the step worked
    /// toward — in an answer errand its sub-goal, in a rows errand the errand
    /// itself, done or else stuck.
    private enum StepEnd: Equatable {
        case errand(ErrandRecord.Ending)
        case subgoal(ErrandModel.Status)
    }

    /// One step, or the miss a failed look is.
    private func stepOrMiss(in tab: BrowserTab, plan: AgentPlan) async throws -> StepEnd? {
        do {
            return try await step(in: tab, plan: plan)
        } catch let error where error is CeilingReached || error is CancellationError {
            throw error
        } catch where stopping {
            // A call Stop cut short is no miss: the errand ends.
            throw CancellationError()
        } catch let error where Self.isLost(error) {
            return .errand(lost(error))
        } catch {
            // A look that failed — a script that threw, a report that is
            // not one — is a miss, not the errand's end (plan 2.4 L4): the
            // page settles, is read again, and the miss counts toward the
            // reconsider limit. Nothing reached the page: every read a
            // step can fail on comes before its act. The browser lost
            // while the page settles ends the errand (review round 1).
            do {
                _ = try await settle(tab, leaving: nil, on: nil)
            } catch let error where Self.isLost(error) {
                return .errand(lost(error))
            } catch {}
            if stopping { throw CancellationError() }
            return miss(nil, ContinuousClock.now)
        }
    }

    // MARK: - An answer errand's sub-goals (ITER-076 brain)

    /// The sub-goal the steps work toward: its words, the actions it took, as
    /// its result lists them, and the fields it typed in, by fingerprint, with
    /// what was typed (D4); and a search field with no button typed into in
    /// the step before, by fingerprint: its search is the next step (ITER-076
    /// stage 3).
    private struct NamedSubgoal {
        let goal: String
        var actions: [String] = []
        var typedInto: [String: String] = [:]
        var searchReady: String?
        /// An address the sub-goal names, opened as its first step (2026-10-07).
        var addressReady: URL?
        /// The control the reader named as showing the rest of a list (2026-10-15): taken as the sub-goal's first
        /// step when the page holds exactly one control of that label — walled and asked about as any step.
        var expandReady: String?
        /// A sub-goal of code's own that opens a list's next page (2026-10-16): it is that one step, and Jev is
        /// never asked — it ends once the link is taken, or at once when the page no longer holds it.
        var paging = false
    }

    /// An answer errand's loop (G3): the text model names one sub-goal at a
    /// time with the `browser_do` tool, and reads what came of each in the
    /// tool's result; Jev picks every step of it, and the page it leaves is
    /// read (step 2). A reply with no call means the model thinks the errand
    /// is done; code decides, with the verifier (stage 1): done, or not
    /// finished — but not before the errand browsed: a first reply without
    /// a call answers from no page, so the user's own goal runs as the first
    /// sub-goal, and the loop goes on (ITER-076 stage 4c, F4). The read that
    /// gives the last information requirement its claim asks the verifier
    /// too. At most `maxSubgoals` replies are asked for; an errand the model
    /// never said was done by then was not getting anywhere.
    private func subgoals(in tab: BrowserTab, plan: AgentPlan) async throws -> ErrandRecord.Ending {
        guard let model = parts.model else { return fail(.subgoalFailed) }
        let goal = plan.goal
        var turns: [ErrandModel.Turn] = []
        for _ in 0..<Self.maxSubgoals {
            var reply: ProLLMClient.Answer
            let worstCase = ErrandModel.worstCaseUSD(of: ErrandModel.subgoalRequest(goal: goal, turns: turns))
            switch try await askModel(.subgoal, worstCaseUSD: worstCase,
                                      usage: { $0.usage }, { [turns] in try await model.subgoal(goal: goal, turns: turns) }) {
            case .answered(let answer): reply = answer
            case .missed: return fail(.subgoalFailed)
            case .ended(let ending): return ending
            }
            if reply.toolCalls.isEmpty, turns.isEmpty {
                // The run's own call, the user's goal its one parameter: the
                // reply's words are not kept.
                reply = ProLLMClient.Answer(text: "", toolCalls: [ErrandModel.call(goal: goal, id: "call_" + UUID().uuidString)],
                                            finishReason: reply.finishReason, inputTokens: reply.inputTokens,
                                            outputTokens: reply.outputTokens, costUSD: reply.costUSD)
            }
            guard let first = reply.toolCalls.first else {
                let page = unanswered(plan).isEmpty ? try await shown(tab) ?? lastPage : nil
                if let ending = try await verified(plan, on: page, model: model) { return ending }
                // Not done: the model hears why — the reference's "DONE rejected" — and is asked again, at most
                // `maxRejections` times an errand (2026-10-15; a reference browser agent's `_finish`, `agent.py`
                // 2636-2660, MIT).
                guard rejections < Self.maxRejections else { return .notFinished }
                rejections += 1
                turns.append(ErrandModel.Turn(reply: reply, results: [], rejection: rejected(plan)))
                continue
            }
            var status = ErrandModel.Status.stuck
            var actions: [String] = []
            let wasOpen = !open(plan).isEmpty
            // The first call runs; any other was not tried (the orchestrator's
            // default of 2026-10-05), nor is a call without a goal.
            if let wanted = ErrandModel.goal(of: first) {
                switch try await pursue(wanted, in: tab, plan: plan) {
                case .ended(.stuck) where wasOpen:
                    // No progress ends the errand (§6.5), but only once the page
                    // it stopped on is read, as every sub-goal's is: what the
                    // reader finds there answers (2026-10-08: a long list
                    // scrolled eight times ended unread).
                    if let ending = try await readPage(in: tab, plan: plan, model: model) { return ending }
                    guard open(plan).isEmpty else { return .stuck }
                    return try await verified(plan, on: try await shown(tab) ?? lastPage, model: model) ?? .stuck
                case .ended(let ending): return ending
                case .status(let ended, let taken): (status, actions) = (ended, taken)
                }
                if let ending = try await readPage(in: tab, plan: plan, model: model) { return ending }
                if let ending = try await followPages(in: tab, plan: plan, model: model) { return ending }
            }
            let page = try await shown(tab) ?? lastPage
            if wasOpen, open(plan).isEmpty, let ending = try await verified(plan, on: page, model: model) {
                return ending
            }
            // What is still to find: each fact the user asked for that none
            // read so far answers — and what the verifier's last no named
            // beyond them (2026-10-15).
            let stillToFind = stillToDo(plan).map(\.line)
            turns.append(ErrandModel.Turn(reply: reply, results: reply.toolCalls.indices.map { index in
                index == 0 ? ErrandModel.result(status, page: page, actions: actions, stillToFind: stillToFind)
                           : ErrandModel.result(.stuck, page: page, actions: [], stillToFind: stillToFind)
            }))
        }
        return .stuck
    }

    /// Whether the errand is done (ITER-076 stage 1, № 35): code decides —
    /// every information requirement has a claim with its id, and the
    /// verifier, shown `page`, says complete and names nothing missing or
    /// ungrounded. While a requirement has no claim the verifier is not
    /// asked: it could not make the errand done (a reference browser agent
    /// rejects then without asking it, `verification.py` 170-172 and 252-253,
    /// MIT). It is asked when the model stops, and when the last requirement
    /// still to find gets its claim — again after a no, once a read gives what
    /// it named a new claim, as many times as reads allow. The steps it reads are the
    /// last actions, with what each typed, kept nowhere else. `.done`; nil
    /// when not done; or the errand's end.
    private func verified(_ plan: AgentPlan, on page: ObservedPage?, model: ErrandModel) async throws
        -> ErrandRecord.Ending? {
        guard unanswered(plan).isEmpty, continuing.isEmpty, let page else { return nil }
        let (goal, requirements, steps, evidence, visited) = (plan.goal, plan.requirements, recent.all, record.facts,
                                                               pagesSeen)
        let said = record.statements
        let today = Self.today()
        let request = ErrandModel.verifyRequest(goal: goal, requirements: requirements, today: today, steps: steps,
                                                page: page, evidence: evidence, statements: said, visited: visited)
        // The verifier's no stands for the very input it judged, once an end of the model's was rejected: it is not
        // asked again about it (2026-10-15). The model's first end still asks it once more, as before. Keyed on the
        // whole input — every fact, statement, step, address and the page — never on counts (Codex review, P1-3).
        let state = Self.verdictKey(of: request)
        if rejections > 0, judged == state { return nil }
        let worstCase = ErrandModel.worstCaseUSD(of: request)
        switch try await askModel(.verify, worstCaseUSD: worstCase, usage: { $0.usage }, {
            try await model.verify(goal: goal, requirements: requirements, today: today, steps: steps, page: page,
                                   evidence: evidence, statements: said, visited: visited)
        }) {
        case .answered(let verdict):
            // Its ids alone, never words: what the next turn hears of it, in the log too (2026-10-15).
            parts.log("\(ErrandRecord.logPrefix(record.errandID)) verdict complete=\(verdict.complete) "
                      + "missing=\(verdict.missing.joined(separator: ",")) ungrounded=\(verdict.ungrounded.joined(separator: ","))")
            if verdict.complete && verdict.missing.isEmpty && verdict.ungrounded.isEmpty { return .done }
            // What it said no to is still to find, until a read gives it a
            // new claim: every information requirement when it named none.
            let information = Set(plan.requirements.filter { $0.kind == .information }.map(\.id))
            let named = Self.planIDs(verdict.missing + verdict.ungrounded, in: plan)
            unconfirmed = named.isEmpty ? information : named.intersection(information)
            // Beside it, what the model hears of this no (2026-10-15): the actions it named, and the information
            // it named as read off the wrong page.
            namedActions = plan.requirements.filter { $0.kind == .action && named.contains($0.id) }.map(\.id)
            misread = Self.planIDs(verdict.ungrounded, in: plan).intersection(information)
            judged = state
            return nil
        case .missed: return nil
        case .ended(let ending): return ending
        }
    }

    /// What a verdict was asked about, whole: every message of its request (Codex review, P1-3).
    nonisolated static func verdictKey(of request: ProLLMClient.Request) -> [String] {
        request.messages.map { $0["content"]?.string ?? "" }
    }

    /// Today, where the Mac is, as the approval page shows the verifier the
    /// current date.
    private static func today() -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: .now)
    }

    /// The information requirements still to find: those no fact answers
    /// yet, and those the verifier named since their last new claim. What the
    /// model is told is still to find, what a read is asked for, and what a
    /// new claim must close before the verifier is asked again.
    private func open(_ plan: AgentPlan) -> [AgentPlan.Requirement] {
        plan.requirements.filter {
            $0.kind == .information && (unconfirmed.contains($0.id) || !answered($0.id) || continuing.keys.contains($0.id))
        }
    }

    /// What is still to do, in the plan's order, as the model hears it (2026-10-15): each information requirement
    /// still to find — one the verifier named as read off the wrong page with the pages it was read off — and each
    /// action requirement the verifier's last no named, by its words.
    private func stillToDo(_ plan: AgentPlan) -> [(id: String, line: String)] {
        let open = Set(open(plan).map(\.id))
        return plan.requirements.compactMap { requirement in
            guard open.contains(requirement.id) || namedActions.contains(requirement.id) else { return nil }
            // A list the reader saw go on (a reference browser agent's recovery line, `agent.py` 2399-2411, MIT).
            if let expands = continuing[requirement.id] {
                return (requirement.id, requirement.text + " (the reader saw the list this ranges over go on past what"
                        + " the page shows: load the rest first" + (expands.map { ": \"" + $0 + "\"" } ?? "") + ")")
            }
            guard misread.contains(requirement.id), open.contains(requirement.id) else { return (requirement.id, requirement.text) }
            let pages = record.facts.filter { $0.requirements.contains(requirement.id) }.map(\.url)
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return (requirement.id, requirement.text + " (read off " + pages.joined(separator: ", ")
                    + ", not the page the task describes)")
        }
    }

    /// Why the model's end of the errand is rejected, as a reference browser agent tells its loop (`agent.py`
    /// 2636-2660, MIT): "DONE rejected: " and each requirement still to do by its id and words.
    private func rejected(_ plan: AgentPlan) -> String {
        let unmet = stillToDo(plan).map { "\($0.id): \($0.line)" }
        return "DONE rejected: " + (unmet.isEmpty ? "completion not confirmed" : unmet.joined(separator: "; "))
    }

    /// The information requirements no fact answers yet (ITER-076 brain,
    /// step 2): none of the reader's claims with its id rests on a quote.
    /// Done waits for none of them; the verifier is not asked before.
    private func unanswered(_ plan: AgentPlan) -> [AgentPlan.Requirement] {
        plan.requirements.filter { $0.kind == .information && !answered($0.id) }
    }

    /// How many facts answer requirement `id`.
    private func answering(_ id: String) -> Int { record.facts.filter { $0.requirements.contains(id) }.count }

    private func answered(_ id: String) -> Bool { record.facts.contains { $0.requirements.contains(id) } }

    /// The plan's requirements `ids` names, however the verifier spelled them:
    /// by the id without its punctuation or case, or by its trailing number
    /// alone, the last requirement with that key winning as in the
    /// reference's dictionaries — a name matching none names nothing (a
    /// reference browser agent's `_plan_ids`, `agent.py` 3061-3074, MIT).
    static func planIDs(_ ids: [String], in plan: AgentPlan) -> Set<String> {
        let key = { (id: String) in String(id.lowercased().unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }) }
        let known = Dictionary(plan.requirements.map { (key($0.id), $0.id) }, uniquingKeysWith: { _, last in last })
        let numbered = Dictionary(plan.requirements.compactMap { requirement in
            requirement.id.range(of: "[0-9]+$", options: .regularExpression).map { (String(requirement.id[$0]), requirement.id) }
        }, uniquingKeysWith: { _, last in last })
        return Set(ids.compactMap { raw in
            let name = key(raw)
            return known[name] ?? (!name.isEmpty && name.allSatisfy(\.isNumber) ? numbered[name] : nil)
        })
    }

    /// Reads the page a sub-goal left (ITER-076 brain, step 2, G6-G8): only
    /// when a fact is still to find and the page's text, source or remaining
    /// requirements are new, in chunks, while a fact is still to find and the errand has
    /// reads left. The facts of each answer go into the record as they come,
    /// as a row does: Stop, the Mac's sleep and the app's quit keep them.
    /// Each read is on record by what ended it, with what the page gave
    /// (ITER-076 stage 4a). Nil: the work goes on; otherwise the errand's end.
    private func readPage(in tab: BrowserTab, plan: AgentPlan, model: ErrandModel, looked: ObservedPage? = nil)
        async throws -> ErrandRecord.Ending? {
        guard reads < Self.maxReads else { return readEnded(.readsSpent) }
        guard !open(plan).isEmpty else { return readEnded(.nothingToFind) }
        await loaded(tab)
        guard let json = try await read(ObserverScript.blocksSource(limit: ErrandModel.chunkLimit * Self.maxReads), in: tab)
        else { return readEnded(.failed) }
        guard let capture = ErrandModel.Capture.decode(json) else {
            note(.pageMiss(.report))
            return readEnded(.notLines)
        }
        guard !capture.blocks.isEmpty else { return readEnded(.noLines, capture) }
        let key = ReadKey(url: capture.url, text: capture.text, requirements: open(plan).map(\.id))
        guard (readPages[key] ?? 0) < Self.barrenReads else { return readEnded(.readBefore, capture) }
        let (factsBefore, saidBefore) = (record.facts, record.statements)
        defer {
            let added = record.facts != factsBefore || record.statements != saidBefore
            readPages[key] = added ? Self.barrenReads : (readPages[key] ?? 0) + 1
        }
        note(.read(.init(end: .read, blocks: capture.blocks.count, walk: capture.walk)))
        let chunks = ErrandModel.chunks(capture.blocks)
        // The page's one link to its next page, told to the reader: its text reads as any other words (2026-10-16).
        let nextPage = (looked ?? lastPage).flatMap { $0.url == capture.url ? NextPage.control(on: $0)?.name : nil }
        // Where the run began, once a list may run past one page: the task's pages count from it (2026-10-18).
        let beganAt = nextPage != nil || pagesFollowed > 0 ? pagesSeen.first : nil
        // The lists this read saw go on, for the requirements it was asked: what is still to find once it is done
        // (2026-10-15). A read that gave no answer leaves them as they were.
        var goesOn: [String: String?]?
        let asking = Set(open(plan).map(\.id))
        defer {
            if let goesOn {
                continuing = goesOn
                continuingAt = goesOn.isEmpty ? nil : capture.url
            }
        }
        for (index, chunk) in chunks.enumerated() {
            let wanted = open(plan)
            guard !wanted.isEmpty, reads < Self.maxReads else { break }
            reads += 1
            let evidence = record.facts
            let said = record.statements
            let worstCase = ErrandModel.worstCaseUSD(of: ErrandModel.readRequest(
                goal: plan.goal, wanted: wanted, evidence: evidence, statements: said, capture: capture, chunk: chunk,
                index: index, total: chunks.count, nextPage: nextPage, beganAt: beganAt))
            switch try await askModel(.read, worstCaseUSD: worstCase, usage: { $0.usage }, {
                try await model.read(goal: plan.goal, wanted: wanted, evidence: evidence, statements: said,
                                     capture: capture, chunk: chunk, index: index, total: chunks.count,
                                     nextPage: nextPage, beganAt: beganAt)
            }) {
            case .answered(let reading):
                let held = record.facts.count
                let before = Dictionary(uniqueKeysWithValues: unconfirmed.map { ($0, answering($0)) })
                let read = ErrandModel.read(after: reading.claims, continues: reading.continues, shown: chunk,
                                            url: FormFill.link(capture.url, holding: shownValues),
                                            kept: evidence, said: said, asked: Set(wanted.map(\.id)), read: reads)
                record.facts = read.facts
                record.statements = read.statements
                var seen = goesOn ?? [:]
                for continuation in reading.continues where asking.contains(continuation.requirement) {
                    seen[continuation.requirement] = .some(continuation.expands ?? seen[continuation.requirement] ?? nil)
                }
                goesOn = seen
                unconfirmed = unconfirmed.filter { answering($0) <= before[$0] ?? 0 }
                let labels = Set(chunk.map(\.label))
                let unplaced = reading.claims.filter { claim in
                    ((claim.cite.map { [$0] } ?? []) + claim.records).contains { !labels.contains($0.first) || !labels.contains($0.last) }
                }.count
                let offAsk = reading.claims.filter { $0.requirement.map { !wanted.map(\.id).contains($0) } ?? true }.count
                parts.log("\(ErrandRecord.logPrefix(record.errandID)) read chunk \(index + 1)/\(chunks.count): "
                          + "claims=\(reading.claims.count) unplaced=\(unplaced) noRequirement=\(offAsk) "
                          + "facts \(held)→\(record.facts.count) answering=\(record.facts.filter { !$0.requirements.isEmpty }.count) "
                          + "labels=\(chunk.first?.label ?? "-")…\(chunk.last?.label ?? "-")")
            case .missed: continue
            case .ended(let ending): return ending
            }
        }
        return nil
    }

    /// The rest of a list a read saw go on, walked by code (a reference browser agent's `_follow_pages` and
    /// `_paging`, `agent.py` 2339-2367 and 3254-3273, MIT): while the reader says a list goes on and the page it
    /// read holds one link to its next page, that link is taken — by code, never asked of Jev, with every wall and
    /// question any step has — and the page it opens is read; at most `maxPages` next pages an errand. A control that
    /// loads more onto the same page is left to the model: its earlier records stay, and a read of them again
    /// would count them twice. Told only that the list went on, the model answered a count from its own memory
    /// (quotes.toscrape, 2026-10-16).
    private func followPages(in tab: BrowserTab, plan: AgentPlan, model: ErrandModel) async throws -> ErrandRecord.Ending? {
        while !continuing.isEmpty, !open(plan).isEmpty, pagesFollowed < Self.maxPages {
            guard let page = try await shown(tab) ?? lastPage, page.url == continuingAt,
                  NextPage.control(on: page) != nil else { return nil }
            pagesFollowed += 1
            switch try await pursue("Open the next page of the list", in: tab, plan: plan, paging: true) {
            case .ended(let ending): return ending
            case .status(let status, _): guard status == .done else { return nil }
            }
            guard let now = try await shown(tab) ?? lastPage, now.url != page.url else { return nil }
            if let ending = try await readPage(in: tab, plan: plan, model: model, looked: now) { return ending }
        }
        return nil
    }

    /// A read that ended at `end`, on record with what `capture` gave: the
    /// work goes on (ITER-076 stage 4a).
    private func readEnded(_ end: ErrandRecord.Event.Read.End, _ capture: ErrandModel.Capture? = nil)
        -> ErrandRecord.Ending? {
        note(.read(.init(end: end, blocks: capture?.blocks.count, walk: capture?.walk)))
        return nil
    }

    /// What one sub-goal came to: how it ended and the actions it took, or the
    /// errand's end.
    private enum SubgoalEnd {
        case status(ErrandModel.Status, actions: [String])
        case ended(ErrandRecord.Ending)
    }

    /// Runs one sub-goal (G4): Jev's question A and watchers read it, and it
    /// ends on Jev's DONE or BLOCKED, `goal_done` above 0.85 before a step
    /// acts, stuck, `actionsPerSubgoal` steps, a hand-over or a ceiling. Its
    /// misses and its stuck watcher count from its own first step; the
    /// errand's progress goes on through it, and a finished one is progress.
    private func pursue(_ goal: String, in tab: BrowserTab, plan: AgentPlan, paging: Bool = false)
        async throws -> SubgoalEnd {
        named = NamedSubgoal(goal: goal, addressReady: paging ? nil : Self.firstAddress(in: goal),
                             expandReady: paging ? nil : continuing.values.compactMap { $0 }.first, paging: paging)
        defer { named = nil }
        attempts = StepAttempts()
        stepsAsked = 0
        while stepsAsked < Self.actionsPerSubgoal {
            try checkpoint(countingSteps: true)
            switch try await stepOrMiss(in: tab, plan: plan) {
            case nil:
                // A list's next page is opened: the page is read next, as the reference reads it (`_paging`).
                if named?.paging == true { return .status(.done, actions: named?.actions ?? []) }
                continue
            case .errand(let ending)?: return .ended(ending)
            case .subgoal(let status)?: return .status(status, actions: named?.actions ?? [])
            }
        }
        return .status(.maxActions, actions: named?.actions ?? [])
    }

    /// Brings the work clock up to date — waits for the user left out — and
    /// throws at Stop or at a ceiling (§7.4, §8). Called before every step and
    /// right before every effect, so neither is noticed only after the fact.
    /// Only the check before a new step counts steps: the step ceiling is
    /// about starting one.
    private func checkpoint(countingSteps: Bool = false) throws {
        if stopping { throw CancellationError() }
        let now = workClock.now
        budget.addActive(seconds: Self.seconds(now - lastCheckpoint - waitedSinceCheckpoint))
        lastCheckpoint = now
        waitedSinceCheckpoint = .zero
        if budget.ceiling(now: .now, countingSteps: countingSteps) != nil { throw CeilingReached() }
    }

    /// One Choose request and what follows from it (§6.3–§6.5). Nil: the
    /// work goes on.
    private func step(in tab: BrowserTab, plan: AgentPlan) async throws -> StepEnd? {
        // A step's cost is its own from its first look: a look that fails is
        // a miss that paid nothing (review of I-06a).
        stepCost = 0
        engineAnswer = nil
        dialogsThisStep = 0
        refusedThisStep = false
        // No step has the user's Yes until it is given for it, and none keeps
        // it past its own end (ITER-076 I-09).
        parts.bridge.approve(nil, in: tab)
        defer { parts.bridge.approve(nil, in: tab) }
        let stillLoading = await loaded(tab)
        let page = try await observe(tab)
        let previous = lastPage
        lastPage = page
        // The agent's own navigation took the tab away from the filled form:
        // what the next document sends is its own (review round 2, R2-2). A
        // document not known to be another keeps the hold.
        if let heldDocument, let now = page.loadedFrom, now != heldDocument { await releaseSends() }
        // A page that asked, in its own dialog, for a payment or a grant: the
        // errand ends at the user's part, before anything more is chosen —
        // the dialog was Cancel whatever the Yes (review of I-09, F4).
        if let dialogNamed { return try await userPart(dialogNamed, on: page, in: tab) }
        // A page that shows dialogs one after another never holds the errand.
        if dialogsThisStep > Self.dialogLimit { return .subgoal(.stuck) }
        // This look tells whether the last action changed the page, and what it visibly did.
        let pageKey = Self.pageKey(of: page)
        if let pending = pendingIdle {
            if pending.page == pageKey { idleFrom.insert(pending) }
            pendingIdle = nil
        }
        // A page state the errand never reached is the last step's progress, whatever it brought (2026-10-18).
        if statesReached.insert(Self.stateKey(of: page)).inserted, lastPageKey != nil { progress.reachedNewState() }
        if let lastPageKey {
            recent.settleLast(pageChanged: pageKey != lastPageKey,
                              effect: previous.map { StepEffect.summary(from: $0, to: page) })
        }
        lastPageKey = pageKey
        // Where this document was loaded from is an address BACK may go back
        // to; where a step with the user's Yes led, one it never asks for again
        // (ITER-076 I-10).
        if let from = page.loadedFrom.map(Self.requested) {
            if let approvedFrom, approvedFrom != from { approvedAddresses.insert(from) }
            loaded.insert(from)
        }
        approvedFrom = nil
        // A consent page reached by its address is the user's part (ITER-076
        // 2.1) — and so is a page that frames one, whatever the frame's site
        // (review of I-09, F3). A page that asks for a secret is not, by
        // itself: its secret fields are hidden and the errand goes on (owner
        // decision 4, 2026-09-29) until a step would touch one.
        if page.asksForGrant {
            return try await userPart(.grant, on: page, in: tab)
        }
        // In an answer errand, the sub-goal the model named: its words rank
        // the page's actions as a row's terms do (ITER-076 brain).
        let subgoal = named.map { AgentPlan.Subgoal(description: $0.goal, terms: [$0.goal]) }
            ?? plan.subgoal(forRow: scratchpad.rows.count)
        let chosenHere = try await optionsStillChosen(on: page, in: tab)
        // What the user said No to on this page is not offered again, by
        // what it does (ITER-076 I-05, review round 1).
        let pageAddress = AgentAction.effectAddress(page.liveAddress)
        let canGoBack = try await backEntry(in: tab) != nil
        let set = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: subgoal.terms,
                                                                               chosenOptions: chosenHere,
                                                                               refused: refused[pageAddress] ?? [],
                                                                               canGoBack: canGoBack))
        let began = ContinuousClock.now
        // A cookie window (ITER-076 stage 3, № 98, owner default 3.1): the
        // least consent it offers — reject all, necessary only, a settings
        // layer's save with only necessary switches on, close — or the way to
        // it — a switch to turn off, the control that opens its settings
        // (2026-10-21) — is the step, clicked without a Yes and with no model
        // asked, once on a page: one still there after it is left to Jev, as
        // any control. A window that offers none of them is the user's part
        // when it blocks the page; a bar that blocks nothing is read past
        // (2026-10-19).
        let cookies = CookieBanner.window(on: page)
        if let cookies, cookies.least == nil, cookies.blocksPage { return try await userPart(.cookies, on: page, in: tab) }
        let dismiss = cookies?.least.map {
            AgentAction(operation: .click, target: $0, destination: nil, payload: nil, isPlannedSearch: false)
        }.flatMap { cookiesClicked[pageAddress]?.contains($0.effect) == true ? nil : $0 }
        // D4 (ITER-076 stage 3, № 122): a search form whose field the step
        // before typed in is searched now, as a person's Enter sends it — by
        // the address its form builds, its button or not (2026-10-07).
        let ready = named?.searchReady
        named?.searchReady = nil
        let enter = ready.flatMap { fingerprint in page.elements.first { $0.fingerprint == fingerprint } }
            .flatMap { field in named.flatMap { SafetyGuard.searchAddress(typedInto: field, on: page, typed: $0.typedInto) } }
            .map { Self.search($0) }
        // An address the sub-goal names is its first step, the run's own
        // (2026-10-07): the model names where it goes — "Open https://…" —
        // and Jev has no step that goes to an address. Once, and not when the
        // page is already there.
        var goTo: AgentAction?
        if dismiss == nil, enter == nil, let address = named?.addressReady {
            named?.addressReady = nil
            if address.absoluteString != page.liveAddress, address.absoluteString != page.url { goTo = Self.search(address) }
        }
        // The step the code takes itself, when it takes one.
        let own = dismiss ?? enter ?? goTo

        // Choose (§6.3).
        let engine = parts.engine
        let summary = PageSummary(url: page.url, title: page.title, text: page.text)
        let goal = plan.goal
        stepsAsked += 1
        budget.countStep()
        let choice: ChooseAnswer
        var action: AgentAction
        if let own {
            if let dismiss { cookiesClicked[pageAddress, default: []].insert(dismiss.effect) }
            choice = ChooseAnswer(candidateID: "", confidence: 1, goalMet: nil, stuck: nil, usage: nil)
            action = own
        } else if let label = named?.expandReady, page.url == continuingAt, let expand = Self.expanding(label, in: set) {
            // The control the reader named as showing the rest of a list, when it is the page's one control of that
            // label (2026-10-15; a reference browser agent's `_follow_pages`, `agent.py` 2338-2372, MIT): taken
            // without asking Jev, then walled and asked about as any step.
            named?.expandReady = nil
            choice = ChooseAnswer(candidateID: expand.id, confidence: 1, goalMet: nil, stuck: nil, usage: nil)
            action = expand.action
        } else if named?.paging == true {
            // The list's next page, found again on the look this step goes against — never by a label two controls
            // may share: a pager drawn above and below its list is one address, taken at its first drawing the step
            // offers (a reference browser agent's `_paging`, `agent.py` 3254-3273, MIT; Codex review of 2026-10-18,
            // P1-4). Gone from the page, nothing of the walk is left to Jev.
            let drawings = page.url == continuingAt ? NextPage.drawings(on: page).map(\.index) : []
            guard let link = set.candidates.first(where: { candidate in
                candidate.action.operation == .open && candidate.action.target.map { drawings.contains($0.index) } == true
            }) else { return .subgoal(.stuck) }
            choice = ChooseAnswer(candidateID: link.id, confidence: 1, goalMet: nil, stuck: nil, usage: nil)
            action = link.action
        } else {
            // Jev's question A and its watchers read the sub-goal in an answer
            // errand; its risk questions read the user's goal (ITER-076 brain).
            let request = ChooseRequest(candidates: set.candidates, subgoal: subgoal,
                                        rowsCollected: scratchpad.rows.count, rowsWanted: plan.rowsWanted,
                                        goal: named?.goal ?? goal, page: summary, recentActions: recent.all)
            switch try await askEngine(usage: { $0.usage }, { try await engine.choose(request) }) {
            case .ended(let ending): return .errand(ending)
            case .missed: return miss(nil, began)
            case .answered(let answer): (choice, engineAnswer) = (answer, answer)
            }
            guard let picked = set.candidates.first(where: { $0.id == choice.candidateID })?.action else {
                return miss(nil, began)
            }
            action = picked
        }
        // The action as it was offered — a field's before its text is written:
        // what a No, or a send whose delivery is not known, keeps it from
        // being offered again (ITER-076 stage 3, № 89, 97).
        var offered = action

        var newRow = false
        if named != nil {
            // A sub-goal Jev's watcher sees achieved ends before the step acts
            // (ITER-076 A2, P2-4): `goal_done` above 0.85, as the watchers'
            // source stops. A finished sub-goal is progress.
            if AgentPolicy.subgoalDone(noul: choice.goalMet) {
                progress.record(action, newRow: false, subgoalFinished: true)
                return .subgoal(.done)
            }
        } else if AgentPolicy.goalMet(noul: choice.goalMet) == true {
            // A row, when this page serves the subgoal (§6.6).
            switch try await collectRow(in: tab, subgoal: subgoal, plan: plan) {
            case .overBudget: return .errand(.ceiling)
            case .notAdded: break
            case .added: newRow = true
            }
            // The row was reported: whoever heard it may have pressed Stop,
            // and then nothing more is done (review round 1, P2-4).
            if stopping { throw CancellationError() }
            if scratchpad.rows.count >= plan.rowsWanted {
                log(action, .acted, choice.confidence, began)
                return .errand(.done)
            }
        }
        var confidence = choice.confidence
        // The text model named this step: Jev's watchers read Jev's own pick, not it.
        var directed = false
        if action.operation == .done || action.operation == .stuck {
            // DONE ends a sub-goal at any confidence: it acts on nothing, and the page it leaves is read and judged,
            // as a reference browser agent keeps DONE out of its confidence gate (`agent.py` 767-772, MIT) — an
            // unsure DONE reconsidered on a page that showed the result sent Jev to pick a link and leave
            // (2026-10-16). BLOCKED ends one only from `subgoalEndsFrom`; below it, it is reconsidered — once on a
            // page state; the second time there the text model names the step (2026-10-15; `agent.py` 2636-2668).
            if named != nil, action.operation == .stuck, confidence < AgentPolicy.subgoalEndsFrom {
                guard own == nil, !doubtedEnds.insert(pageKey).inserted, recoveries < Self.maxRecoveries else {
                    return miss(action, began)
                }
                let what = action.operation == .done ? "the sub-goal is done" : "the sub-goal is blocked"
                switch try await recover(set.candidates.map(\.action).filter { $0.operation != .stuck }, on: page,
                                         plan: plan, problem: String(format: "uncertain whether %@ (%.2f)", what, confidence)) {
                case .ended(let ending): return .errand(ending)
                case .none: return miss(action, began)
                case .gaveUp:
                    log(action, .reconsidered, confidence, began)
                    return .subgoal(.blocked)
                case .directed(let picked): (action, offered, confidence, directed) = (picked, picked, 1, true)
                }
            }
            if action.operation == .done || action.operation == .stuck {
                log(action, .acted, confidence, began)
                guard action.operation == .done else { return .subgoal(.blocked) }
                if named != nil { progress.record(action, newRow: false, subgoalFinished: true) }
                return .subgoal(.done)
            }
        }
        // Jev's own watcher says the errand makes no progress (ITER-076 1.3, B).
        if !directed, AgentPolicy.isStuck(noul: choice.stuck, step: stepsAsked) {
            log(action, .reconsidered, choice.confidence, began)
            return .subgoal(.stuck)
        }

        // Jev unsure of a step that acts (2026-10-15; a reference browser agent's `_try_unsure` and `_recover`,
        // `agent.py` 3306-3322 and 2373-2500, MIT): its pick is tried once on a page state — unless the page's
        // structure says it is irreversible, and never one already taken from that state — and past that the text
        // model names the step among the page's listed actions, at most `maxRecoveries` times an errand. What either
        // names is walled, asked about and taken as any step is.
        if named != nil, own == nil, confidence < AgentPolicy.actFrom {
            // A page still showing a loading indicator once the look's wait ran out is still loading, not unclear:
            // it is waited on once more and looked at again, once a page state, before any unsure pick is tried
            // (2026-10-16; a reference browser agent's `_outwait` of a page still rendering, `agent.py` 721-725, MIT).
            // Tried, Jev's pick left a page six seconds before its result came.
            if stillLoading, !outwaitedLoading.contains(pageKey) {
                outwaitedLoading.insert(pageKey)
                log(action, .reconsidered, confidence, began)
                await loaded(tab, upTo: Self.loadingOutwait)
                return nil
            }
            let untried = !triedUnsure.contains(pageKey) && !takenFrom.contains(TakenFrom(page: pageKey, effect: action.effect))
            if untried, AgentPolicy.risk(of: action, irreversibleNoul: nil, pageURL: page.address(of: action.target)) != .irreversible {
                triedUnsure.insert(pageKey)
                confidence = AgentPolicy.actFrom
            } else if recoveries < Self.maxRecoveries {
                switch try await recover(set.candidates.map(\.action).filter { $0.operation != .stuck }, on: page, plan: plan,
                                         problem: String(format: "uncertain next step (%.2f)", confidence)) {
                case .ended(let ending): return .errand(ending)
                case .none: break
                case .gaveUp:
                    log(action, .reconsidered, confidence, began)
                    return .subgoal(.blocked)
                case .directed(let picked) where picked.operation == .done || picked.operation == .stuck:
                    log(picked, .acted, 1, began)
                    guard picked.operation == .done else { return .subgoal(.blocked) }
                    progress.record(picked, newRow: false, subgoalFinished: true)
                    return .subgoal(.done)
                case .directed(let picked):
                    (action, offered, confidence, directed) = (picked, picked, 1, true)
                }
            }
        }

        // The same step from the same page state already did nothing: taken again it is a loop, so the text model
        // is told so and names the step — once; a retry it names stands (a reference browser agent's
        // `attempted.idle`, `agent.py` 778-788, MIT). Jev opened a link to the page itself, named like the task's,
        // seven times over (qa-practice new tab, 2026-10-16).
        if named != nil, own == nil, !directed, idleFrom.remove(TakenFrom(page: pageKey, effect: action.effect)) != nil,
           recoveries < Self.maxRecoveries {
            let what = ([action.operation.rawValue] + (action.target.map { [$0.name] } ?? [])).joined(separator: " ")
            switch try await recover(set.candidates.map(\.action).filter { $0.operation != .stuck }, on: page, plan: plan,
                                     problem: what + " already did nothing here") {
            case .ended(let ending): return .errand(ending)
            case .none: break
            case .gaveUp:
                log(action, .reconsidered, confidence, began)
                return .subgoal(.blocked)
            case .directed(let picked) where picked.operation == .done || picked.operation == .stuck:
                log(picked, .acted, 1, began)
                guard picked.operation == .done else { return .subgoal(.blocked) }
                progress.record(picked, newRow: false, subgoalFinished: true)
                return .subgoal(.done)
            case .directed(let picked):
                (action, offered, confidence, directed) = (picked, picked, 1, true)
            }
        }

        // A CAPTCHA provider's widget, by its frame's address, is the user's
        // part, never acted on (ITER-076 stage 3, owner decision 6): a check
        // that clears itself is waited out first (№ 115).
        if page.inCaptchaWidget(action.target) {
            if try await outwaited(page, in: tab) {
                log(action, .reconsidered, confidence, began)
                return nil
            }
            log(action, .handedOver, confidence, began)
            return try await userPart(.captcha, on: page, in: tab)
        }
        // A grant is never taken and never asked about: it is the user's
        // part (§7.2).
        if SafetyGuard.isGrant(action) {
            log(action, .handedOver, confidence, began)
            return try await userPart(.grant, on: page, in: tab)
        }
        // A file from the user's disk is theirs to pick: a step that may send
        // a form still waiting for one is the user's part (ITER-076 I-08). It
        // is named so before the secret check, which a form too big to read
        // whole also meets (Codex review 1 of I-08, P2-1).
        if action.target?.needsFile == true {
            log(action, .handedOver, confidence, began)
            return try await userPart(.file, on: page, in: tab)
        }
        // Signing in and paying are the user's part (§7.2, §11): a step that
        // could send a secret field is handed over, never asked about.
        if action.target?.touchesSecret == true {
            log(action, .handedOver, confidence, began)
            return try await userPart(page.flags(of: action.target).paymentForm ? .payment : .signIn, on: page, in: tab)
        }
        // So is a press that would send a form short of a secret field it needs, before any Yes (2026-10-21).
        if SafetyGuard.needsTheUsersSecret(action) {
            log(action, .handedOver, confidence, began)
            return try await userPart(page.flags(of: action.target).paymentForm ? .payment : .signIn, on: page, in: tab)
        }
        // A form of the user's details (ITER-076 stage 7): Jev chose to type
        // in one of its fields — the whole form is previewed, then filled
        // with one Yes; a field of a form previewed before is typed only by
        // its Fill (№ 57); a click that may send a filled form asks the Yes
        // bound to its values (№ 93). After the walls above, which hold for a
        // form as for any step: a form that could send a secret field is the
        // user's — one whose only secret field is an empty password is not
        // (2026-10-21), and its password is never typed: it is withheld.
        if named != nil, let form = formStep(for: action, on: page) {
            switch form {
            case .fill(let fields):
                return try await fillForm(fields, chosen: action, on: page, in: tab, goal: goal,
                                          confidence: confidence, began: began)
            case .typedByItsFill, .unknownForm:
                return miss(action, began)
            case .send(let key):
                return try await sendForm(key, click: action, on: page, in: tab, summary: summary, goal: goal,
                                          confidence: confidence, began: began)
            }
        }

        // Risk (§6.3, §7.1): the page's structure and the lexicon answer C
        // where they can, Jev's C the rest. Jev is asked for every action that
        // is not always reversible, so E is answered also where structure or
        // the lexicon already said "irreversible": a grant behind a POST form
        // or a word like "Share" is still the user's part (review of A3, round
        // 1). Without E — the call failed, or its answer has none — the step
        // is a miss: never asked about, never taken (review of A3d, round 2,
        // P1-6).
        // D4, strictly (ITER-076 stage 3, № 81): Jev's click on a pure
        // search's button is that search, sent by the address its form builds
        // — no click, none of the page's code, no Yes. Its history says the
        // click Jev chose.
        var searched = enter != nil
        var shown: AgentAction?
        if own == nil, let named, let address = SafetyGuard.searchAddress(for: action, on: page, typed: named.typedInto) {
            shown = action
            action = Self.search(address)
            searched = true
        }
        // A search is never sent twice: a site that ignores its query shows
        // its form again — a miss, never a loop (№ 58).
        if searched, let address = action.destination, !searchesSent.insert(address).inserted {
            return miss(action, began)
        }
        // A cookie window's least consent, and a search, ask no Yes (owner
        // default 3.1; D4): the words of a query are the user's.
        let known = own != nil || searched ? .alwaysReversible
            : AgentPolicy.risk(of: action, irreversibleNoul: nil, pageURL: page.address(of: action.target))
        var risk = known
        if known != .alwaysReversible {
            switch try await askEngine(usage: { $0.usage }, { [action] in
                try await engine.risk(of: action, on: summary, goal: goal)
            }) {
            case .ended(let ending): return .errand(ending)
            case .missed: return miss(action, began)
            case .answered(let answer):
                // E: a grant is the user's part, never taken (ITER-076 1.3).
                guard let grants = AgentPolicy.grants(noul: answer.grant) else { return miss(action, began) }
                if grants {
                    log(action, .handedOver, confidence, began)
                    return try await userPart(.grant, on: page, in: tab)
                }
                if known == nil {
                    risk = AgentPolicy.risk(of: action, irreversibleNoul: answer.irreversible,
                                            pageURL: page.address(of: action.target))
                }
            }
        }
        guard let risk else { return miss(action, began) }
        // An irreversible step on a page that takes a payment, or one that
        // commits where its form or region shows what it costs, pays — in any
        // language (owner decision 6).
        if SafetyGuard.pays(action, risk: risk, on: page.flags) {
            log(action, .handedOver, confidence, began)
            return .errand(handOver(.payment, on: page))
        }
        let decision = AgentPolicy.decide(confidence: confidence, risk: risk)
        // A field's text (ITER-076 brain): when Jev chose to type in an answer
        // errand, the text model writes it before the step is asked about or
        // taken; with none, nothing is typed and the step is a miss.
        if action.operation == .type, named != nil, decision == .act || decision == .askUser {
            switch try await written(for: action, goal: goal, on: page) {
            case .ended(let ending): return .errand(ending)
            case .missed: return miss(action, began)
            case .answered(let text):
                guard let text else { return miss(action, began) }
                action = AgentAction(operation: .type, target: action.target, destination: nil, payload: text,
                                     isPlannedSearch: false)
            }
        }

        var target = page
        // The action as it stands on the look it is taken on: after a Yes, the
        // fresh one's — every index read after the act is that look's (Claude
        // review of I-09, kept 17).
        var acting = action
        var approval: ActionScript.Approval?
        switch attempts.after(decision) {
        case .stuck:
            log(action, .reconsidered, confidence, began)
            return .subgoal(.stuck)
        case .reconsider:
            log(action, .reconsidered, confidence, began)
            return nil
        case .askUser:
            let fresh: ObservedPage
            let again: AgentAction
            switch try await askUser(action, on: page, in: tab) {
            case .approved(let page, let action):
                (fresh, again) = (page, action)
            case .refused:
                // A No — or a question left to lapse — is final for this
                // action on this page: it is never offered, nor asked about,
                // again in this errand (ITER-076 I-05) — a field by itself,
                // whatever text was written for it (stage 3, № 89).
                refused[pageAddress, default: []].insert(offered.effect)
                fallthrough
            case .lapsed:
                log(action, .refused, confidence, began)
                progress.record(action, newRow: newRow, subgoalFinished: newRow)
                return stalled()
            }
            // A form that needs the user's file now is theirs to finish, named
            // before the payment as the policy names it before the question
            // and the act before its walls (Claude review of I-08's round-2
            // fix).
            if again.target?.needsFile == true {
                log(action, .handedOver, confidence, began)
                return try await userPart(.file, on: fresh, in: tab)
            }
            // A sign-in or a card form that came while the question waited —
            // in a frame of another site, every control of which is then the
            // user's — makes the step the user's part, as it does before the
            // question (Claude review c7 of I-09, #5); so does a secret field
            // the form came to need meanwhile (2026-10-21).
            if again.target?.touchesSecret == true || SafetyGuard.needsTheUsersSecret(again) {
                log(action, .handedOver, confidence, began)
                return try await userPart(fresh.flags(of: again.target).paymentForm ? .payment : .signIn, on: fresh,
                                          in: tab)
            }
            // Owner decision 6: the payment evidence of the page the Yes came
            // on is read again — a total that loaded while the question
            // waited makes the step a payment, and a Yes never pays (review of
            // I-02, N3-P1-5). The hands check it once more at the act.
            if SafetyGuard.pays(again, risk: risk, on: fresh.flags) {
                log(action, .handedOver, confidence, began)
                return .errand(handOver(.payment, on: fresh))
            }
            target = fresh
            approvedFrom = page.loadedFrom.map(Self.requested)
            acting = again
            // Bound to the document the act runs in: the page's — an open
            // runs there — or its control's frame's (ITER-076 I-09).
            approval = ActionScript.Approval(pageURL: action.operation == .open ? page.liveAddress
                                                : page.address(of: action.target),
                                             text: action.target?.text ?? "",
                                             formSubmitLabel: action.target?.formSubmitLabel,
                                             submits: action.target?.submits,
                                             formGrants: action.target?.formGrants,
                                             paymentForm: fresh.flags(of: again.target).paymentForm,
                                             listForm: action.target?.listForm)
        case .act:
            break
        }

        // What the page did before the act is its own: a dialog that named the
        // user's part ends the errand here, before anything is sent (Claude
        // review of I-09, kept 2); one declined before is no failure of this
        // act.
        noteTabEvents(tab)
        if let dialogNamed { return try await userPart(dialogNamed, on: target, in: tab) }
        declinedThisStep = false
        let sending = Sending(outcome: approval == nil ? .acted : .confirmed, confidence: confidence,
                              began: began)
        // The windows this step's act asks to open are its own (ITER-076 I-10).
        _ = parts.bridge.windowsOpened(in: tab)
        switch try await dispatch(acting, on: target, in: tab, approval: approval, sending: sending) {
        case .named(let kind):
            // A dialog that named the user's part while the act was readied —
            // the look at the act, an aim — ends the errand before anything is
            // sent (Claude review c8 of I-09, #14, #25).
            return try await userPart(kind, on: target, in: tab)
        case .fileNeeded(let recorded):
            // The form needs the user's file now: the act did nothing (Codex
            // review 1 of I-08, P2-2).
            if !recorded { log(action, .handedOver, confidence, began) }
            return try await userPart(.file, on: target, in: tab)
        case .changed:
            // Only a form's Send is bound to its values (`sendForm`).
            log(action, .gone, confidence, began)
        case .finished(let outcome):
            log(action, outcome, confidence, began)
            // A login or payment form that appeared at the last moment is the
            // user's part (ITER-076 2.2, S3).
            if outcome == .handedOver { return try await handOverAtTheAct(acting, on: target, in: tab) }
            if outcome == .acted { took(shown ?? acting) }
        case .answered(let outcome):
            // Recorded as it went out; the page said nothing happened.
            if outcome == .handedOver { return try await handOverAtTheAct(acting, on: target, in: tab) }
        case .sent(let check):
            // The action went out, and was recorded before it did, so a Stop
            // that comes meanwhile cannot lose it; its postcondition is still
            // checked and reported (§7.4; review round 1, P1-1). A download or
            // an address the tab refused on its way fails it (ITER-076 I-09),
            // and so does a dialog of the page answered Cancel, or Stay (Codex
            // review 1 of I-09, P1-3). A dialog that named the user's part ends
            // the errand there, before any limit reads the step (Claude review
            // of I-09, kept 2).
            took(shown ?? acting)
            var held = try await postcondition(check)
            noteTabEvents(tab)
            // A click that asked for a window: its address, opened here — only
            // when nothing the tab did on the way failed the click or named the
            // user's part (ITER-076 I-10 merged onto I-09's dialogs).
            if action.operation == .click, let address = parts.bridge.windowsOpened(in: tab).last,
               dialogNamed == nil, !refusedThisStep, !declinedThisStep {
                if let opened = try await openWindow(address, after: check) { held = opened }
                noteTabEvents(tab)
            }
            let failed = held == false || (held == true && (refusedThisStep || declinedThisStep))
            if failed { record.markLastStep(.failed).map(parts.log) }
            // An act with the user's Yes whose delivery is not known — its
            // check did not see it land — is never sent again on this page,
            // not even with a new Yes: a second send would be a second act
            // (ITER-076 stage 3, № 97; a reference agent never replays a
            // mutation).
            if approval != nil, held != true || answeredOnlyByABox { refused[pageAddress, default: []].insert(offered.effect) }
            // A field the step typed in, its text seen there, is this
            // sub-goal's, with that text: a search it sends goes without a Yes
            // (D4) — at once, with the next step.
            if held == true, !failed, acting.operation == .type, let field = acting.target, let text = acting.payload {
                named?.typedInto[field.fingerprint] = text
                if let typed = named?.typedInto, SafetyGuard.searchAddress(typedInto: field, on: target, typed: typed) != nil {
                    named?.searchReady = field.fingerprint
                }
            }
            if let dialogNamed { return try await userPart(dialogNamed, on: target, in: tab) }
        }
        if dialogsThisStep > Self.dialogLimit { return .subgoal(.stuck) }
        progress.record(action, newRow: newRow, subgoalFinished: newRow)
        return stalled()
    }

    /// An action that reached the page, in the last actions the questions
    /// read — and, in an answer errand, in its sub-goal's list (ITER-076
    /// brain).
    private func took(_ action: AgentAction) {
        let taken = Self.recentAction(action)
        recent.append(taken)
        named?.actions.append(Self.listed(taken))
        if let lastPageKey {
            takenFrom.insert(TakenFrom(page: lastPageKey, effect: action.effect))
            pendingIdle = TakenFrom(page: lastPageKey, effect: action.effect)
        }
    }

    /// The page's one control that clicks or opens under `label`, or none: two of that label, or none, direct
    /// nothing — a label the reader wrote is matched against the page's own, never trusted (2026-10-15).
    private static func expanding(_ label: String, in set: CandidateSet) -> Candidate? {
        let named = set.candidates.filter {
            ($0.action.operation == .click || $0.action.operation == .open) && $0.action.target?.name == label
        }
        return named.count == 1 ? named[0] : nil
    }

    /// The no-progress rule (§6.5): a rows errand ends stuck; in an answer errand the sub-goal ends stuck and the
    /// model names another way, the stall's evidence spent — a recovery's worth, at most `maxRecoveries` an errand
    /// with the recoveries, then the errand ends stuck (2026-10-15: one Jev loop on one page ended five errands of
    /// the bench; a reference browser agent sends a stall to recovery, `agent.py` 2373-2386, MIT).
    private func stalled() -> StepEnd? {
        guard progress.isStuck else { return nil }
        guard named != nil, recoveries < Self.maxRecoveries else { return .errand(.stuck) }
        recoveries += 1
        progress = ProgressTracker()
        return .subgoal(.stuck)
    }

    /// What the recovery step came to (2026-10-15).
    private enum Recovered {
        case directed(AgentAction), gaveUp, none, ended(ErrandRecord.Ending)
    }

    /// The step the text model names when Jev is unsure (2026-10-15; a reference browser agent's `_recover`,
    /// `agent.py` 2373-2500, MIT): the page's listed actions, the page, the notes, the recent steps, what it said
    /// before, what is still to do, the task and the problem — one of the actions, none, or giving up. Its words go
    /// to its next call only; the record keeps the call by its numbers.
    private func recover(_ actions: [AgentAction], on page: ObservedPage, plan: AgentPlan, problem: String)
        async throws -> Recovered {
        guard let model = parts.model else { return .none }
        recoveries += 1
        let (goal, subgoal, steps, today) = (plan.goal, named?.goal, recent.all, Self.today())
        let notes = ErrandModel.notes(record.facts, record.statements)
        let (memory, still) = (recoveryMemory, stillToDo(plan).map(\.line))
        let worstCase = ErrandModel.worstCaseUSD(of: ErrandModel.recoverRequest(
            goal: goal, subgoal: subgoal, actions: actions, page: page, notes: notes, steps: steps, memory: memory,
            today: today, stillToDo: still, problem: problem))
        switch try await askModel(.recover, worstCaseUSD: worstCase, usage: { $0.usage }, {
            try await model.recover(goal: goal, subgoal: subgoal, actions: actions, page: page, notes: notes,
                                    steps: steps, memory: memory, today: today, stillToDo: still, problem: problem)
        }) {
        case .ended(let ending): return .ended(ending)
        case .missed: return .none
        case .answered(let recovery):
            recoveryMemory.append("- Reason: \(problem). Diagnosis: \(recovery.diagnosis). Subgoal: \(recovery.nextSubgoal).")
            parts.log("\(ErrandRecord.logPrefix(record.errandID)) recover giveUp=\(recovery.giveUp) "
                      + "action=\(recovery.action.map { "\($0) \(actions[$0 - 1].operation.rawValue)" } ?? "none")")
            if recovery.giveUp { return .gaveUp }
            return recovery.action.map { .directed(actions[$0 - 1]) } ?? .none
        }
    }

    /// No action this step (§6.3): observe again and ask again — twice in a
    /// row is stuck.
    private func miss(_ action: AgentAction?, _ began: ContinuousClock.Instant) -> StepEnd? {
        log(action, .reconsidered, nil, began)
        return attempts.after(.reconsider) == .stuck ? .subgoal(.stuck) : nil
    }

    // MARK: - A web form (ITER-076 stage 7)

    /// A form by the document it was met on, the frame it is in, and its
    /// group there.
    private struct FormKey: Hashable {
        let document: String
        let frame: String?
        let group: Int
    }

    /// A form this errand previewed: its fields as the preview showed them,
    /// whether Fill went through, and how many Send questions it was asked.
    private struct FormState {
        struct Field {
            let identity: ElementIdentity
            let row: FormRow
            let kind: FormFill.Kind?
            /// What Fill left in it: its value, or nothing for a field it left
            /// empty; nil until Fill reached it.
            var typed: String?
        }

        var fields: [Field]
        var filled = false
        var asks = 0
    }

    /// How many times one form's Send is asked: once, and once more after
    /// the site changed a value (the ceiling of № 93) — then the user's.
    static let sendAsks = 2

    /// What a step on a form comes to.
    private enum FormStep {
        /// Fill these fields, previewed first.
        case fill([ObservedElement])
        /// A field of a form previewed before: only its Fill types there.
        case typedByItsFill
        /// A click that may send this filled form.
        case send(FormKey)
        /// A click in no form that may send a form of this page — which, not
        /// known: never taken (review round 1, C4).
        case unknownForm
    }

    /// The form a control is part of, on `page`'s document.
    private func formKey(of control: ObservedElement, on page: ObservedPage) -> FormKey? {
        control.group.map { FormKey(document: page.loadedFrom ?? page.liveAddress, frame: control.frameIdentity, group: $0) }
    }

    /// What `action` is to a form, if anything: a type in a field of a form
    /// of the user's details (`FormFill.fields`), or of one previewed before;
    /// or a click that may send a form Fill filled on this document — a
    /// control of its group; or one in no form, which may send any form of
    /// the page by script: one outside every group of fields sends the form
    /// filled here, when it is the only one and no other group of the page
    /// holds a value. Any other — another group's own control, beside fields
    /// of its own; one beside two filled forms, or a value the user never saw
    /// — sends which form is not known (review round 1, C4): never taken.
    /// Nil: the step is any other.
    private func formStep(for action: AgentAction, on page: ObservedPage) -> FormStep? {
        guard let target = action.target else { return nil }
        switch action.operation {
        case .type:
            if let key = formKey(of: target, on: page), forms[key] != nil { return .typedByItsFill }
            return FormFill.fields(around: target, on: page).map(FormStep.fill)
        case .click:
            guard SafetyGuard.commits(action) else { return nil }
            let document = page.loadedFrom ?? page.liveAddress
            let frame = target.frameIdentity
            let filled = forms.filter { $0.key.document == document && $0.key.frame == frame && $0.value.filled }
            if let key = formKey(of: target, on: page), filled[key] != nil { return .send(key) }
            guard !filled.isEmpty, target.formMethod == nil, target.listForm == nil else { return nil }
            let others = page.elements.filter { $0.frameIdentity == frame && $0.group != nil }
            if let group = target.group, others.contains(where: { $0.group == group && FormFill.holdsAValue($0) }) {
                return .unknownForm
            }
            let filledGroups = Set(filled.keys.map(\.group))
            guard filled.count == 1, let only = filled.first,
                  !others.contains(where: { $0.group.map(filledGroups.contains) == false && FormFill.sendsAValue($0) })
            else {
                return .unknownForm
            }
            return .send(only.key)
        default:
            return nil
        }
    }

    /// A form of the user's details, filled with one Yes (ITER-076 stage 7,
    /// № 92, 180; the owner's decisions 7.1-7.6 of 2026-10-06). Each field's
    /// value is found first: an e-mail, a phone, a web address by code from
    /// the user's details; a message written from the request (text 4); any
    /// other field by the field writer with the details (text 16), kept only
    /// as `FormFill.accept` keeps it; a street address never. A required
    /// field nothing fills ends the errand before the preview, naming it, and
    /// so does a form nothing fills. The preview — every field with its value
    /// and where it came from, a field the site filled too — waits for the
    /// user, never past the errand's expiry; No ends the errand with nothing
    /// typed. Yes holds for the form as it showed it: every field still there
    /// and holding what it held, else it kept changing. Then one batch puts
    /// each value in, in the page's order — a field left empty emptied, one
    /// that holds its value already left — the field found again before
    /// each, Stop and the ceilings checked before each: it stops where a field
    /// changed or is gone, and nothing is typed after Stop. From its first
    /// key to the agent's next act, nothing the tab asks for goes out
    /// (review round 1, C2): a form the page's own script sends meanwhile is
    /// held back — the last field let go within that time, as a person's
    /// next click would — and the form is the user's to finish; a bridge
    /// that cannot hold fills none. Fields filled are progress (№ 39). Nil:
    /// the work goes on.
    private func fillForm(_ fields: [ObservedElement], chosen action: AgentAction, on page: ObservedPage,
                          in tab: BrowserTab, goal: String, confidence: Double,
                          began: ContinuousClock.Instant) async throws -> StepEnd? {
        guard let target = action.target, let key = formKey(of: target, on: page) else { return miss(action, began) }
        let host = URL(string: page.url)?.host ?? ""
        tell(.readingForm(host: host))
        let facts = parts.facts()
        var entries: [FormState.Field] = []
        var missing: [String] = []
        for field in fields {
            let kind = FormFill.kind(of: field)
            var value: FormFill.Value?
            if let kind, [.email, .phone, .website].contains(kind) {
                value = FormFill.fact(kind, in: facts)
            } else if kind?.neverTyped != true {
                switch try await formText(for: field, kind: kind, facts: facts, goal: goal, on: page) {
                case .ended(let ending): return .errand(ending)
                case .missed: value = nil
                case .answered(let written): value = FormFill.accept(written, kind: kind, goal: goal, facts: facts)
                }
            }
            let shown: FormRow.Shown = value.map { .value($0.text, $0.source, unsure: false) }
                ?? (kind?.neverTyped == true ? .neverTyped : .notKnown)
            if value == nil, field.required == true { missing.append(field.name) }
            entries.append(.init(identity: page.identity(of: field), row: FormRow(label: field.name, shown: shown),
                                 kind: kind, typed: nil))
        }
        guard missing.isEmpty, entries.contains(where: { $0.row.value != nil }) else {
            log(action, .handedOver, confidence, began)
            record.form = FormEnding(kind: .detailsMissing, host: host, labels: missing)
            return .errand(.needsUser)
        }
        let destination = Self.destination(of: target, on: page)
        let answer = try await askForm(FormQuestion(kind: .fill, host: host, destination: destination,
                                                    rows: entries.map(\.row)), about: action, on: page, in: tab)
        guard answer == .yes else {
            // Silence ends a preview only at the errand's expiry: its ceiling.
            if answer == nil { try checkpoint() }
            log(action, .refused, confidence, began)
            record.form = FormEnding(kind: .notFilled, host: host, silence: answer == nil)
            return .errand(.stopped)
        }
        let previewed = fields.map(\.valueKey)
        guard var current = try await look(tab), zip(entries, previewed).allSatisfy({ entry, held in
            current.element(matching: entry.identity)?.valueKey == held
        }) else {
            log(action, .gone, confidence, began)
            record.form = FormEnding(kind: .keptChanging, host: host)
            return .errand(.needsUser)
        }
        guard await parts.bridge.holdSends(true, in: tab) else {
            log(action, .handedOver, confidence, began)
            return .errand(.needsUser)
        }
        (heldTab, heldDocument, sendHeld) = (tab, page.loadedFrom, false)
        shownValues += entries.compactMap(\.row.value)
        forms[key] = FormState(fields: entries)
        var stale = false
        batch: for index in entries.indices {
            try checkpoint()
            if stale {
                guard let fresh = try await look(tab) else { break batch }
                (current, stale) = (fresh, false)
            }
            let value = entries[index].row.value ?? ""
            guard let field = current.element(matching: entries[index].identity), field.valueKey == previewed[index] else {
                break batch
            }
            if field.valueKey == FormFill.digest(value) {
                forms[key]?.fields[index].typed = value
                continue
            }
            let act = AgentAction(operation: .type, target: field, destination: nil, payload: value, isPlannedSearch: false)
            let typing = try await typeInto(act, on: current, in: tab, confidence: confidence, began: began)
            stale = true
            if case .typed = typing { forms[key]?.fields[index].typed = value }
            if sendHeld { return heldBack(action, confidence: confidence, began: began) }
            switch typing {
            case .typed:
                continue
            case .gone:
                break batch
            case .ended(let end):
                forms[key]?.filled = true
                return end
            }
        }
        forms[key]?.filled = true
        try checkpoint()
        _ = try await read(ActionScript.letGo, in: tab.inFrame(target.frame))
        _ = try await settle(tab, leaving: nil, on: nil)
        noteTabEvents(tab)
        if sendHeld { return heldBack(action, confidence: confidence, began: began) }
        progress.record(action, newRow: false, subgoalFinished: true)
        tell(.working(title: self.goal, done: 0, wanted: nil))
        return nil
    }

    /// A send a Fill held back (review round 1, C2): the page sent its form by
    /// itself as it was filled. Nothing went out, and the form is the user's
    /// to finish.
    private func heldBack(_ action: AgentAction, confidence: Double, began: ContinuousClock.Instant) -> StepEnd {
        log(action, .handedOver, confidence, began)
        return .errand(.needsUser)
    }

    /// What a writer writes in a form's field (decisions 7.5, 7.6): a
    /// message by text 4 from the request, with its approved input alone; any
    /// other field by text 16, with the user's details.
    private func formText(for field: ObservedElement, kind: FormFill.Kind?, facts: FormFacts, goal: String,
                          on page: ObservedPage) async throws -> Asked<String?> {
        guard let model = parts.model else { return .missed }
        let recentNow = recent.all
        let details = facts.details.map(\.text)
        let message = kind == .message
        let worstCase = ErrandModel.worstCaseUSD(of: message
            ? ErrandModel.fieldTextRequest(goal: goal, field: field, page: page, recent: recentNow)
            : ErrandModel.formFieldTextRequest(goal: goal, details: details, field: field, page: page, recent: recentNow))
        switch try await askModel(.fieldText, worstCaseUSD: worstCase, usage: { $0.usage }, {
            message ? try await model.fieldText(goal: goal, field: field, page: page, recent: recentNow)
                : try await model.formFieldText(goal: goal, details: details, field: field, page: page, recent: recentNow)
        }) {
        case .answered(let written): return .answered(written.text)
        case .missed: return .missed
        case .ended(let ending): return .ended(ending)
        }
    }

    /// Asks a form's question (ITER-076 stage 7): the preview waits for the
    /// user — never past the errand's expiry — the Send for the answer
    /// window. Yes, No, or nil: no answer in time. Stop ends the step.
    private func askForm(_ form: FormQuestion, about action: AgentAction, on page: ObservedPage,
                         in tab: BrowserTab) async throws -> ConfirmationRequest.Answer? {
        let request = ConfirmationRequest(action: action, tab: tab, pageURL: page.liveAddress, askedAt: .now, form: form)
        let asked = workClock.now
        let confirm = parts.confirm
        note(.question(about: action))
        questionOpen = true
        let left = budget.timeLeft(now: .now)
        let window = request.window == nil ? left : min(answerWindow, left)
        let answer = await Deadline.run(within: window) { await confirm(request) } ?? nil
        waitedSinceCheckpoint += workClock.now - asked
        // Stop closed the question on record as it came (`stop`).
        if stopping { throw CancellationError() }
        let outcome = request.outcome(answer: answer, answeredAt: .now, now: .now)
        let given: ConfirmationRequest.Answer? = outcome == .approved ? .yes : answer == .no ? .no : nil
        closeQuestion(given == .yes ? .yes : given == .no ? .no : .expired)
        return given
    }

    /// What typing one of a form's values came to.
    private enum Typing {
        /// It went out: whether it held is the page's to say; the Send shows
        /// what the field holds.
        case typed
        /// Nothing was typed: the field changed, or is covered.
        case gone
        /// The step comes to the user's part, or the errand's end.
        case ended(StepEnd?)
    }

    /// One value of a Fill, typed as any step types — the field aimed at,
    /// the text checked to land — recorded with the user's Yes.
    private func typeInto(_ act: AgentAction, on page: ObservedPage, in tab: BrowserTab, confidence: Double,
                          began: ContinuousClock.Instant) async throws -> Typing {
        noteTabEvents(tab)
        if let dialogNamed { return .ended(try await userPart(dialogNamed, on: page, in: tab)) }
        declinedThisStep = false
        _ = parts.bridge.windowsOpened(in: tab)
        let sending = Sending(outcome: .confirmed, confidence: confidence, began: began)
        switch try await dispatch(act, on: page, in: tab, approval: nil, sending: sending) {
        case .named(let kind):
            return .ended(try await userPart(kind, on: page, in: tab))
        case .fileNeeded(let recorded):
            if !recorded { log(act, .handedOver, confidence, began) }
            return .ended(try await userPart(.file, on: page, in: tab))
        case .finished(let outcome):
            log(act, outcome, confidence, began)
            return outcome == .handedOver ? .ended(try await handOverAtTheAct(act, on: page, in: tab)) : .gone
        case .answered(let outcome):
            return outcome == .handedOver ? .ended(try await handOverAtTheAct(act, on: page, in: tab)) : .gone
        case .changed:
            return .gone
        case .sent(let check):
            took(act)
            let held = try await postcondition(check)
            noteTabEvents(tab)
            if held != true { record.markLastStep(.failed).map(parts.log) }
            if let dialogNamed { return .ended(try await userPart(dialogNamed, on: page, in: tab)) }
            return .typed
        }
    }

    /// A click that may send a filled form (ITER-076 stage 7, № 93): asked
    /// about with the values its fields hold now — and said so when the site
    /// changed one after Fill — bound to them, naming the site the control
    /// pressed sends to when another's (review round 1, C8). A form that
    /// sends anything the question cannot show is never asked about, nor
    /// sent: it is the user's to finish (C5). The agent never pays and never
    /// grants access, a Yes or not: those walls and Jev's grant question come
    /// first, as on any step, and the walls again on the page the Yes came on
    /// — a grant the form came to carry meanwhile included (C7). No, or two
    /// minutes of silence, ends the errand with the form filled, not sent. A
    /// Yes holds only for the page as the question showed it — the same
    /// control, with the words, sending and granting the question saw, every
    /// field holding what it held — and the act reads every field again in
    /// the same script as the click, or, for a person's click, as each event
    /// of the press comes (C3); any change voids the Yes, and the question is
    /// asked once more, saying so; changed again, the errand ends. Once the
    /// click went out, the errand ends: sent, when the next page no longer
    /// shows the form or another to fill; else not confirmed, with that
    /// page's link — never one that holds a value the form held (C9).
    private func sendForm(_ key: FormKey, click action: AgentAction, on page: ObservedPage, in tab: BrowserTab,
                          summary: PageSummary, goal: String, confidence: Double,
                          began: ContinuousClock.Instant) async throws -> StepEnd? {
        guard let form = forms[key], action.target != nil else { return miss(action, began) }
        let host = URL(string: page.url)?.host ?? ""
        if SafetyGuard.pays(action, risk: .irreversible, on: page.flags) {
            log(action, .handedOver, confidence, began)
            return .errand(handOver(.payment, on: page))
        }
        let engine = parts.engine
        switch try await askEngine(usage: { $0.usage }, { [action] in
            try await engine.risk(of: action, on: summary, goal: goal)
        }) {
        case .ended(let ending): return .errand(ending)
        case .missed: return miss(action, began)
        case .answered(let answer):
            guard let grants = AgentPolicy.grants(noul: answer.grant) else { return miss(action, began) }
            if grants {
                log(action, .handedOver, confidence, began)
                return try await userPart(.grant, on: page, in: tab)
            }
        }
        var current = page
        var clicked = action
        var changed = false
        while (forms[key]?.asks ?? Self.sendAsks) < Self.sendAsks {
            let outside = clicked.target?.group != key.group
            guard let control = clicked.target, let shown = Self.sendRows(form, key: key, on: current, outside: outside)
            else {
                log(action, .handedOver, confidence, began)
                return .errand(.needsUser)
            }
            forms[key]?.asks += 1
            let bound = Self.bound(key, on: current, outside: outside)
            let question = FormQuestion(kind: .send, host: host, destination: Self.destination(of: control, on: current),
                                        rows: shown.rows, changed: changed || shown.changed)
            let answer = try await askForm(question, about: clicked, on: current, in: tab)
            guard answer == .yes else {
                log(action, .refused, confidence, began)
                record.form = FormEnding(kind: .notSent, host: host, silence: answer == nil)
                return .errand(.stopped)
            }
            // The Yes holds for the page as the question showed it.
            guard let fresh = try await look(tab) else {
                changed = true
                continue
            }
            let asked = ConfirmationRequest(action: clicked, tab: tab, pageURL: current.liveAddress, askedAt: .now)
            let again = fresh.element(matching: current.identity(of: control)).map {
                AgentAction(operation: .click, target: $0, destination: nil, payload: nil, isPlannedSearch: false)
            }
            guard let again, asked.stillHolds(for: again, tab: tab, pageURL: fresh.liveAddress),
                  Self.bound(key, on: fresh, outside: outside) == bound, let button = again.target else {
                (current, changed) = (fresh, true)
                if let again { clicked = again }
                continue
            }
            // The walls, on the page the Yes came on (as `step` reads them
            // after any Yes) — a grant first: an OAuth request the form came
            // to carry while the question waited (review round 1, C7).
            if SafetyGuard.isGrant(again) {
                log(action, .handedOver, confidence, began)
                return try await userPart(.grant, on: fresh, in: tab)
            }
            if button.needsFile == true {
                log(action, .handedOver, confidence, began)
                return try await userPart(.file, on: fresh, in: tab)
            }
            if button.touchesSecret || SafetyGuard.needsTheUsersSecret(again) {
                log(action, .handedOver, confidence, began)
                return try await userPart(fresh.flags(of: button).paymentForm ? .payment : .signIn, on: fresh, in: tab)
            }
            if SafetyGuard.pays(again, risk: .irreversible, on: fresh.flags) {
                log(action, .handedOver, confidence, began)
                return .errand(handOver(.payment, on: fresh))
            }
            noteTabEvents(tab)
            if let dialogNamed { return try await userPart(dialogNamed, on: fresh, in: tab) }
            declinedThisStep = false
            _ = parts.bridge.windowsOpened(in: tab)
            // Every value the form holds as it goes — Fill's, and what the
            // user said Yes to — is kept out of a link (review round 1, C9).
            shownValues += shown.rows.compactMap(\.value)
            let held = shownValues
            // Bound, as the step binds any Yes, to the control as the question
            // showed it — its words, whether it sends its form and grants —
            // and to the payment evidence on the page now (review round 1, C7).
            let approval = ActionScript.Approval(pageURL: current.address(of: control), text: control.text,
                                                 formSubmitLabel: control.formSubmitLabel, submits: control.submits,
                                                 formGrants: control.formGrants,
                                                 paymentForm: fresh.flags(of: button).paymentForm,
                                                 listForm: control.listForm, formValues: bound)
            let sending = Sending(outcome: .confirmed, confidence: confidence, began: began,
                                  form: FormEnding(kind: .notConfirmed, host: host,
                                                   url: FormFill.link(fresh.url, holding: held)))
            switch try await dispatch(again, on: fresh, in: tab, approval: approval, sending: sending) {
            case .changed:
                takeBackForm(sending)
                // Asked again, the form is as it was before the press: what
                // the page sends meanwhile is held back (review round 1, C2).
                if await parts.bridge.holdSends(true, in: tab) { (heldTab, heldDocument) = (tab, fresh.loadedFrom) }
                current = try await look(tab) ?? fresh
                clicked = current.element(matching: fresh.identity(of: button)).map {
                    AgentAction(operation: .click, target: $0, destination: nil, payload: nil, isPlannedSearch: false)
                } ?? again
                changed = true
            case .named(let kind):
                takeBackForm(sending)
                return try await userPart(kind, on: fresh, in: tab)
            case .fileNeeded(let recorded):
                takeBackForm(sending)
                if !recorded { log(again, .handedOver, confidence, began) }
                return try await userPart(.file, on: fresh, in: tab)
            case .finished(let outcome):
                takeBackForm(sending)
                log(again, outcome, confidence, began)
                return outcome == .handedOver ? try await handOverAtTheAct(again, on: fresh, in: tab) : nil
            case .answered(let outcome):
                takeBackForm(sending)
                return outcome == .handedOver ? try await handOverAtTheAct(again, on: fresh, in: tab) : nil
            case .sent(let check):
                took(again)
                _ = try await postcondition(check)
                noteTabEvents(tab)
                let after = try await look(tab) ?? fresh
                return .errand(sent(key, rows: shown.rows, after: after, host: host, held: held))
            }
        }
        log(action, .gone, confidence, began)
        record.form = FormEnding(kind: .keptChanging, host: host)
        return .errand(.needsUser)
    }

    /// How a form's Send that went out ended (ITER-076 stage 7, № 183): sent,
    /// when the next page shows none of the form's fields and no form to
    /// fill — the fields sent named by their kinds and their labels, the
    /// page after it its link; not confirmed otherwise, with that link.
    private func sent(_ key: FormKey, rows: [FormRow], after: ObservedPage, host: String,
                      held: [String]) -> ErrandRecord.Ending {
        let link = FormFill.link(after.url, holding: held)
        guard let form = forms[key], !form.fields.contains(where: { after.element(matching: $0.identity) != nil }),
              !FormFill.showsAFormToFill(after) else {
            record.form = FormEnding(kind: .notConfirmed, host: host, url: link)
            return .needsUser
        }
        let fields = zip(form.fields, rows).filter { $0.1.value != nil }
        var kinds: [String] = []
        for (field, _) in fields {
            if let kind = field.kind?.rawValue, !kinds.contains(kind) { kinds.append(kind) }
        }
        record.form = FormEnding(kind: .sent, host: host, kinds: kinds, labels: fields.map(\.1.label), url: link)
        return .done
    }

    /// The fields of `key`'s form on `page`, bound to what each holds now.
    private static func bound(_ key: FormKey, on page: ObservedPage, outside: Bool) -> [ActionScript.BoundValue] {
        submitted(key, on: page, outside: outside).compactMap { ActionScript.BoundValue($0, on: page) }
    }

    /// What a press may send with `key`'s form, on `page` (review round 2,
    /// R2-3): every control of its group — a `<form>`'s group holds every
    /// control it submits, one joined to it by its `form` attribute too —
    /// and, for a press from outside the group, whose script may gather any
    /// field of the page, every control in no group as well.
    private static func submitted(_ key: FormKey, on page: ObservedPage, outside: Bool) -> [ObservedElement] {
        page.elements.filter { $0.frameIdentity == key.frame && ($0.group == key.group || (outside && $0.group == nil)) }
    }

    /// The Send's rows, read on `page`, and whether the site changed a value
    /// after Fill: each field of the preview with what Fill left in it — its
    /// value, whole, with its source, or left empty — or, where the site
    /// changed a value of Fill's, what it holds now, to check. Nil when the
    /// form would send what no approved row shows (review round 1, C5; Kimi
    /// P2-2): a value the site put where Fill left none, a value of Fill's
    /// the site emptied, a field gone, one Fill never reached that holds
    /// something or was to — and any other control of the form that sends
    /// something as it stands: a box ticked, a choice made, a field Fill
    /// never typed in — any control the press may send with it
    /// (`submitted(_:on:outside:)`) — on a page read whole: one not read whole
    /// may hold one no look reported (review round 2, R2-3). A value the
    /// site changed is shown only when the look holds it whole: one longer
    /// than a look holds, or read other than it stands, could be shown only
    /// cut while the whole is bound and sent (R2-4).
    private static func sendRows(_ form: FormState, key: FormKey, on page: ObservedPage, outside: Bool)
        -> (rows: [FormRow], changed: Bool)? {
        guard !page.truncated else { return nil }
        var rows: [FormRow] = []
        var changed = false
        var shown: Set<Int> = []
        for field in form.fields {
            guard let element = page.element(matching: field.identity) else { return nil }
            shown.insert(element.index)
            let label = field.row.label
            let empty: FormRow.Shown = field.row.shown == .neverTyped ? .neverTyped : .notKnown
            let now = element.value ?? ""
            switch (field.typed, field.row.shown) {
            case ("", _), (nil, .notKnown), (nil, .neverTyped):
                guard element.valueKey == FormFill.digest("") else { return nil }
                rows.append(FormRow(label: label, shown: empty))
            case (let typed?, .value(_, let source, let unsure)) where element.valueKey == FormFill.digest(typed):
                rows.append(FormRow(label: label, shown: .value(typed, source, unsure: unsure)))
            case (_?, .value(_, let source, _)) where !now.isEmpty && element.valueKey == FormFill.digest(now):
                rows.append(FormRow(label: label, shown: .value(now, source, unsure: true)))
                changed = true
            default:
                return nil
            }
        }
        let others = submitted(key, on: page, outside: outside).filter { !shown.contains($0.index) }
        guard !others.contains(where: FormFill.sendsAValue) else { return nil }
        return (rows, changed)
    }

    /// The site a form is set to send to, when it is another than the page's:
    /// its action's host. Nil for a form a script sends, whose action is not
    /// known.
    private static func destination(of control: ObservedElement, on page: ObservedPage) -> String? {
        guard let action = control.formAction, let to = URL(string: action)?.host?.lowercased(),
              let from = URL(string: page.url)?.host?.lowercased(), to != from else { return nil }
        return to
    }

    // MARK: - Calls

    /// What a paid call came to: its answer; none — with the error it
    /// failed with, or nil when its time ran out first; or over the budget.
    private enum Paid<T> {
        case answered(T), missed((any Error)?), overBudget

        var isAnswered: Bool {
            if case .answered = self { return true }
            return false
        }
    }

    /// A paid call (§8), made only while Stop is not pressed and no ceiling is
    /// reached: its worst case is reserved first — refused if it would cross
    /// the spend ceiling — its deadline never runs past the expiry nor the
    /// work's time left (review round 1, P2-5), and its real cost is settled
    /// after and kept in the record, whatever the call was for (P2-6) — none
    /// for a call that reached no model (ITER-076 stage 8a). A timeout or an
    /// error comes back as a miss, with the error — a call not sent, with
    /// what it came to: the caller decides what it means. Stop, pressed while
    /// it ran, ends the step here.
    private func paid<T: Sendable>(_ worstCaseUSD: Double, within limit: Duration, usage: (T) -> EngineUsage?,
                                   _ work: @escaping @Sendable () async throws -> T) async throws -> Paid<T> {
        try checkpoint()
        guard let reservation = budget.reserve(worstCaseUSD: worstCaseUSD) else { return .overBudget }
        // In the record before the call goes out, at its worst case: a record
        // saved while it is out — the app quitting — misses no spend (review
        // round 2, P2-6).
        record.spentUSD = budget.committedUSD
        let bound = min(limit, budget.timeLeft(now: .now), budget.activeTimeLeft)
        let result = await Deadline.run(within: bound) { () -> Result<T, any Error> in
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        let answer = try? result?.get()
        let before = budget.spentUSD
        budget.settle(reservation, actualUSD: answer.flatMap(usage)?.costUSD ?? (Self.reachedNoModel(result) ? 0 : nil))
        stepCost += budget.spentUSD - before
        record.spentUSD = budget.committedUSD
        if stopping { throw CancellationError() }
        // Cut off by the errand's own time, not by its deadline: that is the
        // ceiling (§8) — whatever the clocks' last millisecond says.
        if result == nil, bound < limit { throw CeilingReached() }
        switch result {
        case .success(let value)?: return .answered(value)
        case .failure(let unsent as JevDecisionEngine.NotSent)?: return .missed(unsent.failure)
        case .failure(let error)?: return .missed(error)
        case nil: return .missed(nil)
        }
    }

    /// Whether a call that gave no answer reached no model, so it cost
    /// nothing (ITER-076 stage 8a): refused before its request left the Mac,
    /// or turned away by the owner's switch, which the server answers in its
    /// router before it reads anything of the request. Every other call with
    /// no usage counts whole (§8).
    private static func reachedNoModel<T>(_ result: Result<T, any Error>?) -> Bool {
        guard case .failure(let error)? = result else { return false }
        return error is JevDecisionEngine.NotSent || error as? JevDecisionEngine.Failure == .switchedOff
    }

    /// What asking the decision engine came to (ITER-076 I-05).
    private enum Asked<T> {
        case answered(T)
        /// No answer this step: asked again after a new look.
        case missed
        /// The errand ends here.
        case ended(ErrandRecord.Ending)
    }

    /// Asks the decision engine, as a paid call — or, with its worst case and
    /// its deadline, the text model (ITER-076 brain): every service of the
    /// agent says its refusals as `JevDecisionEngine.Failure`. What its
    /// service said is never a miss or "stuck" (ITER-076 I-05): no Pro and the
    /// day's limit end the errand at once; a service that is down, or did not
    /// answer in time, is waited for once — as long as it asked, when that
    /// ends before the errand's time does — and asked again, and a second time
    /// ends the errand as unavailable. Any other failure is a miss.
    private func askEngine<T: Sendable>(_ worstCaseUSD: Double? = nil, within limit: Duration = AgentRun.decisionDeadline,
                                        usage: (T) -> EngineUsage?,
                                        _ work: @escaping @Sendable () async throws -> T) async throws -> Asked<T> {
        // The wait before this call, once there was one: on record with
        // whether the service answered after (ITER-076 I-06a).
        var waited: Duration?
        while true {
            let result: Paid<T>
            do {
                if let waited { try await Task.sleep(for: waited) }
                result = try await paid(worstCaseUSD ?? parts.engine.worstCaseUSD, within: limit, usage: usage, work)
            } catch {
                if let waited { note(.serviceWait(seconds: Self.seconds(waited), answered: nil)) }
                throw error
            }
            if let waited { note(.serviceWait(seconds: Self.seconds(waited), answered: result.isAnswered)) }
            let error: (any Error)?
            switch result {
            case .overBudget: return .ended(.ceiling)
            case .answered(let answer): return .answered(answer)
            case .missed(let failed): error = failed
            }
            let retryAfter: Duration?
            switch error as? JevDecisionEngine.Failure {
            case .noPro?:
                return .ended(.noPro)
            case .dailyLimit(let after)?:
                retryAt = after.map { Date.now.addingTimeInterval(Self.seconds($0)) }
                return .ended(.dailyLimit)
            case .unavailable(let after)?:
                retryAfter = after
            case .timedOut?:
                retryAfter = nil
            case .invalid?, .invalidAnswer?:
                return .missed
            case .switchedOff?:
                // The owner's switch (ITER-076 stage 9d, № 27): stopped at
                // once — no wait, no second try, no failure to report.
                parts.switchedOff()
                return .ended(.stopped)
            case nil:
                // Its time ran out before any answer: late, as a 504 is.
                guard error == nil else { return .missed }
                retryAfter = nil
            }
            try checkpoint()
            let wait = retryAfter ?? Self.serviceRetryWait
            guard waited == nil, budget.fits(wait, now: .now) else {
                retryAt = retryAfter.map { Date.now.addingTimeInterval(Self.seconds($0)) }
                failure = .engineUnavailable
                return .ended(.unavailable)
            }
            waited = wait
        }
    }

    /// Asks the text model (ITER-076 brain) as every service is asked
    /// (`askEngine`), and keeps the call on record: its purpose, how it went,
    /// its time and its cost — numbers only.
    private func askModel<T: Sendable>(_ purpose: ProLLMClient.Request.Purpose, worstCaseUSD: Double,
                                       within limit: Duration = AgentRun.modelDeadline, usage: (T) -> EngineUsage?,
                                       _ work: @escaping @Sendable () async throws -> T) async throws -> Asked<T> {
        let began = ContinuousClock.now
        let before = stepCost
        var result = ErrandRecord.Event.Plan.failed
        defer { note(.model(purpose, result, milliseconds: Self.milliseconds(since: began), costUSD: stepCost - before)) }
        do {
            let asked = try await askEngine(worstCaseUSD, within: limit, usage: usage, work)
            switch asked {
            case .answered: result = .ok
            case .ended(.ceiling): result = .ceiling
            case .ended, .missed: break
            }
            return asked
        } catch is CeilingReached {
            result = .ceiling
            throw CeilingReached()
        } catch {
            if stopping { result = .stopped }
            throw error
        }
    }

    /// What the text model writes in the field `action` types in: the
    /// field's text, or none (ITER-076 brain, text 4).
    private func written(for action: AgentAction, goal: String, on page: ObservedPage) async throws -> Asked<String?> {
        guard let model = parts.model, let field = action.target else { return .missed }
        let recentNow = recent.all
        let worstCase = ErrandModel.worstCaseUSD(of: ErrandModel.fieldTextRequest(goal: goal, field: field, page: page,
                                                                                   recent: recentNow))
        switch try await askModel(.fieldText, worstCaseUSD: worstCase, usage: { $0.usage }, {
            try await model.fieldText(goal: goal, field: field, page: page, recent: recentNow)
        }) {
        case .answered(let written): return .answered(written.text)
        case .missed: return .missed
        case .ended(let ending): return .ended(ending)
        }
    }

    private enum RowResult { case added, notAdded, overBudget }

    /// The writer turns the page's excerpt into a row (§6.6); a site already
    /// collected is not asked about again.
    private func collectRow(in tab: BrowserTab, subgoal: AgentPlan.Subgoal, plan: AgentPlan) async throws -> RowResult {
        await loaded(tab)
        guard let json = try await read(ObserverScript.excerptSource(limit: Self.excerptLimit), in: tab) else {
            return .notAdded
        }
        guard let excerpt = try? PageExcerpt.decode(json) else {
            note(.pageMiss(.report))
            return .notAdded
        }
        guard let source = URL(string: excerpt.url),
              let site = Scratchpad.site(of: source),
              !scratchpad.rows.contains(where: { Scratchpad.site(of: $0.source) == site }) else { return .notAdded }
        guard let writer = parts.writer else { return .notAdded }
        let columns = plan.columns
        switch try await paid(writer.worstCaseUSD, within: Self.writerDeadline, usage: { $0.usage },
                              { try await writer.row(columns: columns, subgoal: subgoal, excerpt: excerpt) }) {
        case .overBudget: return .overBudget
        case .missed: return .notAdded
        case .answered(let row):
            guard scratchpad.add(cells: row.cells, source: source) == nil else { return .notAdded }
            // In the record at once: a Stop, a sleep or a quit that saves the
            // record before the run returns keeps it (ITER-076 I-05).
            record.rows = scratchpad.rows
            tell(.working(title: plan.sheetTitle, done: record.rows.count, wanted: plan.rowsWanted))
            return .added
        }
    }

    /// What asking the user came to.
    private enum Answered {
        /// Yes, and the action still stands, as it does on this fresh look.
        case approved(ObservedPage, AgentAction)
        /// No, or no answer in time.
        case refused
        /// Yes, but the action is not there as it was.
        case lapsed
    }

    /// Asks about one irreversible action (§7.1). The Yes holds only if, when
    /// it comes, the same action is still there unchanged on the same page;
    /// that fresh observation, and the action as it stands on it, are what
    /// the action is taken on. Stop while it waits ends the step; so does the
    /// browser lost.
    private func askUser(_ action: AgentAction, on page: ObservedPage, in tab: BrowserTab) async throws -> Answered {
        let request = ConfirmationRequest(action: action, tab: tab, pageURL: page.liveAddress, askedAt: .now)
        let asked = workClock.now
        let confirm = parts.confirm
        note(.question(about: action))
        questionOpen = true
        // No longer than the answer window, and never past the expiry (§8).
        let window = min(answerWindow, budget.timeLeft(now: .now))
        let answer = await Deadline.run(within: window) { await confirm(request) } ?? nil
        waitedSinceCheckpoint += workClock.now - asked
        // Stop closed the question on record as it came (`stop`).
        if stopping { throw CancellationError() }
        let approved = request.outcome(answer: answer, answeredAt: .now, now: .now) == .approved
        closeQuestion(approved ? .yes : answer == .no ? .no : .expired)
        guard approved else { return .refused }
        // Each lapse names what changed on the log (2026-10-21: 19 of 21 Yes answers on one blind task lapsed, cause
        // unknown).
        let lapsed = { (why: String) -> Answered in
            self.parts.log("\(ErrandRecord.logPrefix(self.record.errandID)) the Yes lapsed: \(why)")
            return .lapsed
        }
        guard let fresh = try await look(tab) else { return lapsed("no fresh look") }
        var again = action
        if let target = action.target {
            let identity = page.identity(of: target)
            guard let element = fresh.element(sameAs: target, matching: identity, seenIn: page) else {
                let twins = fresh.elements.filter { $0.fingerprint == identity.fingerprint }.count
                return lapsed("the target is not found again (\(identity.total) like it before, \(twins) now)")
            }
            again = AgentAction(operation: action.operation, target: element, destination: action.destination,
                                payload: action.payload, isPlannedSearch: action.isPlannedSearch)
        }
        if let why = request.lapse(for: again, tab: tab, pageURL: fresh.liveAddress) { return lapsed(why) }
        return .approved(fresh, again)
    }

    /// The open question's answer, on record once.
    private func closeQuestion(_ answer: ErrandRecord.Event.Answer) {
        questionOpen = false
        note(.answer(answer))
    }

    // MARK: - The user's part

    /// The check the hands met at the act (2026-10-08), on the log: a
    /// hand-over names its cause — a false one, the check to fix.
    private func noteWall(_ why: String?) {
        parts.log("\(ErrandRecord.logPrefix(record.errandID)) the hands met a wall: \(why ?? "unnamed")")
    }

    /// The step is the user's part (§7.2, §11), and the errand ends there:
    /// the run says what it is and on which site.
    private func handOver(_ kind: ErrandHandover.Kind, on page: ObservedPage) -> ErrandRecord.Ending {
        let host = URL(string: page.url)?.host ?? ""
        // On record as it is told: never once Stop was pressed.
        if !stopRequested { note(.handover(kind, host: host)) }
        tell(.needsUser(ErrandHandover(kind: kind, host: host)))
        return .needsUser
    }

    /// The step is the user's part (§7.2, §11; ITER-076 stage 3, owner
    /// decision 6). A payment ends the errand at once (L4). Any other part is
    /// waited for, its tab the user's (`BrowserBridge.lend`), the step's Yes
    /// taken back first: up to `pauseWindow`, never past the expiry, none of
    /// the wait counted as the errand's work. Continue: the step ends without
    /// acting, and the next one looks at the page again from scratch — a part
    /// still there waits again. Its window running out ends the errand as the
    /// user's part, the expiry at its ceiling; Stop ends it at once. Nil: the
    /// work goes on.
    private func userPart(_ kind: ErrandHandover.Kind, on page: ObservedPage, in tab: BrowserTab) async throws -> StepEnd? {
        guard kind.waits else { return .errand(handOver(kind, on: page)) }
        let continued = try await waited(for: ErrandHandover(kind: kind, host: URL(string: page.url)?.host ?? ""),
                                         in: tab)
        try checkpoint()
        guard continued else { return .errand(.needsUser) }
        note(.continued)
        // What a page's own dialog named was the user's to do: done.
        dialogNamed = nil
        return nil
    }

    /// The wait for the user's part in `tab` (ITER-076 stage 3): on record
    /// as it is told — never once Stop was pressed — the step's Yes taken
    /// back, the tab lent to them for up to `pauseWindow`, never past the
    /// expiry, none of the wait counted as the errand's work. True once they
    /// said Continue; Stop ends it.
    private func waited(for handover: ErrandHandover, in tab: BrowserTab) async throws -> Bool {
        if !stopRequested { note(.handover(handover.kind, host: handover.host)) }
        parts.bridge.approve(nil, in: tab)
        await releaseSends()
        let window = min(pauseWindow, budget.timeLeft(now: .now))
        let began = workClock.now
        await parts.bridge.lend(tab)
        let wait = parts.waitForUser
        let continued = await Deadline.run(within: window) { await wait(handover, tab, window) } ?? false
        waitedSinceCheckpoint += workClock.now - began
        await parts.bridge.reclaim(tab)
        if stopping { throw CancellationError() }
        return continued
    }

    /// A wall the hands met at the act (ITER-076 2.2, S3): a page that takes
    /// a payment now — asks card details (owner decision of 2026-10-19) — is
    /// a payment; a secret field that came is a sign-in. What the page shows
    /// now decides — the look before the act did not see it. A page that
    /// cannot be read may take a payment: it ends the errand, never waits
    /// (L4).
    private func handOverAtTheAct(_ action: AgentAction, on page: ObservedPage,
                                  in tab: BrowserTab) async throws -> StepEnd? {
        guard let now = try await look(tab) else { return .errand(handOver(.signIn, on: page)) }
        let target = action.target.flatMap { now.element(matching: page.identity(of: $0)) }
        parts.log("\(ErrandRecord.logPrefix(record.errandID)) at the act the page takes a payment: "
                  + "\(now.flags.paymentForm), asks a sign-in: \(now.flags.loginForm), a frame beside the target: "
                  + "\(target?.holdsFrame == true)")
        return try await userPart(now.flags.paymentForm ? .payment : .signIn, on: now, in: tab)
    }

    /// A check that may clear itself — a widget a page shows while it checks
    /// its visitor — waited out before it is the user's part (a reference
    /// browser agent's `_outwait`, `agent.py` 912-919, MIT): the page looked
    /// at again every `checkPoll`, for up to `checkWait`. True when it moved
    /// on meanwhile: the next step looks again.
    private func outwaited(_ page: ObservedPage, in tab: BrowserTab) async throws -> Bool {
        let stuck = Self.pageKey(of: page)
        let deadline = ContinuousClock.now + checkWait
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: Self.checkPoll)
            try checkpoint()
            if let now = try await look(tab), Self.pageKey(of: now) != stuck { return true }
        }
        return false
    }

    // MARK: - Acting and checking

    /// What sending an action led to (review round 1, P1-1): finished —
    /// nothing went out, or nothing there to check, and nothing recorded yet;
    /// answered — it went out, was recorded as it did, and the page said
    /// nothing happened, which the record now says; or sent — recorded as it
    /// went out, with what its postcondition needs.
    private enum Dispatch {
        case finished(ErrandRecord.Outcome)
        case answered(ErrandRecord.Outcome)
        case sent(Postcheck)
        /// The act found its form needs the user's file, and did nothing;
        /// `recorded`: the step is on record already, marked handed over.
        case fileNeeded(recorded: Bool)
        /// A page's own dialog named the user's part — what it named — before
        /// the act went out: nothing was sent, nothing recorded.
        case named(ErrandHandover.Kind)
        /// A form's Send found a field its Yes was bound to changed (ITER-076
        /// stage 7): nothing was sent.
        case changed
    }

    /// How an action is recorded the moment it goes out — and, for a form's
    /// Send, how its form stands from then on (ITER-076 stage 7): pressed,
    /// whatever comes after.
    private struct Sending {
        let outcome: ErrandRecord.Outcome
        let confidence: Double
        let began: ContinuousClock.Instant
        var form: FormEnding? = nil
    }

    /// What checking an action's postcondition needs once it reached the page.
    private struct Postcheck {
        let action: AgentAction
        let page: ObservedPage
        /// For an open or back: where the tab was, which it must leave.
        let before: String?
        let moved: Bool?
        /// Where the tab must end: an open's destination, or back's address.
        let expected: URL?
        let tab: BrowserTab
        /// For a type through trusted input: what the typing came to.
        var typed: TrustedTyping.Typed? = nil
        /// It went out with the user's Yes (ITER-076 I-10).
        var approved = false
    }

    /// Sends the action to the page, with Stop and the ceilings checked right
    /// before it goes, and recorded as it goes.
    private func dispatch(_ action: AgentAction, on page: ObservedPage, in tab: BrowserTab,
                          approval: ActionScript.Approval?, sending: Sending) async throws -> Dispatch {
        switch action.operation {
        case .wait:
            try await Task.sleep(for: Self.waitStep)
            return .finished(.acted)
        // «More» is never offered (ITER-076 stage 3, № 65): nothing to do.
        case .more, .done, .stuck:
            return .finished(.acted)
        case .back:
            // Back goes back in the tab's own history, so the page comes back
            // as it was left (ITER-076 I-10, critic 22) — to the entry the
            // history holds now: it may have changed since the look that
            // offered it (a reference browser agent's `_back`, `page.py`
            // 993-1009, MIT).
            guard let entry = try await backEntry(in: tab), let previous = URL(string: entry.url) else {
                return .finished(.unsupported)
            }
            navigatesAway(to: entry.url, in: tab)
            let before = try await marker(tab)
            try checkpoint()
            if let named = readiedToSend(tab) { return named }
            // From here the page may act: whatever the reply, the action counts
            // as sent, and its postcondition decides (§6.5, §7.4). A bridge that
            // says nothing went out — Stop before the call — takes the record
            // back.
            recordSending(action, sending)
            do {
                try await parts.bridge.goBack(to: entry.id, in: tab)
            } catch is CancellationError {
                record.removeLastStep().map(parts.log)
                throw CancellationError()
            } catch {}
            return .sent(Postcheck(action: action, page: page, before: before, moved: nil, expected: previous, tab: tab))
        case .open, .click, .type, .select, .scroll:
            // An open, or a click on a link, is the agent's own navigation:
            // it goes while a form's sends are held (review round 2, R2-2).
            navigatesAway(to: action.operation == .open ? action.destination
                            : action.operation == .click ? action.target?.href : nil, in: tab)
            // A click or a type goes in as a person's input where the bridge
            // can send it (ITER-076 3.1): some sites ignore scripted input.
            if let hands = parts.bridge as? TrustedInputBridge,
               let aim = ActionScript.aim(for: action, on: page, approval: approval) {
                return try await dispatchTrusted(action, aim: aim, on: page, hands: hands, in: tab, approval: approval,
                                                 sending: sending)
            }
            // An act that commits is found alone first, in its control's
            // document, with every check it makes: how many frames that
            // document holds is what an aim says of a press — a frame the
            // page brought since the step's look is read at the act, and one
            // it brings after makes the act gone (ITER-076 I-09, round 5;
            // Claude review c10, #14).
            var framesSeen: Int?
            if let found = ActionScript.found(for: action, on: page, approval: approval) {
                switch try await probed(found, in: tab.inFrame(action.target?.frame)) {
                case .missed(let missed): return missed
                case .found(let frames): framesSeen = frames
                }
            }
            guard let script = ActionScript.source(for: action, on: page, approval: approval, framesKnown: framesSeen)
            else {
                return .finished(.unsupported)
            }
            if case .stop(let missed) = try await checkedAgainAtTheAct(action, on: page, approval: approval, in: tab,
                                                                       aimSawFrames: (framesSeen ?? 0) > 0) {
                return missed
            }
            let before = try await marker(tab)
            try checkpoint()
            if let named = readiedToSend(tab) { return named }
            let place = Self.place(of: action, in: tab)
            // From here the page may act. A reply that says the element was
            // gone, ambiguous or unsupported means nothing happened; any other
            // reply — or none, when it is lost — means the action counts as
            // sent, and its postcondition decides (§6.5, §7.4).
            if approval != nil { parts.bridge.approve(ApprovedAct(action), in: tab) }
            // A form's Send, approved: what the press sends goes (R2-2).
            if approval?.formValues != nil { await releaseSends() }
            let reply = try await sendAct(script, action, sending, in: place).flatMap { try? ActionOutcome.decode($0) }
            switch reply?.outcome {
            case .gone, .covered: return answered(.gone)
            case .ambiguous: return answered(.ambiguous)
            case .unsupported: return answered(.unsupported)
            case .wall:
                noteWall(reply?.why)
                return answered(.handedOver)
            case .file:
                record.markLastStep(.handedOver).map(parts.log)
                return .fileNeeded(recorded: true)
            case .changed:
                record.markLastStep(.gone).map(parts.log)
                takeBackForm(sending)
                return .changed
            // Not an act's answer: counted as sent, and the postcondition decides.
            case .held, .differs, .aim, .ready, .done, .found, .armed, nil: break
            }
            if action.operation == .open, approval != nil, let destination = action.destination {
                approvedAddresses.insert(Self.requested(destination))
            }
            let expected = action.operation == .open ? action.destination.flatMap(URL.init(string:)) : nil
            return .sent(Postcheck(action: action, page: page, before: before, moved: reply?.moved,
                                   expected: expected, tab: tab, approved: approval != nil))
        }
    }

    /// A click or a type through trusted input (ITER-076 3.1). The aim makes
    /// every check an act makes, and a hit test; until the click nothing has
    /// happened, so a lost or refused aim sends nothing — the target changed
    /// or is covered, and the next step looks again, as in jev-ultrafast.
    /// The point is measured again right before the press — a frame's once
    /// every document on the way has drawn: a target that moved is aimed at
    /// where it is now, once, and one that moves again is gone — a moving
    /// target never earns a press (a reference browser agent's
    /// `_click_point`, `page.py` 1058-1090, MIT; review of I-09, F1). Stop and the ceilings are checked
    /// before the aim, which may scroll the page, and again right before the
    /// click, which follows the last measure with nothing between. A look at
    /// the act made after the aim (`checkedAgainAtTheAct`) takes a while, and
    /// the page may move meanwhile: the point is measured once more after it,
    /// with every check an aim makes, and pressed only where the steady point
    /// before the look was — a target that moved during it is gone, and the
    /// next step looks again; the press never goes to a point measured before
    /// the last check (Codex review 2 of I-09, P1-4; Claude review c8, #18).
    /// From the click on the page may act: the action counts as sent, and its
    /// postcondition decides — but a form's Send carries its check into the
    /// press, armed right before it: the press its own check voided reached
    /// the page in nothing, and is no send (ITER-076 stage 7, review round 1,
    /// C3). A type's text goes where the focus went once a field of the
    /// page's holds it, and is checked to have landed (`TrustedTyping`,
    /// ITER-076 I-07); none goes in after Stop.
    private func dispatchTrusted(_ action: AgentAction, aim: String, on page: ObservedPage,
                                 hands: any TrustedInputBridge, in tab: BrowserTab,
                                 approval: ActionScript.Approval?, sending: Sending) async throws -> Dispatch {
        try checkpoint()
        let place = Self.place(of: action, in: tab)
        var at: (x: Double, y: Double)
        var framesSeen: Int
        switch try await aimed(aim, in: place, hands: hands) {
        case .missed(let missed): return missed
        case .at(let point, let frames): (at, framesSeen) = (point, frames)
        }
        var steady = false
        for _ in 0..<2 where !steady {
            switch try await aimed(aim, in: place, hands: hands) {
            case .missed(let missed): return missed
            case .at(let point, let frames):
                steady = point == at
                (at, framesSeen) = (point, frames)
            }
        }
        guard steady else {
            parts.log("\(ErrandRecord.logPrefix(record.errandID)) the aim did not hold still: the control moved")
            return .finished(.gone)
        }
        switch try await checkedAgainAtTheAct(action, on: page, approval: approval, in: tab,
                                              aimSawFrames: framesSeen > 0) {
        case .stop(let missed):
            return missed
        case .checked:
            // A frame the act's document holds that the aims before the look
            // did not count may have come after the look listed the frames:
            // never read, it ends the step, and the next one looks again
            // (ITER-076 I-09, round 5; Claude review c10, #16).
            switch try await aimed(aim, in: place, hands: hands) {
            case .missed(let missed): return missed
            case .at(let point, let frames): guard point == at, frames <= framesSeen else { return .finished(.gone) }
            }
        case .unchecked:
            break
        }
        let (x, y) = at
        try checkpoint()
        if let named = readiedToSend(tab) { return named }
        // A form's Send carries its check into the press, armed last — right
        // before it — as the press's own events come (ITER-076 stage 7,
        // review round 1, C3).
        let checked = approval.flatMap { ActionScript.arm(for: action, on: page, approval: $0) }
        if let checked {
            let armed = try await read(checked, in: place).flatMap { try? ActionOutcome.decode($0) }
            guard armed?.outcome == .armed else { return Self.missed(armed?.outcome) }
        }
        let sent = Dispatch.sent(Postcheck(action: action, page: page, before: nil, moved: nil, expected: nil, tab: tab,
                                           approved: approval != nil))
        recordSending(action, sending)
        // A dialog the page shows for this click is answered OK, once, only
        // when the click has the user's Yes (ITER-076 I-09).
        if approval != nil { parts.bridge.approve(ApprovedAct(action), in: tab) }
        // A form's Send, armed and approved: what the press sends goes (R2-2).
        if checked != nil { await releaseSends() }
        do {
            try await hands.click(x: x, y: y, in: tab)
        } catch is CancellationError {
            // Stopped before the press began: nothing went out.
            record.removeLastStep().map(parts.log)
            takeBackForm(sending)
            throw CancellationError()
        } catch {
            // The press went out, or may have — cut short by Stop included:
            // the postcondition decides (review round 1, P1-1).
        }
        // The press's own check voided it: the page heard none of it.
        if checked != nil, let verdict = ActionScript.pressed(action, on: page),
           try await read(verdict, in: place).flatMap({ try? ActionOutcome.decode($0) })?.outcome == .changed {
            record.markLastStep(.gone).map(parts.log)
            takeBackForm(sending)
            return .changed
        }
        guard action.operation == .type, action.payload != nil else { return sent }
        let typed: TrustedTyping.Typed
        do {
            typed = try await TrustedTyping.type(action, on: page, approval: approval,
                                                 read: { try await self.read($0, in: place) },
                                                 stopping: { self.stopping })
        } catch let error where Self.isLost(error) {
            throw error
        } catch {
            // Stop cut the typing short: whether any of it landed is read by
            // the postcondition.
            typed = .typed(nil)
        }
        // A secret field that took the focus: the page is the user's part.
        if typed == .wall { return answered(.handedOver) }
        return .sent(Postcheck(action: action, page: page, before: nil, moved: nil, expected: nil, tab: tab,
                               typed: typed, approved: approval != nil))
    }

    /// What the look at the act came to: none was needed; it was made and
    /// found nothing new; or the step comes to something else.
    private enum AtTheAct {
        case unchecked, checked
        case stop(Dispatch)
    }

    /// A card field and the control it is for may stand in two documents of
    /// the page, where the hands' own check at the act reads one (Claude
    /// review of I-09, kept 3): on a page with frames, a step that commits is
    /// looked at again, the page and its frames as one, right before it goes
    /// out — after the aim, which may scroll the page. A page with frames is
    /// one whose step's look found them, or whose latest aim did
    /// (`aimSawFrames`): a frame the page brought since the look is read too
    /// (review round 4, decision 12; Claude review c9 of I-09, #16). A card
    /// the checks never saw is the user's part, a Yes given or not — the
    /// page's card evidence read whole, as the policy read it before,
    /// wherever on the page it came (Claude review c8 of I-09, #24); a total
    /// is none (owner decision of 2026-10-19); a target no longer found there
    /// is gone.
    private func checkedAgainAtTheAct(_ action: AgentAction, on page: ObservedPage, approval: ActionScript.Approval?,
                                      in tab: BrowserTab, aimSawFrames: Bool) async throws -> AtTheAct {
        guard ActionScript.commits(action, approval), let target = action.target,
              !page.frames.isEmpty || (page.frameOwners?.count ?? 0) > 0 || aimSawFrames else { return .unchecked }
        guard !page.flags.paymentForm else { return .unchecked }
        guard let now = try await look(tab), now.element(matching: page.identity(of: target)) != nil else {
            return .stop(.finished(.gone))
        }
        return now.flags.paymentForm ? .stop(.finished(.handedOver)) : .checked
    }

    /// What the tab did while the act was readied, read right before its Yes
    /// is armed and it goes out — the look at the act and the aims included
    /// (Claude review c8 of I-09, #14, #25): a dialog that named the user's
    /// part ends the errand there, before anything is sent; one declined
    /// before is no failure of this act. Nil: the act goes out.
    private func readiedToSend(_ tab: BrowserTab) -> Dispatch? {
        noteTabEvents(tab)
        if let dialogNamed { return .named(dialogNamed) }
        declinedThisStep = false
        return nil
    }

    /// Records `action` as sent right before the call that sends it: a Stop
    /// that comes while that call is on its way finds it in the record the
    /// service saves at once (review round 1, P1-1).
    private func recordSending(_ action: AgentAction, _ sending: Sending) {
        log(action, sending.outcome, sending.confidence, sending.began)
        if let form = sending.form { record.form = form }
    }

    /// A form's Send that never went out — Stop before the press, or the
    /// page's answer that nothing happened — leaves its form as it stood.
    private func takeBackForm(_ sending: Sending) {
        if sending.form != nil { record.form = nil }
    }

    /// The page answered an act that went out: nothing happened, as the
    /// record now says.
    private func answered(_ outcome: ErrandRecord.Outcome) -> Dispatch {
        record.markLastStep(outcome).map(parts.log)
        return .answered(outcome)
    }

    /// Sends an act's script, recorded as it goes: its reply, or nil when the
    /// reply was lost or cut short — the page may have acted (a call Stop
    /// interrupted included). A bridge that says nothing went out — Stop
    /// before the call — takes the record back (review of 3.1, round 2).
    private func sendAct(_ script: String, _ action: AgentAction, _ sending: Sending,
                         in tab: BrowserTab) async throws -> String? {
        recordSending(action, sending)
        do {
            return try await parts.bridge.run(script, in: tab)
        } catch is CancellationError {
            record.removeLastStep().map(parts.log)
            takeBackForm(sending)
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// The postcondition of an action that reached the page (§6.5), checked
    /// even after Stop (§7.4): in a task Stop does not cancel, bounded by the
    /// page deadline — and, after Stop, by what is left of Stop's limit: then
    /// the check is cancelled, which ends the call it is in, and nil says it
    /// was not finished. A failed one is a miss, never repeated blindly. A
    /// lost browser is thrown: it ends the errand.
    private func postcondition(_ check: Postcheck) async throws -> Bool? {
        let checking = Task { () -> Result<Bool, any Error> in
            do { return .success(try await self.verify(check)) } catch { return .failure(error) }
        }
        guard let result = await untilStopLimit(checking) else {
            checking.cancel()
            return nil
        }
        switch result {
        case .success(let held): return held
        case .failure(let error) where Self.isLost(error): throw error
        case .failure: return false
        }
    }

    private func verify(_ check: Postcheck) async throws -> Bool {
        answeredOnlyByABox = false
        let action = check.action
        let page = check.page
        let tab = check.tab
        switch action.operation {
        case .open, .back:
            guard let expected = check.expected else { return false }
            return try await settle(tab, leaving: check.before, on: .site(of: expected), honourStop: false)
        case .scroll:
            // The page is read next once it has gone quiet (ITER-076 I-07).
            _ = try await settle(tab, leaving: nil, on: nil, honourStop: false)
            return check.moved == true
        case .click:
            // A click may start a navigation: give it a moment to begin.
            try await Task.sleep(for: .milliseconds(300))
            guard try await settle(tab, leaving: nil, on: nil, honourStop: false), let target = action.target else {
                return false
            }
            let after = try await observe(tab)
            let element = after.element(matching: page.identity(of: target))
            let region = { (observed: ObservedPage) in
                observed.elements.filter { $0.region == target.region }.map(\.fingerprint)
            }
            // A made-up dropdown a click opened lists its options, wherever
            // the page draws them (ITER-076 I-08).
            let listed = target.opens == true && element.map { list in after.elements.contains { $0.listOf == list.index } }
                == true
            // An option of one: the choice it shows now is read back in the
            // page and kept as this errand's, as a native select's is.
            if let list = target.listOf.flatMap({ index in page.elements.first { $0.index == index } }),
               try await holds(AgentAction(operation: .select, target: list, destination: nil, payload: target.name,
                                           isPlannedSearch: false), on: page, in: tab) {
                chosenOptions[page.identity(of: list)] = target.name
            }
            // In a box, what of its own a press changed — a control gone or redrawn — says it landed; controls that
            // only came in beside it are a box's answer, as one over the page is (Codex review 3 of 2026-10-21, P1-2:
            // a Send that opened a second box beside its own was read as landed, and could be sent again).
            let before = region(page), now = region(after)
            let regionChanged = target.region == .dialog ? !Set(before).isSubset(of: Set(now)) : now != before
            let landed = after.liveAddress != page.liveAddress || regionChanged
                || element?.checked != target.checked || element?.text != target.text || listed
            if landed { return true }
            if target.region == .dialog, Set(now) != Set(before) {
                answeredOnlyByABox = true
                return true
            }
            // A box the page brought over itself where none was — "Thanks for submitting the form", the address the
            // same — is its answer to the click, wherever it is drawn; a cookie window is none (2026-10-21, blind b03:
            // DemoQA's thanks box, outside the form's region, was read as nothing, and the send the user said Yes to
            // went on record as failed). A box is the page's answer, not the proof a send landed: one sent with a Yes
            // is still never sent again on this page (Codex review 2 of 2026-10-21, P1-3).
            let cookies = CookieBanner.window(on: after)
            let brought = after.elements.filter { $0.region == .dialog && cookies?.holds($0) != true }
            answeredOnlyByABox = !brought.isEmpty && !page.elements.contains { $0.region == .dialog }
            return answeredOnlyByABox
        case .type, .select:
            // Typed as a person types (ITER-076 I-07): the suggestions the
            // field lists, then, once the page has gone quiet, whether the text
            // is still where it landed (Codex review of I-07, P2-2).
            if action.operation == .type, let typed = check.typed {
                let place = Self.place(of: action, in: tab)
                return try await TrustedTyping.finish(typed, action: action, on: page,
                                                      read: { try await self.read($0, in: place) },
                                                      settle: { _ = try await self.settle(tab, leaving: nil, on: nil,
                                                                                          honourStop: false) })
            }
            // A select may send its form: as after a click, give a navigation
            // a moment to begin, and let it land.
            if action.operation == .select {
                try await Task.sleep(for: .milliseconds(300))
                guard try await settle(tab, leaving: nil, on: nil, honourStop: false) else { return false }
            }
            // Whether the field shows what was written is read in the page:
            // the observer reports no field's value (ITER-076 2.3).
            let held = try await holds(action, on: page, in: tab)
            if action.operation == .type { _ = try await settle(tab, leaving: nil, on: nil, honourStop: false) }
            if held, action.operation == .select, let select = action.target, let option = action.payload {
                chosenOptions[page.identity(of: select)] = option
            }
            return held
        case .wait, .more, .done, .stuck:
            return true
        }
    }

    /// The entry of the tab's own history BACK goes to (ITER-076 I-10; a
    /// reference browser agent's `_back_target`, `page.py` 410-430, MIT): the
    /// newest before the one the tab shows that is a web address the agent
    /// may open, where a document of this tab was loaded from — never an
    /// address a page wrote into its own history (ITER-076 2.2, S1) — that no
    /// form's sending made, and that no Yes led to: going back there may ask
    /// for it again. Nil when there is none — on a first page — or when the
    /// history cannot be read.
    private func backEntry(in tab: BrowserTab) async throws -> BrowserHistory.Entry? {
        guard let history = try await readingAll({ try await parts.bridge.history(of: tab) }) else { return nil }
        return history.entries.prefix(max(0, history.current)).last { entry in
            let address = Self.requested(entry.url)
            return URL(string: entry.url).map(DiaScript.isOpenable) == true && loaded.contains(address)
                && !entry.sentForm && !approvedAddresses.contains(address)
        }
    }

    /// A window the click asked to open — none is opened
    /// (`ChromeBridge.sandbox`) — is opened in the agent's own tab instead
    /// (ITER-076 I-10, critic 19; a reference browser agent's
    /// `follow_popup`, `session.py` 492-505, MIT), as one more act of the
    /// same step, with Stop and the ceilings checked right before it: by the
    /// rules every open keeps, from the page the click was on. An address the
    /// agent never opens is refused, on record. Never for a click that may
    /// send a POST form: an address alone does not ask for what that form
    /// sends. Nil: nothing was opened — no web address, the tab is no longer
    /// on that page, or Stop or a ceiling came first, which the loop ends at
    /// next — and the click is judged as it is.
    private func openWindow(_ address: String, after check: Postcheck) async throws -> Bool? {
        guard (try? checkpoint()) != nil, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        guard DiaScript.isOpenable(url) else {
            refusedThisStep = true
            note(.addressRefused)
            return nil
        }
        guard SafetyGuard.structuralReason(of: check.action, pageURL: nil) != .postForm,
              let script = ActionScript.source(for: AgentAction(operation: .open, target: nil,
                                                                destination: url.absoluteString, payload: nil,
                                                                isPlannedSearch: false), on: check.page) else {
            return nil
        }
        let before = try await marker(check.tab)
        guard (try? checkpoint()) != nil else { return nil }
        navigatesAway(to: url.absoluteString, in: check.tab)
        let reply = try? await parts.bridge.run(script, in: check.tab)
        guard let reply, (try? ActionOutcome.decode(reply))?.outcome == .done else { return nil }
        if check.approved { approvedAddresses.insert(Self.requested(url.absoluteString)) }
        return try await settle(check.tab, leaving: before, on: .site(of: url))
    }

    /// Whether the field `action` wrote to, as `page` showed it, shows the
    /// action's text now; false when that cannot be read.
    private func holds(_ action: AgentAction, on page: ObservedPage, in tab: BrowserTab) async throws -> Bool {
        guard let script = ActionScript.holds(action, on: page),
              let reply = try await read(script, in: Self.place(of: action, in: tab)) else { return false }
        return (try? ActionOutcome.decode(reply))?.outcome == .held
    }

    /// A read of the page (review round 1, P1-2): its answer, or nil when the
    /// page could not give one. A lost browser, and Stop, are thrown: they
    /// end the errand, and no read may hide them.
    private func read(_ script: String, in tab: BrowserTab) async throws -> String? {
        do {
            return try await reading { try await parts.bridge.run(script, in: tab) }
        } catch let error where error is CancellationError || Self.isLost(error) {
            throw error
        } catch {
            return nil
        }
    }

    /// A call that reads the page. One that fails is on record as a miss
    /// here, once, whoever made it (ITER-076 I-06a review, P2-3) — but not
    /// the browser lost, nor a read Stop cut short, before it went out or
    /// after (`.interrupted` once Stop is pressed; round 2): that is Stop.
    /// The failure goes on to the caller as it came, so what each caller
    /// does after Stop — a sent action still checked — is unchanged.
    private func reading<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch {
            let cutByStop = error is CancellationError || (stopping && error as? BrowserBridgeError == .interrupted)
            if !cutByStop, !Self.isLost(error) { note(.pageMiss(.read)) }
            throw error
        }
    }

    /// A look that may fail as a read does: nil for a page that did not
    /// answer, or whose report is not one.
    private func look(_ tab: BrowserTab) async throws -> ObservedPage? {
        do {
            return try await observe(tab)
        } catch let error where error is CancellationError || Self.isLost(error) {
            throw error
        } catch {
            return nil
        }
    }

    /// A look a model is shown — what a sub-goal left, the page the verifier
    /// judges — taken once the page's loader went (`loaded`), as the step's
    /// own look and every read are. A check of the agent's own — whether an
    /// act took, a page before the act — looks at once.
    private func shown(_ tab: BrowserTab) async throws -> ObservedPage? {
        await loaded(tab)
        return try await look(tab)
    }

    /// The options this errand chose that their selects still show on
    /// `page`, by fingerprint, each read again in the page. A choice the page
    /// no longer shows — set back, reloaded, or a select that is gone — is
    /// forgotten, and its option is offered again.
    private func optionsStillChosen(on page: ObservedPage, in tab: BrowserTab) async throws -> [String: String] {
        var still: [String: String] = [:]
        for (identity, option) in chosenOptions where !stopping {
            let check = page.element(matching: identity).map {
                AgentAction(operation: .select, target: $0, destination: nil, payload: option, isPlannedSearch: false)
            }
            guard let check, let select = check.target, try await holds(check, on: page, in: tab) else {
                chosenOptions[identity] = nil
                continue
            }
            still[select.fingerprint] = option
        }
        return still
    }

    /// Where a navigation must end for the page to have settled.
    private enum Landing {
        /// On the same site as this address, redirects allowed (§6.5).
        case site(of: URL)
        /// On any web page: where a start address took the tab (ITER-076 I-05).
        case anyWebPage
    }

    /// Waits for the page (§11). With `previous` — a marker taken before a
    /// navigation — the page must first be another one; with `landing`, it
    /// must end there. False when that does not happen in time: a miss, on
    /// record here for every caller (ITER-076 I-06a review, P2-3) — but not
    /// at Stop. A postcondition checked after Stop passes `honourStop: false`.
    ///
    /// Once it is ready — `interactive` or `complete` — and has landed, the
    /// page is read only when it has gone quiet (ITER-076 I-07, `quiet`).
    /// One settle owns every limit (Codex review of I-07): the page's deadline
    /// for all of it, the quiet budget from the first ready look, the loading
    /// indicator's budget from the first wait, and every call it awaits ends
    /// by them (P2-4, P2-5). Where the page is after the wait is what the
    /// landing is judged on: a page that moved on meanwhile is looked at
    /// again from its readiness, and one that ended elsewhere is a miss (P2-6).
    /// A landing that must hold is never taken on trust: where the page was
    /// last read must be there, and a page whose last read failed is a miss
    /// (round 3, P2-1). Once waited on, every look reads where the page is,
    /// whatever its loading says, so that reading is never an old one; and
    /// the read after the wait has a short time of its own, so a wait that
    /// used its whole budget still gets it made — a read never made is no
    /// failed read (review of round 3).
    private func settle(_ tab: BrowserTab, leaving previous: String?, on landing: Landing?,
                        honourStop: Bool = true) async throws -> Bool {
        let deadline = ContinuousClock.now + Self.pageDeadline
        var budgets: (quiet: ContinuousClock.Instant, loading: ContinuousClock.Instant)?
        // Where the page was last read to be, once it was first waited on; nil
        // when that read came back with nothing in time.
        var seen: String?
        while ContinuousClock.now < deadline {
            if honourStop, stopping { return false }
            // A navigation waited for that the tab refused — a download, an
            // address the agent never opens — never comes (ITER-076 I-09).
            noteTabEvents(tab)
            if previous != nil, refusedThisStep { return false }
            // Once the page was first ready, every call of this settle ends by
            // the quiet budget, not the page's deadline (Codex review of I-07,
            // round 2, P2-4): spent, the page is read as it is, where it was
            // last read to be. A landing it must make is made only there.
            let callsEnd = budgets.map { min(deadline, $0.quiet + Self.quietReplyGrace) } ?? deadline
            if budgets != nil, ContinuousClock.now >= callsEnd {
                guard let landing else { return true }
                if let seen, Self.lands(seen, on: landing) { return true }
                note(.pageMiss(.settle))
                return false
            }
            let loading = try await bounded(until: callsEnd, { try await self.reading {
                try await self.parts.bridge.isLoading(tab) } })
            var current: String?
            if loading == false || budgets != nil {
                current = try await bounded(until: callsEnd, { try await self.marker(tab) })
            }
            // After the first wait, where the page was last read to be — or
            // nothing, when that read failed.
            if budgets != nil { seen = current }
            if loading == false, let current,
               let ready = try await bounded(until: callsEnd, { try await self.reading {
                   try await self.parts.bridge.run("document.readyState", in: tab) } }),
               ready == "interactive" || ready == "complete", current != previous {
                if let landing, !Self.lands(current, on: landing) {
                    note(.pageMiss(.settle))
                    return false
                }
                let now = ContinuousClock.now
                // The quiet budget ends early enough for its last reply and the
                // read after it, each with its own short time, within the deadline.
                let limits = budgets ?? (quiet: min(now + ObserverScript.settleLimit, deadline - Self.quietReplyGrace * 2),
                                         loading: now + ObserverScript.settleLoading)
                budgets = limits
                guard try await quiet(tab, until: limits.quiet, loadingUntil: limits.loading, honourStop: honourStop) else {
                    return false
                }
                // Where the page is now: it may have moved while it was waited on.
                // The read has its own short time, from the wait's end.
                let final = try await bounded(until: min(deadline, ContinuousClock.now + Self.quietReplyGrace), {
                    try await self.marker(tab)
                })
                if final == current { return true }
                seen = final
                if ContinuousClock.now >= limits.quiet, let final {
                    // No time left to wait on the new page: read as it is, where it is.
                    guard let landing, !Self.lands(final, on: landing) else { return true }
                    note(.pageMiss(.settle))
                    return false
                }
                continue
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        note(.pageMiss(.settle))
        return false
    }

    /// Whether the page a marker names is where `landing` says it must end:
    /// a site's own host below it included — google.com's consent page,
    /// `consent.google.com` (ITER-076 stage 3, № 121).
    private static func lands(_ marker: String, on landing: Landing) -> Bool {
        let address = marker.components(separatedBy: "\n").first ?? ""
        let site = URL(string: address).flatMap(Scratchpad.site(of:))
        return switch landing {
        case .site(let target):
            site == Scratchpad.site(of: target)
                || Scratchpad.site(of: target).map { wanted in site?.hasSuffix("." + wanted) == true } == true
        case .anyWebPage: site != nil
        }
    }

    /// `call`'s answer, or nil once `deadline` has passed first (Codex review
    /// of I-07, P2-4): a call that stalls is left, and cancelled; what it
    /// throws comes through.
    private func bounded<T: Sendable>(until deadline: ContinuousClock.Instant,
                                      _ call: @escaping @MainActor () async throws -> T) async throws -> T? {
        let left = deadline - ContinuousClock.now
        guard left > .zero else { return nil }
        let task = Task { @MainActor () -> Result<T, any Error> in
            do { return .success(try await call()) } catch { return .failure(error) }
        }
        guard let result = await Deadline.run(within: left, { await task.value }) else {
            task.cancel()
            if Task.isCancelled { throw CancellationError() }
            return nil
        }
        return try result.get()
    }

    /// A look a model is shown, and a read, wait first while a loading
    /// indicator is on screen (2026-10-08), up to `ObserverScript.captureLoading` — a reference
    /// browser agent's capture wait (`page.py` 231-233, 447-476, MIT): an
    /// act's settle gives up on a loader after `settleLoading`, and a page's
    /// own loading — a timer, a slow fetch — may take longer; a look at
    /// "Loading..." would show Jev and the reader a page not there yet. The
    /// page waits in itself (`ObserverScript.loadedSource`); a hidden page
    /// gives one sample a call and is asked again every `settlePoll`. A wait
    /// that fails, or Stop, reads the page as it is.
    /// True when a loading indicator was still on screen as the wait ran out (2026-10-16).
    /// No wait runs past the errand's time: its work time and its expiry, whichever ends first (Codex review of
    /// 2026-10-18, P1-3), as a paid call's deadline does not (`paid`).
    @discardableResult
    private func loaded(_ tab: BrowserTab, upTo wait: Duration = ObserverScript.captureLoading) async -> Bool {
        let deadline = ContinuousClock.now + min(wait, timeLeftNow)
        // One sample first, briefly: a page with no loader on screen — or one
        // that does not answer at once — is read as it is, with no wait.
        let sample = try? await bounded(until: ContinuousClock.now + Self.quietReplyGrace, {
            try await self.parts.bridge.run(ObserverScript.loadingSample, in: tab)
        })
        guard let text = sample ?? nil,
              (try? JSONDecoder().decode(Loaded.self, from: Data(text.utf8)))?.loading == true else { return false }
        while !stopping, !Task.isCancelled {
            let left = deadline - ContinuousClock.now
            guard left > .zero else { return true }
            guard let answer = try? await bounded(until: deadline + Self.quietReplyGrace, {
                try await self.parts.bridge.runAwaiting(ObserverScript.loadedSource(within: left), in: tab)
            }), let state = try? JSONDecoder().decode(Loaded.self, from: Data(answer.utf8)) else {
                return false
            }
            guard state.loading else { return false }
            try? await Task.sleep(for: min(ObserverScript.settlePoll, max(.zero, deadline - ContinuousClock.now)))
        }
        return false
    }

    /// What is left of the errand's time this moment: its work time — counted to the last checkpoint, less what
    /// has been worked since — and its expiry, whichever ends first.
    private var timeLeftNow: Duration {
        let worked = workClock.now - lastCheckpoint - waitedSinceCheckpoint
        return min(budget.timeLeft(now: .now), max(.zero, budget.activeTimeLeft - worked))
    }

    /// What the page answers when asked whether a loading indicator is on
    /// screen.
    private struct Loaded: Decodable {
        let loading: Bool
    }

    /// The page read once it has gone quiet (ITER-076 I-07), ported from a
    /// reference browser agent's `_changed_since` (`page.py` 1393-1430, MIT):
    /// ready, no mutation or input event for `settleQuiet`, and no loading
    /// indicator on screen — waited on until `loadingUntil` — all by `until`,
    /// past which the page is read as it is. The page waits in itself
    /// (`ObserverScript.settledSource`), told what is left of each budget; a
    /// hidden page gives one sample a call and is asked again every
    /// `settlePoll`. Each call ends by `until` (Codex review of I-07, P2-4,
    /// P2-5). A navigation that destroys the read retries only the read, never
    /// the action. True but at Stop, when Stop is honoured; Stop cutting the
    /// read short ends the wait, and a lost browser is thrown.
    private func quiet(_ tab: BrowserTab, until deadline: ContinuousClock.Instant,
                       loadingUntil loading: ContinuousClock.Instant, honourStop: Bool) async throws -> Bool {
        while true {
            if honourStop, stopping { return false }
            let now = ContinuousClock.now
            let remaining = deadline - now
            guard remaining > .zero else { return true }
            let script = ObserverScript.settledSource(within: remaining, loadingFor: max(.zero, loading - now))
            do {
                guard let answer = try await bounded(until: deadline + Self.quietReplyGrace, {
                    try await self.parts.bridge.runAwaiting(script, in: tab)
                }) else { return true }
                if (try? JSONDecoder().decode(Quiet.self, from: Data(answer.utf8)))?.stable == true { return true }
            } catch let error where error is CancellationError || Self.isLost(error) {
                throw error
            } catch {
                // Cut short by Stop: the wait ends. Any other failure — a
                // navigation destroyed the read — reads again.
                if Task.isCancelled { throw CancellationError() }
                if honourStop, stopping { return false }
            }
            try await Task.sleep(for: min(ObserverScript.settlePoll, max(.zero, deadline - ContinuousClock.now)))
        }
    }

    /// How long past the quiet wait's end its last answer may take to come
    /// back: the page answers at the end itself.
    private static let quietReplyGrace: Duration = .milliseconds(250)

    /// What the page answers when asked whether it has gone quiet.
    private struct Quiet: Decodable {
        let stable: Bool
    }

    /// The page's address and the moment its document began. One of them
    /// changes whenever a navigation lands — a reload, or a load of the same
    /// address, included — so a finished navigation is never judged by the
    /// address alone.
    private func marker(_ tab: BrowserTab) async throws -> String {
        try await reading { try await parts.bridge.run("location.href + '\\n' + performance.timeOrigin", in: tab) }
    }

    /// A look at the page. A report that is not one is on record as a miss
    /// here, for every caller (ITER-076 I-06a review, P2-3).
    private func observe(_ tab: BrowserTab) async throws -> ObservedPage {
        defer { noteTabEvents(tab) }
        let report = try await reading { try await parts.bridge.run(ObserverScript.source, in: tab) }
        let page: ObservedPage
        do {
            page = try ObservedPage.decode(report)
        } catch {
            note(.pageMiss(.report))
            throw error
        }
        let (frames, listing, framesUnread) = try await framesRead(in: tab)
        let documents = [page] + frames.map(\.page)
        let owners = documents.reduce(0) { $0 + ($1.frameOwners?.count ?? 0) }
        // A frame a document read holds that was never listed — not running
        // yet, or its setup failed — is unread too, and who it is unknown: it
        // may show a total, or hold a twin (Claude review c8 of I-09, #19,
        // #21).
        var unread = framesUnread
        if owners > listing.frames.count { unread.unknown = true }
        if !pagesSeen.contains(page.url) { pagesSeen.append(page.url) }
        return page.merging(frames, unread: unread)
    }

    /// Each frame of the page read as the page is, in its own document
    /// (ITER-076 I-09). A frame that cannot be read — its script failed, its
    /// report is not one, or the bridge could not list it (Codex review 1 of
    /// I-09, P2-2) — is no part of the look, and is on record as a miss:
    /// counted, never dropped silently. A look reads at most
    /// `maxFramesRead` frames, and begins none once `framesReadLimit` is
    /// spent: the frames it leaves are one miss (Claude review c7 of I-09,
    /// #7). Beside them, the listing, and which were not read —
    /// who each listed one is, and whether any could not even be listed
    /// (Codex review 1 of I-09, P1-1; Claude review c8, #19, #21): what an
    /// unread one shows may name what stands around it, show a total, or
    /// hold a twin.
    private func framesRead(in tab: BrowserTab) async throws
        -> (frames: [(id: String, identity: String, page: ObservedPage)], listing: FrameListing,
            unread: ObservedPage.Unread) {
        guard let listing = try await readingAll({ try await parts.bridge.frames(of: tab) }) else {
            return ([], FrameListing(), ObservedPage.Unread(unknown: true))
        }
        // A miss for each frame left out, and one more for what each that
        // never said what it holds may hold — not known, so a miss of its own
        // (Codex review 2 of I-09, P2-5). Who a frame left out is, is not
        // known either (`listing.unknown` counts among `listing.unread`).
        for _ in 0..<(listing.unread + listing.unknown) { note(.pageMiss(.read)) }
        var unread = ObservedPage.Unread(unknown: listing.unread > 0)
        let deadline = ContinuousClock.now + Self.framesReadLimit
        var read: [(id: String, identity: String, page: ObservedPage)] = []
        for (place, frame) in listing.frames.enumerated() {
            guard place < Self.maxFramesRead, ContinuousClock.now < deadline else {
                note(.pageMiss(.read))
                unread.identities.formUnion(listing.frames[place...].map(\.identity))
                break
            }
            guard let id = frame.tab.frame,
                  let report = try await self.read(ObserverScript.source, in: frame.tab) else {
                unread.identities.insert(frame.identity)
                continue
            }
            guard let page = try? ObservedPage.decode(report) else {
                note(.pageMiss(.report))
                unread.identities.insert(frame.identity)
                continue
            }
            read.append((id: id, identity: frame.identity, page: page))
        }
        return (read, listing, unread)
    }

    /// The most frames one look reads: as many as the page's own census
    /// reads (`ObserverScript`'s `MAX_FRAMES`). A page of hundreds of frames
    /// never makes a look of hundreds of reads (Claude review c7 of I-09, #7).
    static let maxFramesRead = 50
    /// How long one look may spend reading its frames: none is begun after.
    static let framesReadLimit: Duration = .seconds(10)

    /// `call`'s answer, or nil when it failed, as a read that fails is: on
    /// record as a miss. A lost browser, and Stop, are thrown.
    private func readingAll<T>(_ call: () async throws -> T) async throws -> T? {
        do {
            return try await reading(call)
        } catch let error where error is CancellationError || Self.isLost(error) {
            throw error
        } catch {
            return nil
        }
    }

    /// Where an action's scripts run: the document of its control — the
    /// page's, or its frame's — but for an open, which leaves the page from
    /// the page itself (ITER-076 I-09).
    private static func place(of action: AgentAction, in tab: BrowserTab) -> BrowserTab {
        action.operation == .open ? tab : tab.inFrame(action.target?.frame)
    }

    /// What one measure of a trusted input's target came to: the point in
    /// the tab's viewport a press goes to, and how many frames the aim's own
    /// look found in its document (review round 4, decision 12); or what the
    /// step comes to instead.
    private enum Aimed {
        case at((x: Double, y: Double), frames: Int)
        case missed(Dispatch)
    }

    /// The aim, in `place`, and where its point lies in the tab's viewport
    /// once every document on the way has drawn: a control in a frame is
    /// pressed where the frame is drawn in the tab, and only where nothing of
    /// the page is laid over the frame (ITER-076 I-09).
    private func aimed(_ aim: String, in place: BrowserTab, hands: any TrustedInputBridge) async throws -> Aimed {
        let reply = try await read(aim, in: place).flatMap { try? ActionOutcome.decode($0) }
        guard let reply, reply.outcome == .aim, let x = reply.x, let y = reply.y, let frames = reply.frames else {
            parts.log("\(ErrandRecord.logPrefix(record.errandID)) the aim missed: \(reply?.outcome.rawValue ?? "no reply")"
                      + (reply?.why.map { " (\($0))" } ?? ""))
            return .missed(Self.missed(reply?.outcome))
        }
        guard let reached = try await readingAll({ try await hands.point(x: x, y: y, in: place) }),
              let point = reached else {
            parts.log("\(ErrandRecord.logPrefix(record.errandID)) the aim's point is not in the tab's viewport")
            return .missed(.finished(.gone))
        }
        return .at(point, frames: frames)
    }

    /// What the lookup of an act sent by script, made alone, came to: how
    /// many frames its control's document holds; or what the step comes to
    /// instead (ITER-076 I-09, round 5; Claude review c10, #14).
    private enum Probed {
        case found(frames: Int)
        case missed(Dispatch)
    }

    /// The lookup `found`, in `place`: nothing is done there.
    private func probed(_ found: String, in place: BrowserTab) async throws -> Probed {
        let reply = try await read(found, in: place).flatMap { try? ActionOutcome.decode($0) }
        guard let reply, reply.outcome == .found, let frames = reply.frames else {
            if reply?.outcome == .wall { noteWall(reply?.why) }
            return .missed(Self.missed(reply?.outcome))
        }
        return .found(frames: frames)
    }

    /// A lookup that did not find its control as its act needs it: what
    /// the step comes to — nothing was sent.
    private static func missed(_ outcome: ActionOutcome.Kind?) -> Dispatch {
        switch outcome {
        case .changed: return .changed
        case .wall: return .finished(.handedOver)
        case .file: return .fileNeeded(recorded: false)
        case .ambiguous: return .finished(.ambiguous)
        case .unsupported: return .finished(.unsupported)
        default: return .finished(.gone)
        }
    }

    /// An address as a server sees it: no fragment, the scheme and host in
    /// lower case. Two addresses that differ only in these are one request.
    private static func requested(_ address: String) -> String {
        guard var parts = URLComponents(string: address) else { return address }
        parts.fragment = nil
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        return parts.string ?? address
    }

    private func log(_ action: AgentAction?, _ outcome: ErrandRecord.Outcome, _ confidence: Double?,
                     _ began: ContinuousClock.Instant) {
        parts.log(record.append(action, outcome: outcome, confidence: confidence, engine: parts.engine.name,
                                milliseconds: Self.milliseconds(since: began), costUSD: stepCost,
                                operationConfidence: engineAnswer?.operationConfidence,
                                targetConfidence: engineAnswer?.targetConfidence, targets: engineAnswer?.targets))
    }

    private static func milliseconds(since began: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - began) / .milliseconds(1))
    }

    // MARK: - The Sheet

    /// `rows` go into a new Sheet named `title` and are read back (§6.6):
    /// every cell must show its canonical value and none may hold a formula.
    /// Stop is checked right before the Sheet is made and right before the
    /// paste, and ends the read-back's wait; no ceiling stops it — at one,
    /// what was collected is written (owner default 6.1). The Sheet's tab is
    /// closed however it went, after Stop too, within what is left of Stop's
    /// limit (ITER-076 stage 6). Nil: written and read back as pasted, or
    /// stopped; otherwise how the Sheet failed.
    private func writeSheet(_ rows: [[String]], title: String, empty: String) async -> ErrandOutcome.SheetFailure? {
        guard let sheet = parts.sheet else { return .notMade }
        let failure: ErrandOutcome.SheetFailure?
        do {
            let address = try await made(sheet, title: title)
            if stopping { throw CancellationError() }
            try await sheet.paste(SheetCells.pasteText(rows: rows, empty: empty), into: address)
            record.sheetWrite = .pasted
            if try await readsAsPasted(sheet, address, rows, empty: empty) {
                record.sheetWrite = .verified
                failure = nil
            } else {
                failure = .mismatch
            }
        } catch let wall as SheetWall {
            failure = wall.handover.kind == .signIn ? .signIn : .notMade
        } catch {
            failure = record.sheet == nil ? .notMade : .mismatch
        }
        _ = await untilStopLimit(Task { await sheet.close() })
        return stopping ? nil : failure
    }

    /// A new Sheet, its address kept the moment it exists, whatever follows —
    /// a Stop before `create` returns, a paste that fails (review rounds 1 and
    /// 2 of I-05, P2-1). Google's sign-in or consent page on the way is the
    /// user's part, waited for in the Sheet's own tab; once they said
    /// Continue, the Sheet is asked for again (ITER-076 stage 6, № 175). A
    /// wait that ended without Continue throws the page that stood there.
    private func made(_ sheet: any SheetDestination, title: String) async throws -> URL {
        while true {
            if stopping { throw CancellationError() }
            do {
                let address = try await sheet.create(title: title, made: { [weak self] made in self?.sheetExists(made) })
                sheetExists(address)
                return address
            } catch let wall as SheetWall {
                guard try await waited(for: wall.handover, in: wall.tab) else { throw wall }
                note(.continued)
            }
        }
    }

    /// Whether the Sheet shows `rows` as pasted: read at the times
    /// `sheetReads` says until it holds as many rows — a Sheet still saving
    /// shows fewer — Stop ending the wait; then every cell must show its
    /// canonical value and none may hold a formula. A read that fails is a
    /// read missed; none that held them all is no.
    private func readsAsPasted(_ sheet: any SheetDestination, _ address: URL, _ rows: [[String]],
                               empty: String) async throws -> Bool {
        for wait in Self.sheetReads {
            try await Task.sleep(for: wait)
            if stopping { throw CancellationError() }
            guard let shown = try? await sheet.readBack(address), shown.cells.count >= rows.count else { continue }
            return !shown.holdsFormula && SheetCells.readBackMatches(expected: rows, displayed: shown.cells,
                                                                    empty: empty)
        }
        return false
    }

    /// The Sheet exists: kept in the record at once, and told to the service
    /// — once, whenever it comes, after Stop too (review round 2, P2-1).
    private func sheetExists(_ address: URL) {
        guard record.sheet == nil else { return }
        record.sheet = address
        record.sheetWrite = .created
        parts.sheetMade(address)
    }

    /// What a look saw, to tell whether the last action changed the page —
    /// what jev-ultrafast's key holds (`agent.py` 143-147): the address, the
    /// text, the actions as they stand and the scroll position — the title
    /// and each select's options too, which an answer from the server can
    /// change and nothing else (review of A3, round 1).
    nonisolated static func pageKey(of page: ObservedPage) -> String {
        let actions = page.elements.map { element in
            [element.fingerprint, element.checked.map { String($0) } ?? "", element.inViewport ? "1" : "0",
             element.value ?? "", (element.options ?? []).joined(separator: "\u{1D}")].joined(separator: "\u{1E}")
        }
        return ([page.url, page.title, page.text, String(page.scrollY)] + actions).joined(separator: "\u{1F}")
    }

    /// A page state as the no-progress count tells one from another (a reference browser agent's `state_key`,
    /// `effects.py` 94-100, MIT): the address and what can be done on the page — each control's role, name,
    /// context, value and tick, in any order — not its words, which a clock or an ad rewrites, nor the scroll.
    nonisolated static func stateKey(of page: ObservedPage) -> String {
        let controls = page.elements.map { element in
            [element.role, element.name, element.context ?? "", element.value ?? "",
             element.checked.map { String($0) } ?? ""].joined(separator: "\u{1E}")
        }
        return ([page.url] + controls.sorted()).joined(separator: "\u{1F}")
    }

    /// A search the code built (D4): opened by its address, on no control.
    private static func search(_ address: URL) -> AgentAction {
        AgentAction(operation: .open, target: nil, destination: address.absoluteString, payload: nil, isPlannedSearch: true)
    }

    /// An action as a sub-goal's result lists it (ITER-076 brain): a click
    /// and a typing as the approval page shows them — "click Search", "type
    /// into Search" — and any other by the label Jev reads it by: a select's
    /// "Name → Option", a page control's own label. No other words.
    private static func listed(_ action: RecentAction) -> String {
        switch action.kind {
        case "click": "click " + action.label
        case "fill": "type into " + action.label
        default: action.label
        }
    }

    /// An action as jev-ultrafast's `recent_actions` names it: the control's
    /// label — a select's with its option, a page control's own label — and
    /// its kind. A link is clicked, as there.
    private static func recentAction(_ action: AgentAction) -> RecentAction {
        let control: String? = switch action.operation {
        case .scroll: "SCROLL_DOWN"
        case .wait: "WAIT"
        case .back: "BACK"
        default: nil
        }
        let label = control.flatMap { name in JevQuestions.controlLabels.first { $0.name == name }?.label }
            ?? (action.operation == .select
                ? "\(action.target?.name ?? "") → \(action.payload ?? "")"
                : action.target?.name ?? URL(string: action.destination ?? "")?.host ?? "")
        let kind = switch action.operation {
        case .type: "fill"
        case .select: "select"
        case .scroll: "scroll"
        case .wait: "wait"
        case .back: "back"
        default: "click"
        }
        // What was typed, as jev-ultrafast keeps it: the questions read it, the
        // record never does (ITER-076 brain).
        return RecentAction(label: label, kind: kind, typed: action.operation == .type ? action.payload : nil,
                            pageChanged: nil)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// A continuation resumed once, by whichever comes first; on the main actor.
@MainActor
private final class ResumeOnce<T> {
    var continuation: CheckedContinuation<T, Never>?

    func resume(_ value: T) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

// MARK: - The brain (owner decision of 2026-10-19)

/// The errand's end, met inside a model call the brain made: no Pro, the day's limit, a service down, the owner's
/// switch.
private struct BrainEnded: Error {}

extension AgentRun {
    /// The errand decided step by step by one model (`BrainLoop`): no plan, no sub-goals, no step of Jev's. It
    /// opens where the goal names a site, or the start page, and works in that one tab; every action the brain asks
    /// for passes this run's own walls, risk check — Jev as the second lock — and the user's Yes, and goes through
    /// its own hands; Stop and the ceilings are this run's.
    fileprivate func brainErrand(_ brain: any Brain) async -> ErrandRecord.Ending {
        tell(.working(title: goal, done: 0, wanted: nil))
        let tab: BrowserTab
        do {
            try checkpoint()
            tab = try await parts.bridge.openTab(Self.firstAddress(in: goal) ?? startPage)
            openTab = tab
        } catch is CeilingReached {
            return .ceiling
        } catch {
            return stopping ? .stopped : fail(.openFailed)
        }
        var ending: ErrandRecord.Ending
        let side = BrainSide(run: self, tab: tab, brain: brain)
        do {
            // A start page that never settles is the brain's first page all the same: it reads what loaded, and
            // can go elsewhere (2026-10-19: two blind errands ended before their first step).
            _ = try await settle(tab, leaving: nil, on: .anyWebPage)
            ending = try await think(with: side)
            if ending == .done || ending == .notFinished { try checkpoint() }
        } catch is BrainEnded {
            ending = side.ended ?? .stopped
        } catch is CeilingReached {
            ending = .ceiling
        } catch {
            ending = stopping ? .stopped : Self.isLost(error) ? lost(error) : fail(.neverSettled)
        }
        record.seen = pagesSeen
        await releaseSends()
        let bridge = parts.bridge
        _ = await untilStopLimit(Task { try? await bridge.closeTab(tab) })
        // The Sheet the user asked for (ITER-076 stage 6): the brain's table, its columns then its rows, written
        // when the errand ended by itself with rows to write, as the step pipeline writes its own: done, not
        // finished, stuck, or at a ceiling; never after Stop. However the Sheet goes, the errand keeps its ending
        // and its answer; a failure of the Sheet is named beside.
        if parts.output == .sheet, [.done, .notFinished, .stuck, .ceiling].contains(ending), let table = brainTable {
            sheetFailure = await writeSheet((table.columns.isEmpty ? [] : [table.columns]) + table.rows, title: goal,
                                            empty: "")
        }
        return ending
    }

    /// The brain's loop, its answer kept as the errand's — with the pages it names that the errand saw as its
    /// sources — and its end as the errand's.
    private func think(with side: BrainSide) async throws -> ErrandRecord.Ending {
        let facts = parts.facts
        let loop = BrainLoop(goal: goal, brain: side, hands: side, recall: { _ in facts().details.map(\.text) },
                             settings: BrainLoop.Settings(maxSteps: limits.steps, table: parts.output == .sheet),
                             log: { [parts] in parts.log($0) },
                             kept: { [weak self] memory in self?.record.told = memory })
        let outcome = try await loop.run()
        brainTable = outcome.table
        record.told = outcome.answer
        record.toldSources = Self.cited(in: outcome.answer, seen: pagesSeen)
        if let ended = side.ended { return ended }
        switch outcome.ending {
        case .done: return .done
        case .notDone: return .notFinished
        case .handedOver: return .needsUser
        case .error: return .stuck
        }
    }

    /// The web addresses `answer` names that the errand saw — the page itself, its fragment and a closing slash
    /// aside — in its order, each once (Codex review of 2026-10-19, P1-5: a site's other pages are not sources).
    static func cited(in answer: String, seen: [String]) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let pages = Set(seen.compactMap(Self.page(of:)))
        var cited: [String] = []
        for match in detector.matches(in: answer, range: NSRange(answer.startIndex..., in: answer)) {
            guard let url = match.url, let page = Self.page(of: url.absoluteString), pages.contains(page),
                  !cited.contains(url.absoluteString) else { continue }
            cited.append(url.absoluteString)
        }
        return cited
    }

    /// A web page's address as a source is compared: scheme and host in lower case, no fragment, no closing slash
    /// on its path — its query as it is.
    private static func page(of address: String) -> String? {
        guard var parts = URLComponents(string: address), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        parts.scheme = scheme
        parts.host = parts.host?.lowercased()
        parts.fragment = nil
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        parts.percentEncodedPath = path
        return parts.string
    }

    /// The question a Yes is asked by, as the bench and the record read it: what is done, on which site.
    private static func question(_ action: AgentAction, on page: ObservedPage) -> String {
        let what = action.target.map { $0.name.isEmpty ? $0.text : $0.name } ?? action.destination ?? ""
        return "\(action.operation.rawValue) \"\(what.prefix(60))\" on \(URL(string: page.url)?.host ?? "")?"
    }

    /// What the brain hears of a control of a cookie window that is not free there: what is (owner default 3.1;
    /// 2026-10-21).
    private static func cookieNote(_ least: ObservedElement, _ way: CookieBanner.Window.Way) -> String {
        let control = "[\(least.index)] \(least.name)"
        switch way {
        case .consent: return "in a cookie window only the least consent may be chosen: \(control)."
        case .turnOff: return "in a cookie window only the least consent may be chosen: first turn off \(control)."
        case .settings:
            return "in a cookie window only the least consent may be chosen; it is in the window's settings: \(control)."
        }
    }

    /// The user's part met at an action: waited for while they do it — then the brain looks again — or the
    /// errand's end.
    private func brainPart(_ kind: ErrandHandover.Kind, on page: ObservedPage, in tab: BrowserTab,
                           _ side: BrainSide) async throws -> BrainActed {
        switch try await userPart(kind, on: page, in: tab) {
        case nil:
            return BrainActed(kind: .notDone, note: "the user did their part (\(kind.rawValue)); look at the page again.")
        case .errand(let ending)?:
            side.ended = ending
            return BrainActed(kind: .ended, note: "This is the user's part (\(kind.rawValue)); the errand ends here.")
        case .subgoal?:
            return BrainActed(kind: .notDone, note: "the user's part was not done.")
        }
    }

    /// One action the brain asked for, as a step of Jev's is taken once chosen (`step`): the walls, the risk — the
    /// page's structure and the lexicon, then Jev for what is not always reversible — the user's Yes for what is
    /// irreversible, bound to what they saw, then the hands, the postcondition and the record. `asSend`: a choice
    /// whose change the page sends, put back (`heldBackChoice`) — irreversible, asked about as a press of no form is.
    fileprivate func brainAct(_ action: AgentAction, on page: ObservedPage, in tab: BrowserTab,
                              _ side: BrainSide, asSend: Bool = false) async throws -> BrainActed {
        var action = action
        stepCost = 0
        engineAnswer = nil
        dialogsThisStep = 0
        refusedThisStep = false
        parts.bridge.approve(nil, in: tab)
        defer { parts.bridge.approve(nil, in: tab) }
        let began = ContinuousClock.now
        let pageAddress = AgentAction.effectAddress(page.liveAddress)
        // A No is final for this action on this page (ITER-076 I-05).
        if refused[pageAddress]?.contains(action.effect) == true {
            return BrainActed(kind: .notDone, note: "the user already said no to this here; do something else.")
        }
        if page.inCaptchaWidget(action.target) {
            if try await outwaited(page, in: tab) {
                return BrainActed(kind: .notDone, note: "the page's check cleared by itself; look again.")
            }
            log(action, .handedOver, 1, began)
            return try await brainPart(.captcha, on: page, in: tab, side)
        }
        // A consent page — its address, or a frame's, carries an OAuth request — is the user's part (ITER-076 2.1):
        // any act on a control of it is handed to them, and so is an address of its own site the brain opens — its
        // approval, read off the page (Codex review of 2026-10-21, P1-4). Leaving it — another site, Back — is not
        // (2026-10-21, blind b16: a site's timeline sent the browser on to its single sign-on, and the errand ended
        // there, handed to the user before the brain had seen the page).
        if page.asksForGrant, action.target != nil || action.operation == .open && page.isOfTheConsent(action.destination) {
            log(action, .handedOver, 1, began)
            return try await brainPart(.grant, on: page, in: tab, side)
        }
        // A control of the page's cookie window is the window's before any wall reads its words (owner default 3.1;
        // 2026-10-21: a consent platform's "Allow All", no cookie word in it, read as a grant would end the errand):
        // only what the window offers free is pressed, below, through the walls; anything else of it is never pressed
        // and the brain hears what is free — the accept is never the agent's to give; a window that blocks the page
        // and offers nothing free is the user's part. A bar that blocks nothing and offers nothing free is read past:
        // its accept is decided as any control (2026-10-19).
        let cookies = action.target.flatMap { target in
            CookieBanner.window(on: page).flatMap { $0.holds(target) && ($0.blocksPage || $0.least != nil) ? $0 : nil }
        }
        if let cookies, let target = action.target {
            guard let least = cookies.least else { return try await brainPart(.cookies, on: page, in: tab, side) }
            guard cookies.frees(target) else { return BrainActed(kind: .notDone, note: Self.cookieNote(least, cookies.way)) }
        }
        if SafetyGuard.isGrant(action) {
            log(action, .handedOver, 1, began)
            return try await brainPart(.grant, on: page, in: tab, side)
        }
        if action.target?.needsFile == true {
            log(action, .handedOver, 1, began)
            return try await brainPart(.file, on: page, in: tab, side)
        }
        if action.target?.touchesSecret == true {
            log(action, .handedOver, 1, began)
            return try await brainPart(page.flags(of: action.target).paymentForm ? .payment : .signIn, on: page, in: tab, side)
        }
        // A press that would send a form short of a secret field it needs is the user's sign-in, before any Yes: the
        // question would only send what the site turns away (2026-10-21). Typing in the form stays the brain's.
        if SafetyGuard.needsTheUsersSecret(action) {
            log(action, .handedOver, 1, began)
            return try await brainPart(page.flags(of: action.target).paymentForm ? .payment : .signIn, on: page, in: tab, side)
        }
        // D4 as the step keeps it (ITER-076 stage 3, № 81): a click on a pure search's button, its box holding words
        // the brain typed there, is that search — sent by the address its form builds: no click, none of the page's
        // code, no Yes. Words the page put in the box are no search of the brain's.
        if let address = SafetyGuard.searchAddress(for: action, on: page, typed: brainTyped) {
            return try await brainAct(Self.search(address), on: page, in: tab, side)
        }
        // What a cookie window offers free — its least consent, a switch to turn off, the way to its settings — is
        // pressed as the step's own dismiss is: no Yes, a link's own handler run rather than its address opened, no
        // hold of the tab's sends — once on a page: one pressed there before is decided as any control.
        var leastConsent = false
        if cookies != nil, let target = action.target {
            let dismiss = AgentAction(operation: .click, target: target, destination: nil, payload: nil, isPlannedSearch: false)
            if cookiesClicked[pageAddress, default: []].insert(dismiss.effect).inserted {
                action = dismiss
                leastConsent = true
            }
        }
        // A field's edit that sends nothing goes without a Yes only while nothing the page sends goes out: the tab's
        // sends are held — as a form's Fill holds them — until the send pressed with the user's Yes, the user's
        // part, the errand's end or another document; an edit whose change the page sends by itself is held back
        // there — a choice's is put back and asked about (`heldBackChoice`). Without the hold, the edit is asked about
        // as any act (Codex review of 2026-10-19, P1-2). A cookie window's free press is no edit.
        var editing = !leastConsent && !asSend && SafetyGuard.editsOnly(action)
        if editing, heldTab == nil || heldDocument != page.loadedFrom {
            await releaseSends()
            if await parts.bridge.holdSends(true, in: tab) {
                (heldTab, heldDocument, sendHeld) = (tab, page.loadedFrom, false)
            } else {
                editing = false
            }
        }
        // Risk (§6.3, §7.1): what the page's structure and the lexicon say, then Jev — the second lock — for
        // every action that is not always reversible; its grant answer makes the step the user's part. A held
        // edit is Jev's alone (`AgentPolicy.editRisk`): its form's send is asked about when it is pressed. A choice
        // whose change the page sent is a send: irreversible, Jev asked for its grant.
        let known: ActionRisk? = action.isPlannedSearch || leastConsent ? .alwaysReversible
            : asSend ? .irreversible
            : editing ? nil : AgentPolicy.risk(of: action, irreversibleNoul: nil, pageURL: page.address(of: action.target))
        var risk = known
        if known != .alwaysReversible {
            let engine = parts.engine
            let summary = PageSummary(url: page.url, title: page.title, text: page.text)
            let goal = goal
            switch try await askEngine(usage: { $0.usage }, { [action] in
                try await engine.risk(of: action, on: summary, goal: goal)
            }) {
            case .ended(let ending):
                side.ended = ending
                return BrainActed(kind: .ended, note: "The agent's service ended the errand.")
            case .missed:
                return BrainActed(kind: .notDone, note: "its risk could not be checked now; try again.")
            case .answered(let answer):
                guard let grants = AgentPolicy.grants(noul: answer.grant) else {
                    return BrainActed(kind: .notDone, note: "its risk could not be checked now; try again.")
                }
                if grants {
                    log(action, .handedOver, 1, began)
                    return try await brainPart(.grant, on: page, in: tab, side)
                }
                if editing {
                    risk = AgentPolicy.editRisk(irreversibleNoul: answer.irreversible)
                } else if known == nil {
                    risk = AgentPolicy.risk(of: action, irreversibleNoul: answer.irreversible,
                                            pageURL: page.address(of: action.target))
                }
            }
        }
        guard let risk else { return BrainActed(kind: .notDone, note: "its risk could not be checked now; try again.") }
        // A held edit Jev calls reversible pays nothing, whatever its field is named ("Payment method: cash on
        // delivery"); any other act — an edit Jev calls irreversible too — is read for payment.
        if !(editing && risk != .irreversible), SafetyGuard.pays(action, risk: risk, on: page.flags) {
            log(action, .handedOver, 1, began)
            side.ended = handOver(.payment, on: page)
            return BrainActed(kind: .ended, note: "Paying is the user's part; the errand ends here.")
        }
        var target = page
        var acting = action
        var approval: ActionScript.Approval?
        var asked: String?
        if AgentPolicy.decide(confidence: 1, risk: risk) == .askUser {
            asked = Self.question(action, on: page)
            // A press that sends a form is bound to every value the form holds as it was asked: one changed while the
            // question waited voids the Yes, and the press checks them all again as it goes (`sendForm`, № 93;
            // Codex review of 2026-10-19, P1-3).
            // A press of no form may send any field of the page by its script: it is bound to every field of the
            // page (Codex review 2 of 2026-10-19, P1). Only a button that submits its own form sends that form's values
            // alone: a group is also a box of fields around a form, and a button in it beside the form submits by
            // script (Codex review 3 of 2026-10-19, P1). A choice asked about as a send is bound as such a press is: its
            // page's script may send any field of it (2026-10-21).
            let presses = (asSend || SafetyGuard.commits(action)) && action.target != nil
            let form = presses ? action.target.flatMap { $0.submits == true ? formKey(of: $0, on: page) : nil } : nil
            let bound = presses ? Self.boundForPress(form, on: page) : nil
            switch try await askUser(action, on: page, in: tab) {
            case .approved(let fresh, let again):
                if presses, Self.boundForPress(form, on: fresh) != bound {
                    log(action, .gone, 1, began)
                    return BrainActed(kind: .notDone, note: "the form's values changed while the user was asked; look again.",
                                      asked: asked)
                }
                if again.target?.needsFile == true {
                    log(action, .handedOver, 1, began)
                    return try await brainPart(.file, on: fresh, in: tab, side)
                }
                if again.target?.touchesSecret == true || SafetyGuard.needsTheUsersSecret(again) {
                    log(action, .handedOver, 1, began)
                    return try await brainPart(fresh.flags(of: again.target).paymentForm ? .payment : .signIn,
                                               on: fresh, in: tab, side)
                }
                if SafetyGuard.pays(again, risk: risk, on: fresh.flags) {
                    log(action, .handedOver, 1, began)
                    side.ended = handOver(.payment, on: fresh)
                    return BrainActed(kind: .ended, note: "Paying is the user's part; the errand ends here.", asked: asked)
                }
                target = fresh
                approvedFrom = page.loadedFrom.map(Self.requested)
                acting = again
                approval = ActionScript.Approval(pageURL: action.operation == .open ? page.liveAddress
                                                    : page.address(of: action.target),
                                                 text: action.target?.text ?? "",
                                                 formSubmitLabel: action.target?.formSubmitLabel,
                                                 submits: action.target?.submits,
                                                 formGrants: action.target?.formGrants,
                                                 paymentForm: fresh.flags(of: again.target).paymentForm,
                                                 listForm: action.target?.listForm, formValues: bound)
            case .refused:
                refused[pageAddress, default: []].insert(action.effect)
                log(action, .refused, 1, began)
                return BrainActed(kind: .userSaidNo, asked: asked)
            case .lapsed:
                log(action, .refused, 1, began)
                return BrainActed(kind: .notDone, note: "the page changed while the user was asked; look again.",
                                  asked: asked)
            }
        }
        noteTabEvents(tab)
        if let dialogNamed { return try await brainPart(dialogNamed, on: target, in: tab, side) }
        declinedThisStep = false
        let sending = Sending(outcome: approval == nil ? .acted : .confirmed, confidence: 1, began: began)
        _ = parts.bridge.windowsOpened(in: tab)
        let sent = approval != nil && (asSend || SafetyGuard.commits(action))
        // The user's Yes lets this act's sends go: a press armed with its form's values releases them itself, right
        // before it goes (`dispatchTrusted`); any other approved act releases them here.
        if approval != nil, approval?.formValues == nil { await releaseSends() }
        let dialogsBefore = dialogsThisStep
        // A choice made under the hold: a send held from here on is its change's own (`heldBackChoice`).
        let choosing = editing && approval == nil && action.operation == .select
        if choosing { sendHeld = false }
        switch try await dispatch(acting, on: target, in: tab, approval: approval, sending: sending) {
        case .named(let kind):
            return try await brainPart(kind, on: target, in: tab, side)
        case .fileNeeded(let recorded):
            if !recorded { log(action, .handedOver, 1, began) }
            return try await brainPart(.file, on: target, in: tab, side)
        case .changed:
            log(action, .gone, 1, began)
            return BrainActed(kind: .notDone, note: "what it acts on changed before it went; look again.", asked: asked)
        case .finished(let outcome):
            log(action, outcome, 1, began)
            if outcome == .handedOver {
                return try await brainHandOverAtTheAct(acting, on: target, in: tab, side)
            }
            if outcome == .acted {
                took(acting)
                noteBrainTyped(acting)
                if let held = heldBackEdit(action, editing: editing, on: page, in: tab, began: began, side) { return held }
                return BrainActed(kind: .done, asked: asked, sent: sent)
            }
            return BrainActed(kind: .notDone, note: Self.why(outcome), asked: asked)
        case .answered(let outcome):
            if outcome == .handedOver { return try await brainHandOverAtTheAct(acting, on: target, in: tab, side) }
            return BrainActed(kind: .notDone, note: Self.why(outcome), asked: asked, sent: sent)
        case .sent(let check):
            took(acting)
            noteBrainTyped(acting)
            var held = try await postcondition(check)
            noteTabEvents(tab)
            // A page that answered the act with a dialog the bridge closed took it — Demoblaze's Add to cart shows
            // "Product added." and nothing else (2026-10-21, blind b14: read as not taken, the add was pressed again
            // and again). A declined one — a confirm cancelled without a Yes — still says it did not go.
            if held == false, dialogsThisStep > dialogsBefore, !declinedThisStep { held = true }
            // A window an edit's click opens is not followed: an edit sends nothing, and following it is a navigation
            // the hold never sees — typing's own click follows none (Codex review of 10d923e..41c4983, P1-1).
            if action.operation == .click, !editing, let address = parts.bridge.windowsOpened(in: tab).last,
               dialogNamed == nil, !refusedThisStep, !declinedThisStep {
                if let opened = try await openWindow(address, after: check) { held = opened }
                noteTabEvents(tab)
            }
            let failed = held == false || (held == true && (refusedThisStep || declinedThisStep))
            if failed { record.markLastStep(.failed).map(parts.log) }
            // A send with the user's Yes not known to have landed is never sent again on this page.
            if approval != nil, held != true || answeredOnlyByABox { refused[pageAddress, default: []].insert(action.effect) }
            if let dialogNamed { return try await brainPart(dialogNamed, on: target, in: tab, side) }
            if choosing {
                noteTabEvents(tab)
                if sendHeld { return try await heldBackChoice(action, on: page, in: tab, began: began, side) }
            }
            if let held = heldBackEdit(action, editing: editing, on: page, in: tab, began: began, side) { return held }
            return failed ? BrainActed(kind: .notDone, note: "the page did not show that it took effect.", asked: asked,
                                       sent: sent)
                : BrainActed(kind: .done, asked: asked, sent: sent)
        }
    }

    /// A choice whose change the page sent by itself, held back (2026-10-21: a quote site's author list posts its
    /// form as it changes, a shop's sort list opens the sorted page by its address): nothing went out. The list is put
    /// back to the choice it held — its sends still held, so what that change sends is held back too — and the choice
    /// is then asked about as a send: bound as a press of no form is, to every field of the page as asked, and made
    /// again with the Yes as its permit, so the page's own send goes out once (`brainAct`, `asSend`). A No refuses it
    /// on this page, the brain hears it, and the errand goes on. A list that cannot be put back so — one that takes
    /// several choices, a choice it no longer lists once, a list gone or changed — leaves the form to the user, as any
    /// held-back edit.
    private func heldBackChoice(_ action: AgentAction, on page: ObservedPage, in tab: BrowserTab,
                                began: ContinuousClock.Instant, _ side: BrainSide) async throws -> BrainActed {
        guard let list = action.target, list.role == "combobox", let held = list.value, let now = try await look(tab),
              let current = now.element(sameAs: list, matching: page.identity(of: list), seenIn: page),
              current.options?.filter({ $0 == held }).count == 1 else {
            return formLeftToTheUser(action, on: page, began: began, side)
        }
        let back = AgentAction(operation: .select, target: current, destination: nil, payload: held, isPlannedSearch: false)
        // The run's own act, no one asked: on record at no cost.
        stepCost = 0
        let putBack = try await dispatch(back, on: now, in: tab, approval: nil,
                                         sending: Sending(outcome: .acted, confidence: 1, began: began))
        if case .named(let kind) = putBack { return try await brainPart(kind, on: now, in: tab, side) }
        guard case .sent(let check) = putBack, try await postcondition(check) == true else {
            return formLeftToTheUser(action, on: page, began: began, side)
        }
        // What the list's change sent as it was put back was held back with the rest: it is no send of the choice's.
        noteTabEvents(tab)
        sendHeld = false
        if let dialogNamed { return try await brainPart(dialogNamed, on: now, in: tab, side) }
        guard let shown = try await look(tab),
              let restored = shown.element(sameAs: current, matching: now.identity(of: current), seenIn: now),
              restored.valueKey == list.valueKey else {
            return formLeftToTheUser(action, on: page, began: began, side)
        }
        let choice = AgentAction(operation: .select, target: restored, destination: nil, payload: action.payload,
                                 isPlannedSearch: false)
        return try await brainAct(choice, on: shown, in: tab, side, asSend: true)
    }

    /// Words the brain typed, kept by the field: a search box holding them is the brain's search (D4).
    private func noteBrainTyped(_ action: AgentAction) {
        guard action.operation == .type, let field = action.target, let text = action.payload else { return }
        brainTyped[field.fingerprint] = text
    }

    /// What a press's Yes is bound to: the form's every value for a button that submits its own form, or, for any
    /// other press, every field of the page.
    private static func boundForPress(_ form: FormKey?, on page: ObservedPage) -> [ActionScript.BoundValue] {
        form.map { bound($0, on: page, outside: false) } ?? page.elements.compactMap { ActionScript.BoundValue($0, on: page) }
    }

    /// An edit whose change the page sent by itself, held back (`heldBack`): nothing went out, and the form is the
    /// user's to finish. Nil for any other act.
    private func heldBackEdit(_ action: AgentAction, editing: Bool, on page: ObservedPage, in tab: BrowserTab,
                              began: ContinuousClock.Instant, _ side: BrainSide) -> BrainActed? {
        noteTabEvents(tab)
        guard editing, sendHeld else { return nil }
        return formLeftToTheUser(action, on: page, began: began, side)
    }

    /// The form a page sends by itself as a field changes, left to the user: nothing went out, and the errand ends.
    private func formLeftToTheUser(_ action: AgentAction, on page: ObservedPage, began: ContinuousClock.Instant,
                                   _ side: BrainSide) -> BrainActed {
        log(action, .handedOver, 1, began)
        record.form = FormEnding(kind: .notSent, host: URL(string: page.url)?.host ?? "")
        side.ended = .needsUser
        return BrainActed(kind: .ended, note: "The page sends this form by itself as a field changes; filling it is the user's part.")
    }

    /// A wall the hands met at the act, as the brain hears it: the act is the user's part, as the run's step makes
    /// it (`handOverAtTheAct`).
    private func brainHandOverAtTheAct(_ action: AgentAction, on page: ObservedPage, in tab: BrowserTab,
                                       _ side: BrainSide) async throws -> BrainActed {
        switch try await handOverAtTheAct(action, on: page, in: tab) {
        case nil:
            return BrainActed(kind: .notDone, note: "the user did their part; look at the page again.")
        case .errand(let ending)?:
            side.ended = ending
            return BrainActed(kind: .ended, note: "A sign-in or a payment is the user's part; the errand ends here.")
        case .subgoal?:
            return BrainActed(kind: .notDone, note: "the user's part was not done.")
        }
    }

    /// What the brain hears of an error a page caused — one that did not load, a script that failed or timed out, a
    /// report that could not be read; nil for an error that ends the errand: Stop, a ceiling, the errand's own end
    /// inside a call, a browser or tab gone.
    static func pageTrouble(_ error: any Error) -> String? {
        if error is CancellationError || error is CeilingReached || error is BrainEnded || isLost(error) { return nil }
        return "the page did not load or answer in time; look again, go back, or try another way."
    }

    /// What an act that did not go through came to, in the brain's words.
    private static func why(_ outcome: ErrandRecord.Outcome) -> String {
        switch outcome {
        case .gone: "the control is gone or changed; look again."
        case .ambiguous: "more than one control matches it; choose another."
        case .unsupported: "this control cannot be used that way."
        case .refused: "the user said no."
        case .handedOver: "this is the user's part."
        case .failed: "the page did not take it."
        case .acted, .confirmed, .reconsidered: "the page did not show that it took effect."
        }
    }

    /// Enter in the field typed into (there are no keys to press): a search form's search, opened by the address
    /// its form builds (D4); any other form, its own button, through the rails as that click.
    fileprivate func brainEnter(after field: ObservedElement, typed: String, on page: ObservedPage, in tab: BrowserTab,
                                _ side: BrainSide) async throws -> BrainActed {
        guard let now = page.element(matching: page.identity(of: field)) ?? page.elements.first(where: { $0.index == field.index })
        else { return BrainActed(kind: .notDone, note: "the field is gone from the page; look again.") }
        if let address = SafetyGuard.searchAddress(typedInto: now, on: page, typed: [now.fingerprint: typed]) {
            return try await brainAct(Self.search(address), on: page, in: tab, side)
        }
        // The field's own form's button: the same group of the same document — never a sibling form that sends to
        // the same address (Codex review of 2026-10-19, P2).
        guard let group = now.group, let button = page.elements.first(where: {
            $0.submits == true && $0.group == group && $0.frameIdentity == now.frameIdentity
        }) else { return BrainActed(kind: .notDone, note: "this field's form has no button to send it; click the page's own button.") }
        let press = AgentAction(operation: .click, target: button, destination: nil, payload: nil, isPlannedSearch: false)
        return try await brainAct(press, on: page, in: tab, side)
    }

    /// The run's side of the brain: the model call paid for and kept on record as every model call is, and the
    /// run's own eyes, hands and rails.
    @MainActor
    final class BrainSide: Brain, BrainHands {
        private unowned let run: AgentRun
        let tab: BrowserTab
        let brain: any Brain
        /// How the errand ended inside a call or an act, when it did there.
        fileprivate(set) var ended: ErrandRecord.Ending?

        init(run: AgentRun, tab: BrowserTab, brain: any Brain) {
            self.run = run
            self.tab = tab
            self.brain = brain
        }

        func think(_ messages: [CDPValue], tools: [CDPValue]) async throws -> ProLLMClient.Outcome {
            let request = ProLLMClient.Request(purpose: .subgoal, messages: messages, tools: tools.isEmpty ? nil : tools)
            let brain = brain
            switch try await run.askModel(.subgoal, worstCaseUSD: ErrandModel.worstCaseUSD(of: request),
                                          within: AgentRun.brainDeadline,
                                          usage: { (answer: ProLLMClient.Answer) in answer.usage },
                                          { try await brain.think(messages, tools: tools).answer() }) {
            case .answered(let answer): return .answered(answer)
            case .missed: return .invalid
            case .ended(let ending):
                ended = ending
                throw BrainEnded()
            }
        }

        func checkpoint() throws {
            try run.checkpoint(countingSteps: true)
            run.budget.countStep()
            run.stepsAsked += 1
        }

        func look() async throws -> (page: ObservedPage, tabs: [BrainTab]) {
            _ = await run.loaded(tab)
            let page: ObservedPage
            do {
                page = try await run.observe(tab)
            } catch {
                guard AgentRun.pageTrouble(error) != nil else { throw error }
                // A page that cannot be read now is read again once; still unreadable, the brain sees an empty page
                // and can go elsewhere.
                try await Task.sleep(for: .seconds(1))
                try run.checkpoint()
                do {
                    page = try await run.observe(tab)
                } catch {
                    // The second read's error is weighed as the first's: a browser gone ends the errand (Codex review
                    // 3 of 2026-10-19, P2).
                    guard AgentRun.pageTrouble(error) != nil else { throw error }
                    let address = await address() ?? ""
                    return (ObservedPage(url: address, title: "", truncated: false, flags: .none, elements: [],
                                         text: "This page could not be read. Go back, or open another page."),
                            [BrainTab(id: String(tab.tabID.suffix(4)), url: address, title: "", current: true)])
                }
            }
            run.lastPage = page
            // The brain's own navigation took the tab away from the form it filled: what the next document sends is
            // its own (as `step`, review round 2, R2-2).
            if let held = run.heldDocument, let now = page.loadedFrom, now != held { await run.releaseSends() }
            // What ends before any step: a page's dialog that named the user's part. A consent page is shown to the
            // brain, which may leave it; an act on it is the user's part (`brainAct`).
            if let named = run.dialogNamed {
                if case .ended = try await run.brainPart(named, on: page, in: tab, self).kind { throw BrainEnded() }
            }
            return (page, [BrainTab(id: String(tab.tabID.suffix(4)), url: page.url, title: page.title, current: true)])
        }

        func address() async -> String? {
            (try? await run.parts.bridge.run("location.href", in: tab))
        }

        func act(_ action: AgentAction, on page: ObservedPage) async throws -> BrainActed {
            do {
                return try await run.brainAct(action, on: page, in: tab, self)
            } catch {
                // A page that did not load or answer is the brain's to hear; Stop, a ceiling, the errand's own end
                // and a browser gone end the errand (2026-10-19: one blind errand ended at a page that never settled).
                guard let note = AgentRun.pageTrouble(error) else { throw error }
                return BrainActed(kind: .notDone, note: note)
            }
        }

        func enter(after field: ObservedElement, typed: String, on page: ObservedPage) async throws -> BrainActed {
            try await run.brainEnter(after: field, typed: typed, on: page, in: tab, self)
        }

        func scroll(down: Bool, pages: Double, on page: ObservedPage) async throws {
            try run.checkpoint()
            let by = (down ? 1 : -1) * pages
            _ = try await run.parts.bridge.run("window.scrollBy(0, \(by) * window.innerHeight * 0.9); 'ok'", in: tab)
        }

        func evaluate(_ script: String) async throws -> String {
            try run.checkpoint()
            return try await run.parts.bridge.run(script, in: tab)
        }

        /// The page's whole text as the reader reads it: its rules for secret fields, someone's writing and text
        /// drawn as dots hold (`blocksSource`; Codex review of 2026-10-19, P1-4).
        func pageText() async throws -> String {
            try run.checkpoint()
            let report = try await run.parts.bridge.run(ObserverScript.blocksSource(limit: AgentRun.brainReadLimit), in: tab)
            return ErrandModel.Capture.decode(report)?.blocks.map(\.text).joined(separator: "\n") ?? ""
        }
    }
}
