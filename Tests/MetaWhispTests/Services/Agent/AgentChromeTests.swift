import AppKit
import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 4b — the agent's own Chrome window by default (owner, 2026-10-06): MetaWhisp starts Google Chrome
/// on a profile of its own, its DevTools port open from the start — no tick at chrome://inspect, no Allow — and the
/// user's own Chrome stays the other way. On folders of the test's own; nothing here starts a browser: a stand-in
/// app that shows nothing takes Chrome's place, and a held port a browser's.
@MainActor
final class AgentChromeTests: XCTestCase {

    // MARK: - The setting

    /// The own window is the default, and a value the app does not know is the default too.
    func testTheOwnWindowIsTheDefault() {
        UserDefaults.standard.removeObject(forKey: "agentBrowser")
        XCTAssertEqual(AgentBrowser(setting: AppSettings.shared.agentBrowser), .ownWindow)
        XCTAssertEqual(AgentBrowser(setting: "usersChrome"), .usersChrome)
        XCTAssertEqual(AgentBrowser(setting: "safari"), .ownWindow, "an unknown value is the default")
    }

    /// The app's link takes the way the setting names: its own Chrome in a folder of the app's — never the user's
    /// Application Support — or the user's own Chrome, as before.
    func testTheAppsLinkTakesTheWayTheSettingNames() {
        let own = ChromeLink.app(.ownWindow)
        let root = AppIdentity.current.supportDirectory.appendingPathComponent("AgentBrowser", isDirectory: true)
        XCTAssertEqual(own.own?.root, root)
        XCTAssertEqual(own.folder, root, "it reads its own folder alone")
        XCTAssertEqual(own.own?.profile, root.appendingPathComponent("Google/Chrome", isDirectory: true),
                       "the shape the link reads")
        let users = ChromeLink.app(.usersChrome)
        XCTAssertNil(users.own)
        XCTAssertEqual(users.folder, DevToolsPortLocator.userApplicationSupport, "the user's own Chrome, as before")
        // Stage 8b: the app holds both links, the service choosing as each errand begins — each with its own list of
        // the agent's tabs, so one browser's tabs are never looked for in the other — and Google Chrome alone (8.8).
        XCTAssertEqual(own.tabs?.file, AgentTabLedger().file)
        XCTAssertNotEqual(users.tabs?.file, own.tabs?.file)
        XCTAssertEqual(own.profiles.map(\.browser), ["Google Chrome"])
        XCTAssertEqual(users.profiles.map(\.browser), ["Google Chrome"])
    }

    // MARK: - How the app starts it

    /// In a window the user sees, on its own profile, with a DevTools port of its own choosing and no first-run
    /// screens. Headless only for tests — the test switch — so nothing of a test's Chrome shows on screen.
    func testTheAppStartsItsChromeInAWindowOnItsOwnProfileWithItsPortOpen() throws {
        let root = try folder("own")
        XCTAssertEqual(AgentChrome(root: root).arguments,
                       ["--remote-debugging-port=0", "--user-data-dir=\(root.appendingPathComponent("Google/Chrome").path)",
                        "--no-first-run", "--no-default-browser-check", "about:blank"])
        XCTAssertEqual(AgentChrome(root: root, headless: true, application: { nil }).arguments,
                       ["--headless=new"] + AgentChrome(root: root).arguments, "no Chrome known: its own agent string")
        XCTAssertEqual(AgentChrome.bundleID, "com.google.Chrome", "found by its bundle id")
    }

    /// Headless, Chrome says it is Chrome of its own version, as a window of it does — never "HeadlessChrome",
    /// which sites that keep automation out read first (2026-10-19). The version is its app's.
    func testAHeadlessChromeSaysItIsChromeOfItsVersion() throws {
        let app = try standIn(seconds: 0, version: "155.0.8059.84")
        XCTAssertEqual(AgentChrome.majorVersion(of: app), 155)
        let headless = AgentChrome(root: try folder("own"), headless: true, application: { app }).arguments
        XCTAssertEqual(headless.first, "--headless=new")
        XCTAssertEqual(headless.dropFirst().first,
                       "--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
                       + "Chrome/155.0.0.0 Safari/537.36")
        XCTAssertFalse(AgentChrome(root: try folder("own"), application: { app }).arguments.contains { $0.hasPrefix("--user-agent") },
                       "a window of Chrome sends its own")
        XCTAssertNil(AgentChrome.majorVersion(of: try standIn(seconds: 0)), "a version-less app names none")
    }

    /// The app starts its Chrome through LaunchServices, as an app of its own — never as its child process, so
    /// macOS counts Chrome, not MetaWhisp, as responsible for its microphone, camera and screen permissions: a new
    /// instance beside the user's own Chrome, opened without taking the user's focus (Show tab brings it forward),
    /// kept out of the recent items, with Chrome's switches. A hidden stand-in app takes Chrome's place: nothing
    /// shows on screen.
    func testTheAppStartsItsChromeThroughLaunchServicesAsAnAppOfItsOwn() async throws {
        let root = try folder("own")
        XCTAssertEqual(AgentChrome(root: root).launch, .launchServices, "the app's launcher")
        XCTAssertEqual(ChromeLink.app(.ownWindow).own?.launch, .launchServices)
        let switches = AgentChrome(root: root).arguments
        let configuration = AgentChrome.configuration(arguments: switches)
        XCTAssertEqual(configuration.arguments, switches)
        XCTAssertTrue(configuration.createsNewApplicationInstance, "a new instance beside the user's own Chrome")
        XCTAssertFalse(configuration.activates, "it does not take the user's focus")
        XCTAssertFalse(configuration.addsToRecentItems)

        // A stand-in no app checks in for: LaunchServices answers once it has ended, a second later. It notes its
        // parent and its switches.
        let notes = try folder("notes")
        let app = try standIn(seconds: 1, noting: notes)
        let own = AgentChrome(root: root, startLimit: .milliseconds(1_500), application: { app })
        await XCTAssertStartFails(own, with: .noPort, "the stand-in opens no port")
        let started = try XCTUnwrap(own.started)
        XCTAssertTrue(started is NSRunningApplication, "tracked as LaunchServices' running app")
        let parent = try String(contentsOf: notes.appendingPathComponent("parent"), encoding: .utf8)
        XCTAssertNotEqual(parent, "\(getpid())\n", "an app of its own, not the app's child")
        XCTAssertEqual(try String(contentsOf: notes.appendingPathComponent("arguments"), encoding: .utf8),
                       switches.joined(separator: "\n") + "\n", "Chrome's switches reach it")
        XCTAssertEqual(own.launches, 1)
    }

    /// LaunchServices answers a moment after it is asked: a second start in that moment — a Stop while Chrome
    /// starts, and the next errand right after — waits for the start under way and starts no second Chrome.
    func testTwoStartsAtOnceStartOneChrome() async throws {
        let app = try standIn(seconds: 1)
        let own = AgentChrome(root: try folder("own"), startLimit: .milliseconds(1_500), application: { app })
        async let first: Void = XCTAssertStartFails(own, with: .noPort)
        async let second: Void = XCTAssertStartFails(own, with: .noPort)
        _ = await (first, second)
        XCTAssertEqual(own.launches, 1, "one Chrome per profile")
    }

    /// One Chrome on the own profile: while the one the app started still runs — its port not open yet — a second
    /// start waits for it and starts none. Once it has ended, the next start starts one again.
    func testAChromeTheAppStartedIsNotStartedAgainWhileItRunsAndIsOnceItEnded() async throws {
        let app = try standIn(seconds: 30)
        let own = AgentChrome(root: try folder("own"), launch: .childProcess, endsWith: getpid(),
                              startLimit: .milliseconds(300), application: { app })
        addTeardownBlock { @MainActor in
            if let started = own.started { kill(started.processIdentifier, SIGTERM) }
        }
        await XCTAssertStartFails(own, with: .noPort, "the stand-in opens no port")
        XCTAssertEqual(own.launches, 1)
        let first = try XCTUnwrap(own.started)
        XCTAssertFalse(first.isTerminated, "the premise: it still runs")
        await XCTAssertStartFails(own, with: .noPort)
        XCTAssertEqual(own.launches, 1, "no second start while it runs")

        kill(first.processIdentifier, SIGTERM)
        let deadline = ContinuousClock.now + .seconds(5)
        while !first.isTerminated, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        await XCTAssertStartFails(own, with: .noPort)
        XCTAssertEqual(own.launches, 2, "started again once it ended")
    }

    /// A running own Chrome whose port does not answer is not started a second time on its profile, and it is not
    /// the user's to set up: it never says remote debugging is off. A profile no live process holds — a lock a
    /// crash left — is started.
    func testARunningOwnChromeThatDoesNotAnswerIsNotStartedAgainAndALeftLockIsStarted() async throws {
        let app = try standIn(seconds: 0)
        let held = try folder("held")
        try lock(profile(in: held), by: getpid())
        let own = AgentChrome(root: held, launch: .childProcess, application: { app })
        let link = ChromeLink(applicationSupport: try folder("user"), settleLimit: .milliseconds(300), own: own)
        let connection = await link.connect()
        XCTAssertNil(connection)
        XCTAssertEqual(link.state, .didNotStart,
                       "its own failure (stage 8b), never remote debugging off: the own Chrome is not the user's to set up")
        XCTAssertEqual(own.launches, 0, "no second Chrome on a profile a live one holds")

        let left = try folder("left")
        try lock(profile(in: left), by: 999_999)
        let started = AgentChrome(root: left, launch: .childProcess, application: { app })
        _ = await ChromeLink(applicationSupport: try folder("user"), settleLimit: .milliseconds(300), own: started)
            .connect()
        XCTAssertEqual(started.launches, 1, "a lock no live process holds: the app starts its Chrome")
    }

    /// The own Chrome never asks for Allow: a connection slow to open says connecting, never "click Allow".
    func testTheOwnWayNeverSaysWaitingForAllow() async throws {
        let port = try await HeldPort.start()
        defer { port.stop() }
        let root = try folder("own")
        try portFile(port.port, in: profile(in: root))
        try lock(profile(in: root), by: getpid())
        let link = ChromeLink(applicationSupport: try folder("user"), allowLimit: .seconds(10),
                              own: AgentChrome(root: root, application: { nil }))
        let pending = Task { await link.connect() }
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(port.connections, 1, "the own Chrome's port, held")
        XCTAssertEqual(link.state, .connecting, "never waiting for Allow")
        pending.cancel()
        _ = await pending.value
    }

    // MARK: - Chrome not installed, and the user's Chrome never read

    /// Chrome not installed: the errand does not run and ends as no browser running — the approved line — which is
    /// no failure: nothing is reported (stage 8a). The user's own Chrome, running with remote debugging on, is not
    /// taken instead: in the own way the user's profile folders are never read.
    func testChromeNotInstalledEndsTheErrandNotRunUnreportedAndTheUsersChromeIsNotTaken() async throws {
        let users = try await HeldPort.start(speaking: true)
        defer { users.stop() }
        let user = try folder("user")
        try portFile(users.port, in: profile(in: user))
        try lock(profile(in: user), by: getpid())
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let sent = Sent()
        let reporter = ErrandReporter(client: ProLLMClient(licenseKey: { "LICENSE-1" }, send: { try await sent.respond($0) },
                                                           log: { _ in }),
                                      directory: h.folder.appendingPathComponent("Reports"), appVersion: "0")
        let own = AgentChrome(root: try folder("own"), application: { nil })
        let service = h.makeService(link: ChromeLink(applicationSupport: user, own: own), reporter: reporter)
        let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        await h.until({ !service.errandRunning }, "the errand's end")
        // Not "not running": a Mac without Chrome is told so (the owner's line of 2026-10-06, item 20).
        let notRun = ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0,
                                   notRun: .browserNotInstalled)
        XCTAssertEqual(h.events(of: id), [.connecting(.connecting), .connecting(.notInstalled), .finished(notRun)])
        XCTAssertEqual(h.saved(id)?.outcome, notRun)
        await reporter.sendWaiting()
        XCTAssertTrue(reporter.waiting.isEmpty, "no report")
        XCTAssertEqual(sent.count, 0, "nothing sent")
        XCTAssertEqual(users.connections, 0, "the user's own Chrome is never read in the own way")
        XCTAssertTrue(h.runners.isEmpty, "no run")
    }

    // MARK: - The link's ends, each way (stage 8b, № 158, 15)

    /// MetaWhisp's own Chrome is set up by no one and asks no one: no port in time, no answer, or a refused
    /// connection is its own failure — never "not running", "remote debugging off" or "not allowed", the user's
    /// way's ends.
    func testEveryFailureOfTheOwnChromeIsItsOwnAndNeverTheUsersLines() async throws {
        // No port in time: a Chrome that opens none.
        let app = try standIn(seconds: 30)
        let silent = AgentChrome(root: try folder("silent"), launch: .childProcess, endsWith: getpid(),
                                 startLimit: .milliseconds(300), application: { app })
        addTeardownBlock { @MainActor in
            if let started = silent.started { kill(started.processIdentifier, SIGTERM) }
        }
        let noPort = ChromeLink(applicationSupport: try folder("user"), settleLimit: .milliseconds(300), own: silent)
        _ = await noPort.connect()
        XCTAssertEqual(noPort.state, .didNotStart, "no port in time")

        // Running, no answer: its profile held, no port.
        let held = try folder("held")
        try lock(profile(in: held), by: getpid())
        let quiet = ChromeLink(applicationSupport: try folder("user"), settleLimit: .milliseconds(300),
                               own: AgentChrome(root: held, application: { nil }))
        _ = await quiet.connect()
        XCTAssertEqual(quiet.state, .didNotStart, "no answer")

        // A refused connection.
        let refusing = try await HeldPort.start(answering: "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        defer { refusing.stop() }
        let root = try folder("refusing")
        try portFile(refusing.port, in: profile(in: root))
        try lock(profile(in: root), by: getpid())
        let refused = ChromeLink(applicationSupport: try folder("user"), settleLimit: .seconds(3),
                                 own: AgentChrome(root: root, application: { nil }))
        _ = await refused.connect()
        XCTAssertEqual(refused.state, .didNotStart, "a refused connection")
        XCTAssertEqual(refusing.connections, 1)
    }

    /// The errand that MetaWhisp's own Chrome did not let in fails — MetaChat's approved "The errand failed." — and
    /// is reported once, as the app's own failure.
    func testAnErrandTheOwnChromeDidNotLetInFailsAndIsReported() async throws {
        let refusing = try await HeldPort.start(answering: "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        defer { refusing.stop() }
        let root = try folder("refusing")
        try portFile(refusing.port, in: profile(in: root))
        try lock(profile(in: root), by: getpid())
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let reporter = ErrandReporter(client: ProLLMClient(licenseKey: { nil }, send: { _ in throw URLError(.cancelled) },
                                                           log: { _ in }),
                                      directory: h.folder.appendingPathComponent("Reports"), appVersion: "0")
        let link = ChromeLink(applicationSupport: try folder("user"), own: AgentChrome(root: root, application: { nil }))
        let service = h.makeService(link: link, reporter: reporter)
        let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        await h.until({ !service.errandRunning }, "the errand's end", limit: .seconds(10))
        let failed = ErrandOutcome(ending: .failed, answer: nil, sources: [], sheet: nil, rows: 0,
                                   failure: .browserDidNotStart)
        XCTAssertEqual(h.events(of: id).last, .finished(failed))
        XCTAssertEqual(ChatService.errandEndingLine(failed), "The errand failed.")
        XCTAssertEqual(reporter.waiting.map(\.errandID), [id], "one report, kept to go")
        XCTAssertTrue(h.runners.isEmpty)
    }

    /// The user's way reads Google Chrome alone (8.8): Brave running with its port open — or Arc — is not used, and
    /// the user hears that Chrome is not running; on a Mac without Google Chrome, that it is not installed (8b-34),
    /// not reported.
    func testTheUsersWayIsGoogleChromeAloneAndAMacWithoutItIsToldSo() async throws {
        let brave = try await HeldPort.start(speaking: true)
        defer { brave.stop() }
        let user = try folder("user")
        let braveProfile = user.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true)
        try FileManager.default.createDirectory(at: braveProfile, withIntermediateDirectories: true)
        try portFile(brave.port, in: braveProfile)
        try lock(braveProfile, by: getpid())
        let arc = user.appendingPathComponent("Arc/User Data", isDirectory: true)
        try FileManager.default.createDirectory(at: arc, withIntermediateDirectories: true)
        try lock(arc, by: getpid())
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")

        let installed = ChromeLink(applicationSupport: user, settleLimit: .milliseconds(300), application: { chrome })
        let connection = await installed.connect()
        XCTAssertNil(connection)
        XCTAssertEqual(installed.state, .notRunning)
        XCTAssertEqual(brave.connections, 0, "Brave's port is never used")

        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let reporter = ErrandReporter(client: ProLLMClient(licenseKey: { nil }, send: { _ in throw URLError(.cancelled) },
                                                           log: { _ in }),
                                      directory: h.folder.appendingPathComponent("Reports"), appVersion: "0")
        let missing = ChromeLink(applicationSupport: user, settleLimit: .milliseconds(300), application: { nil })
        let service = h.makeService(link: missing, reporter: reporter)
        let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        await h.until({ !service.errandRunning }, "the errand's end", limit: .seconds(5))
        let notRun = ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0,
                                   notRun: .browserNotInstalled)
        XCTAssertEqual(h.events(of: id).last, .finished(notRun))
        XCTAssertEqual(ChatService.errandEndingLine(notRun),
                       "Google Chrome is not installed on this Mac. Install it from google.com/chrome, then ask again.")
        XCTAssertTrue(reporter.waiting.isEmpty, "not reported")
        XCTAssertEqual(brave.connections, 0)
    }

    // MARK: - The user's Allow first (stage 8b, 8.2)

    /// An errand that waits for the user's Allow starts no Chrome and asks no port — MetaWhisp's own Chrome or the
    /// user's — and Not now leaves it so.
    func testAnErrandWaitingForTheAllowStartsNoChromeAndAsksNoPort() async throws {
        let app = try standIn(seconds: 30)
        let root = try folder("own")
        let own = AgentChrome(root: root, launch: .childProcess, endsWith: getpid(), startLimit: .milliseconds(300),
                              application: { app })
        addTeardownBlock { @MainActor in
            if let started = own.started { kill(started.processIdentifier, SIGTERM) }
        }
        let users = try await HeldPort.start(speaking: true)
        defer { users.stop() }
        let user = try folder("user")
        try portFile(users.port, in: profile(in: user))
        try lock(profile(in: user), by: getpid())
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.allowed = false
        let service = h.makeService(link: ChromeLink(applicationSupport: user, own: own),
                                    usersLink: ChromeLink(applicationSupport: user))
        for way in [AgentBrowser.ownWindow, .usersChrome] {
            h.way = way
            _ = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
            await h.until({ service.disclosure == way }, "the disclosure: \(way)")
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(own.launches, 0, "MetaWhisp's own Chrome never started: \(way)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: own.profile.path), "no profile made: \(way)")
            XCTAssertEqual(users.connections, 0, "the user's Chrome never asked: \(way)")
            service.notNow()
            XCTAssertNil(service.disclosure)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(own.launches, 0)
        XCTAssertEqual(users.connections, 0)
        XCTAssertTrue(h.runners.isEmpty)
    }

    // MARK: - Off and the other browser (stage 8b, 8.3, 8.4)

    /// The agent turned off, or the browser changed from the user's own Chrome: the connection to it closes once
    /// nothing runs — and the user's own Chrome is never closed.
    func testOffAndLeavingTheUsersWayCloseOnlyTheConnectionNeverTheUsersChrome() async throws {
        let usersPort = try await HeldPort.start(speaking: true, replying: true)
        defer { usersPort.stop() }
        let user = try folder("user")
        try portFile(usersPort.port, in: profile(in: user))
        try lock(profile(in: user), by: getpid())
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.way = .usersChrome
        let own = AgentChrome(root: try folder("own"), application: { nil })
        let service = h.makeService(link: ChromeLink(applicationSupport: user, own: own),
                                    usersLink: ChromeLink(applicationSupport: user))
        for leave in ["the own way", "off"] {
            let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
            await h.until({ h.runners.contains { $0.setup.id == id && $0.isRunning } }, "the run in the user's Chrome",
                          limit: .seconds(5))
            let ended = usersPort.ended
            if leave == "off" {
                h.agentOn = false
                service.turnedOff()
            } else {
                h.runners.first { $0.setup.id == id }?.finish(ErrandOutcome(ending: .done, answer: "Ten jokes",
                                                                             sources: [], sheet: nil, rows: 0))
                await h.until({ !service.errandRunning }, "the errand's end")
                h.way = .ownWindow
                service.wayChanged()
            }
            await h.until({ usersPort.ended == ended + 1 }, "the connection to close: \(leave)", limit: .seconds(5))
            XCTAssertFalse(Self.closed(usersPort), "the user's own Chrome is never closed: \(leave)")
            (h.way, h.agentOn) = (.usersChrome, true)
        }
        XCTAssertEqual(own.launches, 0, "MetaWhisp's own Chrome never started")
    }

    // MARK: - A cleared MetaChat (stage 8b, 8.12)

    /// Clearing MetaChat closes MetaWhisp's own Chrome over its port and deletes its profile — its history and
    /// sign-ins — and nothing else: not the user's own Chrome profile, not another browser's, not a folder beside it,
    /// not a file beside the profile in the agent's own folder.
    func testClearingMetaChatClosesTheOwnChromeAndDeletesItsProfileAndNothingElse() async throws {
        let ownPort = try await HeldPort.start(speaking: true, replying: true)
        defer { ownPort.stop() }
        let root = try folder("own")
        let ownProfile = try profile(in: root)
        try portFile(ownPort.port, in: ownProfile)
        try "visited".write(to: ownProfile.appendingPathComponent("History"), atomically: true, encoding: .utf8)
        try "kept".write(to: root.appendingPathComponent("Beside.txt"), atomically: true, encoding: .utf8)
        let user = try folder("user")
        let usersChrome = try profile(in: user)
        try "the user's own".write(to: usersChrome.appendingPathComponent("Bookmarks"), atomically: true,
                                   encoding: .utf8)
        let usersBrave = user.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true)
        try FileManager.default.createDirectory(at: usersBrave, withIntermediateDirectories: true)
        let other = try folder("other")
        try "other".write(to: other.appendingPathComponent("Notes.txt"), atomically: true, encoding: .utf8)

        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let own = AgentChrome(root: root, application: { nil }, usersApplicationSupport: user)
        let service = h.makeService(link: ChromeLink(applicationSupport: user, own: own),
                                    usersLink: ChromeLink(applicationSupport: user))
        service.deleteAllRecords()
        await h.until({ !FileManager.default.fileExists(atPath: ownProfile.path) }, "the own profile to go",
                      limit: .seconds(10))
        XCTAssertTrue(Self.closed(ownPort), "closed over its own port first")
        XCTAssertEqual(try String(contentsOf: usersChrome.appendingPathComponent("Bookmarks"), encoding: .utf8),
                       "the user's own")
        XCTAssertTrue(FileManager.default.fileExists(atPath: usersBrave.path))
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("Notes.txt"), encoding: .utf8), "other")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Beside.txt"), encoding: .utf8), "kept")
    }

    /// The next errand's look for MetaWhisp's own Chrome waits for a clear's close and delete under way: it never
    /// connects to the Chrome being closed, and no Chrome starts on a profile being deleted.
    func testANewLookWaitsForAClearUnderWay() async throws {
        let ownPort = try await HeldPort.start(speaking: true, replying: true)
        defer { ownPort.stop() }
        let root = try folder("own")
        let ownProfile = try profile(in: root)
        try portFile(ownPort.port, in: ownProfile)
        // A Chrome that takes a second to end after its close: its lock is held by a process that lives a second.
        let ending = Process()
        ending.executableURL = URL(fileURLWithPath: "/bin/sleep")
        ending.arguments = ["1"]
        try ending.run()
        addTeardownBlock { if ending.isRunning { ending.terminate() } }
        try lock(ownProfile, by: ending.processIdentifier)
        let link = ChromeLink(applicationSupport: try folder("user"), settleLimit: .milliseconds(300),
                              own: AgentChrome(root: root, application: { nil }, usersApplicationSupport: try folder("user")))
        let forget = Task { await link.forgetOwnBrowser() }
        try await Task.sleep(for: .milliseconds(100))
        let connection = await link.connect()
        await forget.value
        XCTAssertNil(connection, "not the Chrome being closed")
        XCTAssertEqual(link.state, .notInstalled, "it looked once the profile was gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownProfile.path))
        XCTAssertEqual(ownPort.connections, 1, "the close's own connection alone")
    }

    /// A profile that is the user's own — a root that is their Application Support, or a link into it — is never
    /// deleted. Folders of the test's own stand for the user's: nothing here can reach the Mac's real profiles.
    func testAProfileThatIsTheUsersOwnIsNeverDeleted() throws {
        let user = try folder("user")
        let usersChrome = try profile(in: user)
        try "the user's own".write(to: usersChrome.appendingPathComponent("Bookmarks"), atomically: true,
                                   encoding: .utf8)
        AgentChrome(root: user, application: { nil }, usersApplicationSupport: user).deleteProfile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: usersChrome.appendingPathComponent("Bookmarks").path),
                      "a root that is the user's Application Support")

        let linked = try folder("linked")
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("Google"),
                                                   withDestinationURL: user.appendingPathComponent("Google"))
        AgentChrome(root: linked, application: { nil }, usersApplicationSupport: user).deleteProfile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: usersChrome.appendingPathComponent("Bookmarks").path),
                      "a link into it")

        // A profile that holds the user's folder.
        let outer = try folder("outer")
        let nested = outer.appendingPathComponent("Google/Chrome/Users", isDirectory: true)
        let nestedChrome = try profile(in: nested)
        try "the user's own".write(to: nestedChrome.appendingPathComponent("Bookmarks"), atomically: true,
                                   encoding: .utf8)
        AgentChrome(root: outer, application: { nil }, usersApplicationSupport: nested).deleteProfile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedChrome.appendingPathComponent("Bookmarks").path),
                      "a profile that holds theirs")
    }

    // MARK: - The quit

    /// The app's quit closes the agent's own Chrome over its port — once the errand's run has returned, its tab
    /// closed — and, with no errand, one a crash left open. The user's own Chrome is never closed.
    func testTheQuitClosesTheOwnChromeAfterTheRunReturnedAndNeverTheUsersChrome() async throws {
        let ownPort = try await HeldPort.start(speaking: true, replying: true)
        defer { ownPort.stop() }
        let root = try folder("own")
        try portFile(ownPort.port, in: profile(in: root))
        try lock(profile(in: root), by: getpid())
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let own = AgentChrome(root: root, application: { nil })
        let service = h.makeService(link: ChromeLink(applicationSupport: try folder("user"), own: own))
        let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        await h.until({ h.runners.contains { $0.setup.id == id && $0.isRunning } }, "the run", limit: .seconds(5))
        let run = try XCTUnwrap(h.runners.first { $0.setup.id == id })
        run.returnsOnStop = false
        let quit = try XCTUnwrap(service.appWillQuit(), "the own Chrome to close")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(Self.closed(ownPort), "not while the run still closes its tab")
        run.finish(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0))
        await quit.value
        XCTAssertTrue(Self.closed(ownPort), "closed over its own port once the run returned")
        XCTAssertEqual(own.launches, 0)

        // A launch with no errand, the own Chrome a crash left still running: the quit closes it too.
        let leftPort = try await HeldPort.start(speaking: true, replying: true)
        defer { leftPort.stop() }
        let leftRoot = try folder("left")
        try portFile(leftPort.port, in: profile(in: leftRoot))
        let later = h.makeService(link: ChromeLink(applicationSupport: try folder("user"),
                                                   own: AgentChrome(root: leftRoot, application: { nil })))
        let closing = try XCTUnwrap(later.appWillQuit(), "the own Chrome to close, with no errand")
        await closing.value
        XCTAssertTrue(Self.closed(leftPort))

        // The user's own Chrome: an errand in it, then the quit — it is never closed.
        let usersPort = try await HeldPort.start(speaking: true, replying: true)
        defer { usersPort.stop() }
        let user = try folder("users")
        try portFile(usersPort.port, in: profile(in: user))
        try lock(profile(in: user), by: getpid())
        let theirs = h.makeService(link: ChromeLink(applicationSupport: user))
        let errand = try XCTUnwrap(theirs.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        await h.until({ h.runners.contains { $0.setup.id == errand && $0.isRunning } }, "the run in the user's Chrome",
                      limit: .seconds(5))
        let returned = try XCTUnwrap(theirs.appWillQuit(), "its run to return")
        await returned.value
        XCTAssertEqual(usersPort.connections, 1, "the premise: the errand ran in the user's Chrome")
        XCTAssertFalse(Self.closed(usersPort), "the user's own Chrome is never closed")
        XCTAssertNil(h.makeService(link: ChromeLink(applicationSupport: user)).appWillQuit(),
                     "nothing to wait for: no run, and no browser of the agent's own")
    }

    // MARK: - Helpers

    /// Whether `Browser.close` reached the port.
    private static func closed(_ port: HeldPort) -> Bool {
        port.messages.contains { $0.contains("\"Browser.close\"") }
    }

    /// A folder of the test's own, removed after it.
    private func folder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-own-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// `Google/Chrome` in `root`: the profile, made.
    private func profile(in root: URL) throws -> URL {
        let profile = root.appendingPathComponent("Google/Chrome", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        return profile
    }

    /// The lock a running browser holds on its profile: `<host>-<pid>`.
    private func lock(_ profile: URL, by pid: pid_t) throws {
        try FileManager.default.createSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path,
                                                   withDestinationPath: "test-host.local-\(pid)")
    }

    private func portFile(_ port: Int, in profile: URL) throws {
        try "\(port)\n/devtools/browser/held".write(to: profile.appendingPathComponent("DevToolsActivePort"),
                                                   atomically: true, encoding: .utf8)
    }

    /// An app in Chrome's place that shows nothing — no window, no Dock icon — and opens no port: it lives
    /// `seconds`, or until it is ended. `noting`: a folder it writes its parent process (`parent`) and the switches
    /// it was given (`arguments`) to.
    private func standIn(seconds: Int, noting notes: URL? = nil, version: String? = nil) throws -> URL {
        let app = try folder("program").appendingPathComponent("Chrome.app", isDirectory: true)
        let program = app.appendingPathComponent("Contents/MacOS/chrome")
        try FileManager.default.createDirectory(at: program.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "test.metawhisp.standin.\(UUID().uuidString)",
                                   "CFBundleExecutable": "chrome", "CFBundlePackageType": "APPL",
                                   "LSBackgroundOnly": true]
        if let version { info["CFBundleShortVersionString"] = version }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let note = notes.map {
            "printf '%s\\n' \"$PPID\" > '\($0.path)/parent'\nprintf '%s\\n' \"$@\" > '\($0.path)/arguments'\n"
        } ?? ""
        try ("#!/bin/sh\n" + note + (seconds > 0 ? "exec /bin/sleep \(seconds)\n" : "exit 0\n"))
            .write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        // LaunchServices keeps every app it opened on its list: the stand-in leaves it before its folder goes.
        let path = app.resolvingSymlinksInPath().path
        addTeardownBlock {
            let unregister = Process()
            unregister.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework"
                                           + "/Frameworks/LaunchServices.framework/Support/lsregister")
            unregister.arguments = ["-u", path]
            unregister.standardOutput = FileHandle.nullDevice
            unregister.standardError = FileHandle.nullDevice
            guard (try? unregister.run()) != nil else { return }
            let deadline = Date().addingTimeInterval(10)
            while unregister.isRunning, Date() < deadline { usleep(20_000) }
        }
        return app
    }

    private func XCTAssertStartFails(_ own: AgentChrome, with failure: AgentChrome.StartFailure, _ message: String = "",
                                     file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await own.start()
            XCTFail("it started: \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AgentChrome.StartFailure, failure, message, file: file, line: line)
        }
    }

    /// What the failed errands' reporter sent: nothing, here.
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var requests = 0
        var count: Int { lock.withLock { requests } }

        func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
            lock.withLock { requests += 1 }
            return (Data(#"{"ok":true}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}
