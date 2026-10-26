import Foundation

/// What one errand's card shows (ITER-076 I-11), as board 3 of the approved
/// "Jev agent interface" draws it: a badge whose colour is a state — plain
/// while it works or once it stopped, orange when it is the user's move, green
/// when it is done — a label and a source line, a title, a body, a status row
/// (a bar, a line, the time left to answer) and buttons.
///
/// Built from the errand's own events alone, so it shows what the service
/// says and nothing before: it never claims "Stopped" until the service ended
/// the errand, nor a pause the run does not make. It shows no page text beyond
/// a host and what a question's own action names — never a typed value, a
/// field's value, a chosen option, the rest of an address, an answer or a
/// source. The work's title is the service's: a plan's title, or an answer
/// errand's own words, the user's (ITER-076 brain). Every ending's title is
/// MetaChat's approved line for it.
struct ErrandCard: Equatable {
    enum Tone: Equatable { case plain, yourMove, done }
    enum Glyph: Equatable { case globe, send, lock, key, stop, check, pen }
    enum Action: Equatable { case stop, stopAll, yes, no, openSheet, openInMetaChat, proceed, showTab }

    struct Button: Equatable {
        let label: String
        let action: Action
        let primary: Bool
    }

    /// The status row's bar.
    enum Bar: Equatable {
        case none
        /// Rows done of rows wanted, 0...1; muted once the errand stopped.
        case progress(Double, muted: Bool)
        /// The time left to answer: `countdown(at:)`.
        case countdown
        /// Under way, how far unknown.
        case sliding
    }

    /// The time left to answer a question, as the card shows it.
    struct Countdown: Equatable {
        /// "m:ss", counted up to the whole second, so it reads 0:00 exactly
        /// when silence becomes No.
        let time: String
        let fractionLeft: Double
    }

    let id: UUID
    private(set) var tone = Tone.plain
    private(set) var glyph = Glyph.globe
    private(set) var label = ""
    private(set) var source = ""
    private(set) var title = ""
    private(set) var body = ""
    private(set) var meta = ""
    private(set) var bar = Bar.none
    /// The question the card asks, while it is open.
    private(set) var question: ConfirmationRequest?
    /// The user's part the errand waits for, while it does (ITER-076 stage 3).
    private(set) var pause: ErrandPause?
    /// The errand's Sheet, once it ended with one.
    private(set) var sheet: URL?
    private(set) var buttons: [Button] = []
    /// A form's fields, one line each, under the title (ITER-076 stage 7):
    /// "<label> — <value> · <source>", or left empty and why. Values are
    /// shown (decision 7.3); the page marks none of them secret — a field it
    /// marks secret is never reported, so never here.
    private(set) var rows: [String] = []
    /// The errand ended: the card can be closed, and closes by itself.
    private(set) var hasEnded = false
    /// The errand's place in the queue while it waits; 1 is next.
    private(set) var placeInLine: Int?
    /// The title ends with its count of rows ("— 3 of 10"): the layout keeps
    /// that end in sight however long the plan's title is.
    private(set) var titleEndsWithCount = false

    // What earlier events said, for the ones after: the plan's title (the
    // Sheet's), how many rows it wants, and what was handed over.
    private var planTitle = ""
    private var wanted: Int?
    private var handover: ErrandHandover?

    init(id: UUID) {
        self.id = id
    }

    /// The card once `event` is shown.
    @MainActor
    func showing(_ event: ErrandEvent) -> ErrandCard {
        var next = ErrandCard(id: id)
        next.planTitle = planTitle
        next.wanted = wanted
        next.handover = handover
        switch event {
        case .queued(let position):
            next.show(.plain, .globe, "Queued", title: Self.placeInLine(position), buttons: Self.stopButtons)
            next.placeInLine = position
        case .connecting(let state):
            next.connecting(state)
        case .working(let title, let done, let wanted):
            next.working(title: title, done: done, wanted: wanted)
        case .readingForm(let host):
            next.show(.plain, .globe, "Working", source: Self.background, title: "Opening the form on \(host)",
                      body: "Reading its fields.", bar: .sliding, buttons: Self.stopButtons)
        case .needsYes(let request):
            next.asking(request)
        case .needsUser(let handover):
            next.handover = handover
            next.handedOver(handover)
        case .paused(let pause):
            next.handover = pause.handover
            next.paused(pause)
        case .finished(let outcome), .amended(let outcome):
            next.ended(outcome)
        }
        return next
    }

    func countdown(at now: ContinuousClock.Instant) -> Countdown? {
        guard let question, let window = question.window else { return nil }
        let elapsed = now - question.askedAt
        let passed = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let left = min(window, max(0, window - passed))
        return Countdown(time: Self.clock(left.rounded(.up)), fractionLeft: left / window)
    }

    // MARK: - States

    private static let stopButtons = [Button(label: "Stop", action: .stop, primary: false),
                                      Button(label: "Stop all", action: .stopAll, primary: false)]
    private static let background = "Chrome · background tab"

    private mutating func show(_ tone: Tone, _ glyph: Glyph, _ label: String, source: String = "", title: String,
                               body: String = "", meta: String = "", bar: Bar = .none, rows: [String] = [],
                               buttons: [Button]) {
        self.tone = tone
        self.glyph = glyph
        self.label = label
        self.source = source
        self.title = title
        self.body = body
        self.meta = meta
        self.bar = bar
        self.rows = rows
        self.buttons = buttons
    }

    /// Board 4's lines while Chrome asks the user to Allow; board 1's
    /// planning card once connected, until the run's first progress. Every
    /// other state is the wait: a link that fails ends the errand, and its
    /// end says why.
    private mutating func connecting(_ state: ChromeLink.State) {
        switch state {
        case .waitingForAllow:
            show(.yourMove, .globe, "Connecting", source: "Chrome", title: "Click Allow when Chrome asks.",
                 meta: "MetaWhisp never clicks Allow for you.", bar: .sliding, buttons: Self.stopButtons)
        case .connected:
            show(.plain, .globe, "Planning", source: Self.background, title: "Planning the errand", bar: .sliding,
                 buttons: Self.stopButtons)
        case .idle, .connecting, .notRunning, .notInstalled, .didNotStart, .remoteDebuggingOff, .notAllowed:
            show(.plain, .globe, "Connecting", source: "Chrome", title: "Connecting to Chrome", bar: .sliding,
                 buttons: Self.stopButtons)
        }
    }

    private mutating func working(title: String, done: Int, wanted: Int?) {
        planTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.wanted = wanted.flatMap { $0 > 0 ? $0 : nil }
        guard let wanted = self.wanted else {
            return show(.plain, .globe, "Working", source: Self.background, title: planTitle,
                        buttons: Self.stopButtons)
        }
        let count = min(max(done, 0), wanted)
        titleEndsWithCount = !planTitle.isEmpty
        show(.plain, .globe, "Working", source: Self.background,
             title: planTitle.isEmpty ? "" : "\(planTitle) — \(count) of \(wanted)",
             body: "One row per site, into a new Google Sheet.",
             bar: .progress(Double(count) / Double(wanted), muted: false), buttons: Self.stopButtons)
    }

    private mutating func asking(_ request: ConfirmationRequest) {
        if let form = request.form { return asking(request, form: form) }
        let host = URL(string: request.pageURL)?.host ?? ""
        let (title, word) = Self.question(request, host: host)
        show(.yourMove, .send, "Needs your Yes", source: Self.chrome(host), title: title,
             body: "No answer in \(Self.clock(ConfirmationRequest.answerWindow)) counts as No.", bar: .countdown,
             buttons: [Button(label: word, action: .yes, primary: true), Button(label: "No", action: .no, primary: false)])
        question = request
    }

    /// A form's question (ITER-076 stage 7, item 17, approved 2026-10-06):
    /// board 2's preview — every field with its value and where it came
    /// from, [Fill] [No], no timer (decision 7.4) — or its Send, naming the
    /// fields it sends and showing their values (decision 7.3), with two
    /// minutes to answer. A form set to send to another site names it.
    private mutating func asking(_ request: ConfirmationRequest, form: FormQuestion) {
        let elsewhere = form.destination.map { " It is set to send to \($0)." } ?? ""
        let rows = form.rows.map(Self.line)
        switch form.kind {
        case .fill:
            show(.yourMove, .pen, "Preview", source: Self.chrome(form.host), title: "Fill the form on \(form.host)?\(elsewhere)",
                 meta: "Passwords, codes and card numbers are never typed.", rows: rows,
                 buttons: [Button(label: "Fill", action: .yes, primary: true), Button(label: "No", action: .no, primary: false)])
        case .send:
            let labels = Self.listed(form.rows.filter { $0.value != nil }.map(\.label))
            let window = "No answer in \(Self.clock(ConfirmationRequest.answerWindow)) counts as No."
            show(.yourMove, .send, "Needs your Yes", source: Self.chrome(form.host),
                 title: "Send the form on \(form.host): \(labels)?\(elsewhere)",
                 body: form.changed ? "The site changed a value after Fill. " + window : window, bar: .countdown,
                 rows: rows,
                 buttons: [Button(label: "Send", action: .yes, primary: true), Button(label: "No", action: .no, primary: false)])
        }
        question = request
    }

    /// A field's line: "<label> — <value> · <source>", with "· check this"
    /// for a value to check, or left empty and why.
    private static func line(_ row: FormRow) -> String {
        switch row.shown {
        case .value(let value, let source, let unsure):
            let from = switch source {
            case .memories: "from your memories"
            case .request: "written from the request"
            case .proAccount: "from your Pro account"
            }
            return "\(row.label) — \(value) · \(from)" + (unsure ? " · check this" : "")
        case .notKnown: return "\(row.label) — left empty · not known"
        case .neverTyped: return "\(row.label) — left empty · never typed"
        }
    }

    /// Fields named in a sentence, as board 2 names them: "name, email,
    /// company".
    private static func listed(_ labels: [String]) -> String {
        labels.map { $0.lowercased() }.joined(separator: ", ")
    }

    /// The step only the user may do, when it ends the errand — a payment,
    /// or a wall on a page that could not be read: the card offers Stop, and
    /// no Continue or Show tab. An unknown site leaves the label alone.
    private mutating func handedOver(_ handover: ErrandHandover) {
        let (title, body, meta) = Self.lines(of: handover)
        show(.yourMove, Self.glyph(of: handover.kind), Self.label(of: handover.kind), source: Self.chrome(handover.host),
             title: title, body: body, meta: meta, buttons: [Button(label: "Stop", action: .stop, primary: false)])
    }

    /// The step only the user may do, waited for (ITER-076 stage 3): board
    /// 3's own sign-in card — its meta, [Show tab] [Continue] [Stop] — under
    /// the title and body each part has: only a sign-in says "Sign in
    /// yourself"; no other line.
    private mutating func paused(_ pause: ErrandPause) {
        let handover = pause.handover
        let lines = Self.lines(of: handover)
        show(.yourMove, Self.glyph(of: handover.kind), Self.label(of: handover.kind), source: Self.chrome(handover.host),
             title: lines.title, body: Self.pauseBody(of: handover.kind, lines.body),
             meta: "Waits up to 10 min, then the errand stops.",
             buttons: [Button(label: "Show tab", action: .showTab, primary: false),
                       Button(label: "Continue", action: .proceed, primary: true),
                       Button(label: "Stop", action: .stop, primary: false)])
        self.pause = pause
    }

    /// A hand-over's own lines: its title, body and meta.
    private static func lines(of handover: ErrandHandover) -> (title: String, body: String, meta: String) {
        let host = handover.host
        return switch handover.kind {
        case .signIn: (host.isEmpty ? "" : "\(host) asks you to sign in", "", "")
        case .captcha: (host.isEmpty ? "" : "\(host) asks you to solve a CAPTCHA", "That is yours to do.", "")
        case .grant: ("This page asks to give access.", "That is yours to do.",
                      "The agent never clicks it, even after a Yes.")
        case .payment: ("This page asks for a payment.", "That is yours to do.",
                        "The agent never pays, even after a Yes.")
        case .file: ("This form asks for a file from your Mac.", "That is yours to do.", "")
        case .cookies: (host.isEmpty ? "" : "\(host) asks about cookies", "That is yours to do.", "")
        }
    }

    /// A pause's body: the user's part and that the errand goes on after it —
    /// a sign-in's and a CAPTCHA's own (the owner's words of 2026-10-06,
    /// approval page item 6), every other part its hand-over body.
    private static func pauseBody(of kind: ErrandHandover.Kind, _ body: String) -> String {
        switch kind {
        case .signIn: "Sign in yourself, then continue."
        case .captcha: "Do the check yourself, then continue."
        default: body
        }
    }

    /// Every ending's title is MetaChat's approved line for it, without the
    /// answer, the sources and the Sheet's address that MetaChat shows below
    /// it: they are page text.
    @MainActor
    private mutating func ended(_ outcome: ErrandOutcome) {
        if let form = outcome.form { return ended(outcome, form: form) }
        // The Sheet's address comes back from the browser: only a web address
        // is offered to open.
        let sheet = outcome.sheet.flatMap { ["https", "http"].contains($0.scheme?.lowercased()) ? $0 : nil }
        let line = ChatService.errandEndingLine(outcome)
        let answered = !(outcome.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let rows = outcome.rows
        let body = answered ? "The answer is in MetaChat."
            : rows <= 0 ? ""
            : outcome.ending == .done ? "Every row keeps its source."
            : rows == 1 ? "1 row saved." : "\(rows) rows saved."
        let bar: Bar = if outcome.ending == .done {
            .progress(1, muted: false)
        } else if let wanted, rows > 0 {
            .progress(Double(min(rows, wanted)) / Double(wanted), muted: true)
        } else {
            .none
        }
        let source = sheet != nil ? (planTitle.isEmpty ? "Sheet" : "Sheet · \(planTitle)")
            : handover.map { Self.chrome($0.host) } ?? "Chrome"
        let open = Button(label: "Open in MetaChat", action: .openInMetaChat, primary: false)
        let buttons = sheet == nil ? [open] : [Button(label: "Open sheet", action: .openSheet, primary: true), open]
        switch outcome.ending {
        case .done:
            show(.done, .check, "Done", source: source, title: line, body: body, bar: bar, buttons: buttons)
        case .needsUser:
            show(.yourMove, handover.map { Self.glyph(of: $0.kind) } ?? .key,
                 handover.map { Self.label(of: $0.kind) } ?? "Yours to do", source: source, title: line, body: body,
                 bar: bar, buttons: buttons)
        case .failed, .unavailable, .noPro:
            show(.plain, .stop, "Failed", source: source, title: line, body: body, bar: bar, buttons: buttons)
        // Not finished: the errand stopped with what it found (ITER-076
        // stage 1); its title is MetaChat's line, as every ending's.
        case .stopped, .stuck, .ceiling, .dailyLimit, .notFinished:
            show(.plain, .stop, "Stopped", source: source, title: line, body: body, bar: bar, buttons: buttons)
        }
        self.sheet = sheet
        hasEnded = true
    }

    /// A form's ending (ITER-076 stage 7, item 17): board 2's sent card —
    /// the fields sent by the page's own labels — or MetaChat's line for it,
    /// as every ending's title is. The user's No stopped it; the rest is
    /// theirs to do, and the details missing name the fields (decision 7.1).
    @MainActor
    private mutating func ended(_ outcome: ErrandOutcome, form: FormEnding) {
        let open = [Button(label: "Open in MetaChat", action: .openInMetaChat, primary: false)]
        let labels = Self.listed(form.labels)
        let named = labels.isEmpty ? "" : labels.prefix(1).uppercased() + labels.dropFirst() + "."
        let source = Self.chrome(form.host)
        let line = ChatService.errandEndingLine(outcome)
        switch form.kind {
        case .sent:
            show(.done, .check, "Sent", source: source, title: "Sent after your Yes.", body: named,
                 bar: .progress(1, muted: false), buttons: open)
        case .notFilled, .notSent:
            show(.plain, .stop, "Stopped", source: source, title: line, buttons: open)
        case .notConfirmed, .keptChanging:
            show(.yourMove, .key, "Yours to do", source: source, title: line, buttons: open)
        case .detailsMissing:
            show(.yourMove, .key, "Yours to do", source: source, title: line, body: named, buttons: open)
        }
        hasEnded = true
    }

    // MARK: - The question

    /// What the question's action will do and on which site, and the word
    /// its Yes button says: the action's own. A form send is the board's
    /// "Send the form"; any other action names its control by its accessible
    /// name — what the request itself names — never a value, an option or
    /// text typed. Its Yes is the control's own English action word when its
    /// name has one ("Delete"), else what the action does.
    private static func question(_ request: ConfirmationRequest, host: String) -> (title: String, word: String) {
        let action = request.action
        let target = action.target
        let on = host.isEmpty ? "" : " on \(host)"
        let name = quoted(target?.name)
        let ownWord = SafetyGuard.lexiconHit(in: [target?.name]).map(\.capitalized)
        let sendsForm = target?.submits == true
            || SafetyGuard.structuralReason(of: action, pageURL: request.pageURL) != nil
        if sendsForm, action.operation == .click || action.operation == .select {
            return ("Send the form\(on)?", ownWord ?? "Send")
        }
        switch action.operation {
        case .open:
            let opened = (action.destination ?? target?.href).flatMap { URL(string: $0)?.host } ?? host
            return (opened.isEmpty ? "Open a page?" : "Open a page on \(opened)?", ownWord ?? "Open")
        case .type:
            return ("Type into\(name)\(on)?", "Type")
        case .select:
            return ("Choose an option in\(name)\(on)?", "Choose")
        case .click, .scroll, .wait, .back, .done, .stuck, .more:
            return ("Click\(name)\(on)?", ownWord ?? "Click")
        }
    }

    /// A control's name in quotes, after a space — at most 60 characters of
    /// it, on one line — or nothing for a control without one.
    private static func quoted(_ name: String?) -> String {
        let words = (name ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return "" }
        let limit = 60
        return " “" + (words.count > limit ? String(words.prefix(limit - 1)) + "…" : words) + "”"
    }

    // MARK: - Words

    private static func chrome(_ host: String) -> String {
        host.isEmpty ? "Chrome" : "Chrome · \(host)"
    }

    private static func label(of kind: ErrandHandover.Kind) -> String {
        kind == .signIn ? "Sign-in needed" : "Yours to do"
    }

    private static func glyph(of kind: ErrandHandover.Kind) -> Glyph {
        kind == .signIn || kind == .captcha ? .lock : .key
    }

    /// 1 is next; then 2nd, 3rd, 4th…
    private static func placeInLine(_ position: Int) -> String {
        guard position > 1 else { return "Next in line" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .ordinal
        return "\(formatter.string(from: NSNumber(value: position)) ?? "\(position)") in line"
    }

    /// Whole seconds as "m:ss".
    private static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
