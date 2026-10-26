import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 9d, № 21, № 23 — a tab the agent left open in the user's
/// Chrome is closed when the next errand connects: the app crashed with it
/// open, or its close never got through — the Mac went to sleep and the
/// connection went with it. Only a tab the agent made that still shows its
/// mark: a tab the user took over and moved on in, and the user's own tabs,
/// stay. In a real Chrome (headless, a profile of its own); skipped without
/// Chrome.
@MainActor
final class ChromeStrayTabLiveTests: XCTestCase {

    func testATabTheAppLeftOpenIsClosedOnTheNextConnectionAndNothingElse() async throws {
        let chrome = try await TestChrome.launch()
        defer { chrome.quit() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mw-stray-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let ledger = AgentTabLedger(file: folder.appendingPathComponent("AgentTabs.json"))

        // The last session: the agent's tabs and the user's own one; then the
        // app goes, and its connection with it — nothing is closed.
        let first = CDPConnection(url: chrome.endpoint.webSocketURL)
        try await first.open()
        let fixtures = ChromeFixtures(connection: first)
        await fixtures.start()
        let bridge = ChromeBridge(connection: first, prepareTab: { try await fixtures.serve($0) }, tabs: ledger,
                                  resolve: ChromeFixtures.resolve)
        let crashed = try await bridge.openTab(URL(string: "https://site-1.test/")!)
        let unclosed = try await bridge.openTab(URL(string: "https://site-2.test/")!)
        let movedOn = try await bridge.openTab(URL(string: "https://site-3.test/")!)
        let created = try await first.send("Target.createTarget", params: ["url": "about:blank"])
        let users = try XCTUnwrap(created["targetId"]?.string)
        try await Self.until(on: first, "the agent's tabs marked") { titles in
            [crashed, unclosed, movedOn].allSatisfy { titles[$0.windowID]?.hasPrefix(ChromeBridge.tabMark) == true }
        }
        fixtures.stop()
        await first.close()
        // The close a sleep cut short: the connection is gone, the close fails,
        // and the tab stays listed.
        do {
            try await bridge.closeTab(unclosed)
            XCTFail("a close over a connection that is gone")
        } catch {}
        XCTAssertEqual(Set(ledger.open), [crashed.windowID, unclosed.windowID, movedOn.windowID])

        // The user takes one of them over and moves on in it: its page is
        // theirs now, and shows no mark.
        let user = CDPConnection(url: chrome.endpoint.webSocketURL)
        try await user.open()
        let attached = try await user.send("Target.attachToTarget",
                                           params: ["targetId": .string(movedOn.windowID), "flatten": true])
        let session = try XCTUnwrap(attached["sessionId"]?.string)
        _ = try await user.send("Page.navigate", params: ["url": "data:text/html,<title>Mine</title>"],
                                sessionID: session)
        try await Self.until(on: user, "the user's page in that tab") { $0[movedOn.windowID] == "Mine" }
        await user.close()

        // The next errand's connection.
        let link = ChromeLink(applicationSupport: try Self.applicationSupport(linking: chrome.profile, in: folder),
                              tabs: ledger)
        let next = await link.bridge()
        XCTAssertNotNil(next, "connected")
        let look = CDPConnection(url: chrome.endpoint.webSocketURL)
        try await look.open()
        defer { Task { await look.close() } }
        try await Self.until(on: look, "the left tabs closed") {
            $0[crashed.windowID] == nil && $0[unclosed.windowID] == nil
        }
        let titles = try await Self.titles(on: look)
        XCTAssertEqual(titles[movedOn.windowID], "Mine", "the tab the user moved on in is theirs")
        XCTAssertNotNil(titles[users], "the user's own tab is never touched")
        XCTAssertEqual(ledger.open, [], "each listed tab closed, or let go")
    }

    // MARK: - Helpers

    /// Every page's title, by its target id.
    private static func titles(on connection: CDPConnection) async throws -> [String: String] {
        let targets = try await connection.send("Target.getTargets")
        var titles: [String: String] = [:]
        for info in targets["targetInfos"]?.array ?? [] where info["type"]?.string == "page" {
            if let id = info["targetId"]?.string { titles[id] = info["title"]?.string ?? "" }
        }
        return titles
    }

    /// Until the pages' titles say `done`; fails after 10 s.
    private static func until(on connection: CDPConnection, _ what: String,
                              _ done: ([String: String]) -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if done(try await titles(on: connection)) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// An Application Support folder of the test's own, where `profile` is
    /// Google Chrome's.
    private static func applicationSupport(linking profile: URL, in folder: URL) throws -> URL {
        let support = folder.appendingPathComponent("Application Support", isDirectory: true)
        let google = support.appendingPathComponent("Google", isDirectory: true)
        try FileManager.default.createDirectory(at: google, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: google.appendingPathComponent("Chrome"), withDestinationURL: profile)
        return support
    }
}
