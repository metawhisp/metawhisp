import XCTest
@testable import MetaWhisp

/// Level 2 (ITER-074 §12.1): the real observer script on real HTML in a
/// `WKWebView`. What it reports is what every later decision rests on.
final class ObserverScriptTests: XCTestCase {

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

    /// ITER-076 I-07: a hidden page draws no frames, so the wait for it to go
    /// quiet gives one sample and returns — the caller asks again — never
    /// waiting on a frame that will not come. A web view in no window is one.
    @MainActor
    func testAHiddenPageGivesOneSampleOfItsQuiet() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-1.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let hidden = try await bridge.run("String(document.hidden)", in: tab)
        XCTAssertEqual(hidden, "true", "the premise: a web view in no window is hidden")
        let began = ContinuousClock.now
        let answer = try await bridge.runAwaiting(ObserverScript.settledSource(within: .seconds(3)), in: tab)
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(1_000), "one sample, not the whole wait")
        XCTAssertEqual(answer, #"{"stable":false}"#, "just installed: not quiet yet")
    }

    @MainActor
    func testTheResultsPageShowsItsLinksByRegion() async throws {
        let page = try await observe("https://search.test/?q=x")
        XCTAssertEqual(page.url, "https://search.test/?q=x")
        XCTAssertEqual(page.title, "Search results")
        XCTAssertEqual(page.elements.count, 6)
        XCTAssertTrue(page.elements.allSatisfy { $0.role == "link" })
        XCTAssertEqual(named("Site One", in: page)?.region, .main)
        XCTAssertEqual(named("Site One", in: page)?.href, "https://site-1.test/")
        XCTAssertEqual(named("Site Two", in: page)?.region, .main)
        XCTAssertEqual(named("Site Two", in: page)?.href, "https://site-2.test/")
        XCTAssertEqual(named("Site Three", in: page)?.region, .main)
        XCTAssertEqual(named("Site Three", in: page)?.href, "https://site-3.test/")
        XCTAssertEqual(named("Images", in: page)?.region, .nav)
        XCTAssertEqual(named("Settings", in: page)?.region, .nav)
        XCTAssertEqual(named("Next", in: page)?.region, .footer)
    }

    @MainActor
    func testIndicesFollowDocumentOrder() async throws {
        let page = try await observe("https://search.test/?q=x")
        XCTAssertEqual(page.elements.map(\.index), Array(0..<page.elements.count))
        XCTAssertEqual(page.elements.first?.name, "Images")
    }

    @MainActor
    func testAButtonIsSeen() async throws {
        let page = try await observe("https://site-1.test/")
        XCTAssertEqual(page.elements.count, 1)
        let button = page.elements.first
        XCTAssertEqual(button?.role, "button")
        XCTAssertEqual(button?.name, "Subscribe")
        XCTAssertEqual(button?.text, "Subscribe")
        XCTAssertEqual(button?.region, .other)
    }

    @MainActor
    func testRelativeLinksBecomeAbsolute() async throws {
        let page = try await observe("https://site-2.test/")
        XCTAssertEqual(named("See plans", in: page)?.href, "https://site-2.test/plans")
    }

    @MainActor
    func testTheAccessibleNameWinsOverTheText() async throws {
        let page = try await observe("https://site-2.test/")
        let trial = named("Start free trial", in: page)
        XCTAssertEqual(trial?.text, "Try")
        XCTAssertEqual(trial?.role, "button")
    }

    @MainActor
    func testInputsAreNamedByPlaceholderOrLabel() async throws {
        let page = try await observe("https://site-2.test/")
        let email = named("Work email", in: page)
        XCTAssertEqual(email?.role, "textbox")
        XCTAssertEqual(email?.inputType, "email")
        let message = named("Message", in: page)
        XCTAssertEqual(message?.role, "textbox")
        XCTAssertNotNil(message)
        XCTAssertNil(message?.inputType)
    }

    @MainActor
    func testHiddenAndZeroSizeElementsAreDropped() async throws {
        let page = try await observe("https://site-2.test/")
        XCTAssertNil(named("Gone", in: page))
        XCTAssertNil(named("Invisible", in: page))
        XCTAssertFalse(page.elements.contains { $0.href == "https://site-2.test/zero" })
    }

    @MainActor
    func testClickHandlersAndAriaRolesCount() async throws {
        let page = try await observe("https://site-2.test/")
        XCTAssertEqual(named("Clickable div", in: page)?.role, "button")
        XCTAssertEqual(named("Role button", in: page)?.role, "button")
    }

    @MainActor
    func testTheNearestHeadingIsRecorded() async throws {
        let site2 = try await observe("https://site-2.test/")
        XCTAssertEqual(named("See plans", in: site2)?.heading, "Pricing")
        XCTAssertEqual(named("Clickable div", in: site2)?.heading, "Hidden things")
        let site1 = try await observe("https://site-1.test/")
        XCTAssertEqual(named("Subscribe", in: site1)?.heading, "Site One")
    }

    @MainActor
    func testFarAwayElementsAreMarkedOutOfView() async throws {
        let page = try await observe("https://site-2.test/")
        XCTAssertEqual(named("Far below", in: page)?.inViewport, false)
        XCTAssertEqual(named("See plans", in: page)?.inViewport, true)
    }

    @MainActor
    func testFingerprintsSurviveReobservation() async throws {
        let first = try await observe("https://site-2.test/")
        let second = try await observe("https://site-2.test/")
        XCTAssertEqual(first.elements.map(\.fingerprint).sorted(),
                       second.elements.map(\.fingerprint).sorted())
        XCTAssertFalse(first.elements.isEmpty)
    }

    // MARK: - Review round 1 (names, roles, visibility, regions, budgets, trust)

    @MainActor
    private func observe(_ tab: BrowserTab, on bridge: WebViewBridge) async throws -> ObservedPage {
        let json = try await bridge.run(ObserverScript.source, in: tab)
        return try ObservedPage.decode(json)
    }

    /// `<button title="Details">Delete</button>` must read "Delete": the name
    /// is what the risk check reads (§7.1).
    @MainActor
    func testContentBeatsTheTitle() async throws {
        let page = try await observe("https://site-6.test/")
        XCTAssertEqual(named("Delete", in: page)?.role, "button")
        XCTAssertNil(named("Details", in: page))
    }

    @MainActor
    func testLabelledByBeatsAriaLabel() async throws {
        let page = try await observe("https://site-6.test/")
        XCTAssertEqual(named("Right name", in: page)?.href, "https://site-6.test/labelled")
        XCTAssertNil(named("Wrong name", in: page))
    }

    @MainActor
    func testAnImageLinkIsNamedByItsAlt() async throws {
        let page = try await observe("https://site-6.test/")
        XCTAssertEqual(named("Company logo", in: page)?.href, "https://site-6.test/logo")
    }

    @MainActor
    func testHtmlLabelsNameTheirFields() async throws {
        let page = try await observe("https://site-6.test/")
        XCTAssertEqual(named("City", in: page)?.role, "textbox")
        XCTAssertEqual(named("Zip", in: page)?.role, "textbox")
    }

    @MainActor
    func testTheTitleIsALastResort() async throws {
        let page = try await observe("https://site-6.test/")
        XCTAssertEqual(named("Close", in: page)?.role, "button")
    }

    @MainActor
    func testHiddenHeadingsDoNotCount() async throws {
        let page = try await observe("https://site-6.test/")
        XCTAssertEqual(named("Close", in: page)?.heading, "Names")
        XCTAssertEqual(named("Volume", in: page)?.heading, "Roles")
    }

    @MainActor
    func testMoreRolesAreRecognised() async throws {
        let page = try await observe("https://site-6.test/")
        let expected = ["Volume": "slider", "Quantity": "spinbutton", "Small": "radio",
                        "Bold": "menuitemcheckbox", "Red": "option", "Fallback": "button",
                        "Notes": "textbox", "Seats": "spinbutton", "Brightness": "slider",
                        "Tags": "listbox"]
        for (name, role) in expected {
            XCTAssertEqual(named(name, in: page)?.role, role, name)
        }
    }

    /// What someone typed into an editor is theirs; the report names the
    /// editor and never carries its contents.
    @MainActor
    func testTypedTextNeverLeavesAnEditor() async throws {
        let page = try await observe("https://site-6.test/")
        XCTAssertEqual(named("Compose", in: page)?.text, "")
        XCTAssertFalse(page.elements.contains { $0.name.contains("Private draft") || $0.text.contains("Private draft") })
    }

    @MainActor
    func testTransparentAndCollapsedElementsAreDropped() async throws {
        let page = try await observe("https://site-6.test/")
        XCTAssertNil(named("Ghost", in: page))
        XCTAssertNil(named("Ghost link", in: page))
        XCTAssertNil(named("Collapsed", in: page))
    }

    @MainActor
    func testTheNearestLandmarkWins() async throws {
        let page = try await observe("https://site-6.test/")
        XCTAssertEqual(named("Related", in: page)?.region, .aside)
    }

    @MainActor
    func testCoveredAndClippedElementsAreOutOfView() async throws {
        let page = try await observe("https://site-8.test/")
        XCTAssertEqual(named("Covered link", in: page)?.inViewport, false)
        XCTAssertEqual(named("Clipped link", in: page)?.inViewport, false)
        XCTAssertEqual(named("Close overlay", in: page)?.inViewport, true)
    }

    @MainActor
    func testAHugePageIsCutAndSaysSo() async throws {
        let page = try await observe("https://site-10.test/")
        XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.elements.count, ObserverScript.maxElements)
    }

    /// The observer runs in the page's own world, so a page can break it.
    /// Broken must mean refused, never a report the app half-believes.
    @MainActor
    func testAPageThatRewritesJSONCannotFakeTheReport() async throws {
        do {
            _ = try await observe("https://site-14.test/")
            XCTFail("a page that rewrote JSON.stringify must not produce a report")
        } catch is DecodingError {
            // Refused at decoding — the only acceptable outcome.
        } catch {
            XCTFail("expected the report to be refused at decoding, got \(error)")
        }
    }

    /// Identity must survive the page changing around an element: a new link
    /// at the top and a moved link shift every index, not the fingerprints.
    @MainActor
    func testFingerprintsSurviveChangesToThePage() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-2.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let before = try await observe(tab, on: bridge)
        _ = try await bridge.run("""
            const main = document.querySelector('main');
            const fresh = document.createElement('a');
            fresh.href = '/new'; fresh.textContent = 'New link';
            main.insertBefore(fresh, main.firstChild);
            main.appendChild(document.getElementById('plans'));
            'changed'
            """, in: tab)
        let after = try await observe(tab, on: bridge)
        XCTAssertEqual(after.elements.count, before.elements.count + 1)
        let afterPrints = Set(after.elements.map(\.fingerprint))
        for element in before.elements where element.name != "See plans" {
            XCTAssertTrue(afterPrints.contains(element.fingerprint), element.name)
        }
        XCTAssertNotEqual(named("See plans", in: before)?.index, named("See plans", in: after)?.index)
    }

    /// The row a button sits in is part of its identity, so three "Remove"
    /// buttons are three different things to do.
    @MainActor
    func testIdenticalButtonsAreToldApartByTheirRow() async throws {
        let page = try await observe("https://site-15.test/")
        let removes = page.elements.filter { $0.name == "Remove" }
        XCTAssertEqual(removes.map(\.context), ["Home", "Office", "Parents"])
        XCTAssertEqual(Set(removes.map(\.fingerprint)).count, 3)
        XCTAssertEqual(removes.map { page.identity(of: $0).total }, [1, 1, 1])
    }

    /// Swapping two rows must not swap which address "Remove" removes.
    @MainActor
    func testReorderedRowsKeepTheirButtons() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-15.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let before = try await observe(tab, on: bridge)
        let home = try XCTUnwrap(before.elements.first { $0.name == "Remove" && $0.context == "Home" })
        let identity = before.identity(of: home)
        _ = try await bridge.run("""
            const rows = document.getElementById('rows');
            rows.insertBefore(rows.children[1], rows.children[0]);
            'swapped'
            """, in: tab)
        let after = try await observe(tab, on: bridge)
        XCTAssertEqual(after.element(matching: identity)?.context, "Home")
    }

    /// A rich editor's contents are someone's writing, links included.
    @MainActor
    func testEditorContentNeverLeaks() async throws {
        let page = try await observe("https://site-6.test/")
        XCTAssertEqual(named("Rich editor", in: page)?.text, "")
        XCTAssertFalse(page.elements.contains {
            $0.name.contains("Private draft") || $0.text.contains("Private draft") || ($0.context ?? "").contains("Private draft")
        })
    }

    // MARK: - The page's text and scroll (ITER-076 A3a)

    /// The report carries the page's visible text, as the writer's excerpt
    /// reads it: never what someone wrote in an editor.
    @MainActor
    func testTheReportCarriesThePagesTextWithoutAnyonesWriting() async throws {
        let page = try await observe("https://site-6.test/")
        XCTAssertFalse(page.text.isEmpty)
        XCTAssertFalse(page.text.contains("Private draft"), page.text)
        XCTAssertLessThanOrEqual(page.text.count, 6_000)
    }

    /// A page cut at the report's element limit had every field checked for a
    /// secret first, so it still gives its text.
    @MainActor
    func testAPageCutAtTheElementLimitStillGivesItsText() async throws {
        let page = try await observe("https://site-10.test/")
        XCTAssertTrue(page.truncated)
        XCTAssertFalse(page.text.isEmpty)
    }

    /// The report says how far down the page is scrolled.
    @MainActor
    func testTheReportSaysHowFarThePageIsScrolled() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-26.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let top = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(top.scrollY, 0)
        _ = try await bridge.run("window.scrollTo(0, 400); 'scrolled'", in: tab)
        let down = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        XCTAssertEqual(down.scrollY, 400)
    }

    /// ARIA takes the first recognised role; "heading button" is a heading.
    @MainActor
    func testTheFirstRecognisedRoleWins() async throws {
        let page = try await observe("https://site-6.test/")
        XCTAssertNil(named("Heading first", in: page))
        XCTAssertEqual(named("Fallback", in: page)?.role, "button")
    }

    /// One huge element or one huge address cannot blow the budget or the
    /// report.
    @MainActor
    func testOversizedContentIsBounded() async throws {
        let started = ContinuousClock.now
        let page = try await observe("https://site-16.test/")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        let huge = try XCTUnwrap(page.elements.first { $0.role == "button" })
        XCTAssertLessThanOrEqual(huge.name.count, 200)
        XCTAssertLessThanOrEqual(huge.text.count, 200)
        let long = try XCTUnwrap(named("Long address", in: page))
        XCTAssertLessThanOrEqual(long.href?.count ?? 0, 2000)
    }

    // MARK: - ITER-076 I-10

    /// Critic 12: a link whose address is "#", empty or `javascript:` acts
    /// through the page's own script — a button, clicked, with nowhere to
    /// go; a link with a real address keeps it.
    @MainActor
    func testALinkThatActsThroughThePagesScriptIsAButtonAndARealLinkKeepsItsAddress() async throws {
        let page = try await observe("https://site-231.test/")
        for name in ["Load more", "Show all", "Refresh list", "Shout"] {
            XCTAssertEqual(named(name, in: page)?.role, "button", name)
            XCTAssertNil(named(name, in: page)?.href, name)
        }
        XCTAssertEqual(named("Next page", in: page)?.role, "link")
        XCTAssertEqual(named("Next page", in: page)?.href, "https://site-231.test/next")
    }

    /// Critic 14: words cut by the look's own limit of size are kept up to
    /// it, and the look says they were cut; a page read whole says nothing.
    @MainActor
    func testAPagesTextCutBySizeIsKeptAndSaysSo() async throws {
        let huge = try await observe("https://site-234.test/")
        // The page's first words, read up to the limit and never past it (no
        // margin past it since I-09 round 5): of what was read, only
        // whitespace is squeezed out — the layout's line breaks and indents
        // around the heading, a space at the cut, 10 characters at most.
        let notes = "Notes " + (0..<2000).map { "Line \($0) of the notes." }.joined(separator: " ")
        XCTAssertTrue(notes.hasPrefix(huge.text), String(huge.text.suffix(40)))
        XCTAssertLessThanOrEqual(huge.text.count, ObservedPage.maxText)
        XCTAssertGreaterThanOrEqual(huge.text.count, ObservedPage.maxText - 10)
        XCTAssertTrue(huge.text.hasPrefix("Notes Line 0 of the notes."), String(huge.text.prefix(40)))
        XCTAssertTrue(huge.textCut)
        let whole = try await observe("https://site-1.test/")
        XCTAssertFalse(whole.text.isEmpty)
        XCTAssertFalse(whole.textCut)
    }

    /// Critic 14: words a look runs out of time on are kept as far as they
    /// were read — never dropped whole — and the look says they were cut.
    @MainActor
    func testAPagesTextCutByTimeKeepsWhatWasReadAndSaysSo() async throws {
        let page = try await observe("https://site-242.test/")
        XCTAssertTrue(page.text.hasPrefix("Slow notes Part 0. Part 1."), String(page.text.prefix(40)))
        XCTAssertFalse(page.text.contains("Part 599."), "the premise: the look ran out of time")
        XCTAssertTrue(page.textCut)
    }

    /// ITER-076 stage 2: the reader's lines are the same words — a look that
    /// runs out of time keeps the lines it read before it, as the page's text
    /// does, never none; the lines say nothing of the cut.
    @MainActor
    func testTheReadersLinesCutByTimeKeepWhatWasRead() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-242.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let json = try await bridge.run(ObserverScript.blocksSource(limit: 12_000), in: tab)
        let capture = try XCTUnwrap(ErrandModel.Capture.decode(json), json)
        XCTAssertEqual(capture.blocks.first, .init(label: "main/:1", kind: "heading", text: "Slow notes"), json)
        XCTAssertTrue(capture.text.contains("Part 0. Part 1."), String(capture.text.prefix(60)))
        XCTAssertFalse(capture.text.contains("Part 599."), "the premise: the look ran out of time")
    }

    /// Critic 17: a page with more controls than a look reports keeps the
    /// ones on screen first — here the last in the document — then the rest
    /// in document order, and reports them in document order.
    @MainActor
    func testControlsOnScreenAreKeptFirstWhenThePageHasMoreThanALookReports() async throws {
        let page = try await observe("https://site-237.test/")
        XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.elements.count, ObserverScript.maxElements)
        let last = try XCTUnwrap(named("Item 600", in: page), "the control on screen is kept")
        XCTAssertTrue(last.inViewport)
        XCTAssertNotNil(named("Item 1", in: page), "the rest in document order")
        let numbers = page.elements.compactMap { Int($0.name.replacingOccurrences(of: "Item ", with: "")) }
        XCTAssertEqual(numbers, numbers.sorted(), "reported in document order")
        XCTAssertEqual(page.elements.map(\.index), Array(0..<page.elements.count))
    }

    /// Change 3 needs where a document was loaded from, which the page's own
    /// history calls never change.
    @MainActor
    func testWhereTheDocumentWasLoadedFromIsReportedAndAPagesOwnAddressChangeLeavesIt() async throws {
        let page = try await observe("https://site-233.test/")
        XCTAssertEqual(page.address, "https://site-233.test/delete-account", "the premise: the page rewrote it")
        XCTAssertEqual(page.loadedFrom, "https://site-233.test/")
    }

    /// ITER-076 broad set (Wikipedia, 2026-10-07): a suggestion drawn as an
    /// option whose whole face is its article's link, of the same name, is one
    /// control — the link, of the option's list. The option itself the hands
    /// could never press: they never click through another control. An
    /// option with words of its own beside its link stays, and so does one
    /// with no control inside; a menu item drawn as its link is that link.
    @MainActor
    func testAnOptionDrawnAsItsLinkIsReportedOnceAsThatLinkOfItsList() async throws {
        let page = try await observe("https://site-471.test/")
        let field = try XCTUnwrap(named("Search the encyclopedia", in: page))
        let article = page.elements.filter { $0.name == "Incompleteness theorems" }
        XCTAssertEqual(article.map(\.role), ["link"], "one control, the one the hands can press")
        XCTAssertEqual(article.first?.href, "https://site-471.test/wiki/Incompleteness")
        XCTAssertEqual(article.first?.listOf, field.index, "of the option's list still")
        XCTAssertEqual(named("Kurt Goedel - logician", in: page)?.role, "option", "words of its own: pressed there")
        XCTAssertEqual(named("Kurt Goedel - logician", in: page)?.listOf, field.index)
        XCTAssertEqual(named("Kurt Goedel", in: page)?.role, "link")
        XCTAssertEqual(named("Goedel numbering", in: page)?.role, "option", "no control inside: itself")
        XCTAssertEqual(page.elements.filter { $0.name == "Settings" }.map(\.role), ["link"])
        XCTAssertEqual(page.elements.map(\.index), Array(0..<page.elements.count))
    }

    /// ITER-076 (2026-10-07): a link to a place on its own page is clicked,
    /// so it is of the form around it, as every clicked control is — a click
    /// in a POST form may send it. A link to another page is opened by its
    /// address, sends nothing, and stays of no form.
    @MainActor
    func testALinkToAPlaceOnItsPageIsOfItsFormAndALinkElsewhereOfNone() async throws {
        let page = try await observe("https://site-472.test/")
        let terms = try XCTUnwrap(named("Read the terms", in: page))
        XCTAssertEqual(terms.formMethod, "post")
        XCTAssertEqual(terms.formAction, "https://site-472.test/order")
        let click = AgentAction(operation: .click, target: terms, destination: nil, payload: nil, isPlannedSearch: false)
        XCTAssertEqual(SafetyGuard.structuralReason(of: click, pageURL: page.liveAddress), .postForm)
        XCTAssertNil(named("Help", in: page)?.formMethod, "another page's link: of no form")
        XCTAssertNil(named("Request a demo", in: page)?.formMethod, "no form around it")
    }
}
