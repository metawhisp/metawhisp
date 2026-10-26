import AppKit
import Combine
import IOKit.pwr_mgt
import XCTest
@testable import MetaWhisp

/// A browser link the test drives, like `ChromeLink`: a request with no
/// connection and no attempt under way starts one and says `.connecting` at
/// once; a caller waits until the test connects the link or fails it, and is
/// back at once when its task is cancelled; once connected, every caller gets
/// the bridge at once, as the link reuses its open connection.
@MainActor
final class FakeErrandLink: BrowserLink {
    @Published var state: ChromeLink.State = .idle
    var states: AnyPublisher<ChromeLink.State, Never> { $state.eraseToAnyPublisher() }
    let bridge = FakeErrandBridge()
    /// An attempt someone else started is still under way: a request joins it.
    var attemptUnderWay = false
    private(set) var asked = 0
    private var connected = false
    private var callers: [UUID: CheckedContinuation<(any BrowserBridge)?, Never>] = [:]

    /// Callers still waiting for a bridge.
    var waiting: Int { callers.count }

    /// Whether the link stands for the agent's own Chrome (ITER-076 stage 4b): what the quit closes.
    var owns = false
    var ownsBrowser: Bool { owns }
    /// Each time the service closed the agent's own browser, dropped the connection, or forgot the own browser — its
    /// window closed and its profile deleted (ITER-076 stage 8b).
    private(set) var closes = 0
    private(set) var disconnects = 0
    private(set) var forgets = 0

    func closeOwnBrowser() async { closes += 1 }

    func disconnect() { disconnects += 1 }

    func forgetOwnBrowser() async { forgets += 1 }

    func errandBridge() async -> (any BrowserBridge)? {
        asked += 1
        if connected { return bridge }
        if callers.isEmpty, !attemptUnderWay { state = .connecting }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { callers[token] = $0 }
        } onCancel: {
            Task { @MainActor in self.callers.removeValue(forKey: token)?.resume(returning: nil) }
        }
    }

    func connect() {
        connected = true
        attemptUnderWay = false
        state = .connected(browser: "Google Chrome")
        answerEveryone(bridge)
    }

    /// The callers waiting now get no bridge; `state` says why.
    func fail(_ state: ChromeLink.State) {
        connected = false
        attemptUnderWay = false
        self.state = state
        answerEveryone(nil)
    }

    private func answerEveryone(_ bridge: (any BrowserBridge)?) {
        let waiting = callers.values
        callers = [:]
        for caller in waiting { caller.resume(returning: bridge) }
    }
}

/// The runs never touch a page here. It keeps the tabs it was asked to
/// bring forward (ITER-076 stage 3).
@MainActor
final class FakeErrandBridge: BrowserBridge {
    private(set) var shown: [BrowserTab] = []

    func openTab(_ url: URL) async throws -> BrowserTab { throw BrowserBridgeError.tabNotFound }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { false }
    func run(_ javascript: String, in tab: BrowserTab) async throws -> String { "" }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String { #"{"stable":true}"# }
    func closeTab(_ tab: BrowserTab) async throws {}
    func show(_ tab: BrowserTab) async { shown.append(tab) }
}

/// A run the test drives: it reports, asks and ends when the test says. Like
/// `AgentRun`, Stop makes it return `.stopped` — at once, or, with
/// `returnsOnStop` off, once the test finishes it, as a run that still checks
/// an action it had sent.
@MainActor
final class FakeErrandRunner: ErrandRunner {
    let setup: ErrandSetup
    var record: ErrandRecord
    /// The run cancels the task it runs in, then returns as failed — a run
    /// cut short by its task.
    var cancelsItsTask = false
    var returnsOnStop = true
    private(set) var stops = 0
    private(set) var isRunning = false
    private var report: (@MainActor (ErrandProgress) -> Void)?
    private var ending: CheckedContinuation<ErrandOutcome, Never>?

    init(setup: ErrandSetup) {
        self.setup = setup
        record = ErrandRecord(errandID: setup.id, goal: setup.goal)
    }

    func run(report: @escaping @MainActor (ErrandProgress) -> Void) async -> ErrandOutcome {
        if cancelsItsTask {
            withUnsafeCurrentTask { $0?.cancel() }
            return ErrandOutcome(ending: .failed, answer: nil, sources: [], sheet: nil, rows: 0)
        }
        self.report = report
        isRunning = true
        let outcome = await withCheckedContinuation { ending = $0 }
        isRunning = false
        return outcome
    }

    func stop() {
        stops += 1
        guard returnsOnStop else { return }
        finish(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: record.rows.count))
    }

    func say(_ progress: ErrandProgress) { report?(progress) }

    /// Rows the run has collected so far.
    func collect(_ count: Int) {
        record.rows = (1...count).map { Scratchpad.Row(cells: ["Site \($0)"], source: URL(string: "https://site-\($0).test/")!) }
    }

    func finish(_ outcome: ErrandOutcome) {
        ending?.resume(returning: outcome)
        ending = nil
    }

    /// Asks the user through the service, in the background.
    func ask(_ request: ConfirmationRequest) -> AskedQuestion {
        let asked = AskedQuestion()
        let confirm = setup.confirm
        asked.task = Task { asked.answered(await confirm(request)) }
        return asked
    }
}

extension FakeErrandRunner {
    /// Waits for the user through the service, in the background (ITER-076
    /// stage 3).
    func pause(_ handover: ErrandHandover, in tab: BrowserTab, window: Duration) -> AskedPause {
        let asked = AskedPause()
        let wait = setup.waitForUser
        asked.task = Task { asked.answered(await wait(handover, tab, window)) }
        return asked
    }
}

/// A pause a run made, and whether the user said Continue — read once
/// `isAnswered`.
@MainActor
final class AskedPause {
    private(set) var isAnswered = false
    private(set) var continued = false
    fileprivate var task: Task<Void, Never>?

    fileprivate func answered(_ continued: Bool) {
        self.continued = continued
        isAnswered = true
    }

    /// The run gives up on its pause, as `AgentRun` does at its window.
    func giveUp() { task?.cancel() }
}

/// A question a run asked, and what came back — read once `isAnswered`, so a
/// question that never closes fails its test instead of hanging the suite.
@MainActor
final class AskedQuestion {
    private(set) var isAnswered = false
    private(set) var answer: ConfirmationRequest.Answer?
    fileprivate var task: Task<Void, Never>?

    fileprivate func answered(_ answer: ConfirmationRequest.Answer?) {
        self.answer = answer
        isAnswered = true
    }

    /// The run gives up on its question, as `AgentRun` does at its deadline.
    func giveUp() { task?.cancel() }
}

/// An `AgentService` on fakes: a link the test connects, runs the test drives,
/// a clock the test moves, timers the test fires, a keep-awake that counts, a
/// record folder and a notification center of its own.
@MainActor
final class AgentServiceHarness {
    let link = FakeErrandLink()
    let center = NotificationCenter()
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("mw-agent-service-\(UUID().uuidString)", isDirectory: true)
    var pro = true
    /// Settings → Agent, as the services read it (ITER-076 stage 8b): the agent on, the user's Allow given — so an
    /// errand runs at once unless a test says otherwise — and the browser errands use. Never the host's settings.
    var agentOn = true
    var allowed = true
    var way = AgentBrowser.ownWindow
    /// How many times a service kept the user's Allow.
    private(set) var allows = 0
    var now = ContinuousClock.now
    /// The runs made from now on cancel their own task.
    var runsCancelTheirTask = false
    private(set) var runners: [FakeErrandRunner] = []
    private(set) var timers: [(delay: Duration, action: @MainActor () -> Void)] = []
    private(set) var assertionsMade = 0
    private(set) var assertionsReleased: [IOPMAssertionID] = []
    private(set) var updates: [ErrandUpdate] = []
    /// What the services said in the log (ITER-076 I-06a).
    let logged = LogLines()
    private var watch: AnyCancellable?
    private var services: [AgentService] = []

    /// Settings → Agent as the harness holds it.
    var settings: AgentSettings {
        AgentSettings(isOn: { [weak self] in self?.agentOn ?? false },
                      isAllowed: { [weak self] in self?.allowed ?? false },
                      allow: { [weak self] in
                          self?.allowed = true
                          self?.allows += 1
                      },
                      way: { [weak self] in self?.way ?? .ownWindow })
    }

    /// A service with a run factory, unless `withRunner` is false; `store`
    /// replaces the one in `folder`, and `link` the fake one; `reporter`
    /// reports its failed errands (ITER-076 I-06b), none without it;
    /// `usersLink`: the user's own Chrome's link, when the test tells the two
    /// ways apart (ITER-076 stage 8b) — `link` serves both without it;
    /// `settings` replaces the harness's own (U1: gated by the Ultra switch).
    /// Its errands are stopped at `cleanUp`, so none goes on after the test.
    func makeService(withRunner: Bool = true, store: ErrandRecordStore? = nil,
                     link: BrowserLink? = nil, reporter: ErrandReporter? = nil,
                     usersLink: BrowserLink? = nil, settings: AgentSettings? = nil) -> AgentService {
        let makeRunner: ErrandRunnerFactory = { [weak self] setup in
            let runner = FakeErrandRunner(setup: setup)
            runner.cancelsItsTask = self?.runsCancelTheirTask ?? false
            self?.runners.append(runner)
            return runner
        }
        let keepAwake = KeepAwake(create: { [weak self] in
            guard let self else { return nil }
            assertionsMade += 1
            return IOPMAssertionID(assertionsMade)
        }, release: { [weak self] in self?.assertionsReleased.append($0) })
        let service = AgentService(link: link ?? self.link, keepAwake: keepAwake,
                                   store: store ?? ErrandRecordStore(directory: folder),
                                   notificationCenter: center, isPro: { [weak self] in self?.pro ?? false },
                                   makeRunner: withRunner ? makeRunner : nil, now: { [weak self] in self?.now ?? .now },
                                   schedule: { [weak self] delay, action in self?.timers.append((delay, action)) },
                                   log: logged.sink, reporter: reporter, settings: settings ?? self.settings,
                                   usersLink: usersLink)
        watch = service.events.sink { [weak self] in self?.updates.append($0) }
        services.append(service)
        return service
    }

    func events(of id: UUID) -> [ErrandEvent] {
        updates.filter { $0.id == id }.map(\.event)
    }

    /// What the service saved for an errand.
    func saved(_ id: UUID) -> ErrandRecordStore.Saved? {
        let file = ErrandRecordStore(directory: folder).fileURL(for: id)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ErrandRecordStore.Saved.self, from: data)
    }

    /// Whether an assertion is held: made and not released.
    var keepsAwake: Bool { assertionsMade > assertionsReleased.count }

    /// The lid closes: the system says the Mac is going to sleep.
    func macWillSleep() {
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
    }

    func macDidWake() {
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// The first timer still set for `delay` goes off, as if its time had
    /// passed; the others stay set.
    func fireFirstTimer(after delay: Duration, file: StaticString = #filePath, line: UInt = #line) {
        guard let index = timers.firstIndex(where: { $0.delay == delay }) else {
            return XCTFail("no timer set for \(delay)", file: file, line: line)
        }
        timers.remove(at: index).action()
    }


    /// Lets the main actor run until `condition` holds; fails after `limit`.
    func until(_ condition: () -> Bool, _ what: String, limit: Duration = .seconds(2),
               file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Lets the main actor run until errand `id` has shown `event`; fails
    /// after `limit`, saying what it showed. Where the link stands once an
    /// errand has its run is shown by a job the service queues, which may
    /// come after the run started: a test that reads that event — or
    /// `latest`, which it sets — waits for it here, never for the run alone.
    func until(_ id: UUID, shows event: ErrandEvent, limit: Duration = .seconds(2),
               file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + limit
        while !events(of: id).contains(event) {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for the errand to show \(event); it showed \(events(of: id))",
                        file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// The harness lets go of the runs it saw made.
    func forgetRuns() {
        runners = []
    }

    /// The errand's run, once the service made it and it is running.
    func runner(for id: UUID, file: StaticString = #filePath, line: UInt = #line) async -> FakeErrandRunner? {
        await until({ runners.contains { $0.setup.id == id && $0.isRunning } }, "the run of \(id)", file: file, line: line)
        return runners.first { $0.setup.id == id }
    }

    func cleanUp() {
        for service in services { service.stopAll() }
        try? FileManager.default.removeItem(at: folder)
    }
}

extension AgentSettings {
    /// For a test's own service: the agent on, the user's Allow given, MetaWhisp's own window — never the host's
    /// settings (ITER-076 stage 8b).
    static let allowedForTests = AgentSettings(isOn: { true }, isAllowed: { true }, allow: {}, way: { .ownWindow })
}

extension ErrandAdmission {
    /// The id of a started or queued errand.
    var id: UUID? {
        switch self {
        case .started(let id), .queued(let id, _): id
        case .refused: nil
        }
    }
}
