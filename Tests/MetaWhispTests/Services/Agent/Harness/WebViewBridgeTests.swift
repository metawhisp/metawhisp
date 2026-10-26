import XCTest
@testable import MetaWhisp

/// Level 2 of the agent's automated test system (ITER-074 §12.1): this suite
/// proves the page harness itself — address routing, local loading, script
/// execution and the bridge's error contract — so every later page and loop
/// test can trust it. No network, no real browser, no macOS permissions.
final class WebViewBridgeTests: XCTestCase {
    /// Every page test starts the same way: open, then wait until the page
    /// says it is complete. The shared step lives here, not in ten tests.
    @MainActor
    private func openLoaded(_ bridge: WebViewBridge, _ address: String) async throws -> BrowserTab {
        let tab = try await bridge.openTab(URL(string: address)!)
        try await bridge.waitUntilLoaded(tab)
        return tab
    }

    // MARK: - Routing (pure, no bridge)

    func testASearchAddressRoutesToTheResultsPage() {
        XCTAssertEqual(
            FixtureRouter.fileName(for: URL(string: "https://search.test/?q=competitors")!),
            "search-results.html"
        )
        XCTAssertEqual(
            FixtureRouter.fileName(for: URL(string: "https://site-12.test/pricing")!),
            "site-12.html"
        )
        XCTAssertEqual(
            FixtureRouter.fileName(for: URL(string: "https://nowhere.test/")!),
            "not-found.html"
        )
    }

    // MARK: - Loading and running scripts

    @MainActor
    func testAFixturePageLoadsAndRunsJavaScript() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://site-1.test/")
        let title = try await bridge.run("document.title", in: tab)
        XCTAssertEqual(title, "Site One")
    }

    @MainActor
    func testThePageBelievesItIsAtItsAddress() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://site-1.test/")
        let href = try await bridge.run("location.href", in: tab)
        XCTAssertEqual(href, "https://site-1.test/")
    }

    @MainActor
    func testAClickRunsThePagesOwnScript() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://site-1.test/")
        let title = try await bridge.run("document.getElementById('subscribe').click(); document.title", in: tab)
        XCTAssertEqual(title, "Subscribed")
    }

    @MainActor
    func testTheResultsPageHasThreeResults() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://search.test/?q=competitors")
        let results = try await bridge.run("String(document.querySelectorAll('main a').length)", in: tab)
        XCTAssertEqual(results, "3")
    }

    @MainActor
    func testAnUnknownAddressGetsTheNotFoundPage() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://nowhere.test/")
        let title = try await bridge.run("document.title", in: tab)
        XCTAssertEqual(title, "Not found")
    }

    // MARK: - Error contract

    @MainActor
    func testNonWebURLsAreRefusedBeforeAnythingLoads() async throws {
        let bridge = WebViewBridge()
        let bad = URL(string: "javascript:alert(1)")!
        do {
            _ = try await bridge.openTab(bad)
            XCTFail("A javascript: address must never reach the browser")
        } catch let error as BrowserBridgeError {
            XCTAssertEqual(error, .notOpenable(bad))
        }
        XCTAssertTrue(bridge.openedURLs.isEmpty, "the refusal must happen before any bookkeeping")
        XCTAssertEqual(bridge.openTabCount, 0)
    }

    @MainActor
    func testAClosedTabIsGone() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://site-1.test/")
        try await bridge.closeTab(tab)
        XCTAssertEqual(bridge.openTabCount, 0)
        do {
            _ = try await bridge.run("1", in: tab)
            XCTFail("A closed tab must not answer scripts")
        } catch let error as BrowserBridgeError {
            XCTAssertEqual(error, .tabNotFound)
        }
    }

    @MainActor
    func testAScriptErrorIsReportedNotSwallowed() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://site-1.test/")
        do {
            _ = try await bridge.run("throw new Error('boom')", in: tab)
            XCTFail("A thrown page error must surface, not come back as a value")
        } catch let error as BrowserBridgeError {
            if case .scriptFailed = error {} else { XCTFail("Expected scriptFailed, got \(error)") }
        }
    }

    @MainActor
    func testUndefinedComesBackAsEmptyText() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://site-1.test/")
        let result = try await bridge.run("undefined", in: tab)
        XCTAssertEqual(result, "")
    }

    // MARK: - Navigation sealing (pure, no bridge)

    func testOurOwnLoadIsAllowed() {
        let u = URL(string: "https://site-1.test/")!
        XCTAssertEqual(
            FixtureNavigation.decide(url: u, isMainFrame: true, expectedLoad: u),
            .allow
        )
    }

    func testAPageGoingToAWebAddressIsRoutedToAFixture() {
        let x = URL(string: "https://example.com/x")!
        XCTAssertEqual(
            FixtureNavigation.decide(url: x, isMainFrame: true, expectedLoad: nil),
            .route(x)
        )
    }

    func testAFrameGoingAnywhereIsBlocked() {
        let u = URL(string: "https://example.com/")!
        XCTAssertEqual(
            FixtureNavigation.decide(url: u, isMainFrame: false, expectedLoad: nil),
            .block
        )
    }

    func testANonWebAddressIsBlocked() {
        let file = URL(string: "file:///etc/hosts")!
        XCTAssertEqual(
            FixtureNavigation.decide(url: file, isMainFrame: true, expectedLoad: nil),
            .block
        )
        let mail = URL(string: "mailto:someone@example.com")!
        XCTAssertEqual(
            FixtureNavigation.decide(url: mail, isMainFrame: true, expectedLoad: nil),
            .block
        )
        XCTAssertEqual(
            FixtureNavigation.decide(url: nil, isMainFrame: true, expectedLoad: nil),
            .block
        )
    }

    func testAnEmptyFrameIsAllowed() {
        let blank = URL(string: "about:blank")!
        XCTAssertEqual(
            FixtureNavigation.decide(url: blank, isMainFrame: false, expectedLoad: nil),
            .allow
        )
    }

    // MARK: - Navigation sealing (through the bridge)

    @MainActor
    func testClickingAResultLandsOnThatSitesFixture() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://search.test/?q=x")
        let clicked = try await bridge.run("document.querySelector('main a').click(); 'clicked'", in: tab)
        XCTAssertEqual(clicked, "clicked")
        try await bridge.waitForURL(URL(string: "https://site-1.test/")!, in: tab)
        let title = try await bridge.run("document.title", in: tab)
        XCTAssertEqual(title, "Site One")
        XCTAssertEqual(bridge.navigatedURLs, [URL(string: "https://site-1.test/")!])
    }

    @MainActor
    func testGoingToARealHostLandsOnTheNotFoundFixture() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://site-1.test/")
        let going = try await bridge.run("location.href = 'https://example.com/'; 'going'", in: tab)
        XCTAssertEqual(going, "going")
        try await bridge.waitForURL(URL(string: "https://example.com/")!, in: tab)
        let title = try await bridge.run("document.title", in: tab)
        XCTAssertEqual(title, "Not found")
    }

    @MainActor
    /// Any rejection would also pass after a real request failed (CORS, DNS,
    /// offline), so the test asks the page which rule refused it: a
    /// `connect-src` violation happens before a request exists.
    func testAPageCannotFetchFromTheNetwork() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://site-1.test/")
        let refusedBy = try await bridge.runAsync("""
            const violation = new Promise((resolve) => document.addEventListener(
              'securitypolicyviolation', (event) => resolve(event.effectiveDirective), { once: true }));
            try { await fetch('https://example.com/'); return 'reached'; } catch (error) {}
            return await Promise.race([violation, new Promise((resolve) => setTimeout(() => resolve('no violation'), 1000))]);
            """, in: tab)
        XCTAssertEqual(refusedBy, "connect-src")
    }

    @MainActor
    func testScriptsMustReturnText() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://site-1.test/")
        for script in ["true", "42", "({a: 1})"] {
            do {
                _ = try await bridge.run(script, in: tab)
                XCTFail("A script returning a non-string (\(script)) must be refused")
            } catch let error as WebViewBridgeError {
                if case .unsupportedResult = error {} else { XCTFail("Expected unsupportedResult, got \(error)") }
            }
        }
        let empty = try await bridge.run("null", in: tab)
        XCTAssertEqual(empty, "")
    }

    @MainActor
    func testARunThatOutlivesItsDeadlineTimesOut() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://site-1.test/")
        do {
            _ = try await bridge.run(
                "const t = Date.now(); while (Date.now() - t < 400) {} 'late'",
                in: tab,
                timeout: .milliseconds(50)
            )
            XCTFail("A script past its deadline must time out")
        } catch let error as BrowserBridgeError {
            XCTAssertEqual(error, .timedOut)
        }
        let ok = try await bridge.run("'ok'", in: tab)
        XCTAssertEqual(ok, "ok")
    }

    @MainActor
    func testTwoTabsAreIndependent() async throws {
        let bridge = WebViewBridge()
        let one = try await openLoaded(bridge, "https://site-1.test/")
        let two = try await openLoaded(bridge, "https://search.test/?q=x")
        let titleOne = try await bridge.run("document.title", in: one)
        let titleTwo = try await bridge.run("document.title", in: two)
        XCTAssertEqual(titleOne, "Site One")
        XCTAssertEqual(titleTwo, "Search results")
        try await bridge.closeTab(one)
        XCTAssertEqual(bridge.openTabCount, 1)
        let still = try await bridge.run("document.title", in: two)
        XCTAssertEqual(still, "Search results")
    }

    @MainActor
    /// Every fixture file, not just one, and the policy's content, not just
    /// its presence.
    func testEveryPageCarriesTheNetworkLock() async throws {
        let bridge = WebViewBridge()
        // site-13 stops its own load on purpose; it has its own test. site-85
        // answers `document.readyState` in its own world with 70 MB, which this
        // harness waits on there; the Chrome bridge, which asks in the agent's
        // own world, is tested on it.
        let files = try FileManager.default.contentsOfDirectory(atPath: FixtureRouter.pagesDirectory.path)
            .filter { $0.hasSuffix(".html") && $0 != "site-13.html" && $0 != "site-85.html" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let host = file == "search-results.html" ? "search.test"
                : file == "not-found.html" ? "nowhere.test"
                : file.replacingOccurrences(of: ".html", with: ".test")
            let tab = try await openLoaded(bridge, "https://\(host)/")
            let policy = try await bridge.run(
                "(document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]') || {}).content || ''",
                in: tab)
            XCTAssertTrue(policy.hasPrefix("default-src 'none';"), "\(file): \(policy)")
            let prefetch = try await bridge.run(
                "(document.querySelector('meta[http-equiv=\"x-dns-prefetch-control\"]') || {}).content || ''",
                in: tab)
            XCTAssertEqual(prefetch, "off", file)
            try await bridge.closeTab(tab)
        }
    }

    /// CSP does not cover speculative connections (`preconnect`,
    /// `dns-prefetch`); a content rule list blocking every load does.
    @MainActor
    func testEveryTabBlocksResourceLoads() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://site-1.test/")
        XCTAssertTrue(bridge.blocksNetworkLoads(in: tab))
        // The same rule list hides a canary element; seeing it hidden proves
        // the rules are active in this tab, not merely registered.
        let canary = try await bridge.run("""
            const probe = document.createElement('div');
            probe.className = 'mw-content-rules-canary';
            probe.textContent = 'canary';
            document.body.appendChild(probe);
            getComputedStyle(probe).display
            """, in: tab)
        XCTAssertEqual(canary, "none")
    }

    /// A page that stops its own load must end the wait, not leave it
    /// hanging until the deadline.
    @MainActor
    func testAStoppedLoadDoesNotHangTheWait() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-13.test/")!)
        let started = ContinuousClock.now
        // WebKit reports a stopped load as a cancelled navigation (−999),
        // verified with a probe on 2026-09-24.
        do {
            try await bridge.waitUntilLoaded(tab, timeout: .seconds(3))
            XCTFail("a stopped load must not pass for a loaded page")
        } catch let error as WebViewBridgeError {
            XCTAssertEqual(error, .navigationFailed(NSURLErrorCancelled))
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    /// Closing a tab while its script is still busy must not leave the caller
    /// waiting forever.
    @MainActor
    func testClosingATabSettlesItsPendingRun() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://site-1.test/")
        let started = ContinuousClock.now
        async let pending: String = bridge.run(
            "const t = Date.now(); while (Date.now() - t < 300) {} 'late'", in: tab, timeout: .seconds(1))
        try await bridge.closeTab(tab)
        _ = try? await pending
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    /// A wait cuts every script it runs to the time it has left, so a busy
    /// page cannot stretch it past its deadline.
    @MainActor
    func testAWaitNeverOverrunsItsDeadline() async throws {
        let bridge = WebViewBridge()
        let tab = try await openLoaded(bridge, "https://site-1.test/")
        _ = try await bridge.run(
            "setTimeout(() => { const t = Date.now(); while (Date.now() - t < 1500) {} }, 0); 'busy soon'",
            in: tab)
        try await Task.sleep(for: .milliseconds(50))
        let started = ContinuousClock.now
        do {
            try await bridge.waitForURL(URL(string: "https://site-1.test/")!, in: tab, timeout: .milliseconds(300))
            XCTFail("the page was busy past the deadline; the wait must not succeed late")
        } catch let error as BrowserBridgeError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(1000))
    }
}
