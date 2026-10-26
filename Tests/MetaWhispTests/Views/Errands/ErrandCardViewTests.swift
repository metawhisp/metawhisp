import AppKit
import XCTest
@testable import MetaWhisp

/// ITER-076 I-11 — the errand card as AppKit draws it, in the notification
/// card's shape (344 pt wide, 26 pt corners, glass), laid out by hand: no
/// Auto Layout, which crashed Tahoe on these cards. A wrong number does not
/// throw; it puts text under a button or off the card, on someone's screen.
@MainActor
final class ErrandCardViewTests: XCTestCase {

    private let sheet = URL(string: "https://docs.google.com/spreadsheets/d/abc/edit")!

    private func card(_ events: ErrandEvent...) -> ErrandCard {
        events.reduce(ErrandCard(id: UUID())) { $0.showing($1) }
    }

    private func formSend(askedAt: ContinuousClock.Instant = .now) -> ConfirmationRequest {
        let send = ObservedElement(index: 0, role: "button", name: "Send", text: "Send", href: nil, inputType: nil,
                                   heading: nil, region: .main, inViewport: true, context: nil,
                                   formAction: "https://example.com/contact", formMethod: "post",
                                   formSubmitLabel: "Send", options: nil, checked: nil, submits: true)
        return ConfirmationRequest(action: AgentAction(operation: .click, target: send, destination: nil, payload: nil,
                                                       isPlannedSearch: false),
                                   tab: BrowserTab(windowID: "1", tabID: "2"), pageURL: "https://example.com/contact",
                                   askedAt: askedAt)
    }

    /// Every state the card shows: the board's six, then the rest.
    private var states: [(name: String, card: ErrandCard)] {
        [("working", card(.working(title: "Finding competitors", done: 3, wanted: 10))),
         ("needs-yes", card(.needsYes(formSend()))),
         ("sign-in", card(.needsUser(ErrandHandover(kind: .signIn, host: "example.com")))),
         ("yours-to-do", card(.needsUser(ErrandHandover(kind: .grant, host: "example.com")))),
         ("stopped", card(.working(title: "MetaWhisp competitors", done: 4, wanted: 10),
                          .finished(ErrandOutcome(ending: .stuck, answer: nil, sources: [], sheet: sheet, rows: 4)))),
         ("done", card(.working(title: "MetaWhisp competitors", done: 10, wanted: 10),
                       .finished(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: sheet, rows: 10)))),
         ("queued", card(.queued(position: 2))),
         ("connecting", card(.connecting(.connecting))),
         ("allow", card(.connecting(.waitingForAllow(browser: "Google Chrome")))),
         ("planning", card(.connecting(.connected(browser: "Google Chrome")))),
         ("payment", card(.needsUser(ErrandHandover(kind: .payment, host: "shop.example.com")))),
         ("remote-debugging-off", card(.finished(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil,
                                                               rows: 0, notRun: .remoteDebuggingOff)))),
         // ITER-076 stage 7: the form's states.
         ("form-reading", card(.readingForm(host: "site-440.test"))),
         ("form-preview", card(.needsYes(formQuestion(.fill)))),
         ("form-send", card(.needsYes(formQuestion(.send)))),
         ("form-sent", card(.finished(ErrandOutcome(
            ending: .done, answer: nil, sources: [], sheet: nil, rows: 0,
            form: FormEnding(kind: .sent, host: "site-440.test", kinds: ["email"], labels: ["Work email"])))))]
    }

    /// A form's question (ITER-076 stage 7) with eight fields, one of them
    /// a long message, one left empty.
    private func formQuestion(_ kind: FormQuestion.Kind) -> ConfirmationRequest {
        let rows = (1...6).map { FormRow(label: "Field \($0)", shown: .value("Value \($0)", .memories, unsure: false)) }
            + [FormRow(label: "Message", shown: .value(String(repeating: "We would like a demo. ", count: 20), .request,
                                                       unsure: false)),
               FormRow(label: "Phone", shown: .notKnown)]
        var request = formSend()
        request.form = FormQuestion(kind: kind, host: "site-440.test", destination: nil, rows: rows)
        return request
    }

    private func view(_ card: ErrandCard, pressed: ((ErrandCard.Action) -> Void)? = nil) -> ErrandCardView {
        ErrandCardView(card: card, onPress: pressed ?? { _ in }, onClose: {}, onHover: { _ in })
    }

    private func texts(_ view: ErrandCardView) -> [String] {
        view.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
    }

    private func buttons(_ view: ErrandCardView) -> [NSButton] {
        view.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && !$0.title.isEmpty }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    private func closeButton(_ view: ErrandCardView) -> NSButton? {
        view.subviews.compactMap { $0 as? NSButton }.first { $0.title.isEmpty }
    }

    /// A form's rows, in the box they scroll in, each with its frame on the
    /// card (review round 3, R3-4).
    private func rows(_ view: ErrandCardView) -> [(field: NSTextField, frame: NSRect)] {
        let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first { !$0.isHidden }
        return (scroll?.documentView?.subviews ?? []).compactMap { $0 as? NSTextField }
            .map { ($0, $0.convert($0.bounds, to: view)) }
    }

    // MARK: - Shape and layout

    func testTheCardIsTheNotificationCardsShape() {
        let shown = view(states[0].card)
        XCTAssertEqual(shown.frame.width, 344)
        let clip = shown.subviews.first
        XCTAssertEqual(clip?.layer?.cornerRadius, 26)
        XCTAssertTrue(clip?.subviews.contains { $0 is NSVisualEffectView } ?? false, "glass, not a grey panel")
    }

    func testNothingIsLaidOutBeyondTheCard() {
        for (name, shownCard) in states {
            let shown = view(shownCard)
            let box = shown.bounds
            XCTAssertGreaterThan(box.height, 0, name)
            XCTAssertEqual(shown.frame.height, shown.measuredHeight, accuracy: 0.001, name)
            for sub in shown.subviews where !sub.isHidden {
                XCTAssertTrue(box.contains(sub.frame.insetBy(dx: 0.5, dy: 0.5)), "\(name): \(type(of: sub)) at \(sub.frame)")
            }
        }
    }

    /// The board's texts reach the screen: the label in capitals, as the board
    /// sets it, and every other line as the model holds it.
    func testTheCardShowsItsModelsLines() {
        let working = view(states[0].card)
        XCTAssertEqual(Set(texts(working)), ["WORKING", "Chrome · background tab", "Finding competitors — 3 of 10",
                                             "One row per site, into a new Google Sheet."])
        let yes = view(states[1].card)
        XCTAssertTrue(texts(yes).contains("2:00"), "the time left")
        XCTAssertTrue(texts(yes).contains("No answer in 2:00 counts as No."))
        let grant = view(states[3].card)
        XCTAssertTrue(texts(grant).contains("The agent never clicks it, even after a Yes."))
    }

    /// ITER-076 stage 7: a form's fields stand under the title and above the
    /// buttons.
    func testAFormsFieldsStandUnderTheTitleAboveTheButtons() {
        let preview = view(card(.needsYes(formQuestion(.fill))))
        let fields = preview.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
        let title = fields.first { $0.stringValue == "Fill the form on site-440.test?" }
        let rows = rows(preview)
        XCTAssertEqual(rows.map(\.field.stringValue).first, "Field 1 — Value 1 · from your memories")
        XCTAssertEqual(rows.map(\.field.stringValue).last, "Phone — left empty · not known")
        XCTAssertEqual(rows.count, 8)
        guard let title, let lowest = buttons(preview).first else { return XCTFail("the card lost a part") }
        for row in rows {
            XCTAssertLessThan(row.frame.maxY, title.frame.minY + 0.5, "under the title")
            XCTAssertGreaterThan(row.frame.minY, lowest.frame.maxY, "above the buttons")
        }
        XCTAssertEqual(buttons(preview).map(\.title), ["Fill", "No"])
    }

    /// A form's value is shown whole, however long: the Yes is given for
    /// exactly what is sent, so a long message wraps to every line it needs
    /// and is never cut (review round 2 of stage 7: two lines cut the rest).
    func testAFormsLongValueIsShownWhole() {
        let preview = view(card(.needsYes(formQuestion(.fill))))
        let found = rows(preview).first { $0.field.stringValue.hasPrefix("Message — ") }
        guard let message = found?.field, let shown = found?.frame, let lowest = buttons(preview).first else {
            return XCTFail("the card lost the message")
        }
        XCTAssertEqual(message.maximumNumberOfLines, 0, "no line limit")
        // The value's own height across the row, measured with no line limit.
        let probe = NSTextField(wrappingLabelWithString: message.stringValue)
        probe.font = message.font
        probe.maximumNumberOfLines = 0
        let whole = probe.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: message.frame.width, height: 10_000)).height
            ?? .greatestFiniteMagnitude
        XCTAssertGreaterThanOrEqual(message.frame.height + 0.5, whole, "every line of the value is drawn")
        XCTAssertGreaterThan(message.frame.height, 40, "a long value takes more than two lines")
        XCTAssertGreaterThan(shown.minY, lowest.frame.maxY, "still above the buttons")
    }

    func testTheButtonsAreTheBoardsInItsOrder() {
        XCTAssertEqual(buttons(view(states[0].card)).map(\.title), ["Stop", "Stop all"])
        XCTAssertEqual(buttons(view(states[1].card)).map(\.title), ["Send", "No"])
        XCTAssertEqual(buttons(view(states[5].card)).map(\.title), ["Open sheet", "Open in MetaChat"])
        for (name, shownCard) in states {
            let shown = buttons(view(shownCard))
            for (left, right) in zip(shown, shown.dropFirst()) {
                XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX, "\(name): buttons overlap")
            }
        }
    }

    func testOnlyAnEndedCardHasAClose() {
        for (name, shownCard) in states {
            XCTAssertEqual(closeButton(view(shownCard))?.isHidden == false, shownCard.hasEnded, name)
        }
    }

    /// The source line stops short of the close button.
    func testTheSourceLineDoesNotRunUnderTheCloseButton() {
        let shown = view(card(.working(title: String(repeating: "Long sheet title ", count: 10), done: 1, wanted: 2),
                              .finished(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: sheet, rows: 1))))
        let source = shown.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("Sheet · ") }
        guard let source, let close = closeButton(shown) else { return XCTFail("the card lost a subview") }
        XCTAssertLessThanOrEqual(source.frame.maxX, close.frame.minX)
    }

    /// A title 200 characters long, in any script, is truncated by the
    /// layout, never wrapped past the card; a running errand's count stays
    /// in sight.
    func testALongTitleIsTruncatedNeverWrappedPastTheCard() {
        let short = view(card(.working(title: "Shops", done: 1, wanted: 3)))
        for script in ["Competitors in the dictation market ", "競合他社の一覧と価格 ", "المنافسون في السوق "] {
            let long = String(repeating: script, count: 200 / script.count + 1)
            let working = view(card(.working(title: long, done: 1, wanted: 3)))
            XCTAssertEqual(working.measuredHeight, short.measuredHeight, "one line, whatever its length")
            let field = working.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasSuffix("— 1 of 3") }
            XCTAssertEqual(field?.lineBreakMode, .byTruncatingMiddle, "the count stays in sight")
            let ended = view(card(.working(title: long, done: 1, wanted: 3), .finished(ErrandOutcome(
                ending: .stopped, answer: nil, sources: [], sheet: sheet, rows: 1))))
            XCTAssertLessThan(ended.measuredHeight, 300, "bounded however long the line")
        }
    }

    /// An ending's line is read whole: it wraps, it is not cut to one line.
    func testAnEndingsLineWrapsToBeRead() {
        let stopped = view(states[4].card)
        let title = stopped.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Stopped: the errand was not getting anywhere." }
        let oneLine = view(card(.finished(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil,
                                                        rows: 0)))).subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Stopped." }
        guard let title, let oneLine else { return XCTFail("the card lost its title") }
        XCTAssertGreaterThan(title.frame.height, oneLine.frame.height * 1.5, "two lines, not one cut short")
    }

    // MARK: - In place, the countdown, the buttons

    func testTheCardUpdatesInPlace() {
        let shown = view(states[6].card)
        let queued = shown.measuredHeight
        shown.update(states[5].card)
        XCTAssertTrue(texts(shown).contains("DONE"))
        XCTAssertFalse(texts(shown).contains("QUEUED"))
        XCTAssertEqual(buttons(shown).map(\.title), ["Open sheet", "Open in MetaChat"])
        XCTAssertEqual(closeButton(shown)?.isHidden, false)
        XCTAssertGreaterThan(shown.measuredHeight, queued, "a body and a bar take room")
        XCTAssertEqual(shown.frame.height, shown.measuredHeight, accuracy: 0.001)
    }

    func testTheCountdownShowsTheTimeLeft() {
        let asked = ContinuousClock.now
        let shown = view(card(.needsYes(formSend(askedAt: asked))))
        shown.refresh(at: asked + .seconds(30))
        XCTAssertTrue(texts(shown).contains("1:30"))
        shown.refresh(at: asked + .seconds(200))
        XCTAssertTrue(texts(shown).contains("0:00"))
    }

    func testAClickReachesItsAction() {
        var pressed: [ErrandCard.Action] = []
        let shown = view(states[1].card, pressed: { pressed.append($0) })
        buttons(shown).forEach { $0.performClick(nil) }
        XCTAssertEqual(pressed, [.yes, .no])
    }

    /// The buttons act on the first click in a panel that is never key, and
    /// never take the keyboard: the user's window keeps its focus.
    func testTheButtonsNeverTakeFocus() {
        for button in buttons(view(states[1].card)) {
            XCTAssertTrue(button.acceptsFirstMouse(for: nil), button.title)
            XCTAssertTrue(button.refusesFirstResponder, button.title)
        }
    }

    // MARK: - Light and dark, drawn

    /// Every state drawn in light and in dark from the real view: the card is
    /// on the picture — its badge is not the desk behind it — and light and
    /// dark differ there. With `MW_ERRAND_CARD_SHOTS` naming a folder, each
    /// picture is saved there as a PNG.
    func testEveryStateIsDrawnInLightAndDark() throws {
        let folder = ProcessInfo.processInfo.environment["MW_ERRAND_CARD_SHOTS"].map { URL(fileURLWithPath: $0) }
        for (name, shownCard) in states {
            var badges: [NSColor] = []
            for dark in [false, true] {
                let picture = try XCTUnwrap(picture(of: shownCard, dark: dark), name)
                let desk = try XCTUnwrap(color(in: picture, x: 2, y: 2))
                // Inside the badge, left of its glyph: the margin, the card's
                // padding, then 5 pt in, half the badge down.
                let badge = try XCTUnwrap(color(in: picture, x: 34 + 20 + 5, y: 34 + 18 + 17))
                XCTAssertGreaterThan(distance(badge, desk), 0.2, "\(name): no card on the \(dark ? "dark" : "light") picture")
                badges.append(badge)
                if let folder, let png = picture.representation(using: .png, properties: [:]) {
                    try png.write(to: folder.appendingPathComponent("i11-\(name)-\(dark ? "dark" : "light").png"))
                }
            }
            if shownCard.tone == .plain {
                XCTAssertGreaterThan(distance(badges[0], badges[1]), 0.5, "\(name): the plain badge is inverted from the glass")
            }
        }
    }

    /// The real view on the board's desk colour, with room for its shadow.
    private func picture(of shownCard: ErrandCard, dark: Bool) -> NSBitmapImageRep? {
        let shown = view(shownCard)
        let margin: CGFloat = 34
        let desk = NSView(frame: NSRect(x: 0, y: 0, width: shown.frame.width + margin * 2,
                                        height: shown.measuredHeight + margin * 2))
        desk.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        desk.wantsLayer = true
        desk.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0x20 / 255, green: 0x21 / 255, blue: 0x24 / 255, alpha: 1)
                                            : NSColor(srgbRed: 0xD6 / 255, green: 0xD2 / 255, blue: 0xCA / 255, alpha: 1)).cgColor
        shown.setFrameOrigin(NSPoint(x: margin, y: margin))
        desk.addSubview(shown)
        guard let picture = desk.bitmapImageRepForCachingDisplay(in: desk.bounds) else { return nil }
        desk.cacheDisplay(in: desk.bounds, to: picture)
        return picture
    }

    /// The colour at a point given in the picture's points, from its top-left.
    private func color(in picture: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> NSColor? {
        let scale = CGFloat(picture.pixelsWide) / picture.size.width
        return picture.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
    }

    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }
}
