import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 4b — the agent's own Chrome, for real: the Google Chrome the app starts on a profile of its own.
/// Headless here, and a child process of the test run that ends with it — the test switch — so nothing shows on
/// screen; its folder is the test's own, never the user's Chrome or profile. Skipped without Chrome.
@MainActor
final class AgentChromeLiveTests: XCTestCase {

    /// The first errand, with no own profile yet: the app starts Chrome on its own profile and connects — the errand
    /// shows connecting, then connected, never remote debugging off or waiting for Allow. The user's own Chrome, with
    /// a live DevTools port, is never read. A second errand reuses the running Chrome, and so does the next launch
    /// after a crash: no second start.
    func testTheFirstErrandStartsTheOwnChromeWithNoSetupAndTheNextOnesReuseIt() async throws {
        let own = try ownChrome()
        let users = try await HeldPort.start(speaking: true)
        defer { users.stop() }
        let user = try usersChrome(on: users)
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService(link: ChromeLink(applicationSupport: user, own: own))
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.profile.path), "no own profile yet")

        let first = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        await h.until(first, shows: .connecting(.connected(browser: "Google Chrome")), limit: .seconds(40))
        XCTAssertEqual(h.events(of: first), [.connecting(.connecting), .connecting(.connected(browser: "Google Chrome"))],
                       "connecting, then connected: no tick, no Allow")
        XCTAssertEqual(own.launches, 1)
        let chrome = try XCTUnwrap(own.started)
        XCTAssertEqual(ChromeLink.holder(of: own.profile), chrome.processIdentifier, "the Chrome it started holds its profile")
        XCTAssertEqual(users.connections, 0, "the user's own Chrome is never read")

        // "Connected" shows as the link connects; the run is made once the errand's bridge is ready — later, under
        // load (the gate of 2026-10-07 00:29): the harness waits for it.
        let made = await h.runner(for: first)
        let run = try XCTUnwrap(made)
        run.finish(ErrandOutcome(ending: .done, answer: "Ten jokes.", sources: [], sheet: nil, rows: 0))
        await h.until({ !service.errandRunning }, "the first errand's end")
        let second = try XCTUnwrap(service.start(goal: "Find 3 courses", origin: .chat(messageID: UUID())).id)
        await h.until(second, shows: .connecting(.connected(browser: "Google Chrome")), limit: .seconds(10))
        XCTAssertEqual(own.launches, 1, "the second errand reuses the running Chrome")
        XCTAssertFalse(chrome.isTerminated, "the window stays open between errands")

        // The next launch, after a crash: a new link and a new launcher on the same folder.
        let next = AgentChrome(root: own.root, headless: true, launch: .childProcess, endsWith: getpid())
        let link = ChromeLink(applicationSupport: user, own: next)
        let connection = await link.connect()
        XCTAssertNotNil(connection)
        XCTAssertEqual(link.state, .connected(browser: "Google Chrome"))
        XCTAssertEqual(next.launches, 0, "found running: not started again")
        XCTAssertEqual(users.connections, 0)
    }

    /// Headless, the own Chrome says it is Chrome of its own version, as a window of it does — a page reads no
    /// "HeadlessChrome" in its agent string (2026-10-19: what sites that keep automation out read first).
    func testTheHeadlessOwnChromeSaysItIsChrome() async throws {
        let own = try ownChrome()
        let link = ChromeLink(applicationSupport: try folder("user"), own: own)
        let connected = await link.connect()
        let connection = try XCTUnwrap(connected)
        let version = try await connection.send("Browser.getVersion")
        let agent = try XCTUnwrap(version["userAgent"]?.string)
        XCTAssertFalse(agent.contains("Headless"), agent)
        let major = try XCTUnwrap(AgentChrome.majorVersion(of: try XCTUnwrap(AgentChrome.installed())))
        XCTAssertTrue(agent.contains("Chrome/\(major).0.0.0"), agent)
    }

    /// The app's quit closes the own Chrome, with the agent's tab in it.
    func testTheAppsQuitClosesTheOwnChrome() async throws {
        let own = try ownChrome()
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService(link: ChromeLink(applicationSupport: try folder("user"), own: own))
        let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        await h.until(id, shows: .connecting(.connected(browser: "Google Chrome")), limit: .seconds(40))
        let chrome = try XCTUnwrap(own.started)
        XCTAssertFalse(chrome.isTerminated, "the premise")

        let quit = try XCTUnwrap(service.appWillQuit(), "the own Chrome to close")
        await quit.value
        let deadline = ContinuousClock.now + .seconds(10)
        while !chrome.isTerminated, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(chrome.isTerminated, "the own Chrome closed with the app")
    }

    // MARK: - Helpers

    /// The own Chrome of a test: headless, a child process ending with the test run, on a folder of the test's own
    /// with no profile yet; ended and removed after the test.
    private func ownChrome() throws -> AgentChrome {
        try XCTSkipUnless(AgentChrome.installed() != nil, "needs Google Chrome")
        let own = AgentChrome(root: try folder("own"), headless: true, launch: .childProcess, endsWith: getpid())
        addTeardownBlock { @MainActor in
            guard let chrome = own.started else { return }
            if !chrome.isTerminated { kill(chrome.processIdentifier, SIGTERM) }
            // Polled: `waitUntilExit()` waits on a run loop a concurrency thread never runs.
            let deadline = Date().addingTimeInterval(10)
            while !chrome.isTerminated, Date() < deadline { usleep(20_000) }
        }
        return own
    }

    /// An Application Support folder of the test's own whose Google Chrome runs with remote debugging on: a live
    /// port in its profile, held by a live process.
    private func usersChrome(on port: HeldPort) throws -> URL {
        let support = try folder("user")
        let profile = support.appendingPathComponent("Google/Chrome", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try "\(port.port)\n/devtools/browser/user".write(to: profile.appendingPathComponent("DevToolsActivePort"),
                                                        atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path,
                                                   withDestinationPath: "test-host.local-\(getpid())")
        return support
    }

    /// A folder of the test's own, removed after it — after its Chrome has ended (teardown blocks run last first).
    private func folder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-own-live-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
