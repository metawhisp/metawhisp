import XCTest
@testable import MetaWhisp

/// The app turns a page into complete candidate actions — operation, target,
/// parameters — so a model only ever picks one and never invents a parameter
/// (ITER-074 §6.2).
final class CandidateBuilderTests: XCTestCase {

    private func element(_ index: Int, role: String = "link", name: String, href: String? = nil,
                         region: PageRegion = .main, inViewport: Bool = true, heading: String? = nil,
                         context: String? = nil, options: [String]? = nil) -> ObservedElement {
        ObservedElement(index: index, role: role, name: name, text: name, href: href, inputType: nil,
                        heading: heading, region: region, inViewport: inViewport, context: context,
                        formAction: nil, formMethod: nil, formSubmitLabel: nil, options: options,
                        checked: nil)
    }

    private func page(_ elements: [ObservedElement]) -> ObservedPage {
        ObservedPage(url: "https://search.test/?q=x", title: "Results", truncated: false, flags: .none,
                     elements: elements)
    }

    private let context = CandidateContext(subgoalTerms: ["competitors", "voice", "notes"])

    // MARK: - Operations and parameters

    /// ITER-076 2.3: a control with no name is never offered — nothing can
    /// judge what it does, and nobody could say yes to it.
    func testANamelessControlIsNeverOffered() {
        let elements = [
            element(0, role: "button", name: ""),
            element(1, role: "link", name: " ", href: "https://site-1.test/"),
            element(2, role: "textbox", name: ""),
            element(3, role: "button", name: "Next"),
        ]
        let set = CandidateBuilder.build(page: page(elements), context: context)
        let offered = set.candidates.compactMap { $0.action.target?.name }
        XCTAssertEqual(offered, ["Next"])
    }

    /// Review of 2.3: a name made only of invisible characters is no name.
    func testANameOfOnlyInvisibleCharactersIsNoName() {
        let set = CandidateBuilder.build(page: page([
            element(0, role: "button", name: "\u{200B}"),
            element(1, role: "button", name: "\u{2060}\u{00A0}\u{FEFF}\u{00AD}"),
            element(2, role: "button", name: "Next"),
            // Blank-looking characters that are neither spaces nor format
            // characters (review of 2.3, round 2).
            element(3, role: "button", name: "\u{3164}"),
            element(4, role: "button", name: "\u{2800}\u{034F}\u{115F}\u{FFA0}"),
        ]), context: context)
        XCTAssertEqual(set.candidates.compactMap { $0.action.target?.name }, ["Next"])
    }

    /// Review of 2.3: which option a select shows is never reported, so the
    /// loop keeps what it chose itself. The option this errand chose on this
    /// page and saw held is not offered again; the select's other options
    /// are, and so is the same option in another select.
    func testAnOptionThisErrandChoseIsNotOfferedAgain() {
        let billing = element(0, role: "combobox", name: "Billing period", options: ["Monthly", "Yearly"])
        let renewal = element(1, role: "combobox", name: "Renewal", options: ["Yearly", "Never"])
        let set = CandidateBuilder.build(page: page([billing, renewal]), context: CandidateContext(
            subgoalTerms: [], chosenOptions: [billing.fingerprint: "Yearly"]))
        let offered = set.candidates.filter { $0.action.operation == .select }
            .map { "\($0.action.target?.name ?? ""): \($0.action.payload ?? "")" }
        XCTAssertEqual(Set(offered), ["Billing period: Monthly", "Renewal: Yearly", "Renewal: Never"])
    }

    func testALinkBecomesAnOpenOfItsOwnAddress() {
        let set = CandidateBuilder.build(page: page([element(0, name: "Site One", href: "https://site-1.test/")]),
                                         context: context)
        let open = set.candidates.first { $0.action.operation == .open }
        XCTAssertEqual(open?.action.destination, "https://site-1.test/")
        XCTAssertEqual(open?.action.target?.name, "Site One")
        XCTAssertEqual(open?.action.isPlannedSearch, false)
    }

    /// Owner default 3.3 (ITER-076 stage 3, № 100): an anchor with a real web
    /// address opens by going to it, whatever role the page gives it — a menu
    /// item, a button, an option — and a control inside one; so a menu link
    /// in a whole-page POST form is no click that may send that form. One
    /// whose address is a place on its own page — a tab's panel — is clicked:
    /// its page's script shows the panel; so is a control with no address.
    func testAnAnchorWithARealAddressOpensByGoingToItWhateverItsRole() {
        var menu = element(0, role: "menuitem", name: "Products", href: "https://search.test/products")
        menu = ObservedElement(index: 0, role: "menuitem", name: "Products", text: "Products",
                               href: "https://search.test/products", inputType: nil, heading: nil, region: .nav,
                               inViewport: true, context: nil, formAction: "https://search.test/default.aspx",
                               formMethod: "post", formSubmitLabel: nil, options: nil, checked: nil)
        let elements = [menu,
                        element(1, role: "button", name: "Pricing", href: "https://search.test/pricing"),
                        element(2, role: "tab", name: "Reviews", href: "https://search.test/?q=x#reviews"),
                        element(3, role: "button", name: "Show more")]
        let set = CandidateBuilder.build(page: page(elements), context: context)
        let action = { (name: String) in set.candidates.first { $0.action.target?.name == name }?.action }
        XCTAssertEqual(action("Products")?.operation, .open)
        XCTAssertEqual(action("Products")?.destination, "https://search.test/products")
        XCTAssertNil(SafetyGuard.structuralReason(of: try! XCTUnwrap(action("Products")), pageURL: "https://search.test/"),
                     "no form a click would send")
        XCTAssertEqual(action("Pricing")?.operation, .open)
        XCTAssertEqual(action("Pricing")?.destination, "https://search.test/pricing")
        XCTAssertEqual(action("Reviews")?.operation, .click, "a place on its own page")
        XCTAssertEqual(action("Show more")?.operation, .click, "no address")
    }

    /// ITER-076 (2026-10-07): a link to a place on its own page is clicked, as
    /// owner default 3.3 clicks any other control's — its page's script shows
    /// the place; a link to another page, its fragment or not, is opened.
    func testALinkToAPlaceOnItsOwnPageIsClicked() {
        let set = CandidateBuilder.build(page: page([
            element(0, name: "Request a demo", href: "https://search.test/?q=x#demo"),
            element(1, name: "Products", href: "https://search.test/products#top"),
        ]), context: context)
        let action = { (name: String) in set.candidates.first { $0.action.target?.name == name }?.action }
        XCTAssertEqual(action("Request a demo")?.operation, .click)
        XCTAssertEqual(action("Products")?.operation, .open)
        XCTAssertEqual(action("Products")?.destination, "https://search.test/products#top")
    }

    /// `javascript:`, `mailto:` and other non-web links are neither opened
    /// nor clicked (§6.2).
    func testNonWebLinksAreNotCandidates() {
        let set = CandidateBuilder.build(page: page([
            element(0, name: "Run script", href: "javascript:alert(1)"),
            element(1, name: "Write to us", href: "mailto:someone@example.com")
        ]), context: context)
        XCTAssertFalse(set.candidates.contains { $0.action.target != nil })
    }

    func testControlsBecomeTheirOperations() {
        let set = CandidateBuilder.build(page: page([
            element(0, role: "button", name: "Show more"),
            element(1, role: "searchbox", name: "Search the docs"),
            element(2, role: "checkbox", name: "Remember me")
        ]), context: context)
        XCTAssertEqual(set.candidates.first { $0.action.target?.name == "Show more" }?.action.operation, .click)
        XCTAssertEqual(set.candidates.first { $0.action.target?.name == "Search the docs" }?.action.operation, .type)
        XCTAssertEqual(set.candidates.first { $0.action.target?.name == "Remember me" }?.action.operation, .click)
    }

    /// A select becomes one candidate per option. Which one it shows now is
    /// never reported (ITER-076 2.3), so that one is offered too.
    func testASelectOffersEveryOption() {
        let set = CandidateBuilder.build(page: page([
            element(0, role: "combobox", name: "Billing period", options: ["Monthly", "Yearly"])
        ]), context: context)
        let selects = set.candidates.filter { $0.action.operation == .select }
        XCTAssertEqual(selects.map(\.action.payload), ["Monthly", "Yearly"])
    }

    /// On a tab with history to go back to (ITER-076 I-10).
    func testPageLevelActionsAreAlwaysOffered() {
        var backed = context
        backed.canGoBack = true
        let set = CandidateBuilder.build(page: page([]), context: backed)
        let operations = Set(set.candidates.map(\.action.operation))
        XCTAssertEqual(operations, [.scroll, .wait, .back, .done, .stuck])
    }

    /// ITER-076 I-10 (critic 22): BACK goes back in the tab's own history, so
    /// it is offered only when there is an entry to go back to — never on a
    /// first page.
    func testBackIsOfferedOnlyWhenTheTabCanGoBack() {
        var first = context
        first.canGoBack = false
        let without = CandidateBuilder.build(page: page(buttons(40)), context: first)
        XCTAssertFalse(without.candidates.contains { $0.action.operation == .back })
        XCTAssertEqual(Set(without.candidates.filter { $0.action.target == nil }.map(\.action.operation)),
                       [.scroll, .wait, .done, .stuck])
        first.canGoBack = true
        let with = CandidateBuilder.build(page: page(buttons(40)), context: first)
        XCTAssertTrue(with.candidates.contains { $0.action.operation == .back })
        XCTAssertEqual(with.candidates.filter { $0.action.target != nil }.count, 40)
    }

    /// A non-web address is neither opened nor clicked, whatever role the
    /// page gives the element (review round 6): a "button" that is a
    /// `file:` link would still leave the browser.
    func testANonWebAddressOffersNothingWhateverItsRole() {
        let set = CandidateBuilder.build(page: page([
            element(0, role: "button", name: "Continue", href: "javascript:alert(1)"),
            element(1, role: "menuitem", name: "Open the file", href: "file:///etc/hosts")
        ]), context: context)
        XCTAssertFalse(set.candidates.contains { $0.action.target != nil })
    }

    // MARK: - Twins

    /// Twin buttons cannot be told apart safely (§6.3), so none is offered;
    /// twin links go to the same place, so one is offered.
    func testTwinsAreOfferedOnlyWhenTheyAreOneDestination() {
        let set = CandidateBuilder.build(page: page([
            element(0, role: "button", name: "Remove"),
            element(1, role: "button", name: "Remove"),
            element(2, name: "Learn more", href: "https://a.test/more"),
            element(3, name: "Learn more", href: "https://a.test/more")
        ]), context: context)
        XCTAssertFalse(set.candidates.contains { $0.action.target?.name == "Remove" })
        XCTAssertEqual(set.candidates.filter { $0.action.target?.name == "Learn more" }.count, 1)
    }

    // MARK: - The whole visible page (ITER-076 stage 3, № 65, 68)

    /// Jev sees every control of the page, in page order — chrome, footer and
    /// main content as they stand — then the page-level operations; no
    /// «more», no planned search.
    func testEveryControlIsOfferedInPageOrder() {
        let set = CandidateBuilder.build(page: page([
            element(0, name: "Images", href: "https://search.test/images", region: .nav),
            element(1, name: "Below the fold", href: "https://a.test/1", inViewport: false),
            element(2, name: "Voice notes for teams", href: "https://site-1.test/", region: .main),
            element(3, name: "Next", href: "https://search.test/?page=2", region: .footer),
        ]), context: context)
        XCTAssertEqual(set.candidates.compactMap { $0.action.target?.name },
                       ["Images", "Below the fold", "Voice notes for teams", "Next"])
        XCTAssertEqual(set.candidates.filter { $0.action.target == nil }.map(\.action.operation),
                       [.scroll, .wait, .done, .stuck])
        XCTAssertFalse(set.candidates.contains { $0.action.operation == .more || $0.action.isPlannedSearch })
    }

    private func buttons(_ count: Int) -> [ObservedElement] {
        (0..<count).map { element($0, role: "button", name: "Action \($0)") }
    }

    /// A dense page is offered whole, up to 240 actions, in one question.
    func testEveryActionOfADensePageIsOfferedAtOnce() {
        let set = CandidateBuilder.build(page: page(buttons(40)), context: context)
        XCTAssertEqual(set.candidates.compactMap { $0.action.target?.name }, (0..<40).map { "Action \($0)" })
        XCTAssertFalse(set.candidates.contains { $0.action.operation == .more })
    }

    /// Past 240 actions, the ones on screen are kept first — what scrolling
    /// brought into view is offered — then the rest, the kept ones in page
    /// order.
    func testAtMost240ActionsTheOnesOnScreenKeptFirst() {
        XCTAssertEqual(CandidateBuilder.maxActions, 240)
        let links = (0..<300).map { index in
            element(index, name: "Link \(index)", href: "https://a.test/\(index)", inViewport: index >= 250)
        }
        let set = CandidateBuilder.build(page: page(links), context: context)
        let names = set.candidates.compactMap { $0.action.target?.name }
        XCTAssertEqual(names.count, 240)
        XCTAssertEqual(names, (0..<190).map { "Link \($0)" } + (250..<300).map { "Link \($0)" },
                       "the 50 on screen, then the first 190 of the rest, in page order")
        XCTAssertEqual(set.candidates.filter { $0.action.target == nil }.map(\.action.operation),
                       [.scroll, .wait, .done, .stuck])
    }

    /// Past 240 actions, after the ones on screen, the ones the sub-goal
    /// names — most of its terms first — are kept before the rest: an option
    /// deep in a made-up list of 300 stays within Jev's reach (Codex review 1
    /// of I-08, P2-4). The kept ones stay in page order.
    func testPast240ActionsTheOnesTheSubgoalNamesAreKeptAfterTheOnesOnScreen() {
        let options = (1...300).map { index in
            element(index, role: "option", name: "Size \(index)", inViewport: index <= 6)
        }
        let set = CandidateBuilder.build(page: page(options), context: CandidateContext(subgoalTerms: ["size", "250"]))
        let names = set.candidates.compactMap { $0.action.target?.name }
        XCTAssertEqual(names.count, 240)
        XCTAssertTrue(names.contains("Size 250"), "the option the sub-goal names")
        XCTAssertEqual(Array(names.prefix(6)), (1...6).map { "Size \($0)" }, "the ones on screen")
        let order = names.compactMap { Int($0.dropFirst("Size ".count)) }
        XCTAssertEqual(order, order.sorted(), "in page order")
    }

    /// Every option of a select can be chosen. The ones that match the
    /// subgoal come first, with the select; past the first five, the rest
    /// wait behind every other action on the page instead of crowding it out.
    func testASelectOffersEveryOptionBestMatchFirst() {
        let options = ["Monthly", "Quarterly", "Weekly", "Daily", "Hourly", "Biennial", "Yearly", "Lifetime"]
        let set = CandidateBuilder.build(page: page([
            element(0, role: "combobox", name: "Billing period", options: options),
            element(1, name: "Voice notes pricing", href: "https://a.test/pricing"),
            element(2, name: "Imprint", href: "https://a.test/imprint", region: .footer)
        ]), context: CandidateContext(subgoalTerms: ["yearly", "notes"]))
        let order = set.candidates.compactMap { $0.action.operation == .select ? $0.action.payload : $0.action.target?.name }
        XCTAssertEqual(order, ["Yearly", "Monthly", "Quarterly", "Weekly", "Daily", "Voice notes pricing", "Imprint",
                               "Hourly", "Biennial", "Lifetime"])
    }

    /// Candidate ids are what the model answers with; they are unique and
    /// stable for one build.
    func testCandidateIDsAreUnique() {
        let set = CandidateBuilder.build(page: page((0..<5).map { element($0, name: "L\($0)", href: "https://a.test/\($0)") }),
                                         context: context)
        XCTAssertEqual(Set(set.candidates.map(\.id)).count, set.candidates.count)
    }

    // MARK: - On a real page (L2)

    /// Observer to builder: nothing that leads out of the browser is offered
    /// — not a "button" inside a `mailto:` link, not a form that sends to one
    /// (review round 7).
    @MainActor
    func testNothingThatLeadsOutOfTheBrowserIsOffered() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-25.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let observed = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        let offered = CandidateBuilder.build(page: observed, context: context).candidates
            .compactMap { $0.action.target?.name }
        XCTAssertFalse(offered.contains("Write to support"))
        XCTAssertFalse(offered.contains("Send the form"))
        XCTAssertFalse(offered.contains("Continue inside"))
        XCTAssertTrue(offered.contains("Next page"))
    }

    @MainActor
    func testTheResultsFixtureOffersItsWholePageInOrder() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://search.test/?q=voice")!)
        try await bridge.waitUntilLoaded(tab)
        let observed = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        let set = CandidateBuilder.build(page: observed,
                                         context: CandidateContext(subgoalTerms: ["voice", "notes", "meeting", "dictation"]))
        XCTAssertEqual(set.candidates.compactMap { $0.action.destination },
                       ["https://search.test/images", "https://search.test/settings", "https://site-1.test/",
                        "https://site-2.test/", "https://site-3.test/", "https://search.test/?q=next&page=2"])
    }

    /// Review of A3, round 1: the option a select shows — its reported value —
    /// is not offered again, as jev-ultrafast offers only the others.
    func testTheOptionASelectShowsIsNotOfferedAgain() {
        var sort = ObservedElement(index: 0, role: "combobox", name: "Sort by", text: "", href: nil, inputType: nil,
                                   heading: nil, region: .main, inViewport: true, context: nil, formAction: nil,
                                   formMethod: nil, formSubmitLabel: nil, options: ["Newest", "Popular", "Oldest"],
                                   checked: nil)
        sort.value = "Popular"
        let page = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none, elements: [sort])
        let offered = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: []))
            .candidates.compactMap { $0.action.operation == .select ? $0.action.payload : nil }
        XCTAssertEqual(offered, ["Newest", "Oldest"])
    }

    /// ITER-076 I-05: an action the user said No to is left out, by what it
    /// does — its operation, its target's role, words and row, where it goes
    /// and its option. The same control's other actions, and every other
    /// control, are still offered.
    func testAnActionTheUserRefusedIsLeftOut() {
        let send = element(0, role: "button", name: "Send")
        let plan = element(1, role: "combobox", name: "Plan", options: ["Monthly", "Yearly"])
        let pricing = element(2, role: "link", name: "Pricing", href: "https://site-1.test/pricing")
        let refusedSelect = AgentAction(operation: .select, target: plan, destination: nil, payload: "Yearly",
                                        isPlannedSearch: false)
        let refusedClick = AgentAction(operation: .click, target: send, destination: nil, payload: nil,
                                       isPlannedSearch: false)
        var refusing = context
        refusing.refused = [refusedSelect.effect, refusedClick.effect]
        let offered = CandidateBuilder.build(page: page([send, plan, pricing]), context: refusing).candidates
            .filter { $0.action.target != nil }
            .map { "\($0.action.operation.rawValue) \($0.action.target?.name ?? "") \($0.action.payload ?? "")" }
        XCTAssertEqual(Set(offered), ["select Plan Monthly", "open Pricing "])
        let all = CandidateBuilder.build(page: page([send, plan, pricing]), context: context).candidates
        XCTAssertEqual(all.filter { $0.action.target != nil }.count, 4, "nothing is left out without a No")
    }

    /// Review round 1 (P2-2): a No holds for what the action does, not for
    /// how the page draws it. The same link redrawn — at another place,
    /// under another heading, its address with another fragment or another
    /// case in its host — stays refused; a client-side route is another
    /// place; a button whose label stays while its words change is another
    /// action.
    func testARefusalHoldsForWhatTheActionDoesNotHowItIsDrawn() {
        let delete = element(0, role: "link", name: "Delete", href: "https://site-1.test/delete?id=7#a")
        var refusing = context
        refusing.refused = [AgentAction(operation: .open, target: delete, destination: delete.href, payload: nil,
                                        isPlannedSearch: false).effect]
        let redrawn = element(5, role: "link", name: "Delete", href: "https://SITE-1.test/delete?id=7#b",
                              heading: "Your files")
        let route = element(6, role: "link", name: "Delete", href: "https://site-1.test/delete?id=7#/archive")
        let other = element(7, role: "link", name: "Delete", href: "https://site-1.test/delete?id=8")
        let offered = CandidateBuilder.build(page: page([redrawn, route, other]), context: refusing).candidates
            .compactMap { $0.action.target == nil ? nil : $0.action.destination }
        XCTAssertEqual(Set(offered), ["https://site-1.test/delete?id=7#/archive", "https://site-1.test/delete?id=8"])

        func button(_ index: Int, text: String, heading: String? = nil) -> ObservedElement {
            ObservedElement(index: index, role: "button", name: "Continue", text: text, href: nil, inputType: nil,
                            heading: heading, region: .main, inViewport: true, context: nil,
                            formAction: "https://site-1.test/send#top", formMethod: "post", formSubmitLabel: "Continue",
                            options: nil, checked: nil)
        }
        let asked = button(0, text: "Continue")
        refusing.refused = [AgentAction(operation: .click, target: asked, destination: nil, payload: nil,
                                        isPlannedSearch: false).effect]
        let same = button(3, text: "Continue", heading: "Step two")
        let changed = button(4, text: "Delete account")
        let buttons = CandidateBuilder.build(page: page([same]), context: refusing).candidates
            .compactMap { $0.action.target?.text }
        XCTAssertEqual(buttons, [], "the same button, redrawn, stays refused")
        let changedOffered = CandidateBuilder.build(page: page([changed]), context: refusing).candidates
            .compactMap { $0.action.target?.text }
        XCTAssertEqual(changedOffered, ["Delete account"], "the label stayed, the action changed: offered again")
    }

    /// Review round 2 (N2-P2-1): where a control goes is part of what it
    /// does. Refusing the Delete that goes to id=7 leaves the Delete that
    /// goes to id=8 offered; an alias of id=7 that differs only in its
    /// fragment stays refused. Such a control opens by its address (owner
    /// default 3.3, ITER-076 stage 3).
    func testARefusalKeepsWhereAClickedControlGoes() {
        func delete(_ index: Int, _ href: String) -> ObservedElement {
            element(index, role: "button", name: "Delete", href: href)
        }
        let seven = delete(0, "https://site-1.test/delete?id=7")
        var refusing = context
        refusing.refused = [AgentAction(operation: .open, target: seven, destination: seven.href, payload: nil,
                                        isPlannedSearch: false).effect]
        let offered = CandidateBuilder.build(page: page([delete(1, "https://site-1.test/delete?id=7#row"),
                                                         delete(2, "https://site-1.test/delete?id=8")]),
                                             context: refusing).candidates
            .filter { $0.action.operation == .open }.compactMap { $0.action.target?.href }
        XCTAssertEqual(offered, ["https://site-1.test/delete?id=8"])
    }

    /// ITER-076 brain: a combobox the observer reads as a text field — a
    /// textarea, as a search engine's own search box is drawn — is typed
    /// into; one a click opens is clicked; a hand-made one with no type, as
    /// before, offers nothing.
    func testAComboboxTheObserverReadsAsATextFieldIsTypedInto() {
        var box = element(0, role: "combobox", name: "Search")
        box.opens = false
        let typed = CandidateBuilder.build(page: page([box]), context: context).candidates
            .filter { $0.action.target != nil }.map(\.action.operation)
        XCTAssertEqual(typed, [.type])
        box.opens = true
        XCTAssertEqual(CandidateBuilder.build(page: page([box]), context: context).candidates
            .filter { $0.action.target != nil }.map(\.action.operation), [.click])
        box.opens = nil
        XCTAssertEqual(CandidateBuilder.build(page: page([box]), context: context).candidates
            .filter { $0.action.target != nil }.map(\.action.operation), [])
    }
}
