import AppKit
import Foundation

/// The agent's one live connection to a browser (ITER-076 3.1), ported from
/// browser-harness (`admin.py` `ensure_daemon` and `daemon.py`, MIT © Browser
/// Use). The browser comes one of two ways — the `agentBrowser` setting, one
/// link for each, the errand service choosing as each errand begins (stage
/// 4b, 8b):
/// - the agent's own Chrome window, the default: a Google Chrome the app
///   starts itself on a profile of its own (`AgentChrome`), its DevTools port
///   open from the start — nothing to tick, nothing to Allow. The link looks
///   in that profile alone, never in the user's, so the agent never sees the
///   user's tabs, history or sign-ins; it starts that Chrome when none runs
///   there, keeps it open between errands, and the app's quit closes it.
///   It ends no way but Chrome not installed, or its own failure;
/// - the user's own Chrome: a Google Chrome the user runs with "Allow remote
///   debugging for this browser instance" on at
///   `chrome://inspect/#remote-debugging` — Google Chrome's profile alone
///   (stage 8b, 8.8), no other browser's. It asks the user to Allow the
///   connection. The app never starts it, never clicks its Allow and never
///   closes it: all three are the user's.
///
/// Either way:
/// - one connection serves every errand, so a browser that asks the user to
///   Allow it asks once; it is kept while it is open — a browser slow to
///   answer is not replaced, since a new connection would ask the user
///   again — and only one attempt to open it runs at a time;
/// - a browser that answered and did not allow the connection — declined,
///   refused at once, or no answer in time — is not asked again on its own;
///   the next errand asks again. Only a port nothing answered on is passed
///   over, for the next browser or a later look.
@MainActor
final class ChromeLink: ObservableObject {
    enum State: Equatable {
        case idle
        /// Looking for a browser that answers.
        case connecting
        /// The user's own Chrome does not run on this Mac.
        case notRunning
        /// Google Chrome is not on this Mac, whichever way (stage 4b, 8b).
        case notInstalled
        /// MetaWhisp's own Chrome did not open its port in time, did not
        /// answer, or refused the connection (stage 8b, № 15): the app's own
        /// failure. The own way ends no other way but `notInstalled`.
        case didNotStart
        /// A browser runs, but none answers: "Allow remote debugging for this
        /// browser instance" is off at `chrome://inspect/#remote-debugging`.
        case remoteDebuggingOff
        /// The browser is asking the user to Allow this connection.
        case waitingForAllow(browser: String)
        case connected(browser: String)
        /// The user declined, or did not answer within the limit.
        case notAllowed
    }

    /// The app's link for `way`, with the app's list of the agent's tabs not
    /// known closed (stage 9d, № 21, № 23): the agent's own Chrome in the
    /// app's folder, or the user's own Chrome. Each keeps its own list: the
    /// app holds both links at once (stage 8b), and a list checked against
    /// the other browser would let go of the tabs it does not find there.
    static func app(_ way: AgentBrowser) -> ChromeLink {
        switch way {
        case .ownWindow:
            ChromeLink(tabs: AgentTabLedger(), own: AgentChrome())
        case .usersChrome:
            ChromeLink(tabs: AgentTabLedger(file: AppIdentity.current.supportDirectory
                .appendingPathComponent("AgentTabs-usersChrome.json")))
        }
    }

    /// How long the quit gives the agent's own Chrome to take its close.
    static let closeLimit: Duration = .seconds(2)

    @Published private(set) var state: State = .idle

    /// The agent's tabs not known closed: each bridge keeps it, and closes
    /// the ones left open as it is made. None in tests that do not ask.
    let tabs: AgentTabLedger?
    /// The agent's own Chrome, the way it is used (stage 4b); nil when it is
    /// the user's own Chrome.
    let own: AgentChrome?
    private let applicationSupport: URL?
    /// The folder the link reads: the agent's own Chrome's alone, or the
    /// user's Application Support.
    var folder: URL? { own?.root ?? applicationSupport }
    /// The browsers' profile folders the link reads in its folder, in order:
    /// Google Chrome's alone (stage 8b, 8.8).
    let profiles: [(browser: String, folder: String)]
    /// Google Chrome's app on this Mac; nil when there is none.
    private let application: () -> URL?
    private let settleLimit: Duration
    private let allowLimit: Duration
    private var connection: CDPConnection?
    /// The attempt under way, with its number: an attempt a newer one has
    /// superseded writes nothing — neither the state nor this.
    private var attempt: (number: Int, task: Task<CDPConnection?, Never>)?
    /// The number of the last attempt made.
    private var attempts = 0
    /// Callers waiting on the attempt.
    private var waiting = 0
    /// A cleared MetaChat's close and delete under way (stage 8b, 8.12): a
    /// new attempt waits for it, so no Chrome starts on a profile being
    /// deleted. Its number tells it from a later one.
    private var forgetting: Task<Void, Never>?
    private var forgets = 0

    /// `settleLimit`: how long a running browser gets to answer before its
    /// remote debugging counts as off — browser-harness's 3 s. `own`: the
    /// agent's own Chrome, read in place of the user's `applicationSupport`.
    /// `profiles`: Google Chrome's alone unless a test gives more.
    /// `application`: Google Chrome's app, as the user's way looks for it.
    init(applicationSupport: URL? = DevToolsPortLocator.userApplicationSupport,
         settleLimit: Duration = .seconds(3), allowLimit: Duration = .seconds(600), tabs: AgentTabLedger? = nil,
         own: AgentChrome? = nil, profiles: [(browser: String, folder: String)] = DevToolsPortLocator.googleChrome,
         application: @escaping () -> URL? = AgentChrome.installed) {
        self.applicationSupport = applicationSupport
        self.settleLimit = settleLimit
        self.allowLimit = allowLimit
        self.tabs = tabs
        self.own = own
        self.profiles = profiles
        self.application = application
    }

    /// The app quits (stage 4b): the agent's own Chrome closes, with any tab of
    /// the agent's still in it, over its own DevTools port — this session's,
    /// or one a crash left running. The user's own Chrome is never closed:
    /// without `own` this does nothing.
    func closeOwnBrowser() async {
        guard let root = own?.root else { return }
        for endpoint in DevToolsPortLocator.endpoints(applicationSupport: root, profiles: profiles) {
            let connection = CDPConnection(url: endpoint.webSocketURL)
            if (try? await connection.open(allowLimit: Self.closeLimit)) != nil {
                _ = try? await connection.send("Browser.close", timeout: Self.closeLimit)
            }
            await connection.close()
        }
    }

    /// How long a cleared MetaChat waits for the agent's own Chrome to end
    /// before its profile goes (stage 8b, 8.12).
    static let forgetLimit: Duration = .seconds(5)

    /// MetaChat was cleared (stage 8b, 8.12): the agent's own Chrome closes,
    /// and once it has ended — or `forgetLimit` is over — its profile, the
    /// history and sign-ins of every errand, is deleted (`AgentChrome`). The
    /// user's own Chrome is never touched: without `own` this does nothing.
    func forgetOwnBrowser() async {
        guard let own else { return }
        let forgetting = Task { @MainActor in
            await closeOwnBrowser()
            let deadline = ContinuousClock.now + Self.forgetLimit
            while Self.isRunning(profile: own.profile), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            own.deleteProfile()
        }
        forgets += 1
        let number = forgets
        self.forgetting = forgetting
        await forgetting.value
        if forgets == number { self.forgetting = nil }
    }

    /// The connection is closed (stage 8b): the agent was turned off, or its
    /// browser changed. The browser stays open — the user's own Chrome is
    /// never closed — and the next errand opens a connection of its own.
    func disconnect() {
        guard let connection else { return }
        self.connection = nil
        state = .idle
        Task { await connection.close() }
    }

    /// A bridge into the browser over the one connection; nil with `state`
    /// saying why. Its Show tab brings that browser forward
    /// (ITER-076 stage 3). The agent's tabs left open before — a crash, a
    /// sleep — are closed first (stage 9d, № 21, № 23).
    func bridge() async -> ChromeBridge? {
        guard let connection = await connect() else { return nil }
        let bridge = ChromeBridge(connection: connection, bringForward: { [weak self] in self?.bringBrowserForward() },
                                  tabs: tabs)
        await bridge.closeStrayTabs()
        return bridge
    }

    /// The connected browser's app in front of the user's (ITER-076 stage 3,
    /// Show tab): the process its profile's lock names (`holder(of:)`).
    private func bringBrowserForward() {
        guard case .connected(let browser) = state, let folder,
              let profile = profiles.first(where: { $0.browser == browser })?.folder,
              let pid = Self.holder(of: folder.appendingPathComponent(profile, isDirectory: true))
        else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// The live connection, opened if need be. Callers that come while an
    /// attempt runs share it. A caller that stops is back at once; when the
    /// last one stops, the attempt ends — and with it the browser's question
    /// to the user, which the waiting connection holds up (review of 3.1).
    func connect() async -> CDPConnection? {
        let current: Task<CDPConnection?, Never>
        // An attempt whose last caller stopped is cancelled and ending: a new
        // caller is never given its nil, and starts an attempt of its own
        // (review of ITER-076 B1, round 2).
        if let attempt, !attempt.task.isCancelled {
            current = attempt.task
        } else {
            attempts += 1
            let number = attempts
            // A new attempt with no connection to reuse says so at once, so a
            // caller never reads the last attempt's end as its own (review of
            // ITER-076 B1, S4).
            if connection == nil { state = .connecting }
            current = Task {
                let opened = await self.reuseOrOpen(attempt: number)
                if self.attempt?.number == number { self.attempt = nil }
                return opened
            }
            attempt = (number, current)
        }
        waiting += 1
        let result = await Deadline.run(within: allowLimit + .seconds(60)) { await current.value }
        waiting -= 1
        guard let result else {
            if waiting == 0, attempt?.task == current { current.cancel() }
            return nil
        }
        return result
    }

    // MARK: - Private

    private func reuseOrOpen(attempt number: Int) async -> CDPConnection? {
        if let connection, await connection.state == .open { return connection }
        guard isCurrent(number) else { return nil }
        connection = nil
        return await open(attempt: number)
    }

    private func isCurrent(_ number: Int) -> Bool { attempt?.number == number }

    /// Attempt `number` says where it stands, unless a newer attempt has
    /// superseded it.
    private func report(_ state: State, for number: Int) {
        guard isCurrent(number) else { return }
        self.state = state
    }

    private func open(attempt number: Int) async -> CDPConnection? {
        report(.connecting, for: number)
        if let forgetting { await forgetting.value }
        guard let folder else {
            report(.notRunning, for: number)
            return nil
        }
        var deadline = ContinuousClock.now + settleLimit
        var started = false
        // The agent's own Chrome asks no one and is set up by no one: every
        // end of it but Chrome not installed is the app's own failure (stage
        // 8b, № 15) — never "not running", "remote debugging off" or "not
        // allowed", the user's way's ends.
        let failed: State? = own == nil ? nil : .didNotStart
        while true {
            for endpoint in DevToolsPortLocator.endpoints(applicationSupport: folder, profiles: profiles) {
                let connection = CDPConnection(url: endpoint.webSocketURL)
                do {
                    try await connection.open(allowLimit: allowLimit) { [weak self] in
                        Task { @MainActor in
                            // The agent's own Chrome asks no one: slow to open is not "click Allow" (stage 4b).
                            guard let self, self.own == nil, self.state == .connecting else { return }
                            self.report(.waitingForAllow(browser: endpoint.browser), for: number)
                        }
                    }
                } catch CDPError.unreachable {
                    // Nothing answered: a port file a closed browser left behind.
                    continue
                } catch CDPError.cancelled {
                    report(.idle, for: number)
                    return nil
                } catch {
                    // The browser answered and did not allow it.
                    report(failed ?? .notAllowed, for: number)
                    return nil
                }
                // Superseded while the browser said yes: its callers are gone,
                // and the connection is not kept.
                guard isCurrent(number) else {
                    await connection.close()
                    return nil
                }
                self.connection = connection
                state = .connected(browser: endpoint.browser)
                watch(connection)
                return connection
            }
            let running = profiles.contains {
                Self.isRunning(profile: folder.appendingPathComponent($0.folder, isDirectory: true))
            }
            // Nothing answers on the agent's own profile and nothing holds it:
            // the app starts its Chrome — once an attempt — and looks again
            // once it has opened its port (stage 4b). A Chrome that holds the
            // profile is never started a second time.
            if !running, let own, !started {
                started = true
                do {
                    try await own.start()
                } catch is CancellationError {
                    report(.idle, for: number)
                    return nil
                } catch AgentChrome.StartFailure.notInstalled {
                    report(.notInstalled, for: number)
                    return nil
                } catch {
                    // It did not open its port in time, or it ended first.
                    report(.didNotStart, for: number)
                    return nil
                }
                deadline = ContinuousClock.now + settleLimit
                continue
            }
            guard running else {
                // The user's Chrome is not running — or not on this Mac at
                // all, either way (stage 8b, № 158): advice to open it would
                // be no use.
                report(failed ?? (application() == nil ? .notInstalled : .notRunning), for: number)
                return nil
            }
            guard ContinuousClock.now < deadline else {
                // The agent's own Chrome is not the user's to set up: it never
                // says remote debugging is off.
                report(failed ?? .remoteDebuggingOff, for: number)
                return nil
            }
            // A Stop ends the wait and the attempt with it (review of ITER-076
            // B1c, round 2): swallowed, it left the loop spinning to its limit.
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                report(.idle, for: number)
                return nil
            }
        }
    }

    /// When the connection ends — the browser quit, or the app closed it —
    /// the link is idle again.
    private func watch(_ connection: CDPConnection) {
        Task { [weak self] in
            for await _ in await connection.events() {}
            guard let self, self.connection === connection else { return }
            self.connection = nil
            if case .connected = self.state { self.state = .idle }
        }
    }

    /// Whether a browser holds the profile folder: its `SingletonLock` names
    /// the holder as `<host>-<pid>`, and that process is alive
    /// (browser-harness `daemon.py` 187-216).
    nonisolated static func isRunning(profile: URL) -> Bool {
        guard let pid = holder(of: profile) else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The process the profile folder's `SingletonLock` names as its holder.
    nonisolated static func holder(of profile: URL) -> pid_t? {
        let lock = profile.appendingPathComponent("SingletonLock").path
        guard let holder = try? FileManager.default.destinationOfSymbolicLink(atPath: lock),
              let pid = holder.split(separator: "-").last.flatMap({ pid_t($0) }), pid > 0 else { return nil }
        return pid
    }
}
