import XCTest
@testable import MetaWhisp

/// Level 2, ITER-076 A3b — owner decision 4 of 2026-09-29: Jev sees the values
/// of ordinary fields; since the owner's decision of 2026-10-03, what a person
/// sees, and never the value of a field the page marks secret by its
/// structure. A secret field is hidden and the errand goes on; a control that
/// could send one says so.
final class ObserverValuesTests: XCTestCase {

    @MainActor
    private func observed(_ address: String) async throws -> (page: ObservedPage, json: String) {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: address)!)
        try await bridge.waitUntilLoaded(tab)
        let json = try await bridge.run(ObserverScript.source, in: tab)
        return (try ObservedPage.decode(json), json)
    }

    private func named(_ name: String, in page: ObservedPage) -> ObservedElement? {
        page.elements.first { $0.name == name }
    }

    /// A text field, a search box, a select's chosen option and a textarea
    /// each report what they hold — as a value, never as a name or text.
    @MainActor
    func testOrdinaryFieldsReportTheirValues() async throws {
        let (page, _) = try await observed("https://site-94.test/")
        XCTAssertEqual(named("Username", in: page)?.value, "sam")
        XCTAssertEqual(named("Search guides", in: page)?.value, "voice notes")
        XCTAssertEqual(named("Sort by", in: page)?.value, "Popular")
        XCTAssertEqual(named("Sort by", in: page)?.options, ["Newest", "Popular"])
        XCTAssertEqual(named("Feedback", in: page)?.value, "Great guides")
        XCTAssertEqual(named("Search guides", in: page)?.text, "")
        XCTAssertNil(named("Help", in: page)?.value, "a link holds no value")
    }

    /// The password is not reported at all, and the page is still observed
    /// for the errand to go on.
    @MainActor
    func testAPasswordIsHiddenAndThePageStaysOpen() async throws {
        let (page, json) = try await observed("https://site-94.test/")
        XCTAssertNil(named("Password", in: page))
        XCTAssertFalse(json.contains("correct-horse"))
        XCTAssertTrue(page.flags.loginForm)
        XCTAssertNotNil(named("Help", in: page))
    }

    /// Owner decision 4: a step stops only where it could send a secret. A
    /// control in the form that holds one could. A control in another form
    /// and a link could not. A control outside any form could, once the
    /// password there is filled in: a script may send that form from any
    /// button (review of A3d, round 2, N-P1-2) — an empty login box leaves
    /// the page's own controls alone (`testAControlOutsideAnyFormTouchesOnlyAFilledSecret`).
    @MainActor
    func testAControlThatCouldSendASecretSaysSo() async throws {
        let (page, _) = try await observed("https://site-94.test/")
        for name in ["Username", "Sign in", "Sort by", "Feedback", "Continue"] {
            XCTAssertEqual(named(name, in: page)?.touchesSecret, true, name)
        }
        for name in ["Search guides", "Search", "Help"] {
            XCTAssertEqual(named(name, in: page)?.touchesSecret, false, name)
        }
    }

    // MARK: - Review of A3, round 1 (Codex and Claude, 2026-09-29)

    /// A field that draws what it holds as dots is a password in any
    /// language, and hidden. A card number split over fields, or parted by
    /// dots, underscores or slashes, written in full-width digits or with
    /// zero-width spaces, is a card all the same: its form takes a payment
    /// and could send it — and what the fields hold is shown, as a person
    /// reads it (owner decision of 2026-10-03).
    @MainActor
    func testADotsFieldIsHiddenAndACardInAnyShapeIsAPaymentShown() async throws {
        let (page, json) = try await observed("https://site-97.test/")
        XCTAssertNil(named("Kennwort", in: page))
        XCTAssertFalse(json.contains("hunter2-geheim"))
        for (name, value) in [("Karte 1", "4111"), ("Karte 4", "1111"), ("Prüfziffer", "737"),
                              ("Ref A", "4111.1111.1111.1111"), ("Ref B", "4111_1111_1111_1111"),
                              ("Ref C", "4111/1111/1111/1111"), ("Ref D", "4111 1111 1111 1111"),
                              ("Ref E", "4111111111111111")] {
            XCTAssertEqual(named(name, in: page)?.value, value, name)
        }
        XCTAssertEqual(named("Menge", in: page)?.value, "2")
        XCTAssertEqual(named("Plain", in: page)?.value, "order 12")
        XCTAssertTrue(page.flags.loginForm)
        XCTAssertTrue(page.flags.paymentForm)
        for name in ["Weiter", "Menge", "Keep", "Plain"] {
            XCTAssertEqual(named(name, in: page)?.touchesSecret, true, name)
        }
    }

    /// An e-mail address, a web address and a slug are no keys: a contact
    /// form keeps its values and can be sent.
    @MainActor
    func testAddressesAndSlugsStayAsTheyAre() async throws {
        let (page, _) = try await observed("https://site-97.test/")
        XCTAssertEqual(named("Email", in: page)?.value, "alexander.richardson1985@example.com")
        XCTAssertEqual(named("Website", in: page)?.value, "https://example.com/products/12345")
        XCTAssertEqual(named("About", in: page)?.value,
                       "See https://www.linkedin.com/in/alexander-richardson-1985 and order 12345")
        XCTAssertEqual(named("Send", in: page)?.touchesSecret, false)
    }

    /// A secret field a form holds anywhere — in a component's shadow root,
    /// or hidden — makes every control of that form one that could send it;
    /// so does a widget only its words call a password, drawn inside an
    /// editor. The editor itself is someone's writing, shown as it stands,
    /// its widget's words with it (owner decision of 2026-10-03).
    @MainActor
    func testAFormHoldingASecretAnywhereCouldSendIt() async throws {
        let (page, json) = try await observed("https://site-97.test/")
        XCTAssertNil(named("Secret", in: page))
        XCTAssertFalse(json.contains("pa55word"))
        for name in ["Account name", "Log on", "Send note"] {
            XCTAssertEqual(named(name, in: page)?.touchesSecret, true, name)
        }
        XCTAssertNotNil(named("Message editor", in: page), "an editor whose widget is marked secret by no structure")
        XCTAssertTrue(json.contains("hunter2x"))
        XCTAssertEqual(named("Coupon", in: page)?.value, "SPRING")
        // A hidden input is never read, for what it holds or for a secret
        // (owner decision of 2026-10-03): its card number makes no form one
        // that could send a secret.
        for name in ["Coupon", "Apply coupon"] {
            XCTAssertEqual(named(name, in: page)?.touchesSecret, false, name)
        }
    }

    /// A secret field outside any form may go with any control outside a form:
    /// each but a link could send it.
    @MainActor
    func testAFormlessSecretMakesEveryFormlessControlButALinkTouchIt() async throws {
        let (page, _) = try await observed("https://site-98.test/")
        XCTAssertNil(named("Kod", in: page))
        XCTAssertEqual(named("Log in", in: page)?.touchesSecret, true)
        XCTAssertEqual(named("Enter", in: page)?.touchesSecret, true)
        XCTAssertEqual(named("Help", in: page)?.touchesSecret, false)
    }

    /// A field once seen to be secret stays secret for the life of the page:
    /// a "show password" toggle, or the field drawn anew under its name, does
    /// not make it an ordinary field.
    @MainActor
    func testASecretFieldStaysSecretWhenItShowsItsText() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-98.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let first = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertNil(named("Kod", in: first))
        _ = try await bridge.run("document.querySelector('[name=k1]').type = 'text'; ''", in: tab)
        var json = try await bridge.run(ObserverScript.source, in: tab)
        XCTAssertNil(named("Kod", in: try ObservedPage.decode(json)), "shown as text")
        XCTAssertFalse(json.contains("9911"))
        _ = try await bridge.run("""
            const old = document.querySelector('[name=k1]');
            const fresh = document.createElement('input');
            fresh.name = 'k1'; fresh.setAttribute('aria-label', 'Kod'); fresh.value = '9911';
            old.replaceWith(fresh); ''
            """, in: tab)
        json = try await bridge.run(ObserverScript.source, in: tab)
        XCTAssertNil(named("Kod", in: try ObservedPage.decode(json)), "drawn anew")
        XCTAssertFalse(json.contains("9911"))
    }

    /// The address anyone but the app sees is the one the address bar shows
    /// — its path, query and fragment as written — and the title is the
    /// page's own (owner decision of 2026-10-03). Where the tab really is
    /// stays with the app.
    @MainActor
    func testTheAddressAndTitleAreShownAsTheBrowserShowsThem() async throws {
        let address = "https://site-98.test/guides/\(FakeSecrets.stripeLiveKey)/view?api_key=zz&q=shoes&token=abc#access_token=eyJhbGciOiJIUzI1NiJ9"
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: address)!)
        try await bridge.waitUntilLoaded(tab)
        let page = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(page.url, address)
        XCTAssertEqual(page.title, "Site Ninety-Eight \(FakeSecrets.stripeLiveKey)")
        let real = try await bridge.run("String(location.href)", in: tab)
        XCTAssertEqual(page.address, real)
        XCTAssertEqual(page.liveAddress, real)
        let excerpt = try PageExcerpt.decode(try await bridge.run(ObserverScript.excerptSource(), in: tab))
        XCTAssertEqual(excerpt.url, page.url, "the writer sees the same address")
        XCTAssertEqual(excerpt.title, page.title)
    }

    // MARK: - Review of A3d, round 2 (Codex, I-02)

    /// A frame of the page's own origin inside a form is read for secret
    /// fields; one of another origin makes the form unknown, and unknown
    /// counts as holding one (P1-5).
    @MainActor
    func testASecretInAFrameInsideAFormIsCounted() async throws {
        let (page, json) = try await observed("https://site-102.test/")
        XCTAssertFalse(json.contains("pa55word"))
        for name in ["Nickname", "Continue", "Coupon", "Apply"] {
            XCTAssertEqual(named(name, in: page)?.touchesSecret, true, name)
        }
        for name in ["Note", "Save note"] {
            XCTAssertEqual(named(name, in: page)?.touchesSecret, false, name)
        }
        XCTAssertTrue(page.flags.loginForm)
    }

    /// A password in a frame of the page's own origin stays a password when the
    /// page shows its text: the frame's fields are remembered for the life of
    /// the document as the page's own are (N3-P1-3).
    @MainActor
    func testAFramesPasswordStaysSecretWhenItsTextIsShown() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-115.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let first = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(named("Weiter", in: first)?.touchesSecret, true)
        _ = try await bridge.run("document.getElementById('show').click(); ''", in: tab)
        let type = try await bridge.run("document.getElementById('frame').contentDocument.getElementById('feld').type", in: tab)
        XCTAssertEqual(type, "text", "the page showed it")
        let second = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(named("Weiter", in: second)?.touchesSecret, true)
        XCTAssertEqual(named("Spitzname", in: second)?.touchesSecret, true)
    }

    /// A secret field in a frame of the page's own origin, in no form, is a
    /// secret outside any form: every control in no form but a link could
    /// send it (P1-5).
    @MainActor
    func testASecretInAFrameOutsideAnyFormReachesEveryFormlessControl() async throws {
        let (page, _) = try await observed("https://site-113.test/")
        XCTAssertEqual(named("Next", in: page)?.touchesSecret, true)
        XCTAssertEqual(named("Help", in: page)?.touchesSecret, false)
    }

    /// A frame a person cannot see — not shown, zero-sized, made invisible —
    /// in no form, is no secret outside any form, as a hidden field in no
    /// form is none: nothing can be typed into it, and the page's other
    /// controls send nothing from it. An ad-heavy page holds such frames,
    /// and every button on it was the user's part (2026-10-16). The frame
    /// shown is still one (the test above).
    @MainActor
    func testAFrameNoOneSeesInNoFormLeavesTheFormlessControlsAlone() async throws {
        let (page, _) = try await observed("https://site-477.test/")
        XCTAssertEqual(named("Start", in: page)?.touchesSecret, false)
        XCTAssertEqual(named("Help", in: page)?.touchesSecret, false)
        XCTAssertFalse(page.flags.loginForm)
    }

    /// A frame no one sees still holds what was typed into it: a card number typed into a frame of the page's own
    /// origin, in no form, then hidden as a checkout moves on, goes with the page's next press. Every formless
    /// control but a link could send it, and the page takes a payment (Codex review of 2026-10-18, P1-1).
    @MainActor
    func testAFrameNoOneSeesWithASecretTypedInStillReachesTheFormlessControls() async throws {
        let (page, json) = try await observed("https://site-483.test/")
        XCTAssertEqual(named("Continue", in: page)?.touchesSecret, true)
        XCTAssertEqual(named("Help", in: page)?.touchesSecret, false)
        XCTAssertTrue(page.flags.paymentForm)
        XCTAssertFalse(json.contains("4242"))
    }

    /// A frame a person saw holding a secret — another site's card entry, in no form — stays one once the page
    /// hides it, as a field once secret does: what was typed into it cannot be read, and the page's next press
    /// may send it (Codex review of 2026-10-18, P1-1). A frame never seen is none (the test above it).
    @MainActor
    func testAFrameSeenHoldingASecretStaysOneOnceThePageHidesIt() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-484.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let shown = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(named("Continue", in: shown)?.touchesSecret, true)
        let hid = try await bridge.run("hideCard()", in: tab)
        XCTAssertEqual(hid, "hidden")
        let hidden = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(named("Continue", in: hidden)?.touchesSecret, true)
        XCTAssertEqual(named("Help", in: hidden)?.touchesSecret, false)
        XCTAssertTrue(hidden.flags.paymentForm)
    }

    /// Seen holding a secret, a frame stays one of its kind whatever names it later: hidden, and the title that
    /// named it a card's taken away, it is still a card's, and every formless control but a link could send what
    /// was typed into it (Codex re-review of 2026-10-18, P1).
    @MainActor
    func testAFrameSeenHoldingASecretStaysOneOnceHiddenAndNamedNoMore() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-484.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let shown = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(named("Continue", in: shown)?.touchesSecret, true)
        let hid = try await bridge.run("hideCardAndItsName()", in: tab)
        XCTAssertEqual(hid, "hidden")
        let hidden = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(named("Continue", in: hidden)?.touchesSecret, true)
        XCTAssertEqual(named("Help", in: hidden)?.touchesSecret, false)
        XCTAssertTrue(hidden.flags.paymentForm)
    }

    /// A field remembered as a card keeps its form a card form: once the
    /// page masks the card number it holds, the form still takes a payment
    /// and could send it (N-P1-1). What the fields hold is shown as a person
    /// reads it, the masked number and the security code typed after it
    /// (owner decision of 2026-10-03).
    @MainActor
    func testARememberedCardStillMakesItsFormACardForm() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-105.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let first = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(named("Kartennummer", in: first)?.value, "4111 1111 1111 1111")
        XCTAssertTrue(first.flags.paymentForm)
        XCTAssertEqual(named("Prüfnummer", in: first)?.value, "")
        _ = try await bridge.run("""
            document.getElementById('nummer').value = '**** **** **** 1111';
            document.getElementById('pruef').value = '737'; ''
            """, in: tab)
        let second = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(named("Kartennummer", in: second)?.value, "**** **** **** 1111")
        XCTAssertEqual(named("Prüfnummer", in: second)?.value, "737")
        XCTAssertTrue(second.flags.paymentForm, "a card once, a card for the document's life")
        XCTAssertEqual(named("Weiter", in: second)?.touchesSecret, true)
    }

    /// A remembered name belongs to its own form: a login form's password
    /// field named "value" makes no search field of that name secret, though
    /// both forms send to one address; a field drawn anew in the login form
    /// under that name stays hidden (N-P2-2).
    @MainActor
    func testARememberedNameStaysInItsOwnForm() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-106.test/")!)
        try await bridge.waitUntilLoaded(tab)
        for look in 0..<2 {
            let json = try await bridge.run(ObserverScript.source, in: tab)
            let page = try ObservedPage.decode(json)
            XCTAssertNil(named("Passwort", in: page), "look \(look)")
            XCTAssertEqual(named("Suche", in: page)?.value, "voice notes", "look \(look)")
            XCTAssertEqual(named("Suchen", in: page)?.touchesSecret, false, "look \(look)")
        }
        _ = try await bridge.run("""
            const old = document.querySelector('#login [name=value]');
            const fresh = document.createElement('input');
            fresh.name = 'value'; fresh.setAttribute('aria-label', 'Kennung'); fresh.value = 'geheim-123';
            old.replaceWith(fresh); ''
            """, in: tab)
        let json = try await bridge.run(ObserverScript.source, in: tab)
        let page = try ObservedPage.decode(json)
        XCTAssertNil(named("Kennung", in: page), "drawn anew in its own form")
        XCTAssertFalse(json.contains("geheim-123"))
        XCTAssertEqual(named("Suche", in: page)?.value, "voice notes")
        // The form moves — a notice put before it — and its field is drawn anew
        // again: the form is still the one that holds a password (N3-P1-2). A new
        // form now standing where the login form stood inherits nothing.
        _ = try await bridge.run("""
            {
            const login = document.getElementById('login');
            const notice = document.createElement('p');
            notice.textContent = 'Wartung heute Abend';
            login.before(notice);
            const newer = document.createElement('form');
            newer.action = '/'; newer.method = 'get';
            newer.innerHTML = '<input name="value" aria-label="Neue Suche" value="red shoes">';
            notice.before(newer);
            const old = login.querySelector('[name=value]');
            const fresh = document.createElement('input');
            fresh.name = 'value'; fresh.setAttribute('aria-label', 'Zugang'); fresh.value = 'k9x2';
            old.replaceWith(fresh);
            }
            ''
            """, in: tab)
        let movedJSON = try await bridge.run(ObserverScript.source, in: tab)
        let moved = try ObservedPage.decode(movedJSON)
        XCTAssertNil(named("Zugang", in: moved), "drawn anew in its form, which moved")
        XCTAssertFalse(movedJSON.contains("k9x2"))
        XCTAssertEqual(named("Neue Suche", in: moved)?.value, "red shoes", "a new form in the old place")
        XCTAssertEqual(named("Suche", in: moved)?.value, "voice notes")
        XCTAssertFalse(try Self.jevState(of: moved).contains("k9x2"), "Jev never reads it")
    }

    /// What Jev's step question reads of a page, encoded.
    static func jevState(of page: ObservedPage) throws -> String {
        let set = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: []))
        let request = ChooseRequest(candidates: set.candidates, subgoal: .init(description: "Read", terms: []),
                                    rowsCollected: 0, rowsWanted: 1, goal: "Read",
                                    page: PageSummary(url: page.url, title: page.title, text: page.text),
                                    recentActions: [])
        return String(decoding: try JSONEncoder().encode(try JevDecisionEngine.step(for: request).state), as: UTF8.self)
    }

    /// A control in no form could send a login form's password only once it
    /// is filled in — typed, or filled by the browser (N-P1-2): an empty
    /// login box leaves the page's own search alone, and — it sends no
    /// secret (2026-10-21) — its own fields and button too.
    @MainActor
    func testAControlOutsideAnyFormTouchesOnlyAFilledSecret() async throws {
        let (empty, _) = try await observed("https://site-103.test/")
        for name in ["Search the help", "Search", "Sign in", "Email", "Log in"] {
            XCTAssertEqual(named(name, in: empty)?.touchesSecret, false, name)
        }
        let (filled, json) = try await observed("https://site-103.test/?filled")
        XCTAssertFalse(json.contains("hunter2-x"))
        for name in ["Search the help", "Search", "Sign in", "Log in"] {
            XCTAssertEqual(named(name, in: filled)?.touchesSecret, true, name)
        }
    }

    /// Owner decision 6: a control knows whether its own form, or the region
    /// around it — for a control in no form, its region — shows a money
    /// amount: a currency sign or an ISO 4217 code beside a number, in any
    /// script (P1-7; N3-P1-6: a checkout's total may stand beside its form).
    /// Counts, dates, rooms and a "Top 10" are no amounts.
    @MainActor
    func testAControlKnowsWhetherItsFormOrRegionShowsAnAmount() async throws {
        let (page, _) = try await observed("https://site-112.test/")
        for name in ["Place euro", "Place dollar", "Place code", "Place arabic", "Place rupee", "Place input",
                     "Place summary"] {
            XCTAssertEqual(named(name, in: page)?.showsAmount, true, name)
        }
        for name in ["Place none", "Menu", "Aside button"] {
            XCTAssertEqual(named(name, in: page)?.showsAmount, false, name)
        }
    }

    /// A value is bounded like any text the report carries.
    @MainActor
    func testAValueIsBounded() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-94.test/")!)
        try await bridge.waitUntilLoaded(tab)
        _ = try await bridge.run("document.querySelector('textarea').value = 'word '.repeat(500); ''", in: tab)
        let page = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        let value = try XCTUnwrap(named("Feedback", in: page)?.value)
        XCTAssertLessThanOrEqual(value.count, 200)
        XCTAssertTrue(value.hasPrefix("word word"))
    }

    // MARK: - Numbers as they stand (ITER-076 I-09, review round 3, decision 10)

    /// The page's text, the report and the excerpt of site-261's shapes page,
    /// as the observer gives them.
    @MainActor
    private func shapes() async throws -> (page: ObservedPage, readings: [String]) {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-261.test/shapes")!)
        try await bridge.waitUntilLoaded(tab)
        let json = try await bridge.run(ObserverScript.source, in: tab)
        let page = try ObservedPage.decode(json)
        let excerpt = try await bridge.run(ObserverScript.excerptSource(), in: tab)
        return (page, [json, excerpt, try Self.jevState(of: page)])
    }

    /// Prices, years, phone numbers, order numbers and model names stay as
    /// they are (Claude review c8, #8).
    @MainActor
    func testPricesYearsPhoneAndOrderNumbersStayWithoutSuchWords() async throws {
        let (page, _) = try await shapes()
        for kept in ["$1,299.00 and EUR 1299.", "Founded in 2026.", "Call 555-1234 or +1 415 555 0123.",
                     "Order 12345678 and order #246813579 shipped.", "Model XR2000-PRO in stock."] {
            XCTAssertTrue(page.text.contains(kept), "\(kept): \(page.text)")
        }
    }
}

/// ITER-076 I-09, round 5 — owner decision of 2026-10-03: Jev sees what a
/// person sees on the screen. Only the value of a field the page marks secret
/// by structure is never read: `type=password`; an `autocomplete` of
/// `current-password`, `new-password`, `one-time-code` or `cc-*`; dots drawn
/// by `-webkit-text-security`.
extension ObserverValuesTests {

    /// Each field the page marks secret by structure alone — its words name
    /// nothing — is never reported: its value reaches neither the report, the
    /// writer's excerpt nor what Jev reads. Its form could send it, and the
    /// page asks for a sign-in and a payment.
    @MainActor
    func testFieldsMarkedSecretByStructureNeverReportTheirValues() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-289.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let json = try await bridge.run(ObserverScript.source, in: tab)
        let page = try ObservedPage.decode(json)
        let excerpt = try await bridge.run(ObserverScript.excerptSource(), in: tab)
        let state = try Self.jevState(of: page)
        for value in ["vA-4417q", "vB-5521q", "vC-6632q", "738204", "vE-7743q", "4111111111111111", "8462", "08/31"] {
            for text in [json, excerpt, state] { XCTAssertFalse(text.contains(value), value) }
        }
        for name in ["Entry A", "Entry B", "Entry C", "Entry D", "Entry E", "Entry F", "Entry G", "Entry H"] {
            XCTAssertNil(named(name, in: page), name)
        }
        XCTAssertTrue(page.flags.loginForm)
        XCTAssertTrue(page.flags.paymentForm)
        for name in ["Email", "Go on", "Holder", "Keep"] {
            XCTAssertEqual(named(name, in: page)?.touchesSecret, true, name)
        }
        XCTAssertEqual(named("Email", in: page)?.value, "sam@example.com")
        XCTAssertEqual(named("Holder", in: page)?.value, "Sam Doe")
        XCTAssertEqual(named("Help", in: page)?.touchesSecret, false)
    }

    /// A field only its words name as a secret — "Password", "One-time
    /// code", "Passport number", "API key", "CVV", no type, no autocomplete,
    /// no dots — reports what it holds, as a person sees it. Its words still
    /// say the page asks for a sign-in and a payment, and its form could send
    /// them: what the agent may act on is unchanged.
    @MainActor
    func testAFieldNamedSecretOnlyByItsWordsReportsItsValue() async throws {
        let (page, json) = try await observed("https://site-292.test/")
        for (name, value) in [("Password", "vP-3391q"), ("One-time code", "552901"), ("Passport number", "X7654321"),
                              ("API key", "key-words-here"), ("CVV", "613")] {
            XCTAssertEqual(named(name, in: page)?.value, value, name)
            XCTAssertTrue(try Self.jevState(of: page).contains(value), name)
        }
        XCTAssertFalse(json.contains("[hidden]"), json)
        XCTAssertTrue(page.flags.loginForm)
        XCTAssertTrue(page.flags.paymentForm)
        for name in ["Password", "Passport number", "Save details"] {
            XCTAssertEqual(named(name, in: page)?.touchesSecret, true, name)
        }
        XCTAssertEqual(named("Help", in: page)?.touchesSecret, false)
    }

    /// What the walk did not reach is still judged by its structure and its
    /// words: a field past the walk's cut that draws dots shows nothing of
    /// its text in the page's words or the excerpt; a field only its words
    /// call a password, outside any form, makes every control outside a form
    /// one that could send it; and one past the cut that joins a form by its
    /// `form`, filled in, makes that form's button one (owner decision of
    /// 2026-10-03; empty, it sends nothing, 2026-10-21).
    @MainActor
    func testWhatTheWalkDidNotReachIsStillJudgedByItsStructureAndItsWords() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-296.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let json = try await bridge.run(ObserverScript.source, in: tab)
        let page = try ObservedPage.decode(json)
        let excerpt = try await bridge.run(ObserverScript.excerptSource(), in: tab)
        XCTAssertTrue(page.truncated, "the premise: the walk was cut short")
        XCTAssertTrue(page.text.contains("Public words stay"), page.text)
        XCTAssertFalse(json.contains("SECRET-PAST"))
        XCTAssertFalse(excerpt.contains("SECRET-PAST"), excerpt)
        XCTAssertEqual(named("Password", in: page)?.value, "pw-shown-1")
        XCTAssertEqual(named("Help", in: page)?.touchesSecret, true)
        XCTAssertEqual(named("Send", in: page)?.touchesSecret, true)
    }

    /// A card number split over fields no word names is a card: its form
    /// takes a payment and could send it. A password field the page draws
    /// plainly is a password still: `type=password` alone marks it (owner
    /// decision of 2026-10-03).
    @MainActor
    func testASplitCardIsAPaymentAndAPasswordIsOneWhateverItsStyle() async throws {
        let (page, json) = try await observed("https://site-297.test/")
        XCTAssertTrue(page.flags.paymentForm)
        XCTAssertEqual(named("Part 1", in: page)?.value, "4111")
        XCTAssertEqual(named("Next", in: page)?.touchesSecret, true)
        XCTAssertNil(named("Entry", in: page))
        XCTAssertFalse(json.contains("vP-9081q"))
        XCTAssertTrue(page.flags.loginForm)
        XCTAssertEqual(named("Go", in: page)?.touchesSecret, true)
    }

    /// `type=password` alone marks a field secret, whatever its style says:
    /// read where the browser's style draws no dots, a password field is
    /// still never reported (owner decision of 2026-10-03).
    @MainActor
    func testAPasswordFieldIsSecretByItsTypeAlone() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-297.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let undotted = """
            (() => {
              const real = window.getComputedStyle;
              window.getComputedStyle = function (element, pseudo) {
                const style = real.call(window, element, pseudo);
                return new Proxy(style, { get: (target, key) => key === 'webkitTextSecurity' ? 'none'
                  : (typeof target[key] === 'function' ? target[key].bind(target) : target[key]) });
              };
              try { return \(ObserverScript.source); } finally { window.getComputedStyle = real; }
            })()
            """
        let json = try await bridge.run(undotted, in: tab)
        let page = try ObservedPage.decode(json)
        XCTAssertNotNil(named("Part 1", in: page), "the premise: the page was read")
        XCTAssertNil(named("Entry", in: page))
        XCTAssertFalse(json.contains("vP-9081q"))
        XCTAssertEqual(named("Go", in: page)?.touchesSecret, true)
    }

    /// An address never shows a user name or a password — a browser never
    /// does — whether the page left `URL` as it is or broke it in its own
    /// world; the rest stays as written (owner decision of 2026-10-03).
    @MainActor
    func testAnAddressShowsNoUserNameOrPassword() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-98.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let probe = "(() => {\n" + ObserverScript.walk + """
            const address = 'https://sam:pw-4417@site-98.test/files/a%20b?q=1#top';
            const plain = addressMasked(address);
            const kept = window.URL;
            window.URL = function () { throw new Error('broken'); };
            let broken = '';
            try { broken = addressMasked(address); } finally { window.URL = kept; }
            return JSON.stringify([plain, broken]);
            })()
            """
        let shown = try JSONDecoder().decode([String].self, from: Data(try await bridge.run(probe, in: tab).utf8))
        XCTAssertEqual(shown, ["https://site-98.test/files/a%20b?q=1#top", "https://site-98.test/files/a%20b"])
    }

    /// A card number, a key, a token and an IBAN a person reads — in the
    /// page's words, a button's name, a row, a select's options and a
    /// field's value — reach the report and what Jev reads as they are shown.
    @MainActor
    func testACardNumberAndAKeyInTextReachJev() async throws {
        let (words, wordsJSON) = try await observed("https://site-96.test/")
        XCTAssertTrue(words.text.contains("Your live key is sk-live-9f8e7d6c5b4a39281706f5e4d3c2b1a0 and it never expires."),
                      words.text)
        XCTAssertTrue(words.text.contains("Card on file: 4111 1111 1111 1111, expires soon."), words.text)
        XCTAssertNotNil(named("Copy \(FakeSecrets.githubToken)", in: words), "\(words.elements.map(\.name))")
        XCTAssertEqual(named("Plan", in: words)?.options, ["4111 1111 1111 1111", "[hidden]", "Monthly"])
        XCTAssertEqual(named("Revoke", in: words)?.context?.hasPrefix("Token eyJhbGciOiJIUzI1NiJ9"), true)
        let state = try Self.jevState(of: words)
        for shown in ["sk-live-9f8e7d6c5b4a39281706f5e4d3c2b1a0", "4111 1111 1111 1111",
                      FakeSecrets.githubToken] {
            XCTAssertTrue(wordsJSON.contains(shown), shown)
            XCTAssertTrue(state.contains(shown), shown)
        }
        let (fields, _) = try await observed("https://site-95.test/")
        XCTAssertEqual(named("Notes", in: fields)?.value, "4111 1111 1111 1111")
        XCTAssertEqual(named("Reference", in: fields)?.value?.hasPrefix("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0"),
                       true)
        XCTAssertEqual(named("Save profile", in: fields)?.touchesSecret, true,
                       "a card number a field holds still makes its form a payment's")
        XCTAssertTrue(fields.flags.paymentForm)
        let (iban, _) = try await observed("https://site-111.test/")
        XCTAssertTrue(iban.text.contains("Payouts go to DE89 3704 0044 0532 0130 00 every Monday."), iban.text)
        XCTAssertEqual(named("Account", in: iban)?.value, "GB82 WEST 1234 5698 7654 32")
    }
}
