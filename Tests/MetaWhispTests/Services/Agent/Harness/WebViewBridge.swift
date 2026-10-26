import AppKit
import WebKit
@testable import MetaWhisp

/// What went wrong inside the test browser itself (ITER-074 §12.1).
enum WebViewBridgeError: Error, Equatable {
    /// A script returned something other than text; agent scripts return strings.
    case unsupportedResult(String)
    /// The page's navigation failed with this error code.
    case navigationFailed(Int)
    /// WebKit's web content process died.
    case contentProcessTerminated
}

/// One pure decision per navigation attempt, so the harness can seal itself
/// against the network without WebKit being involved in the decision.
enum FixtureNavigation: Equatable {
    /// Our own `loadHTMLString` for this address, or an empty frame.
    case allow
    /// A page asked to go to a web address: cancel it and load that
    /// address's fixture instead, so nothing reaches the network.
    case route(URL)
    /// Anything else: cancel and record it.
    case block

    /// The rules, in order: no address → block; our own load → allow; an
    /// empty `about:` frame → allow; any other frame → block; a web address
    /// in the main frame → route it to its fixture; everything else → block.
    static func decide(url: URL?, isMainFrame: Bool, expectedLoad: URL?) -> FixtureNavigation {
        guard let url else { return .block }
        if let expectedLoad, sameAddress(url, expectedLoad) { return .allow }
        if url.scheme?.lowercased() == "about" { return .allow }
        guard isMainFrame else { return .block }
        return DiaScript.isOpenable(url) ? .route(url) : .block
    }

    /// Two addresses are the same page when scheme, host, path and query
    /// match, ignoring case in the scheme and host and an empty path versus
    /// "/". WebKit may hand back our own load's address normalised; missing
    /// that would route our own load again and again.
    static func sameAddress(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String {
            let path = url.path.isEmpty ? "/" : url.path
            return [url.scheme?.lowercased() ?? "", url.host?.lowercased() ?? "", path, url.query ?? ""]
                .joined(separator: "\u{1F}")
        }
        return key(a) == key(b)
    }
}

/// Watches one tab's navigations: seals them through `FixtureNavigation` and
/// records how the latest load ended.
@MainActor
/// A page's alert, closed at once and heard as the Chrome bridge hears one (`BrowserEvent.dialog`, accepted): the brain
/// tests meet pages that answer an act with an alert alone (2026-10-21, blind b14).
private final class FixtureDialogs: NSObject, WKUIDelegate {
    var onAlert: (() -> Void)?

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        onAlert?()
        completionHandler()
    }
}

private final class FixtureNavigator: NSObject, WKNavigationDelegate {
    enum LoadState: Equatable { case loading, loaded, failed(Int), terminated }

    var state: LoadState = .loading
    /// The address of the `loadHTMLString` the bridge itself started.
    var expectedLoad: URL?
    /// The navigation that load started. Callbacks for any other navigation —
    /// a page's own attempt the bridge cancelled and routed — are ignored.
    var currentNavigation: WKNavigation?
    /// A page's navigation routed to its fixture, with the request the page made: a POST's form in its body.
    var onRoute: ((URL, URLRequest) -> Void)?
    var onBlock: ((URL?) -> Void)?
    /// The tab's sends are held (`BrowserBridge.holdSends`): a page's own
    /// navigation is refused, and said through `onHeld`, as Chrome's guard
    /// refuses it (ITER-076 stage 7, review round 1, C2) — but the agent's
    /// own, to an address it was told (`letGo`; review round 2, R2-2).
    var holding = false
    var letGo: Set<String> = []
    var onHeld: ((URL) -> Void)?

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let decision = FixtureNavigation.decide(
            url: url,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            expectedLoad: expectedLoad)
        switch decision {
        case .allow:
            if let url, let expected = expectedLoad, FixtureNavigation.sameAddress(url, expected) {
                expectedLoad = nil
                state = .loading
            }
            return .allow
        case .route(let target):
            if holding, !letGo.contains(ChromeBridge.navigation(target.absoluteString)) {
                onHeld?(target)
                return .cancel
            }
            // The replacement load starts after WebKit has taken the cancel.
            let request = navigationAction.request
            Task { @MainActor [weak self] in self?.onRoute?(target, request) }
            return .cancel
        case .block:
            onBlock?(url)
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === currentNavigation else { return }
        state = .loaded
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        record(error, for: navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        record(error, for: navigation)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        state = .terminated
    }

    /// Only the navigation the bridge started can fail the tab. A page's own
    /// navigation that the bridge cancelled and routed reports a cancellation
    /// too — that one is ignored; our own load being cancelled (a page calling
    /// `window.stop()`) is a real failure and ends the wait.
    private func record(_ error: Error, for navigation: WKNavigation!) {
        guard navigation === currentNavigation else { return }
        state = .failed((error as NSError).code)
    }
}

/// Resumes a continuation exactly once, whichever of the script's answer and
/// the deadline arrives first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<String, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// `BrowserBridge` over one `WKWebView` per tab, for tests (ITER-074 §12.1).
/// Pages come from `FixtureRouter`; nothing reaches the network: every page
/// carries a Content-Security-Policy that refuses all connections, and every
/// navigation a page starts is routed to the fixture for that address.
@MainActor
final class WebViewBridge: BrowserBridge {
    /// Every URL the agent asked to open, in order — tests assert on it.
    private(set) var openedURLs: [URL] = []
    /// Addresses pages tried to navigate to that were routed to fixtures.
    private(set) var navigatedURLs: [URL] = []
    /// Navigations that were refused.
    private(set) var blockedURLs: [URL] = []
    /// Navigations refused while a tab's sends were held.
    private(set) var heldURLs: [URL] = []
    /// The forms pages sent by POST, in order: where each went and its body as the page sent it (2026-10-21). The
    /// page that answers one is handed that body as `window.posted`, as a server renders what was posted.
    private(set) var sentForms: [(url: URL, body: String)] = []
    /// What each tab did on its own since it was last asked.
    private var pendingEvents: [BrowserTab: [BrowserEvent]] = [:]
    private var tabs: [BrowserTab: WKWebView] = [:]
    private var navigators: [BrowserTab: FixtureNavigator] = [:]
    private var dialogKeepers: [BrowserTab: FixtureDialogs] = [:]
    private var nextTabNumber = 1
    /// Each tab's history as a browser keeps it (ITER-076 I-10): every page
    /// the tab loaded, the one it shows, and the next entry's id. A load of
    /// the address the tab shows takes that entry's place; any other drops
    /// the entries after the one shown. WebKit's own list is not used: every
    /// page here is a load of the bridge's own.
    private var histories: [BrowserTab: (entries: [(id: Int, url: URL)], current: Int)] = [:]
    private var nextEntryID = 1

    /// How many tabs are still open — a finished errand must leave zero.
    var openTabCount: Int { tabs.count }

    /// The network lock put into every fixture page. `connect-src` falls back
    /// to `default-src 'none'`, so `fetch` and XHR are refused before a request
    /// exists; inline scripts and styles still run. DNS prefetching is switched
    /// off too, because CSP does not govern it.
    static let networkLock = """
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; \
    style-src 'unsafe-inline'; img-src data:"><meta http-equiv="x-dns-prefetch-control" content="off">
    """

    /// WebKit lists no navigation entry for a page loaded from a string, so
    /// each page gets one as Chrome lists it (ITER-076 I-10): the address the
    /// page was loaded at — read before any of its own scripts runs, so its
    /// history calls never change it.
    static let loadedFrom = """
    (() => {
      const loaded = String(location.href);
      const listed = performance.getEntriesByType.bind(performance);
      performance.getEntriesByType = (type) => {
        const entries = listed(type);
        return type === 'navigation' && entries.length === 0 ? [{ name: loaded }] : entries;
      };
    })();
    """

    /// Every tab also gets a content rule list that blocks every load: CSP
    /// does not cover speculative connections such as `<link rel=preconnect>`,
    /// content rules do. Compiled once per test process.
    private static var blockEverything: WKContentRuleList?
    private var tabsWithBlockRules: Set<BrowserTab> = []

    private static func networkBlockRules() async throws -> WKContentRuleList {
        if let blockEverything { return blockEverything }
        // The second rule hides a canary element, so a test can see that the
        // list is active in a tab, not merely registered.
        let rules = #"""
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".mw-content-rules-canary"}}]
        """#
        guard let list = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "metawhisp-agent-tests-block-all", encodedContentRuleList: rules) else {
            throw BrowserBridgeError.scriptFailed(code: -1)
        }
        blockEverything = list
        return list
    }

    /// Refuses non-web addresses before any bookkeeping, so a dangerous
    /// scheme never even reaches a page (spec §6.2). The fixture's HTML is
    /// loaded at the address it plays, so the page's own `location.href` and
    /// relative links behave like the real site's.
    func openTab(_ url: URL) async throws -> BrowserTab {
        guard DiaScript.isOpenable(url) else { throw BrowserBridgeError.notOpenable(url) }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(try await Self.networkBlockRules())
        configuration.userContentController.addUserScript(WKUserScript(source: Self.loadedFrom,
                                                                       injectionTime: .atDocumentStart,
                                                                       forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        let tab = BrowserTab(windowID: "test-window", tabID: "tab-\(nextTabNumber)")
        nextTabNumber += 1

        let navigator = FixtureNavigator()
        navigator.onRoute = { [weak self] target, request in self?.route(target, request: request, in: tab) }
        navigator.onBlock = { [weak self] target in
            if let target { self?.blockedURLs.append(target) }
        }
        navigator.onHeld = { [weak self] target in
            self?.heldURLs.append(target)
            if self?.pendingEvents[tab]?.contains(.sendHeld) != true { self?.pendingEvents[tab, default: []].append(.sendHeld) }
        }
        let dialogs = FixtureDialogs()
        dialogs.onAlert = { [weak self] in self?.pendingEvents[tab, default: []].append(.dialog(.alert, accepted: true)) }
        // WebKit holds its delegates weakly; `navigators` and `dialogKeepers` keep them alive.
        web.navigationDelegate = navigator
        web.uiDelegate = dialogs
        tabs[tab] = web
        navigators[tab] = navigator
        dialogKeepers[tab] = dialogs
        tabsWithBlockRules.insert(tab)
        openedURLs.append(url)
        try load(url, into: tab)
        return tab
    }

    func isLoading(_ tab: BrowserTab) async throws -> Bool {
        guard let web = tabs[tab] else { throw BrowserBridgeError.tabNotFound }
        return web.isLoading
    }

    /// Runs with the default five-second deadline.
    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await run(javascript, in: tab, timeout: .seconds(5))
    }

    /// The async overload of `evaluateJavaScript` traps when the script
    /// returns `undefined`, so the completion-handler form is wrapped by hand.
    /// A script that outlives `timeout` fails with `.timedOut`; its late answer
    /// is dropped.
    func run(_ javascript: String, in tab: BrowserTab, timeout: Duration) async throws -> String {
        guard let web = tabs[tab] else { throw BrowserBridgeError.tabNotFound }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                once.resume(with: .failure(BrowserBridgeError.timedOut))
            }
            web.evaluateJavaScript(javascript) { result, error in
                once.resume(with: Self.text(from: result, error: error))
                timer.cancel()
            }
        }
    }

    /// Runs an expression whose value is a promise, and returns what it
    /// resolves to — as Chrome's evaluation does (ITER-076 I-07): the body of
    /// an async function that awaits it. WebKit's own evaluation cannot.
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await runAsync("return await (\n" + javascript + "\n);", in: tab)
    }

    /// Runs `body` as the body of an async function (WKWebView
    /// `callAsyncJavaScript`), so it may `await`; same result rules and the
    /// same five-second deadline as `run`.
    func runAsync(_ body: String, in tab: BrowserTab) async throws -> String {
        guard let web = tabs[tab] else { throw BrowserBridgeError.tabNotFound }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let timer = Task {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                once.resume(with: .failure(BrowserBridgeError.timedOut))
            }
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): once.resume(with: Self.text(from: value, error: nil))
                case .failure(let error): once.resume(with: Self.text(from: nil, error: error))
                }
                timer.cancel()
            }
        }
    }

    /// Whether the tab's web view was built with the block-everything rules.
    func blocksNetworkLoads(in tab: BrowserTab) -> Bool { tabsWithBlockRules.contains(tab) }

    /// A page's own navigations are refused while held, as Chrome's guard
    /// refuses every document a held tab asks for (ITER-076 stage 7, review
    /// round 1, C2).
    func holdSends(_ held: Bool, in tab: BrowserTab) async -> Bool {
        guard let navigator = navigators[tab] else { return false }
        navigator.holding = held
        if !held { navigator.letGo = [] }
        return true
    }

    func letNavigate(to address: String, in tab: BrowserTab) {
        guard let navigator = navigators[tab], navigator.holding else { return }
        navigator.letGo.insert(ChromeBridge.navigation(address))
    }

    func events(in tab: BrowserTab) -> [BrowserEvent] {
        defer { pendingEvents[tab] = nil }
        return pendingEvents[tab] ?? []
    }

    func history(of tab: BrowserTab) async throws -> BrowserHistory {
        guard tabs[tab] != nil else { throw BrowserBridgeError.tabNotFound }
        let kept = histories[tab] ?? (entries: [], current: 0)
        return BrowserHistory(entries: kept.entries.map { .init(id: $0.id, url: $0.url.absoluteString, sentForm: false) },
                              current: kept.current)
    }

    /// Loads the entry's page again, as a browser that kept nothing of it
    /// does, and recorded as a navigation to it.
    func goBack(to entry: Int, in tab: BrowserTab) async throws {
        guard tabs[tab] != nil else { throw BrowserBridgeError.tabNotFound }
        guard var kept = histories[tab], let index = kept.entries.firstIndex(where: { $0.id == entry }) else {
            throw BrowserBridgeError.scriptFailed(code: -1)
        }
        kept.current = index
        histories[tab] = kept
        navigatedURLs.append(kept.entries[index].url)
        try load(kept.entries[index].url, into: tab, traversing: true)
    }

    func closeTab(_ tab: BrowserTab) async throws {
        guard let web = tabs.removeValue(forKey: tab) else { throw BrowserBridgeError.tabNotFound }
        histories[tab] = nil
        web.stopLoading()
        web.navigationDelegate = nil
        navigators[tab] = nil
        tabsWithBlockRules.remove(tab)
    }

    /// Waits until the tab's latest navigation finished and the document is
    /// complete. A failed navigation or a dead content process ends the wait
    /// with that error instead of passing for a loaded page.
    func waitUntilLoaded(_ tab: BrowserTab, timeout: Duration = .seconds(10)) async throws {
        try await waitUntil(tab, timeout: timeout) { _ in true }
    }

    /// Like `waitUntilLoaded`, and the tab must also show `url` — the way to
    /// wait for a navigation a click started.
    func waitForURL(_ url: URL, in tab: BrowserTab, timeout: Duration = .seconds(10)) async throws {
        try await waitUntil(tab, timeout: timeout) { href in href == url.absoluteString }
    }

    // MARK: - Private

    /// Agent scripts return text: a string is itself, `undefined` / `null`
    /// are empty, anything else is an error — Dia would turn it into text in
    /// its own way, so tests must not depend on one.
    nonisolated private static func text(from result: Any?, error: Error?) -> Result<String, Error> {
        if let error {
            return .failure(BrowserBridgeError.scriptFailed(code: (error as NSError).code))
        }
        switch result {
        case nil:
            return .success("")
        case is NSNull:
            return .success("")
        case let text as String:
            return .success(text)
        case let other?:
            return .failure(WebViewBridgeError.unsupportedResult(String(describing: type(of: other))))
        }
    }

    private func route(_ url: URL, request: URLRequest, in tab: BrowserTab) {
        navigatedURLs.append(url)
        let posted = request.httpMethod?.uppercased() == "POST"
            ? request.httpBody.flatMap { String(data: $0, encoding: .utf8) } : nil
        if let posted { sentForms.append((url, posted)) }
        try? load(url, into: tab, posted: posted)
    }

    private func load(_ url: URL, into tab: BrowserTab, traversing: Bool = false, posted: String? = nil) throws {
        guard let web = tabs[tab], let navigator = navigators[tab] else {
            throw BrowserBridgeError.tabNotFound
        }
        if !traversing {
            var kept = histories[tab] ?? (entries: [], current: -1)
            if kept.entries.indices.contains(kept.current),
               FixtureNavigation.sameAddress(kept.entries[kept.current].url, url) {
                kept.entries[kept.current] = (id: nextEntryID, url: url)
            } else {
                kept.entries = Array(kept.entries.prefix(kept.current + 1)) + [(id: nextEntryID, url: url)]
                kept.current = kept.entries.count - 1
            }
            nextEntryID += 1
            histories[tab] = kept
        }
        let html = Self.sealed(try FixtureRouter.html(for: url), posted: posted)
        navigator.expectedLoad = url
        navigator.state = .loading
        navigator.currentNavigation = web.loadHTMLString(html, baseURL: url)
    }

    /// Puts the network lock right after `<head>`, or in front of the page if
    /// it has none — and, for the page a POST brought, the form it was sent:
    /// `window.posted`, before any script of the page's.
    private static func sealed(_ html: String, posted: String? = nil) -> String {
        let quoted = posted.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        let lock = networkLock + (quoted.map { "<script>window.posted = \($0);</script>" } ?? "")
        guard let head = html.range(of: "<head>", options: .caseInsensitive) else {
            return lock + html
        }
        var copy = html
        copy.insert(contentsOf: lock, at: head.upperBound)
        return copy
    }

    /// Every script the wait runs gets only the time the wait has left, so a
    /// busy page cannot stretch the wait past its deadline, and a success that
    /// arrives after the deadline does not count.
    private func waitUntil(_ tab: BrowserTab, timeout: Duration,
                           accept: (String) -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        func remaining() -> Duration { deadline - clock.now }
        while remaining() > .zero {
            guard let navigator = navigators[tab] else { throw BrowserBridgeError.tabNotFound }
            switch navigator.state {
            case .failed(let code):
                throw WebViewBridgeError.navigationFailed(code)
            case .terminated:
                throw WebViewBridgeError.contentProcessTerminated
            case .loading:
                break
            case .loaded:
                if navigator.expectedLoad == nil {
                    let ready = try await run("document.readyState", in: tab,
                                              timeout: min(remaining(), .seconds(5)))
                    if ready == "complete" {
                        let href = try await run("location.href", in: tab,
                                                 timeout: min(remaining(), .seconds(5)))
                        if accept(href), remaining() > .zero { return }
                    }
                }
            }
            try await Task.sleep(for: min(.milliseconds(20), max(remaining(), .zero)))
        }
        throw BrowserBridgeError.timedOut
    }
}
