import XCTest
@testable import MetaWhisp

/// The one link to the next page of a list, as a reference browser agent finds it (`next_page_control`,
/// `pages_forward`, `pager_link`; `agent.py` and `page.py`, MIT).
final class NextPageTests: XCTestCase {
    private func link(_ name: String, _ href: String?, role: String = "link", frame: String? = nil) -> ObservedElement {
        var element = ObservedElement(index: 0, role: role, name: name, text: name, href: href, inputType: nil,
                                      heading: nil, region: .main, inViewport: true, context: nil, formAction: nil,
                                      formMethod: nil, formSubmitLabel: nil, options: nil, checked: nil)
        element.frame = frame
        return element
    }

    private func page(_ elements: [ObservedElement], url: String = "https://site-478.test/page/1/") -> ObservedPage {
        ObservedPage(url: url, title: "Quotes 478", truncated: false, flags: .none, elements: elements, text: "")
    }

    /// A pager's next by its words — "Next", "Next page", "More results", "Older posts", with arrows after
    /// them, or one or two arrows alone — to another address of the page's own site.
    func testANextLinkToAnotherAddressOfTheSiteIsFound() {
        for name in ["Next →", "Next", "next page", "More results", "Older posts »", "›", "»»", " Next  › "] {
            let found = NextPage.control(on: page([link("Home", "https://site-478.test/"),
                                                   link(name, "https://site-478.test/page/2/")]))
            XCTAssertEqual(found?.href, "https://site-478.test/page/2/", name)
        }
    }

    /// A pager drawn above and below its list is one link: one address.
    func testAPagerDrawnTwiceIsOne() {
        let found = NextPage.control(on: page([link("Next →", "https://site-478.test/page/2/"),
                                               link("Next →", "https://site-478.test/page/2/")]))
        XCTAssertEqual(found?.href, "https://site-478.test/page/2/")
    }

    /// The pager drawn twice is both its drawings, in the page's order, the walk takes whichever a step offers
    /// (Codex review of 2026-10-18, P1-4); where there is no one next link, there are none.
    func testAPagerDrawnTwiceIsBothItsDrawings() {
        var top = link("Next →", "https://site-478.test/page/2/"), bottom = link("Next →", "/page/2/")
        (top.index, bottom.index) = (3, 9)
        XCTAssertEqual(NextPage.drawings(on: page([link("Home", "https://site-478.test/"), top, bottom])).map(\.index), [3, 9])
        XCTAssertEqual(NextPage.drawings(on: page([link("Next →", "https://site-478.test/page/2/"),
                                                   link("Next", "https://site-478.test/archive/2/")])).count, 0)
    }

    /// Nothing that only reads like a pager: a button, words that only start like one, a link to another
    /// site or to this same page, one with no address, one in a frame — and two next links of two addresses,
    /// where which one goes on is not known.
    func testWhatOnlyReadsLikeAPagerIsNot() {
        let cases: [(String, [ObservedElement])] = [
            ("a button", [link("Next →", nil, role: "button")]),
            ("not a pager's words", [link("Next steps for teams", "https://site-478.test/next"),
                                     link("Learn more", "https://site-478.test/more")]),
            ("another site", [link("Next →", "https://site-479.test/page/2/")]),
            ("this same page", [link("Next →", "https://site-478.test/page/1/")]),
            ("no address", [link("Next →", nil)]),
            ("in a frame", [link("Next →", "https://site-478.test/page/2/", frame: "frame-1")]),
            ("two addresses", [link("Next →", "https://site-478.test/page/2/"),
                               link("Next", "https://site-478.test/archive/2/")]),
        ]
        for (why, elements) in cases { XCTAssertNil(NextPage.control(on: page(elements)), why) }
    }

    /// A read of a page with a next-page control carries the notice after the requirements still to evidence,
    /// where the reference puts it (`retrieval.py` 714-715); one of a page without it carries none.
    func testAReadOfAPageWithANextPageCarriesTheNotice() throws {
        let capture = ErrandModel.Capture(url: "https://site-478.test/page/1/", frames: 0,
                                          blocks: [.init(label: "main/:1", kind: "paragraph", text: "A quote")])
        let wanted: [AgentPlan.Requirement] = [.init(id: "1", text: "Count the quotes", kind: .information)]
        func asked(_ next: String?) throws -> String {
            let request = ErrandModel.readRequest(goal: "g", wanted: wanted, evidence: [], capture: capture,
                                                  chunk: capture.blocks, index: 0, total: 1, nextPage: next)
            return try XCTUnwrap(request.messages.last?["content"]?.string)
        }
        XCTAssertTrue(try asked("Next →").contains("- Count the quotes\n\n" + NextPage.notice("Next →")
                                                   + "\n\n# Requirement ids"))
        XCTAssertFalse(try asked(nil).contains("next-page control"))
    }

    /// Once a list may run past one page, the read says where the run began, between the requirements and the
    /// notice, as the reference's question does (`read_question`, `agent.py` 3187-3198): read from the second
    /// page, "the second page" was taken for the one after it and its answer kept as no requirement's
    /// (quotes.toscrape/js, 2026-10-16). A read that is not told where the run began says nothing of it.
    func testAReadPastTheFirstPageSaysWhereTheRunBegan() throws {
        let capture = ErrandModel.Capture(url: "https://site-478.test/page/2/", frames: 0,
                                          blocks: [.init(label: "main/:1", kind: "paragraph", text: "A quote")])
        let wanted: [AgentPlan.Requirement] = [.init(id: "1", text: "Who wrote the first quote on the second page",
                                                     kind: .information)]
        func asked(_ began: String?) throws -> String {
            let request = ErrandModel.readRequest(goal: "g", wanted: wanted, evidence: [], capture: capture,
                                                  chunk: capture.blocks, index: 0, total: 1, nextPage: "Next →",
                                                  beganAt: began)
            return try XCTUnwrap(request.messages.last?["content"]?.string)
        }
        XCTAssertTrue(try asked("https://site-478.test/page/1/").contains(
            "- Who wrote the first quote on the second page\n\n"
                + "The task's \"this page\" is https://site-478.test/page/1/, where the run began, and \"the next page\" "
                + "is the one after it. A task that names how many pages it covers ends at the last one it names.\n\n"
                + NextPage.notice("Next →") + "\n\n# Requirement ids"))
        XCTAssertFalse(try asked(nil).contains("where the run began"))
    }

    /// The reader is told the page has a next-page control, as the reference tells it: a list on it may
    /// continue, and what the next page shows is not answered here.
    func testTheReaderIsToldOfTheNextPageControl() {
        XCTAssertEqual(NextPage.notice("Next →"), "This page has a next-page control ('Next →'): a list on it may "
                       + "continue. A requirement about the page that control opens is not answered by this page, "
                       + "whatever this page holds: leave it unanswered until that page is read.")
    }
}
