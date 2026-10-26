import XCTest
@testable import MetaWhisp

/// Level 2 (ITER-074 §6.6): the page's own words the writer gets — visible
/// text of the main content, bounded, and never anything someone wrote or
/// anything hidden.
final class ExcerptScriptTests: XCTestCase {

    @MainActor
    private func excerpt(_ address: String, limit: Int = 3_000) async throws -> PageExcerpt {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: address)!)
        try await bridge.waitUntilLoaded(tab)
        return try PageExcerpt.decode(try await bridge.run(ObserverScript.excerptSource(limit: limit), in: tab))
    }

    @MainActor
    func testTheExcerptIsTheMainContentsVisibleText() async throws {
        let page = try await excerpt("https://site-1.test/")
        XCTAssertEqual(page.url, "https://site-1.test/")
        XCTAssertFalse(page.title.isEmpty)
        XCTAssertFalse(page.text.isEmpty)
    }

    /// Hidden text — where a page hides orders for a model — stays out.
    @MainActor
    func testHiddenTextStaysOut() async throws {
        let page = try await excerpt("https://site-9.test/")
        XCTAssertFalse(page.text.contains("SYSTEM"))
    }

    /// What someone wrote in a field or an editor stays out.
    @MainActor
    func testWritingStaysOut() async throws {
        let page = try await excerpt("https://site-20.test/")
        XCTAssertFalse(page.text.contains("Private"))
    }

    /// The excerpt follows the tree a person sees and every sensitive field:
    /// text a component slots into its text field, a component's own text that
    /// no slot shows, and a secret in a custom control stay out — the page's
    /// public words stay in (review round 10).
    @MainActor
    func testSlottedWritingUnrenderedTextAndSecretsStayOut() async throws {
        let page = try await excerpt("https://site-28.test/")
        XCTAssertTrue(page.text.contains("Public words stay"))
        for hidden in ["Private draft", "Unrendered", "secret"] {
            XCTAssertFalse(page.text.contains(hidden), hidden)
        }
    }

    /// A page too long to scan whole still gives the words it shows: each
    /// field is judged secret by its own structure, never by what the scan
    /// reached (owner decision of 2026-10-03).
    @MainActor
    func testAPageTooLongToScanStillGivesTheWordsItShows() async throws {
        let page = try await excerpt("https://site-22.test/")
        XCTAssertTrue(page.text.hasPrefix("A long page with a password at the end"), page.text)
    }

    @MainActor
    func testTheExcerptIsBounded() async throws {
        let page = try await excerpt("https://site-24.test/", limit: 40)
        XCTAssertLessThanOrEqual(page.text.count, 40)
    }

    // MARK: - ITER-076 stage 4a: a read says what its walk met

    /// The reader's lines of the page at `address`, and whether the page was
    /// hidden when they were read.
    @MainActor
    private func lines(_ address: String, limit: Int = ErrandModel.chunkLimit * AgentRun.maxReads) async throws
        -> (capture: ErrandModel.Capture, pageHidden: Bool) {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: address)!)
        try await bridge.waitUntilLoaded(tab)
        let json = try await bridge.run(ObserverScript.blocksSource(limit: limit), in: tab)
        let hidden = try await bridge.run("String(document.hidden)", in: tab) == "true"
        return (try XCTUnwrap(ErrandModel.Capture.decode(json)), hidden)
    }

    /// The reader's lines come with what their walk met, by kinds and
    /// numbers: where it began, how many places hold a main content, whether
    /// the page was hidden, the words it met and kept, the rule that left
    /// each of the rest, and what cut it — so a page read empty says why.
    @MainActor
    func testTheReadersLinesSayWhatTheirWalkMetAndWhyItLeftTheRest() async throws {
        let jokes = try await lines("https://site-404.test/")
        XCTAssertEqual(jokes.capture.blocks.count, 15, "the premise: the page's lines")
        XCTAssertEqual(jokes.capture.walk, ErrandModel.Capture.Walk(root: .main, roots: 1, pageHidden: jokes.pageHidden,
                                                                    met: 17, kept: 17, dropped: [:], cut: nil))

        // Its one main part keeps no word, so the body is read in its place
        // (ITER-076 stage 4c): it keeps none either.
        let unseen = try await lines("https://site-430.test/")
        XCTAssertEqual(unseen.capture.blocks, [], "the premise: no word of its main content is seen")
        XCTAssertEqual(unseen.capture.walk, ErrandModel.Capture.Walk(root: .body, roots: 1, pageHidden: unseen.pageHidden,
                                                                     met: 5, kept: 0,
                                                                     dropped: [.unseen: 3, .hidden: 1, .writing: 1],
                                                                     cut: nil))

        let whole = try await lines("https://site-1.test/")
        XCTAssertEqual(whole.capture.walk?.root, .body, "a page that marks no main content is read from its body")
        XCTAssertEqual(whole.capture.walk?.roots, 0)

        let cut = try await lines("https://site-24.test/", limit: 40)
        XCTAssertEqual(cut.capture.walk?.cut, .limit)
    }

    // MARK: - ITER-076 stage 4c: every part the page marks main

    /// The page's text as the step's look reads it.
    @MainActor
    private func looked(_ address: String) async throws -> String {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: address)!)
        try await bridge.waitUntilLoaded(tab)
        return try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab)).text
    }

    /// Each line of a read as its kind and its words.
    private func shown(_ capture: ErrandModel.Capture) -> [String] {
        capture.blocks.map { $0.kind + " " + $0.text }
    }

    /// F3: a page that marks three main parts, the first holding no word — as
    /// a search engine's results reached by typing and a suggestion did — is
    /// read part by part in the page's order, a part inside another once, and
    /// nothing outside them; by the reader's lines, the writer's excerpt and
    /// the step's look alike.
    @MainActor
    func testEveryPartThePageMarksMainIsReadInItsOrderAndNothingOutsideThem() async throws {
        let read = try await lines("https://site-431.test/")
        XCTAssertEqual(shown(read.capture), ["heading Results 431", "list_item Result one 431", "list_item Result two 431",
                                             "paragraph A part inside a part 431", "paragraph Result three 431"])
        XCTAssertEqual(read.capture.walk, ErrandModel.Capture.Walk(root: .role, roots: 4, pageHidden: read.pageHidden,
                                                                   met: 5, kept: 5, dropped: [:], cut: nil),
                       "it began at the first part; four places mark a main part, one inside another")
        let words = "Results 431 Result one 431 Result two 431 A part inside a part 431 Result three 431"
        let page = try await excerpt("https://site-431.test/")
        XCTAssertEqual(page.text, words, "the writer's excerpt")
        let look = try await looked("https://site-431.test/")
        XCTAssertEqual(look, words, "the step's look")
    }

    /// F3: a page whose main parts hold no word a person sees — one holds
    /// nothing, one only hidden words — is read from its body, by all three.
    @MainActor
    func testAPageWhoseMainPartsHoldNoWordAPersonSeesIsReadFromItsBody() async throws {
        let read = try await lines("https://site-432.test/")
        XCTAssertEqual(shown(read.capture), ["paragraph Words above the parts 432", "paragraph Words below the parts 432"])
        XCTAssertEqual(read.capture.walk, ErrandModel.Capture.Walk(root: .body, roots: 2, pageHidden: read.pageHidden,
                                                                   met: 3, kept: 2, dropped: [.hidden: 1], cut: nil))
        let words = "Words above the parts 432 Words below the parts 432"
        let page = try await excerpt("https://site-432.test/")
        XCTAssertEqual(page.text, words, "the writer's excerpt")
        let look = try await looked("https://site-432.test/")
        XCTAssertEqual(look, words, "the step's look")
    }

    /// F3: a page that marks one main part holding words is read as before:
    /// that part alone, nothing around it.
    @MainActor
    func testAPageThatMarksOneMainPartIsReadFromItAlone() async throws {
        let read = try await lines("https://search.test/?q=x")
        XCTAssertEqual(read.capture.blocks.map(\.text), ["Site One", "A voice notes app for teams.", "Site Two",
                                                         "Dictation for doctors.", "Site Three",
                                                         "Meeting recorder without a bot."])
        XCTAssertEqual(read.capture.walk?.root, .main)
        XCTAssertEqual(read.capture.walk?.roots, 1)
        let words = "Site One A voice notes app for teams. Site Two Dictation for doctors. Site Three Meeting recorder without a bot."
        let page = try await excerpt("https://search.test/?q=x")
        XCTAssertEqual(page.text, words, "the writer's excerpt")
        let look = try await looked("https://search.test/?q=x")
        XCTAssertEqual(look, words, "the step's look")
    }

    /// 2026-10-08 (live, a practice site's frames page): the reader read no
    /// frame, so an email form's own heading, in a frame of the page's
    /// A rating drawn as stars says its value only in the page's markup — a `star-rating` class with its word,
    /// or a rating's label — and is read where it stands, as a reference browser agent's capture reads it
    /// (`capture.js` `ratingOf`, MIT): a list of books rated by stars counted none of its one-star books
    /// (books.toscrape, 2026-10-16). A hidden rating, a class that only mentions a star, and an icon's title
    /// say nothing.
    @MainActor
    func testARatingDrawnAsStarsIsReadWhereItStands() async throws {
        let read = try await lines("https://site-482.test/")
        XCTAssertEqual(shown(read.capture), ["heading Young Adult 482", "paragraph One stars", "heading Book A",
                                             "paragraph £10.00", "paragraph Three stars", "heading Book B",
                                             "paragraph £20.00", "paragraph Reviewed: 4 out of 5",
                                             "paragraph Starred: none", "paragraph Saved"])
        let page = try await excerpt("https://site-482.test/")
        XCTAssertTrue(page.text.contains("One stars Book A £10.00 Three stars Book B"), page.text)
    }

    /// origin, never reached it, and the page's heading above the frame was
    /// taken for the form's. A frame of the page's origin is read where it
    /// stands, under the headings above it, as a reference browser agent's
    /// capture reads one; the count says the frames not read.
    @MainActor
    func testAFrameOfThePagesOriginIsReadWhereItStands() async throws {
        let bridge = WebViewBridge()
        let tab = try await bridge.openTab(URL(string: "https://site-474.test/")!)
        try await bridge.waitUntilLoaded(tab)
        let framed = "(() => { const d = document.querySelector('iframe').contentDocument; "
            + "return d && d.body ? d.body.textContent : ''; })()"
        var inside = ""
        for _ in 0..<50 where !inside.contains("Send updates") {
            inside = try await bridge.run(framed, in: tab)
            if !inside.contains("Send updates") { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(inside.contains("Send updates to my inbox"), "the premise: the frame holds its form")
        let json = try await bridge.run(ObserverScript.blocksSource(limit: 12_000), in: tab)
        let capture = try XCTUnwrap(ErrandModel.Capture.decode(json))
        let texts = capture.blocks.map(\.text)
        let above = try XCTUnwrap(texts.firstIndex(of: "Internal IFrame: Email Subscription"), "\(texts)")
        XCTAssertEqual(capture.blocks.dropFirst(above + 1).first?.text, "Send updates to my inbox", "\(texts)")
        XCTAssertEqual(capture.blocks.dropFirst(above + 1).first?.kind, "heading")
        XCTAssertLessThan(try XCTUnwrap(texts.firstIndex(of: "Send updates to my inbox")),
                          try XCTUnwrap(texts.firstIndex(of: "Discover more")), "where the frame stands")
        XCTAssertEqual(capture.frames, 0, "every frame was read")
    }
}
