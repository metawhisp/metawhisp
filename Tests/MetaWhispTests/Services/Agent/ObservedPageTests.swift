import XCTest
@testable import MetaWhisp

/// The Swift side of the observer: decoding its report, and the fingerprint
/// that lets the agent find the same element again after the page changes
/// (ITER-074 §6.1, §6.3).
final class ObservedPageTests: XCTestCase {

    private func element(index: Int = 0,
                         role: String = "link",
                         name: String = "Plans",
                         text: String = "See plans",
                         href: String? = "https://a.test/plans",
                         inputType: String? = nil,
                         heading: String? = "Pricing",
                         region: PageRegion = .main,
                         inViewport: Bool = true,
                         context: String? = nil) -> ObservedElement {
        ObservedElement(index: index, role: role, name: name, text: text, href: href,
                        inputType: inputType, heading: heading, region: region,
                        inViewport: inViewport, context: context, formAction: nil, formMethod: nil,
                        formSubmitLabel: nil, options: nil, checked: nil)
    }

    func testAnObserverReportDecodes() throws {
        let json = #"""
        {"url":"https://a.test/","title":"A","truncated":false,"flags":{"loginForm":false,"paymentForm":false},"elements":[{"index":0,"role":"link","name":"Plans","text":"See plans","href":"https://a.test/plans","inputType":null,"heading":"Pricing","region":"main","inViewport":true,"value":null,"touchesSecret":false,"showsAmount":false}],"text":"Pricing See plans","scrollY":120}
        """#
        let page = try ObservedPage.decode(json)
        XCTAssertEqual(page.url, "https://a.test/")
        XCTAssertEqual(page.title, "A")
        XCTAssertFalse(page.truncated)
        XCTAssertEqual(page.elements, [element()])
        XCTAssertEqual(page.text, "Pricing See plans")
        XCTAssertEqual(page.scrollY, 120)
    }

    /// Whether a control could send a secret (owner decision 4), and whether
    /// its form or region shows a money amount (owner decision 6; review of
    /// A3d, round 2, P1-7), are part of every element: an element without
    /// either is not a complete report. A field's value is read when there is
    /// one.
    func testAnElementSaysWhetherItCouldSendASecret() throws {
        let head = #"{"url":"https://a.test/","title":"A","truncated":false,"flags":{"loginForm":false,"paymentForm":false},"text":"","scrollY":0,"elements":[{"index":0,"role":"textbox","name":"Email","text":"","href":null,"inputType":"email","heading":null,"region":"main","inViewport":true"#
        XCTAssertThrowsError(try ObservedPage.decode(head + #"}]}"#))
        XCTAssertThrowsError(try ObservedPage.decode(head + #","touchesSecret":true}]}"#), "no showsAmount")
        XCTAssertThrowsError(try ObservedPage.decode(head + #","showsAmount":true}]}"#), "no touchesSecret")
        let page = try ObservedPage.decode(head + #","value":"sam@example.com","touchesSecret":true,"showsAmount":true}]}"#)
        XCTAssertEqual(page.elements.first?.value, "sam@example.com")
        XCTAssertEqual(page.elements.first?.touchesSecret, true)
        XCTAssertEqual(page.elements.first?.showsAmount, true)
    }

    /// The page's text and scroll position are part of every report
    /// (ITER-076 A3a): one without them is not a complete report.
    func testAReportWithoutTheTextOrTheScrollIsRefused() {
        let head = #"{"url":"https://a.test/","title":"A","truncated":false,"flags":{"loginForm":false,"paymentForm":false},"elements":[]"#
        XCTAssertThrowsError(try ObservedPage.decode(head + #","scrollY":0}"#))
        XCTAssertThrowsError(try ObservedPage.decode(head + #","text":""}"#))
        XCTAssertNoThrow(try ObservedPage.decode(head + #","text":"","scrollY":0}"#))
    }

    func testGarbageIsRefused() {
        XCTAssertThrowsError(try ObservedPage.decode("not json"))
        XCTAssertThrowsError(try ObservedPage.decode(#"{"url":"x"}"#))
    }

    /// A page can make the report as big as it likes; the app reads a bounded
    /// amount and refuses the rest instead of decoding it.
    func testAnOversizedReportIsRefused() {
        let huge = String(repeating: " ", count: ObservedPage.maxReportBytes + 1)
        XCTAssertThrowsError(try ObservedPage.decode(huge)) { error in
            XCTAssertEqual(error as? ObservationError, .tooLarge)
        }
    }

    /// Twin links — same name, destination, heading and row — go to the same
    /// place, so the occurrence among them is enough to act on one.
    func testTwinLinksAreMatchedByOccurrence() {
        let more = { (index: Int) in self.element(index: index, name: "Learn more", text: "Learn more") }
        let page = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none,
                                elements: [more(0), element(index: 1, name: "Other"), more(2), more(3)])
        let identities = page.elements.map(page.identity(of:))
        XCTAssertEqual(identities.map(\.occurrence), [0, 0, 1, 2])
        XCTAssertEqual(identities.map(\.total), [3, 1, 3, 3])
        XCTAssertEqual(page.element(matching: identities[2])?.index, 2)
    }

    /// Twin buttons may act on different rows; position among them says
    /// nothing once a row moves, so they are refused and the step is decided
    /// again (§6.3).
    func testTwinButtonsAreRefused() {
        let remove = { (index: Int) in
            self.element(index: index, role: "button", name: "Remove", text: "Remove", href: nil,
                         heading: "Saved addresses")
        }
        let page = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none,
                                elements: [remove(0), remove(1)])
        XCTAssertNil(page.element(matching: page.identity(of: page.elements[0])))
    }

    /// Twins that are not one destination are the same act only when the element is provably the same node: its key,
    /// which the observer keeps for the document's life, in the same document — not its place among them
    /// (2026-10-21: on DemoQA every Yes on a field with a twin lapsed, "2 like it before, 2 now").
    func testATwinIsFoundAgainByItsKeyInTheSameDocument() {
        let field = { (index: Int, key: Int) -> ObservedElement in
            var twin = self.element(index: index, role: "textbox", name: "", text: "", href: nil, heading: "Practice Form")
            twin.key = key
            return twin
        }
        var before = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none,
                                  elements: [field(0, 7), field(1, 9)])
        before.documentID = "D1"
        var after = before
        after.elements = [field(0, 7), field(1, 9)]
        let target = before.elements[1]
        XCTAssertNil(after.element(matching: before.identity(of: target)), "by its place alone, still refused")
        XCTAssertEqual(after.element(sameAs: target, matching: before.identity(of: target), seenIn: before)?.key, 9)

        var moved = after
        moved.elements = [field(0, 9), field(1, 7)]
        XCTAssertNil(moved.element(sameAs: target, matching: before.identity(of: target), seenIn: before),
                     "the twins swapped: the node at its place is another one")
        var reloaded = after
        reloaded.documentID = "D2"
        XCTAssertNil(reloaded.element(sameAs: target, matching: before.identity(of: target), seenIn: before),
                     "another document numbers its nodes anew")
        var unknown = after
        unknown.documentID = nil
        XCTAssertNil(unknown.element(sameAs: target, matching: before.identity(of: target), seenIn: before))
        var framed = field(1, 9)
        framed.frame = "F1"
        var inFrame = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none,
                                   elements: [field(0, 7), framed])
        inFrame.documentID = "D1"
        XCTAssertNil(inFrame.element(sameAs: framed, matching: inFrame.identity(of: framed), seenIn: inFrame),
                     "a frame's document is not the page's: its keys are not compared")
    }

    /// A link twin is only safe when both go to a real, whole address.
    /// Without an href they may run different scripts; with one cut at the
    /// report's limit they may differ after the cut.
    func testTwinLinksWithoutAWholeAddressAreRefused() {
        let noHref = { (index: Int) in self.element(index: index, name: "Open", text: "Open", href: nil) }
        let bare = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none,
                                elements: [noHref(0), noHref(1)])
        XCTAssertNil(bare.element(matching: bare.identity(of: bare.elements[0])))

        let cut = "https://a.test/" + String(repeating: "a", count: ObserverScript.maxURLLength - 15)
        XCTAssertEqual(cut.count, ObserverScript.maxURLLength)
        let longHref = { (index: Int) in self.element(index: index, name: "Open", text: "Open", href: cut) }
        let long = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none,
                                elements: [longHref(0), longHref(1)])
        XCTAssertNil(long.element(matching: long.identity(of: long.elements[0])))
    }

    /// The Swift limit and the script's own must be the same number.
    func testTheURLLimitMatchesTheScript() {
        XCTAssertTrue(ObserverScript.source.contains("MAX_URL = \(ObserverScript.maxURLLength)"))
    }

    func testAChangedNumberOfTwinsMatchesNothing() {
        let more = { (index: Int) in self.element(index: index, name: "Learn more", text: "Learn more") }
        let before = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none,
                                  elements: [more(0), more(1), element(index: 2, name: "Other")])
        let after = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none,
                                 elements: [more(0), more(1), more(2), element(index: 3, name: "Other")])
        XCTAssertNil(after.element(matching: before.identity(of: before.elements[1])))
        XCTAssertEqual(after.element(matching: before.identity(of: before.elements[2]))?.index, 3,
                       "a unique element is still found wherever it moved")
    }

    func testTheFingerprintIgnoresTheIndex() {
        XCTAssertEqual(element(index: 0).fingerprint, element(index: 7).fingerprint)
    }

    func testTheFingerprintIgnoresViewportAndVisibleText() {
        XCTAssertEqual(element(text: "See plans", inViewport: true).fingerprint,
                       element(text: "See all plans", inViewport: false).fingerprint)
    }

    func testTheFingerprintSeesWhatIdentifiesAnElement() {
        let base = element().fingerprint
        XCTAssertNotEqual(element(role: "button").fingerprint, base)
        XCTAssertNotEqual(element(name: "Pricing plans").fingerprint, base)
        XCTAssertNotEqual(element(href: "https://a.test/other").fingerprint, base)
        XCTAssertNotEqual(element(heading: "Enterprise").fingerprint, base)
        XCTAssertNotEqual(element(context: "Office").fingerprint, base)
    }

    func testTheFingerprintIsStableAndShort() {
        let fingerprint = element().fingerprint
        XCTAssertEqual(fingerprint, element().fingerprint)
        XCTAssertEqual(fingerprint.count, 16)
        XCTAssertTrue(fingerprint.allSatisfy { "0123456789abcdef".contains($0) })
    }

    // MARK: - ITER-076 I-09: frames

    private func page(_ address: String, _ elements: [ObservedElement], flags: PageFlags = .none,
                      text: String = "") -> ObservedPage {
        var page = ObservedPage(url: address, title: "T", truncated: false, flags: flags, elements: elements)
        page.text = text
        page.address = address
        return page
    }

    /// A frame's controls join the page's, each numbered anew — a made-up
    /// dropdown's options still name their dropdown — and each carrying its
    /// frame, which is part of its identity: the same control in two frames
    /// is two controls, and twins are counted within one frame. The page's
    /// own controls keep the identity they always had.
    func testAFramesControlsJoinThePageWithTheirFrameInTheirIdentity() {
        let top = page("https://a.test/", [element(index: 0, role: "button", name: "Top", href: nil)])
        var list = element(index: 1, role: "option", name: "Terrace", href: nil)
        list.listOf = 0
        let widget = [element(index: 0, role: "combobox", name: "Seating", href: nil), list]
        let merged = top.merging([(id: "F1", identity: "F1", page: page("https://b.test/", widget)),
                                  (id: "F2", identity: "F2", page: page("https://b.test/", widget))])
        XCTAssertEqual(merged.elements.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(merged.elements.map(\.frame), [nil, "F1", "F1", "F2", "F2"])
        XCTAssertEqual(merged.elements.map(\.listOf), [nil, nil, 1, nil, 3])
        XCTAssertEqual(merged.elements[0].fingerprint, top.elements[0].fingerprint, "the page's own: as before")
        XCTAssertNotEqual(merged.elements[1].fingerprint, widget[0].fingerprint, "the frame is part of it")
        XCTAssertNotEqual(merged.elements[1].fingerprint, merged.elements[3].fingerprint, "two frames, two controls")
        XCTAssertEqual(merged.identity(of: merged.elements[3]).total, 1)
        XCTAssertEqual(merged.element(matching: merged.identity(of: merged.elements[3]))?.frame, "F2")
        let click = { (target: ObservedElement) in
            AgentAction(operation: .click, target: target, destination: nil, payload: nil, isPlannedSearch: false)
        }
        XCTAssertNotEqual(click(merged.elements[1]).effect, click(merged.elements[3]).effect,
                          "a No to one frame's control is not a No to the other's")
    }

    /// Each control answers to its own frame: where it is, and what that
    /// frame asks for. The page's flags hold every frame's; its text, every
    /// frame's, bounded as the page's own.
    func testEachControlAnswersToItsOwnFrame() {
        let top = page("https://a.test/", [element(index: 0, role: "button", name: "Top", href: nil)],
                       text: String(repeating: "a", count: 5_990))
        let card = page("https://pay.test/card", [element(index: 0, role: "textbox", name: "Postal code", href: nil)],
                        flags: PageFlags(loginForm: false, paymentForm: true), text: "Card details")
        let merged = top.merging([(id: "F1", identity: "F1", page: card)])
        XCTAssertEqual(merged.address(of: merged.elements[0]), "https://a.test/")
        XCTAssertEqual(merged.address(of: merged.elements[1]), "https://pay.test/card")
        XCTAssertEqual(merged.flags(of: merged.elements[0]), merged.flags, "the page's: with every frame's")
        XCTAssertEqual(merged.flags(of: merged.elements[1]), PageFlags(loginForm: false, paymentForm: true))
        XCTAssertEqual(merged.flags, PageFlags(loginForm: false, paymentForm: true))
        XCTAssertEqual(merged.text.count, 6_000)
        XCTAssertTrue(merged.text.hasSuffix("\nCard deta"), merged.text.suffix(12).description)
        XCTAssertEqual(merged.liveAddress, "https://a.test/")
    }

    /// A frame from another site that holds a sign-in — a password field, or
    /// an OAuth request in its address — or a card form is the user's part:
    /// every control in it could send a secret, its links aside, which only
    /// leave the page. A frame of the page's own site is judged by its own
    /// fields, as the page is.
    func testAFrameFromAnotherSiteWithASignInOrACardIsTheUsersPart() {
        let top = page("https://www.a.test/", [])
        let fields = [element(index: 0, role: "button", name: "Next", href: nil),
                      element(index: 1, role: "link", name: "Help", href: "https://b.test/help")]
        let login = PageFlags(loginForm: true, paymentForm: false)
        let other = top.merging([(id: "F1", identity: "F1", page: page("https://b.test/", fields, flags: login))])
        XCTAssertEqual(other.elements.map(\.touchesSecret), [true, false])
        let card = top.merging([(id: "F1", identity: "F1", page: page("https://b.test/", fields,
                                                       flags: PageFlags(loginForm: false, paymentForm: true)))])
        XCTAssertEqual(card.elements.map(\.touchesSecret), [true, false])
        let own = top.merging([(id: "F1", identity: "F1", page: page("https://a.test/login", fields, flags: login))])
        XCTAssertEqual(own.elements.map(\.touchesSecret), [false, false], "the page's own site: its own rules")
        let plain = top.merging([(id: "F1", identity: "F1", page: page("https://b.test/", fields))])
        XCTAssertEqual(plain.elements.map(\.touchesSecret), [false, false])
        // A sign-in button from another site that asks for access by OAuth.
        let oauth = top.merging([(id: "F1", identity: "F1", page: page("https://accounts.b.test/button?client_id=app&response_type=code",
                                                       fields))])
        XCTAssertEqual(oauth.elements.map(\.touchesSecret), [true, false])
    }

    /// Who a frame is — not the browser's id for it, which a reload changes —
    /// is part of each control's identity: the same control in a frame made
    /// anew is the same control, and a No to it holds; in another frame, it
    /// is another control. Each is acted on in the frame it is in now (review
    /// of I-09, F5).
    func testAFramesControlsAreKnownByWhoTheFrameIsNotByItsId() {
        let top = page("https://a.test/", [])
        let widget = [element(index: 0, role: "button", name: "Remove member", href: nil)]
        let first = top.merging([(id: "F1", identity: "/https://a.test#0", page: page("https://a.test/w", widget))])
        let again = top.merging([(id: "F9", identity: "/https://a.test#0", page: page("https://a.test/w", widget))])
        let other = top.merging([(id: "F1", identity: "/https://a.test#1", page: page("https://a.test/w", widget))])
        let click = { (target: ObservedElement) in
            AgentAction(operation: .click, target: target, destination: nil, payload: nil, isPlannedSearch: false)
        }
        XCTAssertEqual(first.elements[0].fingerprint, again.elements[0].fingerprint)
        XCTAssertEqual(click(first.elements[0]).effect, click(again.elements[0]).effect, "a No holds")
        XCTAssertEqual(again.elements[0].frame, "F9", "acted on where it is now")
        XCTAssertNotEqual(first.elements[0].fingerprint, other.elements[0].fingerprint)
        XCTAssertNotEqual(click(first.elements[0]).effect, click(other.elements[0]).effect)
    }

    /// The consent's family (Codex review of 10d923e..41c4983, P1-2): an address under the domain the consent host
    /// stands in — the host's last two labels — whatever its depth: login.eu.example.com's approval kept at
    /// accounts.example.com is of it; another site is not.
    func testAnAddressUnderTheConsentsDomainIsOfTheConsent() {
        let consent = page("https://login.eu.example.com/auth?client_id=app&response_type=code&redirect_uri=https%3A%2F%2Fapp.test%2Fcb", [])
        for address in ["https://accounts.example.com/continue?decision=yes", "https://example.com/", "https://login.eu.example.com/x",
                        "https://deep.eu.example.com/approve"] {
            XCTAssertTrue(consent.isOfTheConsent(address), address)
        }
        for address in ["https://other.org/", "https://example.com.other.org/", "https://notexample.com/", "https://duckduckgo.com/?q=x"] {
            XCTAssertFalse(consent.isOfTheConsent(address), address)
        }
        let short = page("https://idp.test/authorize?client_id=app&redirect_uri=x", [])
        XCTAssertTrue(short.isOfTheConsent("https://finish.idp.test/continue"))
        XCTAssertFalse(short.isOfTheConsent("https://site.test/"))
        XCTAssertFalse(page("https://a.test/apps", []).isOfTheConsent("https://a.test/approve"), "no consent, no family")
        // A host written with its root's dot is the same host (Codex review 2 of 2026-10-21's second round, P1).
        let rooted = page("https://login.eu.example.com./auth?client_id=app&response_type=code&redirect_uri=https%3A%2F%2Fapp.test%2Fcb", [])
        for address in ["https://login.eu.example.com./continue?decision=yes", "https://accounts.example.com./x",
                        "https://accounts.example.com/x"] {
            XCTAssertTrue(rooted.isOfTheConsent(address), address)
        }
        XCTAssertTrue(consent.isOfTheConsent("https://accounts.example.com./continue"))
        XCTAssertFalse(rooted.isOfTheConsent("https://other.org./"))
    }

    /// A frame whose address asks for access by OAuth makes the page ask for
    /// a grant, whatever the frame's site — as the page's own address does
    /// (review of I-09, F3).
    func testAFrameWhoseAddressAsksForAccessMakesThePageAskForAGrant() {
        let top = page("https://a.test/apps", [])
        let consent = "https://a.test/oauth/authorize?client_id=app&response_type=code&redirect_uri=https%3A%2F%2Fa.test%2Fcb"
        XCTAssertTrue(page(consent, []).asksForGrant, "the page itself")
        XCTAssertTrue(top.merging([(id: "F1", identity: "i", page: page(consent, []))]).asksForGrant, "its own site")
        XCTAssertTrue(top.merging([(id: "F1", identity: "i",
                                    page: page("https://b.test/authorize?client_id=app&redirect_uri=x", []))]).asksForGrant,
                      "another site")
        XCTAssertFalse(top.asksForGrant)
        XCTAssertFalse(top.merging([(id: "F1", identity: "i", page: page("https://a.test/widget?client_id=app", []))])
            .asksForGrant, "a client named, no request")
    }

    /// An identity provider's frame from another site — an address that names
    /// an OAuth client, or a host that signs people in — is the user's part
    /// with no password field in it, its links aside; one of the page's own
    /// site, or no identity provider's, is judged by its own fields (review
    /// of I-09, F6).
    func testAnIdentityProvidersFrameFromAnotherSiteIsTheUsersPart() {
        let top = page("https://a.test/", [])
        let chooser = [element(index: 0, role: "button", name: "Continue as Sam", href: nil),
                       element(index: 1, role: "link", name: "Help", href: "https://b.test/help")]
        for address in ["https://b.test/gsi/select?client_id=app-1", "https://b.test/x?client%5Fid%3Dapp-1",
                        "https://accounts.google.com/gsi/button", "https://appleid.apple.com/auth/frame",
                        "https://login.microsoftonline.com/common/frame", "https://login.live.com/frame",
                        "https://www.facebook.com/v18.0/dialog/oauth", "https://github.com/login/oauth/select"] {
            let merged = top.merging([(id: "F1", identity: "i", page: page(address, chooser))])
            XCTAssertEqual(merged.elements.map(\.touchesSecret), [true, false], address)
        }
        for address in ["https://a.test/gsi/select?client_id=app-1", "https://www.facebook.com/plugins/like",
                        "https://github.com/acme/widget", "https://b.test/frame"] {
            let merged = top.merging([(id: "F1", identity: "i", page: page(address, chooser))])
            XCTAssertEqual(merged.elements.map(\.touchesSecret), [false, false], address)
        }
    }

    // MARK: - Review round 3 of I-09, part C (Claude review c8)

    /// A total one frame shows reaches the controls of every frame, not only
    /// the page's controls that hold one: an order button in a frame beside
    /// the frame that shows the total is a payment's (Claude review c8 of
    /// I-09, #20).
    func testATotalInOneFrameReachesTheControlsOfEveryFrame() {
        var order = element(index: 0, role: "button", name: "Bestellen", href: nil)
        order.holdsFrame = false
        var total = page("https://b.test/total", [], text: "Total: 49,00 EUR")
        total.amountShown = true
        let top = page("https://a.test/", [element(index: 0, role: "link", name: "Help", href: "https://a.test/help")])
        let merged = top.merging([(id: "F1", identity: "/https://b.test", page: total),
                                  (id: "F2", identity: "/https://b.test", page: page("https://b.test/order", [order]))])
        XCTAssertEqual(merged.elements.first { $0.name == "Bestellen" }?.showsAmount, true)
        XCTAssertEqual(merged.elements.first { $0.name == "Help" }?.showsAmount, false, "the page's own: by its region")
    }

    /// A frame the look did not read may show a total, and may hold a twin:
    /// every control whose form or region holds a frame, and every frame's
    /// control, is read as showing a total (#19); a frame control whose
    /// frame is one of the unread's — or any, when one could not even be
    /// listed — is not reported: it cannot be told from a twin it may have
    /// there (#21).
    func testAFrameNotReadMayShowATotalAndHoldATwin() {
        var order = element(index: 0, role: "button", name: "Jetzt bestellen", href: nil)
        order.holdsFrame = true
        var help = element(index: 1, role: "link", name: "Help", href: "https://a.test/help")
        help.holdsFrame = false
        let top = page("https://a.test/", [order, help])
        let widget = page("https://b.test/member", [element(index: 0, role: "button", name: "Remove member", href: nil)])
        let other = page("https://c.test/chat", [element(index: 0, role: "button", name: "Open chat", href: nil)])
        let frames = [(id: "F1", identity: "/https://b.test", page: widget),
                      (id: "F2", identity: "/https://c.test", page: other)]
        let whole = top.merging(frames)
        XCTAssertEqual(whole.elements.map(\.name), ["Jetzt bestellen", "Help", "Remove member", "Open chat"])
        XCTAssertEqual(whole.elements.map(\.showsAmount), [false, false, false, false])
        let twinUnread = top.merging(frames, unread: ObservedPage.Unread(identities: ["/https://b.test"]))
        XCTAssertEqual(twinUnread.elements.map(\.name), ["Jetzt bestellen", "Help", "Open chat"])
        XCTAssertEqual(twinUnread.elements.map(\.showsAmount), [true, false, true])
        let unlisted = top.merging(frames, unread: ObservedPage.Unread(unknown: true))
        XCTAssertEqual(unlisted.elements.map(\.name), ["Jetzt bestellen", "Help"])
        XCTAssertEqual(unlisted.elements.map(\.showsAmount), [true, false])
    }
}
