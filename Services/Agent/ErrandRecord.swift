import Foundation

/// What an errand leaves behind (ITER-074 §6.5, §8, §11): the rows it
/// collected, how it ended, and one entry per step — the operation, the
/// target's role and fingerprint, the confidence, the engine, the time and
/// the cost. A step has no field for the page's text or for what was typed,
/// so the record cannot carry them. Beside the steps, every event of the
/// errand in order (ITER-076 I-06a), each said in the app's log as it is
/// kept.
struct ErrandRecord: Codable, Equatable {
    enum Outcome: String, Codable, CaseIterable {
        /// Sent to the page, or done by the loop itself.
        case acted
        /// The element was gone or changed; decided again.
        case gone
        /// Twins that are not one destination; decided again.
        case ambiguous
        case unsupported
        /// The engine was unsure or its answer was malformed; asked again.
        case reconsidered
        /// The user said yes to this exact action.
        case confirmed
        /// The user said no, or did not answer in time.
        case refused
        case failed
        /// A grant or a wall — the user's part (§7.2); nothing was done.
        case handedOver
    }

    enum Ending: String, Codable, CaseIterable {
        case done, stopped, stuck, ceiling, failed
        /// A login or payment form: the user does that part (§7.2, §11).
        case needsUser
        /// The Pro server did not accept the user's license (ITER-076 I-05).
        case noPro
        /// Today's allowance of the agent's service is used up; it renews at
        /// the next UTC day.
        case dailyLimit
        /// The agent's service did not answer — down or too slow — and did
        /// not once it was waited for and asked again.
        case unavailable
        /// The text model stopped, and the verifier never said that
        /// everything asked was done (ITER-076 stage 1): what the errand found
        /// is its answer.
        case notFinished
    }

    /// Why an errand failed, when a failure ended it (ITER-076 I-05): one of
    /// a closed set, kept and logged by its name alone — never a page's text.
    /// How far the rows got into the Sheet.
    enum SheetWrite: String, Codable {
        /// Made; the rows are not known to be in it.
        case created
        /// The paste returned; not read back yet, or read back not as pasted.
        case pasted
        /// Read back as pasted.
        case verified
    }

    enum Failure: String, Codable, CaseIterable {
        /// The browser would not open the errand's tab.
        case openFailed
        /// The start page never finished loading onto a web page.
        case neverSettled
        /// The connection to the browser is gone. The errand's tab closed is
        /// the user's stop, no failure (ITER-076 stage 8a, № 117).
        case bridgeLost
        /// The decision engine's service did not answer.
        case engineUnavailable
        /// The Sheet could not be made, or does not show what was pasted — in
        /// records made before ITER-076 stage 6, when that ended an errand: a
        /// Sheet's failure now ends nothing (`ErrandOutcome.sheetFailure`).
        case sheetFailed
        /// No plan could be written for the goal.
        case planFailed
        /// The text model gave no sub-goal the errand could use, or there is
        /// none to ask (ITER-076 brain).
        case subgoalFailed
        /// MetaWhisp's own Chrome did not open its port in time, did not
        /// answer, or refused the connection (ITER-076 stage 8b, № 15): the
        /// app's own failure — no one was asked to set anything up.
        case browserDidNotStart
    }

    /// One thing an errand did or met, in the order it came (ITER-076
    /// I-06a): by numbers, kinds, ids, roles and a host alone — never a
    /// page's words, a label, a typed value, an address beyond its host, the
    /// goal, a prompt or an answer.
    enum Event: Codable, Equatable {
        /// How asking for the plan went.
        enum Plan: String, Codable, CaseIterable {
            case ok, failed
            /// Its time ran out before any answer.
            case timedOut
            /// Its worst case would cross the spend ceiling, or the errand's
            /// own time cut it.
            case ceiling
            case stopped
        }

        enum PageMiss: String, Codable, CaseIterable {
            /// The page's script failed, or gave no answer.
            case read
            /// What it answered is not a report.
            case report
            /// The page did not finish loading, in time, where it must.
            case settle
        }

        enum Answer: String, Codable, CaseIterable {
            case yes, no
            /// No answer in time.
            case expired
            /// Stop, the Mac's sleep or the app's quit closed the question
            /// first (I-06a review, P2-4).
            case stopped
        }

        /// The plan: written, or how not; its time and its cost.
        case plan(Plan, milliseconds: Int, costUSD: Double)
        /// Another call of the text model (ITER-076 brain): its purpose, how
        /// it went — as a plan's call goes — its time and its cost.
        case model(ProLLMClient.Request.Purpose, Plan, milliseconds: Int, costUSD: Double)
        /// A browser step, as `steps` keeps it.
        case step(Step)
        case pageMiss(PageMiss)
        /// A wait for the agent's service, and whether it answered the call
        /// after; nil when the errand ended first.
        case serviceWait(seconds: Double, answered: Bool?)
        /// A question to the user about one action: its operation, and its
        /// target's role as a step keeps it.
        case question(operation: String, targetRole: String?)
        case answer(Answer)
        /// The user's part: its kind, on the page's host.
        case handover(ErrandHandover.Kind, host: String)
        /// The user said Continue after doing their part: the errand went on
        /// (ITER-076 stage 3).
        case continued
        /// How the errand ended: why it failed, or why it never ran, and the
        /// rows it kept.
        case ending(Ending, failure: Failure?, notRun: ErrandOutcome.NotRun?, rows: Int)
        /// A step recorded as it went out that never did: the bridge said
        /// nothing was sent. It takes the step's place, under its number.
        case takenBack
        /// A page's own dialog, by its kind, and whether it was answered OK —
        /// or Leave (ITER-076 I-09); never its words.
        case dialog(PageDialog, accepted: Bool)
        /// A download the tab began, refused before anything was saved.
        case downloadRefused
        /// A document the tab asked for at an address the agent never opens,
        /// refused before the request went out.
        case addressRefused
        /// A read of the page a sub-goal left (ITER-076 stage 4a).
        case read(Read)

        /// A read of the page a sub-goal left (ITER-076 stage 4a): the guard
        /// that ended it — or that the reader was asked — how many lines the
        /// page gave, and what the read met, when the page said; kinds and
        /// numbers alone.
        struct Read: Codable, Equatable {
            enum End: String, Codable, CaseIterable {
                /// Every fact asked for has its claim: nothing to read for.
                case nothingToFind
                /// The errand's reads are spent.
                case readsSpent
                /// The page's script gave no answer: a page miss says how.
                case failed
                /// What the page answered is not its lines: a page miss says so.
                case notLines
                /// The page gave no line.
                case noLines
                /// The page's text was read before in this errand.
                case readBefore
                /// The reader was asked.
                case read
            }

            let end: End
            var blocks: Int? = nil
            var walk: ErrandModel.Capture.Walk? = nil
        }

        /// A question about `action`: of it, only what a step keeps.
        static func question(about action: AgentAction) -> Event {
            .question(operation: action.operation.rawValue, targetRole: ErrandRecord.role(of: action))
        }

        /// The event as the log says it: its kind and its fields, nothing else.
        var line: String {
            switch self {
            case .plan(let result, let milliseconds, let cost):
                Self.said("plan", ["result": result.rawValue, "ms": "\(milliseconds)", "usd": Self.usd(cost)])
            case .model(let purpose, let result, let milliseconds, let cost):
                Self.said("model", ["purpose": purpose.rawValue, "result": result.rawValue, "ms": "\(milliseconds)",
                                    "usd": Self.usd(cost)])
            case .step(let step):
                Self.said("step", ["op": step.operation, "role": step.targetRole, "fp": step.fingerprint,
                                   "outcome": step.outcome.rawValue, "confidence": step.confidence.map { "\($0)" },
                                   "opConfidence": step.operationConfidence.map { "\($0)" },
                                   "targetConfidence": step.targetConfidence.map { "\($0)" },
                                   "targets": step.targets.map { "\($0)" },
                                   "engine": step.engine, "ms": "\(step.milliseconds)",
                                   "usd": step.costUSD.map(Self.usd)])
            case .pageMiss(let miss):
                Self.said("page", ["miss": miss.rawValue])
            case .serviceWait(let seconds, let answered):
                Self.said("wait", ["s": "\(seconds)", "answered": answered.map { "\($0)" }])
            case .question(let operation, let role):
                Self.said("question", ["op": operation, "role": role])
            case .answer(let reply):
                Self.said("answer", ["reply": reply.rawValue])
            case .handover(let kind, let host):
                Self.said("handover", ["kind": kind.rawValue, "host": host])
            case .continued:
                "continued"
            case .takenBack:
                "taken back"
            case .dialog(let kind, let accepted):
                Self.said("dialog", ["kind": kind.rawValue, "accepted": "\(accepted)"])
            case .downloadRefused:
                "download refused"
            case .addressRefused:
                "address refused"
            case .read(let read):
                Self.said("read", Self.fields(of: read))
            case .ending(let ending, let failure, let notRun, let rows):
                Self.said("ending", ["kind": ending.rawValue, "failure": failure?.rawValue, "notRun": notRun?.rawValue,
                                     "rows": "\(rows)"])
            }
        }

        /// `kind` and each field that has a value, as `name=value`, in order.
        private static func said(_ kind: String, _ fields: KeyValuePairs<String, String?>) -> String {
            said(kind, fields.map { (name: $0.key, value: $0.value) })
        }

        private static func said(_ kind: String, _ fields: [(name: String, value: String?)]) -> String {
            ([kind] + fields.compactMap { name, value in value.map { "\(name)=\($0)" } }).joined(separator: " ")
        }

        /// A read as its line says it: how it ended, the lines the page gave,
        /// and what the read met — each rule that left words out with how
        /// many, by the rule's name.
        private static func fields(of read: Read) -> [(name: String, value: String?)] {
            var fields: [(name: String, value: String?)] = [("end", read.end.rawValue),
                                                             ("blocks", read.blocks.map { "\($0)" })]
            guard let walk = read.walk else { return fields }
            let dropped = walk.dropped.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue):\($0.value)" }.joined(separator: ",")
            fields += [("root", walk.root.rawValue), ("roots", "\(walk.roots)"), ("hidden", "\(walk.pageHidden)"),
                       ("met", "\(walk.met)"), ("kept", "\(walk.kept)"), ("dropped", dropped.isEmpty ? nil : dropped),
                       ("cut", walk.cut?.rawValue)]
            return fields
        }

        private static func usd(_ amount: Double) -> String { String(format: "%.6f", amount) }
    }

    struct Step: Codable, Equatable {
        let operation: String
        let targetRole: String?
        let fingerprint: String?
        let outcome: Outcome
        let confidence: Double?
        let engine: String
        let milliseconds: Int
        let costUSD: Double?
        /// Jev's own confidences — the operation's, and its target's when it
        /// has one — and how many targets its operation was offered, when Jev
        /// chose the step (ITER-076 stage 4a); nil in a record made before.
        var operationConfidence: Double? = nil
        var targetConfidence: Double? = nil
        var targets: Int? = nil
    }

    /// A fact the reader found (ITER-076 brain, step 2): the requirements it
    /// answers — none for one the reader kept as context (stage 1) — a quote
    /// of the page — its own words, copied by code from the blocks the reader
    /// cited — the label of the block it begins at, and the page's shown
    /// address.
    struct Fact: Codable, Equatable {
        var requirements: [String]
        let quote: String
        let source: String
        let url: String
    }

    /// One of the reader's claims (2026-10-15): its words, the requirement it answers whole when it named one asked,
    /// and the facts it rests on, by their place in `facts`. The words are the reader's, the facts beneath them the
    /// page's own; a claim that rests on no fact is never kept — as a reference browser agent keeps each claim as a
    /// fact with its text and basis (`memory.py` 27-42, MIT).
    struct Statement: Codable, Equatable {
        var requirement: String?
        let text: String
        let basis: [Int]
        /// The read that made it, counted from 1 an errand (2026-10-18): a requirement is answered by every claim
        /// of the last read that answered it. Nil in a record made before reads were counted.
        var read: Int? = nil
    }

    /// The most events a record keeps: past it, the newest — an errand's end
    /// and what led to it — and a count of the rest.
    static let maxEvents = 200

    let errandID: UUID
    /// The user's own words.
    let goal: String
    private(set) var steps: [Step] = []
    var rows: [Scratchpad.Row] = []
    /// The facts the reader found, each kept the moment it came, as a row is
    /// (ITER-076 brain, step 2): none in a record made before they were kept.
    /// The reader's evidence, numbered by place (stage 1).
    var facts: [Fact] {
        get { found ?? [] }
        set { found = newValue }
    }
    private var found: [Fact]?
    /// The reader's claims, each kept the moment it came, beside the facts they rest on (2026-10-15): none in a
    /// record made before they were kept.
    var statements: [Statement] {
        get { said ?? [] }
        set { said = newValue }
    }
    private var said: [Statement]?
    /// The new Sheet the rows go into, from the moment it is made.
    var sheet: URL?
    /// How far the rows got into `sheet` (ITER-076 I-05, review round 1).
    var sheetWrite: SheetWrite?
    /// What the errand's paid calls cost so far — the plan's and every
    /// step's, each call's whole worst case when it reported no usage (none
    /// for a call that reached no model, ITER-076 stage 8a), and a call still
    /// out at its worst case until it settles, so a record saved meanwhile (a
    /// quit) leaves nothing out; nil in a record made before this was kept.
    var spentUSD: Double?
    var ending: Ending?
    /// The brain's own answer (owner decision of 2026-10-19: one model decides every step): what it said when it
    /// called done, or, until then, what it kept so far. When set, it is the errand's answer; nil in any other
    /// errand, and in a record made before.
    var told: String?
    /// The pages that answer names, of those the errand saw: its sources.
    var toldSources: [String]?
    /// The pages the brain's errand looked at, in order; nil in any other errand.
    var seen: [String]?
    /// Why it failed, when a failure ended it.
    var failure: Failure?
    /// How its form ended (ITER-076 stage 7, № 183), once it did: kept here,
    /// not as an event — a report never carries it — so the ending the
    /// service saves at a Stop says it too: once Send was pressed, the errand
    /// never says only "Stopped.". Nil for any other errand, and in a record
    /// made before.
    var form: FormEnding?
    /// The events kept, and how many older ones were dropped; nil in a
    /// record made before events were kept.
    private var timeline: Timeline?

    private struct Timeline: Codable, Equatable {
        var events: [Event] = []
        var dropped = 0
    }

    init(errandID: UUID, goal: String) {
        self.errandID = errandID
        self.goal = goal
    }

    /// The answer the facts make (ITER-076 brain, step 2): each fact's quote,
    /// then its page's address, grouped by requirement — in the order each was
    /// first answered — each quote of a page once; nil with no fact. The
    /// page's own words and addresses: no word of the app's. An errand that
    /// did not end done ends with everything it read: then the context the
    /// reader kept follows, as a reference browser agent's partial answer
    /// gives every quote it holds (`retrieval.py` 1784-1807, MIT; stage 1).
    ///
    /// A done errand answers in the reader's words (2026-10-15; the owner: the result counts): each requirement, in
    /// the order it was first answered, by every claim the last read that answered it made, each with the pages of
    /// the facts it rests on — as a reference browser agent drafts its answer from every claim its reader wrote for
    /// a requirement, each linked to what it rests on (`draft_answer`, `assemble_answer`, `retrieval.py` 1665-1697,
    /// 1820-1836, MIT) — then each of those facts its words do not already hold, the page's own words with their
    /// page: a list's records under "ten jokes", a total's rows under the total. An earlier read's claims are a
    /// former answer the last read superseded. A requirement no claim answered gives its quotes.
    var answer: String? {
        if let told, !told.isEmpty { return told }
        let parts = ending == .done ? statedParts() : answerItems(endingAs: ending).map { $0.quote + "\n" + $0.url }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// A done errand's answer, part by part: each requirement's claims of its last read and the facts beneath
    /// them, or its quotes.
    private func statedParts() -> [String] {
        var quoted: Set<[String]> = []
        var shown: Set<Int> = []
        return requirementOrder.flatMap { id -> [String] in
            guard let last = statements.last(where: { $0.requirement == id }) else {
                return facts.filter { $0.requirements.contains(id) && quoted.insert([$0.quote, $0.url]).inserted }
                    .map { $0.quote + "\n" + $0.url }
            }
            // A version and its release date are one answer in two claims of one read (2026-10-18: kept by the last
            // claim alone, the answer gave the date and no version). A record made before reads were counted gives
            // its last claim.
            let said = last.read.map { read in statements.filter { $0.requirement == id && $0.read == read } } ?? [last]
            return said.flatMap { claim -> [String] in
                let beneath = claim.basis.filter { facts.indices.contains($0) }
                let pages = beneath.map { facts[$0].url }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                let records = beneath.filter { !claim.text.contains(facts[$0].quote) && shown.insert($0).inserted }
                    .map { facts[$0].quote + "\n" + facts[$0].url }
                return [([claim.text] + pages).joined(separator: "\n")] + records
            }
        }
    }

    /// The requirements the facts answer, in the order each was first answered.
    private var requirementOrder: [String] {
        var order: [String] = []
        for fact in facts { for id in fact.requirements where !order.contains(id) { order.append(id) } }
        return order
    }

    /// The answer's items, in its order, each once: a fact's quote and its
    /// page's shown address — for an errand that ended `ending`. What a Sheet
    /// holds, one row each (ITER-076 stage 6).
    func answerItems(endingAs ending: Ending?) -> [(quote: String, url: String)] {
        var shown: Set<[String]> = []
        return answering(endingAs: ending).compactMap { fact in
            shown.insert([fact.quote, fact.url]).inserted ? (fact.quote, fact.url) : nil
        }
    }

    /// The facts the answer gives, in its order.
    private func answering(endingAs ending: Ending?) -> [Fact] {
        let answered = requirementOrder.flatMap { id in facts.filter { $0.requirements.contains(id) } }
        return ending == .done ? answered : answered + facts.filter(\.requirements.isEmpty)
    }

    /// Where the errand's result came from: each row's page, then each page a
    /// fact of the answer was read on, once each, in the order read — then
    /// the page a form's site showed once it was sent (ITER-076 stage 7).
    var sources: [URL] {
        if let toldSources { return toldSources.compactMap(URL.init(string:)) }
        var pages: [URL] = []
        for fact in facts where ending != .done || !fact.requirements.isEmpty {
            if let page = URL(string: fact.url), !pages.contains(page) { pages.append(page) }
        }
        let sent = form.flatMap { $0.kind == .sent ? $0.url.flatMap(URL.init(string:)) : nil }
        return rows.map(\.source) + pages + (sent.map { pages.contains($0) ? [] : [$0] } ?? [])
    }

    /// Every event of the errand in order, the newest `maxEvents`.
    var events: [Event] { timeline?.events ?? [] }
    /// How many events came before the ones kept.
    var droppedEvents: Int { timeline?.dropped ?? 0 }

    /// How the log names errand `id`'s lines.
    static func logPrefix(_ id: UUID) -> String { "[Errand \(id.uuidString.prefix(8))]" }

    /// The log's line for the event at `index`: the errand, the event's
    /// number since the errand began, and the event.
    func logLine(at index: Int) -> String {
        "\(Self.logPrefix(errandID)) #\(droppedEvents + index + 1) \(events[index].line)"
    }

    /// Keeps `event` — past `maxEvents`, in place of the oldest, which is
    /// counted — and returns its line for the log.
    @discardableResult
    mutating func note(_ event: Event) -> String {
        var kept = timeline ?? Timeline()
        kept.events.append(event)
        if kept.events.count > Self.maxEvents {
            kept.events.removeFirst()
            kept.dropped += 1
        }
        timeline = kept
        return logLine(at: kept.events.count - 1)
    }

    /// Ends the record: its ending and its failure, and the ending as its
    /// last event — in place of an ending already last, the service's saved
    /// ending over its run's own. The line for the log, or nil when the
    /// record already ends so.
    @discardableResult
    mutating func end(_ ending: Ending, failure: Failure?, notRun: ErrandOutcome.NotRun? = nil) -> String? {
        self.ending = ending
        self.failure = failure
        let event = Event.ending(ending, failure: failure, notRun: notRun, rows: rows.count)
        guard case .ending? = events.last else { return note(event) }
        guard events.last != event else { return nil }
        let last = events.count - 1
        timeline?.events[last] = event
        return logLine(at: last)
    }

    /// A target's role as the record keeps it: the report comes from the
    /// page's world, so a role the agent does not act on is "other".
    private static func role(of action: AgentAction?) -> String? {
        action?.target.map { CandidateBuilder.actionableRoles.contains($0.role) ? $0.role : "other" }
    }

    /// Records a step from the action itself: its operation, and of its
    /// target only the role and the fingerprint — beside the engine's own
    /// numbers when it gave them (ITER-076 stage 4a). A step with no action —
    /// a malformed or missing answer — is recorded as "none". Kept as an
    /// event too; returns its line for the log.
    @discardableResult
    mutating func append(_ action: AgentAction?, outcome: Outcome, confidence: Double?, engine: String,
                         milliseconds: Int, costUSD: Double?, operationConfidence: Double? = nil,
                         targetConfidence: Double? = nil, targets: Int? = nil) -> String {
        let step = Step(operation: action?.operation.rawValue ?? "none", targetRole: Self.role(of: action),
                        fingerprint: action?.target?.fingerprint, outcome: outcome, confidence: confidence,
                        engine: engine, milliseconds: milliseconds, costUSD: costUSD,
                        operationConfidence: operationConfidence, targetConfidence: targetConfidence, targets: targets)
        steps.append(step)
        return note(.step(step))
    }

    /// Takes the last step back: recorded as it went out, it never did — the
    /// bridge said nothing was sent (ITER-076 I-05). `steps` drops it; its
    /// event says so in its place, under its number. Numbers only grow, so
    /// a record saved meanwhile — the service's at Stop — and this one never
    /// give one number to two endings (I-06a review, P2-1).
    @discardableResult
    mutating func removeLastStep() -> String? {
        guard steps.popLast() != nil, let index = lastStepEvent else { return nil }
        timeline?.events[index] = .takenBack
        return logLine(at: index)
    }

    /// Corrects the last step's outcome: an action is recorded the moment it
    /// reaches the page, and its postcondition may turn out not to hold. Its
    /// event is corrected too, and said again under its number.
    @discardableResult
    mutating func markLastStep(_ outcome: Outcome) -> String? {
        guard let last = steps.popLast() else { return nil }
        let step = Step(operation: last.operation, targetRole: last.targetRole, fingerprint: last.fingerprint,
                        outcome: outcome, confidence: last.confidence, engine: last.engine,
                        milliseconds: last.milliseconds, costUSD: last.costUSD,
                        operationConfidence: last.operationConfidence, targetConfidence: last.targetConfidence,
                        targets: last.targets)
        steps.append(step)
        guard let index = lastStepEvent else { return nil }
        timeline?.events[index] = .step(step)
        return logLine(at: index)
    }

    /// Where the last step's event is among the events kept.
    private var lastStepEvent: Int? {
        events.lastIndex { if case .step = $0 { true } else { false } }
    }
}
