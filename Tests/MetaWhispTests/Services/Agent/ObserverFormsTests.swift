import XCTest
@testable import MetaWhisp

/// Level 2 (ITER-074 §6.1, §7.2): what the observer reports about forms, and
/// what it must never report. Sensitive fields leave no trace but a flag; the
/// page's hidden text never becomes an element.
final class ObserverFormsTests: XCTestCase {

    @MainActor
    private func observe(_ address: String) async throws -> ObservedPage {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: address)!)
        try await bridge.waitUntilLoaded(tab)
        let json = try await bridge.run(ObserverScript.source, in: tab)
        return try ObservedPage.decode(json)
    }

    private func named(_ name: String, in page: ObservedPage) -> ObservedElement? {
        page.elements.first { $0.name == name }
    }

    /// The observer's report as the app receives it, unparsed.
    @MainActor
    private func report(_ address: String) async throws -> String {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: address)!)
        try await bridge.waitUntilLoaded(tab)
        return try await bridge.run(ObserverScript.source, in: tab)
    }

    /// The report as the app receives it and as it decodes: a secret must be
    /// nowhere in the JSON, whichever field or key would carry it.
    @MainActor
    private func observed(_ address: String) async throws -> (page: ObservedPage, json: String) {
        let json = try await report(address)
        return (try ObservedPage.decode(json), json)
    }

    /// The fields typing goes into are said so (2026-10-21, Codex review 3, P1-1): a writable text field, a combobox
    /// that takes typing, a number field — the fields the hands write in (`aimToWrite`) — and no read-only field, no
    /// aria-readonly one, no native select, whatever its role.
    @MainActor
    func testTheFieldsTypingGoesIntoAreSaidSo() async throws {
        let page = try await observe("https://site-543.test/")
        for name in ["Plain", "Combo", "Count"] {
            XCTAssertEqual(named(name, in: page)?.typedInto, true, name)
        }
        for name in ["Locked", "Aria locked", "Read-only list", "Save"] {
            XCTAssertNotEqual(named(name, in: page)?.typedInto, true, name)
        }
    }

    // MARK: - ITER-076 2.3

    /// S4: a web component's button is named by the words its slot shows, so
    /// "Delete account" reaches the checks — and words it hides do not.
    @MainActor
    func testAWebComponentsButtonIsNamedByTheWordsItsSlotShows() async throws {
        let page = try await observe("https://site-66.test/")
        let delete = try XCTUnwrap(page.elements.first { $0.role == "button" && $0.name == "Delete account" },
                                   "\(page.elements.map(\.name))")
        XCTAssertTrue(SafetyGuard.lexiconRequiresConfirmation(
            AgentAction(operation: .click, target: delete, destination: nil, payload: nil, isPlannedSearch: false)))
        XCTAssertNotNil(page.elements.first { $0.role == "button" && $0.name == "Shown words" },
                        "hidden words stay out of the name: \(page.elements.map(\.name))")
    }

    /// Owner decision 4 (2026-09-29) replaces ITER-076 2.3's "no value ever":
    /// an ordinary field reports what it holds as its value. What someone
    /// wrote still reaches no name, text or row context.
    @MainActor
    func testOrdinaryFieldsReportTheirValuesNeverAsWords() async throws {
        let page = try await observe("https://site-66.test/")
        XCTAssertEqual(named("Search the site", in: page)?.value, "prefilled private words")
        XCTAssertEqual(named("Note", in: page)?.value, "typed private note")
        let plan = try XCTUnwrap(named("Plan", in: page))
        XCTAssertEqual(plan.value, "Premium")
        XCTAssertEqual(plan.options, ["Basic", "Premium"])
        XCTAssertFalse(page.elements.contains {
            [$0.name, $0.text, $0.context ?? "", $0.heading ?? ""].contains { $0.contains("private") }
        }, "a value is never a name, text, row or heading")
    }

    /// Review of 2.3: a custom select shows its choice as its own text, and
    /// that text is its value. It reaches no neighbour's row and no excerpt,
    /// drawn in the page or in a component's shadow root; the select itself
    /// is still reported by its name.
    @MainActor
    func testTheChoiceACustomSelectShowsIsNeverReported() async throws {
        let (page, json) = try await observed("https://site-66.test/")
        XCTAssertFalse(json.contains("Large"), "a combobox's choice drawn in the page")
        XCTAssertFalse(json.contains("Gold tier"), "a combobox's choice drawn in a shadow root")
        XCTAssertEqual(page.elements.first { $0.name == "Size" }?.role, "combobox")
        XCTAssertEqual(page.elements.first { $0.name == "Plan choice" }?.role, "combobox")
        XCTAssertNotNil(named("Apply size", in: page))
        XCTAssertNotNil(named("Save plan", in: page))
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-66.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let excerpt = try PageExcerpt.decode(try await bridge.run(ObserverScript.excerptSource(), in: tab))
        XCTAssertTrue(excerpt.text.contains("Chosen options"))
        XCTAssertFalse(excerpt.text.contains("Large"))
    }

    /// Review of 2.3: a control is named as a person hears it. Text a
    /// component draws straight in its shadow root names its host; a
    /// picture's alt, an icon's own label and an svg's title name their
    /// control, a slotted picture too; an icon's label counts beside the
    /// words next to it; an unlabelled submit button reads "Submit". A
    /// control named this way is offered.
    @MainActor
    func testAControlIsNamedByItsPicturesIconsAndShadowText() async throws {
        let page = try await observe("https://site-66.test/")
        let names = page.elements.map(\.name)
        for name in ["Close panel", "Trash", "Settings", "Share", "Submit"] {
            XCTAssertEqual(page.elements.first { $0.name == name }?.role, "button", "\(name) in \(names)")
        }
        let remove = try XCTUnwrap(named("Delete ProjectAlpha", in: page), "\(names)")
        XCTAssertTrue(SafetyGuard.lexiconRequiresConfirmation(
            AgentAction(operation: .click, target: remove, destination: nil, payload: nil, isPlannedSearch: false)))
        XCTAssertEqual(named("Trash", in: page)?.inViewport, true, "a slotted picture is part of its button on screen")
        let offered = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: [])).candidates
            .compactMap { $0.action.target?.name }
        XCTAssertTrue(Set(["Close panel", "Trash", "Settings", "Share", "Submit"]).isSubset(of: Set(offered)),
                      "\(offered)")
    }

    // MARK: - A field named by the words of its own group (2026-10-21)

    /// A practice form's captions are `<label>`s tied to no field (2026-10-21, a live run): unnamed, its date field
    /// and its subjects box had twins the hands refuse, and the brain could not tell them apart. A field the
    /// accessible-name order leaves unnamed is named by the words a person reads before it in its own group — its
    /// row's caption, the placeholder its select box draws — and the brain reads it so. A field its own label or
    /// placeholder names keeps that name; the form's button is named by its words, which the brain reads once,
    /// under it.
    @MainActor
    func testAFieldIsNamedByTheWordsBeforeItInItsOwnGroup() async throws {
        let page = try await observe("https://site-510.test/")
        let names = page.elements.map(\.name)
        let date = try XCTUnwrap(page.elements.first { $0.value == "21 Oct 2026" }, "\(names)")
        XCTAssertEqual(date.name, "Date of Birth")
        let subjects = try XCTUnwrap(named("Subjects", in: page), "its caption six boxes up: \(names)")
        XCTAssertEqual(subjects.role, "combobox")
        for field in [date, subjects] {
            XCTAssertEqual(page.identity(of: field).total, 1, "\(field.name) has no twin")
        }
        XCTAssertEqual(named("Select State", in: page)?.role, "combobox", "the placeholder its box draws: \(names)")
        XCTAssertEqual(page.elements.first { $0.inputType == "file" }?.name, "Picture")
        XCTAssertEqual(named("Email", in: page)?.inputType, "text", "its own label names it")
        XCTAssertEqual(named("Mobile Number", in: page)?.inputType, "text", "its own placeholder names it")
        XCTAssertNil(named("Mobile", in: page))
        XCTAssertEqual(named("Submit", in: page)?.submits, true)
        let state = BrainPrompt.elements(of: page, previous: nil)
        XCTAssertTrue(state.contains("<textbox name=Date of Birth type=text value=\"21 Oct 2026\" />"), state)
        XCTAssertTrue(state.contains("<button submits />\n\tSubmit"), state)
    }

    /// A field switched off is named by no group, as a select is by no role, and stays unoffered (Codex review P2-5);
    /// a select with no words in its own group is still named by its role (2026-10-21).
    @MainActor
    func testAFieldSwitchedOffIsNamedByNoGroup() async throws {
        let page = try await observe("https://site-510.test/")
        let lists = page.elements.filter { $0.options != nil }
        XCTAssertEqual(lists.map(\.name), ["", "combobox"], "\(page.elements.map(\.name))")
        let offered = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: [])).candidates
            .filter { $0.action.operation == .select }.compactMap { $0.action.target?.index }
        XCTAssertEqual(Set(offered), Set(lists.dropFirst().map(\.index)), "the one switched off is not offered")
    }

    /// A caption over two fields names neither: which one it is for is not known (2026-10-21).
    @MainActor
    func testACaptionOverTwoFieldsNamesNeither() async throws {
        let page = try await observe("https://site-510.test/")
        XCTAssertNil(named("Full name", in: page))
        let unnamed = page.elements.filter { $0.role == "textbox" && $0.name.isEmpty }
        XCTAssertEqual(unnamed.filter { $0.heading == "Student Registration Form" }.count, 2,
                       "only the two under one caption: \(page.elements.map(\.name))")
    }

    /// What a person does not read as a field's caption never names it (2026-10-21): words hidden from sight — not
    /// drawn, hidden or see-through — a hint after the field, the list it names as its own — the tags it holds — an
    /// announcement of how its search went, another control's words and a label of another control; the caption
    /// above them does. A section of the page, by its tag or its role, is no field's group: its words before a lone
    /// field are the page's. A secret field is named by nothing of its group: it is withheld.
    @MainActor
    func testWordsAPersonDoesNotReadAsACaptionNameNoField() async throws {
        let page = try await observe("https://site-510.test/")
        let names = page.elements.map(\.name)
        for name in ["Pronouns", "Nickname", "Tags", "Country", "Quantity", "Gift note"] {
            XCTAssertEqual(named(name, in: page)?.inputType, "text", "\(name) in \(names)")
        }
        for words in ["Old caption", "Unseen", "Faded", "Shown on your profile", "Science", "3 results"] {
            XCTAssertFalse(names.contains { $0.contains(words) }, "\(words) in \(names)")
        }
        XCTAssertEqual(page.elements.filter { $0.name == "Less" }.map(\.role), ["button"], "\(names)")
        XCTAssertEqual(page.elements.filter { $0.name == "Add a card" }.map(\.role), ["checkbox"], "\(names)")
        XCTAssertEqual(page.elements.filter { $0.heading == "Newsletter" }.map(\.name), ["", ""], "\(names)")
        XCTAssertNil(named("Password", in: page), "withheld")
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-510.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let probe = "(() => {\n" + ObserverScript.walk
            + "return JSON.stringify(observe().withheld.map((element) => element.name));\n})()"
        let withheld = try JSONDecoder().decode([String].self, from: Data(try await bridge.run(probe, in: tab).utf8))
        XCTAssertEqual(withheld, [""], "the secret field's caption is not its name")
    }

    /// A practice form in a table names its boxes and radios only by the words drawn right after each, and a field
    /// that shares its cell only by the words on its line, or on the line above it (2026-10-21, a live run: three
    /// boxes, unnamed, with one row's words, were twins the hands refused eight times). Each is named by the words
    /// on its own line — a box's up to the next control, line break or block, a field's from the last one before
    /// it — so none has a twin; words hidden from assistive technology are none of them. The password stays
    /// withheld.
    @MainActor
    func testABoxAndAFieldAreNamedByTheWordsOnTheirOwnLine() async throws {
        let page = try await observe("https://site-511.test/")
        let names = page.elements.map(\.name)
        XCTAssertEqual(page.elements.filter { $0.role == "checkbox" }.map(\.name),
                       ["Checkbox 1", "Checkbox 2", "Checkbox 3", "Notify me", "Weekly digest"], "\(names)")
        XCTAssertEqual(page.elements.filter { $0.role == "radio" }.map(\.name), ["radio 1", "radio 2", "radio 3"], "\(names)")
        for box in page.elements where ["checkbox", "radio"].contains(box.role) {
            XCTAssertEqual(page.identity(of: box).total, 1, "\(box.name) has no twin")
        }
        XCTAssertEqual(page.elements.filter { $0.role == "textbox" }.map(\.name),
                       ["Username:", "TextArea Comment:", "First name:", "Last name:", "Email:"], "\(names)")
        XCTAssertEqual(named("Dropdown:", in: page)?.role, "combobox", "\(names)")
        XCTAssertFalse(page.elements.contains { $0.inputType == "password" || $0.name.contains("Password") }, "withheld")
    }

    /// Slots show only what a person sees: a named slot shows its own words
    /// and not the ones no slot takes, nested slots pass their words through,
    /// an empty slot shows its fallback, and hidden slotted words stay out.
    @MainActor
    func testSlotsShowOnlyWhatAPersonSees() async throws {
        let (page, json) = try await observed("https://site-66.test/")
        let names = page.elements.map(\.name)
        for name in ["Archive project", "Remove member", "Default action", "Visible part"] {
            XCTAssertEqual(page.elements.first { $0.name == name }?.role, "button", "\(name) in \(names)")
            XCTAssertEqual(named(name, in: page)?.inViewport, true, "what a slot shows is its button on screen")
        }
        XCTAssertFalse(json.contains("Words no slot shows"))
        XCTAssertFalse(json.contains("Hidden part"))
    }

    /// A payment page's ordinary select lists its options (owner decision 4),
    /// and so does one on a page cut short: what the walk reached is shown as
    /// a person sees it — only a field the page marks secret is ever left out
    /// (owner decision of 2026-10-03).
    @MainActor
    func testOptionsAreListedOnAPaymentPageAndOnAPageCutShort() async throws {
        let payment = try await observe("https://site-19.test/")
        XCTAssertTrue(payment.flags.paymentForm)
        let country = try XCTUnwrap(named("Country", in: payment))
        XCTAssertEqual(country.options?.isEmpty, false)
        let long = try await observe("https://site-68.test/")
        XCTAssertTrue(long.truncated)
        XCTAssertFalse(long.flags.loginForm || long.flags.paymentForm, "nothing secret on it")
        let early = try XCTUnwrap(named("Early choice", in: long))
        XCTAssertEqual(early.options, ["First choice", "Second choice"])
        XCTAssertEqual(early.value, "First choice")
    }

    /// Review of 2.3: the text walk counts every node it visits, and takes
    /// no more of a node's children than it may still visit (round 2), so a
    /// row that holds a large drawing costs a bounded walk for each control
    /// in it, and the report is not cut short by the drawing.
    @MainActor
    func testARowHoldingALargeDrawingDoesNotCutTheReportShort() async throws {
        let page = try await observe("https://site-69.test/")
        XCTAssertFalse(page.truncated)
        XCTAssertEqual(page.elements.filter { $0.name.hasPrefix("Series ") }.count, 80)
    }

    /// Review of 2.3, round 2: the choice a custom select library draws never
    /// reaches the report — not as a combobox's title (bootstrap-select), not
    /// as a control drawn inside the combobox (select2's read-only textbox, a
    /// remove button), not as text inside a list box drawn as a select
    /// (Choices.js). The rows' own buttons are still reported.
    @MainActor
    func testACustomSelectLibrarysChoiceNeverReachesTheReport() async throws {
        let (page, json) = try await observed("https://site-70.test/")
        // Round 2 of the 2.3b review: vue-select's deselect buttons, read
        // through the search box's label, and a choice drawn as a button.
        let choices = ["Mustard", "Alaska", "Tokyo", "Canada", "Mexico", "Lisbon", "Porto"]
        for choice in choices {
            XCTAssertFalse(json.contains(choice), choice)
        }
        for button in ["Save condiment", "Save state", "Book trip", "Save countries", "Book flight"] {
            XCTAssertNotNil(named(button, in: page), "\(button) in \(page.elements.map(\.name))")
        }
        // Round 3 of the 2.3b review: a remove button with no type is a
        // submitter, and it never names the form.
        XCTAssertEqual(named("Add a stop", in: page)?.formSubmitLabel, "Book train")
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-70.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let excerpt = try PageExcerpt.decode(try await bridge.run(ObserverScript.excerptSource(), in: tab))
        XCTAssertTrue(excerpt.text.contains("Orders"), excerpt.text)
        for choice in choices {
            XCTAssertFalse(excerpt.text.contains(choice), "\(choice) in \(excerpt.text)")
        }
    }

    /// Review of 2.3b, round 2: every field is checked for a secret before
    /// any is left out of the report — an ARIA text box inside a custom
    /// select's wrapper still flags the page and is hidden. Since owner
    /// decision 4 the ordinary select beside it lists its options, and the
    /// button with no form beside the secret could send it.
    @MainActor
    func testEveryFieldIsCheckedForASecretBeforeAnyIsLeftOut() async throws {
        let page = try await observe("https://site-77.test/")
        XCTAssertTrue(page.flags.loginForm)
        XCTAssertNil(named("Verification code", in: page))
        XCTAssertEqual(named("Account", in: page)?.options, ["three@example.com", "four@example.com"])
        XCTAssertEqual(named("Continue", in: page)?.touchesSecret, true)
    }

    /// Review of 2.3b, round 2: a form's destination keeps the query and the
    /// fragment its own action names — a script may send it as it is. Only a
    /// form with no action of its own, which sends to the page's address, is
    /// read without the page's query and fragment.
    @MainActor
    func testAFormKeepsTheQueryItsOwnActionNames() async throws {
        let page = try await observe("https://site-78.test/?orderby=price")
        let go = try XCTUnwrap(named("Go", in: page))
        XCTAssertEqual(go.formAction, "https://site-78.test/account?op=delete")
        XCTAssertTrue(SafetyGuard.lexiconRequiresConfirmation(
            AgentAction(operation: .click, target: go, destination: nil, payload: nil, isPlannedSearch: false)))
        XCTAssertEqual(named("Continue", in: page)?.formAction, "https://site-78.test/app#/orders/cancel")
        XCTAssertEqual(named("Sort by", in: page)?.formAction, "https://site-78.test/")
        // Round 3 of the 2.3b review: "#" names no page, only a place on it —
        // the form still sends to the page's address.
        XCTAssertEqual(named("Sort order", in: page)?.formAction, "https://site-78.test/#")
    }

    /// Review of 2.3b, round 3: deciding whether words sit in a custom select
    /// walks up the tree without recursion. Chrome draws a page nested
    /// thousands deep, and the old recursion ran out of stack there (the
    /// reviewer ran it in Chrome); WebKit draws nothing past about 512
    /// levels. So this pins that such a page is observed without error, and
    /// that a control within WebKit's depth is still named.
    @MainActor
    func testADeeplyNestedPageIsStillObserved() async throws {
        let shallow = try await observe("https://site-80.test/?depth=400")
        XCTAssertEqual(named("Deep action", in: shallow)?.role, "button", "\(shallow.elements.map(\.name))")
        let deep = try await observe("https://site-80.test/?depth=3000")
        XCTAssertFalse(deep.truncated)
    }

    /// Review of 2.3b: a real field inside a custom select's wrapper — the
    /// ARIA 1.1 combobox layout — is still a field: reported, and checked for
    /// a secret. A list box that is a plain list keeps its links and buttons,
    /// and a tree of choices keeps its items.
    @MainActor
    func testFieldsInsideASelectsWrapperAndPlainListsAreStillControls() async throws {
        let page = try await observe("https://site-74.test/")
        let names = page.elements.map { "\($0.role): \($0.name)" }
        XCTAssertEqual(named("Search products", in: page)?.role, "searchbox", "\(names)")
        XCTAssertEqual(named("City", in: page)?.role, "textbox", "\(names)")
        for link in ["First result", "Second result"] {
            XCTAssertEqual(named(link, in: page)?.role, "link", "\(names)")
        }
        XCTAssertEqual(named("Load more", in: page)?.role, "button", "\(names)")
        XCTAssertEqual(named("Recorders", in: page)?.role, "treeitem", "\(names)")
    }

    /// Review of 2.3b: a field whose words name a sign-in or a payment inside
    /// a custom select's wrapper still flags the page. Since owner decision 4
    /// the page's ordinary select lists its options; since the owner's
    /// decision of 2026-10-03 the fields themselves, marked secret by no
    /// structure, are shown.
    @MainActor
    func testASecretFieldInsideASelectsWrapperStillFlagsThePage() async throws {
        let page = try await observe("https://site-75.test/")
        XCTAssertTrue(page.flags.loginForm, "the verification code inside a list box")
        XCTAssertTrue(page.flags.paymentForm, "the card number inside a combobox")
        XCTAssertNotNil(named("Verification code", in: page))
        XCTAssertNotNil(named("Card number", in: page))
        XCTAssertEqual(named("Account", in: page)?.options, ["one@example.com", "two@example.com"])
    }

    /// Review of 2.3, round 2: a control that is itself a picture or an svg is
    /// named by its own alt or title.
    @MainActor
    func testAControlThatIsItselfAPictureIsNamedByIt() async throws {
        let page = try await observe("https://site-66.test/")
        let names = page.elements.map(\.name)
        XCTAssertEqual(named("Next photo", in: page)?.role, "button", "\(names)")
        XCTAssertEqual(named("Close dialog", in: page)?.role, "button", "\(names)")
    }

    /// Review of 2.3, round 2: the word a browser shows on a value-less submit
    /// names that button only. An unseen one names no form, so typing a
    /// search is not read as "submit".
    @MainActor
    func testAnUnseenSubmitNamesNoForm() async throws {
        let page = try await observe("https://site-66.test/")
        let find = try XCTUnwrap(named("Find a page", in: page))
        XCTAssertNil(find.formSubmitLabel)
        XCTAssertEqual(named("Submit", in: page)?.role, "button")
    }

    /// ITER-076 I-09, round 7 (Claude review c11, #11): a form's submit label
    /// is its first submit button's words, whether a person can press it or
    /// not. Only one a person can press sends a change (round 5, Claude
    /// review c10, #15) — never one disabled, by itself or its fieldset,
    /// inert, hidden, not displayed, not visible or of zero size: in a form
    /// with none, a change is its own send.
    @MainActor
    func testAFormIsNamedByItsFirstSubmitButtonAndAChangeIsItsSendWhenNoneCanBePressed() async throws {
        let page = try await observe("https://site-300.test/forms")
        for way in ["Disabled", "Fieldset", "Inert", "Hidden", "Undisplayed", "Unseen", "Zero"] {
            let plan = try XCTUnwrap(named(way + " plan", in: page), "\(page.elements.map(\.name))")
            XCTAssertEqual(plan.formSubmitLabel, "Save", way)
            XCTAssertTrue(SafetyGuard.commits(AgentAction(operation: .click, target: plan, destination: nil, payload: nil,
                                                          isPlannedSearch: false)), way)
        }
        let pressable = try XCTUnwrap(named("Pressable plan", in: page), "\(page.elements.map(\.name))")
        XCTAssertEqual(pressable.formSubmitLabel, "Save")
        XCTAssertFalse(SafetyGuard.commits(AgentAction(operation: .click, target: pressable, destination: nil, payload: nil,
                                                       isPlannedSearch: false)))
    }

    /// ITER-076 I-09, round 7 (Claude review c11, #3): a card number a field
    /// showed stays a card's when the page then draws the field as dots: the
    /// page takes a payment, and the field, secret now, is not reported.
    @MainActor
    func testACardNumberAFieldShowedStaysACardsOnceDrawnAsDots() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-310.test/remembered")!)
        try await bridge.waitUntilLoaded(tab)
        let shown = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertTrue(shown.flags.paymentForm)
        XCTAssertEqual(named("Number", in: shown)?.value, "4111 1111 1111 1111")
        _ = try await bridge.run("document.querySelector('[name=n]').style.webkitTextSecurity = 'disc', 'dots'", in: tab)
        let dotted = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertNil(named("Number", in: dotted))
        XCTAssertTrue(dotted.flags.paymentForm)
    }

    /// Review of 2.3b, round 2: the excerpt does not walk into what is never
    /// drawn, or into a drawing: a large icon sprite before the text leaves
    /// the text in reach.
    @MainActor
    func testTheExcerptSkipsHiddenAndDrawnSprites() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-79.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let excerpt = try PageExcerpt.decode(try await bridge.run(ObserverScript.excerptSource(), in: tab))
        XCTAssertTrue(excerpt.text.contains("Plans start at ten dollars a month."), excerpt.text)
    }

    /// Review of 2.3, round 2: the writer's excerpt reads the tree a person
    /// sees — words slotted into a component, drawn in its shadow root, or
    /// inside an element that draws no box of its own — and nothing a person
    /// does not see, nothing someone wrote, and no custom select's choice.
    @MainActor
    func testTheExcerptReadsTheTreeAPersonSees() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-66.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let excerpt = try PageExcerpt.decode(try await bridge.run(ObserverScript.excerptSource(), in: tab))
        for words in ["Delete account", "Close panel", "Contents words"] {
            XCTAssertTrue(excerpt.text.contains(words), "\(words) in \(excerpt.text)")
        }
        for unseen in ["Hidden words", "Hidden part", "Words no slot shows", "Large", "Gold tier",
                       "prefilled private words", "typed private note"] {
            XCTAssertFalse(excerpt.text.contains(unseen), unseen)
        }
    }

    // MARK: - Sensitive fields and flags

    /// A password field is not reported at all; the page is flagged instead,
    /// so the loop pauses and asks the user to sign in (§7.2, §11). A field
    /// only its name calls one ("pwd") is shown as any field is (owner
    /// decision of 2026-10-03).
    @MainActor
    func testALoginFormIsFlaggedAndItsPasswordIsGone() async throws {
        let (page, json) = try await observed("https://site-5.test/")
        XCTAssertTrue(page.flags.loginForm)
        XCTAssertFalse(page.flags.paymentForm)
        XCTAssertNil(named("Password", in: page))
        XCTAssertEqual(named("Access key", in: page)?.role, "textbox")
        XCTAssertFalse(page.elements.contains { $0.inputType == "password" })
        XCTAssertFalse(json.contains("not-a-real-secret"))
    }

    /// Owner decision 4: next to a password the user name is an ordinary
    /// value and is shown — but the field could send the password with its
    /// form, so it says so. The password never shows.
    @MainActor
    func testAUserNameInALoginFormIsShownAndCouldSendTheSecret() async throws {
        let (page, json) = try await observed("https://site-5.test/")
        let email = try XCTUnwrap(named("Email", in: page))
        XCTAssertEqual(email.role, "textbox")
        XCTAssertEqual(email.value, "someone@example.com")
        XCTAssertTrue(email.touchesSecret)
        XCTAssertFalse(json.contains("not-a-real-secret"))
    }

    /// The fields the page marks as a card's (`cc-number`, `cc-exp`) are
    /// gone; those only their words or names call a card's ("Security code",
    /// name=cvc) are shown, and still make the form a payment (owner
    /// decision of 2026-10-03).
    @MainActor
    func testAPaymentFormIsFlaggedAndItsCardFieldsAreGone() async throws {
        let page = try await observe("https://site-12.test/")
        XCTAssertTrue(page.flags.paymentForm)
        XCTAssertNil(named("Card number", in: page))
        XCTAssertNil(named("Expiry", in: page))
        XCTAssertEqual(named("Security code", in: page)?.role, "textbox")
        XCTAssertEqual(named("Verification", in: page)?.role, "textbox")
        XCTAssertEqual(named("Pay now", in: page)?.touchesSecret, true)
        XCTAssertNotNil(named("Email for the receipt", in: page))
        XCTAssertEqual(named("Pay now", in: page)?.role, "button")
    }

    @MainActor
    func testAnOrdinaryPageRaisesNoFlags() async throws {
        let page = try await observe("https://site-2.test/")
        XCTAssertFalse(page.flags.loginForm)
        XCTAssertFalse(page.flags.paymentForm)
    }

    // MARK: - Forms

    /// A risk check needs to know where a button sends things (§6.3, §7.1).
    @MainActor
    func testAFormControlCarriesItsFormsDestination() async throws {
        let page = try await observe("https://site-7.test/")
        let proceed = named("Continue", in: page)
        XCTAssertEqual(proceed?.formAction, "https://site-7.test/send-message")
        XCTAssertEqual(proceed?.formMethod, "post")
        XCTAssertEqual(proceed?.formSubmitLabel, "Continue")
        let message = named("Your message", in: page)
        XCTAssertEqual(message?.formAction, "https://site-7.test/send-message")
        XCTAssertEqual(message?.formSubmitLabel, "Continue")
        XCTAssertEqual(message?.text, "")
        // The search field and its button are both called "Search"; tell them
        // apart by role.
        let searchBox = page.elements.first { $0.role == "searchbox" && $0.name == "Search" }
        XCTAssertEqual(searchBox?.formMethod, "get")
        XCTAssertEqual(searchBox?.formAction, "https://site-7.test/search")
        let searchButton = page.elements.first { $0.role == "button" && $0.name == "Search" }
        XCTAssertEqual(searchButton?.formAction, "https://site-7.test/search")
        XCTAssertNotEqual(searchButton?.fingerprint, proceed?.fingerprint)
    }

    /// ITER-076 2.1: whether a control sends its form is structure the risk
    /// check reads in any language. A submit button sends its form; a plain
    /// button or a field does not, and a submit button outside a form sends
    /// nothing.
    @MainActor
    func testAControlSaysWhetherItSubmitsItsForm() async throws {
        let page = try await observe("https://site-52.test/")
        XCTAssertEqual(named("Supprimer le compte", in: page)?.submits, true)
        XCTAssertEqual(named("Supprimer le compte", in: page)?.formMethod, "post")
        XCTAssertEqual(named("Afficher les détails", in: page)?.submits, false)
        XCTAssertEqual(named("Chercher", in: page)?.submits, true)
        XCTAssertEqual(page.elements.first { $0.role == "searchbox" }?.submits, false)
        XCTAssertEqual(named("Weiter", in: page)?.submits, true, "a button with no type submits")
        XCTAssertEqual(named("Weiter", in: page)?.formAction, "https://other-52.test/abonnement")
        XCTAssertEqual(named("Sans formulaire", in: page)?.submits, false, "outside a form it sends nothing")
        XCTAssertEqual(named("Envoyer l'image", in: page)?.submits, true, "an image input submits")
        XCTAssertEqual(named("Hors du formulaire", in: page)?.submits, true, "the form= attribute joins a form")
        XCTAssertEqual(named("Hors du formulaire", in: page)?.formMethod, "post")
        XCTAssertEqual(named("Chercher et enregistrer", in: page)?.formMethod, "post", "formmethod overrides the form")
        XCTAssertEqual(named("Fermer la boîte", in: page)?.formMethod, "dialog")
        XCTAssertEqual(named("Supprimer le compte", in: page)?.formGrants, false)
        // A script control inside a form belongs to it, and sends nothing by itself.
        XCTAssertEqual(named("Konto löschen", in: page)?.formMethod, "post")
        XCTAssertEqual(named("Konto löschen", in: page)?.submits, false)
        // A link inside a form only goes to its own address; the form says
        // nothing about it.
        XCTAssertNil(named("Aide", in: page)?.formAction)
        XCTAssertNil(named("Aide", in: page)?.formMethod)
        XCTAssertEqual(named("Aide", in: page)?.submits, false)
        // An anchor with another role is clicked, not opened, so its page
        // scripts run and the form around it counts (CandidateBuilder: only
        // role "link" is opened).
        XCTAssertEqual(named("Profil", in: page)?.role, "menuitem")
        XCTAssertEqual(named("Profil", in: page)?.formMethod, "post")
        // A label for a submit button sends that button's form.
        XCTAssertEqual(named("Los", in: page)?.submits, true)
        XCTAssertEqual(named("Los", in: page)?.formAction, "https://other-52.test/abonnement")
    }

    /// ITER-076 2.1: a form that carries an OAuth request in its fields,
    /// hidden ones included, grants access whatever its button says.
    @MainActor
    func testAFormCarryingAnOAuthRequestIsMarkedAsAGrant() async throws {
        let page = try await observe("https://site-53.test/")
        XCTAssertEqual(named("Autoriser l'accès", in: page)?.formGrants, true)
        XCTAssertNil(named("Annuler", in: page)?.formGrants, "a link outside any form carries none")
    }

    @MainActor
    func testElementsOutsideAFormHaveNoFormFields() async throws {
        let page = try await observe("https://site-2.test/")
        XCTAssertNil(named("See plans", in: page)?.formAction)
        XCTAssertNil(named("See plans", in: page)?.formMethod)
    }

    /// Two submit buttons with the same name in different forms are
    /// different things to do; their fingerprints must differ.
    func testTheFormsDestinationIsPartOfTheFingerprint() {
        func button(action: String?, method: String?) -> ObservedElement {
            ObservedElement(index: 0, role: "button", name: "Continue", text: "Continue", href: nil,
                            inputType: nil, heading: "Contact us", region: .main, inViewport: true,
                            context: nil, formAction: action, formMethod: method, formSubmitLabel: "Continue",
                            options: nil, checked: nil)
        }
        let send = button(action: "https://a.test/send", method: "post")
        XCTAssertNotEqual(send.fingerprint, button(action: "https://a.test/search", method: "post").fingerprint)
        XCTAssertNotEqual(send.fingerprint, button(action: "https://a.test/send", method: "get").fingerprint)
    }

    // MARK: - Values

    /// A select lists its options, the page's own words, and the one it
    /// shows is its value (owner decision 4).
    @MainActor
    func testASelectListsItsOptions() async throws {
        let page = try await observe("https://site-4.test/")
        let billing = named("Billing period", in: page)
        XCTAssertEqual(billing?.role, "combobox")
        XCTAssertEqual(billing?.options, ["Monthly", "Yearly"])
        XCTAssertEqual(billing?.value, "Yearly")
    }

    /// An ordinary search box reports what it holds (owner decision 4).
    @MainActor
    func testAnOrdinarySearchBoxReportsWhatItHolds() async throws {
        let page = try await observe("https://site-4.test/")
        XCTAssertEqual(named("Search the docs", in: page)?.value, "prefilled query")
    }

    /// A draft is someone's writing: it must not reach a neighbour's row
    /// context, nor become the heading of what follows the editor.
    @MainActor
    func testADraftNeverLeaksThroughContextOrHeadings() async throws {
        let page = try await observe("https://site-17.test/")
        let send = try XCTUnwrap(named("Send", in: page))
        XCTAssertFalse((send.context ?? "").contains("Private draft"))
        XCTAssertEqual(named("After editor", in: page)?.heading, "Compose")
        XCTAssertFalse(page.elements.contains {
            $0.name.contains("draft") || $0.text.contains("draft") || ($0.context ?? "").contains("draft")
                || ($0.heading ?? "").contains("Draft")
        })
    }

    // MARK: - Review round 4: every way a secret could still get out

    /// A field is named by any of its labels, not only a <label for>: one
    /// aria-labelledby calls "Password" asks for a sign-in — and, marked
    /// secret by no structure, shows what it holds as a person sees it
    /// (owner decision of 2026-10-03).
    @MainActor
    func testAPasswordNamedByAriaLabelledByIsASignInAndShown() async throws {
        let (page, json) = try await observed("https://site-18.test/")
        XCTAssertTrue(page.flags.loginForm)
        XCTAssertEqual(named("Password", in: page)?.value, "secret-by-label")
        XCTAssertTrue(json.contains("secret-by-label"))
    }

    /// A verification code with no autocomplete is shown as it stands.
    @MainActor
    func testAVerificationCodeWithoutAutocompleteIsShown() async throws {
        let (page, json) = try await observed("https://site-18.test/")
        XCTAssertEqual(named("Verification code", in: page)?.value, "123456")
        XCTAssertTrue(json.contains("123456"))
    }

    /// An expiry date with no autocomplete makes the page a payment, and is
    /// shown as it stands.
    @MainActor
    func testAnExpiryDateWithoutAutocompleteIsAPaymentAndShown() async throws {
        let page = try await observe("https://site-19.test/")
        XCTAssertTrue(page.flags.paymentForm)
        XCTAssertEqual(named("Expiry date", in: page)?.value, "12/29")
    }

    /// A restored draft in a textarea reaches no label, name or neighbour.
    @MainActor
    func testATextareasContentsReachNoLabelOrNeighbour() async throws {
        let page = try await observe("https://site-20.test/")
        XCTAssertEqual(named("Notes", in: page)?.role, "textbox")
        XCTAssertFalse(page.elements.contains {
            $0.name.contains("Private") || $0.text.contains("Private") || ($0.context ?? "").contains("Private")
        })
    }

    /// Non-editable chips inside an editor are part of the writing.
    @MainActor
    func testChipsInsideAnEditorAreNotControlsOrHeadings() async throws {
        let page = try await observe("https://site-20.test/")
        XCTAssertNil(named("Chip action", in: page))
        XCTAssertEqual(named("After chips", in: page)?.heading, "Notes")
    }

    /// A password inside a widget's shadow root locks the whole page's
    /// values, including the form around the widget.
    @MainActor
    func testAShadowPasswordLocksThePage() async throws {
        let page = try await observe("https://site-21.test/")
        XCTAssertTrue(page.flags.loginForm)
        XCTAssertNil(named("Widget password", in: page))
    }

    /// Saved accounts listed as options are ordinary values (owner decision
    /// 4) — listed, in a form that could send the password.
    @MainActor
    func testSavedAccountsInALoginFormAreListedAndCouldSendTheSecret() async throws {
        let page = try await observe("https://site-5.test/")
        let account = try XCTUnwrap(named("Account", in: page))
        XCTAssertEqual(account.options, ["someone@example.com", "another account"])
        XCTAssertTrue(account.touchesSecret)
    }

    /// ITER-076 2.2: the fields after a field whose words cannot be read are
    /// still checked: a card field behind an unreadable one still flags the
    /// page. Neither is marked secret by its structure, so both are shown
    /// (owner decision of 2026-10-03).
    @MainActor
    func testAFieldBehindAnUnreadableOneIsStillChecked() async throws {
        let page = try await observe("https://site-55.test/")
        XCTAssertTrue(page.flags.paymentForm, "the card field after the unreadable one was checked")
        XCTAssertNotNil(named("Card number", in: page))
        XCTAssertEqual(page.elements.filter { $0.role == "textbox" }.count, 2, "both fields are reported")
        XCTAssertNotNil(named("Continue", in: page))
    }

    /// A page too long to scan is cut and says so, and a password past the
    /// cut still flags it; what the walk did reach reports what it holds — a
    /// field the walk reached is checked for its structure whole (owner
    /// decision of 2026-10-03).
    @MainActor
    func testAnIncompleteScanStillReportsTheValuesItReached() async throws {
        let page = try await observe("https://site-22.test/")
        XCTAssertTrue(page.truncated)
        XCTAssertTrue(page.flags.loginForm, "a password is found even past the scan limit")
        XCTAssertEqual(named("Early field", in: page)?.value, "early value")
        XCTAssertNil(named("Late password", in: page))
    }

    /// aria-labelledby is resolved in the control's own shadow root, not in
    /// the document where another element may carry the same id.
    @MainActor
    func testShadowLabelsResolveInTheirOwnRoot() async throws {
        let page = try await observe("https://site-21.test/")
        XCTAssertEqual(page.elements.first { $0.role == "button" && $0.name == "Delete account" }?.role, "button")
        XCTAssertFalse(page.elements.contains { $0.role == "button" && $0.name == "Save" })
    }

    /// A control named "action" or "method" cannot rewrite where the form
    /// says it sends; a button with a missing or unknown type is a submitter.
    @MainActor
    func testFormDestinationsResistClobberingAndOddTypes() async throws {
        let page = try await observe("https://site-7.test/")
        let clobbered = try XCTUnwrap(named("Clobbered submit", in: page))
        XCTAssertEqual(clobbered.formAction, "https://site-7.test/real-destination")
        XCTAssertEqual(clobbered.formMethod, "post")
        XCTAssertEqual(clobbered.formSubmitLabel, "Clobbered submit")
        let override = try XCTUnwrap(named("Override", in: page))
        XCTAssertEqual(override.formAction, "https://site-7.test/override")
        XCTAssertEqual(override.formMethod, "get")
        XCTAssertEqual(named("Decoy", in: page)?.formSubmitLabel, "Clobbered submit")
    }

    // MARK: - Review round 5: every word that names a field, every place someone writes

    /// Words never hide a field — a hidden aria-labelledby label, a hidden
    /// <label>, a title: what those fields hold is shown. Only the password
    /// autocomplete token, the page's structure, does (owner decision of
    /// 2026-10-03). (What someone wrote in a custom text field stays theirs,
    /// whatever its name: `testACustomTextFieldsContentsReachNoNeighbour`.)
    @MainActor
    func testOnlyAFieldsStructureHidesItNeverItsHiddenOrSecondaryWords() async throws {
        let (page, json) = try await observed("https://site-23.test/")
        XCTAssertTrue(page.flags.loginForm)
        XCTAssertFalse(json.contains("secret-four"), "autocomplete=current-password")
        XCTAssertFalse(page.elements.contains { $0.name == "Field four" })
        for shown in ["secret-one", "secret-two", "secret-three"] {
            XCTAssertTrue(json.contains(shown), shown)
        }
    }

    /// Whatever sits inside a text field, native or ARIA, is someone's
    /// writing: it reaches no neighbour, and a chip in it is not a control.
    @MainActor
    func testACustomTextFieldsContentsReachNoNeighbour() async throws {
        let page = try await observe("https://site-23.test/")
        XCTAssertNotNil(named("Continue", in: page))
        XCTAssertNotNil(named("Send it", in: page))
        XCTAssertFalse(page.elements.contains { element in
            [element.name, element.text, element.context ?? "", element.heading ?? ""].contains {
                $0.contains("secret") || $0.contains("private-message")
            }
        })
        XCTAssertNil(named("Remove Alex", in: page))
    }

    /// A chip a component draws in its own shadow root is still inside the
    /// editor around its host.
    @MainActor
    func testAShadowChipInsideAnEditorIsNotAControl() async throws {
        let page = try await observe("https://site-23.test/")
        XCTAssertEqual(named("Composer", in: page)?.role, "textbox")
        XCTAssertFalse(page.elements.contains { $0.name.contains("shadow chip") || $0.text.contains("shadow chip") })
    }

    /// Options in a list box are choices, not writing: they stay controls.
    @MainActor
    func testOptionsInAListBoxAreStillControls() async throws {
        let page = try await observe("https://site-23.test/")
        XCTAssertEqual(named("Monthly plan", in: page)?.role, "option")
    }

    // MARK: - Review round 7: read whole, walk the tree a person sees, say where a click leads

    /// The words that name a sign-in are read in every label whole — the
    /// sixth aria-labelledby label, a word split across tags, a word past any
    /// display cut-off. Marked secret by no structure, the fields show what
    /// they hold (owner decision of 2026-10-03).
    @MainActor
    func testSignInWordsAreReadInEveryLabelWhole() async throws {
        let (page, json) = try await observed("https://site-24.test/")
        XCTAssertTrue(page.flags.loginForm)
        for shown in ["secret-sixth", "secret-split", "secret-long", "secret-verify"] {
            XCTAssertTrue(json.contains(shown), shown)
        }
    }

    /// Writing is judged on the tree a person sees: a chip slotted into a
    /// component's text field is part of it, and a list box stays a list box
    /// whatever fallback role it names.
    @MainActor
    func testWritingFollowsSlotsAndTheElementsOwnRole() async throws {
        let page = try await observe("https://site-24.test/")
        XCTAssertNil(named("Remove Sam", in: page))
        XCTAssertEqual(named("To", in: page)?.role, "textbox")
        XCTAssertEqual(named("Large size", in: page)?.role, "option")
    }

    /// A control reports where activating it leads — its own address, or the
    /// link around it — and a form control where its form sends.
    @MainActor
    func testAControlInsideALinkReportsTheLinksAddress() async throws {
        let page = try await observe("https://site-25.test/")
        let buttons = page.elements.filter { $0.role == "button" }
        XCTAssertEqual(buttons.first { $0.name == "Write to support" }?.href, "mailto:help")
        XCTAssertEqual(buttons.first { $0.name == "Next page" }?.href, "https://site-25.test/next")
        XCTAssertEqual(named("Send the form", in: page)?.formAction, "mailto:help")
        let inside = page.elements.filter { $0.name == "Continue inside" }
        XCTAssertFalse(inside.isEmpty)
        XCTAssertTrue(inside.allSatisfy { $0.formAction == "mailto:help" },
                      "a control inside a submit button sends its form")
    }

    /// A select lists up to 1000 options and a page up to 2000 in all: a
    /// country list fits whole, and the report stays bounded.
    @MainActor
    func testLongSelectsAreListedWithinBounds() async throws {
        let page = try await observe("https://site-25.test/")
        XCTAssertEqual(named("Country", in: page)?.options?.count, 300)
        XCTAssertEqual(named("Big one", in: page)?.options?.count, 1000)
        XCTAssertEqual(named("Big two", in: page)?.options?.count, 700)
    }

    /// A secret in a custom control, and text a component slots into its
    /// text field, reach no neighbour (review round 10).
    @MainActor
    func testSlottedWritingAndSecretsInCustomControlsReachNoNeighbour() async throws {
        let page = try await observe("https://site-28.test/")
        XCTAssertNotNil(named("Go", in: page))
        XCTAssertNotNil(named("Save draft", in: page))
        XCTAssertFalse(page.elements.contains { element in
            [element.name, element.text, element.context ?? "", element.heading ?? ""].contains {
                $0.contains("secret") || $0.contains("Private draft") || $0.contains("Unrendered")
            }
        })
    }

    /// A hidden field's secret cannot become another element's name through
    /// aria-labelledby: a field is judged sensitive whether it is shown or not
    /// (review round 11).
    @MainActor
    func testAHiddenSecretNeverBecomesAName() async throws {
        let page = try await observe("https://site-28.test/")
        XCTAssertNotNil(named("Unlock", in: page))
        XCTAssertFalse(page.elements.contains { $0.name.contains("secret") || $0.text.contains("secret") })
    }

    /// An image's words count as they are shown: an image hidden, or inside a
    /// sensitive field, names nothing (review round 12).
    @MainActor
    func testAnImageInAHiddenOrSensitiveFieldNamesNothing() async throws {
        let page = try await observe("https://site-28.test/")
        XCTAssertFalse(page.elements.contains { $0.name.contains("SECRET") || $0.text.contains("SECRET") })
    }

    /// A control inside a sensitive field is part of it and is not reported
    /// with its own words — an image button's alt, a button's aria-label
    /// (review round 13).
    @MainActor
    func testAControlInsideASensitiveFieldIsNotReported() async throws {
        let page = try await observe("https://site-28.test/")
        XCTAssertFalse(page.elements.contains { $0.name.contains("SECRET") || $0.text.contains("SECRET") })
    }

    /// A submit button inside a sensitive field never names its form: no
    /// reported word — name, text, row, heading or submit label — comes from
    /// it (review round 14).
    @MainActor
    func testASubmitButtonInsideASensitiveFieldNeverNamesItsForm() async throws {
        let page = try await observe("https://site-28.test/")
        XCTAssertNotNil(named("Email", in: page))
        XCTAssertFalse(page.elements.contains { element in
            [element.name, element.text, element.context ?? "", element.heading ?? "",
             element.formSubmitLabel ?? ""].contains { $0.contains("SECRET") }
        })
    }

    /// A submit button that is itself sensitive never names its form either
    /// (review round 15).
    @MainActor
    func testASensitiveSubmitButtonNeverNamesItsForm() async throws {
        let page = try await observe("https://site-28.test/")
        let email = try XCTUnwrap(named("Work email", in: page))
        XCTAssertFalse((email.formSubmitLabel ?? "").contains("SECRET"))
    }

    /// A label a component draws in its shadow root still says what a field
    /// is for: the page asks for a sign-in (review round 15). The field,
    /// marked secret by no structure, shows what it holds (owner decision of
    /// 2026-10-03).
    @MainActor
    func testALabelDrawnInAShadowRootStillNamesASignIn() async throws {
        let (page, json) = try await observed("https://site-30.test/")
        XCTAssertTrue(page.flags.loginForm)
        XCTAssertTrue(json.contains("SECRET-SHADOW"))
    }

    /// A label a component fills through a slot still says what a field is
    /// for — a native label or an aria-labelledby one — on a page with no
    /// other secret (review round 16). The field shows what it holds (owner
    /// decision of 2026-10-03).
    @MainActor
    func testASlottedLabelStillNamesASignIn() async throws {
        for address in ["https://site-31.test/", "https://site-32.test/"] {
            let (page, json) = try await observed(address)
            XCTAssertTrue(page.flags.loginForm, address)
            XCTAssertTrue(json.contains("SECRET-SLOT"), address)
        }
    }

    /// A label's words keep their boundaries however the page draws them —
    /// through a component's slot, split across tags, or held in markup no
    /// slot shows — so a short word like "OTP" still names a sign-in (review
    /// round 17). The field shows what it holds (owner decision of
    /// 2026-10-03).
    @MainActor
    func testALabelsWordsKeepTheirBoundaries() async throws {
        for address in ["https://site-33.test/", "https://site-34.test/", "https://site-35.test/",
                        "https://site-36.test/"] {
            let (page, json) = try await observed(address)
            XCTAssertTrue(page.flags.loginForm, address)
            XCTAssertTrue(json.contains("SECRET-"), address)
        }
    }

    /// Every seam is read both ways at once — where one tag's text meets the
    /// next, or at an invisible character such as a soft hyphen — and a word
    /// held in a nested component that no slot shows still counts (review
    /// round 18). The field shows what it holds (owner decision of
    /// 2026-10-03).
    @MainActor
    func testEverySeamIsReadBothWays() async throws {
        for address in ["https://site-37.test/", "https://site-38.test/", "https://site-39.test/"] {
            let (page, json) = try await observed(address)
            XCTAssertTrue(page.flags.loginForm, address)
            XCTAssertTrue(json.contains("SECRET-"), address)
        }
    }

    /// A short word names a secret only standing alone: "otp" inside "Hotpot"
    /// — even split across tags — or "shotput" flags nothing, and the field is
    /// still reported (review round 18).
    @MainActor
    func testAShortWordInsideALongerOneFlagsNothing() async throws {
        let page = try await observe("https://site-40.test/")
        XCTAssertFalse(page.flags.loginForm)
        XCTAssertFalse(page.flags.paymentForm)
        XCTAssertTrue(page.elements.contains { $0.role == "textbox" }, "the field is ordinary and reported")
    }

    /// A component's own drawing never breaks the words its markup holds
    /// ("Pass" and a component holding "word" that draws only "*"), and
    /// "MM / YY" reads as the expiry it is however its tags fall (review
    /// round 19). The fields show what they hold (owner decision of
    /// 2026-10-03).
    @MainActor
    func testMarkupWordsAndSpacedShortWordsStayWhole() async throws {
        let (tail, tailJSON) = try await observed("https://site-41.test/")
        XCTAssertTrue(tail.flags.loginForm)
        XCTAssertTrue(tailJSON.contains("SECRET-TAIL"))
        let (expiry, expiryJSON) = try await observed("https://site-42.test/")
        XCTAssertTrue(expiry.flags.paymentForm)
        XCTAssertTrue(expiryJSON.contains("SECRET-EXPIRY"))
    }

    /// A label's words come from everything that names a field — markup a
    /// slot shows but a component does not draw, an image's alt text, an
    /// element named by aria-label — and never from a component's stylesheet
    /// (review round 20). The field shows what it holds (owner decision of
    /// 2026-10-03).
    @MainActor
    func testEverySourceOfALabelsWordsIsRead() async throws {
        for address in ["https://site-43.test/", "https://site-44.test/", "https://site-45.test/",
                        "https://site-46.test/"] {
            let (page, json) = try await observed(address)
            XCTAssertTrue(page.flags.loginForm, address)
            XCTAssertTrue(json.contains("SECRET-"), address)
        }
    }

    /// A control's own contents are not words about a field: a topic select
    /// offering "Reset password" flags nothing, and the page's fields are
    /// reported (review round 20).
    @MainActor
    func testAControlsContentsAreNotLabelWords() async throws {
        let page = try await observe("https://site-47.test/")
        XCTAssertFalse(page.flags.loginForm)
        XCTAssertTrue(page.elements.contains { $0.role == "textbox" }, "the field is ordinary and reported")
    }

    /// The usual English names of a secret say what their field asks for
    /// however they are written — "CVV2", "MM/YYYY", "Card #",
    /// "Authenticator code", "PIN", "Passphrase" — each on a page with no
    /// other secret (review round 20); the field shows what it holds (owner
    /// decision of 2026-10-03).
    @MainActor
    func testTheUsualNamesOfASecretAreKnown() async throws {
        let payment = ["CVV2", "CVC2", "MM/YYYY", "Card #", "Card No.", "cardNo", "debitCardNo"]
        let password = ["Authenticator code", "PIN", "Passphrase"]
        for label in payment + password {
            let query = try XCTUnwrap(label.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
            let page = try await observe("https://site-49.test/?label=\(query)")
            let flagged = payment.contains(label) ? page.flags.paymentForm : page.flags.loginForm
            XCTAssertTrue(flagged, label)
            XCTAssertTrue(page.elements.contains { $0.role == "textbox" }, "the field is reported: \(label)")
        }
    }

    /// "Gift card note" names no card number: the field is ordinary and
    /// reported (review round 20).
    @MainActor
    func testAGiftCardNoteIsNotACardNumber() async throws {
        let page = try await observe("https://site-49.test/?label=Gift%20card%20note")
        XCTAssertFalse(page.flags.paymentForm)
        XCTAssertTrue(page.elements.contains { $0.role == "textbox" }, "the field is ordinary and reported")
    }

    /// "Card No" keeps its word end wherever the page breaks after it — a
    /// seam before "Required" drawn on its own line — so the field is a card
    /// number (review round 21), shown as any field is (owner decision of
    /// 2026-10-03).
    @MainActor
    func testCardNoBeforeASeamIsACardNumber() async throws {
        let page = try await observe("https://site-50.test/")
        XCTAssertTrue(page.flags.paymentForm)
        XCTAssertTrue(page.elements.contains { $0.role == "textbox" }, "the card field is reported")
    }

    /// The limit counts the words as the page wrote them, before "#" is read
    /// as "number": a label of 20,000 "#" is read in full, names no secret,
    /// and the field is reported (review round 21).
    @MainActor
    func testTheLimitCountsTheWordsAsThePageWroteThem() async throws {
        let page = try await observe("https://site-51.test/")
        XCTAssertFalse(page.flags.paymentForm)
        XCTAssertTrue(page.elements.contains { $0.role == "textbox" }, "the field is ordinary and reported")
    }

    // MARK: - Shadow DOM, dialogs, hostile text

    @MainActor
    func testOpenShadowRootsAreSeenAndClosedOnesAreNot() async throws {
        let page = try await observe("https://site-11.test/")
        let inner = named("Shadow action", in: page)
        XCTAssertEqual(inner?.role, "button")
        XCTAssertEqual(inner?.region, .main)
        XCTAssertEqual(inner?.heading, "Components")
        XCTAssertNil(named("Closed action", in: page))
    }

    @MainActor
    func testACookieBannerIsADialog() async throws {
        let page = try await observe("https://site-3.test/")
        for name in ["Reject all", "Necessary only", "Accept all"] {
            XCTAssertEqual(named(name, in: page)?.region, .dialog, name)
        }
        XCTAssertEqual(named("Meeting recorder without a bot", in: page)?.region, .main)
    }

    /// A control in a dialog carries that dialog's own words, as a person
    /// reads them — what tells a cookie window (ITER-076 stage 3, № 98); a
    /// control outside any dialog carries none.
    @MainActor
    func testAControlInADialogCarriesTheDialogsOwnWords() async throws {
        let page = try await observe("https://site-3.test/")
        for name in ["Reject all", "Necessary only", "Accept all"] {
            let words = try XCTUnwrap(named(name, in: page)?.dialogText, name)
            XCTAssertTrue(words.contains("We use cookies to improve the site."), "\(name): \(words)")
        }
        XCTAssertNil(named("Meeting recorder without a bot", in: page)?.dialogText)
    }

    /// A cookie window's switches carry whether they are on and whether a person can change them, and a control that
    /// shows or hides a part of the page whether that part is shown (2026-10-21): what tells a necessary switch, and
    /// a category's header from a choice. A switch drawn by its label is reported as its switch; anything else says
    /// neither.
    @MainActor
    func testACookieWindowsSwitchesSayWhetherTheyCanChangeAndItsHeadersWhetherTheyAreOpen() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-520.test/?on=targeting")!)
        try await bridge.waitUntilLoaded(tab)
        _ = try await bridge.run("document.getElementById('settings').click(); 'ok'", in: tab)
        let page = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        let switches = page.elements.filter { $0.role == "switch" }
        XCTAssertEqual(switches.map(\.name), ["Targeting Cookies", "Functional Cookies", "Performance Cookies"])
        XCTAssertEqual(switches.map(\.checked), [true, false, false])
        XCTAssertEqual(switches.map(\.disabled), [false, false, false])
        XCTAssertTrue(switches.allSatisfy { $0.region == .dialog && ($0.dialogText ?? "").contains("Preference Center") },
                      "\(switches)")
        let headers = page.elements.filter { $0.expanded != nil }
        XCTAssertEqual(headers.map(\.name), ["Targeting Cookies", "Functional Cookies", "Performance Cookies",
                                             "Strictly Necessary Cookies Always Active"])
        XCTAssertEqual(headers.map(\.role), ["button", "button", "button", "button"])
        XCTAssertEqual(headers.map(\.expanded), [false, false, false, false])
        let save = try XCTUnwrap(named("Confirm My Choices", in: page))
        XCTAssertNil(save.expanded)
        XCTAssertNil(save.disabled, "a button says nothing of it")

        let other = try await bridge.openTab(URL(string: "https://site-521.test/")!)
        try await bridge.waitUntilLoaded(other)
        _ = try await bridge.run("document.getElementById('customize').click(); 'ok'", in: other)
        let boxes = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: other)).elements
            .filter { $0.role == "checkbox" }
        XCTAssertEqual(boxes.map(\.name), ["Session", "Analytics", "Marketing"])
        XCTAssertEqual(boxes.map(\.checked), [true, false, true])
        XCTAssertEqual(boxes.map(\.disabled), [true, false, false])
    }

    /// A field of a GET form carries that form's own query as a browser
    /// writes it — its hidden fields as they are, in order, and the field's
    /// own place — and whether it sits in the page's search landmark: what
    /// D4 builds a search's address from (ITER-076 stage 3). A hidden field
    /// is never an element.
    @MainActor
    func testAFieldOfAGetFormCarriesItsFormsQueryAndItsSearchLandmark() async throws {
        let search = try await observe("https://site-415.test/")
        let box = try XCTUnwrap(named("Search", in: search).flatMap { $0.role == "searchbox" ? $0 : nil })
        XCTAssertEqual(box.formEntries, [.init(name: "src", value: "hp & home"), .init(name: "q", value: nil)])
        XCTAssertNotEqual(box.inSearch, true, "no landmark on this page")
        XCTAssertFalse(search.elements.contains { $0.inputType == "hidden" }, "a hidden field is no element")
        XCTAssertNil(named("Search", in: search).flatMap { $0.role == "button" ? $0 : nil }?.formEntries,
                     "a button carries none")
        let google = try await observe("https://site-403.test/")
        let textarea = try XCTUnwrap(google.elements.first { $0.role == "combobox" && $0.name == "Search" })
        XCTAssertEqual(textarea.formEntries, [.init(name: "q", value: nil)])
        XCTAssertEqual(textarea.inSearch, true, "a form of role search")
        let post = try await observe("https://site-5.test/")
        XCTAssertNil(post.elements.first { $0.role == "textbox" }?.formEntries, "a POST form's field carries none")
    }

    /// Hidden instructions are not elements, and visible ones are only data.
    @MainActor
    func testHiddenInstructionsNeverBecomeElements() async throws {
        let page = try await observe("https://site-9.test/")
        XCTAssertFalse(page.elements.contains { $0.name.contains("SYSTEM") || $0.text.contains("SYSTEM") })
        XCTAssertFalse(page.elements.contains { $0.name.contains("allowed to pay") })
        XCTAssertEqual(named("Delete account", in: page)?.href, "https://site-9.test/account/delete")
        // A link whose address is its script is a button: a click runs the
        // page's own script, and no `javascript:` address is ever opened
        // (§6.2; ITER-076 I-10, critic 12).
        XCTAssertEqual(named("Run script", in: page)?.role, "button")
        XCTAssertNil(named("Run script", in: page)?.href)
    }
}

/// ITER-076 I-09, round 5 — owner decision of 2026-10-03: a field's words
/// never hide it; the words that name a sign-in or a payment still say what
/// the agent must leave to the user.
extension ObserverFormsTests {

    /// A field whose words cannot be read — too many to read — gives no
    /// payment evidence, and nothing more: the page was read whole, the field
    /// reports what it holds, the select beside it lists its options, and its
    /// form is no card form.
    @MainActor
    func testAFieldWhoseWordsCannotBeReadGivesNoPaymentEvidenceAndKeepsItsValue() async throws {
        let page = try await observe("https://site-293.test/")
        XCTAssertFalse(page.truncated)
        XCTAssertFalse(page.flags.paymentForm)
        XCTAssertFalse(page.flags.loginForm)
        let field = try XCTUnwrap(page.elements.first { $0.role == "textbox" }, "\(page.elements.map(\.name))")
        XCTAssertEqual(field.value, "4000 1234")
        XCTAssertEqual(named("Topic", in: page)?.options, ["First topic", "Second topic"])
        XCTAssertEqual(named("Send", in: page)?.touchesSecret, false)
    }

    /// A frame the page's words name — a label around it reads "Card number",
    /// its title "Password" — while it holds a field still says what the page
    /// asks for: a payment and a sign-in, the user's part; the controls of
    /// its form, and with none every control outside a form, could send them.
    /// Its field is marked by nothing of its own: the frame's own look reports
    /// what it holds.
    @MainActor
    func testAFrameThePagesWordsNameStillSaysWhatThePageAsksFor() async throws {
        let page = try await observe("https://site-295.test/")
        XCTAssertTrue(page.flags.paymentForm, "the label around the frame in the form")
        XCTAssertTrue(page.flags.loginForm, "the frame's own title")
        XCTAssertEqual(named("Pay", in: page)?.touchesSecret, true)
        XCTAssertEqual(named("Help", in: page)?.touchesSecret, true)
    }

    /// A card form its words alone name — no autocomplete, no type — is still
    /// a payment, the user's part: its button is handed over as one, never
    /// pressed.
    @MainActor
    func testACardFormWithoutCardAttributesIsStillThePaymentHandOver() async throws {
        let page = try await observe("https://site-294.test/")
        XCTAssertTrue(page.flags.paymentForm)
        XCTAssertEqual(named("Pay", in: page)?.touchesSecret, true)
        let bridge = WebViewBridge()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.operation == .click && $0.action.target?.name == "Pay" }
                ?? request.candidates.first { $0.action.operation == .done })
        })
        let plan = try XCTUnwrap(AgentPlan(goal: "Pay", subgoals: [.init(description: "Pay", terms: ["pay"])],
                                           searches: [URL(string: "https://site-294.test/")!], columns: ["Name"],
                                           sheetTitle: "Page", rowsWanted: 1, emptyCell: "n/a"))
        let record = await AgentRun(plan: plan, errandID: UUID(),
                                    collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                         sheet: FixtureSheet(), confirm: { _ in .yes })).run()
        XCTAssertEqual(record.ending, .needsUser, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.handover(.payment, host: "site-294.test")), "\(record.eventLines)")
        XCTAssertFalse(record.steps.contains { $0.outcome == .acted }, "nothing pressed: \(record.eventLines)")
    }

    // MARK: - ITER-076 stage 7: a form as one whole (№ 69)

    /// Each field says what the page's structure says of it — its
    /// autocomplete, whether it is required — and the group it is part of:
    /// its form. Its submit button is in that group too. What a field holds
    /// is known by a digest of it, exact, beside the value a person sees.
    @MainActor
    func testAFormsFieldsSayTheirAutocompleteWhetherRequiredAndTheirGroup() async throws {
        let page = try await observe("https://site-440.test/")
        let first = try XCTUnwrap(named("First name", in: page))
        XCTAssertEqual(first.autocomplete, "given-name")
        XCTAssertEqual(first.required, true)
        XCTAssertEqual(named("Last name", in: page)?.required, false)
        XCTAssertEqual(named("Work email", in: page)?.autocomplete, nil)
        XCTAssertEqual(named("Work email", in: page)?.inputType, "email")
        XCTAssertEqual(named("Company", in: page)?.autocomplete, "organization")
        let group = try XCTUnwrap(first.group, "a field of a form is in its form's group")
        for name in ["Last name", "Work email", "Company", "Phone", "How can we help?", "Request a demo"] {
            XCTAssertEqual(named(name, in: page)?.group, group, name)
        }
        XCTAssertNil(named("Request a demo", in: page)?.autocomplete)
        XCTAssertNil(named("Request a demo", in: page)?.required)
        XCTAssertNil(named("Request a demo", in: page)?.valueKey, "a button holds no value")
        let empty = try XCTUnwrap(first.valueKey)
        XCTAssertEqual(named("Last name", in: page)?.valueKey, empty, "two empty fields hold the same: nothing")
    }

    /// The digest follows the value exactly, to its last character and
    /// space, whatever the report's value shows: a value longer than the
    /// report holds, or one that differs only in its spaces, is another.
    @MainActor
    func testAFieldsValueKeyFollowsItsExactValue() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-440.test/")!)
        try await bridge.waitUntilLoaded(tab)
        func key(after script: String) async throws -> String? {
            _ = try await bridge.run(script, in: tab)
            let page = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
            return page.elements.first { $0.name == "How can we help?" }?.valueKey
        }
        let long = String(repeating: "a", count: 300)
        let one = try await key(after: "document.getElementById('message').value = '\(long)'; 'ok'")
        let other = try await key(after: "document.getElementById('message').value = '\(long)b'; 'ok'")
        let spaced = try await key(after: "document.getElementById('message').value = '\(long)  b'; 'ok'")
        let again = try await key(after: "document.getElementById('message').value = '\(long)'; 'ok'")
        XCTAssertNotNil(one)
        XCTAssertNotEqual(one, other, "a change past the report's 200 characters")
        XCTAssertNotEqual(other, spaced, "a change in the spaces alone")
        XCTAssertEqual(one, again)
        // The app's port of the digest gives the page's own key, to the last
        // UTF-16 unit of a text beyond Latin.
        XCTAssertEqual(one, FormFill.digest(long))
        let world = try await key(after: "document.getElementById('message').value = 'Zoë 😀 — 東京\\n'; 'ok'")
        XCTAssertEqual(world, FormFill.digest("Zoë 😀 — 東京\n"))
        let empty = try await key(after: "document.getElementById('message').value = ''; 'ok'")
        XCTAssertEqual(empty, FormFill.digest(""))
    }

    /// Review round 1, C5: a list's key is of what it sends — its chosen
    /// option's value — not of the words it shows: an option whose value the
    /// page changes under the same words is another choice; one that sends
    /// nothing has the key of nothing.
    @MainActor
    func testAListsValueKeyIsOfTheValueItSends() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-443.test/")!)
        try await bridge.waitUntilLoaded(tab)
        func key(after script: String) async throws -> String? {
            _ = try await bridge.run(script, in: tab)
            let page = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
            return page.elements.first { $0.name == "Country" }?.valueKey
        }
        let none = try await key(after: "'ok'")
        XCTAssertEqual(none, FormFill.digest(""), "the placeholder sends nothing")
        let germany = try await key(after: "document.getElementById('country').selectedIndex = 1; 'ok'")
        let changed = try await key(after: "document.getElementById('country').options[1].value = 'FR'; 'ok'")
        XCTAssertEqual(germany, FormFill.digest("Germany"))
        XCTAssertNotEqual(germany, changed, "the same words, another value sent")
        XCTAssertEqual(changed, FormFill.digest("FR"))
    }

    /// A form a script gathers without a form tag, as a React page draws one
    /// (a reference browser agent's `fieldScope`): its fields and its button
    /// are one group — the box that holds them — and a search box in the
    /// page's header is no part of it.
    @MainActor
    func testAFormWithoutAFormTagIsTheGroupOfTheBoxThatHoldsItsFields() async throws {
        let page = try await observe("https://site-441.test/")
        let group = try XCTUnwrap(named("Full name", in: page)?.group)
        for name in ["Email", "Company", "Message", "Book my demo"] {
            XCTAssertEqual(named(name, in: page)?.group, group, name)
        }
        XCTAssertNil(named("Full name", in: page)?.formMethod, "no form tag")
        XCTAssertNotEqual(named("Find", in: page)?.group, group, "the header's search box is another")
    }
}

/// Owner decision 4 (2026-09-29): a secret field is hidden and the errand goes
/// on; a step stops only where it could send one. 2026-10-20, a blind errand: a
/// practice form's empty password handed its first field over as a sign-in. An
/// empty password sends no secret.
extension ObserverFormsTests {

    /// A practice form — a user name, an empty password, a comment, a file,
    /// boxes, radios, a list, its two buttons — is the errand's: none of its
    /// controls could send a secret. The password stays withheld, and the page
    /// still asks for a sign-in.
    @MainActor
    func testAnEmptyPasswordLeavesTheRestOfItsFormToTheErrand() async throws {
        let page = try await observe("https://site-497.test/")
        XCTAssertNil(named("Password", in: page), "withheld")
        XCTAssertFalse(page.elements.contains { $0.inputType == "password" })
        XCTAssertTrue(page.flags.loginForm)
        for name in ["Username", "Comments", "Filename", "Checkbox 1", "Radio 1", "Dropdown", "cancel", "submit"] {
            XCTAssertEqual(named(name, in: page)?.touchesSecret, false, name)
        }
    }

    /// What could send a secret walls every control of its form as before: the
    /// password typed in; a card's field, empty — marked by its structure, or
    /// only its words call it one (owner decision of 2026-10-03: payment is the
    /// user's part); a frame of another origin, whose content is not known;
    /// more controls than a form is read to. The password stays withheld and
    /// its value reaches no report; the link outside the form stays free.
    @MainActor
    func testWhatCouldSendASecretStillWallsTheWholeForm() async throws {
        for variant in ["filled", "card", "cvc", "frame", "big"] {
            let (page, json) = try await observed("https://site-497.test/?\(variant)")
            XCTAssertNil(named("Password", in: page), variant)
            XCTAssertFalse(json.contains("hunter2-practice"), variant)
            for name in ["Username", "Comments", "Checkbox 1", "submit"] {
                XCTAssertEqual(named(name, in: page)?.touchesSecret, true, "\(variant): \(name)")
            }
            XCTAssertEqual(named("Help", in: page)?.touchesSecret, false, variant)
        }
    }

    /// A field only its words call a sign-in's — "Backup code", empty — is
    /// that sign-in's own field: the user's to fill, as a withheld one is. It
    /// sends nothing empty, so the form's other controls stay the errand's.
    @MainActor
    func testAFieldNamedASignInsIsTheUsersAndLeavesTheRestOfItsForm() async throws {
        let page = try await observe("https://site-497.test/?code")
        XCTAssertEqual(named("Backup code", in: page)?.touchesSecret, true)
        XCTAssertEqual(named("Backup code", in: page)?.value, "", "shown, as a person sees it")
        for name in ["Username", "submit"] {
            XCTAssertEqual(named(name, in: page)?.touchesSecret, false, name)
        }
    }

    /// D4 (ITER-076 stage 3, № 81) opens a search by the address code builds
    /// only from a form that holds no password: a search form that holds one,
    /// empty, sends no secret — its controls touch none — and is still no pure
    /// search: its field carries no query to build, and its search is asked
    /// about as any form's. The plain search beside it is one.
    @MainActor
    func testASearchFormHoldingAnEmptyPasswordIsNoPureSearch() async throws {
        let page = try await observe("https://site-498.test/")
        let locked = try XCTUnwrap(named("Find a guide", in: page))
        let find = try XCTUnwrap(named("Find", in: page))
        XCTAssertFalse(locked.touchesSecret)
        XCTAssertFalse(find.touchesSecret)
        XCTAssertNil(locked.formEntries)
        let typed = [locked.fingerprint: "voice notes"]
        XCTAssertNil(SafetyGuard.searchAddress(typedInto: locked, on: page, typed: typed))
        let press = AgentAction(operation: .click, target: find, destination: nil, payload: nil, isPlannedSearch: false)
        XCTAssertNil(SafetyGuard.searchAddress(for: press, on: page, typed: typed))
        let plain = try XCTUnwrap(named("Search the site", in: page))
        XCTAssertEqual(SafetyGuard.searchAddress(typedInto: plain, on: page, typed: [plain.fingerprint: "voice notes"])?
            .absoluteString, "https://site-498.test/search?q=voice+notes")
    }

    /// A form that needs its secret field — its autocomplete names it the
    /// sign-in's own password, a new one or a code, or it is `required` or
    /// `aria-required` — and holds it empty sends no secret: no control of it
    /// touches one, and its e-mail is the errand's to type. It needs one,
    /// though, and every control of it says so: a press of it is the user's
    /// sign-in (2026-10-21). A required field that is no secret — the e-mail —
    /// needs nothing of the user's, and the practice form's optional password
    /// leaves its form needing none.
    @MainActor
    func testAFormThatNeedsItsEmptySecretFieldSaysSo() async throws {
        for (variant, press) in [("", "Sign in"), ("?required", "Sign in"), ("?aria", "Sign in"),
                                 ("?new", "Create account"), ("?otp", "Verify")] {
            let page = try await observe("https://site-499.test/\(variant)")
            XCTAssertNil(page.elements.first { ["Password", "Code"].contains($0.name) }, "\(variant): withheld")
            let send = try XCTUnwrap(named(press, in: page), variant)
            XCTAssertEqual(send.touchesSecret, false, variant)
            XCTAssertEqual(send.formNeedsSecret, true, variant)
            XCTAssertEqual(named("Help", in: page)?.formNeedsSecret, false, "\(variant): a link")
        }
        let signIn = try await observe("https://site-499.test/")
        XCTAssertEqual(named("Email", in: signIn)?.touchesSecret, false)
        XCTAssertEqual(named("Email", in: signIn)?.formNeedsSecret, true, "every control of the form says so")
        let practice = try await observe("https://site-497.test/")
        for name in ["Username", "Comments", "submit"] {
            XCTAssertEqual(named(name, in: practice)?.formNeedsSecret, false, name)
        }
        let filled = try await observe("https://site-499.test/?filled")
        XCTAssertEqual(named("Sign in", in: filled)?.touchesSecret, true, "typed in, it could be sent: the wall")
    }
}
