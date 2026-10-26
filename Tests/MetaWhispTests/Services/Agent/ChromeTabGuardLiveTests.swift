import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 I-09 — the agent's tab, guarded, in a real Chrome (headless, a
/// profile of its own, the fixture pages served from inside Chrome): it never
/// reaches the user's own machine or network, it saves no file, the page's
/// own dialogs never hold it up or answer for the user, and it is marked as
/// the agent's. The user's own tabs are never touched. Ported from a
/// reference browser agent (MIT). Skipped without Chrome.
final class ChromeTabGuardLiveTests: XCTestCase {

    // MARK: - Helpers

    /// A person's click on the control the page names `name`.
    @MainActor
    private func press(_ name: String, on page: ObservedPage, in tab: BrowserTab, _ world: ChromeWorld) async throws {
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: name), on: page), in: tab)
        XCTAssertEqual(aim.outcome, .aim, name)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
    }

    /// What the tab did on its own, gathered until `enough` holds or the time
    /// is up — 10 s, where a second is plenty.
    @MainActor
    private func events(in tab: BrowserTab, _ world: ChromeWorld, seconds: Double = 10,
                        until enough: ([BrowserEvent]) -> Bool) async throws -> [BrowserEvent] {
        var seen: [BrowserEvent] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            seen += world.bridge.events(in: tab)
            if enough(seen) { return seen }
            try await Task.sleep(for: .milliseconds(50))
        }
        return seen
    }

    /// Where the tab's page is, read in its own world.
    @MainActor
    private func address(of tab: BrowserTab, _ world: ChromeWorld) async throws -> String {
        try await world.bridge.runInPage("location.href", in: tab)
    }

    // MARK: - No private address (owner decision D7)

    /// The plan's addresses: none on the user's machine or network is ever
    /// opened, and no tab is left.
    @MainActor
    func testThePlanNeverOpensAPrivateAddress() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for address in ["http://192.168.1.1", "http://router.local", "http://localhost:8080", "http://[::1]/",
                        "http://10.0.0.5", "http://100.64.0.1", "http://169.254.169.254/", "http://intranet/",
                        "http://0x7f000001/"] {
            do {
                _ = try await world.bridge.openTab(URL(string: address)!)
                XCTFail("opened \(address)")
            } catch let error as BrowserBridgeError {
                XCTAssertEqual(error, .notOpenable(URL(string: address)!), address)
            }
        }
        let tabs = try await world.agentTabCount()
        XCTAssertEqual(tabs, 0)
    }

    /// A public page that sends the tab home — a person's click on a link, a
    /// redirect, the page's own `location =` — is stopped at the request: the
    /// tab stays where it was, nothing reached the address, and the refusal
    /// is told.
    @MainActor
    func testANavigationToAPrivateAddressIsStoppedAtTheRequest() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-190.test/")
        try await press("Open the router", on: page, in: tab, world)
        var seen = try await events(in: tab, world) { $0.contains(.addressRefused) }
        XCTAssertEqual(seen, [.addressRefused], "a person's click")
        _ = try await world.bridge.run("location.assign('https://site-190.test/redirect?to=http%3A%2F%2F127.0.0.1%3A9%2Fadmin'), 'x'",
                                       in: tab)
        seen = try await events(in: tab, world) { $0.contains(.addressRefused) }
        XCTAssertEqual(seen, [.addressRefused], "a redirect")
        let again = try ObservedPage.decode(try await world.bridge.run(ObserverScript.source, in: tab))
        try await press("Go home", on: again, in: tab, world)
        seen = try await events(in: tab, world) { $0.contains(.addressRefused) }
        XCTAssertEqual(seen, [.addressRefused], "the page's location =")
        try await Task.sleep(for: .milliseconds(300))
        let now = try await address(of: tab, world)
        XCTAssertEqual(now, "https://site-190.test/", "the tab stays where it was")
        XCTAssertFalse(world.fixtures.blocked.contains { $0.contains("127.0.0.1") || $0.contains("192.168.") },
                       "no request went out: \(world.fixtures.blocked)")
        XCTAssertTrue(world.fixtures.served.contains { $0.path == "/redirect" }, "the public redirect itself was asked")
    }

    /// A page that sends itself home as it loads is stopped at the request.
    @MainActor
    func testAMetaRefreshToLoopbackIsStoppedAtTheRequest() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let tab = try await world.bridge.openTab(URL(string: "https://site-191.test/")!)
        let seen = try await events(in: tab, world) { $0.contains(.addressRefused) }
        XCTAssertEqual(seen, [.addressRefused])
        try await Task.sleep(for: .milliseconds(300))
        let now = try await address(of: tab, world)
        XCTAssertEqual(now, "https://site-191.test/")
        XCTAssertFalse(world.fixtures.blocked.contains { $0.contains("127.0.0.1") })
    }

    /// A frame of the page at an address on the user's network is a
    /// document the tab asks for: never loaded.
    @MainActor
    func testAFrameAtAPrivateAddressIsNeverLoaded() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let tab = try await world.bridge.openTab(URL(string: "https://site-192.test/")!)
        let seen = try await events(in: tab, world) { $0.contains(.addressRefused) }
        XCTAssertEqual(seen, [.addressRefused])
        XCTAssertFalse(world.fixtures.blocked.contains { $0.contains("10.0.0.5") })
    }

    /// What the page itself fetches is the page's own, and not filtered:
    /// here it reaches the fixtures, which refuse every address that is no
    /// test site. DNS rebinding — a public name that resolves to a private
    /// address — is not seen by a check of names.
    @MainActor
    func testWhatAPageFetchesItselfIsNotFiltered() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-190.test/")
        try await press("Ping home", on: page, in: tab, world)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !world.fixtures.blocked.contains("http://127.0.0.1:9/ping") {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(world.fixtures.blocked.contains("http://127.0.0.1:9/ping"))
        XCTAssertEqual(world.bridge.events(in: tab), [])
    }

    /// A name reserved for a private network is the user's network, as a
    /// `.local` name is: the plan never opens it, and a public page that
    /// sends the tab there is stopped at the request (ITER-076 I-09 review,
    /// NET-3).
    @MainActor
    func testANameReservedForPrivateNetworksIsNeverReached() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for address in ["http://router.home.arpa/", "http://nas.internal/", "http://bthomehub.home/",
                        "http://intranet.corp/", "http://mx.mail/"] {
            do {
                _ = try await world.bridge.openTab(URL(string: address)!)
                XCTFail("opened \(address)")
            } catch let error as BrowserBridgeError {
                XCTAssertEqual(error, .notOpenable(URL(string: address)!), address)
            }
        }
        let (tab, _) = try await world.open("https://site-1.test/")
        for name in ["nas.internal", "router.home.arpa", "bthomehub.home"] {
            _ = try await world.bridge.run(
                "location.assign('https://site-1.test/redirect?to=http%3A%2F%2F\(name)%2F'), 'x'", in: tab)
            // Chrome may first ask for the https form of the address, then
            // the http one: each is refused.
            let seen = try await events(in: tab, world) { $0.contains(.addressRefused) }
            XCTAssertTrue(!seen.isEmpty && seen.allSatisfy { $0 == .addressRefused }, "\(name): \(seen)")
        }
        try await Task.sleep(for: .milliseconds(300))
        let late = world.bridge.events(in: tab)
        XCTAssertTrue(late.allSatisfy { $0 == .addressRefused }, "\(late)")
        let now = try await address(of: tab, world)
        XCTAssertEqual(now, "https://site-1.test/", "the tab stays where it was")
        XCTAssertFalse(world.fixtures.blocked.contains { $0.contains(".internal") || $0.contains(".home") },
                       "no request went out: \(world.fixtures.blocked)")
    }

    // MARK: - No private address, whatever name leads there (ITER-076 stage 9e, № 104)

    /// What the Mac's resolver answers in these tests: a home router's name,
    /// a name built around a private address, a name with a public address
    /// and a private one — the public one first — a work name a VPN answers
    /// in 10.x, written as IPv6 maps it, a name on the link alone, a test
    /// site at a public address; any other name does not exist. One name it
    /// never answers.
    private static let answers: [String: [String]] = [
        "fritz.box": ["192.168.178.1"],
        "192.168.1.1.nip.io": ["192.168.1.1"],
        "printer.example.com": ["93.184.215.14", "192.168.178.1"],
        "vpn.example.com": ["::ffff:10.0.0.1"],
        "nas.example.com": ["fe80::1"],
        "site-1.test": ["93.184.215.14"],
    ]

    private static let resolver: ChromeBridge.Resolver = { host in
        if host == "slow.example.com" { try? await Task.sleep(for: .seconds(60)) }
        return answers[host] ?? []
    }

    /// A public name the Mac's own resolver answers with an address on the
    /// user's machine or network is refused at its request, exactly as that
    /// address is (owner decision D7): one private address among public ones
    /// is enough. Nothing reaches it.
    @MainActor
    func testANameTheMacsResolverLeadsHomeIsRefusedAtItsRequest() async throws {
        let world = try await ChromeWorld.start(resolve: Self.resolver)
        defer { world.stop() }
        for host in ["fritz.box", "192.168.1.1.nip.io", "printer.example.com", "vpn.example.com", "nas.example.com"] {
            let tab = try await world.bridge.openTab(URL(string: "https://\(host)/")!)
            let seen = try await events(in: tab, world) { $0.contains(.addressRefused) }
            XCTAssertEqual(seen, [.addressRefused], host)
            try await world.bridge.closeTab(tab)
        }
        XCTAssertEqual(world.fixtures.blocked, [], "no request went out")
        XCTAssertEqual(world.fixtures.served, [], "no request went out")
    }

    /// A public page that redirects the tab to such a name: the redirect
    /// itself is asked for, the request it makes is refused, and the tab
    /// stays where it was.
    @MainActor
    func testARedirectToANameThatLeadsHomeIsRefusedAtItsRequest() async throws {
        let world = try await ChromeWorld.start(resolve: Self.resolver)
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-1.test/")
        _ = try await world.bridge.run(
            "location.assign('https://site-1.test/redirect?to=https%3A%2F%2Ffritz.box%2F'), 'x'", in: tab)
        let seen = try await events(in: tab, world) { $0.contains(.addressRefused) }
        XCTAssertEqual(seen, [.addressRefused])
        try await Task.sleep(for: .milliseconds(300))
        let now = try await address(of: tab, world)
        XCTAssertEqual(now, "https://site-1.test/", "the tab stays where it was")
        XCTAssertTrue(world.fixtures.served.contains { $0.path == "/redirect" }, "the public redirect itself was asked")
        XCTAssertFalse(world.fixtures.blocked.contains { $0.contains("fritz.box") }, "\(world.fixtures.blocked)")
    }

    /// A name the Mac's resolver does not answer in time is refused: no page
    /// goes on unseen. The refusal comes at the guard's bound, not when the
    /// resolver is done.
    @MainActor
    func testANameTheMacsResolverDoesNotAnswerInTimeIsRefused() async throws {
        let world = try await ChromeWorld.start(resolve: Self.resolver)
        defer { world.stop() }
        let tab = try await world.bridge.openTab(URL(string: "https://slow.example.com/")!)
        let seen = try await events(in: tab, world) { $0.contains(.addressRefused) }
        XCTAssertEqual(seen, [.addressRefused])
        XCTAssertEqual(world.fixtures.blocked, [], "never let go on")
    }

    /// The guard refuses no more than that: a name answered with public
    /// addresses only, and a name the resolver says does not exist, go on —
    /// their pages are drawn.
    @MainActor
    func testANamePublicOrUnknownToTheMacsResolverGoesOn() async throws {
        let world = try await ChromeWorld.start(resolve: Self.resolver)
        defer { world.stop() }
        for (address, title) in [("https://site-1.test/", "Site One"), ("https://site-2.test/", "Site Two")] {
            let (tab, page) = try await world.open(address)
            XCTAssertEqual(page.title, title, address)
            XCTAssertEqual(world.bridge.events(in: tab), [], address)
        }
    }

    /// DNS rebinding in a real Chrome: Chrome itself takes `rebind.test` and
    /// `open.test` to a server on this Mac's loopback. With the Mac's
    /// resolver answering `rebind.test` with the loopback address, an errand
    /// that starts there sends the server no byte of a request, and the run
    /// reads the refusal; with it answering `open.test` with a public
    /// address, that page is drawn from the same server. Chrome may open a
    /// bare connection to where a navigation leads as it starts, before any
    /// request — two, and closes them unused, on Chrome 154 (2026-10-06) —
    /// as it does for a private address written out: no request goes on it.
    @MainActor
    func testANameThatResolvesHomeNeverReachesItsServerAndAPublicOneIsDrawn() async throws {
        let body = "<title>Open</title><p>Open</p>"
        let server = try await HeldPort.start(answering: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n" + body)
        defer { server.stop() }
        let chrome = try await TestChrome.launch(arguments: [
            "--host-resolver-rules=MAP rebind.test 127.0.0.1, MAP open.test 127.0.0.1",
        ])
        let connection = CDPConnection(url: chrome.endpoint.webSocketURL)
        try await connection.open()
        defer {
            Task { await connection.close() }
            chrome.quit()
        }
        let answers = ["rebind.test": ["127.0.0.1"], "open.test": ["93.184.215.14"]]
        let bridge = ChromeBridge(connection: connection, resolve: { answers[$0] ?? [] })
        let (engine, _) = Self.engine([])
        let record = await AgentRun(plan: try plan("http://rebind.test:\(server.port)/"), errandID: UUID(),
                                    collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                         sheet: FixtureSheet(), confirm: { _ in .no })).run()
        XCTAssertTrue(record.events.contains(.addressRefused), "\(record.eventLines)")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(server.heard, 0, "the server never saw a request")
        let tab = try await bridge.openTab(URL(string: "http://open.test:\(server.port)/")!)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, (try? await bridge.run("document.readyState", in: tab)) != "complete" {
            try await Task.sleep(for: .milliseconds(50))
        }
        let title = try await bridge.run("document.title", in: tab)
        XCTAssertEqual(title, ChromeBridge.tabMark + "Open", "drawn")
        XCTAssertGreaterThan(server.heard, 0, "from the server")
        XCTAssertEqual(bridge.events(in: tab), [])
        try await bridge.closeTab(tab)
    }

    // MARK: - No download

    /// Every way a page has to save a file is refused in the agent's tab,
    /// and the page stays where it was. An answer that says it is a file —
    /// an attachment, a type no page is drawn from — is refused before
    /// Chrome begins to save it: no download of it begins, and nothing is
    /// saved. A download the page starts itself — a `download` link, a data
    /// or blob address — never begins at all: the agent's tab draws no page
    /// allowed one (ITER-076 I-10), so there is nothing to refuse or cancel
    /// (the race Claude review c7 of I-09, #22, names is gone).
    @MainActor
    func testADownloadInTheAgentsTabIsRefusedAndNothingIsSaved() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-193.test/")
        let begun = Box<[String]>()
        begun.value = []
        let stream = await world.connection.events()
        let watching = Task {
            for await event in stream where event.method == "Page.downloadWillBegin" {
                begun.value = (begun.value ?? []) + [event.params["guid"]?.string ?? "?"]
            }
        }
        defer { watching.cancel() }
        for (name, refused) in [("The report", true), ("The data", true), ("The notes", false), ("The words", false),
                                ("The made file", false)] {
            try await press(name, on: page, in: tab, world)
            let seen = try await events(in: tab, world, seconds: refused ? 10 : 1) { $0.contains(.downloadRefused) }
            XCTAssertEqual(seen, refused ? [.downloadRefused] : [], name)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(begun.value ?? [], [], "\(name): never begun")
        }
        try await Task.sleep(for: .milliseconds(500))
        let saved = try FileManager.default.contentsOfDirectory(atPath: world.chrome.downloads.path)
        XCTAssertEqual(saved, [], "nothing saved")
        let now = try await address(of: tab, world)
        XCTAssertEqual(now, "https://site-193.test/")
    }

    /// An answer Chrome would save rather than draw — an image of a type it
    /// does not draw, a disposition it takes for an attachment, a misspelt
    /// one or a form's part, a PDF — is refused as it comes, before Chrome
    /// begins to save it: no download of it ever begins, nothing is saved,
    /// and the page stays where it was (Claude review c7 of I-09, #8).
    @MainActor
    func testAnAnswerChromeWouldSaveIsRefusedBeforeItBegins() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-210.test/")
        let began = Counter()
        let stream = await world.connection.events()
        let watching = Task {
            for await event in stream where event.method == "Page.downloadWillBegin" { began.add() }
        }
        defer { watching.cancel() }
        for file in ["scan.tif?type=image%2Ftiff", "page.html?type=text%2Fhtml&disposition=attachement",
                     "part.html?type=text%2Fhtml&disposition=form-data%3B%20name%3Dx",
                     "terms.pdf?type=application%2Fpdf",
                     // A second type after a drawn one's parameters: Chrome takes the last (Claude review c8 of
                     // I-09, #27).
                     "mixed.html?type=text%2Fhtml%3B%20charset%3Dutf-8%2C%20application%2Foctet-stream"] {
            _ = try await world.bridge.run("location.assign('https://site-210.test/files/\(file)'), 'x'", in: tab)
            let seen = try await events(in: tab, world) { $0.contains(.downloadRefused) }
            XCTAssertEqual(seen, [.downloadRefused], file)
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(began.value, 0, "no download ever began")
        let saved = try FileManager.default.contentsOfDirectory(atPath: world.chrome.downloads.path)
        XCTAssertEqual(saved, [], "nothing saved")
        let now = try await address(of: tab, world)
        XCTAssertEqual(now, "https://site-210.test/")
    }

    /// A page sent inline under a file name is a page: drawn as its type says, never refused (2026-10-19: a hosting
    /// service names a file on every page it serves, and a contact page was refused as a download on every brain).
    @MainActor
    func testAPageSentInlineUnderAFileNameIsDrawn() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-210.test/")
        let page = "https://site-210.test/files/contact?type=text%2Fhtml%3B%20charset%3Dutf-8"
            + "&disposition=inline%3B%20filename%3D%22contact%22"
        _ = try await world.bridge.run("location.assign('\(page)'), 'x'", in: tab)
        let deadline = Date().addingTimeInterval(10)
        var now = try await address(of: tab, world)
        while now != page, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            now = try await address(of: tab, world)
        }
        XCTAssertEqual(now, page, "the page opened")
        XCTAssertFalse(world.bridge.events(in: tab).contains(.downloadRefused), "\(world.bridge.events(in: tab))")
    }

    /// The user's own tabs are not the agent's: a tab the bridge did not open
    /// saves its download as it always does.
    @MainActor
    func testTheUsersOwnTabStillDownloads() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        _ = try await world.open("https://site-193.test/")
        let created = try await world.connection.send("Target.createTarget", params: ["url": "about:blank"])
        let target = try XCTUnwrap(created["targetId"]?.string)
        let attached = try await world.connection.send("Target.attachToTarget",
                                                       params: ["targetId": .string(target), "flatten": true])
        let session = try XCTUnwrap(attached["sessionId"]?.string)
        try await world.fixtures.serve(session)
        _ = try await world.connection.send("Page.navigate", params: [
            "url": "https://site-193.test/files/report.pdf?type=application%2Fpdf&attachment=1"], sessionID: session)
        let deadline = Date().addingTimeInterval(10)
        var saved: [String] = []
        while Date() < deadline {
            saved = try FileManager.default.contentsOfDirectory(atPath: world.chrome.downloads.path)
            if saved.contains("report.pdf") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(saved, ["report.pdf"])
    }

    /// The user's own tabs are not the agent's: a tab the bridge did not open
    /// reaches the user's own network as it always does — its router's page,
    /// at a private address the agent's tab never opens. The guard decides
    /// none of its requests, even while the agent's tab is open (part B of
    /// I-09 review round 3: the guard's rule on the user's tabs had no test).
    @MainActor
    func testTheUsersOwnTabStillReachesTheirOwnNetwork() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (agents, _) = try await world.open("https://site-190.test/")
        let created = try await world.connection.send("Target.createTarget", params: ["url": "about:blank"])
        let target = try XCTUnwrap(created["targetId"]?.string)
        let attached = try await world.connection.send("Target.attachToTarget",
                                                       params: ["targetId": .string(target), "flatten": true])
        let session = try XCTUnwrap(attached["sessionId"]?.string)
        // The user's router answers — a moment later, as a device on their
        // network does.
        let connection = world.connection
        let paused = await connection.events()
        let router = Task {
            for await event in paused where event.method == "Fetch.requestPaused" && event.sessionID == session {
                guard let request = event.params["requestId"]?.string else { continue }
                try? await Task.sleep(for: .milliseconds(300))
                _ = try? await connection.send("Fetch.fulfillRequest", params: [
                    "requestId": .string(request), "responseCode": 200,
                    "responseHeaders": [["name": "Content-Type", "value": "text/html"]],
                    "body": .string(Data("<title>Router</title>".utf8).base64EncodedString()),
                ], sessionID: session)
            }
        }
        defer { router.cancel() }
        _ = try await world.connection.send("Fetch.enable", params: ["patterns": [["urlPattern": "*"]]],
                                            sessionID: session)
        _ = try await world.connection.send("Page.navigate", params: ["url": "http://127.0.0.1:9/router"],
                                            sessionID: session, timeout: .seconds(10))
        let deadline = Date().addingTimeInterval(10)
        var title: String?
        while Date() < deadline {
            let reply = try? await world.connection.send("Runtime.evaluate", params: [
                "expression": "location.href + ' ' + document.title", "returnByValue": true,
            ], sessionID: session)
            title = reply?["result"]?["value"]?.string
            if title == "http://127.0.0.1:9/router Router" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(title, "http://127.0.0.1:9/router Router", "the user's own tab reached their router")
        XCTAssertEqual(world.bridge.events(in: agents), [], "the guard refused nothing of the user's")
    }

    /// An answer of a type no page is drawn from — a disk image, a type no
    /// one knows — is refused as it comes, before Chrome begins to save it:
    /// no download of it ever begins, the folder Chrome saves to stays empty,
    /// and the page stays where it was. A type Chrome draws still opens
    /// (ITER-076 I-09 review, NET-2).
    @MainActor
    func testAnAnswerOfATypeNoPageIsDrawnFromIsRefusedBeforeItBegins() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-210.test/")
        let began = Counter()
        let stream = await world.connection.events()
        let watching = Task {
            for await event in stream where event.method == "Page.downloadWillBegin" { began.add() }
        }
        defer { watching.cancel() }
        for name in ["The disk image", "The unknown file"] {
            try await press(name, on: page, in: tab, world)
            let seen = try await events(in: tab, world) { $0.contains(.downloadRefused) }
            XCTAssertEqual(seen, [.downloadRefused], name)
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(began.value, 0, "no download ever began")
        let saved = try FileManager.default.contentsOfDirectory(atPath: world.chrome.downloads.path)
        XCTAssertEqual(saved, [], "nothing saved")
        let now = try await address(of: tab, world)
        XCTAssertEqual(now, "https://site-210.test/")
        try await press("The listing", on: page, in: tab, world)
        try await world.waitUntilPageIs("/files/list.json complete", in: tab)
        XCTAssertEqual(world.bridge.events(in: tab), [], "a page Chrome draws is no download")
    }

    /// A document whose request failed on its way got no answer: it is no
    /// download, and nothing is refused.
    @MainActor
    func testADocumentWhoseRequestFailedIsNoDownload() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-210.test/")
        try await press("Elsewhere", on: page, in: tab, world)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !world.fixtures.blocked.contains("https://elsewhere.example/") {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(world.fixtures.blocked.contains("https://elsewhere.example/"), "asked, and failed")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(world.bridge.events(in: tab), [])
    }

    // MARK: - The guard lives as long as the tab (ITER-076 I-09 review, NET-4)

    /// Chrome behind a proxy that can keep a call from it, and the fixture
    /// pages, with no bridge: each test makes its own and lets go of it.
    @MainActor
    private struct Rig {
        let chrome: TestChrome
        let proxy: CDPProxy
        let connection: CDPConnection
        let fixtures: ChromeFixtures

        static func start() async throws -> Rig {
            let chrome = try await TestChrome.launch()
            let proxy = try await CDPProxy.start(to: chrome.endpoint.webSocketURL)
            let connection = CDPConnection(url: proxy.url)
            try await connection.open()
            let fixtures = ChromeFixtures(connection: connection)
            await fixtures.start()
            return Rig(chrome: chrome, proxy: proxy, connection: connection, fixtures: fixtures)
        }

        func stop() {
            fixtures.stop()
            let connection = connection
            Task { await connection.close() }
            proxy.stop()
            chrome.quit()
        }

        /// What the tab's page answers to `expression`, in its own world, on
        /// the test's own session.
        func evaluate(_ expression: String, on session: String, seconds: Int = 10) async throws -> String? {
            let reply = try await connection.send("Runtime.evaluate", params: [
                "expression": .string(expression), "awaitPromise": true, "returnByValue": true,
            ], sessionID: session, timeout: .seconds(seconds))
            return reply["result"]?["value"]?.string
        }
    }

    /// A reference that keeps nothing alive.
    @MainActor
    private final class Held<Object: AnyObject> {
        weak var object: Object?
        init(_ object: Object) { self.object = object }
    }

    /// A tab opened by a bridge that only this call holds, whose close
    /// Chrome said it carried out and never did: the close fails, the tab
    /// stays open, and the errand that owned the bridge has let go of it.
    @MainActor
    private func aTabWhoseCloseFailed(_ rig: Rig) async throws -> (BrowserTab, Held<ChromeBridge>) {
        let fixtures = rig.fixtures
        let bridge = ChromeBridge(connection: rig.connection, prepareTab: { try await fixtures.serve($0) },
                                  resolve: ChromeFixtures.resolve)
        let tab = try await bridge.openTab(URL(string: "https://site-1.test/")!)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, (try? await bridge.run("document.readyState", in: tab)) != "complete" {
            try await Task.sleep(for: .milliseconds(50))
        }
        let target = tab.windowID
        rig.proxy.swallows = { $0.contains("\"Target.closeTarget\"") && $0.contains(target) }
        do {
            try await bridge.closeTab(tab)
            XCTFail("the close went through")
        } catch let error as BrowserBridgeError {
            XCTAssertEqual(error, .timedOut)
        }
        rig.proxy.swallows = nil
        return (tab, Held(bridge))
    }

    /// A close that fails leaves the tab guarded as before, once the errand
    /// that owned it has let go of its bridge: a document asked for in it is
    /// answered, a frame from another site that starts in it runs, and a
    /// document at a private address is still refused before it goes out.
    @MainActor
    func testATabWhoseCloseFailedStaysGuardedAndNothingInItWaitsForever() async throws {
        let rig = try await Rig.start()
        defer { rig.stop() }
        let (tab, _) = try await aTabWhoseCloseFailed(rig)
        let attached = try await rig.connection.send("Target.attachToTarget",
                                                     params: ["targetId": .string(tab.windowID), "flatten": true])
        let session = try XCTUnwrap(attached["sessionId"]?.string)
        let went = try await rig.connection.send("Page.navigate", params: ["url": "https://site-2.test/"],
                                                 sessionID: session, timeout: .seconds(10))
        XCTAssertNil(went["errorText"], "\(went)")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline,
              (try? await rig.evaluate("location.href + ' ' + document.readyState", on: session))
                != "https://site-2.test/ complete" {
            try await Task.sleep(for: .milliseconds(50))
        }
        let framed = try await rig.evaluate("""
            new Promise(done => {
              const frame = document.createElement('iframe');
              frame.onload = () => done('loaded');
              frame.src = 'https://site-3.test/';
              document.body.appendChild(frame);
              setTimeout(() => done('held'), 8000);
            })
            """, on: session, seconds: 15)
        XCTAssertEqual(framed, "loaded", "a frame from another site runs")
        XCTAssertTrue(rig.fixtures.served.contains { $0.host == "site-3.test" })
        let refused = try await rig.connection.send("Page.navigate", params: ["url": "http://127.0.0.1:9/admin"],
                                                    sessionID: session, timeout: .seconds(10))
        XCTAssertEqual(refused["errorText"]?.string, "net::ERR_ABORTED", "\(refused)")
        XCTAssertFalse(rig.fixtures.blocked.contains { $0.contains("127.0.0.1") }, "\(rig.fixtures.blocked)")
    }

    /// A close Chrome says it carried out, the first time only: the close is
    /// tried again, and the tab is gone (Claude review c7 of I-09, #10). What
    /// the close threw is read here, so a close never tried again fails as
    /// itself — its time up, the tab still open (Claude review c8 of I-09,
    /// #31).
    @MainActor
    func testACloseThatFailsOnceIsTriedAgain() async throws {
        let rig = try await Rig.start()
        defer { rig.stop() }
        let fixtures = rig.fixtures
        let bridge = ChromeBridge(connection: rig.connection, prepareTab: { try await fixtures.serve($0) },
                                  resolve: ChromeFixtures.resolve)
        let tab = try await bridge.openTab(URL(string: "https://site-1.test/")!)
        let target = tab.windowID
        let once = FirstTime()
        rig.proxy.swallows = { $0.contains("\"Target.closeTarget\"") && $0.contains(target) && once.take() }
        var failed: BrowserBridgeError?
        do {
            try await bridge.closeTab(tab)
        } catch let error as BrowserBridgeError {
            failed = error
        }
        XCTAssertNil(failed, "tried again, and closed")
        let targets = try await rig.connection.send("Target.getTargets")
        XCTAssertFalse((targets["targetInfos"]?.array ?? []).contains { $0["targetId"]?.string == target }, "gone")
    }

    /// A tab whose close failed each time it was tried is the user's from
    /// then on: its requests still go on, none waiting forever, but the
    /// guard answers none of its dialogs and takes none of its file pickers.
    /// The user's own close of its page, which asks before it is left,
    /// reaches the user, and their Leave closes the tab (Claude review c7 of
    /// I-09, #10). While the agent drives a tab, the same question is Stay
    /// (`testLeavingAPageThatAsksIsStayUnlessTheLeavingHasAYes`).
    @MainActor
    func testATabWhoseCloseFailedLeavesItsDialogsAndPickersToTheUser() async throws {
        let rig = try await Rig.start()
        defer { rig.stop() }
        let fixtures = rig.fixtures
        let bridge = ChromeBridge(connection: rig.connection, prepareTab: { try await fixtures.serve($0) },
                                  resolve: ChromeFixtures.resolve)
        let tab = try await bridge.openTab(URL(string: "https://site-196.test/")!)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, (try? await bridge.run("document.readyState", in: tab)) != "complete" {
            try await Task.sleep(for: .milliseconds(50))
        }
        let page = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        let aim = try ActionOutcome.decode(try await bridge.run(
            try XCTUnwrap(ActionScript.aim(for: try page.action(.click, on: "Mark as changed"), on: page)), in: tab))
        try await bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        let target = tab.windowID
        rig.proxy.swallows = { $0.contains("\"Target.closeTarget\"") && $0.contains(target) }
        do {
            try await bridge.closeTab(tab)
            XCTFail("the close went through")
        } catch let error as BrowserBridgeError {
            XCTAssertEqual(error, .timedOut)
        }
        rig.proxy.swallows = nil
        XCTAssertTrue(rig.proxy.messages.contains {
            $0.contains("\"Page.setInterceptFileChooserDialog\"") && $0.contains("false") && $0.contains(tab.tabID)
        }, "its file pickers are the user's")
        // The user closes the tab: its page asks first.
        let attached = try await rig.connection.send("Target.attachToTarget",
                                                     params: ["targetId": .string(target), "flatten": true])
        let session = try XCTUnwrap(attached["sessionId"]?.string)
        let events = await rig.connection.events()
        _ = try await rig.connection.send("Page.enable", sessionID: session)
        _ = try await rig.connection.send("Page.close", sessionID: session)
        let asked = await Deadline.run(within: .seconds(5)) {
            for await event in events where event.method == "Page.javascriptDialogOpening" && event.sessionID == session {
                return true
            }
            return false
        } ?? false
        XCTAssertTrue(asked, "the page asked")
        // A person reads the question before answering it.
        try await Task.sleep(for: .milliseconds(500))
        let left = try? await rig.connection.send("Page.handleJavaScriptDialog", params: ["accept": true],
                                                  sessionID: session)
        XCTAssertNotNil(left, "the question was the user's to answer")
        let gone = Date().addingTimeInterval(10)
        var open = true
        while Date() < gone, open {
            let targets = try await rig.connection.send("Target.getTargets")
            open = (targets["targetInfos"]?.array ?? []).contains { $0["targetId"]?.string == target }
            if open { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertFalse(open, "the user's Leave closed the tab")
    }

    // MARK: - Every failed close hands the tab back (Codex review 2 of I-09, P2-4)

    /// How a close of the agent's tab goes wrong.
    private enum FailedClose {
        /// Chrome says it closed the tab, each time it is asked, and does not.
        case unclosed
        /// Chrome answers the close with an error.
        case refused
        /// Chrome never answers the close.
        case unanswered
        /// Chrome says it closed the tab, and its list of tabs fails.
        case unlisted
    }

    /// A tab Chrome says it closed and did not is the user's, its frames
    /// and all: the file picker of a widget of another site that was there
    /// before the close, and of one that came after it, is the user's (Claude
    /// review c8 of I-09, #29).
    @MainActor
    func testATabChromeSaysItClosedAndDidNotIsTheUsersFramesAndAll() async throws {
        try await closeFailsAndTheTabIsTheUsers(.unclosed)
    }

    /// A close Chrome answers with an error hands the tab back to the user
    /// as one it never carried out does (Codex review 2 of I-09, P2-4;
    /// Claude review c8 of I-09, #17).
    @MainActor
    func testATabWhoseCloseChromeRefusesIsTheUsers() async throws {
        try await closeFailsAndTheTabIsTheUsers(.refused)
    }

    /// A close Chrome never answers hands the tab back once its time is up
    /// (Codex review 2 of I-09, P2-4; Claude review c8 of I-09, #30).
    @MainActor
    func testATabWhoseCloseChromeNeverAnswersIsTheUsers() async throws {
        try await closeFailsAndTheTabIsTheUsers(.unanswered)
    }

    /// A close whose outcome cannot be read — Chrome's list of tabs fails —
    /// hands the tab back (Codex review 2 of I-09, P2-4).
    @MainActor
    func testATabWhoseCloseCannotBeCheckedIsTheUsers() async throws {
        try await closeFailsAndTheTabIsTheUsers(.unlisted)
    }

    /// A tab of site-263 with a widget of another site that asks for a file:
    /// its close fails as `failure` says, within its bound. From then on the
    /// tab is the user's: their click reaches the widget that was there and
    /// one the page adds after, and neither file picker is taken; a question
    /// the page asks is theirs to answer; and its requests are still guarded
    /// — a private address refused before it goes out.
    @MainActor
    private func closeFailsAndTheTabIsTheUsers(_ failure: FailedClose, file: StaticString = #filePath,
                                               line: UInt = #line) async throws {
        let rig = try await Rig.start()
        defer { rig.stop() }
        let fixtures = rig.fixtures
        let bridge = ChromeBridge(connection: rig.connection, prepareTab: { try await fixtures.serve($0) },
                                  resolve: ChromeFixtures.resolve)
        let tab = try await bridge.openTab(URL(string: "https://site-263.test/upload")!)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let frames = (try? await bridge.frames(of: tab))?.frames.count
            if frames == 1, (try? await bridge.run("document.readyState", in: tab)) == "complete" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let target = tab.windowID
        let close: @Sendable (String) -> Bool = { $0.contains("\"Target.closeTarget\"") && $0.contains(target) }
        switch failure {
        case .unclosed:
            rig.proxy.swallows = close
        case .refused:
            rig.proxy.answers = { close($0) ? .error("Target refused") : nil }
        case .unanswered:
            rig.proxy.answers = { close($0) ? .never : nil }
        case .unlisted:
            rig.proxy.swallows = close
            rig.proxy.answers = { $0.contains("\"Target.getTargets\"") ? .error("No list") : nil }
        }
        let began = ContinuousClock.now
        var thrown: BrowserBridgeError?
        do {
            try await bridge.closeTab(tab)
        } catch let error as BrowserBridgeError {
            thrown = error
        }
        rig.proxy.swallows = nil
        rig.proxy.answers = nil
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(40), "bounded", file: file, line: line)
        let expected: BrowserBridgeError = failure == .unclosed || failure == .unanswered ? .timedOut
            : .scriptFailed(code: -32000)
        XCTAssertEqual(thrown, expected, "the close failed", file: file, line: line)
        // The user's own session on the tab.
        let attached = try await rig.connection.send("Target.attachToTarget",
                                                     params: ["targetId": .string(target), "flatten": true])
        let session = try XCTUnwrap(attached["sessionId"]?.string, file: file, line: line)
        let pickers = Counter()
        let stream = await rig.connection.events()
        let watching = Task {
            for await event in stream where event.method == "Page.fileChooserOpened" { pickers.add() }
        }
        defer { watching.cancel() }
        _ = try await rig.connection.send("Page.enable", sessionID: session)
        let added = try await rig.evaluate("more()", on: session)
        XCTAssertEqual(added, "added", file: file, line: line)
        for (host, y) in [("site-264.test", 30.0), ("site-265.test", 130.0)] {
            let reached = try await clickUntilPressed(host, x: 150, y: y, on: session, rig)
            XCTAssertTrue(reached, "\(host): the user's click reached it", file: file, line: line)
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(pickers.value, 0, "no file picker taken", file: file, line: line)
        // A question the page asks: the user reads it, and their OK is the answer.
        let dialogs = await rig.connection.events()
        let asking = Task { try await rig.evaluate("String(confirm('Go on?'))", on: session, seconds: 20) }
        let asked = await Deadline.run(within: .seconds(5)) {
            for await event in dialogs where event.method == "Page.javascriptDialogOpening" && event.sessionID == session {
                return true
            }
            return false
        } ?? false
        XCTAssertTrue(asked, "the page asked", file: file, line: line)
        try await Task.sleep(for: .milliseconds(500))
        _ = try? await rig.connection.send("Page.handleJavaScriptDialog", params: ["accept": true], sessionID: session)
        let answer = try await asking.value
        XCTAssertEqual(answer, "true", "the user's OK, not the guard's Cancel", file: file, line: line)
        let refused = try await rig.connection.send("Page.navigate", params: ["url": "http://127.0.0.1:9/admin"],
                                                    sessionID: session, timeout: .seconds(10))
        XCTAssertEqual(refused["errorText"]?.string, "net::ERR_ABORTED", "\(refused)", file: file, line: line)
        XCTAssertFalse(rig.fixtures.blocked.contains { $0.contains("127.0.0.1") }, "\(rig.fixtures.blocked)",
                       file: file, line: line)
    }

    /// Presses the point of the tab's page, as a person does, until the
    /// widget of `host` says it was pressed — 10 s at most, where a second
    /// is plenty.
    @MainActor
    private func clickUntilPressed(_ host: String, x: Double, y: Double, on session: String, _ rig: Rig) async throws
        -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            for type in ["mousePressed", "mouseReleased"] {
                _ = try await rig.connection.send("Input.dispatchMouseEvent", params: [
                    "type": .string(type), "x": .number(x), "y": .number(y), "button": "left", "clickCount": 1,
                ], sessionID: session)
            }
            let pressed = Date().addingTimeInterval(0.3)
            while Date() < pressed {
                if try await rig.evaluate("String(clicks.includes('\(host)'))", on: session) == "true" { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        return false
    }

    /// The guard a failed close left ends once the tab is gone — closed by
    /// the user, here by the test — and nothing of it is kept.
    @MainActor
    func testTheGuardOfATabWhoseCloseFailedEndsOnceTheTabIsGone() async throws {
        let rig = try await Rig.start()
        defer { rig.stop() }
        let (tab, held) = try await aTabWhoseCloseFailed(rig)
        XCTAssertNotNil(held.object, "the tab is open: its guard is kept")
        _ = try await rig.connection.send("Target.closeTarget", params: ["targetId": .string(tab.windowID)])
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, held.object != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(held.object, "the tab is gone: so is its guard")
    }

    /// A tab's guard ends with that tab only: closing one of two tabs leaves
    /// the other guarded — a private address still refused, a public page
    /// still opened.
    @MainActor
    func testClosingOneTabLeavesAnotherGuarded() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (first, _) = try await world.open("https://site-1.test/")
        let (second, page) = try await world.open("https://site-190.test/")
        try await world.bridge.closeTab(first)
        try await press("Open the router", on: page, in: second, world)
        let seen = try await events(in: second, world) { $0.contains(.addressRefused) }
        XCTAssertEqual(seen, [.addressRefused])
        try await press("A public page", on: page, in: second, world)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, (try? await address(of: second, world)) != "https://site-1.test/" {
            try await Task.sleep(for: .milliseconds(50))
        }
        let now = try await address(of: second, world)
        XCTAssertEqual(now, "https://site-1.test/")
    }

    // MARK: - The page's own dialogs

    /// An alert is closed and the page goes on.
    @MainActor
    func testAnAlertIsClosedAndThePageGoesOn() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-194.test/")
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "loaded")
        XCTAssertEqual(world.bridge.events(in: tab), [.dialog(.alert, accepted: true)])
    }

    /// A confirm guards the step that brought it: Cancel without the user's
    /// Yes, OK with it — once.
    @MainActor
    func testAConfirmIsCancelUnlessTheStepHasAYesThenOKOnce() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-195.test/")
        try await press("Delete everything", on: page, in: tab, world)
        try await press("Delete everything", on: page, in: tab, world)
        world.bridge.approve(ApprovedAct(words: ["Delete everything"]), in: tab)
        try await press("Delete everything", on: page, in: tab, world)
        try await press("Delete everything", on: page, in: tab, world)
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "kept;kept;deleted;kept;")
        XCTAssertEqual(world.bridge.events(in: tab), [.dialog(.confirm, accepted: false), .dialog(.confirm, accepted: false),
                                                      .dialog(.confirm, accepted: true), .dialog(.confirm, accepted: false)])
    }

    /// A prompt without a Yes is cancelled: nothing is written into it.
    @MainActor
    func testAPromptIsCancelled() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-195.test/")
        try await press("Rename the list", on: page, in: tab, world)
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "not renamed;")
        XCTAssertEqual(world.bridge.events(in: tab), [.dialog(.prompt, accepted: false)])
    }

    /// A confirm whose own words name a grant is Cancel even with the step's
    /// Yes, and the tab says so, by kind alone; one that names a charge or a
    /// purchase the control's words never named — a card charged, a
    /// purchase completed under "Renew" or "Finish" — is Cancel as any
    /// confirm about another act is, and names no one's part (owner
    /// decision of 2026-10-19). One bound to the act is still OK, once
    /// (review of I-09, F4).
    @MainActor
    func testAConfirmThatNamesAGrantOrAnotherActIsCancelEvenWithAYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-195.test/")
        for (name, kind) in [("Renew", nil), ("Finish", nil), ("Connect Acme", ErrandHandover.Kind.grant)] {
            world.bridge.approve(ApprovedAct(words: [name]), in: tab)
            try await press(name, on: page, in: tab, world)
            // What the dialog named is noted as it is decided, before the answer
            // goes out (review round 4, decision 10).
            XCTAssertEqual(world.bridge.events(in: tab),
                           (kind.map { [.dialogNamed($0)] } ?? []) + [.dialog(.confirm, accepted: false)], name)
        }
        // The Yes such a dialog met is used up: the next confirm is Cancel.
        try await press("Delete everything", on: page, in: tab, world)
        XCTAssertEqual(world.bridge.events(in: tab), [.dialog(.confirm, accepted: false)])
        world.bridge.approve(ApprovedAct(words: ["Delete everything"]), in: tab)
        try await press("Delete everything", on: page, in: tab, world)
        XCTAssertEqual(world.bridge.events(in: tab), [.dialog(.confirm, accepted: true)])
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "not charged;not bought;not granted;kept;deleted;", "nothing paid, nothing granted")
    }

    /// "Leave the page?" as the agent leaves: Stay, unless the leaving has
    /// the user's Yes.
    @MainActor
    func testLeavingAPageThatAsksIsStayUnlessTheLeavingHasAYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-196.test/")
        try await press("Mark as changed", on: page, in: tab, world)
        _ = try await world.bridge.run("location.assign('https://site-1.test/'), 'x'", in: tab)
        var seen = try await events(in: tab, world) { !$0.isEmpty }
        XCTAssertEqual(seen, [.dialog(.beforeunload, accepted: false)])
        try await Task.sleep(for: .milliseconds(300))
        var now = try await address(of: tab, world)
        XCTAssertEqual(now, "https://site-196.test/", "stayed")
        world.bridge.approve(ApprovedAct(words: []), in: tab)
        _ = try await world.bridge.run("location.assign('https://site-1.test/'), 'x'", in: tab)
        seen = try await events(in: tab, world) { !$0.isEmpty }
        XCTAssertEqual(seen, [.dialog(.beforeunload, accepted: true)])
        try await world.waitUntilPageIs("/ complete", in: tab)
        now = try await address(of: tab, world)
        XCTAssertEqual(now, "https://site-1.test/", "left")
    }

    /// A page that shows dialogs one after another never holds the tab: each
    /// is answered, and a script still runs in it.
    @MainActor
    func testDialogsInALoopNeverFreezeTheTab() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-195.test/")
        try await press("Show the tips", on: page, in: tab, world)
        let seen = try await events(in: tab, world) { $0.count >= 10 }
        XCTAssertGreaterThanOrEqual(seen.count, 10)
        XCTAssertTrue(seen.allSatisfy { $0 == .dialog(.alert, accepted: true) })
        let answered = try await world.bridge.run("String(1 + 1)", in: tab)
        XCTAssertEqual(answered, "2")
    }

    // MARK: - The errand: each refusal and dialog kept, the step that caused it honest

    private func plan(_ start: String) throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: "Look around the page", subgoals: [.init(description: "Look", terms: ["page"])],
                                searches: [URL(string: start)!], columns: ["Name"], sheetTitle: "Page",
                                rowsWanted: 1, emptyCell: "n/a"))
    }

    /// An engine that picks, in turn, the first candidate each of `picks`
    /// finds, then DONE, keeping every request.
    private static func engine(_ picks: [@Sendable (Candidate) -> Bool],
                               irreversible: @escaping @Sendable (AgentAction) -> Double = { _ in 0.05 })
        -> (ScriptedEngine, Requests) {
        let requests = Requests()
        let turn = Counter()
        let engine = ScriptedEngine(choice: { request in
            _ = requests.add(request)
            if turn.value < picks.count, let chosen = request.candidates.first(where: picks[turn.value]) {
                turn.add()
                return ScriptedEngine.pick(chosen)
            }
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        }, irreversible: irreversible)
        return (engine, requests)
    }

    private static func on(_ operation: AgentOperation, _ name: String) -> @Sendable (Candidate) -> Bool {
        { $0.action.operation == operation && $0.action.target?.name == name }
    }

    @MainActor
    private func run(_ world: ChromeWorld, from start: String, engine: ScriptedEngine, bridge: (any BrowserBridge)? = nil,
                     confirm: @escaping @MainActor @Sendable (ConfirmationRequest) async -> ConfirmationRequest.Answer?
                        = { _ in .no }) async throws -> ErrandRecord {
        let run = AgentRun(plan: try plan(start), errandID: UUID(),
                           collaborators: .init(bridge: bridge ?? world.bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: confirm))
        return await run.run()
    }

    /// The page's own log, in its own world — what it did.
    @MainActor
    private func pageLog(_ tab: BrowserTab, _ world: ChromeWorld) async throws -> String {
        try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
    }

    private static func isDialog(_ event: ErrandRecord.Event) -> Bool {
        if case .dialog = event { true } else { false }
    }

    /// A link to the user's network is never offered; a click whose page
    /// then sends the tab there fails, and the refusal is on record.
    @MainActor
    func testAStepThatLeadsToAPrivateAddressFailsAndTheRefusalIsKept() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.on(.click, "Go home")])
        let record = try await run(world, from: "https://site-190.test/", engine: engine)
        XCTAssertFalse(requests.all.first?.candidates.contains { $0.action.target?.name == "Open the router" } ?? true,
                       "a link to the user's network is no action")
        XCTAssertEqual(record.steps.first { $0.operation == "click" }?.outcome, .failed, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.addressRefused), "\(record.eventLines)")
        XCTAssertEqual(record.ending, .done)
    }

    /// A click whose page shows it did something, then sends the tab to the
    /// user's network, fails all the same: the refusal is on its way.
    @MainActor
    func testAStepThatChangesThePageButIsRefusedOnItsWayFails() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, _) = Self.engine([Self.on(.click, "Head home")])
        let record = try await run(world, from: "https://site-190.test/", engine: engine)
        XCTAssertEqual(record.steps.first { $0.operation == "click" }?.outcome, .failed, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.addressRefused), "\(record.eventLines)")
    }

    /// An open whose answer is a file fails at once — no wait for a page
    /// that never comes — and the refused download is on record.
    @MainActor
    func testAStepThatDownloadsFailsAtOnceAndTheRefusalIsKept() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, _) = Self.engine([Self.on(.open, "The report")])
        let record = try await run(world, from: "https://site-193.test/", engine: engine)
        XCTAssertEqual(record.steps.first { $0.operation == "open" }?.outcome, .failed, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.downloadRefused), "\(record.eventLines)")
        XCTAssertFalse(record.events.contains(.pageMiss(.settle)), "the refusal ended the wait: \(record.eventLines)")
        let saved = try FileManager.default.contentsOfDirectory(atPath: world.chrome.downloads.path)
        XCTAssertEqual(saved, [])
    }

    /// The page's confirm guards the step: with the user's Yes for the step
    /// it is answered OK, once; with a No the step is never taken. A prompt a
    /// step without a Yes brings is cancelled. Each dialog is on record.
    @MainActor
    func testADialogIsAnsweredByTheStepsOwnYesAndKept() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, _) = Self.engine([Self.on(.click, "Delete everything"), Self.on(.click, "Rename the list")])
        let record = try await run(world, from: "https://site-195.test/", engine: engine, confirm: { _ in .yes })
        XCTAssertEqual(record.steps.first { $0.operation == "click" }?.outcome, .confirmed, "\(record.eventLines)")
        XCTAssertEqual(record.events.filter { if case .dialog = $0 { true } else { false } },
                       [.dialog(.confirm, accepted: true), .dialog(.prompt, accepted: false)], "\(record.eventLines)")
        let (refusing, _) = Self.engine([Self.on(.click, "Delete everything")])
        let refused = try await run(world, from: "https://site-195.test/", engine: refusing, confirm: { _ in .no })
        XCTAssertFalse(refused.events.contains { if case .dialog = $0 { true } else { false } },
                       "a No: the step is never taken")
    }

    /// The user's Yes for a click whose page then asks, in a confirm, for a
    /// grant: the confirm is Cancel, and the errand ends at the user's part —
    /// one step on record, and the engine never asked again (review of
    /// I-09, F4).
    @MainActor
    func testAStepWhosePageAsksForAGrantEndsAtTheUsersPart() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for (name, kind) in [("Connect Acme", ErrandHandover.Kind.grant)] {
            let hands = KeepsTheTab(world.bridge)
            let (engine, requests) = Self.engine([Self.on(.click, name)], irreversible: { _ in 0.9 })
            let asked = Counter()
            let record = try await run(world, from: "https://site-195.test/", engine: engine, bridge: hands, confirm: { _ in
                asked.add()
                return .yes
            })
            XCTAssertEqual(asked.value, 1, "\(name): the click had the user's Yes")
            XCTAssertEqual(record.ending, .needsUser, "\(name): \(record.eventLines)")
            XCTAssertTrue(record.events.contains(.handover(kind, host: "site-195.test")), "\(name): \(record.eventLines)")
            XCTAssertEqual(record.events.filter(Self.isDialog), [.dialog(.confirm, accepted: false)],
                           "\(name): \(record.eventLines)")
            XCTAssertEqual(record.steps.map(\.operation), ["click"], "\(name): \(record.eventLines)")
            XCTAssertEqual(requests.all.count, 1, "\(name): nothing chosen past the user's part")
            let tab = try XCTUnwrap(hands.kept.first)
            let log = try await pageLog(tab, world)
            XCTAssertEqual(log, "not granted;")
        }
    }

    /// The user's Yes for "Renew", whose page then asks, in a confirm, to
    /// charge the card: Cancel, as any confirm about another act, and no
    /// one's part (owner decision of 2026-10-19): the errand goes on, and
    /// nothing is charged.
    @MainActor
    func testAStepWhosePageAsksToChargeACardIsCancelAndGoesOn() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Renew")], irreversible: { _ in 0.9 })
        let asked = Counter()
        let record = try await run(world, from: "https://site-195.test/", engine: engine, bridge: hands, confirm: { _ in
            asked.add()
            return .yes
        })
        XCTAssertEqual(asked.value, 1, "the click had the user's Yes: \(record.eventLines)")
        XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } }, "\(record.eventLines)")
        XCTAssertEqual(record.events.filter(Self.isDialog), [.dialog(.confirm, accepted: false)], "\(record.eventLines)")
        let log = try await pageLog(try XCTUnwrap(hands.kept.first), world)
        XCTAssertEqual(log, "not charged;")
    }

    /// Stop right after a click the user said Yes to: a confirm the page
    /// shows a moment later is Cancel — the Yes ended at Stop, not at the
    /// step's end (review of I-09, F2).
    @MainActor
    func testStopEndsTheStepsYesAtOnce() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Clear the draft")], irreversible: { _ in 0.9 })
        let asked = Counter()
        let run = AgentRun(plan: try plan("https://site-195.test/"), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in
                                                    asked.add()
                                                    return .yes
                                                }))
        hands.afterClick = { run.stop() }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .stopped)
        // The click had the user's Yes: its dialog Yes was armed, and Stop
        // ended it (Claude review c7 of I-09, #26).
        XCTAssertEqual(asked.value, 1, "\(run.record.eventLines)")
        XCTAssertTrue(run.record.events.contains(.answer(.yes)), "\(run.record.eventLines)")
        let tab = try XCTUnwrap(hands.kept.first)
        var log = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, log.isEmpty {
            log = try await pageLog(tab, world)
            if log.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertEqual(log, "kept the draft;", "Cancel after Stop")
    }

    // MARK: - A dialog bound to the approved act (Codex review 1 of I-09, P1-3, P1-4)

    /// Under the step's Yes a confirm is OK once only when it is bound to
    /// the approved act — a word it shares with the control, in any language,
    /// or a bare confirmation. A confirm about another act — a charge of the
    /// saved card under "Renew" — is Cancel; a prompt is Cancel whatever the
    /// Yes; without a Yes everything is Cancel.
    @MainActor
    func testAConfirmUnderAYesIsOKOnlyWhenBoundToTheApprovedAct() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-207.test/")
        let cases: [(String, [BrowserEvent])] = [
            ("Renew", [.dialog(.confirm, accepted: false)]),
            ("Archive", [.dialog(.confirm, accepted: false)]),
            ("Delete", [.dialog(.confirm, accepted: true)]),
            ("Remove", [.dialog(.confirm, accepted: true)]),
            ("L\u{00F6}schen", [.dialog(.confirm, accepted: true)]),
            ("Rename", [.dialog(.prompt, accepted: false)]),
        ]
        for (name, expected) in cases {
            world.bridge.approve(ApprovedAct(words: [name]), in: tab)
            try await press(name, on: page, in: tab, world)
            let seen = try await events(in: tab, world) { $0.count >= expected.count }
            XCTAssertEqual(seen, expected, name)
            world.bridge.approve(nil, in: tab)
        }
        try await press("Delete", on: page, in: tab, world)
        let unapproved = try await events(in: tab, world) { !$0.isEmpty }
        XCTAssertEqual(unapproved, [.dialog(.confirm, accepted: false)], "no Yes")
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "not charged;not sent;deleted;removed;geloescht;not renamed;kept;")
    }

    /// A grant asked for in a confirm, then a flood of alerts that pushes
    /// out everything else the tab kept: the grant it named is still read
    /// (Claude review of I-09, kept 2).
    @MainActor
    func testWhatADialogNamedOutlastsAFloodOfAlerts() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-207.test/")
        try await press("Extend", on: page, in: tab, world)
        var log = ""
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !log.hasSuffix("done;") {
            log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
            if !log.hasSuffix("done;") { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertEqual(log, "not granted;done;")
        let seen = world.bridge.events(in: tab)
        XCTAssertEqual(seen.filter { $0 == .dialogNamed(.grant) }.count, 1, "kept, once")
        XCTAssertLessThanOrEqual(seen.count, ChromeBridge.maxEvents, "the rest stays bounded")
    }

    /// The user's Yes for a click whose page then confirms something else
    /// than the approved act — another act, a charge of the saved card in
    /// plain words, a renewal at a price the control never showed: Cancel,
    /// and the step fails honestly (Codex review 1 of I-09, P1-3; owner
    /// decision of 2026-10-19: a dialog's words name no one's part).
    @MainActor
    func testAStepWhoseConfirmIsNotItsApprovedActFails() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for (name, logged) in [("Archive", "not sent;"), ("Renew", "not charged;"), ("Renew plan", "not renewed;")] {
            let hands = KeepsTheTab(world.bridge)
            let (engine, _) = Self.engine([Self.on(.click, name)], irreversible: { _ in 0.9 })
            let record = try await run(world, from: "https://site-207.test/", engine: engine, bridge: hands,
                                       confirm: { _ in .yes })
            XCTAssertEqual(record.events.filter(Self.isDialog), [.dialog(.confirm, accepted: false)],
                           "\(name): \(record.eventLines)")
            XCTAssertEqual(record.steps.first?.outcome, .failed, "\(name): \(record.eventLines)")
            XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } },
                           "\(name): \(record.eventLines)")
            let log = try await pageLog(try XCTUnwrap(hands.kept.first), world)
            XCTAssertEqual(log, logged, name)
        }
    }

    /// A grant asked for in a confirm, then more alerts than the step's
    /// limit: the errand ends at the user's part, not stuck (Claude review
    /// of I-09, kept 2).
    @MainActor
    func testAGrantAskedForBeforeAFloodOfAlertsEndsAtTheUsersPart() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, _) = Self.engine([Self.on(.click, "Extend")])
        let record = try await run(world, from: "https://site-207.test/", engine: engine)
        XCTAssertEqual(record.ending, .needsUser, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.handover(.grant, host: "site-207.test")), "\(record.eventLines)")
    }

    /// A page that asks, in its own dialog, for a payment while the user is
    /// asked about a step: Cancel — before the Yes is armed — and no one's
    /// part (owner decision of 2026-10-19); the step then goes with the Yes
    /// (Claude review of I-09, kept 2, read the dialog as the user's part).
    @MainActor
    func testAChargeAskedForWhileTheQuestionWaitsIsCancelAndTheActGoes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Remove")], irreversible: { _ in 0.9 })
        let bridge = world.bridge
        let record = try await run(world, from: "https://site-207.test/", engine: engine, bridge: hands,
                                   confirm: { request in
                                       _ = try? await bridge.runInPage("setTimeout(() => confirm('Pay EUR 5 now?'), 0); 'x'",
                                                                       in: request.tab)
                                       try? await Task.sleep(for: .milliseconds(300))
                                       return .yes
                                   })
        XCTAssertTrue(record.events.contains(.dialog(.confirm, accepted: false)), "\(record.eventLines)")
        XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } }, "\(record.eventLines)")
        let log = try await pageLog(try XCTUnwrap(hands.kept.first), world)
        XCTAssertEqual(log, "removed;", "removed with the Yes: \(record.eventLines)")
    }

    /// Stop between a dialog's answer being decided — OK, under the step's
    /// Yes — and its going out: the answer is decided as it goes, and goes
    /// out as Cancel; nothing is deleted (Codex review 1 of I-09, P1-4).
    @MainActor
    func testStopBeforeAnAcceptanceGoesOutSendsCancel() async throws {
        let chrome = try await TestChrome.launch()
        let connection = CDPConnection(url: chrome.endpoint.webSocketURL)
        try await connection.open()
        let fixtures = ChromeFixtures(connection: connection)
        await fixtures.start()
        let stop = StopHolder()
        let bridge = ChromeBridge(connection: connection, prepareTab: { try await fixtures.serve($0) },
                                  beforeAnswer: { stop.fire() }, resolve: ChromeFixtures.resolve)
        defer {
            fixtures.stop()
            Task { await connection.close() }
            chrome.quit()
        }
        let hands = KeepsTheTab(bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Delete")], irreversible: { _ in 0.9 })
        let run = AgentRun(plan: try plan("https://site-207.test/"), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .yes }))
        stop.action = { run.stop() }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(stop.fired, 1, "the dialog came, and Stop with it")
        let tab = try XCTUnwrap(hands.kept.first)
        var log = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, log.isEmpty {
            log = (try? await bridge.runInPage("document.getElementById('log').textContent", in: tab)) ?? ""
            if log.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertEqual(log, "kept;", "Cancel went out")
    }

    /// An open the user gave no Yes for, from a page that asks before it is
    /// left: Stay — the step fails and the page stays. With the Yes for the
    /// open: Leave, once (review of I-09, tests F2: the script-sent path).
    @MainActor
    func testAnOpenLeavesAPageThatAsksOnlyWithItsYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let picks = [Self.on(.click, "Mark as changed"), Self.on(.open, "Somewhere else")]
        let stays = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine(picks)
        let record = try await run(world, from: "https://site-196.test/", engine: engine, bridge: stays)
        XCTAssertEqual(record.events.filter(Self.isDialog), [.dialog(.beforeunload, accepted: false)], "\(record.eventLines)")
        XCTAssertEqual(record.steps.first { $0.operation == "open" }?.outcome, .failed, "\(record.eventLines)")
        let stayed = try await address(of: try XCTUnwrap(stays.kept.first), world)
        XCTAssertEqual(stayed, "https://site-196.test/")
        let leaves = KeepsTheTab(world.bridge)
        let (approved, _) = Self.engine(picks, irreversible: { $0.operation == .open ? 0.9 : 0.05 })
        let left = try await run(world, from: "https://site-196.test/", engine: approved, bridge: leaves,
                                 confirm: { _ in .yes })
        XCTAssertEqual(left.events.filter(Self.isDialog), [.dialog(.beforeunload, accepted: true)], "\(left.eventLines)")
        XCTAssertEqual(left.steps.first { $0.operation == "open" }?.outcome, .confirmed, "\(left.eventLines)")
        let now = try await address(of: try XCTUnwrap(leaves.kept.first), world)
        XCTAssertEqual(now, "https://site-1.test/")
    }

    /// A choice whose change the page asks to confirm, with no Yes: Cancel
    /// (review of I-09, tests F2: the script-sent path).
    @MainActor
    func testAChoiceWhosePageAsksIsCancelWithoutAYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([{ $0.action.operation == .select && $0.action.target?.name == "Plan"
                                          && $0.action.payload == "Yearly" }])
        let record = try await run(world, from: "https://site-205.test/", engine: engine, bridge: hands)
        XCTAssertEqual(record.steps.first?.operation, "select", "\(record.eventLines)")
        XCTAssertEqual(record.events.filter(Self.isDialog), [.dialog(.confirm, accepted: false)], "\(record.eventLines)")
        let log = try await pageLog(try XCTUnwrap(hands.kept.first), world)
        XCTAssertEqual(log, "kept;")
    }

    /// A page that shows dialogs one after another ends the errand stuck —
    /// never frozen — and the record keeps a bounded number of them.
    @MainActor
    func testAPageThatShowsDialogsInALoopEndsTheErrandStuck() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, _) = Self.engine([Self.on(.click, "Show the tips")])
        let record = try await run(world, from: "https://site-195.test/", engine: engine)
        XCTAssertEqual(record.ending, .stuck, "\(record.eventLines)")
        let dialogs = record.events.filter { if case .dialog = $0 { true } else { false } }.count
        XCTAssertGreaterThan(dialogs, AgentRun.dialogLimit)
        XCTAssertLessThanOrEqual(dialogs, AgentRun.dialogLimit + 1)
        let tabs = try await world.agentTabCount()
        XCTAssertEqual(tabs, 0, "its tab closed")
    }

    /// An alert as the page loads is closed, and the errand goes on.
    @MainActor
    func testAnAlertOnLoadIsClosedAndTheErrandGoesOn() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([])
        let record = try await run(world, from: "https://site-194.test/", engine: engine)
        XCTAssertEqual(record.ending, .done)
        XCTAssertEqual(requests.all.count, 1, "the page was read")
        XCTAssertTrue(record.events.contains(.dialog(.alert, accepted: true)), "\(record.eventLines)")
    }

    // MARK: - The agent's tab, marked

    /// The tab strip shows the agent's tab with its mark, whatever title the
    /// page gives itself; the agent reads the page's title without it.
    @MainActor
    func testTheAgentsTabCarriesItsMarkAndTheAgentNeverReadsIt() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, first) = try await world.open("https://site-1.test/")
        let title = { () async throws -> String in
            let targets = try await world.connection.send("Target.getTargets")
            return (targets["targetInfos"]?.array ?? []).first { $0["targetId"]?.string == tab.windowID }?["title"]?.string ?? ""
        }
        let shown = try await title()
        XCTAssertTrue(shown.hasPrefix(ChromeBridge.tabMark), shown)
        XCTAssertFalse(first.title.contains(ChromeBridge.tabMark.trimmingCharacters(in: .whitespaces)), first.title)
        let (renamed, _) = try await world.open("https://site-197.test/")
        try await world.waitUntilPageIs("/ complete", in: renamed)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline,
              try await world.bridge.runInPage("document.getElementById('log').textContent", in: renamed) != "renamed" {
            try await Task.sleep(for: .milliseconds(50))
        }
        let page = try ObservedPage.decode(try await world.bridge.run(ObserverScript.source, in: renamed))
        XCTAssertEqual(page.title, "Inbox (2)")
        // The excerpt the writer reads has the page's own title too (Claude
        // review c7 of I-09, #25).
        let excerpt = try PageExcerpt.decode(try await world.bridge.run(ObserverScript.excerptSource(), in: renamed))
        XCTAssertEqual(excerpt.title, "Inbox (2)")
        let targets = try await world.connection.send("Target.getTargets")
        let strip = (targets["targetInfos"]?.array ?? []).first { $0["targetId"]?.string == renamed.windowID }?["title"]?.string
        XCTAssertEqual(strip, ChromeBridge.tabMark + "Inbox (2)")
    }
}

/// ITER-076 I-09 — the tab's guard's own rules, without a browser.
final class ChromeTabGuardTests: XCTestCase {
    /// An answer that is a file Chrome saves rather than a page it draws: one
    /// sent as an attachment, or of a type no page is drawn from (a reference
    /// browser agent's `_is_download`, MIT). One sent inline that names a file
    /// is drawn as its type says (2026-10-19: a hosting service names a file
    /// on every page it serves, and a contact page was refused as a download).
    func testAnAnswerThatIsAFileIsADownload() {
        XCTAssertTrue(ChromeBridge.isDownload(type: "application/pdf", disposition: "attachment; filename=\"a.pdf\""))
        XCTAssertFalse(ChromeBridge.isDownload(type: "text/html; charset=utf-8", disposition: "inline; filename=\"contact\""))
        XCTAssertTrue(ChromeBridge.isDownload(type: "application/octet-stream", disposition: "inline; filename=a.bin"))
        XCTAssertTrue(ChromeBridge.isDownload(type: "text/html", disposition: "filename=a.html"))
        XCTAssertTrue(ChromeBridge.isDownload(type: "text/html", disposition: "ATTACHMENT"))
        XCTAssertTrue(ChromeBridge.isDownload(type: "application/octet-stream", disposition: ""))
        XCTAssertTrue(ChromeBridge.isDownload(type: "Text/CSV; charset=utf-8", disposition: ""))
        XCTAssertFalse(ChromeBridge.isDownload(type: "text/html; charset=utf-8", disposition: ""))
        XCTAssertFalse(ChromeBridge.isDownload(type: "image/png", disposition: "inline"))
    }

    /// A document at a web address on the user's machine or network is
    /// refused as it is asked for; anything else is let go on.
    func testADocumentAtAPrivateAddressIsRefusedAtItsRequest() {
        for address in ["http://127.0.0.1:9/x", "https://[::1]/", "http://router.local/", "http://intranet/",
                        "http://10.0.0.5/admin"] {
            XCTAssertTrue(ChromeBridge.refuses(address), address)
        }
        for address in ["https://site-1.test/", "http://8.8.8.8/", "about:blank", "data:text/html,x",
                        "chrome-error://chromewebdata/"] {
            XCTAssertFalse(ChromeBridge.refuses(address), address)
        }
    }

    /// Only an answer of a type Chrome draws as a page is let in. Any other
    /// is refused as a download: a disk image, a type no one knows, no type
    /// at all, a second type slipped in after a drawn one (ITER-076 I-09
    /// review, NET-2).
    func testAnAnswerOfATypeNoPageIsDrawnFromIsADownload() {
        for type in ["application/x-apple-diskimage", "application/x-made-up-kind", "application/x-msdownload", "",
                     "image/", "image/png, application/x-apple-diskimage", "text/html\napplication/zip", "*/*",
                     // A drawn family whose subtype is no single token.
                     "image/ x-apple-diskimage", "image/(png)", "image/png/x",
                     // Drawn by Chrome as text, but outside the types the tab takes: refused all the same.
                     "text/css", "application/javascript"] {
            XCTAssertTrue(ChromeBridge.isDownload(type: type, disposition: ""), type)
        }
        for type in ["text/html", "TEXT/HTML; charset=utf-8", " text/html ", "application/xhtml+xml", "text/plain",
                     "text/xml", "application/xml", "application/json; charset=utf-8", "image/png", "image/svg+xml",
                     "audio/mpeg", "video/mp4"] {
            XCTAssertFalse(ChromeBridge.isDownload(type: type, disposition: ""), type)
        }
    }

    /// A name reserved for a private network — a home network's (RFC 8375)
    /// or any private network's (ICANN, 2024) — is refused at its request as
    /// a `.local` name is: public DNS never answers it (ITER-076 I-09 review,
    /// NET-3).
    func testADocumentAtANameReservedForPrivateNetworksIsRefusedAtItsRequest() {
        for address in ["http://router.home.arpa/", "http://home.arpa/", "http://nas.internal/",
                        "https://a.b.internal:8443/x", "http://NAS.Internal./"] {
            XCTAssertTrue(ChromeBridge.refuses(address), address)
        }
        for address in ["https://nothome.arpa/", "https://internal.example.com/", "https://example.xinternal/"] {
            XCTAssertFalse(ChromeBridge.refuses(address), address)
        }
    }

    /// A name ICANN resolved never to give to anyone — `.home`, `.corp`,
    /// `.mail` — is refused at its request as `.internal` is: only the
    /// user's own resolver answers it (Claude review c7 of I-09, #9).
    func testADocumentAtANameNeverDelegatedIsRefusedAtItsRequest() {
        for address in ["http://bthomehub.home/", "http://intranet.corp/", "http://mx.mail/x", "http://Router.Home./"] {
            XCTAssertTrue(ChromeBridge.refuses(address), address)
        }
        for address in ["https://home.example.com/", "https://example.homes/", "https://corp.example.com/",
                        "https://example.email/"] {
            XCTAssertFalse(ChromeBridge.refuses(address), address)
        }
    }

    /// The Mac's own resolver, as the guard asks it (ITER-076 stage 9e):
    /// `localhost` comes back as its numeric addresses — no network needed —
    /// each one the user's own machine to the classifier.
    func testTheMacsOwnResolverGivesLocalhostItsNumericAddresses() async throws {
        let answer = await ChromeBridge.addresses(of: "localhost")
        let addresses = try XCTUnwrap(answer)
        XCTAssertFalse(addresses.isEmpty)
        XCTAssertTrue(Set(addresses).isSubset(of: ["127.0.0.1", "::1"]), "\(addresses)")
        XCTAssertTrue(addresses.allSatisfy { DiaScript.isPrivate(host: $0) }, "\(addresses)")
    }

    /// An answer is a file whenever Chrome would save it rather than draw it
    /// (Claude review c7 of I-09, #8): a disposition of any type but
    /// `inline` — a misspelt one, or a form's part, which Chrome takes for an
    /// attachment — and an image, a sound or a film of a type Chrome does not
    /// draw. A PDF is a file: the user's Chrome may be set to save PDFs. A
    /// type holding a comma is more than one, whatever comes first: Chrome
    /// reads each and takes the last it can read (Claude review c8 of I-09,
    /// #27) — one inside quotes is refused all the same, a step and never a
    /// file.
    func testAnAnswerChromeWouldSaveIsADownload() {
        for (type, disposition) in [("text/html", "attachement"), ("text/html", "form-data; name=x"),
                                    ("text/html", "  Attachement ; x=1"), ("image/tiff", ""), ("image/heic", ""),
                                    ("video/x-msvideo", ""), ("audio/x-made-up", ""), ("application/pdf", ""),
                                    ("application/pdf", "inline"),
                                    ("text/html; charset=utf-8, application/octet-stream", ""),
                                    ("image/png;q=1,application/zip", ""), ("text/html; charset=\"utf-8, x\"", "")] {
            XCTAssertTrue(ChromeBridge.isDownload(type: type, disposition: disposition), "\(type) \(disposition)")
        }
        for (type, disposition) in [("text/html", "inline"), ("text/html", " INLINE "), ("text/html", ""),
                                    ("image/png", ""), ("image/jpeg", "inline"), ("image/gif", ""), ("image/webp", ""),
                                    ("image/avif", ""), ("image/x-icon", ""), ("image/bmp", ""), ("audio/mpeg", ""),
                                    ("audio/wav", ""), ("video/webm", ""), ("video/mp4", "")] {
            XCTAssertFalse(ChromeBridge.isDownload(type: type, disposition: disposition), "\(type) \(disposition)")
        }
    }
}

/// What a test does at the moment a page's dialog is decided and its answer
/// not yet sent (Codex review 1 of I-09, P1-4): Stop, here.
@MainActor
final class StopHolder {
    var action: () -> Void = {}
    private(set) var fired = 0

    func fire() {
        fired += 1
        action()
    }
}
