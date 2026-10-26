import XCTest
@testable import MetaWhisp

/// Level 2 (ITER-074 §6.3, §6.5): the app's own action scripts on real HTML.
/// An action on an element finds it again in a fresh walk, in the same
/// script run as the action, so nothing can change between the look-up and
/// the act; a vanished element or ambiguous twins get no action at all.
final class ActionScriptTests: XCTestCase {

    @MainActor
    private func open(_ address: String) async throws -> (WebViewBridge, BrowserTab) {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: address)!)
        try await bridge.waitUntilLoaded(tab)
        return (bridge, tab)
    }

    @MainActor
    private func observe(_ bridge: WebViewBridge, _ tab: BrowserTab) async throws -> ObservedPage {
        try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
    }

    @MainActor
    private func perform(_ action: AgentAction, on page: ObservedPage, _ bridge: WebViewBridge,
                         _ tab: BrowserTab) async throws -> ActionOutcome {
        let script = try XCTUnwrap(ActionScript.source(for: action, on: page))
        return try ActionOutcome.decode(try await bridge.run(script, in: tab))
    }

    private func action(_ operation: AgentOperation, on target: ObservedElement?, payload: String? = nil,
                        destination: String? = nil) -> AgentAction {
        AgentAction(operation: operation, target: target, destination: destination, payload: payload,
                    isPlannedSearch: false)
    }

    private func named(_ name: String, in page: ObservedPage) -> ObservedElement? {
        page.elements.first { $0.name == name }
    }

    // MARK: - A list that takes several choices

    /// Choosing in a list that takes several choices adds the option, as a click with the command key does — it never
    /// takes the others away; a list of one choice still changes its choice (2026-10-21, blind b02: "Selection Item 2
    /// and 4" ended with Item 2 alone, every choice replacing the one before).
    @MainActor
    func testChoosingInAListOfSeveralAddsTheOption() async throws {
        let (bridge, tab) = try await open("https://site-512.test/")
        let page = try await observe(bridge, tab)
        let extras = try XCTUnwrap(named("Extras", in: page))
        XCTAssertEqual(extras.role, "listbox")
        let added = try await perform(action(.select, on: extras, payload: "Card"), on: page, bridge, tab)
        XCTAssertEqual(added.outcome, .done)
        let chosen = try await bridge.run(
            "Array.from(document.getElementById('extras').selectedOptions).map(o => o.text).join(',')", in: tab)
        XCTAssertEqual(chosen, "Card,Box", "the choice already made stays")
        let after = try await observe(bridge, tab)
        let card = try XCTUnwrap(ActionScript.holds(action(.select, on: named("Extras", in: after), payload: "Card"),
                                                    on: after))
        let cardHeld = try ActionOutcome.decode(try await bridge.run(card, in: tab))
        XCTAssertEqual(cardHeld.outcome, .held)

        let size = try XCTUnwrap(named("Size", in: after))
        _ = try await perform(action(.select, on: size, payload: "Large"), on: after, bridge, tab)
        let one = try await bridge.run(
            "Array.from(document.getElementById('size').selectedOptions).map(o => o.text).join(',')", in: tab)
        XCTAssertEqual(one, "Large", "a list of one choice changes it")
    }

    // MARK: - A choice asked about as a send (2026-10-21)

    /// A choice in a form its own button sends commits nothing by itself; made again with the user's Yes bound to the
    /// form's values — a choice whose change the page sends — it is a send to the hands, as a press is: it is looked up
    /// alone first, and a card field that came since the look walls it, where the same choice unbound goes.
    @MainActor
    func testAChoiceBoundToTheFormsValuesCommitsAtTheHands() async throws {
        let (bridge, tab) = try await open("https://site-531.test/")
        let page = try await observe(bridge, tab)
        let author = try XCTUnwrap(named("Author", in: page))
        let choose = action(.select, on: author, payload: "Sam Lee")
        XCTAssertFalse(SafetyGuard.commits(choose), "a form its own button sends")
        XCTAssertFalse(ActionScript.commits(choose, nil))
        XCTAssertNil(ActionScript.found(for: choose, on: page))
        let approval = ActionScript.Approval(pageURL: page.liveAddress, text: author.text,
                                             formSubmitLabel: author.formSubmitLabel, submits: author.submits,
                                             formGrants: author.formGrants, paymentForm: page.flags.paymentForm,
                                             listForm: author.listForm,
                                             formValues: page.elements.compactMap { ActionScript.BoundValue($0, on: page) })
        XCTAssertTrue(ActionScript.commits(choose, approval))
        let lookup = try XCTUnwrap(ActionScript.found(for: choose, on: page, approval: approval))
        let looked = try ActionOutcome.decode(try await bridge.run(lookup, in: tab))
        XCTAssertEqual(looked.outcome, .found)
        _ = try await bridge.run("const card = document.createElement('input'); card.setAttribute('autocomplete', "
                                 + "'cc-number'); document.body.appendChild(card); 'ok'", in: tab)
        let bound = try XCTUnwrap(ActionScript.source(for: choose, on: page, approval: approval))
        let walled = try ActionOutcome.decode(try await bridge.run(bound, in: tab))
        XCTAssertEqual(walled.outcome, .wall)
        XCTAssertEqual(walled.why, "paymentForm")
        let untouched = try await bridge.run("document.getElementById('author').value", in: tab)
        XCTAssertEqual(untouched, "", "nothing was chosen")
        let unbound = try await perform(choose, on: page, bridge, tab)
        XCTAssertEqual(unbound.outcome, .done, "unbound, the choice commits nothing: no card walls it")
    }

    // MARK: - A form's Send, bound to its values (ITER-076 stage 7, № 93)

    /// The Send of site-440's demo form, bound to what its fields hold on
    /// `page`.
    private func boundSend(on page: ObservedPage) throws -> (AgentAction, ActionScript.Approval) {
        let send = try XCTUnwrap(named("Request a demo", in: page))
        let fields = page.elements.filter { $0.group == send.group }.compactMap { ActionScript.BoundValue($0, on: page) }
        XCTAssertEqual(fields.count, 6, "every field of the form is bound, the button not")
        let approval = ActionScript.Approval(pageURL: page.liveAddress, text: send.text,
                                             formSubmitLabel: send.formSubmitLabel, submits: send.submits,
                                             formGrants: send.formGrants,
                                             paymentForm: page.flags.paymentForm, listForm: send.listForm,
                                             formValues: fields)
        return (action(.click, on: send), approval)
    }

    /// A value changed after the Yes — by one character past what the report
    /// shows, or in its spaces — voids it: the click script reads every bound
    /// field again in the same run as the act, and does nothing.
    @MainActor
    func testASendIsVoidWhenAFieldItIsBoundToChanged() async throws {
        let long = String(repeating: "We would like a demo. ", count: 12)
        for change in ["document.getElementById('company').value = 'Other Corp'",
                       "document.getElementById('message').value += '!'",
                       "document.getElementById('first').value = 'Sam  '",
                       "document.getElementById('phone').remove()"] {
            let (bridge, tab) = try await open("https://site-440.test/")
            _ = try await bridge.run("""
                document.getElementById('first').value = 'Sam';
                document.getElementById('company').value = 'AcmeCorp';
                document.getElementById('message').value = '\(long)'; ''
                """, in: tab)
            let page = try await observe(bridge, tab)
            let (send, approval) = try boundSend(on: page)
            _ = try await bridge.run(change + "; ''", in: tab)
            let script = try XCTUnwrap(ActionScript.source(for: send, on: page, approval: approval))
            let outcome = try ActionOutcome.decode(try await bridge.run(script, in: tab))
            XCTAssertEqual(outcome.outcome, .changed, change)
            try await Task.sleep(for: .milliseconds(300))
            let path = try await bridge.run("location.pathname", in: tab)
            XCTAssertEqual(path, "/", "nothing sent: \(change)")
        }
    }

    /// A box the Send is bound to, ticked after the Yes, voids it too.
    @MainActor
    func testASendIsVoidWhenABoxItIsBoundToTurned() async throws {
        let (bridge, tab) = try await open("https://site-443.test/")
        let page = try await observe(bridge, tab)
        let send = try XCTUnwrap(named("Get my demo", in: page))
        let fields = page.elements.filter { $0.group == send.group }.compactMap { ActionScript.BoundValue($0, on: page) }
        XCTAssertEqual(fields.count, 8, "the eight fields, the list and the box among them")
        XCTAssertEqual(fields.filter { $0.checked != nil }.count, 1)
        let approval = ActionScript.Approval(pageURL: page.liveAddress, text: send.text,
                                             formSubmitLabel: send.formSubmitLabel, submits: send.submits,
                                             formGrants: send.formGrants, formValues: fields)
        _ = try await bridge.run("document.getElementById('agree').checked = true; ''", in: tab)
        let script = try XCTUnwrap(ActionScript.source(for: action(.click, on: send), on: page, approval: approval))
        let outcome = try ActionOutcome.decode(try await bridge.run(script, in: tab)).outcome
        XCTAssertEqual(outcome, .changed)
    }

    /// Unchanged, the bound Send goes out; the aim of a person's click
    /// checks the values too.
    @MainActor
    func testABoundSendGoesOutWhileEveryValueHolds() async throws {
        let (bridge, tab) = try await open("https://site-440.test/")
        _ = try await bridge.run("document.getElementById('first').value = 'Sam'; ''", in: tab)
        let page = try await observe(bridge, tab)
        let (send, approval) = try boundSend(on: page)
        let aim = try XCTUnwrap(ActionScript.aim(for: send, on: page, approval: approval))
        let aimed = try ActionOutcome.decode(try await bridge.run(aim, in: tab)).outcome
        XCTAssertEqual(aimed, .aim)
        _ = try await bridge.run("document.getElementById('last').value = 'Example'; ''", in: tab)
        let aimedAgain = try ActionOutcome.decode(try await bridge.run(aim, in: tab)).outcome
        XCTAssertEqual(aimedAgain, .changed, "the aim right before a person's click reads them too")
        _ = try await bridge.run("document.getElementById('last').value = ''; ''", in: tab)
        let script = try XCTUnwrap(ActionScript.source(for: send, on: page, approval: approval))
        let sent = try ActionOutcome.decode(try await bridge.run(script, in: tab)).outcome
        XCTAssertEqual(sent, .done)
    }

    // MARK: - Actions on elements

    @MainActor
    func testAClickReachesTheButton() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let outcome = try await perform(action(.click, on: named("Show details", in: page)), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
        let after = try await observe(bridge, tab)
        XCTAssertNotNil(named("Hide details", in: after))
    }

    /// ITER-076 2.2 (S3): a password or card field that appeared after the
    /// choice stops the act; the page is now the user's part.
    @MainActor
    func testAClickIsRefusedWhenASecretFieldAppearedAfterTheChoice() async throws {
        for field in ["<input type=password aria-label=Code>", "<input autocomplete=cc-number aria-label=Card>"] {
            let (bridge, tab) = try await open("https://site-26.test/")
            let page = try await observe(bridge, tab)
            let show = try XCTUnwrap(named("Show details", in: page))
            _ = try await bridge.run("document.querySelector('main').insertAdjacentHTML('beforeend', '\(field)'); ''", in: tab)
            let outcome = try await perform(action(.click, on: show), on: page, bridge, tab)
            XCTAssertEqual(outcome.outcome, .wall, field)
            let after = try await observe(bridge, tab)
            XCTAssertNil(named("Hide details", in: after), "nothing was clicked: \(field)")
        }
    }

    /// ITER-076 2.2: opening a link only leaves the page, so a secret field
    /// that appeared on it does not keep the agent there.
    @MainActor
    func testOpenStillLeavesAPageThatNowAsksForASecret() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let link = try XCTUnwrap(named("Next page", in: page))
        let field = "document.querySelector('main').insertAdjacentHTML('beforeend', '<input type=password aria-label=Code>'); ''"
        _ = try await bridge.run(field, in: tab)
        let outcome = try await perform(action(.open, on: link, destination: link.href), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
        try await bridge.waitForURL(URL(string: "https://site-26.test/next")!, in: tab)
    }

    /// ITER-076 2.2: what the risk checks read about a control — whether it
    /// sends its form, whether the form grants access — is bound at the act
    /// like its words: a control that changed since the check is not acted on.
    @MainActor
    func testAControlThatNowSendsItsFormOrGrantsIsNotActedOn() async throws {
        let cases = [
            ("Later", "document.getElementById('first').type = 'submit'; ''"),
            ("Continue", "document.getElementById('prefs').insertAdjacentHTML('beforeend', "
                + "'<input type=hidden name=client_id value=a><input type=hidden name=redirect_uri value=https://b.test/cb>'); ''"),
        ]
        for (name, change) in cases {
            let (bridge, tab) = try await open("https://site-56.test/")
            let page = try await observe(bridge, tab)
            let control = try XCTUnwrap(named(name, in: page))
            _ = try await bridge.run(change, in: tab)
            let outcome = try await perform(action(.click, on: control), on: page, bridge, tab)
            XCTAssertEqual(outcome.outcome, .gone, name)
            try await Task.sleep(for: .milliseconds(300))
            let address = try await bridge.run("location.href", in: tab)
            XCTAssertEqual(address, "https://site-56.test/", "the form was not sent: \(name)")
        }
    }

    /// ITER-076 2.2: the wall is what the page asks for, not its size. A page
    /// cut at the element cap, with no secret field, still takes typing.
    @MainActor
    func testTypingStillWorksOnAPageCutAtTheElementCap() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let flood = "for (let i = 0; i < 600; i++) document.body.insertAdjacentHTML('beforeend', '<button>More ' + i + '</button>'); ''"
        _ = try await bridge.run(flood, in: tab)
        let page = try await observe(bridge, tab)
        XCTAssertTrue(page.truncated, "the page is cut at the cap")
        let outcome = try await perform(action(.type, on: named("Search the docs", in: page), payload: "voice notes"),
                                         on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
        let value = try await bridge.run("document.querySelector('input[type=search]').value", in: tab)
        XCTAssertEqual(value, "voice notes")
    }

    @MainActor
    func testTypingFillsTheField() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let outcome = try await perform(action(.type, on: named("Search the docs", in: page), payload: "voice notes"),
                                         on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
        let value = try await bridge.run("document.querySelector('input[type=search]').value", in: tab)
        XCTAssertEqual(value, "voice notes")
    }

    /// ITER-076 2.3: whether a field shows what was written is read in the
    /// page, and only the answer comes back — never the value.
    @MainActor
    func testTheHoldsCheckAnswersWithoutTheValue() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let search = try XCTUnwrap(named("Search the docs", in: page))
        _ = try await perform(action(.type, on: search, payload: "voice notes"), on: page, bridge, tab)
        let held = try XCTUnwrap(ActionScript.holds(action(.type, on: search, payload: "voice  notes"), on: page))
        let reply = try await bridge.run(held, in: tab)
        XCTAssertEqual(try ActionOutcome.decode(reply).outcome, .held, "whitespace is compared as it reads")
        XCTAssertFalse(reply.contains("voice"), "the value never leaves the page")
        let other = try XCTUnwrap(ActionScript.holds(action(.type, on: search, payload: "other words"), on: page))
        let otherReply = try await bridge.run(other, in: tab)
        XCTAssertEqual(try ActionOutcome.decode(otherReply).outcome, .differs)
        let billing = try XCTUnwrap(named("Billing period", in: page))
        let monthly = try XCTUnwrap(ActionScript.holds(action(.select, on: billing, payload: "Monthly"), on: page))
        let monthlyReply = try await bridge.run(monthly, in: tab)
        XCTAssertEqual(try ActionOutcome.decode(monthlyReply).outcome, .held)
        XCTAssertNil(ActionScript.holds(action(.click, on: search), on: page), "only a typed or selected field")
    }

    /// Review of 2.3: a page may rewrite its own address when a field
    /// changes, as a sort select does. The check follows the field, not the
    /// address: it is found again and still shows what was chosen.
    @MainActor
    func testTheHoldsCheckFollowsTheFieldWhenThePageRewritesItsAddress() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let billing = try XCTUnwrap(named("Billing period", in: page))
        _ = try await perform(action(.select, on: billing, payload: "Yearly"), on: page, bridge, tab)
        _ = try await bridge.run("history.replaceState(null, '', '/?period=yearly'); ''", in: tab)
        let check = try XCTUnwrap(ActionScript.holds(action(.select, on: billing, payload: "Yearly"), on: page))
        let reply = try await bridge.run(check, in: tab)
        XCTAssertEqual(try ActionOutcome.decode(reply).outcome, .held)
    }

    /// Review of 2.3, round 2: the holds check stays on the page's own
    /// origin. A look-alike field on another site is never read.
    @MainActor
    func testTheHoldsCheckStaysOnThePagesOrigin() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let billing = try XCTUnwrap(named("Billing period", in: page))
        _ = try await bridge.run("location.assign('https://site-71.test/'); ''", in: tab)
        try await bridge.waitForURL(URL(string: "https://site-71.test/")!, in: tab)
        let check = try XCTUnwrap(ActionScript.holds(action(.select, on: billing, payload: "Monthly"), on: page))
        let reply = try await bridge.run(check, in: tab)
        XCTAssertEqual(try ActionOutcome.decode(reply).outcome, .gone)
    }

    /// The origin the holds check stays on is written as `location.origin`
    /// is: scheme and host in lower case, no default port.
    func testAnOriginIsWrittenAsTheBrowserWritesIt() {
        XCTAssertEqual(ActionScript.origin(of: "https://Site-26.TEST/path?q=1#f"), "https://site-26.test")
        XCTAssertEqual(ActionScript.origin(of: "https://site-26.test:443/"), "https://site-26.test")
        XCTAssertEqual(ActionScript.origin(of: "http://site-26.test:8080/x"), "http://site-26.test:8080")
        XCTAssertNil(ActionScript.origin(of: "about:blank"))
        // Round 2 of the 2.3b review: a browser writes an international host
        // in punycode, and an IPv6 host in one pair of brackets.
        XCTAssertEqual(ActionScript.origin(of: "https://xn--bcher-kva.example/path"), "https://xn--bcher-kva.example")
        XCTAssertEqual(ActionScript.origin(of: "http://[::1]:8080/x"), "http://[::1]:8080")
        // Round 3 of the 2.3b review: only the scheme and host are read, so a
        // path or query a strict parser refuses cannot lose the origin.
        XCTAssertEqual(ActionScript.origin(of: "https://site-26.test/p[1]/?filter[color]=red|blue&q=%#a#b"),
                       "https://site-26.test")
        XCTAssertEqual(ActionScript.origin(of: "https://user:pw@site-26.test:8443/%zz"), "https://site-26.test:8443")
    }

    /// Review of 2.3b: the origin the check stays on comes from the app, not
    /// from the page, whose own `URL` may lie.
    @MainActor
    func testTheHoldsCheckOriginCannotBeFakedByThePage() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let billing = try XCTUnwrap(named("Billing period", in: page))
        _ = try await bridge.run("location.assign('https://site-71.test/'); ''", in: tab)
        try await bridge.waitForURL(URL(string: "https://site-71.test/")!, in: tab)
        _ = try await bridge.run("window.URL = function () { return { origin: location.origin }; }; ''", in: tab)
        let check = try XCTUnwrap(ActionScript.holds(action(.select, on: billing, payload: "Monthly"), on: page))
        let reply = try await bridge.run(check, in: tab)
        XCTAssertEqual(try ActionOutcome.decode(reply).outcome, .gone)
    }

    /// Review of 2.3, round 2: the holds check needs only the field. A select
    /// whose change relabels its form's submit button still answers held.
    @MainActor
    func testTheHoldsCheckNeedsOnlyTheField() async throws {
        let (bridge, tab) = try await open("https://site-73.test/")
        let page = try await observe(bridge, tab)
        let period = try XCTUnwrap(named("Plan period", in: page))
        XCTAssertEqual(period.formSubmitLabel, "Buy for $10 a month")
        let chosen = try await perform(action(.select, on: period, payload: "Yearly"), on: page, bridge, tab)
        XCTAssertEqual(chosen.outcome, .done)
        let check = try XCTUnwrap(ActionScript.holds(action(.select, on: period, payload: "Yearly"), on: page))
        let reply = try await bridge.run(check, in: tab)
        XCTAssertEqual(try ActionOutcome.decode(reply).outcome, .held)
    }

    /// Review of 2.3, round 2: the holds check still stops at a field that
    /// could now send a secret — a password that appeared in its own form,
    /// filled in (owner decision 4; empty, it sends none, 2026-10-21) — and at
    /// a field that is gone. A secret elsewhere on the page does not stop it.
    @MainActor
    func testTheHoldsCheckStillStopsAtAWallAndAtAGoneField() async throws {
        let (bridge, tab) = try await open("https://site-94.test/")
        let page = try await observe(bridge, tab)
        let search = try XCTUnwrap(named("Search guides", in: page))
        _ = try await perform(action(.type, on: search, payload: "voice memos"), on: page, bridge, tab)
        let check = try XCTUnwrap(ActionScript.holds(action(.type, on: search, payload: "voice memos"), on: page))
        let held = try await bridge.run(check, in: tab)
        XCTAssertEqual(try ActionOutcome.decode(held).outcome, .held, "the login form's password is elsewhere")
        _ = try await bridge.run("document.getElementById('search').insertAdjacentHTML('beforeend', '<input type=password id=code aria-label=Code>'); ''", in: tab)
        let empty = try await bridge.run(check, in: tab)
        XCTAssertEqual(try ActionOutcome.decode(empty).outcome, .held, "an empty password sends no secret")
        _ = try await bridge.run("document.getElementById('code').value = 'x9'; ''", in: tab)
        let walled = try await bridge.run(check, in: tab)
        XCTAssertEqual(try ActionOutcome.decode(walled).outcome, .wall)
        _ = try await bridge.run("document.getElementById('search').remove(); ''", in: tab)
        let gone = try await bridge.run(check, in: tab)
        XCTAssertEqual(try ActionOutcome.decode(gone).outcome, .gone)
    }

    /// Typing into an editor replaces its text through the editor's own
    /// editing, with the whole selection inside it (review round 10).
    @MainActor
    func testTypingIntoAnEditorReplacesItsText() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let outcome = try await perform(action(.type, on: named("Notes editor", in: page), payload: "new notes"),
                                         on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
        let text = try await bridge.run("document.getElementById('notes').textContent", in: tab)
        XCTAssertEqual(text, "new notes")
    }

    @MainActor
    func testSelectingChoosesTheOption() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let outcome = try await perform(action(.select, on: named("Billing period", in: page), payload: "Yearly"),
                                         on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
        let chosen = try await bridge.run("document.querySelector('select').selectedOptions[0].text", in: tab)
        XCTAssertEqual(chosen, "Yearly")
    }

    /// Open goes to the link's own address, and back returns through the
    /// tab's own history (ITER-076 I-10).
    @MainActor
    func testOpenFollowsTheLinkAndBackReturns() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let link = named("Next page", in: page)
        let opened = try await perform(action(.open, on: link, destination: link?.href), on: page, bridge, tab)
        XCTAssertEqual(opened.outcome, .done)
        try await bridge.waitForURL(URL(string: "https://site-26.test/next")!, in: tab)
        let history = try await bridge.history(of: tab)
        XCTAssertEqual(history.entries.map(\.url), ["https://site-26.test/", "https://site-26.test/next"])
        XCTAssertEqual(history.current, 1)
        try await bridge.goBack(to: history.entries[0].id, in: tab)
        try await bridge.waitForURL(URL(string: "https://site-26.test/")!, in: tab)
    }

    /// ITER-076 (2026-10-07): a link to a place on its own page is its page
    /// script's to show — a demo request's window, a tab's panel — so the
    /// action offered for it is a click, and the window opens; going to its
    /// address would only move the page to it, the script never told.
    @MainActor
    func testTheActionOfferedForALinkToAPlaceOnItsPageOpensWhatItsScriptShows() async throws {
        let (bridge, tab) = try await open("https://site-472.test/")
        let page = try await observe(bridge, tab)
        XCTAssertNil(named("Work email", in: page), "the premise: the window is closed")
        let offered = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: ["demo"]))
        let ask = try XCTUnwrap(offered.candidates.first { $0.action.target?.name == "Request a demo" }?.action)
        let outcome = try await perform(ask, on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
        let after = try await observe(bridge, tab)
        XCTAssertNotNil(named("Work email", in: after), "the window opened: \(ask.operation)")
    }

    /// ITER-076 broad set: a suggestion drawn as an option around its link is
    /// that link, of the option's list — found again as one, and opened.
    @MainActor
    func testASuggestionDrawnAsItsLinkIsFoundAgainAndOpened() async throws {
        let (bridge, tab) = try await open("https://site-471.test/")
        let page = try await observe(bridge, tab)
        let link = try XCTUnwrap(named("Incompleteness theorems", in: page))
        XCTAssertNotNil(link.listOf, "the premise: of the option's list")
        let opened = try await perform(action(.open, on: link, destination: link.href), on: page, bridge, tab)
        XCTAssertEqual(opened.outcome, .done)
        try await bridge.waitForURL(URL(string: "https://site-471.test/wiki/Incompleteness")!, in: tab)
    }

    @MainActor
    func testAPlannedSearchOpensItsOwnAddress() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let search = AgentAction(operation: .open, target: nil, destination: "https://search.test/?q=voice+notes",
                                 payload: nil, isPlannedSearch: true)
        let outcome = try await perform(search, on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
        try await bridge.waitForURL(URL(string: "https://search.test/?q=voice+notes")!, in: tab)
    }

    @MainActor
    func testScrollMovesTheViewport() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let outcome = try await perform(action(.scroll, on: nil), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
        XCTAssertEqual(outcome.moved, true)
    }

    /// ITER-076 I-10 (critic 16): a page that cannot scroll, whose results
    /// are in a tall panel that can, scrolls that panel — not the small list
    /// beside it — and the page stays; once the panel is at its end, nothing
    /// moves.
    @MainActor
    func testScrollMovesATallPanelWhenThePageCannotScroll() async throws {
        let (bridge, tab) = try await open("https://site-235.test/")
        let page = try await observe(bridge, tab)
        let outcome = try await perform(action(.scroll, on: nil), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
        XCTAssertEqual(outcome.moved, true)
        let moved = "[window.scrollY, document.getElementById('results').scrollTop > 0, "
            + "document.getElementById('tiny').scrollTop].join(' ')"
        let now = try await bridge.run(moved, in: tab)
        XCTAssertEqual(now, "0 true 0")
        _ = try await bridge.run("const r = document.getElementById('results'); r.scrollTop = r.scrollHeight; ''", in: tab)
        let atTheEnd = try await perform(action(.scroll, on: nil), on: page, bridge, tab)
        XCTAssertEqual(atTheEnd.moved, false)
    }

    /// A page that scrolls scrolls as before, and a panel in it stays.
    @MainActor
    func testScrollMovesThePageAndNotItsPanelWhenThePageCanScroll() async throws {
        let (bridge, tab) = try await open("https://site-236.test/")
        let page = try await observe(bridge, tab)
        let outcome = try await perform(action(.scroll, on: nil), on: page, bridge, tab)
        XCTAssertEqual(outcome.moved, true)
        let now = try await bridge.run("[window.scrollY > 0, document.getElementById('results').scrollTop].join(' ')",
                                       in: tab)
        XCTAssertEqual(now, "true 0")
    }

    // MARK: - Nothing happens to the wrong element

    /// An element that is gone — or changed — is not acted on (§6.3).
    @MainActor
    func testAVanishedElementIsNotActedOn() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let shown = try XCTUnwrap(named("Show details", in: page))
        let vanished = ObservedElement(index: shown.index, role: shown.role, name: "Vanished", text: "Vanished",
                                       href: nil, inputType: nil, heading: shown.heading, region: shown.region,
                                       inViewport: true, context: nil, formAction: nil, formMethod: nil,
                                       formSubmitLabel: nil, options: nil, checked: nil)
        let outcome = try await perform(action(.click, on: vanished), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .gone)
        let after = try await observe(bridge, tab)
        XCTAssertNotNil(named("Show details", in: after), "nothing was clicked")
    }

    /// Twin buttons may act on different things; neither is pressed.
    @MainActor
    func testTwinButtonsAreNotActedOn() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let outcome = try await perform(action(.click, on: named("Delete", in: page)), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .ambiguous)
        let after = try await observe(bridge, tab)
        XCTAssertEqual(after.elements.filter { $0.name == "Delete" }.count, 2)
    }

    /// A practice form's date field and subjects box, named by the words before them in their own rows, are no
    /// twins: typing into either acts, where unnamed it was refused as ambiguous (2026-10-21, a live run).
    @MainActor
    func testTypingIntoAFieldNamedByItsGroupActs() async throws {
        let (bridge, tab) = try await open("https://site-510.test/")
        let page = try await observe(bridge, tab)
        for (name, text, id) in [("Date of Birth", "12 Nov 1998", "dob-input"), ("Subjects", "Maths", "subjects-input")] {
            let field = try XCTUnwrap(named(name, in: page), "\(page.elements.map(\.name))")
            let outcome = try await perform(action(.type, on: field, payload: text), on: page, bridge, tab)
            XCTAssertEqual(outcome.outcome, .done, name)
            let value = try await bridge.run("document.getElementById('\(id)').value", in: tab)
            XCTAssertEqual(value, text, name)
        }
    }

    /// A practice form's boxes and radios, named by the words drawn after each, are no twins: a click on "Checkbox 2"
    /// or "radio 3" acts and ticks that one, where unnamed it was refused as ambiguous (2026-10-21, a live run).
    @MainActor
    func testClickingABoxNamedByItsLineActs() async throws {
        let (bridge, tab) = try await open("https://site-511.test/")
        let page = try await observe(bridge, tab)
        for (name, value) in [("Checkbox 2", "cb2"), ("radio 3", "rd3")] {
            let box = try XCTUnwrap(named(name, in: page), "\(page.elements.map(\.name))")
            let outcome = try await perform(action(.click, on: box), on: page, bridge, tab)
            XCTAssertEqual(outcome.outcome, .done, name)
            let ticked = try await bridge.run("String(document.querySelector('input[value=\(value)]').checked)", in: tab)
            XCTAssertEqual(ticked, "true", name)
        }
    }

    /// A sensitive field is never typed into, whatever a stale candidate
    /// says: the field is never reported, so it cannot be found again
    /// (owner decision 4 keeps it hidden; the page itself no longer stops
    /// the act).
    @MainActor
    func testASensitiveFieldIsNeverTypedInto() async throws {
        let (bridge, tab) = try await open("https://site-5.test/")
        let page = try await observe(bridge, tab)
        let password = ObservedElement(index: 0, role: "textbox", name: "Password", text: "", href: nil,
                                       inputType: "password", heading: page.elements.first?.heading, region: .main,
                                       inViewport: true, context: nil, formAction: nil, formMethod: nil,
                                       formSubmitLabel: nil, options: nil, checked: nil)
        let outcome = try await perform(action(.type, on: password, payload: "guess"), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .gone)
        let value = try await bridge.run("document.getElementById('pass').value", in: tab)
        XCTAssertEqual(value, "not-a-real-secret", "nothing was typed")
    }

    // MARK: - Review round 11: a Yes holds only for what was approved

    /// An approved action checks, in the same script as the act, that the
    /// page and the element's words are still what the user said yes to: a
    /// button whose label stays "Confirm payment" but now shows "Pay $100" is
    /// not pressed.
    @MainActor
    func testAnApprovedActionIsNotTakenWhenItsWordsChanged() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let pay = try XCTUnwrap(named("Confirm payment", in: page))
        let approval = ActionScript.Approval(pageURL: page.url, text: pay.text, formSubmitLabel: pay.formSubmitLabel,
                                             submits: pay.submits, formGrants: pay.formGrants)
        _ = try await bridge.run("document.getElementById('pay').textContent = 'Pay $100'; ''", in: tab)
        let script = try XCTUnwrap(ActionScript.source(for: action(.click, on: pay), on: page, approval: approval))
        let outcome = try ActionOutcome.decode(try await bridge.run(script, in: tab))
        XCTAssertEqual(outcome.outcome, .gone)
        let title = try await bridge.run("document.title", in: tab)
        XCTAssertEqual(title, "Site Twenty-Six", "nothing was paid")
    }

    /// Every action is bound to the page and the words the checks saw, not
    /// only an approved one: a button whose label stays "Confirm payment" but
    /// whose text changes between the check and the act is not pressed
    /// (review round 12).
    @MainActor
    func testAnActionIsNotTakenWhenItsWordsChangedAfterTheCheck() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let pay = try XCTUnwrap(named("Confirm payment", in: page))
        _ = try await bridge.run("document.getElementById('pay').textContent = 'Pay $100'; ''", in: tab)
        let script = try XCTUnwrap(ActionScript.source(for: action(.click, on: pay), on: page))
        let outcome = try ActionOutcome.decode(try await bridge.run(script, in: tab))
        XCTAssertEqual(outcome.outcome, .gone)
        let title = try await bridge.run("document.title", in: tab)
        XCTAssertEqual(title, "Site Twenty-Six", "nothing was paid")
    }

    /// The approval carries the payment evidence the checks saw (review of
    /// I-02, N3-P1-5): the same evidence at the act is no reason to stop.
    @MainActor
    func testAnApprovedActionIsTakenWhenNothingChanged() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let pay = try XCTUnwrap(named("Confirm payment", in: page))
        XCTAssertTrue(pay.showsAmount, "it shows $10")
        let approval = ActionScript.Approval(pageURL: page.url, text: pay.text, formSubmitLabel: pay.formSubmitLabel,
                                             submits: pay.submits, formGrants: pay.formGrants,
                                             paymentForm: page.flags.paymentForm)
        let script = try XCTUnwrap(ActionScript.source(for: action(.click, on: pay), on: page, approval: approval))
        let outcome = try ActionOutcome.decode(try await bridge.run(script, in: tab))
        XCTAssertEqual(outcome.outcome, .done)
        let title = try await bridge.run("document.title", in: tab)
        XCTAssertEqual(title, "Paid")
    }

    // MARK: - Review round 9: the page's own handlers, a cut address

    /// An element that changed after it was observed is not acted on.
    @MainActor
    func testAnElementThatChangedSinceTheObservationIsNotActedOn() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        _ = try await bridge.run("document.getElementById('reveal').textContent = 'Something else'; ''", in: tab)
        let outcome = try await perform(action(.click, on: named("Show details", in: page)), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .gone)
        let text = try await bridge.run("document.getElementById('reveal').textContent", in: tab)
        XCTAssertEqual(text, "Something else", "nothing was clicked")
    }

    /// Focus runs the page's own handlers. If one moves the focus elsewhere,
    /// the text goes nowhere — not into an editor nobody chose.
    @MainActor
    func testTypingStopsWhenFocusIsMovedElsewhere() async throws {
        let (bridge, tab) = try await open("https://site-27.test/")
        let page = try await observe(bridge, tab)
        let outcome = try await perform(action(.type, on: named("Redirecting field", in: page), payload: "hello"),
                                         on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .gone)
        let other = try await bridge.run("document.getElementById('other').textContent", in: tab)
        XCTAssertEqual(other, "untouched")
        let own = try await bridge.run("document.getElementById('thief').value", in: tab)
        XCTAssertEqual(own, "")
    }

    /// A field that turns into a password field when focused is not typed
    /// into: it is a secret field now, hidden — the user's part, not a field
    /// that is gone (ITER-076 2.2, S3; owner decision 4; review of A3, round
    /// 1), whenever in the act it turns.
    @MainActor
    func testTypingStopsWhenTheFieldTurnsSensitiveOnFocus() async throws {
        let (bridge, tab) = try await open("https://site-27.test/")
        let page = try await observe(bridge, tab)
        let outcome = try await perform(action(.type, on: named("Turncoat field", in: page), payload: "hello"),
                                         on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .wall)
        let value = try await bridge.run("document.getElementById('turncoat').value", in: tab)
        XCTAssertEqual(value, "")
    }

    /// Review of A3, round 1: a select's option is chosen as the observer
    /// listed it — as a person reads it, a card number and a literal
    /// "[hidden]" each its own option (owner decision of 2026-10-03).
    @MainActor
    func testASelectTakesOnlyTheOneOptionThatReadsAsListed() async throws {
        for (payload, index) in [("4111 1111 1111 1111", "0"), ("[hidden]", "1"), ("Monthly", "2")] {
            let (bridge, tab) = try await open("https://site-96.test/")
            let page = try await observe(bridge, tab)
            let plan = try XCTUnwrap(named("Plan", in: page))
            XCTAssertEqual(plan.options, ["4111 1111 1111 1111", "[hidden]", "Monthly"])
            let outcome = try await perform(action(.select, on: plan, payload: payload), on: page, bridge, tab)
            XCTAssertEqual(outcome.outcome, .done, payload)
            let chosen = try await bridge.run("String(document.querySelector('select').selectedIndex)", in: tab)
            XCTAssertEqual(chosen, index, payload)
        }
    }

    /// Review of A3, round 1: an act is bound to where the tab really is — a
    /// page whose address carries a session finds its own page. What others
    /// see of the address is what the address bar shows (owner decision of
    /// 2026-10-03).
    @MainActor
    func testAnActIsBoundToWhereTheTabReallyIs() async throws {
        let (bridge, tab) = try await open("https://site-26.test/?session=abc123&view=all")
        let page = try await observe(bridge, tab)
        XCTAssertEqual(page.url, "https://site-26.test/?session=abc123&view=all")
        XCTAssertEqual(page.liveAddress, "https://site-26.test/?session=abc123&view=all")
        let outcome = try await perform(action(.click, on: named("Show details", in: page)), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
    }

    /// Review of A3, round 1: a target the page turned into a secret field
    /// after it was chosen is the user's part — a wall, not a target that is
    /// gone — and nothing is typed.
    @MainActor
    func testATargetThatTurnedSecretIsAWall() async throws {
        let (bridge, tab) = try await open("https://site-94.test/")
        let page = try await observe(bridge, tab)
        let search = try XCTUnwrap(named("Search guides", in: page))
        _ = try await bridge.run("document.querySelector('[type=search]').setAttribute('autocomplete', 'one-time-code'); ''",
                                 in: tab)
        let outcome = try await perform(action(.type, on: search, payload: "hello"), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .wall)
        let value = try await bridge.run("document.querySelector('[type=search]').value", in: tab)
        XCTAssertEqual(value, "voice notes")
    }

    // MARK: - Review of A3d, round 2 (Codex, I-02)

    /// A search box that became a password box — before the act, or when it
    /// took the focus — is the user's part, not a target that is gone, though
    /// its role changed with it (P2-4). Nothing is typed.
    @MainActor
    func testASearchBoxThatBecameAPasswordBoxIsAWall() async throws {
        let (bridge, tab) = try await open("https://site-104.test/")
        let page = try await observe(bridge, tab)
        let find = try XCTUnwrap(named("Find a guide", in: page))
        XCTAssertEqual(find.role, "searchbox")
        _ = try await bridge.run("document.getElementById('find').type = 'password'; ''", in: tab)
        let before = try await perform(action(.type, on: find, payload: "hello"), on: page, bridge, tab)
        XCTAssertEqual(before.outcome, .wall, "turned before the act")
        let found = try await bridge.run("document.getElementById('find').value", in: tab)
        XCTAssertEqual(found, "")
        // A page of its own: the box turned above is a secret in no form,
        // which would stop any step here.
        let (focusBridge, focusTab) = try await open("https://site-104.test/")
        let focusPage = try await observe(focusBridge, focusTab)
        let flip = try XCTUnwrap(named("Quick find", in: focusPage))
        XCTAssertFalse(flip.touchesSecret)
        let onFocus = try await perform(action(.type, on: flip, payload: "hello"), on: focusPage, focusBridge, focusTab)
        XCTAssertEqual(onFocus.outcome, .wall, "turned on focus")
        let flipped = try await focusBridge.run("document.getElementById('flip').type + '|' + document.getElementById('flip').value",
                                                in: focusTab)
        XCTAssertEqual(flipped, "password|")
        // Its role and its name change together, on focus and before the act:
        // still the same field, found by what the page cannot redraw (N3-P2-2).
        let (bothBridge, bothTab) = try await open("https://site-104.test/")
        let bothPage = try await observe(bothBridge, bothTab)
        let lookup = try XCTUnwrap(named("Lookup", in: bothPage))
        XCTAssertFalse(lookup.touchesSecret)
        let both = try await perform(action(.type, on: lookup, payload: "hello"), on: bothPage, bothBridge, bothTab)
        XCTAssertEqual(both.outcome, .wall, "role and name changed on focus")
        let turned = try await bothBridge.run("document.getElementById('both').type + '|' + document.getElementById('both').value",
                                              in: bothTab)
        XCTAssertEqual(turned, "password|")
        let (renamedBridge, renamedTab) = try await open("https://site-104.test/")
        let renamedPage = try await observe(renamedBridge, renamedTab)
        let renamed = try XCTUnwrap(named("Find a guide", in: renamedPage))
        _ = try await renamedBridge.run("""
            const find = document.getElementById('find');
            find.type = 'password'; find.setAttribute('aria-label', 'Kennung'); ''
            """, in: renamedTab)
        let renamedBefore = try await perform(action(.type, on: renamed, payload: "hello"), on: renamedPage, renamedBridge,
                                              renamedTab)
        XCTAssertEqual(renamedBefore.outcome, .wall, "role and name changed before the act")
    }

    /// A field that is simply gone is still gone, not a wall, when a secret
    /// field stands elsewhere on the page.
    @MainActor
    func testAFieldThatIsGoneIsNotAWall() async throws {
        let (bridge, tab) = try await open("https://site-104.test/")
        let page = try await observe(bridge, tab)
        let find = try XCTUnwrap(named("Find a guide", in: page))
        _ = try await bridge.run("""
            document.getElementById('find').remove();
            document.body.insertAdjacentHTML('beforeend', '<input type=password aria-label=Code>'); ''
            """, in: tab)
        let outcome = try await perform(action(.type, on: find, payload: "hello"), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .gone)
    }

    /// A password that comes into a frame inside the form after the choice
    /// stops the act: the form now holds a secret (P1-5). Nothing is sent.
    @MainActor
    func testASecretThatComesIntoAFrameOfTheFormIsAWall() async throws {
        let (bridge, tab) = try await open("https://site-102.test/")
        let page = try await observe(bridge, tab)
        let save = try XCTUnwrap(named("Save note", in: page))
        XCTAssertFalse(save.touchesSecret)
        _ = try await bridge.run("""
            document.querySelector('#plain iframe').contentDocument.body
              .insertAdjacentHTML('beforeend', '<input type=password aria-label=Code value=x9>'); ''
            """, in: tab)
        let outcome = try await perform(action(.click, on: save), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .wall)
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/plain" }, "the form was not sent")
    }

    /// A password in a frame of the form that the page showed as text since
    /// the last look still makes the form one that holds it (N3-P1-3): the act
    /// is a wall, and nothing is sent.
    @MainActor
    func testAFramesPasswordShownAsTextStillStopsItsForm() async throws {
        let (bridge, tab) = try await open("https://site-115.test/")
        let page = try await observe(bridge, tab)
        let next = try XCTUnwrap(named("Weiter", in: page))
        _ = try await bridge.run("document.getElementById('show').click(); ''", in: tab)
        let outcome = try await perform(action(.click, on: next), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .wall)
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/outer" }, "the form was not sent")
    }

    /// What a frame's field was is remembered for that frame's document only
    /// (review of I-02, N4-P2-1): a new document in the same frame, with an
    /// ordinary field of the same id where the password stood, leaves the
    /// form ordinary again, and its action is taken.
    @MainActor
    func testANewDocumentInTheFrameStartsWithNothingRemembered() async throws {
        let (bridge, tab) = try await open("https://site-115.test/")
        let first = try await observe(bridge, tab)
        XCTAssertEqual(named("Weiter", in: first)?.touchesSecret, true, "a password in the frame")
        _ = try await bridge.run("""
            document.getElementById('frame').srcdoc = '<input id=feld aria-label=Feld value=ab12>'; ''
            """, in: tab)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let type = try await bridge.run("""
                (() => { const d = document.getElementById('frame').contentDocument;
                  const f = d && d.getElementById('feld'); return f ? f.type : ''; })()
                """, in: tab)
            if type == "text" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let page = try await observe(bridge, tab)
        XCTAssertFalse(page.flags.loginForm)
        for name in ["Weiter", "Spitzname"] {
            XCTAssertEqual(named(name, in: page)?.touchesSecret, false, name)
        }
        let outcome = try await perform(action(.click, on: named("Weiter", in: page)), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
        try await bridge.waitForURL(URL(string: "https://site-115.test/outer")!, in: tab)
    }

    /// A total that appears after the look — between the look and the act, or
    /// the aim — is no wall (owner decision of 2026-10-19: a payment is a page
    /// that asks card details): the act goes, a Yes given or not.
    @MainActor
    func testAnAmountThatAppearsBeforeTheActIsNoWall() async throws {
        for approved in [false, true] {
            let (bridge, tab) = try await open("https://site-116.test/")
            let page = try await observe(bridge, tab)
            let order = try XCTUnwrap(named("Bestellung abschließen", in: page))
            XCTAssertFalse(order.showsAmount)
            _ = try await bridge.run("document.getElementById('summe').textContent = 'Gesamtsumme: 49,90 €'; ''", in: tab)
            let approval = approved ? ActionScript.Approval(pageURL: page.liveAddress, text: order.text,
                                                            formSubmitLabel: order.formSubmitLabel, submits: order.submits,
                                                            formGrants: order.formGrants) : nil
            let aim = try ActionOutcome.decode(try await bridge.run(
                try XCTUnwrap(ActionScript.aim(for: action(.click, on: order), on: page, approval: approval)), in: tab))
            XCTAssertEqual(aim.outcome, .aim, "aim, approved: \(approved)")
            let script = try XCTUnwrap(ActionScript.source(for: action(.click, on: order), on: page, approval: approval))
            let act = try ActionOutcome.decode(try await bridge.run(script, in: tab))
            XCTAssertEqual(act.outcome, .done, "act, approved: \(approved)")
            try await bridge.waitForURL(URL(string: "https://site-116.test/paid")!, in: tab)
        }
    }

    /// A button in no form, chosen while the login box was empty, is not
    /// pressed once a password is typed in (N-P1-2): its handler would send it.
    @MainActor
    func testAButtonOutsideTheFormIsAWallOnceThePasswordIsFilled() async throws {
        let (bridge, tab) = try await open("https://site-103.test/")
        let page = try await observe(bridge, tab)
        let signIn = try XCTUnwrap(named("Sign in", in: page))
        XCTAssertFalse(signIn.touchesSecret)
        _ = try await bridge.run("document.getElementById('pw').value = 'hunter2-x'; ''", in: tab)
        let outcome = try await perform(action(.click, on: signIn), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .wall)
        XCTAssertEqual(outcome.why, "secret", "the wall names its check")
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/session" }, "the login form was not sent")
    }

    /// A control of a form chosen while its password was empty — the
    /// errand's then (owner decision 4; 2026-10-20, b02) — is not acted on
    /// once the password is typed in: the form could send it now. Nothing is
    /// typed, nothing sent.
    @MainActor
    func testAControlOfAFormIsAWallOnceItsPasswordIsFilled() async throws {
        let (bridge, tab) = try await open("https://site-497.test/")
        let page = try await observe(bridge, tab)
        let submit = try XCTUnwrap(named("submit", in: page))
        let user = try XCTUnwrap(named("Username", in: page))
        XCTAssertFalse(submit.touchesSecret)
        XCTAssertFalse(user.touchesSecret)
        _ = try await bridge.run("document.getElementById('password').value = 'hunter2-practice'; ''", in: tab)
        let press = try await perform(action(.click, on: submit), on: page, bridge, tab)
        XCTAssertEqual(press.outcome, .wall)
        XCTAssertEqual(press.why, "secret", "the wall names its check")
        let typed = try await perform(action(.type, on: user, payload: "Sam"), on: page, bridge, tab)
        XCTAssertEqual(typed.outcome, .wall)
        let held = try await bridge.run("document.getElementById('username').value", in: tab)
        XCTAssertEqual(held, "", "nothing typed")
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/submit" }, "the form was not sent")
    }

    /// An option is found by its place, its value and its words as they were
    /// seen — any of them changed, it is gone (P2-2) — a card number among
    /// them as a person reads it (owner decision of 2026-10-03). The check
    /// that it held reads the same.
    @MainActor
    func testAnOptionIsFoundByItsPlaceValueAndWords() async throws {
        func fresh() async throws -> (WebViewBridge, BrowserTab, ObservedPage, ObservedElement) {
            let (bridge, tab) = try await open("https://site-108.test/")
            let page = try await observe(bridge, tab)
            let plan = try XCTUnwrap(named("Plan", in: page))
            XCTAssertEqual(plan.options, ["Monthly", "Yearly", "4111 1111 1111 1111"])
            return (bridge, tab, page, plan)
        }
        func chosen(_ bridge: WebViewBridge, _ tab: BrowserTab) async throws -> String {
            try await bridge.run("String(document.getElementById('plan').selectedIndex)", in: tab)
        }
        // An option that reads as a card number is chosen as listed; other
        // words in its place, it is gone.
        var (bridge, tab, page, plan) = try await fresh()
        var outcome = try await perform(action(.select, on: plan, payload: "4111 1111 1111 1111"), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
        let first = try await chosen(bridge, tab)
        XCTAssertEqual(first, "2")
        (bridge, tab, page, plan) = try await fresh()
        _ = try await bridge.run("""
            const plan = document.getElementById('plan');
            plan.options[2].replaceWith(new Option('[hidden]', '[hidden]')); ''
            """, in: tab)
        outcome = try await perform(action(.select, on: plan, payload: "4111 1111 1111 1111"), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .gone, "a literal [hidden] in its place")
        let still = try await chosen(bridge, tab)
        XCTAssertEqual(still, "0")
        // Its value changed.
        (bridge, tab, page, plan) = try await fresh()
        _ = try await bridge.run("document.getElementById('plan').options[1].value = 'y2'; ''", in: tab)
        outcome = try await perform(action(.select, on: plan, payload: "Yearly"), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .gone, "another value")
        // Its place changed.
        (bridge, tab, page, plan) = try await fresh()
        _ = try await bridge.run("document.getElementById('plan').add(new Option('Weekly', 'w'), 1); ''", in: tab)
        outcome = try await perform(action(.select, on: plan, payload: "Yearly"), on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .gone, "another place")
        let second = try await chosen(bridge, tab)
        XCTAssertEqual(second, "0", "nothing was chosen")
        // Unchanged, it is chosen; replaced after, the check says it no longer holds.
        (bridge, tab, page, plan) = try await fresh()
        let yearly = action(.select, on: plan, payload: "Yearly")
        outcome = try await perform(yearly, on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done)
        let held = try ActionOutcome.decode(try await bridge.run(try XCTUnwrap(ActionScript.holds(yearly, on: page)), in: tab))
        XCTAssertEqual(held.outcome, .held)
        // A literal "[hidden]" is words like any: chosen while it stays, never
        // once other words stand in its place.
        let label = try XCTUnwrap(named("Label", in: page))
        let literal = action(.select, on: label, payload: "[hidden]")
        outcome = try await perform(literal, on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .done, "a literal [hidden]")
        _ = try await bridge.run("""
            const label = document.getElementById('label');
            label.options[1].replaceWith(new Option('4111 1111 1111 1111', '4111 1111 1111 1111', true, true));
            label.selectedIndex = 0; ''
            """, in: tab)
        outcome = try await perform(literal, on: page, bridge, tab)
        XCTAssertEqual(outcome.outcome, .gone, "a card number in its place")
        let labelChosen = try await bridge.run("String(document.getElementById('label').selectedIndex)", in: tab)
        XCTAssertEqual(labelChosen, "0")
        _ = try await bridge.run("""
            const plan = document.getElementById('plan');
            const other = new Option('Yearly', 'y2', true, true);
            plan.options[1].replaceWith(other); plan.selectedIndex = 1; ''
            """, in: tab)
        let after = try ActionOutcome.decode(try await bridge.run(try XCTUnwrap(ActionScript.holds(yearly, on: page)), in: tab))
        XCTAssertEqual(after.outcome, .differs)
        // A value that differs only past its first 200 characters, or only in
        // its spaces, is another value (N3-P2-1): gone, and not held.
        for (label, change) in [("a suffix", "'y'.repeat(300) + 'b'"), ("spaces", "'y  2'")] {
            let (valueBridge, valueTab) = try await open("https://site-108.test/")
            _ = try await valueBridge.run("""
                document.getElementById('plan').options[1].value = \(label == "spaces" ? "'y 2'" : "'y'.repeat(300) + 'a'"); ''
                """, in: valueTab)
            let valuePage = try await observe(valueBridge, valueTab)
            let valuePlan = try XCTUnwrap(named("Plan", in: valuePage))
            let choose = action(.select, on: valuePlan, payload: "Yearly")
            _ = try await valueBridge.run("document.getElementById('plan').options[1].value = \(change); ''", in: valueTab)
            let changed = try await perform(choose, on: valuePage, valueBridge, valueTab)
            XCTAssertEqual(changed.outcome, .gone, label)
            _ = try await valueBridge.run("document.getElementById('plan').selectedIndex = 1; ''", in: valueTab)
            let check = try ActionOutcome.decode(try await valueBridge.run(try XCTUnwrap(ActionScript.holds(choose, on: valuePage)),
                                                                           in: valueTab))
            XCTAssertEqual(check.outcome, .differs, label)
        }
    }

    /// ITER-076 I-09, round 5 (Claude review c10, #14): the lookup of an act
    /// that commits, made alone, does nothing and says how many frames the
    /// act's document holds; the act itself, given that count, is gone when
    /// its document holds more — a frame no check read — and goes when it
    /// holds as many. An act that commits nothing has no lookup alone.
    @MainActor
    func testAnActThatCommitsIsGoneWhenItsDocumentHoldsAFrameNoCheckRead() async throws {
        let (bridge, tab) = try await open("https://site-301.test/select")
        let page = try await observe(bridge, tab)
        let choose = action(.select, on: named("Tarif", in: page), payload: "Jaehrlich")
        let found = try ActionOutcome.decode(try await bridge.run(try XCTUnwrap(ActionScript.found(for: choose, on: page)),
                                                                  in: tab))
        XCTAssertEqual(found.outcome, .found)
        XCTAssertEqual(found.frames, 0)
        let log = "document.getElementById('log').textContent"
        var logged = try await bridge.run(log, in: tab)
        XCTAssertEqual(logged, "", "the lookup alone does nothing")
        _ = try await bridge.run("document.getElementById('page').append(document.createElement('iframe')); ''", in: tab)
        let gone = try ActionOutcome.decode(try await bridge.run(
            try XCTUnwrap(ActionScript.source(for: choose, on: page, framesKnown: 0)), in: tab))
        XCTAssertEqual(gone.outcome, .gone)
        logged = try await bridge.run(log, in: tab)
        XCTAssertEqual(logged, "", "nothing chosen")
        let done = try ActionOutcome.decode(try await bridge.run(
            try XCTUnwrap(ActionScript.source(for: choose, on: page, framesKnown: 1)), in: tab))
        XCTAssertEqual(done.outcome, .done)
        logged = try await bridge.run(log, in: tab)
        XCTAssertEqual(logged, "ordered;")
        XCTAssertNil(ActionScript.found(for: action(.type, on: named("Tarif", in: page), payload: "words"), on: page))
    }

    /// An address at the report's length limit may have been cut: neither
    /// where the link goes nor the words at its end are known whole, so the
    /// link offers nothing and is never opened.
    @MainActor
    func testALinkWhoseAddressMayBeCutOffersNothing() async throws {
        let (bridge, tab) = try await open("https://site-27.test/")
        let page = try await observe(bridge, tab)
        let long = try XCTUnwrap(named("Very long link", in: page))
        XCTAssertEqual(long.href?.count, ObserverScript.maxURLLength)
        XCTAssertNil(ActionScript.source(for: action(.open, on: long, destination: long.href), on: page))
        let offered = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: []))
            .candidates.filter { $0.action.target?.name == "Very long link" }
        XCTAssertTrue(offered.isEmpty)
    }

    /// Operations with nothing to run in the page have no script, and an
    /// action that is not whole has none either.
    func testOnlyWholeActionsHaveAScript() {
        let page = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none, elements: [])
        for operation in [AgentOperation.wait, .more, .done, .stuck] {
            XCTAssertNil(ActionScript.source(for: action(operation, on: nil), on: page))
        }
        XCTAssertNil(ActionScript.source(for: action(.back, on: nil), on: page), "back goes through the tab's history")
        XCTAssertNil(ActionScript.source(for: action(.click, on: nil), on: page), "a click needs a target")
        XCTAssertNil(ActionScript.source(for: AgentAction(operation: .open, target: nil, destination: "file:///etc/hosts",
                                                          payload: nil, isPlannedSearch: true), on: page))
    }
}
