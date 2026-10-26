import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 3.1 — the agent's hands in a real Chrome (headless, with a profile
/// of its own), on the fixture pages served from inside Chrome: nothing reaches
/// the network, and the user's Chrome is never touched. Skipped without Chrome.
final class ChromeBridgeLiveTests: XCTestCase {
    @MainActor
    func testOpensReadsAndClosesItsOwnTab() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let tab = try await world.bridge.openTab(URL(string: "https://site-2.test/")!)
        try await world.waitUntilLoaded(tab)
        let title = try await world.bridge.run("document.title", in: tab)
        XCTAssertEqual(title, ChromeBridge.tabMark + "Site Two", "behind the agent's mark (ITER-076 I-09)")
        let open = try await world.agentTabCount()
        XCTAssertEqual(open, 1)
        try await world.bridge.closeTab(tab)
        let left = try await world.agentTabCount()
        XCTAssertEqual(left, 0, "no tab left behind")
        do {
            _ = try await world.bridge.run("document.title", in: tab)
            XCTFail("a closed tab cannot run a script")
        } catch let error as BrowserBridgeError {
            XCTAssertEqual(error, .tabNotFound)
        }
    }

    /// ITER-076 stage 8a, № 117: a tab the user closed — Chrome closed it, the
    /// bridge never asked — is that tab gone, never the connection lost: a
    /// look at it and a wait on it say so, and the connection still serves.
    @MainActor
    func testATabTheUserClosedIsGoneAndTheConnectionStays() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-2.test/")
        _ = try await world.connection.send("Target.closeTarget", params: ["targetId": .string(tab.windowID)])
        let deadline = ContinuousClock.now + .seconds(5)
        while try await world.agentTabCount() > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let left = try await world.agentTabCount()
        XCTAssertEqual(left, 0, "the premise: Chrome closed it")
        do {
            _ = try await world.bridge.run(ObserverScript.source, in: tab)
            XCTFail("a look at a closed tab")
        } catch let error as BrowserBridgeError {
            XCTAssertEqual(error, .tabNotFound, "a look")
        }
        do {
            _ = try await world.bridge.isLoading(tab)
            XCTFail("a wait on a closed tab")
        } catch let error as BrowserBridgeError {
            XCTAssertEqual(error, .tabNotFound, "a wait")
        }
        let (other, _) = try await world.open("https://site-2.test/")
        try await world.bridge.closeTab(other)
    }

    @MainActor
    func testRefusesAnAddressThatIsNotAWebPage() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        do {
            _ = try await world.bridge.openTab(URL(string: "javascript:alert(1)")!)
            XCTFail("never opened")
        } catch let error as BrowserBridgeError {
            guard case .notOpenable = error else { return XCTFail("\(error)") }
        }
        let tabs = try await world.agentTabCount()
        XCTAssertEqual(tabs, 0)
    }

    /// K1 (ITER-074 whole review): a page that rewrites the JavaScript the
    /// observer calls cannot forge its report — scripts run in a world of
    /// their own.
    @MainActor
    func testAPageCannotForgeWhatTheAgentReads() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let tab = try await world.bridge.openTab(URL(string: "https://site-81.test/")!)
        try await world.waitUntilLoaded(tab)
        let pageSays = try await world.bridge.runInPage("JSON.stringify({a: 1})", in: tab)
        XCTAssertEqual(pageSays, #"{"forged":true}"#, "the page did rewrite it")
        let report = try ObservedPage.decode(try await world.bridge.run(ObserverScript.source, in: tab))
        XCTAssertTrue(report.flags.paymentForm, "the observer's own report, not the page's forgery")
        XCTAssertTrue(report.elements.contains { $0.name == "Pay now" })
    }

    /// Review of 3.1 (P0-1): after the tab moves to another site — a new
    /// renderer, where context numbers start again — the agent's scripts still
    /// run in a world of its own, never in a frame the new page wrote.
    @MainActor
    func testAfterAMoveToAnotherSiteScriptsStillRunInTheAgentsWorld() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-83.test/")
        _ = try await world.bridge.run("location.assign('https://site-84.test/'), 'moving'", in: tab)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline,
              (try? await world.bridge.runInPage("location.host + ' ' + document.readyState", in: tab))
                != "site-84.test complete" {
            try await Task.sleep(for: .milliseconds(50))
        }
        let marker = try await world.bridge.run("typeof marker", in: tab)
        XCTAssertEqual(marker, "undefined", "a world of the agent's own, not one the page wrote")
        let report = try ObservedPage.decode(try await world.bridge.run(ObserverScript.source, in: tab))
        XCTAssertTrue(report.flags.paymentForm, "the observer's own report")
        let listening = await world.connection.listening
        XCTAssertEqual(listening, 2, "only the fixtures and the tab's watch listen: each world's report stream ended")
    }

    /// ITER-076 I-07: a move to another page of the same site keeps the
    /// renderer, and Chrome then says the old world's context cannot be
    /// found — its document is gone as surely as after a move to another
    /// site. The next script runs in a new world of the agent's own; so does
    /// the one after a read the move cut short.
    @MainActor
    func testAfterAMoveOnTheSameSiteScriptsRunInANewWorldOfTheAgentsOwn() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-127.test/")
        _ = try await world.bridge.run("location.assign('https://site-127.test/second'), 'moving'", in: tab)
        try await world.waitUntilPageIs("/second complete", in: tab)
        let marker = try await world.bridge.run("location.pathname + ' ' + typeof marker", in: tab)
        XCTAssertEqual(marker, "/second undefined", "a world of the agent's own on the new page")

        // A read out while the page moves is cut short; the next one is not.
        let cut = Task { @MainActor in
            try await world.bridge.runAwaiting("new Promise(() => { setTimeout(() => "
                + "location.assign('https://site-127.test/third'), 50); })", in: tab)
        }
        do {
            _ = try await cut.value
            XCTFail("the move cut the read short")
        } catch {}
        try await world.waitUntilPageIs("/third complete", in: tab)
        let after = try await world.bridge.run("location.pathname + ' ' + typeof marker", in: tab)
        XCTAssertEqual(after, "/third undefined")
    }

    /// Two looks at one document carry its one id, and a reload of the same address brings another: element keys,
    /// which the app compares to find a twin again after a Yes, are compared only within one document (2026-10-21).
    @MainActor
    func testADocumentKeepsItsIdAcrossLooksAndAReloadGetsANewOne() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, first) = try await world.open("https://site-127.test/")
        let id = try XCTUnwrap(first.documentID, "the observer names its document")
        let again = try ObservedPage.decode(try await world.bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(again.documentID, id, "the same document, the same id")
        XCTAssertEqual(again.elements.map(\.key), first.elements.map(\.key), "and the same keys")
        _ = try await world.bridge.run("window.reloadMark = 1, location.reload(), 'reloading'", in: tab)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline,
              (try? await world.bridge.run("typeof window.reloadMark + ' ' + document.readyState", in: tab))
                  != "undefined complete" {
            try await Task.sleep(for: .milliseconds(50))
        }
        let reloaded = try ObservedPage.decode(try await world.bridge.run(ObserverScript.source, in: tab))
        XCTAssertNotNil(reloaded.documentID)
        XCTAssertNotEqual(reloaded.documentID, id, "a reload is another document")
    }

    /// A field once seen to be secret stays secret in Chrome too: the agent's
    /// world lasts as long as the document, and so does what it remembers — a
    /// page that shows the password's text does not make it an ordinary field
    /// (ITER-076 A3d).
    @MainActor
    func testASecretFieldStaysSecretWhenThePageShowsItsText() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, first) = try await world.open("https://site-98.test/")
        XCTAssertFalse(first.elements.contains { $0.name == "Kod" })
        _ = try await world.bridge.runInPage("document.querySelector('[name=k1]').type = 'text'; 'shown'", in: tab)
        let shown = try await world.bridge.runInPage("document.querySelector('[name=k1]').type", in: tab)
        XCTAssertEqual(shown, "text")
        let json = try await world.bridge.run(ObserverScript.source, in: tab)
        XCTAssertFalse(try ObservedPage.decode(json).elements.contains { $0.name == "Kod" })
        XCTAssertFalse(json.contains("9911"))
    }

    /// Review of 3.1 (P1-3): a page that answers the agent's waiting with a
    /// message bigger than the connection takes cannot end the one connection
    /// to the user's Chrome: the agent asks in its own world.
    @MainActor
    func testAPageCannotEndTheConnectionWithAHugeAnswer() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-85.test/")
        let title = try await world.bridge.run("document.title", in: tab)
        XCTAssertEqual(title, ChromeBridge.tabMark + "Site Eighty-Five")
        let state = await world.connection.state
        XCTAssertEqual(state, .open)
    }

    /// Review of 3.1 (P0-2): a trusted click reaches the chosen control and no
    /// other — a row whose centre holds a Delete button is clicked on its own
    /// words. Its risk, and any Yes, were judged on the row, never the button.
    @MainActor
    func testARowIsClickedOnItsOwnWordsNeverOnAControlInsideIt() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-86.test/")
        for name in ["Open conversation with Sam", "Open the card Delete card"] {
            let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: name), on: page), in: tab)
            XCTAssertEqual(aim.outcome, .aim, name)
            try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        }
        let log = try await world.bridge.run("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "opened;card opened;", "never a Delete")
    }

    /// Review of 3.1: a control inside a component's own shadow root answers
    /// the page's hit test with its host; the aim looks inside, so a Delete
    /// button there, at a row's centre, is never clicked for the row.
    @MainActor
    func testADeleteInsideAComponentAtARowsCentreIsNeverClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-89.test/")
        let aim = try await world.outcome(
            ActionScript.aim(for: try page.action(.click, on: "Open message from Alex"), on: page), in: tab)
        XCTAssertEqual(aim.outcome, .aim)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        let log = try await world.bridge.run("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "opened;", "never the Delete")
    }

    /// Review of 3.1, round 2 (P0): a Delete that nothing names a control — a
    /// span a delegated handler reads, a span or a focusable box with a
    /// listener of its own, a component with a closed shadow root, a frame —
    /// at a row's centre is never clicked for the row: the aim prefers a point
    /// where the topmost thing is the row itself.
    @MainActor
    func testADeleteNothingNamesAControlIsNeverClickedForItsRow() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-90.test/")
        for thread in ["A", "B", "C", "D", "E"] {
            let aim = try await world.outcome(
                ActionScript.aim(for: try page.action(.click, on: "Open thread \(thread)"), on: page), in: tab)
            XCTAssertEqual(aim.outcome, .aim, thread)
            try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        }
        let log = try await world.bridge.run("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "A opened;B opened;C opened;D opened;E opened;")
        // A row a frame covers whole is not clicked through the frame.
        let covered = try await world.outcome(
            ActionScript.aim(for: try page.action(.click, on: "Open thread F"), on: page), in: tab)
        XCTAssertEqual(covered.outcome, .covered)
    }

    /// Review of 3.1 (P1-2): controls whose face is something else are aimed
    /// at, not reported covered — a component's button with its words slotted
    /// in, a checkbox drawn by its label, a field under its own label.
    @MainActor
    func testAControlWhoseFaceIsSomethingElseIsAimedAt() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-86.test/")
        for name in ["Save changes", "Send message", "Email me updates"] {
            let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: name), on: page), in: tab)
            XCTAssertEqual(aim.outcome, .aim, name)
            try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        }
        let log = try await world.bridge.run("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "a pressed trusted=true;b pressed trusted=true;updates trusted=true;")
        let city = try page.action(.type, on: "Your city", payload: "Riga")
        let aim = try await world.outcome(ActionScript.aim(for: city, on: page), in: tab)
        XCTAssertEqual(aim.outcome, .aim)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        let focused = try await world.outcome(ActionScript.focused(for: city, on: page), in: tab)
        XCTAssertEqual(focused.outcome, .ready)
    }

    /// Review of 3.1 (P2-4, second review): a control off screen is checked
    /// again once the page has settled — a password field the scroll brought
    /// beside it, in no form, makes the step the user's part, and nothing is
    /// clicked.
    @MainActor
    func testAWallThatComesWithTheScrollStopsTheAim() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-87.test/")
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Continue reading"), on: page),
                                          in: tab)
        XCTAssertEqual(aim.outcome, .wall)
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "")
    }

    /// Owner decision 4: a login form of its own that the scroll brought does
    /// not stop a step outside it — the button sends none of its fields.
    @MainActor
    func testALoginFormThatComesWithTheScrollDoesNotStopAStepOutsideIt() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-101.test/")
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Continue reading"), on: page),
                                          in: tab)
        XCTAssertEqual(aim.outcome, .aim)
        let shown = try await world.bridge.runInPage("String(document.querySelectorAll('input[type=password]').length)", in: tab)
        XCTAssertEqual(shown, "1", "the form did come")
    }

    // MARK: - Review of A3d, round 2 (Codex, I-02)

    /// Frames inside a form in Chrome (P1-5): one of the page's own origin is
    /// read for secret fields, one of another origin — sandboxed, or another
    /// site in its own process — makes its form unknown, which counts as
    /// holding a secret; the aim at its submit is a wall.
    @MainActor
    func testFramesInsideAFormAreCountedInChrome() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-102.test/")
        for name in ["Nickname", "Continue", "Coupon", "Apply"] {
            XCTAssertEqual(page.elements.first { $0.name == name }?.touchesSecret, true, name)
        }
        for name in ["Note", "Save note"] {
            XCTAssertEqual(page.elements.first { $0.name == name }?.touchesSecret, false, name)
        }
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Continue"), on: page), in: tab)
        XCTAssertEqual(aim.outcome, .wall)
        let (_, hosted) = try await world.open("https://site-114.test/")
        XCTAssertEqual(hosted.elements.first { $0.name == "Continue order" }?.touchesSecret, true,
                       "a frame of another site inside the form")
        XCTAssertEqual(hosted.elements.first { $0.name == "Name on order" }?.touchesSecret, true)
    }

    /// A password the browser filled in reads as empty to the page's scripts
    /// until the user acts; Chrome marks the field `:autofill`. A button in no
    /// form that would send that form is then a wall (N-P1-2), and nothing is
    /// sent.
    @MainActor
    func testAnAutofilledPasswordStopsAButtonOutsideItsForm() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, empty) = try await world.open("https://site-103.test/")
        XCTAssertEqual(empty.elements.first { $0.name == "Sign in" }?.touchesSecret, false, "an empty login box")
        let session = tab.tabID
        _ = try await world.connection.send("DOM.enable", sessionID: session)
        _ = try await world.connection.send("CSS.enable", sessionID: session)
        let document = try await world.connection.send("DOM.getDocument", params: ["depth": 0], sessionID: session)
        let root = try XCTUnwrap(document["root"]?["nodeId"])
        let field = try await world.connection.send("DOM.querySelector", params: ["nodeId": root, "selector": "#pw"],
                                                    sessionID: session)
        _ = try await world.connection.send("CSS.forcePseudoState",
                                            params: ["nodeId": try XCTUnwrap(field["nodeId"]),
                                                     "forcedPseudoClasses": ["autofill"]], sessionID: session)
        let value = try await world.bridge.run("document.getElementById('pw').value", in: tab)
        XCTAssertEqual(value, "", "the page's scripts read no value")
        let page = try ObservedPage.decode(try await world.bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(page.elements.first { $0.name == "Sign in" }?.touchesSecret, true)
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Sign in"), on: page), in: tab)
        XCTAssertEqual(aim.outcome, .wall)
        let stale = try await world.outcome(ActionScript.aim(for: try empty.action(.click, on: "Sign in"), on: empty),
                                            in: tab)
        XCTAssertEqual(stale.outcome, .wall, "chosen while the box was empty")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/session" }, "the login form was not sent")
    }

    /// A practice form's empty password is the errand's to leave be (owner
    /// decision 4; 2026-10-20, b02): its user name and its submit touch no
    /// secret. Filled by the browser — `:autofill`, the page's scripts read it
    /// empty — the form could send it: every control of it is a wall, the
    /// submit and the user name chosen while the box was empty too, and
    /// nothing is sent. The password stays withheld.
    @MainActor
    func testAnAutofilledPasswordWallsItsOwnForm() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, empty) = try await world.open("https://site-497.test/")
        for name in ["Username", "submit"] {
            XCTAssertEqual(empty.elements.first { $0.name == name }?.touchesSecret, false, "empty: \(name)")
        }
        let session = tab.tabID
        _ = try await world.connection.send("DOM.enable", sessionID: session)
        _ = try await world.connection.send("CSS.enable", sessionID: session)
        let document = try await world.connection.send("DOM.getDocument", params: ["depth": 0], sessionID: session)
        let root = try XCTUnwrap(document["root"]?["nodeId"])
        let field = try await world.connection.send("DOM.querySelector", params: ["nodeId": root, "selector": "#password"],
                                                    sessionID: session)
        _ = try await world.connection.send("CSS.forcePseudoState",
                                            params: ["nodeId": try XCTUnwrap(field["nodeId"]),
                                                     "forcedPseudoClasses": ["autofill"]], sessionID: session)
        let value = try await world.bridge.run("document.getElementById('password').value", in: tab)
        XCTAssertEqual(value, "", "the page's scripts read no value")
        let page = try ObservedPage.decode(try await world.bridge.run(ObserverScript.source, in: tab))
        XCTAssertNil(page.elements.first { $0.name == "Password" }, "withheld")
        for name in ["Username", "Comments", "Checkbox 1", "submit"] {
            XCTAssertEqual(page.elements.first { $0.name == name }?.touchesSecret, true, name)
        }
        let press = try await world.outcome(ActionScript.aim(for: try empty.action(.click, on: "submit"), on: empty),
                                            in: tab)
        XCTAssertEqual(press.outcome, .wall, "chosen while the box was empty")
        let typing = try await world.outcome(
            ActionScript.aim(for: try empty.action(.type, on: "Username", payload: "Sam"), on: empty), in: tab)
        XCTAssertEqual(typing.outcome, .wall, "chosen while the box was empty")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/submit" }, "the form was not sent")
    }

    /// A search box that becomes a password box when a person's click gives
    /// it the focus is the user's part (P2-4): the check before typing
    /// answers wall, and nothing is typed.
    @MainActor
    func testASearchBoxThatTurnsIntoAPasswordOnFocusIsAWallInChrome() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-104.test/")
        let action = try page.action(.type, on: "Quick find", payload: "hello")
        let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: tab)
        XCTAssertEqual(aim.outcome, .aim)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        let type = try await world.bridge.runInPage("document.getElementById('flip').type", in: tab)
        XCTAssertEqual(type, "password", "the page turned it")
        let focused = try await world.outcome(ActionScript.focused(for: action, on: page), in: tab)
        XCTAssertEqual(focused.outcome, .wall)
        // One that changes its name as well on focus (N3-P2-2).
        let lookup = try page.action(.type, on: "Lookup", payload: "hello")
        let lookupAim = try await world.outcome(ActionScript.aim(for: lookup, on: page), in: tab)
        XCTAssertEqual(lookupAim.outcome, .wall, "the box turned above is a secret in no form now")
        let (freshTab, freshPage) = try await world.open("https://site-104.test/")
        let both = try freshPage.action(.type, on: "Lookup", payload: "hello")
        let bothAim = try await world.outcome(ActionScript.aim(for: both, on: freshPage), in: freshTab)
        XCTAssertEqual(bothAim.outcome, .aim)
        try await world.bridge.click(x: try XCTUnwrap(bothAim.x), y: try XCTUnwrap(bothAim.y), in: freshTab)
        let renamed = try await world.bridge.runInPage(
            "document.getElementById('both').type + '|' + document.getElementById('both').getAttribute('aria-label')", in: freshTab)
        XCTAssertEqual(renamed, "password|Kennung", "the page turned it and renamed it")
        let bothFocused = try await world.outcome(ActionScript.focused(for: both, on: freshPage), in: freshTab)
        XCTAssertEqual(bothFocused.outcome, .wall)
    }

    /// A password in a frame of the form stays a password in Chrome when the
    /// page shows its text between two looks (N3-P1-3): the aim is a wall.
    @MainActor
    func testAFramesPasswordShownAsTextStillStopsItsFormInChrome() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-115.test/")
        XCTAssertEqual(page.elements.first { $0.name == "Weiter" }?.touchesSecret, true)
        _ = try await world.bridge.runInPage("document.getElementById('show').click(); ''", in: tab)
        let type = try await world.bridge.runInPage(
            "document.getElementById('frame').contentDocument.getElementById('feld').type", in: tab)
        XCTAssertEqual(type, "text")
        let again = try ObservedPage.decode(try await world.bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(again.elements.first { $0.name == "Weiter" }?.touchesSecret, true)
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Weiter"), on: page), in: tab)
        XCTAssertEqual(aim.outcome, .wall)
    }

    /// Review of 3.1 (P1-1): a person's click lets a page open a window — a
    /// tab the agent never asked for, which the browser may put in front of
    /// the user's own. Since ITER-076 I-10 the agent's tab opens none at all:
    /// the page's own call says so, and only the agent's tab is there.
    @MainActor
    func testAWindowThePageOpensOnTheAgentsClickIsClosed() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-88.test/")
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Share this"), on: page),
                                          in: tab)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        let log = try await world.bridge.run("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "blocked;", "the page tried, and got no window")
        let open = try await world.agentTabCount()
        XCTAssertEqual(open, 1, "only the agent's own tab")
        try await world.bridge.closeTab(tab)
        let left = try await world.agentTabCount()
        XCTAssertEqual(left, 0)
    }

    /// Review of 3.1: a close is always carried out — a caller that was
    /// stopped still closes its tab.
    @MainActor
    func testAStoppedCallerStillClosesItsTab() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-2.test/")
        let bridge = world.bridge
        let closing = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await bridge.closeTab(tab)
        }
        try? await closing.value
        let left = try await world.agentTabCount()
        XCTAssertEqual(left, 0)
    }

    /// Review of 3.1: the tab of a set-up that failed, or that was stopped
    /// half-way, is closed — Chrome made it whatever happened to the caller.
    @MainActor
    func testATabWhoseSetUpFailsOrIsStoppedIsClosed() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        struct Refused: Error {}
        let failing = ChromeBridge(connection: world.connection, prepareTab: { _ in throw Refused() })
        do {
            _ = try await failing.openTab(URL(string: "https://site-2.test/")!)
            XCTFail("never opened")
        } catch {}
        let stopped = ChromeBridge(connection: world.connection, prepareTab: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let opening = Task { @MainActor in try await stopped.openTab(URL(string: "https://site-2.test/")!) }
        do {
            _ = try await opening.value
            XCTFail("never opened")
        } catch {}
        let left = try await world.agentTabCount()
        XCTAssertEqual(left, 0)
    }

    /// Review of 3.1, round 2: a window a page opens a while after the
    /// agent's click is never there either, while the agent's tab lives
    /// (ITER-076 I-10: none is opened).
    @MainActor
    func testAWindowOpenedAWhileAfterTheClickIsClosed() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-91.test/")
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Share later"), on: page),
                                          in: tab)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        try await Task.sleep(for: .milliseconds(1_500))
        let log = try await world.bridge.run("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "blocked;", "the page tried, and got no window")
        let open = try await world.agentTabCount()
        XCTAssertEqual(open, 1, "only the agent's own tab")
    }

    /// Review of 3.1, round 2: a person's click lets a page open the system's
    /// file picker — a dialog in the user's Chrome. The agent's tab takes the
    /// request instead, and no picker is shown.
    @MainActor
    func testAFilePickerThePageOpensIsNeverShown() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-92.test/")
        let events = await world.connection.events()
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Attach a file"), on: page),
                                          in: tab)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        let session = tab.tabID
        let taken = await Deadline.run(within: .seconds(3)) {
            for await event in events where event.method == "Page.fileChooserOpened" && event.sessionID == session {
                return true
            }
            return false
        } ?? false
        XCTAssertTrue(taken, "the request came to the agent, not to a dialog")
    }

    /// Review of 3.1, round 2 (Kimi): the agent's world is made without the
    /// page's console — Chrome would send all it kept (4 MB in a measure) each
    /// time the Runtime domain is turned on to read the world's id.
    @MainActor
    func testTheAgentsWorldIsMadeWithoutThePagesConsole() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let tab = try await world.bridge.openTab(URL(string: "https://site-93.test/")!)
        // Loaded and done talking — watched in the page's own world, so the
        // agent's is made only after the console holds the page's lines.
        let deadline = ContinuousClock.now + .seconds(10)
        while (try? await world.bridge.runInPage("document.readyState", in: tab)) != "complete",
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let events = await world.connection.events()
        let session = tab.tabID
        let console = Counter()
        let watching = Task {
            for await event in events where event.method == "Runtime.consoleAPICalled" && event.sessionID == session {
                console.add()
            }
        }
        let title = try await world.bridge.run("document.title", in: tab)
        XCTAssertEqual(title, ChromeBridge.tabMark + "Site Ninety-Three")
        try await Task.sleep(for: .milliseconds(500))
        watching.cancel()
        XCTAssertEqual(console.value, 0, "none of the page's console reached the agent")
    }

    /// 3.1c — a click is a person's click: a page that ignores scripted clicks
    /// (site-82 acts only on trusted events) still sees the agent's.
    @MainActor
    func testAClickIsAPersonsClick() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let once = FirstTime()
        let engine = ScriptedEngine(choice: { request in
            if let show = request.candidates.first(where: { $0.action.target?.name == "Show details" }), once.take() {
                return ScriptedEngine.pick(show)
            }
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        })
        let plan = try XCTUnwrap(AgentPlan(
            goal: "Show the details", subgoals: [.init(description: "Show the details", terms: ["details"])],
            searches: [URL(string: "https://site-82.test/")!], columns: ["Name"], sheetTitle: "Details",
            rowsWanted: 1, emptyCell: "n/a"))
        let record = await AgentRun(plan: plan, errandID: UUID(),
                                    collaborators: .init(bridge: world.bridge, engine: engine, writer: FakeWriter(),
                                                         sheet: FixtureSheet(), confirm: { _ in .no })).run()
        let click = try XCTUnwrap(record.steps.first { $0.operation == "click" })
        XCTAssertEqual(click.outcome, .acted, "the page saw the click, and its details changed")
    }

    /// 3.1c — typing is a person's typing: the page keeps what the agent types.
    @MainActor
    func testTypingIsAPersonsTyping() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-82.test/")
        let action = try page.action(.type, on: "Name", payload: "Sam")
        let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: tab)
        XCTAssertEqual(aim.outcome, .aim)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        let focused = try await world.outcome(ActionScript.focused(for: action, on: page), in: tab)
        XCTAssertEqual(focused.outcome, .ready)
        let typed = try await world.outcome(ActionScript.typeText(for: action, on: page), in: tab)
        XCTAssertEqual(typed.outcome, .done)
        let held = try await world.outcome(ActionScript.holds(action, on: page), in: tab)
        XCTAssertEqual(held.outcome, .held, "the page kept a person's typing")
    }

    /// 3.1c — the agent never clicks through something covering the control.
    @MainActor
    func testACoveredControlIsNotClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-82.test/")
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Hidden behind"), on: page),
                                          in: tab)
        XCTAssertEqual(aim.outcome, .covered)
    }

    /// 2026-10-21, blind b03: a field the page shows under a banner fixed to the window's foot — on screen, its centre
    /// covered — is brought to the middle of the window, out from under the banner, and aimed at there: the click
    /// lands on it.
    @MainActor
    func testAFieldUnderABannerFixedToTheWindowIsBroughtOutAndClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-541.test/")
        let action = try page.action(.click, on: "State")
        let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: tab)
        XCTAssertEqual(aim.outcome, .aim)
        let y = try XCTUnwrap(aim.y)
        XCTAssertTrue(y < Double(ChromeBridge.viewport.height) - 110, "aimed above the banner, at \(y)")
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: y, in: tab)
        let log = try await world.bridge.run("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "State pressed")
    }

    /// Its pair: a veil over the whole window, as a modal's backdrop is, still covers the field wherever it is
    /// brought: nothing is clicked.
    @MainActor
    func testAFieldUnderAVeilOverTheWholeWindowIsStillCovered() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-541.test/?veiled")
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "State"), on: page), in: tab)
        XCTAssertEqual(aim.outcome, .covered)
        let log = try await world.bridge.run("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "")
    }

    /// Review of 3.1 (P2-4): a control inside a component's shadow root is
    /// not clicked through an overlay of the page's own, and one in the open
    /// is aimed at.
    @MainActor
    func testAControlInAShadowRootIsAimedAtOnlyWhenNothingCoversIt() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-82.test/")
        let covered = try await world.outcome(
            ActionScript.aim(for: try page.action(.click, on: "Inside a shadow"), on: page), in: tab)
        XCTAssertEqual(covered.outcome, .covered)
        let open = try await world.outcome(
            ActionScript.aim(for: try page.action(.click, on: "Shadow in the open"), on: page), in: tab)
        XCTAssertEqual(open.outcome, .aim)
    }

    /// 3.1c — a control below the fold is brought on screen and aimed at once
    /// the page has settled, on a page that scrolls smoothly and moves things
    /// when scrolled: the click lands on it, after the page's own reactions.
    @MainActor
    func testAControlOffScreenIsBroughtOnAndClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-82.test/")
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Far below"), on: page),
                                          in: tab)
        XCTAssertEqual(aim.outcome, .aim)
        let y = try XCTUnwrap(aim.y)
        XCTAssertTrue((0..<Double(ChromeBridge.viewport.height)).contains(y), "aimed on screen, at \(y)")
        try await Task.sleep(for: .milliseconds(100))
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: y, in: tab)
        let log = try await world.bridge.run("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "Far below pressed")
    }

    /// 3.1c — text goes in only while its own field holds the focus: a field
    /// whose page hands the focus on is not typed in.
    @MainActor
    func testTypingWaitsForItsFieldToHoldTheFocus() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-82.test/")
        let action = try page.action(.type, on: "Moves on", payload: "Sam")
        let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: tab)
        XCTAssertEqual(aim.outcome, .aim)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        let focused = try await world.outcome(ActionScript.focused(for: action, on: page), in: tab)
        XCTAssertEqual(focused.outcome, .gone)
    }

    /// 3.1c — as jev-ultrafast finds a target again before input: a disabled
    /// control is not aimed at, and neither is a read-only field for writing —
    /// though it is still clicked, as a date field that opens a picker is.
    @MainActor
    func testADisabledControlOrAReadOnlyFieldIsNotAimedAt() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-82.test/")
        let disabled = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Not yet"), on: page),
                                               in: tab)
        XCTAssertEqual(disabled.outcome, .gone)
        let write = try await world.outcome(
            ActionScript.aim(for: try page.action(.type, on: "Code", payload: "B-2"), on: page), in: tab)
        XCTAssertEqual(write.outcome, .gone)
        let click = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Code"), on: page),
                                            in: tab)
        XCTAssertEqual(click.outcome, .aim)
    }

    /// J1 end to end through Chrome: the whole loop, a scripted engine, the
    /// fixture pages — the same errand `AgentRunTests` runs in WebKit.
    @MainActor
    func testJ1CollectsTheSitesThroughChrome() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let sheet = FixtureSheet()
        let plan = try XCTUnwrap(AgentPlan(
            goal: "Add three competitor sites to a sheet",
            subgoals: [.init(description: "Find a competitor's site", terms: ["voice", "notes"])],
            searches: [URL(string: "https://search.test/?q=voice+notes")!], columns: ["Name", "URL", "What they do"],
            sheetTitle: "Competitors", rowsWanted: 3, emptyCell: "n/a"))
        let run = AgentRun(plan: plan, errandID: UUID(),
                           collaborators: .init(bridge: world.bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertEqual(record.ending, .done, "\(record.steps.map { "\($0.operation):\($0.outcome)" })")
        XCTAssertEqual(record.rows.map { $0.source.host }, ["site-1.test", "site-2.test", "site-3.test"])
        XCTAssertNotNil(record.sheet)
        let tabs = try await world.agentTabCount()
        XCTAssertEqual(tabs, 0, "no tab left open")
        XCTAssertTrue(world.fixtures.blocked.isEmpty, "nothing tried to leave the test pages: \(world.fixtures.blocked)")
    }
}

extension ObservedPage {
    /// An action on the element the page names `name`.
    func action(_ operation: AgentOperation, on name: String, payload: String? = nil) throws -> AgentAction {
        AgentAction(operation: operation, target: try XCTUnwrap(elements.first { $0.name == name }, name),
                    destination: nil, payload: payload, isPlannedSearch: false)
    }
}

/// A count kept from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// True the first time only.
final class FirstTime: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}

/// A headless Chrome, a connection to it, the bridge, and the fixture pages
/// served from inside Chrome — through a proxy that can hold or keep a call,
/// when asked for one.
@MainActor
final class ChromeWorld {
    let chrome: TestChrome
    let connection: CDPConnection
    let bridge: ChromeBridge
    let fixtures: ChromeFixtures
    /// The pages Chrome had before the test: its own first blank page.
    let before: Set<String>
    /// Between the connection and Chrome, when the world was started with one.
    let proxy: CDPProxy?

    private init(chrome: TestChrome, connection: CDPConnection, bridge: ChromeBridge, fixtures: ChromeFixtures,
                 before: Set<String>, proxy: CDPProxy?) {
        self.chrome = chrome
        self.connection = connection
        self.bridge = bridge
        self.fixtures = fixtures
        self.before = before
        self.proxy = proxy
    }

    /// `resolve`: what the Mac's resolver answers the bridge's guard for a
    /// name (ITER-076 stage 9e) — by default, what it answers for the
    /// fixtures' names.
    static func start(proxied: Bool = false, resolve: @escaping ChromeBridge.Resolver = ChromeFixtures.resolve)
        async throws -> ChromeWorld {
        let chrome = try await TestChrome.launch()
        let proxy = proxied ? try await CDPProxy.start(to: chrome.endpoint.webSocketURL) : nil
        let connection = CDPConnection(url: proxy?.url ?? chrome.endpoint.webSocketURL)
        try await connection.open()
        let fixtures = ChromeFixtures(connection: connection)
        await fixtures.start()
        let bridge = ChromeBridge(connection: connection, prepareTab: { session in
            try await fixtures.serve(session)
        }, resolve: resolve)
        let before = Set(try await pages(on: connection))
        return ChromeWorld(chrome: chrome, connection: connection, bridge: bridge, fixtures: fixtures, before: before,
                           proxy: proxy)
    }

    private static func pages(on connection: CDPConnection) async throws -> [String] {
        let targets = try await connection.send("Target.getTargets")
        return (targets["targetInfos"]?.array ?? []).filter { $0["type"]?.string == "page" }
            .compactMap { $0["targetId"]?.string }
    }

    func stop() {
        fixtures.stop()
        let connection = connection
        Task { await connection.close() }
        proxy?.stop()
        chrome.quit()
    }

    /// Waits until the page's own world says `pathname readyState`.
    func waitUntilPageIs(_ state: String, in tab: BrowserTab, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await bridge.runInPage("location.pathname + ' ' + document.readyState", in: tab)) == state { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("the page never was \(state)")
    }

    /// Until the page is complete — every subresource in — as the tests
    /// read their fixtures whole.
    func waitUntilLoaded(_ tab: BrowserTab, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await bridge.run("document.readyState", in: tab)) == "complete" { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("the page did not load")
    }

    /// A fixture page, loaded, and what the observer reports on it.
    func open(_ address: String) async throws -> (BrowserTab, ObservedPage) {
        let tab = try await bridge.openTab(URL(string: address)!)
        try await waitUntilLoaded(tab)
        return (tab, try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab)))
    }

    /// What an action script answers in the tab.
    func outcome(_ script: String?, in tab: BrowserTab) async throws -> ActionOutcome {
        try ActionOutcome.decode(try await bridge.run(try XCTUnwrap(script), in: tab))
    }

    /// Every page opened since the test began — blank ones included, so a
    /// leaked blank tab counts (review of 3.1).
    func agentTabCount() async throws -> Int {
        try await Self.pages(on: connection).filter { !before.contains($0) }.count
    }
}

/// Serves the fixture pages to Chrome through the Fetch domain: every request
/// in the agent's tabs — and in their frames that run in a process of their
/// own — is paused on a session of the fixtures' own; a `.test` address gets
/// its fixture, anything else is refused and recorded. The fixtures act on
/// their own sessions' requests only: the bridge's guard pauses requests on
/// sessions of its own (ITER-076 I-09).
@MainActor
final class ChromeFixtures {
    private let connection: CDPConnection
    private var listener: Task<Void, Never>?
    private var sessions: Set<String> = []
    private(set) var served: [URL] = []
    private(set) var blocked: [String] = []

    init(connection: CDPConnection) {
        self.connection = connection
    }

    /// What the Mac's resolver answers the bridge's guard for the fixtures'
    /// names (ITER-076 stage 9e): none has an address — none is on any
    /// network — so each document goes on to the fixtures, and no name is
    /// ever looked up.
    nonisolated static let resolve: ChromeBridge.Resolver = { _ in [] }

    func start() async {
        let events = await connection.events()
        let connection = connection
        listener = Task { [weak self] in
            for await event in events where event.method == "Fetch.requestPaused" {
                guard let self, let session = event.sessionID, self.sessions.contains(session),
                      let requestID = event.params["requestId"]?.string,
                      let address = event.params["request"]?["url"]?.string else { continue }
                let url = URL(string: address)
                // A `.test` address under `/never/` is never answered: a
                // request that hangs, as a slow server's does (ITER-076 I-07).
                if let url, url.host?.lowercased().hasSuffix(".test") == true, url.path.hasPrefix("/never/") {
                    continue
                }
                if let url, url.host?.lowercased().hasSuffix(".test") == true,
                   let response = try? FixtureRouter.response(for: url) {
                    self.served.append(url)
                    let headers = response.headers.map { CDPValue.object(["name": .string($0.name), "value": .string($0.value)]) }
                    _ = try? await connection.send("Fetch.fulfillRequest", params: [
                        "requestId": .string(requestID), "responseCode": .number(Double(response.status)),
                        "responseHeaders": .array(headers), "body": .string(response.body.base64EncodedString()),
                    ], sessionID: session)
                } else {
                    self.blocked.append(address)
                    _ = try? await connection.send("Fetch.failRequest", params: [
                        "requestId": .string(requestID), "errorReason": "BlockedByClient",
                    ], sessionID: session)
                }
            }
        }
    }

    /// Turns on the pause for every request of a new tab or frame, before it
    /// loads.
    func serve(_ session: String) async throws {
        sessions.insert(session)
        _ = try await connection.send("Fetch.enable", params: ["patterns": [["urlPattern": "*"]]],
                                      sessionID: session)
    }

    func stop() {
        listener?.cancel()
    }
}

/// A test's bridge around the real one: what it does not change goes to
/// Chrome as it is — a frame's point, the frames, what the tab did, a Yes,
/// the tab's history and the windows its pages asked for.
@MainActor
protocol WrapsChromeBridge: TrustedInputBridge {
    var inner: ChromeBridge { get }
}

extension WrapsChromeBridge {
    func point(x: Double, y: Double, in tab: BrowserTab) async throws -> (x: Double, y: Double)? {
        try await inner.point(x: x, y: y, in: tab)
    }
    func frames(of tab: BrowserTab) async throws -> FrameListing { try await inner.frames(of: tab) }
    func events(in tab: BrowserTab) -> [BrowserEvent] { inner.events(in: tab) }
    func approve(_ act: ApprovedAct?, in tab: BrowserTab) { inner.approve(act, in: tab) }
    func history(of tab: BrowserTab) async throws -> BrowserHistory { try await inner.history(of: tab) }
    func goBack(to entry: Int, in tab: BrowserTab) async throws { try await inner.goBack(to: entry, in: tab) }
    func windowsOpened(in tab: BrowserTab) -> [String] { inner.windowsOpened(in: tab) }
    func holdSends(_ held: Bool, in tab: BrowserTab) async -> Bool { await inner.holdSends(held, in: tab) }
    func letNavigate(to address: String, in tab: BrowserTab) { inner.letNavigate(to: address, in: tab) }
}
