import XCTest
@testable import MetaWhisp

/// ITER-076 I-11 — the errand card's model: from an errand's events to what its
/// card shows. The six states board 3 of the approved "Jev agent interface"
/// draws are checked against the board's own texts for the board's own sample
/// data (`work/ref/design/Cards.dc.html`, `CARDS`); every other state uses the
/// board's layout with the app's existing lines where one exists.
@MainActor
final class ErrandCardTests: XCTestCase {

    private let id = UUID()

    // MARK: - Fixtures

    private func control(role: String = "button", name: String, text: String? = nil,
                         formAction: String? = nil, formMethod: String? = nil, submitLabel: String? = nil,
                         submits: Bool? = nil, value: String? = nil) -> ObservedElement {
        ObservedElement(index: 0, role: role, name: name, text: text ?? name, href: nil, inputType: nil,
                        heading: "Contact", region: .main, inViewport: true, context: nil,
                        formAction: formAction, formMethod: formMethod, formSubmitLabel: submitLabel,
                        options: nil, checked: nil, submits: submits, value: value)
    }

    /// The board's question: the contact form on example.com, sent by its
    /// own "Send" button.
    private func formSend(askedAt: ContinuousClock.Instant = .now) -> ConfirmationRequest {
        let send = control(name: "Send", formAction: "https://example.com/contact", formMethod: "post",
                           submitLabel: "Send", submits: true)
        return question(AgentAction(operation: .click, target: send, destination: nil, payload: nil,
                                    isPlannedSearch: false), askedAt: askedAt)
    }

    private func question(_ action: AgentAction, page: String = "https://example.com/contact?session=abc123",
                          askedAt: ContinuousClock.Instant = .now) -> ConfirmationRequest {
        ConfirmationRequest(action: action, tab: BrowserTab(windowID: "1", tabID: "2"), pageURL: page,
                            askedAt: askedAt)
    }

    private func card(_ events: ErrandEvent...) -> ErrandCard {
        events.reduce(ErrandCard(id: id)) { $0.showing($1) }
    }

    private func labels(_ card: ErrandCard) -> [String] { card.buttons.map(\.label) }
    private func primaries(_ card: ErrandCard) -> [String] { card.buttons.filter(\.primary).map(\.label) }

    private let sheet = URL(string: "https://docs.google.com/spreadsheets/d/abc/edit")!

    // MARK: - The six states the board draws

    func testWorkingIsTheBoardsCard() {
        let working = card(.working(title: "Finding competitors", done: 3, wanted: 10))
        XCTAssertEqual(working.tone, .plain)
        XCTAssertEqual(working.glyph, .globe)
        XCTAssertEqual(working.label, "Working")
        XCTAssertEqual(working.source, "Chrome · background tab")
        XCTAssertEqual(working.title, "Finding competitors — 3 of 10")
        XCTAssertEqual(working.body, "One row per site, into a new Google Sheet.")
        XCTAssertEqual(working.meta, "")
        XCTAssertEqual(working.bar, .progress(0.3, muted: false))
        XCTAssertEqual(working.buttons, [ErrandCard.Button(label: "Stop", action: .stop, primary: false),
                                         ErrandCard.Button(label: "Stop all", action: .stopAll, primary: false)])
        XCTAssertFalse(working.hasEnded, "a running errand's card has no close and never fades")
    }

    /// The board's title lists the form's fields ("…: name, email, company,
    /// message?"). The request names none — it holds the send button, the
    /// page and the time — so the card asks the board's question without the
    /// list (reported to the owner with the other lines).
    func testNeedsYourYesIsTheBoardsCard() {
        let asked = ContinuousClock.now
        let request = formSend(askedAt: asked)
        let yes = card(.working(title: "Demo request", done: 0, wanted: nil), .needsYes(request))
        XCTAssertEqual(yes.tone, .yourMove)
        XCTAssertEqual(yes.glyph, .send)
        XCTAssertEqual(yes.label, "Needs your Yes")
        XCTAssertEqual(yes.source, "Chrome · example.com")
        XCTAssertEqual(yes.title, "Send the form on example.com?")
        XCTAssertEqual(yes.body, "No answer in 2:00 counts as No.")
        XCTAssertEqual(yes.bar, .countdown)
        XCTAssertEqual(yes.countdown(at: asked), ErrandCard.Countdown(time: "2:00", fractionLeft: 1))
        XCTAssertEqual(yes.buttons, [ErrandCard.Button(label: "Send", action: .yes, primary: true),
                                     ErrandCard.Button(label: "No", action: .no, primary: false)])
        XCTAssertEqual(yes.question, request)
        XCTAssertFalse(yes.hasEnded)
    }

    /// A sign-in that ends the errand at once — a wall whose page could not
    /// be read — is no pause (ITER-076 stage 3: the pause is `.paused`). The
    /// card shows the board's lines that are true then and none that promise
    /// a wait or a Continue.
    func testSignInNeededIsTheBoardsCardWithoutThePause() {
        let signIn = card(.working(title: "Order status", done: 0, wanted: nil),
                          .needsUser(ErrandHandover(kind: .signIn, host: "example.com")))
        XCTAssertEqual(signIn.tone, .yourMove)
        XCTAssertEqual(signIn.glyph, .lock)
        XCTAssertEqual(signIn.label, "Sign-in needed")
        XCTAssertEqual(signIn.source, "Chrome · example.com")
        XCTAssertEqual(signIn.title, "example.com asks you to sign in")
        XCTAssertEqual(signIn.body, "", "no Continue exists to sign in and then continue with")
        XCTAssertEqual(signIn.meta, "", "the errand does not wait 10 minutes")
        XCTAssertEqual(labels(signIn), ["Stop"])
        XCTAssertFalse(labels(signIn).contains("Continue"))
        XCTAssertFalse(labels(signIn).contains("Show tab"), "no existing call brings the agent's tab to the front")
    }

    // MARK: - The pause (ITER-076 stage 3, № 10)

    private func button(_ label: String, _ action: ErrandCard.Action, primary: Bool = false) -> ErrandCard.Button {
        ErrandCard.Button(label: label, action: action, primary: primary)
    }

    /// The board's own sign-in card, line for line (`Cards.dc.html:154`,
    /// `Main.dc.html:506-512`): the errand waits, and the card says so.
    func testASignInPauseIsTheBoardsSignInCard() {
        let pause = ErrandPause(id: UUID(), handover: ErrandHandover(kind: .signIn, host: "example.com"))
        let paused = card(.working(title: "Order status", done: 0, wanted: nil), .paused(pause))
        XCTAssertEqual(paused.tone, .yourMove)
        XCTAssertEqual(paused.glyph, .lock)
        XCTAssertEqual(paused.label, "Sign-in needed")
        XCTAssertEqual(paused.source, "Chrome · example.com")
        XCTAssertEqual(paused.title, "example.com asks you to sign in")
        XCTAssertEqual(paused.body, "Sign in yourself, then continue.")
        XCTAssertEqual(paused.meta, "Waits up to 10 min, then the errand stops.")
        XCTAssertEqual(paused.bar, .none)
        XCTAssertEqual(paused.buttons, [button("Show tab", .showTab), button("Continue", .proceed, primary: true),
                                        button("Stop", .stop)])
        XCTAssertEqual(paused.pause, pause)
        XCTAssertFalse(paused.hasEnded, "a waiting errand's card has no close")
    }

    /// A CAPTCHA, a grant and a file keep the titles I-11 gave them, with the
    /// sign-in card's body, meta and buttons: no new line (stage 3 brief, 3A
    /// item 1).
    func testACaptchaAGrantOrAFilePauseKeepsItsTitleWithThePausesLines() {
        let cases: [(ErrandHandover.Kind, String, ErrandCard.Glyph)] = [
            (.captcha, "example.com asks you to solve a CAPTCHA", .lock),
            (.grant, "This page asks to give access.", .key),
            (.file, "This form asks for a file from your Mac.", .key),
            // The owner's words of 2026-10-06 (approval page item 5).
            (.cookies, "example.com asks about cookies", .key),
        ]
        for (kind, title, glyph) in cases {
            let pause = ErrandPause(id: UUID(), handover: ErrandHandover(kind: kind, host: "example.com"))
            let paused = card(.paused(pause))
            XCTAssertEqual(paused.title, title, "\(kind)")
            XCTAssertEqual(paused.label, "Yours to do", "\(kind)")
            XCTAssertEqual(paused.glyph, glyph, "\(kind)")
            XCTAssertEqual(paused.source, "Chrome · example.com", "\(kind)")
            // Only a sign-in says "Sign in yourself" and a CAPTCHA "Do the check
            // yourself" (the owner's words of 2026-10-06, approval page item 6):
            // every other part keeps its own approved body.
            XCTAssertEqual(paused.body, kind == .captcha ? "Do the check yourself, then continue." : "That is yours to do.",
                           "\(kind)")
            XCTAssertEqual(paused.meta, "Waits up to 10 min, then the errand stops.", "\(kind)")
            XCTAssertEqual(labels(paused), ["Show tab", "Continue", "Stop"], "\(kind)")
            XCTAssertEqual(paused.pause, pause, "\(kind)")
        }
    }

    /// Continue and Show tab belong to the pause: once the errand works again,
    /// or ends, the card offers neither.
    func testThePausesButtonsGoWithThePause() {
        let pause = ErrandPause(id: UUID(), handover: ErrandHandover(kind: .signIn, host: "example.com"))
        let working = ErrandEvent.working(title: "Order status", done: 0, wanted: nil)
        let again = card(working, .paused(pause), working)
        XCTAssertNil(again.pause)
        XCTAssertEqual(labels(again), ["Stop", "Stop all"])
        let ended = card(working, .paused(pause),
                         .finished(ErrandOutcome(ending: .needsUser, answer: nil, sources: [], sheet: nil, rows: 0)))
        XCTAssertNil(ended.pause)
        XCTAssertFalse(labels(ended).contains("Continue"))
        XCTAssertFalse(labels(ended).contains("Show tab"))
        XCTAssertEqual(ended.label, "Sign-in needed", "the end keeps what it waited for")
        XCTAssertEqual(ended.glyph, .lock)
        XCTAssertTrue(ended.hasEnded)
    }

    func testYoursToDoIsTheBoardsCard() {
        let grant = card(.needsUser(ErrandHandover(kind: .grant, host: "example.com")))
        XCTAssertEqual(grant.tone, .yourMove)
        XCTAssertEqual(grant.glyph, .key)
        XCTAssertEqual(grant.label, "Yours to do")
        XCTAssertEqual(grant.source, "Chrome · example.com")
        XCTAssertEqual(grant.title, "This page asks to give access.")
        XCTAssertEqual(grant.body, "That is yours to do.")
        XCTAssertEqual(grant.meta, "The agent never clicks it, even after a Yes.")
        XCTAssertEqual(grant.buttons, [ErrandCard.Button(label: "Stop", action: .stop, primary: false)])
    }

    /// The board's title is "Stopped: going in circles."; every ending's
    /// title is MetaChat's approved line for it (one source for every
    /// ending), which for an errand that was going nowhere is
    /// "Stopped: the errand was not getting anywhere."
    func testStoppedIsTheBoardsCard() {
        let stopped = card(.working(title: "MetaWhisp competitors", done: 4, wanted: 10),
                           .finished(ErrandOutcome(ending: .stuck, answer: nil, sources: [], sheet: sheet, rows: 4)))
        XCTAssertEqual(stopped.tone, .plain)
        XCTAssertEqual(stopped.glyph, .stop)
        XCTAssertEqual(stopped.label, "Stopped")
        XCTAssertEqual(stopped.source, "Sheet · MetaWhisp competitors")
        XCTAssertEqual(stopped.title, "Stopped: the errand was not getting anywhere.")
        XCTAssertEqual(stopped.body, "4 rows saved.")
        XCTAssertEqual(stopped.bar, .progress(0.4, muted: true))
        XCTAssertTrue(stopped.hasEnded, "an ended errand's card can be closed")
        XCTAssertEqual(stopped.sheet, sheet)
        XCTAssertEqual(stopped.buttons, [ErrandCard.Button(label: "Open sheet", action: .openSheet, primary: true),
                                         ErrandCard.Button(label: "Open in MetaChat", action: .openInMetaChat,
                                                           primary: false)])
    }

    /// The board's title is "Done: 10 rows"; MetaChat's approved line ends
    /// with a full stop.
    func testDoneIsTheBoardsCard() {
        let done = card(.working(title: "MetaWhisp competitors", done: 10, wanted: 10),
                        .finished(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: sheet, rows: 10)))
        XCTAssertEqual(done.tone, .done)
        XCTAssertEqual(done.glyph, .check)
        XCTAssertEqual(done.label, "Done")
        XCTAssertEqual(done.source, "Sheet · MetaWhisp competitors")
        XCTAssertEqual(done.title, "Done: 10 rows.")
        XCTAssertEqual(done.body, "Every row keeps its source.")
        XCTAssertEqual(done.bar, .progress(1, muted: false))
        XCTAssertTrue(done.hasEnded)
        XCTAssertEqual(done.buttons, [ErrandCard.Button(label: "Open sheet", action: .openSheet, primary: true),
                                      ErrandCard.Button(label: "Open in MetaChat", action: .openInMetaChat,
                                                        primary: false)])
    }

    // MARK: - The errand's own data in its places

    func testAWorkingTitleWithoutACountHasNoCountAndNoBar() {
        let words = card(.working(title: "Ten jokes", done: 2, wanted: nil))
        XCTAssertEqual(words.title, "Ten jokes")
        XCTAssertEqual(words.bar, .none)
        XCTAssertEqual(words.body, "", "no rows, no Sheet")
    }

    func testMoreDoneThanWantedIsCapped() {
        let over = card(.working(title: "Shops", done: 12, wanted: 10))
        XCTAssertEqual(over.title, "Shops — 10 of 10")
        XCTAssertEqual(over.bar, .progress(1, muted: false))
    }

    func testAnEmptyPlanTitleShowsTheLabelAlone() {
        let empty = card(.working(title: "  ", done: 1, wanted: 4))
        XCTAssertEqual(empty.label, "Working")
        XCTAssertEqual(empty.title, "", "no stray \"— 1 of 4\" without a title")
        XCTAssertEqual(empty.bar, .progress(0.25, muted: false))
    }

    /// The title is kept whole, in any script: the card's layout truncates it,
    /// the model never cuts a word.
    func testALongTitleInAnyScriptIsKeptWhole() {
        let long = String(repeating: "競合他社 المنافسون Ανταγωνιστές ", count: 7) + "end"
        let working = card(.working(title: long, done: 1, wanted: 3))
        XCTAssertEqual(working.title, long + " — 1 of 3")
    }

    func testAQuestionClosedShowsTheWorkAgain() {
        let working = ErrandEvent.working(title: "Demo request", done: 0, wanted: nil)
        let back = card(working, .needsYes(formSend()), working)
        XCTAssertEqual(back.label, "Working")
        XCTAssertNil(back.question, "the question is closed: no Yes is offered any more")
        XCTAssertFalse(labels(back).contains("Send"))
    }

    // MARK: - The countdown

    /// The time left of the answer window, from the question's own `askedAt`:
    /// it reaches 0:00 as the service turns silence into No, and stays there.
    func testTheCountdownRunsFromItsOwnQuestionToZero() {
        let asked = ContinuousClock.now
        let yes = card(.needsYes(formSend(askedAt: asked)))
        XCTAssertEqual(yes.countdown(at: asked + .seconds(30)), ErrandCard.Countdown(time: "1:30", fractionLeft: 0.75))
        XCTAssertEqual(yes.countdown(at: asked + .milliseconds(500))?.time, "2:00", "a second shows until it is over")
        XCTAssertEqual(yes.countdown(at: asked + .seconds(110))?.time, "0:10")
        XCTAssertEqual(yes.countdown(at: asked + .milliseconds(119_400))?.time, "0:01")
        XCTAssertEqual(yes.countdown(at: asked + .seconds(120)), ErrandCard.Countdown(time: "0:00", fractionLeft: 0))
        XCTAssertEqual(yes.countdown(at: asked + .seconds(500)), ErrandCard.Countdown(time: "0:00", fractionLeft: 0))
        XCTAssertNil(card(.working(title: "A", done: 0, wanted: nil)).countdown(at: asked), "no question, no time")
    }

    // MARK: - The question: what will be done, and on which site

    /// The primary button is the action's own word: the board's "Send" for a
    /// form send, the control's own English action word when it has one.
    func testTheYesButtonIsTheActionsOwnWord() {
        func yesWord(_ action: AgentAction) -> String? {
            primaries(card(.needsYes(question(action)))).first
        }
        let delete = control(name: "Delete account")
        XCTAssertEqual(yesWord(AgentAction(operation: .click, target: delete, destination: nil, payload: nil,
                                           isPlannedSearch: false)), "Delete")
        // A form whose button says nothing the lexicon knows, in any language.
        let anyLanguage = control(name: "Absenden", formAction: "https://example.com/contact", formMethod: "post",
                                  submitLabel: "Absenden", submits: true)
        XCTAssertEqual(yesWord(AgentAction(operation: .click, target: anyLanguage, destination: nil, payload: nil,
                                           isPlannedSearch: false)), "Send")
        // The word is the clicked control's own, not another button's of its form.
        let next = control(name: "Next", formAction: "https://example.com/account", formMethod: "post",
                           submitLabel: "Delete account")
        XCTAssertEqual(yesWord(AgentAction(operation: .click, target: next, destination: nil, payload: nil,
                                           isPlannedSearch: false)), "Send")
        let link = control(role: "link", name: "Pricing")
        XCTAssertEqual(yesWord(AgentAction(operation: .open, target: link, destination: "https://shop.example.org/plans",
                                           payload: nil, isPlannedSearch: false)), "Open")
        let plain = control(name: "Next")
        XCTAssertEqual(yesWord(AgentAction(operation: .click, target: plain, destination: nil, payload: nil,
                                           isPlannedSearch: false)), "Click")
        let field = control(role: "textbox", name: "Comment")
        XCTAssertEqual(yesWord(AgentAction(operation: .type, target: field, destination: nil, payload: "hello",
                                           isPlannedSearch: false)), "Type")
        let picker = control(role: "combobox", name: "Plan")
        XCTAssertEqual(yesWord(AgentAction(operation: .select, target: picker, destination: nil, payload: "Pro",
                                           isPlannedSearch: false)), "Choose")
    }

    func testEachQuestionSaysWhatWillBeDoneAndWhere() {
        func title(_ action: AgentAction, page: String = "https://example.com/contact") -> String {
            card(.needsYes(question(action, page: page))).title
        }
        let delete = control(name: "Delete account")
        XCTAssertEqual(title(AgentAction(operation: .click, target: delete, destination: nil, payload: nil,
                                         isPlannedSearch: false)), "Click “Delete account” on example.com?")
        let link = control(role: "link", name: "Pricing")
        XCTAssertEqual(title(AgentAction(operation: .open, target: link, destination: "https://shop.example.org/plans?t=9",
                                         payload: nil, isPlannedSearch: false)), "Open a page on shop.example.org?")
        let field = control(role: "textbox", name: "Comment")
        XCTAssertEqual(title(AgentAction(operation: .type, target: field, destination: nil, payload: "hello",
                                         isPlannedSearch: false)), "Type into “Comment” on example.com?")
        let picker = control(role: "combobox", name: "Plan")
        XCTAssertEqual(title(AgentAction(operation: .select, target: picker, destination: nil, payload: "Pro",
                                         isPlannedSearch: false)), "Choose an option in “Plan” on example.com?")
        // A page with no host names no site.
        XCTAssertEqual(title(AgentAction(operation: .click, target: delete, destination: nil, payload: nil,
                                         isPlannedSearch: false), page: "about:blank"), "Click “Delete account”?")
        XCTAssertEqual(card(.needsYes(question(AgentAction(operation: .click, target: delete, destination: nil,
                                                          payload: nil, isPlannedSearch: false),
                                               page: "about:blank"))).source, "Chrome")
    }

    /// A control's name is the request's own; a very long one is shortened so
    /// the question still names the site.
    func testAVeryLongControlNameIsShortened() {
        let long = String(repeating: "Remove ", count: 30)
        let action = AgentAction(operation: .click, target: control(name: long), destination: nil, payload: nil,
                                 isPlannedSearch: false)
        let title = card(.needsYes(question(action))).title
        XCTAssertTrue(title.hasSuffix("…” on example.com?"), title)
        XCTAssertLessThanOrEqual(title.count, 100)
    }

    /// The card shows the host and what the request itself names — never a
    /// typed value, a chosen option, a field's value, the rest of an address,
    /// an answer, a source or a Sheet's address.
    func testTheCardNeverShowsPageTextBeyondTheHostAndWhatTheRequestNames() {
        let secretValue = "hunter2-typed"
        let field = control(role: "textbox", name: "Password", text: "visible-words-\(secretValue)", value: secretValue)
        let typed = AgentAction(operation: .type, target: field, destination: nil, payload: secretValue,
                                isPlannedSearch: false)
        let option = AgentAction(operation: .select, target: control(role: "combobox", name: "Card",
                                                                     value: "4111-chosen"),
                                 destination: nil, payload: "4111-chosen", isPlannedSearch: false)
        let open = AgentAction(operation: .open, target: control(role: "link", name: "Reset"),
                               destination: "https://example.org/reset?token=tok-SECRET-1#code=SECRET-2", payload: nil,
                               isPlannedSearch: false)
        let page = "https://user:pw-SECRET@example.com/account/SECRET-path?key=SECRET-query#SECRET-fragment"
        let outcome = ErrandOutcome(ending: .done, answer: "SECRET-answer from the page", sources: [
            URL(string: "https://source.test/SECRET-source")!], sheet: URL(string: "https://sheets.test/SECRET-sheet")!,
            rows: 1)
        let cards = [card(.needsYes(question(typed, page: page))), card(.needsYes(question(option, page: page))),
                     card(.needsYes(question(open, page: page))),
                     card(.working(title: "Shops", done: 1, wanted: 2), .finished(outcome))]
        for shown in cards {
            let texts = [shown.label, shown.source, shown.title, shown.body, shown.meta] + labels(shown)
            for text in texts {
                for secret in [secretValue, "4111", "SECRET", "pw-", "visible-words"] {
                    XCTAssertFalse(text.contains(secret), "\(text) shows \(secret)")
                }
            }
        }
        // A secret field's name may show; its value never does.
        XCTAssertEqual(cards[0].title, "Type into “Password” on example.com?")
    }

    // MARK: - Endings: MetaChat's approved line, one source for every ending

    func testEveryEndingsTitleIsMetaChatsLine() {
        var outcomes: [ErrandOutcome] = ErrandRecord.Ending.allCases.map {
            ErrandOutcome(ending: $0, answer: nil, sources: [], sheet: nil, rows: 0)
        }
        outcomes += ErrandOutcome.NotRun.allCases.map {
            ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0, notRun: $0)
        }
        for outcome in outcomes {
            let ended = card(.finished(outcome))
            XCTAssertEqual(ended.title, ChatService.errandResultText(outcome), "\(outcome.ending) \(String(describing: outcome.notRun))")
            XCTAssertTrue(ended.hasEnded)
            XCTAssertTrue(labels(ended).contains("Open in MetaChat"), "every result is in MetaChat")
            XCTAssertFalse(labels(ended).contains("Stop"))
        }
    }

    func testEachEndingHasItsLabelToneAndGlyph() {
        func ended(_ ending: ErrandRecord.Ending) -> ErrandCard {
            card(.finished(ErrandOutcome(ending: ending, answer: nil, sources: [], sheet: nil, rows: 0)))
        }
        for ending in [ErrandRecord.Ending.stopped, .stuck, .ceiling, .dailyLimit, .notFinished] {
            XCTAssertEqual(ended(ending).label, "Stopped", "\(ending)")
            XCTAssertEqual(ended(ending).tone, .plain)
            XCTAssertEqual(ended(ending).glyph, .stop)
        }
        for ending in [ErrandRecord.Ending.failed, .unavailable, .noPro] {
            XCTAssertEqual(ended(ending).label, "Failed", "\(ending)")
            XCTAssertEqual(ended(ending).tone, .plain)
            XCTAssertEqual(ended(ending).glyph, .stop)
        }
        XCTAssertEqual(ended(.done).label, "Done")
        XCTAssertEqual(ended(.done).source, "Chrome")
        XCTAssertEqual(ended(.done).bar, .progress(1, muted: false))
        XCTAssertEqual(labels(ended(.done)), ["Open in MetaChat"], "no Sheet, nothing to open but the result")
    }

    /// An answer in words stays in MetaChat: the card says where it is and
    /// never shows it.
    func testAnAnswerIsInMetaChatNotOnTheCard() {
        let answered = card(.working(title: "Ten jokes", done: 0, wanted: nil),
                            .finished(ErrandOutcome(ending: .done, answer: "Joke one. Joke two.", sources: [],
                                                    sheet: nil, rows: 0)))
        XCTAssertEqual(answered.title, "Done.")
        XCTAssertEqual(answered.body, "The answer is in MetaChat.")
        XCTAssertEqual(answered.source, "Chrome")
    }

    /// ITER-076 stage 2: an errand the verifier never said was done stops not
    /// finished, with what it found — the title is MetaChat's own line for
    /// it, the answer stays in MetaChat. One that found nothing was not
    /// getting anywhere: "found only part" would overstate it.
    func testANotFinishedErrandSaysMetaChatsLineForWhatItFound() {
        let cases: [(answer: String?, title: String, body: String)] = [
            ("Joke one.\nhttps://jokes.test/1", "Not finished: the agent found only part of what you asked.",
             "The answer is in MetaChat."),
            (nil, "Stopped: the errand was not getting anywhere.", "")]
        for (answer, title, body) in cases {
            let outcome = ErrandOutcome(ending: .notFinished, answer: answer,
                                        sources: answer == nil ? [] : [URL(string: "https://jokes.test/1")!],
                                        sheet: nil, rows: 0)
            let ended = card(.working(title: "Find 10 jokes", done: 0, wanted: nil), .finished(outcome))
            XCTAssertEqual(ended.title, title)
            XCTAssertEqual(ended.title, ChatService.errandResultText(outcome).components(separatedBy: "\n\n").first,
                           "MetaChat's own line")
            XCTAssertEqual(ended.label, "Stopped")
            XCTAssertEqual(ended.tone, .plain)
            XCTAssertEqual(ended.glyph, .stop)
            XCTAssertEqual(ended.body, body)
            XCTAssertEqual(ended.source, "Chrome")
            XCTAssertEqual(ended.bar, ErrandCard.Bar.none)
            XCTAssertEqual(labels(ended), ["Open in MetaChat"])
            XCTAssertTrue(ended.hasEnded)
        }
    }

    func testOneRowSavedIsSingular() {
        let one = card(.working(title: "Shops", done: 1, wanted: 5),
                       .finished(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 1)))
        XCTAssertEqual(one.body, "1 row saved.")
        XCTAssertEqual(one.bar, .progress(0.2, muted: true))
        XCTAssertEqual(one.source, "Chrome")
        XCTAssertEqual(labels(one), ["Open in MetaChat"])
    }

    /// I-12's default (owner question 2): a hand-over that ends the errand is
    /// an ending — MetaChat's line, closable, [Open in MetaChat], and no
    /// [Show tab], [Stop] or [Continue] — and keeps what it was and where.
    func testAHandOverThatEndedKeepsItsKindAndDropsItsButtons() {
        let ended = card(.needsUser(ErrandHandover(kind: .signIn, host: "example.com")),
                         .finished(ErrandOutcome(ending: .needsUser, answer: nil, sources: [], sheet: nil, rows: 0)))
        XCTAssertEqual(ended.label, "Sign-in needed")
        XCTAssertEqual(ended.tone, .yourMove)
        XCTAssertEqual(ended.glyph, .lock)
        XCTAssertEqual(ended.source, "Chrome · example.com")
        XCTAssertEqual(ended.title, "The errand needs you: sign in or finish that step yourself, then ask again.")
        XCTAssertTrue(ended.hasEnded)
        XCTAssertEqual(labels(ended), ["Open in MetaChat"])
    }

    /// A Sheet made before the end and known only after it: the card shows
    /// it once the service says so.
    func testAnAmendedEndingShowsTheSheet() {
        let stopped = ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 2)
        let first = card(.working(title: "Shops", done: 2, wanted: 4), .finished(stopped))
        XCTAssertEqual(first.source, "Chrome")
        let amended = first.showing(.amended(stopped.withSheet(sheet)))
        XCTAssertEqual(amended.source, "Sheet · Shops")
        XCTAssertEqual(amended.sheet, sheet)
        XCTAssertEqual(primaries(amended), ["Open sheet"])
        XCTAssertEqual(amended.title, "Stopped.")
    }

    /// The Sheet's address comes back from the browser: only a web address
    /// is ever offered to open.
    func testOnlyAWebSheetIsOffered() {
        for address in ["file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:"] {
            let outcome = ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: URL(string: address)!, rows: 1)
            let ended = card(.working(title: "Shops", done: 1, wanted: 1), .finished(outcome))
            XCTAssertNil(ended.sheet, address)
            XCTAssertEqual(labels(ended), ["Open in MetaChat"], address)
            XCTAssertEqual(ended.source, "Chrome", address)
        }
    }

    // MARK: - The states the board does not draw

    func testAQueuedErrandSaysItsPlaceInLine() {
        let next = card(.queued(position: 1))
        XCTAssertEqual(next.label, "Queued")
        XCTAssertEqual(next.title, "Next in line")
        XCTAssertEqual(next.tone, .plain)
        XCTAssertEqual(next.glyph, .globe)
        XCTAssertEqual(next.bar, .none)
        XCTAssertEqual(labels(next), ["Stop", "Stop all"])
        XCTAssertEqual(card(.queued(position: 2)).title, "2nd in line")
        XCTAssertEqual(card(.queued(position: 3)).title, "3rd in line")
    }

    func testConnectingToChromeUsesTheBoardsLines() {
        let connecting = card(.connecting(.connecting))
        XCTAssertEqual(connecting.label, "Connecting")
        XCTAssertEqual(connecting.source, "Chrome")
        XCTAssertEqual(connecting.title, "Connecting to Chrome")
        XCTAssertEqual(connecting.bar, .sliding)
        XCTAssertEqual(labels(connecting), ["Stop", "Stop all"])
        for state in [ChromeLink.State.idle, .notRunning, .notInstalled, .didNotStart, .remoteDebuggingOff, .notAllowed] {
            XCTAssertEqual(card(.connecting(state)).title, "Connecting to Chrome", "\(state): its end says why")
        }
        // Board 4's lines: the user's move is Chrome's Allow.
        let allow = card(.connecting(.waitingForAllow(browser: "Google Chrome")))
        XCTAssertEqual(allow.tone, .yourMove)
        XCTAssertEqual(allow.title, "Click Allow when Chrome asks.")
        XCTAssertEqual(allow.meta, "MetaWhisp never clicks Allow for you.")
        XCTAssertEqual(labels(allow), ["Stop", "Stop all"])
        // Board 1's planning card: connected, the run plans before its first row.
        let planning = card(.connecting(.connected(browser: "Google Chrome")))
        XCTAssertEqual(planning.label, "Planning")
        XCTAssertEqual(planning.source, "Chrome · background tab")
        XCTAssertEqual(planning.title, "Planning the errand")
        XCTAssertEqual(planning.bar, .sliding)
        XCTAssertEqual(labels(planning), ["Stop", "Stop all"])
    }

    func testTheOtherHandOversAreYoursToDo() {
        func handOver(_ kind: ErrandHandover.Kind, host: String = "example.com") -> ErrandCard {
            card(.needsUser(ErrandHandover(kind: kind, host: host)))
        }
        let captcha = handOver(.captcha)
        XCTAssertEqual(captcha.label, "Yours to do")
        XCTAssertEqual(captcha.glyph, .lock)
        XCTAssertEqual(captcha.title, "example.com asks you to solve a CAPTCHA")
        XCTAssertEqual(captcha.body, "That is yours to do.")
        let payment = handOver(.payment)
        XCTAssertEqual(payment.label, "Yours to do")
        XCTAssertEqual(payment.glyph, .key)
        XCTAssertEqual(payment.title, "This page asks for a payment.")
        XCTAssertEqual(payment.body, "That is yours to do.")
        XCTAssertEqual(payment.meta, "The agent never pays, even after a Yes.")
        let file = handOver(.file)
        XCTAssertEqual(file.label, "Yours to do")
        XCTAssertEqual(file.glyph, .key)
        XCTAssertEqual(file.title, "This form asks for a file from your Mac.")
        XCTAssertEqual(file.body, "That is yours to do.")
        for kind in ErrandHandover.Kind.allCases {
            XCTAssertEqual(handOver(kind).tone, .yourMove, "\(kind)")
            XCTAssertEqual(labels(handOver(kind)), ["Stop"], "\(kind)")
        }
        // An unknown site: the label alone, and no site named.
        let nowhere = handOver(.signIn, host: "")
        XCTAssertEqual(nowhere.title, "")
        XCTAssertEqual(nowhere.source, "Chrome")
        XCTAssertEqual(handOver(.captcha, host: "").title, "")
    }
}
