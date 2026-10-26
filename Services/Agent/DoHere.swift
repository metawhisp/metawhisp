import AppKit

/// What `doHere` did (ITER-076 stage 11), as MetaChat's model reads it: the fields filled, the ones whose value the
/// user's details did not hold, the lists the user picks from, and the ones that failed — their call failed or was
/// not asked, or their text did not go in — each by the words that name it, in the page's order.
struct HereResult: Equatable, Sendable {
    var filled: [String] = []
    var unknown: [String] = []
    var pick: [String] = []
    var failed: [String] = []

    /// `{"filled": [...], "unknown": [...], "pick": [...], "failed": [...]}` — the brief's shape with the fields
    /// that failed, laid out as the agent's other texts for a model are (`LayoutJSON`).
    var json: String {
        LayoutJSON.object([("filled", .array(filled.map(LayoutJSON.string))),
                           ("unknown", .array(unknown.map(LayoutJSON.string))),
                           ("pick", .array(pick.map(LayoutJSON.string))),
                           ("failed", .array(failed.map(LayoutJSON.string)))]).text
    }
}

/// The window the user looks at (ITER-076 stage 11, design 1): the last app they activated that is not MetaWhisp —
/// the browser in front when they speak, the app they came from to type in MetaChat.
@MainActor
final class UserWindow {
    static let shared = UserWindow()

    /// The apps activated, by process: the last one that is not this one.
    struct Trail: Equatable {
        let own: pid_t
        private(set) var last: pid_t?

        init(own: pid_t) { self.own = own }

        mutating func activated(_ pid: pid_t) {
            if pid != own { last = pid }
        }
    }

    private var trail = Trail(own: ProcessInfo.processInfo.processIdentifier)
    private var observer: NSObjectProtocol?

    /// Follows the user's apps from now on, starting with the one in front.
    func start(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication { trail.activated(front.processIdentifier) }
        observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                      queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.trail.activated(pid) }
        }
    }

    /// That app's process, while it runs.
    var pid: pid_t? {
        guard let last = trail.last, let app = NSRunningApplication(processIdentifier: last), !app.isTerminated else {
            return nil
        }
        return last
    }
}

/// "Fill this page" in the window the user looks at (ITER-076 stage 11): the eyes read that window's empty fields;
/// the user's details are found for their names; each field's text is asked of text 16 — approved, strict JSON —
/// with the user's words of the send as the goal, all fields together, each call's worst case reserved first as
/// every agent call's is (§8), so none crosses the spend ceiling; then the hands put each text in. A pop-up
/// button is never asked about nor pressed: it is a list the user picks from. What came of it is the result: a
/// field whose call failed, was not asked or whose text did not go in is named as failed. Its log holds numbers
/// only.
@MainActor
struct DoHere {
    /// The process whose window the user looks at; nil: none.
    var app: () -> pid_t?
    /// The eyes on that process's window.
    var look: (pid_t) async -> HereLook?
    /// The user's details for the fields' names.
    var facts: ([String]) async -> FormFacts
    var model: ErrandModel
    var hands: HereWorld
    var limits: AgentBudget.Limits = .standard
    var optionWait: Duration = HereHands.optionWait
    var log: (String) -> Void = { NSLog("%@", $0) }

    /// The app's: the window of `pid`, read by `read`, the hands `AXHands`, text 16 through the Pro
    /// server, with the details `facts` gives.
    static func app(pid: pid_t?, facts: @escaping ([String]) async -> FormFacts) -> DoHere {
        DoHere(app: { pid }, look: read, facts: facts, model: ErrandModel(client: ProLLMClient()),
               hands: AXHands())
    }

    func run(goal: String) async -> HereResult {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, let pid = app() else {
            log("[DoHere] nothing to fill")
            return HereResult()
        }
        let result = await fill(pid, goal: goal)
        // What the eyes turned on to see the page goes back off once the hands are done.
        await Task.detached(priority: .userInitiated) { HerePages.shared.restore(pid) }.value
        return result
    }

    private func fill(_ pid: pid_t, goal: String) async -> HereResult {
        guard let look = await look(pid), !look.fields.isEmpty else {
            log("[DoHere] nothing to fill")
            return HereResult()
        }
        let page = ObservedPage(url: "", title: look.title, truncated: false, flags: .none, elements: [],
                                text: look.text)
        let typed = look.fields.indices.filter { look.fields[$0].role != "AXPopUpButton" }
        let details = typed.isEmpty ? [] : await facts(typed.map { look.fields[$0].label }).details.map(\.text)
        let texts = await write(typed, of: look.fields, goal: goal, details: details, page: page)
        let work = typed.compactMap { at in texts[at].flatMap { $0 }.map { (at: at, text: $0) } }
        let outcomes = await HereHands.fill(work.map { (field: look.fields[$0.at], text: $0.text) }, of: pid, in: hands,
                                            optionWait: optionWait)
        let done = Dictionary(uniqueKeysWithValues: zip(work.map(\.at), outcomes))
        var result = HereResult()
        for (at, field) in look.fields.enumerated() {
            if field.role == "AXPopUpButton" {
                result.pick.append(field.label)
            } else if case .some(.none) = texts[at] {
                result.unknown.append(field.label)
            } else if done[at] == .filled {
                result.filled.append(field.label)
            } else if done[at] == .pick {
                result.pick.append(field.label)
            } else {
                result.failed.append(field.label)
            }
        }
        log("[DoHere] fields=\(look.fields.count) typed=\(typed.count) answered=\(texts.count) "
            + "filled=\(result.filled.count) unknown=\(result.unknown.count) pick=\(result.pick.count) "
            + "failed=\(result.failed.count)")
        return result
    }

    /// Each field's text, asked together, by its place among `fields`: a text, or none — null, its details do not
    /// hold it; a field whose call failed, or was not asked, has no entry. A call that would cross the spend
    /// ceiling with its worst case is not asked, nor any after it.
    private func write(_ typed: [Int], of fields: [HereField], goal: String, details: [String],
                       page: ObservedPage) async -> [Int: String?] {
        var budget = AgentBudget(startedAt: .now, limits: limits)
        var asks: [(at: Int, field: ObservedElement, reservation: AgentBudget.Reservation)] = []
        for (order, at) in typed.enumerated() {
            let field = Self.element(fields[at], index: order)
            let request = Self.request(goal: goal, details: details, field: field, page: page)
            guard let reservation = budget.reserve(worstCaseUSD: ErrandModel.worstCaseUSD(of: request)) else { break }
            asks.append((at, field, reservation))
        }
        let model = self.model
        let answers = await withTaskGroup(of: (Int, ErrandModel.Written?).self) { group in
            for ask in asks {
                let field = ask.field
                group.addTask {
                    (ask.at, try? await model.formFieldText(goal: goal, details: details, field: field, page: page,
                                                            recent: []))
                }
            }
            var all: [Int: ErrandModel.Written] = [:]
            for await (at, written) in group { all[at] = written }
            return all
        }
        var texts: [Int: String?] = [:]
        for ask in asks {
            // What it cost, as the server says; with no answer, its whole worst case (§8).
            budget.settle(ask.reservation, actualUSD: answers[ask.at]?.usage?.costUSD)
            if let written = answers[ask.at] { texts[ask.at] = .some(written.text) }
        }
        log("[DoHere] asked=\(asks.count) of \(typed.count) spentUSD=\(budget.spentUSD)")
        return texts
    }

    /// A field's call: text 16 (`ErrandModel.formFieldTextRequest`) with no recent action.
    static func request(goal: String, details: [String], field: ObservedElement, page: ObservedPage)
        -> ProLLMClient.Request {
        ErrandModel.formFieldTextRequest(goal: goal, details: details, field: field, page: page, recent: [])
    }

    /// A field as text 16 reads it: its name, and its role as the page's observer names it — a combobox, else a
    /// text box — holding nothing.
    static func element(_ field: HereField, index: Int) -> ObservedElement {
        ObservedElement(index: index, role: field.role == "AXComboBox" ? "combobox" : "textbox", name: field.label,
                        text: field.label, href: nil, inputType: nil, heading: nil, region: .main, inViewport: true,
                        context: nil, formAction: nil, formMethod: nil, formSubmitLabel: nil, options: nil,
                        checked: nil, value: "")
    }

    /// How often, and for how long, a window that shows no field is read again: Chrome showed a page's fields to
    /// the Accessibility API only a while after it was first asked (measured 2026-10-07: 0.25 to 2 s; 2026-10-13,
    /// asked as `HerePages` asks: 2.2 to 2.8 s), and WebKit at the second read in the test's own window.
    static let readEvery: Duration = .milliseconds(300)
    static let readWait: Duration = .seconds(5)

    /// The app's eyes: the window of `pid` read off the main thread, its pages shown first (`HerePages`).
    static func read(_ pid: pid_t) async -> HereLook? {
        await read(pid, every: readEvery, within: readWait) { pid in
            HerePages.shared.show(pid)
            return HereEyes.read(pid: pid)
        }
    }

    /// The window `reading` gives, read again every `every` while it shows no field, until `within` has passed;
    /// once when there is none.
    static func read(_ pid: pid_t, every: Duration, within: Duration,
                     reading: @escaping @Sendable (pid_t) -> HereNode?) async -> HereLook? {
        let clock = ContinuousClock()
        let end = clock.now + within
        while true {
            let look = await Task.detached(priority: .userInitiated) { reading(pid).map(HereEyes.look(at:)) }.value
            guard let seen = look, seen.fields.isEmpty, clock.now < end else { return look }
            await HereHands.rest(every)
        }
    }
}
