import XCTest
@testable import MetaWhisp

/// ITER-076 stage 7 (item 17, the texts the owner approved on 2026-10-06) —
/// the form's card: the form being read, the preview with each field's value
/// and where it came from, the Send question bound to those values, and the
/// ending. Values are shown on the card (decision 7.3); the preview has no
/// timer (decision 7.4).
@MainActor
final class ErrandCardFormTests: XCTestCase {

    private let id = UUID()

    private func card(_ events: ErrandEvent...) -> ErrandCard {
        events.reduce(ErrandCard(id: id)) { $0.showing($1) }
    }

    private func button(_ label: String, _ action: ErrandCard.Action, primary: Bool = false) -> ErrandCard.Button {
        ErrandCard.Button(label: label, action: action, primary: primary)
    }

    private static let rows: [FormRow] = [
        FormRow(label: "First name", shown: .value("Sam", .memories, unsure: false)),
        FormRow(label: "Work email", shown: .value("sam.pro@example.test", .proAccount, unsure: false)),
        FormRow(label: "Company", shown: .value("AcmeCorp", .memories, unsure: false)),
        FormRow(label: "Subject", shown: .value("Demo for AcmeCorp", .request, unsure: true)),
        FormRow(label: "Phone", shown: .notKnown),
        FormRow(label: "Street", shown: .neverTyped),
    ]
    private static let lines = [
        "First name — Sam · from your memories",
        "Work email — sam.pro@example.test · from your Pro account",
        "Company — AcmeCorp · from your memories",
        "Subject — Demo for AcmeCorp · written from the request · check this",
        "Phone — left empty · not known",
        "Street — left empty · never typed",
    ]

    private func question(_ kind: FormQuestion.Kind, destination: String? = nil, changed: Bool = false,
                          askedAt: ContinuousClock.Instant = .now) -> ConfirmationRequest {
        let target = ObservedElement(index: 0, role: kind == .fill ? "textbox" : "button",
                                     name: kind == .fill ? "First name" : "Request a demo", text: "", href: nil,
                                     inputType: nil, heading: nil, region: .main, inViewport: true, context: nil,
                                     formAction: "https://site-440.test/thanks", formMethod: "post",
                                     formSubmitLabel: "Request a demo", options: nil, checked: nil)
        let action = AgentAction(operation: kind == .fill ? .type : .click, target: target, destination: nil,
                                 payload: nil, isPlannedSearch: false)
        return ConfirmationRequest(action: action, tab: BrowserTab(windowID: "1", tabID: "2"),
                                   pageURL: "https://site-440.test/?ref=ad", askedAt: askedAt,
                                   form: FormQuestion(kind: kind, host: "site-440.test", destination: destination,
                                                      rows: Self.rows, changed: changed))
    }

    private let working = ErrandEvent.working(title: "Request a demo on site four forty", done: 0, wanted: nil)

    // MARK: - Reading the form

    func testReadingTheFormIsTheBoardsWorkingCard() {
        let reading = card(working, .readingForm(host: "site-440.test"))
        XCTAssertEqual(reading.tone, .plain)
        XCTAssertEqual(reading.glyph, .globe)
        XCTAssertEqual(reading.label, "Working")
        XCTAssertEqual(reading.source, "Chrome · background tab")
        XCTAssertEqual(reading.title, "Opening the form on site-440.test")
        XCTAssertEqual(reading.body, "Reading its fields.")
        XCTAssertEqual(reading.bar, .sliding)
        XCTAssertEqual(reading.buttons, [button("Stop", .stop), button("Stop all", .stopAll)])
        XCTAssertTrue(reading.rows.isEmpty)
        XCTAssertFalse(reading.hasEnded)
    }

    // MARK: - The preview

    /// Board 2's preview, line for line: every field with its value and where
    /// it came from — or left empty and why — [Fill] [No], and no time limit.
    func testThePreviewShowsEveryFieldWithItsValueAndSource() {
        let request = question(.fill)
        let preview = card(working, .readingForm(host: "site-440.test"), .needsYes(request))
        XCTAssertEqual(preview.tone, .yourMove)
        XCTAssertEqual(preview.glyph, .pen)
        XCTAssertEqual(preview.label, "Preview")
        XCTAssertEqual(preview.source, "Chrome · site-440.test")
        XCTAssertEqual(preview.title, "Fill the form on site-440.test?")
        XCTAssertEqual(preview.rows, Self.lines)
        XCTAssertEqual(preview.body, "")
        XCTAssertEqual(preview.meta, "Passwords, codes and card numbers are never typed.")
        XCTAssertEqual(preview.bar, .none, "no timer: the preview waits for the user")
        XCTAssertNil(preview.countdown(at: .now + .seconds(119)))
        XCTAssertEqual(preview.buttons, [button("Fill", .yes, primary: true), button("No", .no)])
        XCTAssertEqual(preview.question, request)
    }

    /// A form set to send to another site names that site.
    func testAPreviewOfAFormSetToSendToAnotherSiteNamesThatSite() {
        let preview = card(working, .needsYes(question(.fill, destination: "forms.example.test")))
        XCTAssertEqual(preview.title, "Fill the form on site-440.test? It is set to send to forms.example.test.")
    }

    // MARK: - Send

    /// The Send question names the fields it sends and shows their values
    /// (decision 7.3); two minutes of silence is No.
    func testTheSendQuestionNamesTheFieldsAndShowsTheirValues() {
        let asked = ContinuousClock.now
        let request = question(.send, askedAt: asked)
        let send = card(working, .needsYes(request))
        XCTAssertEqual(send.tone, .yourMove)
        XCTAssertEqual(send.glyph, .send)
        XCTAssertEqual(send.label, "Needs your Yes")
        XCTAssertEqual(send.source, "Chrome · site-440.test")
        XCTAssertEqual(send.title, "Send the form on site-440.test: first name, work email, company, subject?")
        XCTAssertEqual(send.rows, Self.lines)
        XCTAssertEqual(send.body, "No answer in 2:00 counts as No.")
        XCTAssertEqual(send.meta, "")
        XCTAssertEqual(send.bar, .countdown)
        XCTAssertEqual(send.countdown(at: asked), ErrandCard.Countdown(time: "2:00", fractionLeft: 1))
        XCTAssertEqual(send.buttons, [button("Send", .yes, primary: true), button("No", .no)])
    }

    /// The question asked again after the site changed a value says so; a
    /// form set to send elsewhere names where.
    func testASendAfterTheSiteChangedAValueSaysSo() {
        let send = card(working, .needsYes(question(.send, destination: "forms.example.test", changed: true)))
        XCTAssertEqual(send.title, "Send the form on site-440.test: first name, work email, company, subject? "
                       + "It is set to send to forms.example.test.")
        XCTAssertEqual(send.body, "The site changed a value after Fill. No answer in 2:00 counts as No.")
    }

    // MARK: - The ending

    private func ended(_ form: FormEnding, _ ending: ErrandRecord.Ending, sources: [URL] = []) -> ErrandCard {
        card(working, .finished(ErrandOutcome(ending: ending, answer: nil, sources: sources, sheet: nil, rows: 0,
                                              form: form)))
    }

    /// Board 2's sent card: the fields sent, by the page's own labels.
    func testSentIsTheBoardsCard() {
        let sent = ended(FormEnding(kind: .sent, host: "site-440.test", kinds: ["first name", "email", "company"],
                                    labels: ["First name", "Work email", "Company"]), .done,
                         sources: [URL(string: "https://site-440.test/thanks")!])
        XCTAssertEqual(sent.tone, .done)
        XCTAssertEqual(sent.glyph, .check)
        XCTAssertEqual(sent.label, "Sent")
        XCTAssertEqual(sent.source, "Chrome · site-440.test")
        XCTAssertEqual(sent.title, "Sent after your Yes.")
        XCTAssertEqual(sent.body, "First name, work email, company.")
        XCTAssertEqual(sent.bar, .progress(1, muted: false))
        XCTAssertEqual(sent.buttons, [button("Open in MetaChat", .openInMetaChat)])
        XCTAssertTrue(sent.hasEnded)
        XCTAssertNil(sent.question)
    }

    /// Every other ending's title is MetaChat's line for it; the user's No
    /// stopped it, the rest are the user's to do. The details missing name
    /// the fields (decision 7.1).
    func testEveryOtherFormEndingIsMetaChatsLine() {
        let cases: [(FormEnding, ErrandRecord.Ending, String, String, ErrandCard.Tone, String)] = [
            (FormEnding(kind: .notConfirmed, host: "site-440.test", url: "https://site-440.test/"), .needsUser,
             "Not confirmed: Send was pressed on site-440.test after your Yes, but the next page did not show the form "
                + "was received. Check it: https://site-440.test/", "Yours to do", .yourMove, ""),
            (FormEnding(kind: .notFilled, host: "site-440.test"), .stopped,
             "Not filled: you said No. Nothing was typed into the form on site-440.test.", "Stopped", .plain, ""),
            (FormEnding(kind: .notSent, host: "site-440.test"), .stopped,
             "Not sent: you said No. The form on site-440.test was filled, not sent.", "Stopped", .plain, ""),
            (FormEnding(kind: .notSent, host: "site-440.test", silence: true), .stopped,
             "Not sent: no answer in 2:00. The form on site-440.test was filled, not sent.", "Stopped", .plain, ""),
            (FormEnding(kind: .keptChanging, host: "site-440.test"), .needsUser,
             "Not sent: the form on site-440.test kept changing after your Yes. Fill it in yourself, or ask again.",
             "Yours to do", .yourMove, ""),
            (FormEnding(kind: .detailsMissing, host: "site-440.test", labels: ["Phone", "Work email"]), .needsUser,
             "Not filled: the form on site-440.test asks for details your memories do not hold. Tell MetaChat to "
                + "remember them (for example, \"remember my phone is ...\"), then ask again.",
             "Yours to do", .yourMove, "Phone, work email."),
        ]
        for (form, ending, title, label, tone, body) in cases {
            let shown = ended(form, ending)
            XCTAssertEqual(shown.title, title, "\(form.kind)")
            XCTAssertEqual(shown.label, label, "\(form.kind)")
            XCTAssertEqual(shown.tone, tone, "\(form.kind)")
            XCTAssertEqual(shown.body, body, "\(form.kind)")
            XCTAssertEqual(shown.source, "Chrome · site-440.test", "\(form.kind)")
            XCTAssertEqual(shown.buttons, [button("Open in MetaChat", .openInMetaChat)], "\(form.kind)")
            XCTAssertTrue(shown.hasEnded)
        }
    }
}
