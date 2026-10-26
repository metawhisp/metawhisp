import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 3.1 — the one live connection to the user's browser, on profile
/// folders of the test's own: never the user's Chrome.
@MainActor
final class ChromeLinkTests: XCTestCase {
    func testNoBrowserIsNotRunning() async throws {
        let link = ChromeLink(applicationSupport: try applicationSupport(), settleLimit: .milliseconds(300),
                              application: Self.installed)
        let connection = await link.connect()
        XCTAssertNil(connection)
        XCTAssertEqual(link.state, .notRunning)
    }

    /// A browser holds its profile, but no DevTools port answers: the toggle
    /// at chrome://inspect is off.
    func testARunningBrowserThatDoesNotAnswerHasRemoteDebuggingOff() async throws {
        let support = try applicationSupport()
        try lock(chrome(in: support), by: getpid())
        let link = ChromeLink(applicationSupport: support, settleLimit: .milliseconds(300))
        let connection = await link.connect()
        XCTAssertNil(connection)
        XCTAssertEqual(link.state, .remoteDebuggingOff)
    }

    /// A port file a closed browser left behind is passed over at once.
    func testAPortFileAClosedBrowserLeftIsPassedOver() async throws {
        let support = try applicationSupport()
        let profile = try chrome(in: support)
        try "1\n/devtools/browser/left-behind".write(to: profile.appendingPathComponent("DevToolsActivePort"),
                                                    atomically: true, encoding: .utf8)
        try lock(profile, by: 999_999)
        let link = ChromeLink(applicationSupport: support, settleLimit: .seconds(5), application: Self.installed)
        let started = ContinuousClock.now
        let connection = await link.connect()
        XCTAssertNil(connection)
        XCTAssertEqual(link.state, .notRunning)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    /// Chrome holds a new connection while it asks the user to Allow it: the
    /// link says so, waits up to its limit, and does not ask again on its own.
    func testWaitsForTheUsersAllowAndDoesNotAskAgainOnItsOwn() async throws {
        let port = try await HeldPort.start()
        defer { port.stop() }
        let support = try applicationSupport()
        try portFile(port.port, in: chrome(in: support))
        let link = ChromeLink(applicationSupport: support, allowLimit: .seconds(2))
        let pending = Task { await link.connect() }
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(link.state, .waitingForAllow(browser: "Google Chrome"))
        let connection = await pending.value
        XCTAssertNil(connection)
        XCTAssertEqual(link.state, .notAllowed)
        XCTAssertEqual(port.connections, 1, "asked once")
    }

    /// Review of 3.1, round 2 (Kimi): a Stop while the browser asks the user
    /// ends the question — the connection that holds it up is closed — and
    /// the caller is back at once; the link is idle again.
    func testAStopWhileTheBrowserAsksEndsTheQuestion() async throws {
        let port = try await HeldPort.start()
        defer { port.stop() }
        let support = try applicationSupport()
        try portFile(port.port, in: chrome(in: support))
        let link = ChromeLink(applicationSupport: support)
        let pending = Task { await link.connect() }
        try await Task.sleep(for: .milliseconds(1_300))
        XCTAssertEqual(link.state, .waitingForAllow(browser: "Google Chrome"))
        let stopped = ContinuousClock.now
        pending.cancel()
        let connection = await pending.value
        XCTAssertNil(connection)
        XCTAssertLessThan(ContinuousClock.now - stopped, .milliseconds(500), "back at once")
        let deadline = ContinuousClock.now + .seconds(2)
        while port.ended == 0 || link.state != .idle, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(port.ended, 1, "the question's connection is closed")
        XCTAssertEqual(link.state, .idle)
    }

    /// Review of ITER-076 B1c, round 2: a Stop while a running browser has no
    /// DevTools port yet ends the attempt at once. The waits between looks end
    /// with the Stop, so the attempt neither spins until its limit nor says,
    /// seconds later, that remote debugging is off.
    func testAStopWhileTheBrowserHasNoPortYetEndsTheAttempt() async throws {
        let support = try applicationSupport()
        try lock(chrome(in: support), by: getpid())
        let link = ChromeLink(applicationSupport: support, settleLimit: .seconds(3))
        let pending = Task { await link.connect() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(link.state, .connecting)
        pending.cancel()
        _ = await pending.value
        let deadline = ContinuousClock.now + .seconds(1)
        while link.state != .idle, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(link.state, .idle, "the attempt ended with the Stop")
    }

    /// The user declines: the connection Chrome held ends, and the link says
    /// it was not allowed.
    func testADeclinedAllowIsNotAllowed() async throws {
        let port = try await HeldPort.start()
        defer { port.stop() }
        let support = try applicationSupport()
        try portFile(port.port, in: chrome(in: support))
        let link = ChromeLink(applicationSupport: support, allowLimit: .seconds(30))
        let pending = Task { await link.connect() }
        try await Task.sleep(for: .milliseconds(1_500))
        port.decline()
        let connection = await pending.value
        XCTAssertNil(connection)
        XCTAssertEqual(link.state, .notAllowed)
        XCTAssertEqual(port.connections, 1)
    }

    /// Review of 3.1: a browser that refuses at once — faster than it could
    /// have asked the user — has answered: it is not asked again and again
    /// until the wait runs out, each time a new question to the user.
    func testABrowserThatRefusesAtOnceIsNotAskedAgain() async throws {
        let port = try await HeldPort.start(answering: "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        defer { port.stop() }
        let support = try applicationSupport()
        let profile = try chrome(in: support)
        try portFile(port.port, in: profile)
        try lock(profile, by: getpid())
        let link = ChromeLink(applicationSupport: support, settleLimit: .seconds(3))
        let connection = await link.connect()
        XCTAssertNil(connection)
        XCTAssertEqual(link.state, .notAllowed)
        XCTAssertEqual(port.connections, 1, "asked once")
        _ = await link.connect()
        XCTAssertEqual(port.connections, 2, "the next errand asks again")
    }

    /// Review of 3.1: a port nothing answers on is passed for the next
    /// browser that answers — of the browsers a link is given: the app's
    /// links are given Google Chrome alone (stage 8b, 8.8), so the full list
    /// is given here.
    func testAPortNothingAnswersOnIsPassedForTheNextBrowser() async throws {
        let chrome = try await TestChrome.launch()
        defer { chrome.quit() }
        let support = try applicationSupport()
        try "1\n/devtools/browser/left-behind".write(
            to: try self.chrome(in: support).appendingPathComponent("DevToolsActivePort"), atomically: true,
            encoding: .utf8)
        let brave = support.appendingPathComponent("BraveSoftware", isDirectory: true)
        try FileManager.default.createDirectory(at: brave, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: brave.appendingPathComponent("Brave-Browser"),
                                                   withDestinationURL: chrome.profile)
        let link = ChromeLink(applicationSupport: support, profiles: DevToolsPortLocator.profiles)
        let connection = await link.connect()
        XCTAssertNotNil(connection)
        XCTAssertEqual(link.state, .connected(browser: "Brave"))
    }

    /// Review of 3.1, round 2: a port that answers "not found" — a browser
    /// that has moved on, or something else — is passed for the next browser.
    func testAPortThatAnswersNotFoundIsPassedForTheNextBrowser() async throws {
        let port = try await HeldPort.start(answering: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        defer { port.stop() }
        let chrome = try await TestChrome.launch()
        defer { chrome.quit() }
        let support = try applicationSupport()
        try portFile(port.port, in: self.chrome(in: support))
        let brave = support.appendingPathComponent("BraveSoftware", isDirectory: true)
        try FileManager.default.createDirectory(at: brave, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: brave.appendingPathComponent("Brave-Browser"),
                                                   withDestinationURL: chrome.profile)
        let link = ChromeLink(applicationSupport: support, profiles: DevToolsPortLocator.profiles)
        let connection = await link.connect()
        XCTAssertNotNil(connection)
        XCTAssertEqual(link.state, .connected(browser: "Brave"))
    }

    /// Review of 3.1: a connection that is open is kept even while the browser
    /// is slow to answer — a new one would ask the user again.
    func testAnOpenConnectionIsKeptWhileTheBrowserIsSlow() async throws {
        let port = try await HeldPort.start(speaking: true)
        defer { port.stop() }
        let support = try applicationSupport()
        try portFile(port.port, in: chrome(in: support))
        let link = ChromeLink(applicationSupport: support)
        let first = await link.connect()
        XCTAssertNotNil(first)
        let again = await link.connect()
        XCTAssertTrue(again === first)
        XCTAssertEqual(port.connections, 1)
    }

    /// One connection for every caller: callers that come together share it,
    /// and a later one gets the same while it answers — so Chrome asks once.
    func testConnectsOnceAndKeepsTheConnection() async throws {
        let chrome = try await TestChrome.launch()
        defer { chrome.quit() }
        let support = try applicationSupport(linkingChromeTo: chrome.profile)
        let link = ChromeLink(applicationSupport: support)
        async let first = link.connect()
        async let second = link.connect()
        let (a, b) = await (first, second)
        let connection = try XCTUnwrap(a)
        XCTAssertTrue(connection === b, "callers that come together share one")
        XCTAssertEqual(link.state, .connected(browser: "Google Chrome"))
        let later = await link.connect()
        XCTAssertTrue(later === connection, "kept while it answers")
    }

    /// A connection that ended — the browser quit, or it was closed — leaves
    /// the link idle, and the next caller gets a new one.
    func testAConnectionThatEndedIsOpenedAgain() async throws {
        let chrome = try await TestChrome.launch()
        defer { chrome.quit() }
        let support = try applicationSupport(linkingChromeTo: chrome.profile)
        let link = ChromeLink(applicationSupport: support)
        let opened = await link.connect()
        let first = try XCTUnwrap(opened)
        await first.close()
        let deadline = ContinuousClock.now + .seconds(2)
        while link.state != .idle, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(link.state, .idle)
        let reopened = await link.connect()
        let second = try XCTUnwrap(reopened)
        XCTAssertFalse(second === first)
        XCTAssertEqual(link.state, .connected(browser: "Google Chrome"))
    }

    // MARK: - Helpers

    /// Google Chrome's app as the link looks for it, whatever this Mac has (stage 8b).
    private static let installed: () -> URL? = { URL(fileURLWithPath: "/Applications/Google Chrome.app") }

    /// Show tab brings forward the process that holds the connected
    /// browser's profile (ITER-076 stage 3): the one its lock names; none for
    /// a profile no browser holds.
    func testTheProcessThatHoldsAProfileIsTheOneItsLockNames() throws {
        let support = try applicationSupport()
        let profile = try chrome(in: support)
        XCTAssertNil(ChromeLink.holder(of: profile), "no lock: no holder")
        try lock(profile, by: 4242)
        XCTAssertEqual(ChromeLink.holder(of: profile), 4242)
    }

    private func applicationSupport(linkingChromeTo profile: URL? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("metawhisp-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        if let profile {
            let google = folder.appendingPathComponent("Google", isDirectory: true)
            try FileManager.default.createDirectory(at: google, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: google.appendingPathComponent("Chrome"),
                                                       withDestinationURL: profile)
        }
        return folder
    }

    private func chrome(in support: URL) throws -> URL {
        let profile = support.appendingPathComponent("Google/Chrome", isDirectory: true)
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
}
