import XCTest
@testable import MetaWhisp

/// The safety rules that do not need a model (ITER-074 §6.3, §7.1, §7.2):
/// the irreversible lexicon, the navigation check, the cookie-banner policy
/// and how a confirmation is bound and how long it waits.
///
/// The lexicon is English only. Other languages are read through the page's
/// structure and Jev's risk answer (ITER-076 2.1), and page text in any
/// language is a fixture, never a word list.
final class SafetyGuardTests: XCTestCase {

    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Services/Agent/SafetyGuardTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func element(role: String = "button", name: String, text: String? = nil, href: String? = nil,
                         formAction: String? = nil, formMethod: String? = nil,
                         formSubmitLabel: String? = nil) -> ObservedElement {
        ObservedElement(index: 0, role: role, name: name, text: text ?? name, href: href, inputType: nil,
                        heading: "Section", region: .main, inViewport: true, context: nil,
                        formAction: formAction, formMethod: formMethod, formSubmitLabel: formSubmitLabel,
                        options: nil, checked: nil)
    }

    /// A field's edit that sends nothing is only an edit: typing, a choice in a form its own button sends, a box
    /// ticked. A submit button sends, and is none. A choice is one wherever its list stands (2026-10-21): in a form no
    /// button sends, in no form — its change may send, so it still commits as an act, and what it sends under the hold
    /// is held back and asked about as a send.
    func testAnEditThatSendsNothingIsOnlyAnEdit() {
        func act(_ operation: AgentOperation, _ target: ObservedElement) -> AgentAction {
            AgentAction(operation: operation, target: target, destination: nil, payload: "x", isPlannedSearch: false)
        }
        let field = element(role: "textbox", name: "Contact Name", formAction: "https://shop.test/book", formMethod: "post",
                            formSubmitLabel: "Register")
        XCTAssertTrue(SafetyGuard.editsOnly(act(.type, field)))
        let list = element(role: "combobox", name: "Payment Method", formAction: "https://shop.test/book",
                           formMethod: "post", formSubmitLabel: "Register")
        XCTAssertTrue(SafetyGuard.editsOnly(act(.select, list)))
        let box = element(role: "checkbox", name: "Subscribe", formAction: "https://shop.test/book", formMethod: "post",
                          formSubmitLabel: "Register")
        XCTAssertTrue(SafetyGuard.editsOnly(act(.click, box)))
        let alone = element(role: "combobox", name: "Sort", formAction: "https://shop.test/list", formMethod: "post")
        XCTAssertTrue(SafetyGuard.editsOnly(act(.select, alone)), "a choice no button sends is an edit under the hold")
        XCTAssertTrue(SafetyGuard.commits(act(.select, alone)), "its change may send: it still commits as an act")
        let formless = element(role: "combobox", name: "Order by")
        XCTAssertTrue(SafetyGuard.editsOnly(act(.select, formless)), "a choice in no form is an edit under the hold")
        XCTAssertTrue(SafetyGuard.commits(act(.select, formless)))
        let boxAlone = element(role: "checkbox", name: "In stock")
        XCTAssertFalse(SafetyGuard.editsOnly(act(.click, boxAlone)), "a box no button sends stays a commit")
        var send = element(name: "Register", formAction: "https://shop.test/book", formMethod: "post",
                           formSubmitLabel: "Register")
        send.submits = true
        XCTAssertFalse(SafetyGuard.editsOnly(act(.click, send)))
        XCTAssertFalse(SafetyGuard.editsOnly(AgentAction(operation: .open, target: nil, destination: "https://a.test/",
                                                         payload: nil, isPlannedSearch: true)))
    }

    /// A click on a field only focuses it or opens its list — a text box, a box to search in, a list to choose in —
    /// as the click typing starts with does (2026-10-21, blind b03: a click that opened a made-up State list in a form
    /// whose button says Submit was asked about as a send, every time). Wherever its form stands — a GET form, a POST
    /// form, none — it is an edit under the send hold; as a choice does, it still commits as an act — the hands and the
    /// step check it again, and a Yes asked for it without the hold is bound as a press's (Codex review of 2026-10-21,
    /// P1-2, P1-3, P1-5). A button beside it, a script's or a submit, is no edit.
    func testAClickOnAFieldIsAnEditAndStillCommitsAsAnAct() {
        let click = { (target: ObservedElement) in
            AgentAction(operation: .click, target: target, destination: nil, payload: nil, isPlannedSearch: false)
        }
        for role in ["textbox", "searchbox", "combobox", "spinbutton"] {
            for (method, action) in [("get", "https://a.test/form"), ("post", "https://a.test/form"), (nil, nil)] as [(String?, String?)] {
                var field = element(role: role, name: "Select State", formAction: action, formMethod: method,
                                    formSubmitLabel: method == nil ? nil : "Submit")
                field.typedInto = true
                XCTAssertTrue(SafetyGuard.editsOnly(click(field)), "\(role) in \(method ?? "no form")")
                XCTAssertTrue(SafetyGuard.commits(click(field)), "\(role) in \(method ?? "no form")")
            }
        }
        // A field typing never goes into — read-only, aria-readonly, a native select whatever its role, a list box —
        // is clicked as no typing is: its click is asked about as any control's (Codex reviews 2 and 3 of 2026-10-21).
        let readOnly = element(role: "textbox", name: "Delete draft", formAction: "https://a.test/form", formMethod: "get",
                               formSubmitLabel: "Submit")
        XCTAssertFalse(SafetyGuard.editsOnly(click(readOnly)), "a read-only field's click is no typing's")
        var lockedList = element(role: "combobox", name: "Status", formAction: "https://a.test/form", formMethod: "get",
                                 formSubmitLabel: "Submit")
        lockedList.typedInto = false
        XCTAssertFalse(SafetyGuard.editsOnly(click(lockedList)), "an aria-readonly select is no field typed in")
        XCTAssertFalse(SafetyGuard.editsOnly(click(element(role: "listbox", name: "Colours", formAction: "https://a.test/form",
                                                           formMethod: "get", formSubmitLabel: "Submit"))))
        let script = element(role: "button", name: "Select", formAction: "https://a.test/form", formMethod: "get",
                             formSubmitLabel: "Submit")
        XCTAssertFalse(SafetyGuard.editsOnly(click(script)), "a script's button beside it may send")
        XCTAssertTrue(SafetyGuard.commits(click(script)))
        var send = element(role: "button", name: "Submit", formAction: "https://a.test/form", formMethod: "get",
                           formSubmitLabel: "Submit")
        send.submits = true
        XCTAssertFalse(SafetyGuard.editsOnly(click(send)))
        XCTAssertTrue(SafetyGuard.commits(click(send)))
    }

    /// An address the model opens that carries an OAuth request — a client asking to be sent back somewhere — is a
    /// grant, as a link to it is (Codex review of 2026-10-21, P1-4: the brain could open a consent page's approval by
    /// its address, with no control to wall). An address whose words only speak of one is no grant.
    func testAnAddressTheModelOpensThatCarriesAnOAuthRequestIsAGrant() {
        let open = { (address: String) in
            AgentAction(operation: .open, target: nil, destination: address, payload: nil, isPlannedSearch: false)
        }
        XCTAssertTrue(SafetyGuard.isGrant(open("https://idp.test/authorize?client_id=a&redirect_uri=https%3A%2F%2Fb.test%2Fcb&response_type=code")))
        XCTAssertTrue(SafetyGuard.isGrant(open("https://idp.test/oauth?client_id=a&request_uri=urn%3Ax")))
        XCTAssertFalse(SafetyGuard.isGrant(open("https://en.wikipedia.org/wiki/Authorization")))
        XCTAssertFalse(SafetyGuard.isGrant(open("https://idp.test/docs?client_id=a")), "a client named, sent nowhere")
    }

    // MARK: - Lexicon (§7.1)

    /// Action labels use the verb's base form: "Send", "Delete account",
    /// "Buy now". Matching is by whole word, case-insensitive.
    func testTheLexiconFindsIrreversibleActionWords() {
        for text in ["Send", "Delete account", "Post", "Share", "Pay now", "Buy now", "Place order",
                     "Accept all", "Authorise app", "Authorize", "Confirm", "Invite a friend", "SUBMIT",
                     "Purchase", "Checkout", "Transfer funds", "Donate", "Place bid", "Book a room",
                     "Reserve", "Subscribe", "Upload file", "Withdraw", "Sell"] {
            XCTAssertNotNil(SafetyGuard.lexiconHit(in: [text]), text)
        }
    }

    /// Nouns and other forms name places, not actions: "Posts" and "Orders"
    /// are sections, "Deleted items" a folder. What the lexicon misses, the
    /// irreversible question to the model still asks (§6.3).
    func testTheLexiconIgnoresOrdinaryWordsAndNouns() {
        for text in ["See plans", "Learn more", "Pricing", "Sender guide", "Payload", "Postal code",
                     "Ordinary link", "Posts", "Orders", "Deleted items", "Shared calendar"] {
            XCTAssertNil(SafetyGuard.lexiconHit(in: [text]), text)
        }
    }

    func testTheLexiconReadsAddressesIncludingCamelCase() {
        XCTAssertNotNil(SafetyGuard.lexiconHit(in: ["https://a.test/account/delete"]))
        XCTAssertNotNil(SafetyGuard.lexiconHit(in: ["/api/deleteAccount"]))
        XCTAssertNotNil(SafetyGuard.lexiconHit(in: ["/api/DELETEAccount"]), "an acronym before a word")
        XCTAssertNotNil(SafetyGuard.lexiconHit(in: ["https://a.test/manage?action=%64elete"]), "percent-encoded")
        XCTAssertNotNil(SafetyGuard.lexiconHit(in: ["https://a.test/go?what=delete+account"]), "plus as a space")
        XCTAssertNil(SafetyGuard.lexiconHit(in: ["https://a.test/pricing?plan=pro"]))
    }

    /// Name, visible text, the form's submit label and the destination are
    /// all read: a benign name cannot hide what the form does.
    func testTheWholeActionIsReadNotJustItsName() {
        let benignNameSubmittingForm = element(name: "Continue", formAction: "https://a.test/send-message",
                                               formMethod: "post", formSubmitLabel: "Continue")
        let action = AgentAction(operation: .click, target: benignNameSubmittingForm, destination: nil,
                                 payload: nil, isPlannedSearch: false)
        XCTAssertTrue(SafetyGuard.lexiconRequiresConfirmation(action))

        let hiddenInText = element(name: "Details", text: "Delete this address")
        XCTAssertTrue(SafetyGuard.lexiconRequiresConfirmation(
            AgentAction(operation: .click, target: hiddenInText, destination: nil, payload: nil,
                        isPlannedSearch: false)))

        let plain = element(role: "link", name: "Pricing", href: "https://a.test/pricing")
        XCTAssertFalse(SafetyGuard.lexiconRequiresConfirmation(
            AgentAction(operation: .open, target: plain, destination: "https://a.test/pricing", payload: nil,
                        isPlannedSearch: false)))
    }

    /// Signing the user out, unsubscribing, cancelling or approving is never
    /// done on the agent's own say-so.
    func testLeavingOrUndoingNeedsAYes() {
        for (href, name) in [("https://a.test/logout", "Account"), ("https://a.test/me", "Log out"),
                             ("https://a.test/newsletter/unsubscribe", "Manage email"),
                             ("https://a.test/orders/1/cancel", "Details"),
                             ("https://a.test/requests/7?action=approve", "Open")] {
            let link = element(role: "link", name: name, href: href)
            XCTAssertTrue(SafetyGuard.lexiconRequiresConfirmation(
                AgentAction(operation: .open, target: link, destination: href, payload: nil, isPlannedSearch: false)),
                href)
        }
    }

    // MARK: - Navigation check (§6.3)

    func testAnOrdinaryLinkPassesTheNavigationCheck() {
        XCTAssertTrue(SafetyGuard.passesNavigationCheck(url: URL(string: "https://a.test/pricing")!,
                                                        linkText: "See plans"))
    }

    func testActionWordsFailTheNavigationCheck() {
        let cases: [(String, String)] = [
            ("https://a.test/newsletter/unsubscribe?id=1", "Manage email"),
            ("https://a.test/logout", "Account"),
            ("https://a.test/session/end", "Log out"),
            ("https://a.test/me", "Sign out"),
            ("https://a.test/orders/1/cancel", "Details"),
            ("https://a.test/requests/7?action=approve", "Open"),
            ("https://a.test/account/delete", "Settings")
        ]
        for (address, text) in cases {
            XCTAssertFalse(SafetyGuard.passesNavigationCheck(url: URL(string: address)!, linkText: text), address)
        }
    }

    func testAnEncodedQueryFailsTheNavigationCheck() {
        XCTAssertFalse(SafetyGuard.passesNavigationCheck(url: URL(string: "https://a.test/manage?action=%64elete")!,
                                                         linkText: "Details"))
    }

    func testNonWebAddressesFailTheNavigationCheck() {
        XCTAssertFalse(SafetyGuard.passesNavigationCheck(url: URL(string: "javascript:alert(1)")!, linkText: "Run"))
        XCTAssertFalse(SafetyGuard.passesNavigationCheck(url: URL(string: "mailto:someone@example.com")!,
                                                         linkText: "Write"))
    }

    /// A link from the page can do anything a GET can do — "Purchase",
    /// "Transfer", an opaque endpoint. Only back, scroll, wait, «more» and a
    /// search the app built itself skip the risk question.
    func testOnlyBackScrollWaitMoreAndPlannedSearchesAreAlwaysReversible() {
        for operation in [AgentOperation.back, .scroll, .wait, .more] {
            XCTAssertTrue(SafetyGuard.isAlwaysReversible(
                AgentAction(operation: operation, target: nil, destination: nil, payload: nil, isPlannedSearch: false)))
        }
        let safe = element(role: "link", name: "Site One", href: "https://site-1.test/")
        XCTAssertFalse(SafetyGuard.isAlwaysReversible(
            AgentAction(operation: .open, target: safe, destination: "https://site-1.test/", payload: nil,
                        isPlannedSearch: false)), "a link from the page always gets the risk question")
        let unsubscribe = element(role: "link", name: "Manage email", href: "https://a.test/unsubscribe")
        XCTAssertFalse(SafetyGuard.isAlwaysReversible(
            AgentAction(operation: .open, target: unsubscribe, destination: "https://a.test/unsubscribe",
                        payload: nil, isPlannedSearch: false)))
        for operation in [AgentOperation.click, .type, .select] {
            XCTAssertFalse(SafetyGuard.isAlwaysReversible(
                AgentAction(operation: operation, target: safe, destination: nil, payload: "x", isPlannedSearch: false)))
        }
    }

    /// A search the app built from the plan's own queries is the user's
    /// words, not the page's: always reversible even if a query says
    /// "delete".
    func testAPlannedSearchIsAlwaysReversible() {
        let search = AgentAction(operation: .open, target: nil,
                                 destination: "https://search.test/?q=how+to+delete+an+account",
                                 payload: nil, isPlannedSearch: true)
        XCTAssertTrue(SafetyGuard.isAlwaysReversible(search))
    }

    /// The planned-search flag alone is not trusted: a planned search has no
    /// target on the page and a web address.
    func testAPlannedSearchMustLookLikeOne() {
        let pretender = AgentAction(operation: .open, target: element(role: "link", name: "Buy", href: "https://a.test/buy"),
                                    destination: "https://a.test/buy", payload: nil, isPlannedSearch: true)
        XCTAssertFalse(SafetyGuard.isAlwaysReversible(pretender))
        let scripted = AgentAction(operation: .open, target: nil, destination: "javascript:alert(1)",
                                   payload: nil, isPlannedSearch: true)
        XCTAssertFalse(SafetyGuard.isAlwaysReversible(scripted))
    }

    // MARK: - Cookie banners (§7.2)

    func testACookieBannerIsRecognisedByItsTextAndConsentButtons() {
        XCTAssertTrue(CookieBanner.isRecognised(text: "We use cookies to improve the site.",
                                                buttonLabels: ["Reject all", "Accept all"]))
        XCTAssertFalse(CookieBanner.isRecognised(text: "Subscribe to our newsletter",
                                                 buttonLabels: ["Accept", "No thanks"]),
                       "consent words without cookies are not a cookie banner")
        XCTAssertFalse(CookieBanner.isRecognised(text: "Cookies are baked daily",
                                                 buttonLabels: ["Order now"]),
                       "cookies without consent buttons are not a cookie banner")
    }

    /// A dialog about access to an account is not a cookie banner, even if
    /// it mentions cookies: agreeing there would be a grant (§7.2).
    func testAGrantDialogIsNotACookieBanner() {
        XCTAssertFalse(CookieBanner.isRecognised(
            text: "Allow this app to access your account? We use cookies.",
            buttonLabels: ["Allow access", "Cancel"]))
    }

    /// A grant that mentions cookies is still a grant (review round 5): the
    /// text asks for access to something of the user's, or its only consent
    /// is a bare "Allow".
    func testAGrantThatMentionsCookiesIsNotACookieBanner() {
        let text = "Acme wants to access your files. We use cookies."
        XCTAssertFalse(CookieBanner.isRecognised(text: text, buttonLabels: ["Allow", "Cancel"]))
        XCTAssertFalse(CookieBanner.isRecognised(text: text, buttonLabels: ["Accept", "Cancel"]))
        XCTAssertFalse(CookieBanner.isRecognised(text: "We use cookies.", buttonLabels: ["Allow", "Cancel"]),
                       "a bare Allow is how a permission is granted")
        XCTAssertNil(CookieBanner.classify("Allow"))
        XCTAssertNil(CookieBanner.choice(buttonLabels: ["Allow", "Cancel"], blocksPage: true))
    }

    /// An Allow that says what it allows is still cookie consent, and the
    /// standard wording about accessing information on a device is no grant.
    func testAnAllowThatNamesItsScopeIsStillConsent() {
        XCTAssertEqual(CookieBanner.classify("Allow all"), .accept)
        XCTAssertEqual(CookieBanner.classify("Allow all cookies"), .accept)
        XCTAssertTrue(CookieBanner.isRecognised(
            text: "We and our partners store and/or access information on a device, such as cookies.",
            buttonLabels: ["Allow all", "Deny"]))
    }

    /// Accept is the one choice that grants something, so it is taken only
    /// when its own label says it accepts cookies: a bare «Accept» may sit on
    /// a dialog that asks for more (review round 7).
    func testABareAcceptIsNeverChosen() {
        XCTAssertNil(CookieBanner.choice(buttonLabels: ["Accept", "Cancel"], blocksPage: true))
        XCTAssertNil(CookieBanner.choice(buttonLabels: ["Accept all", "OK", "Got it"], blocksPage: true))
        XCTAssertEqual(CookieBanner.choice(buttonLabels: ["Accept cookies"], blocksPage: true)?.choice, .accept)
        XCTAssertEqual(CookieBanner.choice(buttonLabels: ["Settings", "Accept all cookies"], blocksPage: true)?.index, 1)
    }

    /// A control that opens a cookie window's settings — the way to its least consent when its first layer offers
    /// none (2026-10-21) — is read by its words as a consent label is: a settings word, with nothing around it but
    /// cookie words and a few plain ones. A consent, a save, a policy link and another kind of settings are none.
    func testAControlThatOpensACookieWindowsSettingsIsReadByItsWords() {
        for label in ["Cookie settings", "Cookies settings", "Manage preferences", "Customize", "Customise",
                      "Preferences", "Settings", "Options", "More options", "Manage cookies", "Cookie preferences",
                      "Privacy settings", "Manage my preferences"] {
            XCTAssertTrue(CookieBanner.opensSettings(label), label)
        }
        for label in ["Accept all cookies", "Accept all", "Allow all settings", "Accept and manage settings",
                      "Save preferences", "Confirm my choices", "Our cookie policy", "Learn more", "Account settings",
                      "Reject all", ""] {
            XCTAssertFalse(CookieBanner.opensSettings(label), label)
        }
    }

    /// A settings layer's save is read by its words (2026-10-21): save or confirm, with nothing around it but the
    /// words of what it saves. One that accepts, or allows, too is none.
    func testASettingsLayersSaveIsReadByItsWords() {
        for label in ["Confirm my choices", "Confirm My Choices", "Save preferences", "Save settings", "Save choices",
                      "Confirm choices", "Save and close", "Save", "Save my preferences"] {
            XCTAssertTrue(CookieBanner.saves(label), label)
        }
        for label in ["Save and accept all", "Accept and save", "Accept selected", "Allow selection", "Cookie settings",
                      "Allow All", ""] {
            XCTAssertFalse(CookieBanner.saves(label), label)
        }
    }

    /// A necessary switch (2026-10-21): one a person cannot change, or one named necessary, essential, strictly or
    /// required — never one named non-essential, not required or unnecessary.
    func testANecessarySwitchCannotChangeOrIsNamedSo() {
        func toggle(_ name: String, disabled: Bool? = nil) -> ObservedElement {
            var made = element(role: "switch", name: name, text: "")
            made.disabled = disabled
            return made
        }
        for name in ["Strictly Necessary Cookies", "Essential", "Required cookies", "Necessary", "Strictly"] {
            XCTAssertTrue(CookieBanner.isNecessary(toggle(name)), name)
        }
        XCTAssertTrue(CookieBanner.isNecessary(toggle("Session", disabled: true)), "a person cannot change it")
        for name in ["Targeting Cookies", "Non-essential cookies", "Non essential", "Not required", "Unnecessary",
                     "Session"] {
            XCTAssertFalse(CookieBanner.isNecessary(toggle(name, disabled: false)), name)
        }
    }

    // MARK: - Grants (§7.2, review round 11)

    /// The agent never grants anything: an action whose words grant — allow,
    /// grant, authorize — in what it shows or where it goes is the user's part.
    /// A label that names cookies is consent to cookies, not a grant
    /// (decision 15).
    func testAGrantIsRecognised() {
        func click(_ name: String, formAction: String? = nil) -> AgentAction {
            AgentAction(operation: .click, target: element(name: name, formAction: formAction), destination: nil,
                        payload: nil, isPlannedSearch: false)
        }
        XCTAssertTrue(SafetyGuard.isGrant(click("Allow access")))
        XCTAssertTrue(SafetyGuard.isGrant(click("Authorize Acme")))
        XCTAssertTrue(SafetyGuard.isGrant(click("Continue", formAction: "https://id.test/oauth/authorize")))
        XCTAssertFalse(SafetyGuard.isGrant(click("Allow all cookies")))
        XCTAssertFalse(SafetyGuard.isGrant(click("Send")))
        XCTAssertFalse(SafetyGuard.isGrant(AgentAction(operation: .scroll, target: nil, destination: nil, payload: nil,
                                                       isPlannedSearch: false)))
    }

    // MARK: - Structure, in any language (ITER-076 2.1)

    private func control(_ name: String, method: String?, action: String?, submits: Bool?,
                         operation: AgentOperation = .click) -> AgentAction {
        let target = ObservedElement(index: 0, role: "button", name: name, text: name, href: nil, inputType: nil,
                                     heading: "Section", region: .main, inViewport: true, context: nil,
                                     formAction: action, formMethod: method, formSubmitLabel: name,
                                     options: nil, checked: nil, submits: submits)
        return AgentAction(operation: operation, target: target, destination: nil,
                           payload: operation == .type ? "x" : nil, isPlannedSearch: false)
    }

    /// Sending a POST form changes something, so it needs a Yes whatever its
    /// button says, in whatever language.
    func testSendingAPostFormNeedsAYesInAnyLanguage() {
        for label in ["Supprimer le compte", "Continue", "Weiter", "OK"] {
            let send = control(label, method: "post", action: "https://a.test/account/close", submits: true)
            XCTAssertEqual(SafetyGuard.structuralReason(of: send, pageURL: "https://a.test/account"), .postForm, label)
        }
    }

    /// A form sent to another site hands it what was typed; a page whose
    /// address is unknown counts as another site. Sending a form on the same
    /// site needs a Yes too: a submit control is one (the plan's list).
    func testSendingAnyFormNeedsAYes() {
        let away = control("Weiter", method: "get", action: "https://other.test/subscribe", submits: true)
        XCTAssertEqual(SafetyGuard.structuralReason(of: away, pageURL: "https://a.test/"), .crossOriginForm)
        let home = control("Chercher", method: "get", action: "https://a.test/search", submits: true)
        XCTAssertEqual(SafetyGuard.structuralReason(of: home, pageURL: "https://a.test/page"), .submitsForm)
        XCTAssertEqual(SafetyGuard.structuralReason(of: home, pageURL: nil), .crossOriginForm)
        let unknown = control("Bestätigen", method: "get", action: "https://a.test/abo", submits: nil)
        XCTAssertEqual(SafetyGuard.structuralReason(of: unknown, pageURL: "https://a.test/"), .submitsForm,
                       "a control that does not say whether it submits counts as one that does")
    }

    /// Any click inside a POST form may send it (a label, a script button),
    /// so it needs a Yes; typing does not send, and closing a dialog form is
    /// no sending.
    func testWhatAClickInAFormNeedsDependsOnTheForm() {
        let typing = control("Message", method: "post", action: "https://a.test/x", submits: true, operation: .type)
        XCTAssertNil(SafetyGuard.structuralReason(of: typing, pageURL: "https://a.test/"))
        let plainInPost = control("Afficher les détails", method: "post", action: "https://a.test/x", submits: false)
        XCTAssertEqual(SafetyGuard.structuralReason(of: plainInPost, pageURL: "https://a.test/"), .postForm)
        let plainInGet = control("Filtre", method: "get", action: "https://a.test/x", submits: false)
        XCTAssertNil(SafetyGuard.structuralReason(of: plainInGet, pageURL: "https://a.test/"))
        let dialog = control("Fermer la boîte", method: "dialog", action: "https://a.test/", submits: true)
        XCTAssertNil(SafetyGuard.structuralReason(of: dialog, pageURL: "https://a.test/"))
        let noForm = control("Sans formulaire", method: nil, action: nil, submits: false)
        XCTAssertNil(SafetyGuard.structuralReason(of: noForm, pageURL: "https://a.test/"))
    }

    /// ITER-076 2.2 (S2): a select's chosen option is what the action does, so
    /// the lexicon reads it. A grant word in an option asks for a Yes rather
    /// than handing the errand over: "Grant" in a funding filter is a
    /// category. Typed text is not read: it is the user's own words, and a
    /// check on it would ask about every message.
    func testASelectsOptionIsReadByTheLexicon() {
        func pick(_ option: String, _ operation: AgentOperation = .select) -> AgentAction {
            AgentAction(operation: operation, target: element(role: "combobox", name: "Action"), destination: nil,
                        payload: option, isPlannedSearch: false)
        }
        XCTAssertTrue(SafetyGuard.lexiconRequiresConfirmation(pick("Delete account")))
        XCTAssertTrue(SafetyGuard.lexiconRequiresConfirmation(pick("Allow access")))
        XCTAssertTrue(SafetyGuard.lexiconRequiresConfirmation(pick("Grant")))
        XCTAssertFalse(SafetyGuard.isGrant(pick("Grant")), "an option never hands the errand over")
        XCTAssertFalse(SafetyGuard.isGrant(pick("Allow access")))
        XCTAssertFalse(SafetyGuard.lexiconRequiresConfirmation(pick("Blue")))
        XCTAssertFalse(SafetyGuard.lexiconRequiresConfirmation(pick("Delete everything", .type)))
    }

    private func select(method: String?, submitLabel: String?) -> AgentAction {
        let target = ObservedElement(index: 0, role: "combobox", name: "Sichtbarkeit", text: "", href: nil,
                                     inputType: nil, heading: "Section", region: .main, inViewport: true,
                                     context: nil, formAction: "https://a.test/settings", formMethod: method,
                                     formSubmitLabel: submitLabel, options: nil, checked: nil,
                                     submits: false)
        return AgentAction(operation: .select, target: target, destination: nil, payload: "Public",
                           isPlannedSearch: false)
    }

    /// ITER-076 2.2: a select in a POST form with no submit button may send
    /// the form when it changes, in any language, so it needs a Yes. One in a
    /// GET form, or in none, does not.
    func testASelectInAPostFormWithNoSubmitButtonNeedsAYes() {
        let page = "https://a.test/"
        XCTAssertEqual(SafetyGuard.structuralReason(of: select(method: "post", submitLabel: nil), pageURL: page),
                       .postForm)
        XCTAssertNil(SafetyGuard.structuralReason(of: select(method: "get", submitLabel: nil), pageURL: page))
        XCTAssertNil(SafetyGuard.structuralReason(of: select(method: nil, submitLabel: nil), pageURL: page))
    }

    /// ITER-076 I-10 (critic 27): a submit button says nothing about what a
    /// select's change does — an AutoPostBack select posts its form as it
    /// changes. Whether it does is not known, and not known counts as sending:
    /// a select in a POST form needs a Yes whatever buttons the form has.
    func testASelectInAPostFormNeedsAYesEvenWhenTheFormHasASubmitButton() {
        let page = "https://a.test/"
        XCTAssertEqual(SafetyGuard.structuralReason(of: select(method: "post", submitLabel: "Speichern"), pageURL: page),
                       .postForm)
        XCTAssertFalse(SafetyGuard.commits(select(method: "post", submitLabel: "Speichern")),
                       "choosing in a form sent by its own button changes a field (N3-P2-3)")
        XCTAssertTrue(SafetyGuard.commits(select(method: "post", submitLabel: nil)), "one with none sends it")
    }

    /// An OAuth address is the user's part whatever the words around it.
    func testAnOAuthAddressIsTheUsersInAnyLanguage() {
        func link(_ name: String, _ href: String) -> AgentAction {
            AgentAction(operation: .click, target: element(role: "link", name: name, href: href), destination: href,
                        payload: nil, isPlannedSearch: false)
        }
        XCTAssertTrue(SafetyGuard.isGrant(link("Continuer avec un compte",
            "https://accounts.test/o/oauth2/auth?client_id=abc&redirect_uri=https%3A%2F%2Fa.test%2Fcb&response_type=code")))
        XCTAssertTrue(SafetyGuard.isGrant(link("Weiter", "https://id.test/login?client_id=abc&redirect_uri=https%3A%2F%2Fa.test")))
        XCTAssertFalse(SafetyGuard.isGrant(link("Voir les prix", "https://a.test/prix?ref=home&client=web")))
        // A wrapped link, a pushed request, and a query no parser accepts are still read.
        XCTAssertTrue(SafetyGuard.hasOAuthMarkers(
            "https://a.test/go?to=https%3A%2F%2Fid.test%2Fo%2Foauth2%2Fv2%2Fauth%3Fclient_id%3Dabc%26redirect_uri%3Dx"))
        XCTAssertTrue(SafetyGuard.hasOAuthMarkers("https://id.test/authorize?client_id=abc&request_uri=urn:x"))
        XCTAssertTrue(SafetyGuard.hasOAuthMarkers("https://id.test/auth?client_id=a|b&response_type=code&x={y}"))
        XCTAssertFalse(SafetyGuard.hasOAuthMarkers("https://a.test/docs/client_id"))
        // A malformed escape elsewhere, and a link wrapped twice, still show the request.
        XCTAssertTrue(SafetyGuard.hasOAuthMarkers(
            "https://a.test/go?to=https%3A%2F%2Fid.test%2Fauth%3Fclient_id%3Dabc%26redirect_uri%3Dx&promo=50%off"))
        XCTAssertTrue(SafetyGuard.hasOAuthMarkers(
            "https://a.test/go?to=https%253A%252F%252Fid.test%252Fauth%253Fclient_id%253Dabc%2526redirect_uri%253Dx"))
    }

    /// A form whose fields carry an OAuth request is a grant whatever its
    /// button says.
    func testAFormCarryingAnOAuthRequestIsAGrant() {
        let target = ObservedElement(index: 0, role: "button", name: "Autoriser l'accès", text: "Autoriser l'accès",
                                     href: nil, inputType: nil, heading: nil, region: .main, inViewport: true,
                                     context: nil, formAction: "https://id.test/decision", formMethod: "post",
                                     formSubmitLabel: "Autoriser l'accès", options: nil, checked: nil,
                                     submits: true, formGrants: true)
        XCTAssertTrue(SafetyGuard.isGrant(AgentAction(operation: .click, target: target, destination: nil,
                                                      payload: nil, isPlannedSearch: false)))
    }

    /// ITER-076 2.1 (owner, 2026-09-26): the agent's code holds no Russian,
    /// written out or escaped, in any file under the folder.
    func testTheAgentCodeHoldsNoCyrillic() throws {
        let folder = repoRoot.appendingPathComponent("Services/Agent")
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath: folder.path))
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        let escaped = try NSRegularExpression(pattern: #"\\u\{?0*(4[0-9A-Fa-f]{2}|50[0-9A-Fa-f]|51[0-9A-Fa-f]|52[0-9A-Fa-f])\b"#)
        // The pattern itself catches both escape forms, so a broken pattern cannot pass quietly.
        for sample in [#"let a = "\u{0443}""#, #"const a = '\u0443';"#] {
            XCTAssertNotNil(escaped.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)), sample)
        }
        for file in files {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) }, "\(file) holds Cyrillic")
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(escaped.firstMatch(in: text, range: range), "\(file) holds an escaped Cyrillic letter")
        }
    }

    /// A cookie word exempts only a label that is itself about cookies; an
    /// address that grants is a grant whatever its query says (review round 12).
    func testACookieWordInAnAddressExemptsNothing() {
        func click(_ name: String, href: String) -> AgentAction {
            AgentAction(operation: .click, target: element(name: name, href: href), destination: nil, payload: nil,
                        isPlannedSearch: false)
        }
        XCTAssertTrue(SafetyGuard.isGrant(click("Allow access", href: "https://id.test/oauth/authorize?cookie=1")))
        XCTAssertTrue(SafetyGuard.isGrant(click("Continue", href: "https://id.test/oauth/authorize?cookie=1")))
        XCTAssertFalse(SafetyGuard.isGrant(click("Allow all cookies", href: "https://a.test/settings")))
    }

    /// A label is cookie consent only when it is about nothing but cookies:
    /// one that also grants access is a grant (review round 13).
    func testALabelThatGrantsMoreThanCookiesIsAGrant() {
        func click(_ name: String) -> AgentAction {
            AgentAction(operation: .click, target: element(name: name), destination: nil, payload: nil,
                        isPlannedSearch: false)
        }
        XCTAssertTrue(SafetyGuard.isGrant(click("Allow access to your account and cookies")))
        XCTAssertFalse(SafetyGuard.isGrant(click("Allow necessary cookies only")))
        XCTAssertFalse(SafetyGuard.isGrant(click("Allow all cookies")))
    }

    func testNegationsAndScopesAreRead() {
        XCTAssertEqual(CookieBanner.classify("I do not accept"), .rejectAll)
        XCTAssertEqual(CookieBanner.classify("Don't allow"), .rejectAll)
        XCTAssertEqual(CookieBanner.classify("Accept non-essential"), .accept)
        XCTAssertEqual(CookieBanner.classify("Allow optional cookies"), .accept)
        XCTAssertEqual(CookieBanner.classify("Essential cookies only"), .necessaryOnly)
        XCTAssertEqual(CookieBanner.choice(buttonLabels: ["Accept non-essential", "Reject"], blocksPage: true)?.choice,
                       .rejectAll)
    }

    func testTheLeastPermissiveOptionWins() {
        let labels = ["Accept all", "Necessary only", "Reject all", "Close"]
        XCTAssertEqual(CookieBanner.choice(buttonLabels: labels, blocksPage: true)?.choice, .rejectAll)
        XCTAssertEqual(CookieBanner.choice(buttonLabels: labels, blocksPage: true)?.index, 2)
        XCTAssertEqual(CookieBanner.choice(buttonLabels: ["Accept all", "Allow necessary only"], blocksPage: true)?.choice,
                       .necessaryOnly)
        XCTAssertEqual(CookieBanner.choice(buttonLabels: ["Accept all", "×"], blocksPage: true)?.choice, .close)
    }

    /// Accept is the last resort, and only when the banner is in the way.
    func testAcceptOnlyWhenTheBannerBlocksThePage() {
        XCTAssertEqual(CookieBanner.choice(buttonLabels: ["Accept all cookies"], blocksPage: true)?.choice, .accept)
        XCTAssertNil(CookieBanner.choice(buttonLabels: ["Accept all cookies"], blocksPage: false))
        XCTAssertNil(CookieBanner.choice(buttonLabels: ["Manage preferences"], blocksPage: true))
    }

    // MARK: - A page's own dialog (review of I-09, F4)

    /// A dialog's own words: a grant by its grant words, cookies alone being
    /// no grant; anything else, nothing — a payment is a page that asks card
    /// details (owner decision of 2026-10-19), which no dialog's words are:
    /// an amount or a payment word in them names no user's part.
    func testWhatADialogsOwnWordsAskFor() {
        for message in ["Pay $49.00 now?", "Your card ending 4242 will be charged EUR 99.00. Continue?",
                        "Complete your purchase?", "Place order?", "Es werden 12,50 € abgebucht.", "Total: 1 200 JPY"] {
            XCTAssertNil(SafetyGuard.dialogAsks(message), message)
        }
        for message in ["Allow Acme to access your account?", "Authorize Acme?", "Grant access to your files?"] {
            XCTAssertEqual(SafetyGuard.dialogAsks(message), .grant, message)
        }
        for message in ["Delete this draft?", "Remove the widget?", "Allow all cookies?", "You have 3 new messages",
                        "Leave site? Changes you made may not be saved.", ""] {
            XCTAssertNil(SafetyGuard.dialogAsks(message), message)
        }
    }

    /// Owner decision of 2026-10-19: a payment is a page that asks card
    /// details — `PageFlags.paymentForm` — and nothing else: not the words of
    /// a control ("Pay now", "Place order", "Buy"), not an amount beside it.
    /// Such an act is asked about as any send. On a page that takes a payment
    /// an irreversible act is the user's part; a reversible one is not.
    func testAPaymentIsAPageThatAsksCardDetails() {
        func click(_ name: String, amount: Bool = false) -> AgentAction {
            var target = element(name: name)
            target.showsAmount = amount
            return AgentAction(operation: .click, target: target, destination: nil, payload: nil, isPlannedSearch: false)
        }
        let cards = PageFlags(loginForm: false, paymentForm: true)
        for label in ["Pay now", "Place order", "Submit order", "Buy", "Checkout", "Confirm payment", "Charge the card"] {
            XCTAssertFalse(SafetyGuard.pays(click(label), risk: .irreversible, on: .none), label)
            XCTAssertFalse(SafetyGuard.pays(click(label, amount: true), risk: .irreversible, on: .none), "\(label) beside a total")
            XCTAssertTrue(SafetyGuard.pays(click(label), risk: .irreversible, on: cards), "\(label) where a card is asked")
        }
        XCTAssertTrue(SafetyGuard.pays(click("Continue"), risk: .irreversible, on: cards), "any irreversible act there")
        XCTAssertFalse(SafetyGuard.pays(click("Continue"), risk: .otherReversible, on: cards), "a reversible one is not")
        XCTAssertFalse(SafetyGuard.pays(click("Pay now"), risk: .alwaysReversible, on: cards))
    }

    /// The words of a control that name a payment are read as one list — a
    /// charge or a debit too, and the forms of their stems that name a
    /// payment ("billed", "purchasing") — with compatibility forms and hidden
    /// marks read as what they stand for; a word that only begins like one
    /// ("chargers", "billboard", "billion"), or a form as often about
    /// something else ("charging", "billing"), is none (Codex review 1 of
    /// I-09, P1-3; Claude review of I-09, kept 1). Such a control is asked
    /// about whatever Jev says of its risk, and is no search of the agent's.
    func testTheWordsOfAControlThatNameAPaymentAreReadAndAskedAbout() {
        func click(_ name: String) -> AgentAction {
            AgentAction(operation: .click, target: element(name: name), destination: nil, payload: nil,
                        isPlannedSearch: false)
        }
        for label in ["Charge the card", "Charges", "Debit now", "Debited", "Confirm payment", "Mark as paid",
                      "Billed monthly", "Purchasing", "Place order", "Submit order", "C\u{200B}harge now", "\u{FF23}harge now"] {
            XCTAssertTrue(SafetyGuard.namesPaymentByItsWords(click(label)), label)
            XCTAssertEqual(AgentPolicy.risk(of: click(label), irreversibleNoul: 0.05), .irreversible, "\(label): asked")
        }
        for label in ["Phone chargers", "Charging stations", "Billboard charts", "A billion stars", "Bill Evans",
                      "Billing country", "Bills passed this week", "Debitor list"] {
            XCTAssertFalse(SafetyGuard.namesPaymentByItsWords(click(label)), label)
        }
    }

    /// A page's own dialog asks for a grant in other words too: to give
    /// someone access, to share something with someone (Claude review of
    /// I-09, kept 1). A control's label that says so is asked about, and
    /// handed over on Jev's grant answer, as before (review of A3, round 1).
    func testGivingAccessOrSharingWithSomeoneInADialogIsAGrant() {
        for message in ["Give Acme access to your contacts?", "Share your location with Acme?",
                        "Give\u{200B} Acme access?"] {
            XCTAssertEqual(SafetyGuard.dialogAsks(message), .grant, message)
        }
        // "Access" is a grant word of its own in a dialog now (decision 8 of
        // review round 4): give with no grant word after it stays nothing.
        XCTAssertNil(SafetyGuard.dialogAsks("Give it another try?"), "give, then no access")
        XCTAssertNil(SafetyGuard.dialogAsks("Share this draft?"), "sharing with no one named")
        let share = AgentAction(operation: .click, target: element(name: "Share with someone"), destination: nil,
                                payload: nil, isPlannedSearch: false)
        XCTAssertFalse(SafetyGuard.isGrant(share), "a label: asked about, Jev's grant answer decides")
    }

    /// A page's own dialog under a Yes (Codex review 1 of I-09, P1-3): an
    /// alert is closed; a prompt is Cancel; "Leave the page?" is Leave only
    /// under the step's Yes; a confirm is OK only under the step's Yes, when
    /// it names no grant or amount and is bound to the approved act
    /// — a content word it shares with that control's words, or nothing but
    /// a bare confirmation. A word every sentence has binds nothing.
    func testADialogIsAcceptedOnlyWhenBoundToTheApprovedAct() {
        func act(_ words: String...) -> ApprovedAct { ApprovedAct(words: words) }
        let cases: [(PageDialog, String, ApprovedAct?, Bool, ErrandHandover.Kind?)] = [
            (.alert, "Saved.", nil, true, nil),
            (.confirm, "Charge the saved card?", act("Renew"), false, nil),
            (.confirm, "Send the report to all members?", act("Archive"), false, nil),
            (.confirm, "Send the report to all members?", act("Archive all of the posts"), false, nil),
            (.confirm, "Send the report to all members?", act("Send the report"), true, nil),
            (.confirm, "Delete this draft?", act("Delete"), true, nil),
            // Another act's verb sharing an object word binds nothing (Claude
            // review c8 of I-09, #11; decision 11 of review round 3).
            (.confirm, "Delete this draft?", act("Clear", "Clear the draft"), false, nil),
            (.confirm, "Are you sure?", act("Remove"), true, nil),
            (.confirm, "Do you really want to continue? This cannot be undone.", act("Remove"), true, nil),
            (.confirm, "Wirklich l\u{00F6}schen?", act("L\u{00F6}schen"), true, nil),
            (.confirm, "WIRKLICH L\u{00D6}SCHEN?", act("l\u{00F6}schen"), true, nil),
            (.confirm, "Delete this draft?", nil, false, nil),
            (.confirm, "", act("Delete"), false, nil),
            (.confirm, "Delete? Pay $5 for the restore", act("Delete"), false, nil),
            (.confirm, "Renew for 49.99 dollars?", act("Renew"), false, nil),
            (.prompt, "A new name?", act("Rename", "A new name"), false, nil),
            (.beforeunload, "", act(), true, nil),
            (.beforeunload, "", nil, false, nil),
        ]
        for (kind, message, approved, accept, named) in cases {
            let answer = SafetyGuard.answer(kind, saying: message, under: approved)
            XCTAssertEqual(answer.accept, accept, "\(kind) \(message) under \(approved?.words ?? [])")
            XCTAssertEqual(answer.named, named, "\(kind) \(message)")
        }
    }

    /// A control a click only sets — an option, a box — still commits when
    /// its click may send a POST form that has no submit button, its own or
    /// its dropdown's: that form is sent by its change, as a select's is. On
    /// a page that asks card details that change is a payment; an amount
    /// beside it is none. A form with a submit button is sent by that button
    /// only (Claude review of I-09, kept 14).
    func testAClickThatMaySendAPostFormWithNoSubmitButtonCommits() {
        func option(listForm: ObservedElement.ListForm?) -> AgentAction {
            var target = element(role: "option", name: "Pro")
            target.listForm = listForm
            target.showsAmount = true
            return AgentAction(operation: .click, target: target, destination: nil, payload: nil, isPlannedSearch: false)
        }
        let sendsOnChange = ObservedElement.ListForm(action: "https://a.test/billing/plan", method: "post",
                                                     submitLabel: nil, grants: false)
        let sentByItsButton = ObservedElement.ListForm(action: "https://a.test/billing/plan", method: "post",
                                                       submitLabel: "Save", grants: false)
        let cards = PageFlags(loginForm: false, paymentForm: true)
        XCTAssertTrue(SafetyGuard.commits(option(listForm: sendsOnChange)))
        XCTAssertFalse(SafetyGuard.pays(option(listForm: sendsOnChange), risk: .irreversible, on: .none),
                       "a price beside it is no payment")
        XCTAssertTrue(SafetyGuard.pays(option(listForm: sendsOnChange), risk: .irreversible, on: cards))
        XCTAssertFalse(SafetyGuard.commits(option(listForm: sentByItsButton)))
        XCTAssertFalse(SafetyGuard.pays(option(listForm: sentByItsButton), risk: .irreversible, on: .none))
        // An option of no form at all: its own change is the send (Claude
        // review c8 of I-09, #23).
        XCTAssertTrue(SafetyGuard.commits(option(listForm: nil)))
        let box = { (label: String?) in
            AgentAction(operation: .click, target: self.element(role: "checkbox", name: "Yearly", formAction: "https://a.test/plan",
                                                                formMethod: "post", formSubmitLabel: label),
                        destination: nil, payload: nil, isPlannedSearch: false)
        }
        XCTAssertTrue(SafetyGuard.commits(box(nil)))
        XCTAssertFalse(SafetyGuard.commits(box("Save")))
    }

    /// A currency's name beside a number is an amount too, whole word, any
    /// case, compatibility forms and hidden marks read as what they stand
    /// for; a name that is also an everyday word ("won", "rand", "real",
    /// "pound") only after its number (Codex review 1 of I-09, P1-3).
    func testACurrencysNameBesideANumberIsAnAmount() {
        for text in ["Renew for 49.99 dollars?", "Dollars 49", "Total: 120 euros", "120 EUROS", "\u{FF14}\u{FF19} dollars",
                     "49 dol\u{200B}lars", "1 200 rand", "500 won", "3 reais", "50 pounds sterling", "\u{00A3}50",
                     "2,000 yen", "Yuan 300", "99 rupees", "15 zlotys", "1000 kronor", "40 shekels", "100 lei"] {
            XCTAssertTrue(SafetyGuard.showsAmount(in: text), text)
        }
        for text in ["You won 3 games", "Rand 2 is the second road", "Real 5 stars", "Pound 3 nails in",
                     "dollarsign 5", "5 eurostars", "The euro zone"] {
            XCTAssertFalse(SafetyGuard.showsAmount(in: text), text)
        }
    }

    /// A money amount, as the observer reads one on a page: a currency sign,
    /// or an ISO 4217 code standing as a word, beside a number — compatibility
    /// forms and hidden marks read as what they stand for.
    func testAMoneyAmountIsASignOrACodeBesideANumber() {
        for text in ["$5", "5 €", "EUR 99.00", "99.00EUR", "¥1000", "INR 500", "ILS 20", "\u{FF35}\u{FF33}\u{FF24} 5",
                     "EUR\u{200B} 5"] {
            XCTAssertTrue(SafetyGuard.showsAmount(in: text), text)
        }
        // "EURO 5" is a currency's name beside a number (Codex review 1 of
        // I-09, P1-3); a word that only begins like one is none.
        for text in ["EUROPE 5", "MUSD5", "5 apples", "Page 2 of 5", "USD", "$"] {
            XCTAssertFalse(SafetyGuard.showsAmount(in: text), text)
        }
    }

    // MARK: - Review round 3 of I-09, part C (Codex review 2; Claude review c8)

    /// A page's own dialog names no payment by its words (owner decision of
    /// 2026-10-19: a payment is a page that asks card details, which a dialog
    /// cannot): a charge, a bill, a purchase in its words is Cancel by the
    /// rules every confirm has — bound to the approved act's own word or
    /// not — and never the user's part by itself.
    func testADialogsWordsNameNoPayment() {
        for message in ["Renew by charging the saved card?", "Renew and start billing the saved card?",
                        "Paying now. Continue?", "Buying it now?", "Bills go to your saved card. Continue?",
                        "Pay $49.00 now?", "Place order?", "Total: 1 200 JPY", "Delete this draft?", "Leave the page?"] {
            XCTAssertNil(SafetyGuard.dialogAsks(message), message)
        }
        XCTAssertFalse(SafetyGuard.answer(.confirm, saying: "Charge the saved card?", under: nil).accept, "no Yes")
        let renew = ApprovedAct(words: ["Renew"])
        XCTAssertTrue(SafetyGuard.answer(.confirm, saying: "Renew the plan?", under: renew).accept, "bound to the act")
        let charged = SafetyGuard.answer(.confirm, saying: "Charge the saved card?", under: renew)
        XCTAssertFalse(charged.accept, "about another act")
        XCTAssertNil(charged.named)
    }

    /// A page's own dialog asks for a grant in any form of its words —
    /// allowing, granted, authorizing — and by asking for access to what is
    /// the user's: "permission to access", "access to your", "access your";
    /// cookies alone are still no grant (Claude review c8 of I-09, #10).
    func testADialogAsksForAGrantInAnyFormOfItsWords() {
        for message in ["Acme is requesting permission to access your account. Continue?",
                        "Acme will get access to your files. Continue?", "Acme wants to access your contacts?",
                        "Allowing Acme to post for you?", "Acme is granted your calendar. OK?", "Authorizing Acme?"] {
            XCTAssertEqual(SafetyGuard.dialogAsks(message), .grant, message)
        }
        for message in ["Allow all cookies?", "Delete this draft?"] {
            XCTAssertNil(SafetyGuard.dialogAsks(message), message)
        }
    }

    /// A dialog under a Yes that shows a number is OK'd only when the
    /// approved control shows that number too — in any language, digits of
    /// any script read as their values: a price in a currency written in
    /// letters, which no amount rule reads, is never OK'd past the control
    /// that did not show it (Claude review c8 of I-09, #9).
    func testADialogThatShowsANumberIsOKOnlyWhenTheApprovedControlShowsIt() {
        func act(_ words: String...) -> ApprovedAct { ApprovedAct(words: words) }
        let renew = "\u{041F}\u{0440}\u{043E}\u{0434}\u{043B}\u{0438}\u{0442}\u{044C}"
        let forRubles = " \u{043F}\u{043E}\u{0434}\u{043F}\u{0438}\u{0441}\u{043A}\u{0443} \u{0437}\u{0430} 299 "
            + "\u{0440}\u{0443}\u{0431}.?"
        let cases: [(String, ApprovedAct, Bool)] = [
            (renew + forRubles, act(renew), false),
            ("F\u{00F6}rnya prenumerationen f\u{00F6}r 99 kr?", act("F\u{00F6}rnya"), false),
            ("Renew for 49 usd?", act("Renew"), false),
            ("Delete 3 items?", act("Delete"), false),
            ("Delete 3 items?", act("Delete 30 items"), false),
            ("Delete 3 items?", act("Delete 3 items"), true),
            ("Delete \u{0663} items?", act("Delete 3 items"), true),
            ("Delete this draft?", act("Delete"), true),
        ]
        for (message, approved, accept) in cases {
            XCTAssertEqual(SafetyGuard.answer(.confirm, saying: message, under: approved).accept, accept, message)
            XCTAssertNil(SafetyGuard.answer(.confirm, saying: message, under: approved).named, message)
        }
        XCTAssertFalse(SafetyGuard.answer(.beforeunload, saying: "You have 3 unsaved changes", under: act()).accept)
        XCTAssertTrue(SafetyGuard.answer(.beforeunload, saying: "", under: act()).accept)
    }

    /// A confirm is bound to the approved act only by the act's own word
    /// (Claude review c8 of I-09, #11): when the control's words hold an
    /// action word of the lexicon, the confirm must hold that word; a confirm
    /// that names another act by one — not as a thing after "this", "the",
    /// "your" — is not bound, whatever object word it shares.
    func testABindingNeedsTheActsOwnWord() {
        func act(_ words: String...) -> ApprovedAct { ApprovedAct(words: words) }
        let cases: [(String, ApprovedAct, Bool)] = [
            ("Send this item to all subscribers?", act("Remove item"), false),
            ("Send the report to all members?", act("Archive report"), false),
            ("Send the changes to all attendees?", act("Save changes"), false),
            ("Publish the post now?", act("Delete post"), false),
            ("Is this item yours?", act("Remove item"), false),
            ("Delete this draft?", act("Delete"), true),
            ("Delete this post?", act("Delete"), true),
            ("Remove this order from the list?", act("Remove"), true),
            ("Archive this report?", act("Archive report"), true),
            ("Please confirm.", act("Delete"), true),
        ]
        for (message, approved, accept) in cases {
            XCTAssertEqual(SafetyGuard.answer(.confirm, saying: message, under: approved).accept, accept,
                           "\(message) under \(approved.words)")
        }
    }

    /// The approved act is the act itself (Claude review c8 of I-09, #12):
    /// its form's submit label is its own only when it sends that form — a
    /// control that does not, or a field typed into, carries its own words
    /// alone, never the typed text — and it runs in its control's document,
    /// an open in the page.
    func testTheApprovedActCarriesItsFormsSubmitLabelOnlyWhenItSendsTheForm() {
        let click = { (target: ObservedElement) in
            AgentAction(operation: .click, target: target, destination: nil, payload: nil, isPlannedSearch: false)
        }
        var archive = element(name: "Archive", formAction: "https://a.test/report", formMethod: "post",
                              formSubmitLabel: "Send report")
        archive.submits = false
        var send = element(name: "Send report", formAction: "https://a.test/report", formMethod: "post",
                           formSubmitLabel: "Send report")
        send.submits = true
        XCTAssertEqual(ApprovedAct(click(archive)).words, ["Archive", "Archive"])
        XCTAssertEqual(ApprovedAct(click(send)).words, ["Send report", "Send report", "Send report"])
        let field = element(role: "textbox", name: "Message", formAction: "https://a.test/send", formMethod: "post",
                            formSubmitLabel: "Send")
        XCTAssertEqual(ApprovedAct(AgentAction(operation: .type, target: field, destination: nil, payload: "Hello",
                                               isPlannedSearch: false)).words, ["Message", "Message"])
        XCTAssertFalse(SafetyGuard.answer(.confirm, saying: "Send the report to all members?",
                                          under: ApprovedAct(click(archive))).accept)
        var inFrame = archive
        inFrame.frame = "F1"
        XCTAssertEqual(ApprovedAct(click(inFrame)).frame, "F1")
        XCTAssertNil(ApprovedAct(click(archive)).frame)
        XCTAssertNil(ApprovedAct(AgentAction(operation: .open, target: inFrame, destination: "https://a.test/x",
                                             payload: nil, isPlannedSearch: false)).frame, "an open leaves the page")
    }

    /// A box, a switch or an option of no form at all, whose own change is
    /// the send, commits: on a page that asks card details its irreversible
    /// click is a payment, a price around it none. One the step takes as
    /// reversible pays nothing, and one in a form sent by its own button
    /// only edits the form (Claude review c8 of I-09, #23).
    func testAControlOfNoFormWhoseOwnChangeIsTheSendCommits() {
        let click = { (target: ObservedElement) in
            AgentAction(operation: .click, target: target, destination: nil, payload: nil, isPlannedSearch: false)
        }
        for role in ["radio", "switch", "checkbox", "option", "menuitemradio"] {
            var target = element(role: role, name: "Yearly")
            target.showsAmount = true
            XCTAssertTrue(SafetyGuard.commits(click(target)), role)
            XCTAssertFalse(SafetyGuard.pays(click(target), risk: .irreversible, on: .none), "\(role): a price is no payment")
            XCTAssertTrue(SafetyGuard.pays(click(target), risk: .irreversible, on: PageFlags(loginForm: false, paymentForm: true)),
                          role)
            XCTAssertFalse(SafetyGuard.pays(click(target), risk: .otherReversible, on: PageFlags(loginForm: false, paymentForm: true)),
                           role)
        }
        let boxInAForm = element(role: "checkbox", name: "Yearly", formAction: "https://a.test/plan", formMethod: "post",
                                 formSubmitLabel: "Save")
        XCTAssertFalse(SafetyGuard.commits(click(boxInAForm)))
        // A GET form that no submit button sends is sent by its change too
        // (decision 11 of review round 4; Claude review c9, #14): a filter box
        // there commits — a re-check at the act — and pays only when the step
        // is irreversible beside a total. One its own button sends does not.
        var boxInASearch = element(role: "checkbox", name: "In stock", formAction: "https://a.test/s", formMethod: "get")
        XCTAssertTrue(SafetyGuard.commits(click(boxInASearch)), "no submit button sends a GET form's change either")
        boxInASearch.showsAmount = true
        XCTAssertFalse(SafetyGuard.pays(click(boxInASearch), risk: .otherReversible, on: .none))
        let boxInASearchWithItsButton = element(role: "checkbox", name: "In stock", formAction: "https://a.test/s",
                                                formMethod: "get", formSubmitLabel: "Search")
        XCTAssertFalse(SafetyGuard.commits(click(boxInASearchWithItsButton)), "a GET form sent by its button")
    }

    // MARK: - Review round 4 of I-09, part C (Codex review 3; Claude review c9)

    /// A page's own dialog names a grant inside a word and in every form
    /// (decision 8 of review round 4; Codex review 3 of I-09, P1-3; Claude
    /// review c9, #12): a grant word anywhere in a word — preauthorize,
    /// reauthorize — the grant words being access, permission, authoriz,
    /// authoris, grant and allow; and a form of give or share with access,
    /// permission or with. A payment word inside a word — prepaid, autopay,
    /// repay — names nothing (owner decision of 2026-10-19).
    func testADialogsGrantWordsAreReadInsideWordsAndInEveryForm() {
        for message in ["Renew the prepaid plan?", "Turn on autopay?", "Repay the balance now?",
                        "Renew using your prepaid credit?", "Unpaid invoices remain. Continue?",
                        "Recharge your phone's battery first?"] {
            XCTAssertNil(SafetyGuard.dialogAsks(message), message)
        }
        for message in ["Renew by giving Acme access?", "Renew and keep sharing your data with Acme?",
                        "Preauthorize the renewal?", "Reauthorize Acme?", "Give Acme permission to post?",
                        "Acme requests permission to post on your behalf. Continue?", "Acme gave your team access. OK?",
                        "Your files are shared with Acme. Continue?", "Renew? Acme gives your team permission.",
                        "Access denied. Try again?", "Allowing Acme to post for you?"] {
            XCTAssertEqual(SafetyGuard.dialogAsks(message), .grant, message)
        }
        for message in ["Delete this draft?", "Allow all cookies?", "Share this draft?", "Give it another try?",
                        "Leave the page?"] {
            XCTAssertNil(SafetyGuard.dialogAsks(message), message)
        }
        let renew = ApprovedAct(words: ["Renew"])
        for message in ["Renew by giving Acme access?", "Renew and keep sharing your data with Acme?",
                        "Preauthorize the renewal?", "Give Acme permission to post?"] {
            let answer = SafetyGuard.answer(.confirm, saying: message, under: renew)
            XCTAssertFalse(answer.accept, message)
            XCTAssertNotNil(answer.named, message)
        }
        // A payment word names no user's part: the confirm is read as any other — bound to the act's own word
        // it is OK, about another act it is Cancel.
        let prepaid = SafetyGuard.answer(.confirm, saying: "Renew the prepaid plan?", under: renew)
        XCTAssertTrue(prepaid.accept)
        XCTAssertNil(prepaid.named)
        let autopay = SafetyGuard.answer(.confirm, saying: "Turn on autopay?", under: renew)
        XCTAssertFalse(autopay.accept)
        XCTAssertNil(autopay.named)
        let post = ApprovedAct(words: ["Post"])
        XCTAssertEqual(SafetyGuard.answer(.confirm, saying: "Give Acme permission to post?", under: post).named, .grant)
        func click(_ name: String) -> AgentAction {
            AgentAction(operation: .click, target: element(name: name), destination: nil, payload: nil,
                        isPlannedSearch: false)
        }
        for label in ["Billing country", "Charging stations", "Allow all cookies"] {
            XCTAssertFalse(SafetyGuard.isGrant(click(label)), "a label keeps its exceptions: \(label)")
        }
    }

    /// A confirm is bound sentence by sentence, by the acts it names in an
    /// act's position (decision 9 of review round 4; Claude review c9, #11):
    /// the action words are the policy's whole lexicon — cancel, unsubscribe,
    /// approve, log out, sign out, reject, decline, archive among them — a
    /// word right after "this", "the" or "your" names a thing only within
    /// its sentence, and the act's own word binds only where it names an act.
    func testABindingIsReadSentenceBySentenceByTheActsItNames() {
        func act(_ words: String...) -> ApprovedAct { ApprovedAct(words: words) }
        let cases: [(String, ApprovedAct, Bool)] = [
            // (a) another act after a sentence's end
            ("Remove this? Send it to all subscribers?", act("Remove"), false),
            ("Remove this? Order a free replacement?", act("Remove"), false),
            // (b) another act of the lexicon's leaving or undoing words
            ("Delete this list and unsubscribe all contacts?", act("Delete"), false),
            ("Remove the item and cancel your subscription?", act("Remove item"), false),
            ("Delete the draft and log out?", act("Delete"), false),
            ("Delete this and archive the rest?", act("Delete"), false),
            ("Remove the member and reject all invites?", act("Remove member"), false),
            ("Delete this draft? Press Cancel to keep it.", act("Delete"), false),
            // (c) the act's own word as a thing binds nothing
            ("Your send limit is reached. Upgrade to Pro now?", act("Send"), false),
            ("The post limit is reached. Upgrade now?", act("Post"), false),
            // the approved control's own words are read by the same rule
            ("Post this?", act("Archive this post"), false),
            // still bound
            ("Delete this draft?", act("Delete"), true),
            ("Remove this? It cannot be undone.", act("Remove"), true),
            ("Remove this order from the list?", act("Remove"), true),
            ("Archive this report?", act("Archive report"), true),
            ("Cancel my subscription?", act("Cancel subscription"), true),
            ("Log out of all devices?", act("Log out"), true),
            ("Unsubscribe from all lists?", act("Unsubscribe"), true),
            ("Send the report to all members?", act("Send the report"), true),
            ("Are you sure? This cannot be undone.", act("Delete"), true),
        ]
        for (message, approved, accept) in cases {
            XCTAssertEqual(SafetyGuard.answer(.confirm, saying: message, under: approved).accept, accept,
                           "\(message) under \(approved.words)")
        }
    }

    /// A change that no submit button sends commits (decision 11 of review
    /// round 4; Claude review c9, #14): a control a click only sets, or a
    /// select, of no form, or whose form — its own, or its dropdown's — has
    /// no submit button, whatever the method. On a page that asks card
    /// details its irreversible change is a payment, a price around it none;
    /// one in a form sent by its own button only edits the form.
    func testAChangeThatNoSubmitButtonSendsCommits() {
        func act(_ operation: AgentOperation, _ target: ObservedElement) -> AgentAction {
            AgentAction(operation: operation, target: target, destination: nil,
                        payload: operation == .select ? "Yearly $99" : nil, isPlannedSearch: false)
        }
        func priced(_ target: ObservedElement) -> ObservedElement {
            var shown = target
            shown.showsAmount = true
            return shown
        }
        let radioInAPlainForm = priced(element(role: "radio", name: "Yearly", formAction: "https://a.test/plan",
                                               formMethod: "get"))
        let selectOfNoForm = priced(element(role: "combobox", name: "Plan"))
        let selectInAPlainForm = priced(element(role: "combobox", name: "Plan", formAction: "https://a.test/plan",
                                                formMethod: "get"))
        var optionOfAPlainList = priced(element(role: "option", name: "Yearly"))
        optionOfAPlainList.listForm = ObservedElement.ListForm(action: "https://a.test/plan", method: "get",
                                                               submitLabel: nil, grants: false)
        let cards = PageFlags(loginForm: false, paymentForm: true)
        for (operation, target) in [(AgentOperation.click, radioInAPlainForm), (.select, selectOfNoForm),
                                    (.select, selectInAPlainForm), (.click, optionOfAPlainList)] {
            XCTAssertTrue(SafetyGuard.commits(act(operation, target)), "\(operation) \(target.role)")
            XCTAssertFalse(SafetyGuard.pays(act(operation, target), risk: .irreversible, on: .none),
                           "\(operation) \(target.role): a price is no payment")
            XCTAssertTrue(SafetyGuard.pays(act(operation, target), risk: .irreversible, on: cards),
                          "\(operation) \(target.role)")
            XCTAssertFalse(SafetyGuard.pays(act(operation, target), risk: .otherReversible, on: cards),
                           "\(operation) \(target.role)")
        }
        let selectSentByItsButton = priced(element(role: "combobox", name: "Plan", formAction: "https://a.test/plan",
                                                   formMethod: "get", formSubmitLabel: "Save"))
        XCTAssertFalse(SafetyGuard.commits(act(.select, selectSentByItsButton)))
        XCTAssertFalse(SafetyGuard.pays(act(.select, selectSentByItsButton), risk: .irreversible, on: .none))
    }

    // MARK: - Confirmation (§7.1)

    private let asked = ContinuousClock.now

    private let tab = BrowserTab(windowID: "W1", tabID: "T1")
    private let page = "https://a.test/checkout"

    private func request(_ target: ObservedElement, payload: String? = nil) -> ConfirmationRequest {
        ConfirmationRequest(action: AgentAction(operation: .click, target: target, destination: nil,
                                                payload: payload, isPlannedSearch: false),
                            tab: tab, pageURL: page, askedAt: asked)
    }

    func testSilenceIsStillWaitingInsideTheWindow() {
        let pending = request(element(name: "Send"))
        XCTAssertEqual(pending.outcome(answer: nil, answeredAt: nil, now: asked.advanced(by: .seconds(119))), .waiting)
    }

    func testSilenceBecomesANoWhenTheWindowCloses() {
        let pending = request(element(name: "Send"))
        XCTAssertEqual(pending.outcome(answer: nil, answeredAt: nil, now: asked.advanced(by: .seconds(120))), .refused)
    }

    func testAYesInsideTheWindowApproves() {
        let pending = request(element(name: "Send"))
        XCTAssertEqual(pending.outcome(answer: .yes, answeredAt: asked.advanced(by: .seconds(30)),
                                       now: asked.advanced(by: .seconds(31))), .approved)
        XCTAssertEqual(pending.outcome(answer: .no, answeredAt: asked.advanced(by: .seconds(30)),
                                       now: asked.advanced(by: .seconds(31))), .refused)
    }

    func testALateYesDoesNotCount() {
        let pending = request(element(name: "Send"))
        XCTAssertEqual(pending.outcome(answer: .yes, answeredAt: asked.advanced(by: .seconds(121)),
                                       now: asked.advanced(by: .seconds(121))), .refused)
    }

    /// An answer stamped before the question, or after now, is not an
    /// answer to this question.
    func testAnAnswerOutsideTheRealWindowDoesNotCount() {
        let pending = request(element(name: "Send"))
        XCTAssertEqual(pending.outcome(answer: .yes, answeredAt: asked.advanced(by: .seconds(-5)),
                                       now: asked.advanced(by: .seconds(10))), .waiting)
        XCTAssertEqual(pending.outcome(answer: .yes, answeredAt: asked.advanced(by: .seconds(60)),
                                       now: asked.advanced(by: .seconds(30))), .waiting)
    }

    /// A Yes holds for that exact action, in that tab, on that page, with the
    /// same visible words — and nothing else.
    func testAYesIsBoundToTheExactActionTabPageAndWording() {
        let send = element(name: "Confirm", text: "Pay $10", formAction: "https://a.test/send", formMethod: "post",
                           formSubmitLabel: "Pay $10")
        let approved = request(send, payload: "Hello")
        func action(_ target: ObservedElement, payload: String? = "Hello") -> AgentAction {
            AgentAction(operation: .click, target: target, destination: nil, payload: payload, isPlannedSearch: false)
        }
        XCTAssertTrue(approved.stillHolds(for: action(send), tab: tab, pageURL: page))
        XCTAssertFalse(approved.stillHolds(for: action(send), tab: BrowserTab(windowID: "W1", tabID: "T2"),
                                           pageURL: page), "another tab")
        XCTAssertFalse(approved.stillHolds(for: action(send), tab: tab, pageURL: "https://a.test/other"),
                       "another page on the same site")
        XCTAssertFalse(approved.stillHolds(for: action(send, payload: "Goodbye"), tab: tab, pageURL: page),
                       "another text to type")
        let pricier = element(name: "Confirm", text: "Pay $100", formAction: "https://a.test/send",
                              formMethod: "post", formSubmitLabel: "Pay $100")
        XCTAssertFalse(approved.stillHolds(for: action(pricier), tab: tab, pageURL: page),
                       "the same button now says something else")
        let redirected = element(name: "Confirm", text: "Pay $10", formAction: "https://a.test/other",
                                 formMethod: "post", formSubmitLabel: "Pay $10")
        XCTAssertFalse(approved.stillHolds(for: action(redirected), tab: tab, pageURL: page),
                       "the form now sends somewhere else")
        XCTAssertFalse(approved.stillHolds(
            for: AgentAction(operation: .type, target: send, destination: nil, payload: "Hello", isPlannedSearch: false),
            tab: tab, pageURL: page), "another operation")
    }

    /// A Yes that no longer holds says what changed — by name, never by value (2026-10-21: on a blind task 19 of 21
    /// Yes answers lapsed with "the page changed" and nothing on record said what had).
    func testALapsedYesNamesWhatChanged() {
        let send = element(name: "Confirm", text: "Pay $10", formAction: "https://a.test/send", formMethod: "post",
                           formSubmitLabel: "Pay $10")
        let approved = request(send, payload: "Hello")
        func action(_ target: ObservedElement, _ operation: AgentOperation = .click,
                    payload: String? = "Hello") -> AgentAction {
            AgentAction(operation: operation, target: target, destination: nil, payload: payload, isPlannedSearch: false)
        }
        XCTAssertNil(approved.lapse(for: action(send), tab: tab, pageURL: page))
        XCTAssertEqual(approved.lapse(for: action(send), tab: BrowserTab(windowID: "W1", tabID: "T2"), pageURL: page),
                       "tab")
        XCTAssertEqual(approved.lapse(for: action(send), tab: tab, pageURL: "https://a.test/other"), "page address")
        XCTAssertEqual(approved.lapse(for: action(send, .type), tab: tab, pageURL: page), "operation")
        XCTAssertEqual(approved.lapse(for: action(send, payload: "Goodbye"), tab: tab, pageURL: page), "payload")
        let pricier = element(name: "Confirm", text: "Pay $100", formAction: "https://a.test/send", formMethod: "post",
                              formSubmitLabel: "Pay $100")
        XCTAssertEqual(approved.lapse(for: action(pricier), tab: tab, pageURL: page), "words")
        let redirected = element(name: "Confirm", text: "Pay $10", formAction: "https://a.test/other",
                                 formMethod: "post", formSubmitLabel: "Pay $10")
        XCTAssertEqual(approved.lapse(for: action(redirected), tab: tab, pageURL: page), "target")
        XCTAssertFalse(approved.lapse(for: action(pricier), tab: tab, pageURL: page)?.contains("$") ?? true,
                       "a name, never the page's words")
    }

    // MARK: - D4: a search the agent typed (ITER-076 brain; stage 3, strictly)

    private static let searchAddress = "https://search.test/find"

    /// The page's own GET search: one search field — after a hidden field —
    /// and its button.
    private func searchForm(method: String = "get", action: String = searchAddress, submitLabel: String? = "Search",
                            extra: [ObservedElement] = [], flags: PageFlags = .none, truncated: Bool = false,
                            page address: String = "https://search.test/",
                            field fieldChange: (inout ObservedElement) -> Void = { _ in },
                            button change: (inout ObservedElement) -> Void = { _ in })
        -> (page: ObservedPage, field: ObservedElement, button: ObservedElement) {
        var field = ObservedElement(index: 0, role: "searchbox", name: "Search", text: "", href: nil, inputType: "search",
                                    heading: nil, region: .main, inViewport: true, context: nil, formAction: action,
                                    formMethod: method, formSubmitLabel: submitLabel, options: nil, checked: nil)
        field.formEntries = [.init(name: "src", value: "hp"), .init(name: "q", value: nil)]
        fieldChange(&field)
        var button = ObservedElement(index: 1, role: "button", name: submitLabel ?? "Search", text: submitLabel ?? "",
                                     href: nil, inputType: nil, heading: nil, region: .main, inViewport: true,
                                     context: nil, formAction: action, formMethod: method, formSubmitLabel: submitLabel,
                                     options: nil, checked: nil, submits: true)
        change(&button)
        let page = ObservedPage(url: address, title: "Search", truncated: truncated, flags: flags,
                                elements: (submitLabel == nil ? [field] : [field, button]) + extra, address: address)
        return (page, field, button)
    }

    private func click(_ button: ObservedElement) -> AgentAction {
        AgentAction(operation: .click, target: button, destination: nil, payload: nil, isPlannedSearch: false)
    }

    /// D4: the button of a GET form of the page's own site, whose one search
    /// field the agent typed in this sub-goal, sends it — by the address the
    /// form builds, as a browser writes its query: the hidden fields as they
    /// are, in the form's order, the typed text in the field's place.
    func testASearchTheAgentTypedGoesToTheAddressItsFormBuilds() {
        let (page, field, button) = searchForm()
        XCTAssertEqual(SafetyGuard.searchAddress(for: click(button), on: page,
                                                 typed: [field.fingerprint: "best jokes & puns/ü"])?.absoluteString,
                       "https://search.test/find?src=hp&q=best+jokes+%26+puns%2F%C3%BC")
        XCTAssertNil(SafetyGuard.searchAddress(for: click(button), on: page, typed: [:]), "not typed in this sub-goal")
    }

    /// D4 on a results page (live, 2026-10-07, DuckDuckGo: a Yes was asked
    /// for its Search button): a search's results draw its box anew with the
    /// query in it — another fingerprint, the agent's own words. Its button
    /// sends them as the agent's search; a box showing words the agent never
    /// typed in this sub-goal is asked about as before.
    func testASearchBoxShowingTheAgentsOwnWordsIsItsSearch() {
        let typed = ["the box on the page before": "voice notes"]
        let results = searchForm(field: { $0.value = "voice notes" })
        XCTAssertNotEqual(results.field.fingerprint, "the box on the page before", "the premise: drawn anew")
        XCTAssertEqual(SafetyGuard.searchAddress(for: click(results.button), on: results.page, typed: typed)?
            .absoluteString, "https://search.test/find?src=hp&q=voice+notes")
        let other = searchForm(field: { $0.value = "unsubscribe all" })
        XCTAssertNil(SafetyGuard.searchAddress(for: click(other.button), on: other.page, typed: typed),
                     "words the agent never typed: the Yes as before")
    }

    /// Only a search field makes a search: a search box, or a field in the
    /// page's search landmark. A one-field e-mail form is none (Codex review 2
    /// of the brain, P1-1).
    func testOnlyASearchFieldMakesASearch() {
        let email = { (field: inout ObservedElement) in
            field = ObservedElement(index: 0, role: "textbox", name: "Email", text: "", href: nil, inputType: "email",
                                    heading: nil, region: .main, inViewport: true, context: nil,
                                    formAction: Self.searchAddress, formMethod: "get", formSubmitLabel: "Search",
                                    options: nil, checked: nil)
            field.formEntries = [.init(name: "email", value: nil)]
        }
        let signUp = searchForm(field: email)
        XCTAssertNil(SafetyGuard.searchAddress(for: click(signUp.button), on: signUp.page,
                                               typed: [signUp.field.fingerprint: "jokes"]), "a one-field e-mail form")
        let landmark = searchForm(field: { field in
            email(&field)
            field.inSearch = true
        })
        XCTAssertNotNil(SafetyGuard.searchAddress(for: click(landmark.button), on: landmark.page,
                                                  typed: [landmark.field.fingerprint: "jokes"]), "the page's search landmark")
    }

    /// A second filled control the form would send too — a category, a box
    /// ticked — makes it no pure search: the Yes as before.
    func testASecondFilledControlMakesItNoPureSearch() {
        let category = ObservedElement(index: 2, role: "combobox", name: "Category", text: "", href: nil, inputType: nil,
                                       heading: nil, region: .main, inViewport: true, context: nil,
                                       formAction: Self.searchAddress, formMethod: "get", formSubmitLabel: "Search",
                                       options: ["All", "Books"], checked: nil, value: "All")
        let filled = searchForm(extra: [category])
        XCTAssertNil(SafetyGuard.searchAddress(for: click(filled.button), on: filled.page,
                                               typed: [filled.field.fingerprint: "jokes"]), "a category")
        let box = { (checked: Bool) in
            ObservedElement(index: 2, role: "checkbox", name: "Exact", text: "", href: nil, inputType: "checkbox",
                            heading: nil, region: .main, inViewport: true, context: nil,
                            formAction: Self.searchAddress, formMethod: "get", formSubmitLabel: "Search",
                            options: nil, checked: checked)
        }
        let ticked = searchForm(extra: [box(true)])
        XCTAssertNil(SafetyGuard.searchAddress(for: click(ticked.button), on: ticked.page,
                                               typed: [ticked.field.fingerprint: "jokes"]), "a box ticked")
        let empty = searchForm(extra: [box(false)])
        XCTAssertNotNil(SafetyGuard.searchAddress(for: click(empty.button), on: empty.page,
                                                  typed: [empty.field.fingerprint: "jokes"]), "a box not ticked sends nothing")
    }

    /// A pure search is sent as its typing ends (№ 122), as a person's Enter
    /// sends it — with no button, and with one a person can press too
    /// (2026-10-07: on Wikipedia the agent typed, kept picking the suggestion
    /// list that closed under it, and never sent the search). Its button's
    /// words are still read as a click on it reads them.
    func testAPureSearchIsSentAsItsTypingEndsButtonOrNot() {
        let buttonless = searchForm(submitLabel: nil)
        XCTAssertEqual(SafetyGuard.searchAddress(typedInto: buttonless.field, on: buttonless.page,
                                                 typed: [buttonless.field.fingerprint: "jokes"])?.absoluteString,
                       "https://search.test/find?src=hp&q=jokes")
        let withButton = searchForm()
        XCTAssertEqual(SafetyGuard.searchAddress(typedInto: withButton.field, on: withButton.page,
                                                 typed: [withButton.field.fingerprint: "jokes"])?.absoluteString,
                       "https://search.test/find?src=hp&q=jokes", "a button a person can press sends nothing else")
        for label in ["Charge my card", "Delete"] {
            let form = searchForm(submitLabel: label)
            XCTAssertNil(SafetyGuard.searchAddress(typedInto: form.field, on: form.page,
                                                   typed: [form.field.fingerprint: "jokes"]), label)
        }
    }

    /// A form whose submit buttons no person can press — drawn at no size,
    /// or transparent, as a search box that sends on Enter draws its own — is
    /// to the person a form with no button, which Enter sends: searched the
    /// same way as its typing ends. Enter presses its first submit button,
    /// drawn or not, so that button's words are read as a click on it reads
    /// them: a payment or an action word keeps the search from going.
    func testAFormWhoseButtonNoOneCanPressIsSearchedAsItsTypingEnds() {
        // As the observer reports a field: it sends no form by a click.
        let hidden = { (label: String) in
            self.searchForm(submitLabel: label, field: { field in
                field.submitUnpressable = true
                field.submits = false
            })
        }
        let search = hidden("Search")
        XCTAssertEqual(SafetyGuard.searchAddress(typedInto: search.field, on: search.page,
                                                 typed: [search.field.fingerprint: "jokes"])?.absoluteString,
                       "https://search.test/find?src=hp&q=jokes")
        for label in ["Charge my card", "Delete"] {
            let form = hidden(label)
            XCTAssertNil(SafetyGuard.searchAddress(typedInto: form.field, on: form.page,
                                                   typed: [form.field.fingerprint: "jokes"]), label)
        }
        // A button no one can press whose words the page does not give —
        // `display: none` hides its text from its name — could say anything:
        // its form is not searched without a Yes (Codex review 1 of the fix,
        // P1: a hidden "Delete" on a same-site GET form).
        let unread = self.searchForm(submitLabel: nil, field: { field in
            field.submitUnpressable = true
            field.submits = false
        })
        XCTAssertNil(SafetyGuard.searchAddress(typedInto: unread.field, on: unread.page,
                                               typed: [unread.field.fingerprint: "jokes"]), "a button whose words are unknown")
    }

    /// Every other form still asks: each of D4's conditions, broken alone.
    func testEveryOtherFormIsNoSearch() {
        let typed = { (field: ObservedElement) in [field.fingerprint: "jokes"] }
        let plain = searchForm()
        let other = ObservedElement(index: 2, role: "textbox", name: "Near", text: "", href: nil, inputType: "text",
                                    heading: nil, region: .main, inViewport: true, context: nil,
                                    formAction: Self.searchAddress, formMethod: "get", formSubmitLabel: "Search",
                                    options: nil, checked: nil, value: "home")
        let two = searchForm(extra: [other])
        XCTAssertNil(SafetyGuard.searchAddress(for: click(two.button), on: two.page, typed: typed(two.field)),
                     "two text fields")
        let file = ObservedElement(index: 2, role: "button", name: "Attach", text: "", href: nil, inputType: "file",
                                   heading: nil, region: .main, inViewport: true, context: nil,
                                   formAction: Self.searchAddress, formMethod: "get", formSubmitLabel: "Search",
                                   options: nil, checked: nil)
        let withFile = searchForm(extra: [file])
        XCTAssertNil(SafetyGuard.searchAddress(for: click(withFile.button), on: withFile.page, typed: typed(withFile.field)),
                     "a file field")
        let post = searchForm(method: "post")
        XCTAssertNil(SafetyGuard.searchAddress(for: click(post.button), on: post.page, typed: typed(post.field)),
                     "a POST form")
        let away = searchForm(action: "https://elsewhere.test/find")
        XCTAssertNil(SafetyGuard.searchAddress(for: click(away.button), on: away.page, typed: typed(away.field)),
                     "another site's form")
        let word = searchForm(submitLabel: "Submit")
        XCTAssertNil(SafetyGuard.searchAddress(for: click(word.button), on: word.page, typed: typed(word.field)),
                     "a button that names an action")
        let paying = searchForm(flags: PageFlags(loginForm: false, paymentForm: true))
        XCTAssertNil(SafetyGuard.searchAddress(for: click(paying.button), on: paying.page, typed: typed(paying.field)),
                     "a page that takes a payment")
        let unread = searchForm(truncated: true)
        XCTAssertNil(SafetyGuard.searchAddress(for: click(unread.button), on: unread.page, typed: typed(unread.field)),
                     "a page not read whole")
        let nameless = searchForm(field: { $0.formEntries = nil })
        XCTAssertNil(SafetyGuard.searchAddress(for: click(nameless.button), on: nameless.page,
                                               typed: typed(nameless.field)), "a field whose query is not known")
        let home = searchForm(action: "http://router.local/find", page: "http://router.local/")
        XCTAssertNil(SafetyGuard.searchAddress(for: click(home.button), on: home.page, typed: typed(home.field)),
                     "an address on the user's own network")
        XCTAssertNil(SafetyGuard.searchAddress(for: click(plain.button), on: plain.page,
                                               typed: [plain.field.fingerprint: String(repeating: "joke ", count: 400)]),
                     "a query too long to be read back whole")
        for (what, change) in [
            ("a form that grants", { (button: inout ObservedElement) in button.formGrants = true }),
            ("a form holding a secret field", { (button: inout ObservedElement) in button.touchesSecret = true }),
            ("a form that needs a file", { (button: inout ObservedElement) in button.needsFile = true }),
            ("in a frame", { (button: inout ObservedElement) in button.frame = "frame-1" }),
            ("not its submit button", { (button: inout ObservedElement) in button.submits = false }),
        ] as [(String, (inout ObservedElement) -> Void)] {
            let form = searchForm(button: change)
            XCTAssertNil(SafetyGuard.searchAddress(for: click(form.button), on: form.page, typed: typed(form.field)), what)
        }
        let typing = AgentAction(operation: .type, target: plain.field, destination: nil, payload: "jokes",
                                 isPlannedSearch: false)
        XCTAssertNil(SafetyGuard.searchAddress(for: typing, on: plain.page, typed: typed(plain.field)), "not a click")
    }
}
