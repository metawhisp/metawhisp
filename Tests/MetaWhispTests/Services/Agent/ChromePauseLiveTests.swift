import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 3 (№ 113, 114) — the agent's tab while the user does their
/// part, in a real Chrome (headless, a profile of its own): a window the tab
/// opens meanwhile — a "Sign in with Google" one — is never closed, then or
/// after Continue, nor when the errand ends; one the tab opens after Continue
/// is closed as before. Show tab fronts the agent's own tab, by its target,
/// and brings the browser forward — nothing else is sent. Skipped without
/// Chrome.
final class ChromePauseLiveTests: XCTestCase {

    /// The windows Chrome has open that `tab` opened.
    @MainActor
    private func windows(of tab: BrowserTab, _ world: ChromeWorld) async throws -> Set<String> {
        let targets = try await world.connection.send("Target.getTargets")
        return Set((targets["targetInfos"]?.array ?? []).filter {
            $0["type"]?.string == "page" && $0["openerId"]?.string == tab.windowID
        }.compactMap { $0["targetId"]?.string })
    }

    /// Whether Chrome still has the window `target`.
    @MainActor
    private func isOpen(_ target: String, _ world: ChromeWorld) async throws -> Bool {
        let targets = try await world.connection.send("Target.getTargets")
        return (targets["targetInfos"]?.array ?? []).contains { $0["targetId"]?.string == target }
    }

    /// The tab's page opens a window as a person's click does. Its document
    /// is one the guard never answered (`about:blank`), so no sandbox holds
    /// the window back: what a sign-in's own window is once it is open.
    @MainActor
    private func openAWindow(from tab: BrowserTab, _ world: ChromeWorld) async throws {
        _ = try await world.connection.send("Runtime.evaluate",
                                            params: ["expression": "window.open('about:blank', '_blank'); 'opened'",
                                                     "userGesture": true],
                                            sessionID: tab.tabID)
    }

    @MainActor
    private func blankTab(_ world: ChromeWorld) async throws -> BrowserTab {
        let (tab, _) = try await world.open("https://site-3.test/")
        _ = try await world.connection.send("Page.navigate", params: ["url": "about:blank"], sessionID: tab.tabID)
        try await world.waitUntilPageIs("blank complete", in: tab)
        return tab
    }

    @MainActor
    func testAWindowTheTabOpensWhileTheUserHasItIsNeverClosed() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let tab = try await blankTab(world)

        // As before: a window the agent's tab opens is closed.
        try await openAWindow(from: tab, world)
        try await Task.sleep(for: .milliseconds(1_000))
        let swept = try await windows(of: tab, world)
        XCTAssertEqual(swept, [], "the agent's tab opens no window of its own")

        await world.bridge.lend(tab)
        try await openAWindow(from: tab, world)
        try await Task.sleep(for: .milliseconds(1_000))
        let users = try await windows(of: tab, world)
        XCTAssertEqual(users.count, 1, "the user's window lives while they have the tab")

        await world.bridge.reclaim(tab)
        try await Task.sleep(for: .milliseconds(1_000))
        let kept = try await windows(of: tab, world)
        XCTAssertEqual(kept, users, "after Continue it is still the user's")

        try await openAWindow(from: tab, world)
        try await Task.sleep(for: .milliseconds(1_000))
        let after = try await windows(of: tab, world)
        XCTAssertEqual(after, users, "one the tab opens after Continue is closed")

        try await world.bridge.closeTab(tab)
        for window in users {
            let open = try await isOpen(window, world)
            XCTAssertTrue(open, "the errand's end leaves the user's window")
        }
    }

    /// ITER-076 stage 8b (owner decision 8.6): while the user drives the
    /// agent's tab in a pause, an address on their own machine or network is
    /// still refused at the request — typed into the tab as into its address
    /// bar, or followed from its page — and nothing reaches it. A sign-in
    /// through an intranet host is done in another tab of the same Chrome.
    @MainActor
    func testWhileTheUserHasTheTabAPrivateAddressIsStillRefused() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-3.test/")
        await world.bridge.lend(tab)
        for address in ["http://192.168.1.1/", "http://127.0.0.1:9/admin"] {
            _ = world.bridge.events(in: tab)
            _ = try await world.connection.send("Page.navigate", params: ["url": .string(address)], sessionID: tab.tabID)
            var seen: [BrowserEvent] = []
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !seen.contains(.addressRefused) {
                seen += world.bridge.events(in: tab)
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(seen.contains(.addressRefused), "\(address): refused while the user has the tab")
        }
        XCTAssertFalse(world.fixtures.blocked.contains { $0.contains("192.168.") || $0.contains("127.0.0.1") },
                       "nothing went out: \(world.fixtures.blocked)")
    }

    /// The tab's page's dialogs are the user's while they have it — none is
    /// answered for them — and the agent's again after Continue.
    @MainActor
    func testWhileTheUserHasTheTabItsDialogsAreTheirs() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let tab = try await blankTab(world)
        await world.bridge.lend(tab)
        _ = try await world.connection.send("Runtime.evaluate",
                                            params: ["expression": "setTimeout(() => window.answered = confirm('Leave this draft?'), 0); 'asked'"],
                                            sessionID: tab.tabID)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(world.bridge.events(in: tab), [], "no dialog was answered for the user")
        _ = try await world.connection.send("Page.handleJavaScriptDialog", params: ["accept": true], sessionID: tab.tabID)
        let answered = try await world.bridge.runInPage("String(window.answered)", in: tab)
        XCTAssertEqual(answered, "true", "the user's own answer")

        await world.bridge.reclaim(tab)
        _ = try await world.connection.send("Runtime.evaluate",
                                            params: ["expression": "setTimeout(() => window.again = confirm('Leave this draft?'), 0); 'asked'"],
                                            sessionID: tab.tabID)
        var seen: [BrowserEvent] = []
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, seen.isEmpty {
            seen += world.bridge.events(in: tab)
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(seen, [.dialog(.confirm, accepted: false)], "the agent's again: Cancel without a Yes")
    }

    /// Show tab: `Target.activateTarget` with the agent's own target, then the
    /// browser forward — no input, nothing else.
    @MainActor
    func testShowTabFrontsTheAgentsOwnTabAndTheBrowser() async throws {
        let world = try await ChromeWorld.start(proxied: true)
        defer { world.stop() }
        var fronted = 0
        let bridge = ChromeBridge(connection: world.connection, prepareTab: { try await world.fixtures.serve($0) },
                                  bringForward: { fronted += 1 }, resolve: ChromeFixtures.resolve)
        let tab = try await bridge.openTab(URL(string: "https://site-3.test/")!)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, (try? await bridge.run("document.readyState", in: tab)) != "complete" {
            try await Task.sleep(for: .milliseconds(50))
        }
        let proxy = try XCTUnwrap(world.proxy)
        let before = proxy.messages.count
        await bridge.show(tab)
        // The tab's window sweep lists the targets every quarter of a second.
        let sent = proxy.messages.dropFirst(before).compactMap { try? CDPValue.decode($0) }
            .filter { $0["method"]?.string != "Target.getTargets" }
        XCTAssertEqual(sent.compactMap { $0["method"]?.string }, ["Target.activateTarget"])
        XCTAssertEqual(sent.first?["params"]?["targetId"]?.string, tab.windowID)
        XCTAssertEqual(fronted, 1)
        try await bridge.closeTab(tab)
    }
}
