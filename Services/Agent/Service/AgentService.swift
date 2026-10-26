import AppKit
import Combine
import Foundation

/// Where the service gets a browser for an errand: `ChromeLink` in the app.
@MainActor
protocol BrowserLink: AnyObject {
    var state: ChromeLink.State { get }
    /// The state now, then every change.
    var states: AnyPublisher<ChromeLink.State, Never> { get }
    /// A bridge into the browser; nil with `state` saying why. A
    /// request that starts a new attempt sets `state` to `.connecting` before
    /// it first waits; one that joins an attempt under way or reuses the open
    /// connection leaves it as it is. A caller whose task is cancelled is
    /// back at once.
    func errandBridge() async -> (any BrowserBridge)?
    /// Whether the browser is the agent's own (ITER-076 stage 4b): the app's
    /// quit closes it. The user's own Chrome is never closed.
    var ownsBrowser: Bool { get }
    /// Closes the agent's own browser, the agent's tab with it; nothing for
    /// the user's own Chrome.
    func closeOwnBrowser() async
    /// Closes the connection to the browser (ITER-076 stage 8b); the browser
    /// stays open — the user's own Chrome is never closed.
    func disconnect()
    /// Closes the agent's own browser, then deletes its profile — its
    /// history and sign-ins — and nothing else (ITER-076 stage 8b, 8.12);
    /// nothing for the user's own Chrome.
    func forgetOwnBrowser() async
}

/// A link with no browser of its own and no connection kept: nothing to
/// close, drop or forget.
extension BrowserLink {
    var ownsBrowser: Bool { false }
    func closeOwnBrowser() async {}
    func disconnect() {}
    func forgetOwnBrowser() async {}
}

extension ChromeLink: BrowserLink {
    var states: AnyPublisher<State, Never> { $state.eraseToAnyPublisher() }

    func errandBridge() async -> (any BrowserBridge)? { await bridge() }

    var ownsBrowser: Bool { own != nil }
}

/// The user's say over the agent, as the service reads it (ITER-076 stage 8b): Settings → Agent and the disclosure
/// before the first errand — `AppSettings` in the app, the test's own values in tests, never the host's there.
struct AgentSettings {
    /// "Browser agent" (8.1: on until the user turns it off).
    var isOn: @MainActor () -> Bool
    /// The user's Allow on the disclosure (8.2): kept for good — through off and on, and a cleared MetaChat.
    var isAllowed: @MainActor () -> Bool
    /// Keeps the user's Allow.
    var allow: @MainActor () -> Void
    /// The browser errands use (8.3, "Use your own Chrome"): read as each errand begins.
    var way: @MainActor () -> AgentBrowser

    /// The app's: `AppSettings`.
    static let app = AgentSettings(isOn: { AppSettings.shared.browserAgentOn },
                                   isAllowed: { AppSettings.shared.browserAgentAllowed },
                                   allow: { AppSettings.shared.browserAgentAllowed = true },
                                   way: { AgentBrowser(setting: AppSettings.shared.agentBrowser) })
}

/// One of an errand's events, and the errand it belongs to.
struct ErrandUpdate: Equatable {
    let id: UUID
    let origin: ErrandOrigin
    let event: ErrandEvent
}

/// Owns every errand from its start to its end (ITER-076 B1): one runs and at
/// most three wait (`AgentQueue`); each gets a browser from the link — the
/// agent's own Chrome, or the user's (stage 4b) — then a run from the
/// factory, and every step of that shows as an event, in order, for the
/// Island and MetaChat. Every errand that ends is kept on disk
/// with its record, and the Mac going to sleep or the app quitting stops them
/// all. Every change of state is whole before anyone hears of it, so a
/// subscriber that calls back finds each errand where it now is. Logs hold
/// ids and numbers only — never the goal, a page or an answer — each errand's
/// lines under its id (ITER-076 I-06a): its start, its place in the queue,
/// what stopped it and the ending saved; its run says the rest.
@MainActor
final class AgentService: ObservableObject {
    /// The app's service, with the app's own run for each errand (ITER-076
    /// stage 1, № 14): a Pro user can run one — in MetaWhisp's own Chrome
    /// window, or in the user's own Chrome, as Settings → Agent says at each
    /// errand's start (stage 8b) — only with the Ultra switch on (U1,
    /// `UltraFeatures`): off, the agent is off, whatever the user set. Since
    /// 2026-10-20 the run is the brain's (owner decision of 2026-10-19: one
    /// model decides every step), through the Pro server on the product's arm;
    /// the older step pipeline stays the bench's.
    static let shared = AgentService(link: ChromeLink.app(.ownWindow), keepAwake: KeepAwake(), store: ErrandRecordStore(),
                                     makeRunner: AgentRun.thinking(brain: { ServerBrain(arm: ServerBrain.productArm) }),
                                     reporter: ErrandReporter(),
                                     settings: .app.gated(by: { UltraFeatures.isOn() }),
                                     usersLink: ChromeLink.app(.usersChrome))

    /// The running errand's latest event — once it has ended, its last one —
    /// for a view to read.
    @Published private(set) var latest: ErrandUpdate?
    /// The disclosure before the first errand (ITER-076 stage 8b, 8.2), while
    /// an errand waits for the user's Allow: the browser that errand will run
    /// in. Nil when none waits.
    @Published private(set) var disclosure: AgentBrowser?
    /// Whether an errand runs — from one's start to the last one's end, back
    /// to back included. The Mac is kept awake meanwhile, and the activity
    /// lease follows it, so a swap never quits the app mid-errand.
    @Published private(set) var errandRunning = false

    /// Every errand's events, in order.
    var events: AnyPublisher<ErrandUpdate, Never> { updates.eraseToAnyPublisher() }

    /// Runs an action on the main actor once a time has passed.
    typealias Schedule = (Duration, @escaping @MainActor () -> Void) -> Void

    /// A run that has not returned by its absolute expiry (ITER-074 §8) —
    /// plus a minute for its last call and its tab — is ended by the service,
    /// so a run that never returns cannot keep the Mac awake and the lease
    /// busy for good.
    static let ceiling = AgentBudget.Limits.standard.expiry + .seconds(60)

    /// A quit lasts at most the app's wait for its stopped runs: Stop's limit
    /// (ITER-076 stage 9d, № 20). An app still running a minute past that had
    /// its quit cancelled, and errands may start again (№ 25).
    static let quitLimit = AgentRun.stopLimit + .seconds(60)

    /// How long the owner's switch keeps errands off once a run heard it
    /// (ITER-076 stage 9d, № 27): a minute — then the next errand asks the
    /// server again. A launch starts with errands on.
    static let switchRecheck: Duration = .seconds(60)

    /// The endings the owner hears of (ITER-076 I-06b): one report of the
    /// errand's saved record goes to MetaWhisp.
    static let reportedEndings: Set<ErrandRecord.Ending> = [.failed, .unavailable, .stuck]

    /// How long an errand waits for the user's Allow on the disclosure
    /// (ITER-076 stage 8b, A1): the window a pause waits for the user's part.
    static let consentWindow = AgentRun.pauseWindow

    /// The link to MetaWhisp's own Chrome — in tests, the only link.
    private let link: BrowserLink
    /// The link to the user's own Chrome (ITER-076 stage 8b); nil: `link` serves both ways.
    private let usersLink: BrowserLink?
    private let settings: AgentSettings
    private let keepAwake: KeepAwake
    private let store: ErrandRecordStore
    private let isPro: @MainActor () -> Bool
    private let makeRunner: ErrandRunnerFactory?
    private let now: () -> ContinuousClock.Instant
    private let schedule: Schedule
    /// Where the service's lines go, and its runs' (ITER-076 I-06a).
    private let say: @MainActor @Sendable (String) -> Void
    /// Reports each failed errand to MetaWhisp (ITER-076 I-06b); none without it.
    private let reporter: ErrandReporter?
    private let updates = PassthroughSubject<ErrandUpdate, Never>()
    private var queue = AgentQueue()
    /// Where each errand the service holds, running or waiting, was asked for.
    private var origins: [UUID: ErrandOrigin] = [:]
    /// The place each waiting errand was last told.
    private var positions: [UUID: Int] = [:]
    private var running: Running?
    /// Each run the service made that has not returned yet — its errand's
    /// task, by errand: the running one's, and each one's the service ended
    /// before its run returned (Stop, sleep, the ceiling), which may still be
    /// closing its tab (ITER-076 stage 9d, № 20).
    private var unreturned: [UUID: Task<Void, Never>] = [:]
    /// From the Mac's "going to sleep" until it wakes: nothing starts.
    private var asleep = false
    /// From the app's quit on: nothing starts, until the exit — or, for a
    /// quit that did not end the app, `quitLimit` after it began.
    private var quitting = false
    /// The quits so far: only the latest one's limit lifts the latch.
    private var quits = 0
    /// Until when the owner's switch keeps errands off, once a run heard it.
    private var switchedOffUntil: ContinuousClock.Instant?
    /// Events waiting for the change under way to be whole; `latest` marks
    /// the running errand's.
    private var outbox: [(update: ErrandUpdate, latest: Bool)] = []
    /// Changes under way, nested ones included.
    private var changing = 0
    private var delivering = false
    /// Codex round 3, N3-P1-2 — every save for an errand carries the
    /// generation captured at admit; a clear bumps the counter and every
    /// save whose generation is older than the current one is skipped, so
    /// a delayed final overwrite from a stopped runner cannot bring a
    /// cleared record back. A fresh errand after the clear captures the
    /// new generation and saves normally.
    private var recordGeneration: UInt64 = 0
    /// The agent was turned off or the browser changed (ITER-076 stage 8b):
    /// once nothing runs, the browser no errand uses any more is let go.
    private var letGoWaiting = false
    /// MetaChat was cleared (ITER-076 stage 8b, 8.12): once nothing runs,
    /// MetaWhisp's own Chrome closes and its profile is deleted.
    private var forgetWaiting = false

    /// The errand that runs, from its start until the service ends it.
    private final class Running {
        let errand: AgentQueue.Errand
        let makeRunner: ErrandRunnerFactory
        /// The service's record-generation counter at admit. Every save for
        /// this errand (the initial one and any delayed final overwrite
        /// after Stop, sleep, quit, or the ceiling) must compare against the
        /// live generation and skip when stale — Codex round 3, N3-P1-2.
        let generation: UInt64
        /// The browser the errand runs in, as Settings → Agent said at its
        /// start (ITER-076 stage 8b): a change of way serves the next errand.
        let way: AgentBrowser
        var task: Task<Void, Never>?
        /// The user's Allow the errand waits for, while it does (stage 8b).
        var consent: CheckedContinuation<Bool, Never>?
        /// The link's states, followed while the errand waits for its bridge.
        var connecting: AnyCancellable?
        var runner: (any ErrandRunner)?
        /// The errand's browser, once it has one: Show tab fronts its tab.
        var bridge: (any BrowserBridge)?
        var question: Question?
        /// The user's part the run waits on, while it does (ITER-076 stage 3).
        var pause: Pause?
        /// The errand's latest event other than a question: shown again once
        /// a question closes.
        var shown: ErrandEvent?
        /// How the errand ended and where it was asked for, once the service
        /// has ended it: a stopped run's final record is saved with them.
        var ended: (origin: ErrandOrigin, outcome: ErrandOutcome)?

        init(errand: AgentQueue.Errand, makeRunner: @escaping ErrandRunnerFactory, generation: UInt64,
             way: AgentBrowser) {
            self.errand = errand
            self.makeRunner = makeRunner
            self.generation = generation
            self.way = way
        }
    }

    /// A question the run waits on: what it asks, and a token that tells it
    /// from a later one.
    private struct Question {
        let token: UUID
        let request: ConfirmationRequest
        let continuation: CheckedContinuation<ConfirmationRequest.Answer?, Never>
    }

    /// A pause the run waits on (ITER-076 stage 3): what it shows — whose id
    /// tells it from a later one — and the tab it waits in.
    private struct Pause {
        let shown: ErrandPause
        let tab: BrowserTab
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// `makeRunner`: nil while the app has no run for an errand — every start
    /// is then refused as unavailable. `notificationCenter`: where the system
    /// says the Mac is going to sleep. `log`: where every errand's lines go,
    /// the app's log unless a test listens. `reporter`: where a failed
    /// errand's report goes (ITER-076 I-06b); nil sends none. `settings`:
    /// Settings → Agent and the user's Allow (ITER-076 stage 8b); `link`
    /// serves MetaWhisp's own Chrome window, `usersLink` the user's own
    /// Chrome — `link` both ways without it.
    init(link: BrowserLink, keepAwake: KeepAwake, store: ErrandRecordStore,
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         isPro: @escaping @MainActor () -> Bool = { LicenseService.shared.isPro },
         makeRunner: ErrandRunnerFactory? = nil,
         now: @escaping () -> ContinuousClock.Instant = { .now },
         schedule: @escaping Schedule = AgentService.afterDelay,
         log: @escaping @MainActor @Sendable (String) -> Void = { NSLog("%@", $0) },
         reporter: ErrandReporter? = nil, settings: AgentSettings = .app, usersLink: BrowserLink? = nil) {
        self.link = link
        self.usersLink = usersLink
        self.settings = settings
        say = log
        self.reporter = reporter
        self.keepAwake = keepAwake
        self.store = store
        self.isPro = isPro
        self.makeRunner = makeRunner
        self.now = now
        self.schedule = schedule
        // Delivered on the main queue, so the errands have stopped and their
        // records are on disk before the post returns and the Mac sleeps. The
        // center keeps the observers for as long as the service lives.
        _ = notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.macWillSleep() }
        }
        _ = notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.macDidWake() }
        }
    }

    /// Whether MetaChat offers its model an errand, and says it can browse:
    /// only with a run for it in this build (ITER-076 I-04), with the agent
    /// on in Settings → Agent (stage 8b, 8.1), and not while the owner's
    /// switch on the server is off (stage 9d, № 27) — read each time. With or
    /// without Pro (8.5): without it the start answers, in the approved
    /// words, that the browser agent needs Pro.
    var canRunErrands: Bool { makeRunner != nil && settings.isOn() && !switchedOff }

    /// Whether an errand can start (ITER-076 stage 8b): MetaChat's offer, and
    /// Pro — what MetaChat's example of an errand asks.
    var canStartErrands: Bool { canRunErrands && isPro() }

    /// The owner's switch was heard less than `switchRecheck` ago (ITER-076
    /// stage 9d, № 27).
    private var switchedOff: Bool { switchedOffUntil.map { now() < $0 } ?? false }

    /// Starts an errand, or queues it behind the running one. While the Mac
    /// sleeps or the app quits, without Pro, with an empty goal, with no run
    /// in this build, while the owner's switch is off or while the agent is
    /// off in Settings → Agent (ITER-076 stage 8b — a send under way as the
    /// user turned it off), nothing starts and nothing is asked of the
    /// browser.
    ///
    /// The admission is what `start` decided. The events it sends before it
    /// returns, and what subscribers do on them, come after that decision and
    /// supersede it: a subscriber that stops the running errand as it hears
    /// the new one's `.queued` starts the new one before `start` returns
    /// `.queued`. The errand's events are its account. `output`: what the user
    /// asked it to give — its answer, or a Sheet too (ITER-076 stage 6).
    func start(goal: String, origin: ErrandOrigin, output: ErrandOutput = .answer, start: URL? = nil) -> ErrandAdmission {
        guard !quitting else { return refuse(.appQuitting) }
        guard !asleep else { return refuse(.macAsleep) }
        guard isPro() else { return refuse(.notPro) }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return refuse(.emptyGoal) }
        guard let makeRunner, !switchedOff, settings.isOn() else { return refuse(.unavailable) }
        return change { admit(goal, origin: origin, output: output, start: start, making: makeRunner) }
    }

    private func admit(_ goal: String, origin: ErrandOrigin, output: ErrandOutput, start: URL?,
                       making makeRunner: @escaping ErrandRunnerFactory) -> ErrandAdmission {
        let at = now()
        let errand = AgentQueue.Errand(id: UUID(), goal: goal, queuedAt: at, output: output, start: start)
        let (admission, expired) = queue.submit(errand, now: at)
        endNotStarted(expired)
        switch admission {
        case .started:
            origins[errand.id] = origin
            keepAdmitted(errand, origin: origin)
            begin(errand, making: makeRunner)
            return .started(id: errand.id)
        case .queued(let position):
            origins[errand.id] = origin
            keepAdmitted(errand, origin: origin)
            log(errand.id, "queued at \(position)")
            announcePositions()
            return .queued(id: errand.id, position: position)
        case .refused(.queueFull):
            return refuse(.queueFull)
        case .refused(.updateWaiting):
            return refuse(.updateWaiting)
        }
    }

    /// An admitted errand is on disk at once, not ended (ITER-076 stage 9d,
    /// № 21): a crash, a Force Quit or a power loss leaves it there for the
    /// next launch to end (`endInterrupted`). Its own end is saved over it.
    private func keepAdmitted(_ errand: AgentQueue.Errand, origin: ErrandOrigin) {
        store.save(id: errand.id, origin: origin, record: ErrandRecord(errandID: errand.id, goal: errand.goal),
                   outcome: Self.nothing(.stopped))
    }

    /// Stops one errand, running or waiting (ITER-074 §7.4). A running one
    /// ends at once with what it collected: its run is told to stop and is
    /// not waited for, and the next waiting errand starts.
    func stop(_ id: UUID) {
        change {
            if let current = running, current.errand.id == id {
                stopRunning(current, why: "the user")
            } else if let errand = queue.remove(id) {
                log(id, "stop: the user")
                close(errand, Self.nothing(.stopped), record: nil, latest: false)
                announcePositions()
            }
        }
    }

    /// The waiting errands never start, and the running one stops.
    func stopAll() {
        change { stopEverything() }
    }

    /// Allow on the disclosure (ITER-076 stage 8b, 8.2): kept for good, so
    /// the agent asks no more, and the errand that waits on it goes on — the
    /// waiting ones after it. An Allow that comes once that errand has ended
    /// is kept all the same, and starts nothing.
    func allow() {
        settings.allow()
        say("[AgentService] the user allowed the agent")
        guard let current = running, current.consent != nil else { return }
        change { closeConsent(of: current, allowed: true) }
    }

    /// Not now on the disclosure (ITER-076 stage 8b, 8.2): this time only.
    /// The errand that waits on it ends stopped and the waiting ones as all
    /// stopped; nothing is kept, and the next errand asks again. With no
    /// errand waiting on the disclosure it does nothing.
    func notNow() {
        guard let current = running, current.consent != nil else { return }
        change {
            endNotStarted(queue.stopAll())
            stopRunning(current, why: "not now")
        }
    }

    /// The user turned the agent off in Settings → Agent (ITER-076 stage 8b,
    /// 8.4) — or the service found it off, the Ultra switch with it, as a wait
    /// ended (`stillOn`): every errand stops — the running one stopped, the
    /// waiting ones as all stopped — nothing starts while it is off, and once
    /// no run is out MetaWhisp's own Chrome window closes and the connection to
    /// the user's own Chrome with it. The user's Allow is kept.
    func turnedOff() {
        guard !settings.isOn() else { return }
        say("[AgentService] the agent is turned off: errands stop")
        change { stopEverything() }
        letGoWaiting = true
        letGoOnceIdle()
    }

    /// The user chose the other browser in Settings → Agent (ITER-076 stage
    /// 8b, 8.3): it serves the next errand — a running one finishes in its
    /// own — and once nothing runs, the browser no errand uses any more is let
    /// go: MetaWhisp's own Chrome window closes, or the connection to the
    /// user's own Chrome.
    func wayChanged() {
        letGoWaiting = true
        letGoOnceIdle()
    }

    /// An update is ready (ITER-074 §11): the running errand may finish, the
    /// waiting ones end as not started, and nothing new starts until the
    /// update is installed or withdrawn.
    func updateIsReady() {
        change { endNotStarted(queue.updateIsReady()) }
    }

    /// The update did not happen after all: errands start again.
    func updateWithdrawn() {
        queue.updateWithdrawn()
    }

    /// The app is quitting (ITER-074 §11), and it is Stop: the running errand
    /// stops with what it collected kept, the waiting ones end as not
    /// started, the Mac is free and the lease idle — all before this returns,
    /// as the app exits right after. From here on nothing starts, until the
    /// exit. The app never cancels a quit today; a quit that did not end the
    /// app by `quitLimit` was cancelled all the same, and errands may start
    /// again (ITER-076 stage 9d, № 25) rather than stay refused until the app
    /// is opened again.
    ///
    /// Returns what the app waits for before it exits (stage 9d, № 20): every
    /// run not returned yet — the one just stopped, and any one ended a
    /// moment before — returned, its tab closed by then or Stop's limit over;
    /// then the agent's own browser closed (stage 4b), whichever browser
    /// Settings → Agent names (stage 8b). Nil when no run is out and the
    /// service has no browser of its own.
    @discardableResult
    func appWillQuit() -> Task<Void, Never>? {
        quitting = true
        quits += 1
        let quit = quits
        schedule(Self.quitLimit) { [weak self] in
            guard let self, self.quits == quit, self.quitting else { return }
            self.quitting = false
            self.say("[AgentService] the quit did not end the app: errands may start again")
        }
        if running != nil {
            say("[AgentService] the app is quitting: errands stop")
            change { stopEverything(waitingEndAs: .appQuit) }
        }
        let runs = Array(unreturned.values)
        guard !runs.isEmpty || link.ownsBrowser else { return nil }
        let link = self.link
        return Task {
            for run in runs { await run.value }
            await link.closeOwnBrowser()
        }
    }

    /// The errands the last session left not ended — a crash, a Force Quit or
    /// a power loss cut them off (ITER-076 stage 9d, № 21): each ends now as
    /// stopped, with nothing found — that went with the app — and says so, as
    /// any end does, so MetaChat no longer shows it started. A stop is no
    /// failure: none is reported. The app calls this once at launch, once
    /// MetaChat hears the errands' ends; the errands this service holds are
    /// not the last session's.
    func endInterrupted() {
        for (id, kept) in store.unended() where origins[id] == nil {
            let outcome = Self.nothing(.stopped)
            log(id, "cut off in the last session: ends at launch")
            save(AgentQueue.Errand(id: id, goal: kept.record.goal, queuedAt: now()), origin: kept.origin,
                 outcome: outcome, record: kept.record)
            change { outbox.append((ErrandUpdate(id: id, origin: kept.origin, event: .finished(outcome)), false)) }
        }
    }

    /// Removes every saved errand record from the service's own store. Codex
    /// round 2 (P1-3): the records are user-owned private data; "clear
    /// MetaChat history" must clear them too, and they must clear through the
    /// SAME store the service writes to (no second store for the app).
    /// Codex round 3 (N3-P1-2): bumping the generation first means any save
    /// a stopped runner tries to do after the clear — the late overwrite —
    /// is rejected, so a cleared record does not come back. The reports of
    /// failed errands still waiting to go are cleared with them (ITER-076
    /// I-06b): the clear leaves nothing of the user's errands on disk — only
    /// the ids of tabs the agent may still have to close (`AgentTabLedger`,
    /// stage 9d), which hold no word of an errand. Nor of the sites they
    /// visited (ITER-076 stage 8b, 8.12): once nothing runs, MetaWhisp's own
    /// Chrome window closes and its profile — its history and sign-ins — is
    /// deleted; the user's own Chrome is never touched.
    func deleteAllRecords() {
        recordGeneration &+= 1
        store.deleteAll()
        reporter?.clearWaiting()
        forgetWaiting = true
        letGoOnceIdle()
    }

    /// Answers `request`, the question the user saw (`.needsYes`). It counts
    /// only while that very question is open: a Yes given to a question the
    /// run has let go never answers the next one, about another action
    /// (review of B1, S3). The first answer counts; a late or a second one
    /// does not, and false says so.
    @discardableResult
    func answer(_ id: UUID, to request: ConfirmationRequest, _ answer: ConfirmationRequest.Answer) -> Bool {
        guard let current = running, current.errand.id == id, let question = current.question,
              question.request == request else { return false }
        change { settle(current, question.token, with: answer) }
        return true
    }

    /// Continue (ITER-076 stage 3): the user did their part in `pause`, the
    /// one the card or MetaChat shows. It counts only while that very pause
    /// is open: a Continue for an earlier one, another errand's, or one that
    /// ended does nothing, and false says so. The first one counts.
    @discardableResult
    func proceed(_ id: UUID, after pause: ErrandPause) -> Bool {
        guard let current = running, current.errand.id == id, current.pause?.shown == pause else { return false }
        change { settle(current, pause: pause.id, continued: true) }
        return true
    }

    /// Show tab (ITER-076 stage 3, № 114): the running errand's own tab, and
    /// the browser, in front of the user — only while its run waits for the
    /// user's part there. False otherwise.
    @discardableResult
    func showTab(_ id: UUID) -> Bool {
        guard let current = running, current.errand.id == id, let pause = current.pause,
              let bridge = current.bridge else { return false }
        Task { await bridge.show(pause.tab) }
        return true
    }

    // MARK: - An errand's life

    /// The lid closed, or the Mac is going to sleep (owner decision 12 of
    /// 2026-09-26): the running errand stops with what it collected kept, the
    /// waiting ones do not start, the Mac is free and the lease idle. Nothing
    /// starts until the Mac wakes.
    private func macWillSleep() {
        asleep = true
        guard running != nil else { return }
        say("[AgentService] the Mac is going to sleep: errands stop")
        change { stopEverything(waitingEndAs: .macSlept) }
    }

    private func macDidWake() {
        asleep = false
    }

    /// The waiting errands end as not started — as Stop all, or for `reason`
    /// when the service knows better — then the running one stops.
    private func stopEverything(waitingEndAs reason: ErrandOutcome.NotRun? = nil) {
        endNotStarted(queue.stopAll(), as: reason)
        let why = switch reason {
        case .macSlept?: "the Mac sleeps"
        case .appQuit?: "the app quits"
        default: "stop all"
        }
        if let current = running { stopRunning(current, why: why) }
    }

    private func begin(_ errand: AgentQueue.Errand, making makeRunner: @escaping ErrandRunnerFactory) {
        let current = Running(errand: errand, makeRunner: makeRunner, generation: recordGeneration,
                              way: settings.way())
        running = current
        log(errand.id, "started")
        positions[errand.id] = nil
        // Reports that could not go before go at an errand's start (ITER-076 I-06b).
        if let reporter { Task { await reporter.sendWaiting() } }
        let task = Task { await self.drive(current) }
        current.task = task
        unreturned[errand.id] = task
    }

    /// The user's Allow, the browser, then the run. Whatever comes back after
    /// the errand ended is dropped. What the run is given holds the errand
    /// weakly, so a run that keeps it lets go of nothing once the errand has
    /// ended.
    private func drive(_ current: Running) async {
        defer {
            unreturned[current.errand.id] = nil
            letGoOnceIdle()
        }
        // An errand stopped before its task ran asks the browser nothing — nor
        // one whose agent went off before then, or during any wait below
        // (`stillOn`): no run is made, so no brain.
        guard running === current, stillOn() else { return }
        // Nothing asks the browser before the user's Allow (ITER-076 stage
        // 8b): MetaWhisp's own Chrome never starts for an errand not allowed.
        guard await allowed(current), running === current, stillOn() else { return }
        // The browser Settings → Agent named as the errand began (stage 8b).
        let link = link(for: current.way)
        // The link as it stands for this errand's request: before the request
        // its state may be the last attempt's end, which never shows (review
        // of B1, S4). A request that starts an attempt changes the state at
        // once; one that joins an attempt under way or reuses the connection
        // changes nothing, and the job below — which runs once the request is
        // in — shows where it stands.
        current.connecting = link.states.dropFirst().removeDuplicates().sink { [weak self, weak current] state in
            guard let self, let current else { return }
            self.change { self.show(.connecting(state), of: current) }
        }
        Task { @MainActor [weak self, weak current] in
            guard let self, let current, self.running === current, current.shown == nil else { return }
            self.change { self.show(.connecting(link.state), of: current) }
        }
        let bridge = await link.errandBridge()
        guard running === current, stillOn() else { return }
        current.connecting = nil
        // No browser let the errand in: it ends with why the link named
        // (ITER-076 stage 8a, 8b).
        guard let bridge else {
            change { end(current, Self.notLetIn(link.state), record: nil) }
            return
        }
        let id = current.errand.id
        current.bridge = bridge
        let runner = current.makeRunner(ErrandSetup(id: id, goal: current.errand.goal, bridge: bridge,
                                                    confirm: { [weak self, weak current] request in
            guard let self, let current else { return nil }
            return await self.ask(request, for: current)
        }, sheetMade: { [weak self] sheet in
            self?.sheetMade(sheet, errand: id)
        }, log: say, waitForUser: { [weak self, weak current] handover, tab, window in
            guard let self, let current else { return false }
            return await self.wait(for: handover, in: tab, within: window, of: current)
        }, output: current.errand.output, switchedOff: { [weak self] in
            self?.agentSwitchedOff()
        }, start: current.errand.start))
        current.runner = runner
        schedule(Self.ceiling) { [weak self, weak current] in
            guard let self, let current, self.running === current else { return }
            self.change { self.stopRunning(current, why: "past its ceiling", ending: .ceiling) }
        }
        let outcome = await runner.run { [weak self, weak current] progress in
            guard let current else { return }
            self?.report(progress, of: current)
        }
        guard running === current else {
            // Ended before its run returned — Stop, sleep, quit, the ceiling —
            // while the run still checked an action it had sent: its final
            // record goes over the one saved then, with the end it showed.
            // Codex round 3, N3-P1-2: skip the overwrite when the user has
            // cleared MetaChat between Stop and the run returning.
            if let ended = current.ended {
                save(current.errand, origin: ended.origin, outcome: ended.outcome,
                     record: runner.record, generation: current.generation)
            }
            return
        }
        change { end(current, outcome, record: runner.record) }
    }

    /// The user's Allow (ITER-076 stage 8b, 8.2): true at once when kept from
    /// before. Otherwise the errand waits here, its browser never asked, while
    /// the disclosure shows — no card, no line — and true once the user
    /// allowed. False once the errand ended meanwhile: Not now, Stop, Stop
    /// all, the Mac's sleep, the quit, the agent turned off — or
    /// `consentWindow` with no answer, which ends it as one that waited too
    /// long. Nothing is kept but by Allow.
    private func allowed(_ current: Running) async -> Bool {
        guard !settings.isAllowed() else { return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                change {
                    current.consent = continuation
                    disclosure = current.way
                    log(current.errand.id, "waits for the user's Allow")
                    schedule(Self.consentWindow) { [weak self, weak current] in
                        guard let self, let current, current.consent != nil else { return }
                        self.change { self.end(current, Self.nothing(.ceiling, notRun: .expired), record: nil) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self, weak current] in
                guard let self, let current else { return }
                self.change { self.closeConsent(of: current, allowed: false) }
            }
        }
    }

    /// Whether errands may go on: the agent on in Settings → Agent with the
    /// Ultra switch on (`settings.isOn()`, U1) — read again wherever an
    /// errand admitted while it was on goes on after a wait: its task's start,
    /// the user's Allow, its browser, its turn in the queue. Nothing tells the
    /// service when the Ultra switch goes off — it is read at each ask, and
    /// only Settings → Agent's switch calls `turnedOff` — so off found here is
    /// that call: every errand stops before a run is made for it, and the
    /// browsers no errand uses are let go (Codex P2, 1.4.0 merge review).
    @discardableResult
    private func stillOn() -> Bool {
        guard !settings.isOn() else { return true }
        turnedOff()
        return false
    }

    /// Ends the errand's wait for the user's Allow, if it waits, and closes
    /// the disclosure.
    private func closeConsent(of current: Running, allowed: Bool) {
        guard let consent = current.consent else { return }
        current.consent = nil
        disclosure = nil
        consent.resume(returning: allowed)
    }

    /// Once no errand runs and no run is out (ITER-076 stage 8b), what the
    /// errands no longer use is let go: with the agent off, MetaWhisp's own
    /// Chrome window and the connection to the user's own Chrome; with it on,
    /// the one of the two the browser setting no longer names; after a clear,
    /// MetaWhisp's own Chrome and its profile. The user's own Chrome is never
    /// closed — only the connection to it.
    private func letGoOnceIdle() {
        guard letGoWaiting || forgetWaiting, running == nil, unreturned.isEmpty else { return }
        let (on, way) = (settings.isOn(), settings.way())
        let own = link(for: .ownWindow), users = link(for: .usersChrome)
        if letGoWaiting, !on || way != .usersChrome { users.disconnect() }
        let closeOwn = letGoWaiting && (!on || way != .ownWindow)
        let forget = forgetWaiting
        (letGoWaiting, forgetWaiting) = (false, false)
        say("[AgentService] nothing runs: the browsers no errand uses are let go")
        guard forget || closeOwn else { return }
        Task {
            if forget { await own.forgetOwnBrowser() } else { await own.closeOwnBrowser() }
        }
    }

    /// The link for the browser `way` names: the user's own Chrome's, when
    /// the service has one of its own (ITER-076 stage 8b).
    private func link(for way: AgentBrowser) -> BrowserLink {
        way == .usersChrome ? usersLink ?? link : link
    }

    /// The owner switched the agent off on the server (ITER-076 stage 9d,
    /// № 27), as a run heard: its errand ends stopped by itself; the waiting
    /// ones end as all stopped, and errands stay off — MetaChat offers none,
    /// a start is refused — for `switchRecheck`.
    private func agentSwitchedOff() {
        switchedOffUntil = now() + Self.switchRecheck
        say("[AgentService] the agent is switched off on the server: errands stay off for a minute")
        change { endNotStarted(queue.stopAll()) }
    }

    /// The errand's Sheet exists (ITER-076 I-05, review round 2). While the
    /// errand runs, its run's record has it, and the end shows it. Once the
    /// service has ended the errand, the Sheet is added to what was kept of it
    /// — whenever it comes, past the run's return included — and `.amended`
    /// tells MetaChat. A record cleared meanwhile stays cleared.
    private func sheetMade(_ sheet: URL, errand id: UUID) {
        guard running?.errand.id != id, let kept = store.load(id: id), kept.outcome.sheet == nil else { return }
        var record = kept.record
        if record.sheet == nil {
            record.sheet = sheet
            record.sheetWrite = .created
        }
        let amended = kept.outcome.withSheet(sheet)
        store.save(id: id, origin: kept.origin, record: record, outcome: amended)
        log(id, "its Sheet came after its end")
        change {
            outbox.append((ErrandUpdate(id: id, origin: kept.origin, event: .amended(amended)), latest?.id == id))
        }
    }

    private func report(_ progress: ErrandProgress, of current: Running) {
        change {
            guard running === current else { return }
            switch progress {
            case .working(let title, let done, let wanted):
                show(.working(title: title, done: done, wanted: wanted), of: current)
            case .needsUser(let handover):
                show(.needsUser(handover), of: current)
            case .readingForm(let host):
                show(.readingForm(host: host), of: current)
            }
        }
    }

    /// The run's question to the user (ITER-074 §7.1), shown as `.needsYes`.
    /// The first answer goes back; silence for the answer window, Stop, the
    /// errand's end or the run giving up on it is No. A form's preview has
    /// no window (ITER-076 stage 7, decision 7.4): it waits for the user
    /// until the run gives up on it — at the errand's expiry — or Stop. A
    /// new question ends the one before as No.
    private func ask(_ request: ConfirmationRequest, for current: Running) async -> ConfirmationRequest.Answer? {
        guard running === current else { return nil }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                change {
                    closeQuestion(of: current, with: nil)
                    current.question = Question(token: token, request: request, continuation: continuation)
                    publish(current.errand.id, .needsYes(request), latest: true)
                    if let window = request.window {
                        schedule(.seconds(window)) { [weak self, weak current] in
                            guard let self, let current else { return }
                            self.change { self.settle(current, token, with: nil) }
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self, weak current] in
                guard let self, let current else { return }
                self.change { self.settle(current, token, with: nil) }
            }
        }
    }

    /// Closes the question `token` names, if it is still open, and shows
    /// again what the errand was doing.
    private func settle(_ current: Running, _ token: UUID, with answer: ConfirmationRequest.Answer?) {
        guard current.question?.token == token else { return }
        closeQuestion(of: current, with: answer)
        if running === current, let shown = current.shown { publish(current.errand.id, shown, latest: true) }
    }

    private func closeQuestion(of current: Running, with answer: ConfirmationRequest.Answer?) {
        guard let question = current.question else { return }
        current.question = nil
        question.continuation.resume(returning: answer)
    }

    /// The run waits for the user's part (ITER-076 stage 3), shown as
    /// `.paused` — the question's pattern: the first Continue goes back; the
    /// window the run gave, Stop, the errand's end or the run giving up on it
    /// ends it without one. A new pause ends the one before.
    private func wait(for handover: ErrandHandover, in tab: BrowserTab, within window: Duration,
                      of current: Running) async -> Bool {
        guard running === current else { return false }
        let pause = ErrandPause(id: UUID(), handover: handover)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                change {
                    closePause(of: current, continued: false)
                    current.pause = Pause(shown: pause, tab: tab, continuation: continuation)
                    publish(current.errand.id, .paused(pause), latest: true)
                    schedule(window) { [weak self, weak current] in
                        guard let self, let current else { return }
                        self.change { self.settle(current, pause: pause.id, continued: false) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self, weak current] in
                guard let self, let current else { return }
                self.change { self.settle(current, pause: pause.id, continued: false) }
            }
        }
    }

    /// Closes the pause `id` names, if it is still open, and shows again what
    /// the errand was doing.
    private func settle(_ current: Running, pause id: UUID, continued: Bool) {
        guard current.pause?.shown.id == id else { return }
        closePause(of: current, continued: continued)
        if running === current, let shown = current.shown { publish(current.errand.id, shown, latest: true) }
    }

    private func closePause(of current: Running, continued: Bool) {
        guard let pause = current.pause else { return }
        current.pause = nil
        pause.continuation.resume(returning: continued)
    }

    /// The run is told to stop, and what it collected up to now is kept: the
    /// answer its facts make, as the run's own end gives it (ITER-076 brain,
    /// step 2), and its rows — and how its form stands once Send was pressed
    /// (ITER-076 stage 7), so a Stop after it never says only "Stopped.".
    /// `why`: what stopped it, for the log. `ending`:
    /// `.stopped`, or `.ceiling` when the service's ceiling ends it.
    private func stopRunning(_ current: Running, why: String, ending: ErrandRecord.Ending = .stopped) {
        log(current.errand.id, "stop: \(why)")
        current.runner?.stop()
        let record = current.runner?.record
        end(current, ErrandOutcome(ending: ending, answer: record?.answer, sources: record?.sources ?? [],
                                   sheet: record?.sheet, rows: record?.rows.count ?? 0, form: record?.form),
            record: record)
    }

    /// Ends the running errand: its wait for the browser and its question end,
    /// it is kept and its `.finished` waits to go out, and the next waiting
    /// one starts — while the agent is on (`stillOn`). `record`: nil when no
    /// run was made.
    private func end(_ current: Running, _ outcome: ErrandOutcome, record: ErrandRecord?) {
        guard running === current else { return }
        running = nil
        current.connecting = nil
        current.task?.cancel()
        closeConsent(of: current, allowed: false)
        closeQuestion(of: current, with: nil)
        closePause(of: current, continued: false)
        current.ended = close(current.errand, outcome, record: record, latest: true,
                            generation: current.generation).map { ($0, outcome) }
        // The queue's turn: none is next while the agent is off (`stillOn`).
        if !queue.waiting.isEmpty { stillOn() }
        let (next, expired) = queue.finishRunning(now: now())
        endNotStarted(expired)
        if let next { begin(next, making: current.makeRunner) }
        announcePositions()
    }

    /// Waiting errands the queue let go: each ends without running, and says
    /// why — the queue's reason, unless `reason` says better. Waiting 30
    /// minutes is a ceiling; the rest are stops.
    private func endNotStarted(_ dropped: [AgentQueue.NotStarted], as reason: ErrandOutcome.NotRun? = nil) {
        for item in dropped {
            let notRun = reason ?? Self.notRun(item.reason)
            close(item.errand, Self.nothing(notRun == .expired ? .ceiling : .stopped, notRun: notRun), record: nil,
                  latest: false)
        }
    }

    /// An errand's last step: the service lets it go, its record is kept with
    /// the outcome, and its `.finished` waits to go out. Returns where it was
    /// asked for; nil when it was already let go. `generation` is the
    /// generation captured at admit — set when a Running is being closed,
    /// nil for queued errands that never ran (their save cannot come back
    /// late anyway).
    @discardableResult
    private func close(_ errand: AgentQueue.Errand, _ outcome: ErrandOutcome, record: ErrandRecord?,
                       latest: Bool, generation: UInt64? = nil) -> ErrandOrigin? {
        guard let origin = origins.removeValue(forKey: errand.id) else { return nil }
        positions[errand.id] = nil
        save(errand, origin: origin, outcome: outcome, record: record, generation: generation)
        outbox.append((ErrandUpdate(id: errand.id, origin: origin, event: .finished(outcome)), latest))
        return origin
    }

    /// Keeps the errand's record — a record of its own when no run was made —
    /// under the errand's own id, with the end it showed, its last event —
    /// said in the log, by its kind alone (ITER-076 I-06a). A record that
    /// cannot be written is the store's to report; the errand ends all the
    /// same. Codex round 3, N3-P1-2: skips the save when the errand's
    /// generation is older than the service's current one — the user cleared
    /// MetaChat between admit and this save.
    private func save(_ errand: AgentQueue.Errand, origin: ErrandOrigin, outcome: ErrandOutcome,
                      record: ErrandRecord?, generation: UInt64? = nil) {
        var kept = record ?? ErrandRecord(errandID: errand.id, goal: errand.goal)
        kept.end(outcome.ending, failure: outcome.failure, notRun: outcome.notRun).map(say)
        let gen = generation ?? recordGeneration
        guard gen == recordGeneration else {
            log(errand.id, "not saved: generation \(gen) < current \(recordGeneration)")
            return
        }
        // An outcome keeps the Sheet its record has: one made after the end
        // was shown, and kept since, is not dropped by the run's last save.
        store.save(id: errand.id, origin: origin, record: kept, outcome: outcome.withSheet(kept.sheet))
        // A failed errand's report, from the record just saved (ITER-076
        // I-06b). Only the service's own end is saved with these endings: a
        // stopped run's late save ends as stopped or at its ceiling.
        if Self.reportedEndings.contains(outcome.ending) { reporter?.report(kept) }
    }

    // MARK: - Events

    /// Every change of state runs in here: it is whole before anyone hears of
    /// it (review of B1, S1 and S2). Changes nest; what they tell goes out
    /// once the outermost is done.
    @discardableResult
    private func change<T>(_ body: () -> T) -> T {
        changing += 1
        let result = body()
        changing -= 1
        deliver()
        return result
    }

    /// Sends what the changes left: first whether an errand runs, with the Mac
    /// kept awake to match, then each event in order. What a subscriber's call
    /// back changes goes out after the event it answered.
    private func deliver() {
        guard changing == 0, !delivering else { return }
        delivering = true
        defer { delivering = false }
        while true {
            let isRunning = running != nil
            if errandRunning != isRunning {
                if isRunning { keepAwake.hold() } else { keepAwake.release() }
                errandRunning = isRunning
            } else if !outbox.isEmpty {
                let next = outbox.removeFirst()
                if next.latest { latest = next.update }
                updates.send(next.update)
            } else {
                return
            }
        }
    }

    private func show(_ event: ErrandEvent, of current: Running) {
        current.shown = event
        publish(current.errand.id, event, latest: true)
    }

    private func publish(_ id: UUID, _ event: ErrandEvent, latest: Bool) {
        guard let origin = origins[id] else { return }
        outbox.append((ErrandUpdate(id: id, origin: origin, event: event), latest))
        deliver()
    }

    /// Tells each waiting errand its place when it changed; 1 is next.
    private func announcePositions() {
        for (index, errand) in queue.waiting.enumerated() where positions[errand.id] != index + 1 {
            positions[errand.id] = index + 1
            publish(errand.id, .queued(position: index + 1), latest: false)
        }
    }

    /// How an errand ends that collected nothing.
    private static func nothing(_ ending: ErrandRecord.Ending, notRun: ErrandOutcome.NotRun? = nil) -> ErrandOutcome {
        ErrandOutcome(ending: ending, answer: nil, sources: [], sheet: nil, rows: 0, notRun: notRun)
    }

    private static func notRun(_ reason: AgentQueue.NotStarted.Reason) -> ErrandOutcome.NotRun {
        switch reason {
        case .expired: .expired
        case .updateWaiting: .updateWaiting
        case .stoppedAll: .stoppedAll
        }
    }

    /// How an errand ends that no browser let in, from the end the link named
    /// (ITER-076 stage 8a, 8b), whichever way the browser came. MetaWhisp's
    /// own Chrome that did not start, answer or let it in is the app's own
    /// failure, and reported (№ 15). Every other end is a step only the user
    /// can take — Chrome to install, open or set up, an Allow — so the errand
    /// did not run, and nothing is reported (№ 19). A state that names no
    /// failure means the browser did not let the errand in within the link's
    /// limit.
    private static func notLetIn(_ state: ChromeLink.State) -> ErrandOutcome {
        let notRun: ErrandOutcome.NotRun
        switch state {
        case .didNotStart:
            return ErrandOutcome(ending: .failed, answer: nil, sources: [], sheet: nil, rows: 0,
                                 failure: .browserDidNotStart)
        case .notRunning: notRun = .browserNotRunning
        case .notInstalled: notRun = .browserNotInstalled
        case .remoteDebuggingOff: notRun = .remoteDebuggingOff
        case .idle, .connecting, .waitingForAllow, .connected, .notAllowed: notRun = .notAllowed
        }
        return nothing(.stopped, notRun: notRun)
    }

    /// Runs `action` on the main actor once `delay` has passed on the
    /// continuous clock.
    nonisolated static func afterDelay(_ delay: Duration, _ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            action()
        }
    }

    private func refuse(_ refusal: ErrandAdmission.Refusal) -> ErrandAdmission {
        NSLog("[AgentService] errand refused: %@", String(describing: refusal))
        return .refused(refusal)
    }

    /// Says `what` of errand `id` in the log, under its id.
    private func log(_ id: UUID, _ what: String) {
        say("\(ErrandRecord.logPrefix(id)) \(what)")
    }
}
