import AppKit
import Foundation

/// Which browser the agent uses (ITER-076 stage 4b, owner 2026-10-06): the `agentBrowser` setting.
enum AgentBrowser: String, CaseIterable {
    /// The agent's own Chrome window, on a profile of its own: nothing to set up, and none of the user's tabs,
    /// history or sign-ins. The default.
    case ownWindow
    /// The user's own Chrome: remote debugging ticked at `chrome://inspect/#remote-debugging`, each connection
    /// Allowed by the user.
    case usersChrome

    /// The setting's value; one the app does not know is the default.
    init(setting: String) {
        self = AgentBrowser(rawValue: setting) ?? .ownWindow
    }
}

/// The agent's own Google Chrome (ITER-076 stage 4b): the app starts it on a profile of its own, with its DevTools
/// port open from the start — no tick at `chrome://inspect`, no Allow — in a window the user sees, through
/// LaunchServices as an app of its own. It stays open between errands, so its sign-ins stay, and a launch after a
/// crash finds it still running; the app's quit closes it (`ChromeLink.closeOwnBrowser`). The live bench's launcher
/// (stage 3C), moved here: the bench starts it too.
@MainActor
final class AgentChrome {
    nonisolated static let bundleID = "com.google.Chrome"
    /// How long a start waits for the port it opened: the bench's 30 s.
    nonisolated static let startLimit: Duration = .seconds(30)

    enum StartFailure: Error, Equatable {
        /// No Google Chrome on this Mac.
        case notInstalled
        /// Chrome did not open its port in time, or it ended first.
        case noPort
    }

    /// The app's folder for it, in its support folder.
    nonisolated static var appRoot: URL {
        AppIdentity.current.supportDirectory.appendingPathComponent("AgentBrowser", isDirectory: true)
    }

    /// Deletes its profile — the history and sign-ins of every errand
    /// (ITER-076 stage 8b, 8.12) — and nothing else: the one folder it gives
    /// Chrome as `--user-data-dir`. A profile that is, or holds, one of the
    /// user's own browser profiles or their whole Application Support — a
    /// root that is the user's Application Support, or a link into it —
    /// deletes nothing. Says what happened in the log, by kind alone.
    func deleteProfile() {
        let resolved = { (url: URL) in url.standardizedFileURL.resolvingSymlinksInPath().path }
        let target = resolved(profile)
        if let users = usersApplicationSupport {
            let theirs = [resolved(users)]
                + DevToolsPortLocator.profiles.map { resolved(users.appendingPathComponent($0.folder, isDirectory: true)) }
            if theirs.contains(where: { $0 == target || $0.hasPrefix(target + "/") }) {
                NSLog("[AgentChrome] profile not deleted: it is the user's own")
                return
            }
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: profile.path) else { return }
        do {
            try fm.removeItem(at: profile)
            NSLog("[AgentChrome] profile deleted")
        } catch {
            NSLog("[AgentChrome] ❌ profile not deleted — error %d", (error as NSError).code)
        }
    }

    /// How the app starts Chrome.
    enum Launch: Equatable {
        /// LaunchServices opens Chrome's app as an app of its own (`configuration`), so macOS counts Chrome — not
        /// MetaWhisp — as responsible for its microphone, camera and screen permissions. The app's way.
        case launchServices
        /// Tests: Chrome's program as a child process of the test run — headless, it shows nothing on screen, not
        /// even in the Dock.
        case childProcess
    }

    /// An Application Support folder in the shape `ChromeLink` reads: `Google/Chrome` in it is the profile.
    let root: URL
    let launch: Launch
    /// The user's own Application Support, which holds their browsers'
    /// profiles: never deleted (stage 8b).
    private let usersApplicationSupport: URL?
    private let headless: Bool
    private let endsWith: pid_t?
    private let startLimit: Duration
    private let application: () -> URL?
    /// The Chrome this app started last.
    private(set) var started: (any StartedChrome)?
    private var startedAt = Date.distantPast
    /// From asking LaunchServices until its answer: a second start meanwhile waits for this one.
    private var opening = false
    /// How many times this app started it.
    private(set) var launches = 0

    /// `headless`, `launch` and `endsWith` are for tests: a Chrome nothing of which shows on screen, started as a
    /// child process, and one that ends with the test run that started it. `application`: Google Chrome's app; nil
    /// when there is none. `usersApplicationSupport`: the user's own, for tests a folder of their own.
    init(root: URL = AgentChrome.appRoot, headless: Bool = false, launch: Launch = .launchServices,
         endsWith run: pid_t? = nil, startLimit: Duration = AgentChrome.startLimit,
         application: @escaping () -> URL? = AgentChrome.installed,
         usersApplicationSupport: URL? = DevToolsPortLocator.userApplicationSupport) {
        self.root = root
        self.launch = launch
        self.usersApplicationSupport = usersApplicationSupport
        self.headless = headless
        endsWith = run
        self.startLimit = startLimit
        self.application = application
    }

    var profile: URL { root.appendingPathComponent("Google/Chrome", isDirectory: true) }

    /// Its own profile, a DevTools port of Chrome's choosing, no first-run screens. Headless, Chrome says it is
    /// Chrome of its own version, as a window of it does: "HeadlessChrome" in the agent string is what sites that
    /// keep automation out read first (2026-10-19), and the bench stands for the app's own window.
    var arguments: [String] {
        (headless ? ["--headless=new"] + userAgentSwitch : [])
            + ["--remote-debugging-port=0", "--user-data-dir=\(profile.path)", "--no-first-run",
               "--no-default-browser-check", "about:blank"]
    }

    /// The agent string a window of this Chrome sends, by the major version its app's Info.plist gives; none when
    /// no version is known, and Chrome's own string stands.
    private var userAgentSwitch: [String] {
        guard let app = application(), let major = Self.majorVersion(of: app) else { return [] }
        return ["--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Chrome/\(major).0.0.0 Safari/537.36"]
    }

    /// The major version of the app at `url`, from its Info.plist.
    nonisolated static func majorVersion(of url: URL) -> Int? {
        let info = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String else { return nil }
        return version.split(separator: ".").first.flatMap { Int($0) }
    }

    /// Google Chrome's app on this Mac, found by its bundle id.
    nonisolated static func installed() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// What LaunchServices is asked: Chrome's switches, a new instance beside the user's own Chrome, opened without
    /// taking the user's focus — Show tab brings it forward — and kept out of the recent items.
    nonisolated static func configuration(arguments: [String]) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.addsToRecentItems = false
        return configuration
    }

    /// Starts Chrome on the profile — unless the one this app started still runs, or is being started — and waits,
    /// `startLimit` at most, for the port that start opened: a port file written after it. Throws `StartFailure`, or
    /// `CancellationError` when the caller stops: the Chrome started goes on starting, for the next errand.
    @discardableResult
    func start() async throws -> DevToolsEndpoint {
        let fm = FileManager.default
        if !opening, started?.isTerminated != false {
            guard let app = application() else { throw StartFailure.notInstalled }
            if !fm.fileExists(atPath: profile.path) {
                try fm.createDirectory(at: profile, withIntermediateDirectories: true)
            }
            startedAt = Date()
            opening = true
            defer { opening = false }
            let chrome = try await open(app)
            started = chrome
            launches += 1
            if let endsWith { Self.end(chrome.processIdentifier, with: endsWith) }
        }
        let file = profile.appendingPathComponent("DevToolsActivePort")
        let deadline = ContinuousClock.now + startLimit
        while ContinuousClock.now < deadline, opening || started?.isTerminated == false {
            if let written = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
               written >= startedAt.addingTimeInterval(-1),
               let text = try? String(contentsOf: file, encoding: .utf8),
               let parsed = DevToolsPortLocator.parse(activePort: text) {
                return DevToolsEndpoint(browser: "Google Chrome", port: parsed.port, path: parsed.path)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw StartFailure.noPort
    }

    /// Chrome's app, started the way `launch` says.
    private func open(_ app: URL) async throws -> any StartedChrome {
        switch launch {
        case .launchServices:
            return try await NSWorkspace.shared.openApplication(at: app,
                                                                configuration: Self.configuration(arguments: arguments))
        case .childProcess:
            guard let program = Bundle(url: app)?.executableURL,
                  FileManager.default.isExecutableFile(atPath: program.path) else { throw StartFailure.notInstalled }
            let process = Process()
            process.executableURL = program
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
    }

    /// A Chrome a test started ends with the test run: a watcher outside the run — it outlives a run that is killed
    /// — ends it once the run is gone, and ends by itself when Chrome does. It never touches the profile.
    private static func end(_ chrome: pid_t, with run: pid_t) {
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        watcher.arguments = ["-c", "while kill -0 \(run) 2>/dev/null; do kill -0 \(chrome) 2>/dev/null || exit 0; "
                             + "sleep 1; done; kill \(chrome) 2>/dev/null"]
        watcher.standardOutput = FileHandle.nullDevice
        watcher.standardError = FileHandle.nullDevice
        try? watcher.run()
    }
}

/// A Chrome the app started, as the app tracks it: LaunchServices' running app — or, in tests, a child process.
@MainActor
protocol StartedChrome: AnyObject {
    var processIdentifier: pid_t { get }
    var isTerminated: Bool { get }
}

extension NSRunningApplication: StartedChrome {}

extension Process: StartedChrome {
    var isTerminated: Bool { !isRunning }
}
