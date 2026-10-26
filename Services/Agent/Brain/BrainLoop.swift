import Foundation

/// The model the brain loop asks each step: the step's messages and the AgentOutput tool in, an answer out. The
/// host pays for it and keeps it on record: the errand's run in the app, a bench's endpoint in tests.
@MainActor
protocol Brain: AnyObject, Sendable {
    func think(_ messages: [CDPValue], tools: [CDPValue]) async throws -> ProLLMClient.Outcome
}

/// What one action came to at the hands.
struct BrainActed: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// It reached the page.
        case done
        /// The rails or the page kept it from happening; `note` says why.
        case notDone
        /// The user was asked and said no, or did not answer in time.
        case userSaidNo
        /// The errand ends here: the user's part was left to them.
        case ended
    }

    var kind: Kind
    var note = ""
    /// The question the user was asked about it, when one was.
    var asked: String?
    /// It went out with the user's Yes.
    var sent = false
}

/// The browser as the brain loop drives it: the app's own eyes, hands and rails behind one face. Stop, the
/// errand's ceilings and a browser that is gone come out of these calls as the errors the host ends the errand by.
@MainActor
protocol BrainHands: AnyObject {
    /// Before each step: throws once Stop was pressed or a ceiling is reached.
    func checkpoint() throws
    /// The page in the errand's tab, as the observer reports it, and the tabs shown to the brain.
    func look() async throws -> (page: ObservedPage, tabs: [BrainTab])
    /// The address the tab shows now, without a full look.
    func address() async -> String?
    /// One action through the rails and the hands: the walls, the user's Yes where the rails ask it, the act.
    func act(_ action: AgentAction, on page: ObservedPage) async throws -> BrainActed
    /// Enter in the field last typed into: its search, or its form's own button, through the rails as that act.
    func enter(after field: ObservedElement, typed: String, on page: ObservedPage) async throws -> BrainActed
    func scroll(down: Bool, pages: Double, on page: ObservedPage) async throws
    /// Runs a read-only script in the page and returns its text.
    func evaluate(_ script: String) async throws -> String
    /// The page's whole text as the app's reader reads it: no secret field's words, no text drawn as dots.
    func pageText() async throws -> String
}

/// How an errand the brain ran ended, and what the bench and MetaChat read of it.
struct BrainOutcome: Equatable, Sendable {
    enum Ending: String, Equatable, Sendable {
        /// The brain called done: with success, or saying what is missing.
        case done, notDone = "not_done"
        /// The user's part was left to them, and the errand ended there.
        case handedOver = "handed_over"
        /// The model gave no usable answer, several calls in a row.
        case error
    }

    var ending: Ending
    var answer: String
    var visited: [String] = []
    var asked: [String] = []
    var answersGiven: [Bool] = []
    /// An action the user said Yes to went out: something was sent.
    var sent = false
    var steps = 0
    /// The table the brain's last done gave, in a table errand.
    var table: BrainTable?
}

/// One errand, decided step by step by one model (owner decision of 2026-10-19), as the open-source browser-use
/// agent runs (`browser_use/agent/service.py`, MIT): look, show the model the request, its history, its plan and the
/// page, and run the actions it returns in order — the rest of the list skipped once the page changes — until it
/// calls done. Every action goes through the host's rails; Stop and the ceilings are the host's.
@MainActor
final class BrainLoop {
    struct Settings: Equatable {
        var maxActionsPerStep = 5
        /// The step ceiling as the brain is told it; the host enforces it.
        var maxSteps = AgentBudget.Limits.standard.steps
        /// Model calls that may fail in a row before the errand ends.
        var failuresAllowed = 3
        /// The longest `wait` the brain may ask for.
        var longestWait = 10.0
        /// How much of the whole page's text one extract reads.
        var extractChars = 30_000
        /// An extract's answer shorter than this stays in the history for every later step; a longer one is shown
        /// once (the reference's `MAX_MEMORY_LENGTH`).
        var keptExtractChars = 10_000
        /// How many times the same action may fail on the same page.
        var repeatsAllowed = 3
        /// How many times the check may reject the brain's done before the errand ends not finished.
        var judgeRejections = 2
        /// The user asked for a table: the brain's done also gives its columns and rows (`BrainPrompt.tableTool`).
        var table = false
    }

    private let goal: String
    private let brain: any Brain
    private let hands: any BrainHands
    private let recall: @MainActor (String) async -> [String]
    private let settings: Settings
    private let today: String
    private let log: @MainActor (String) -> Void
    /// Hears what the brain keeps after each step: the answer so far, should the errand be stopped.
    private let kept: @MainActor (String) -> Void

    private var history = BrainHistory()
    private var plan = BrainPlan()
    private var outcome = BrainOutcome(ending: .error, answer: "")
    /// The last field typed into, and its text: what Enter sends.
    private var lastTyped: (field: ObservedElement, text: String)?
    /// How many times each action failed on each page.
    private var failed: [String: Int] = [:]
    /// How many times the check rejected the brain's done.
    private var rejected = 0

    init(goal: String, brain: any Brain, hands: any BrainHands, recall: @escaping @MainActor (String) async -> [String],
         settings: Settings = Settings(), today: String = BrainLoop.todayString(),
         log: @escaping @MainActor (String) -> Void = { NSLog("%@", $0) },
         kept: @escaping @MainActor (String) -> Void = { _ in }) {
        self.goal = goal
        self.brain = brain
        self.hands = hands
        self.recall = recall
        self.settings = settings
        self.today = today
        self.log = log
        self.kept = kept
    }

    nonisolated static func todayString() -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: Date())
    }

    func run() async throws -> BrainOutcome {
        var previous: ObservedPage?
        var readState: [String] = []
        var failures = 0
        while true {
            try hands.checkpoint()
            outcome.steps += 1
            let look = try await hands.look()
            history.notePage(url: look.page.url, title: look.page.title, text: look.page.text)
            if !outcome.visited.contains(look.page.url) { outcome.visited.append(look.page.url) }
            let state = BrainPrompt.state(goal: goal, history: history, plan: plan, tabs: look.tabs, page: look.page,
                                          previous: previous, readState: readState, step: outcome.steps,
                                          maxSteps: settings.maxSteps, today: today)
            let messages: [CDPValue] = [
                ["role": "system", "content": .string(BrainPrompt.system(maxActions: settings.maxActionsPerStep))],
                ["role": "user", "content": .string(state)],
            ]
            readState = []
            previous = look.page
            guard let turn = try await think(messages) else {
                failures += 1
                if failures >= settings.failuresAllowed { return finish(.error, answer: outcome.answer) }
                history.add(.init(evaluation: "", memory: "", nextGoal: "",
                                  results: ["Error: no valid AgentOutput call came back. Call the AgentOutput tool."]))
                continue
            }
            failures = 0
            if let items = turn.planUpdate, !items.isEmpty {
                plan.update(items: items, current: turn.currentPlanItem)
            } else if let item = turn.currentPlanItem {
                plan.move(to: item)
            }
            if !turn.memory.isEmpty {
                outcome.answer = turn.memory
                kept(turn.memory)
            }
            var results: [String] = []
            let actions = Array(turn.actions.prefix(settings.maxActionsPerStep))
            for (place, action) in actions.enumerated() {
                if case .done(let text, let success, let table) = action {
                    guard actions.count == 1 else {
                        results.append("Error: done must be the only action of its step.")
                        continue
                    }
                    // The table a done gives is the errand's whatever the check says of the done: the run writes
                    // what was collected when the errand did not finish, too.
                    if let table { outcome.table = table }
                    // A done that claims success is checked first, by the reference's judge, against the request and
                    // what each step came to: a send the user said no to is not sent (Codex review of 2026-10-19,
                    // P1-5). Rejected, the brain hears why and goes on; rejected again, the errand ends not finished.
                    if success, case .rejected(let reason) = try await judge(text, on: look.page) {
                        rejected += 1
                        guard rejected < settings.judgeRejections else { return finish(.notDone, answer: text) }
                        results.append("Error: done was rejected by the check: \(reason) Finish what is missing, or "
                                       + "call done with success=false saying what is missing.")
                        break
                    }
                    history.add(.init(evaluation: turn.evaluation, memory: turn.memory, nextGoal: turn.nextGoal,
                                      results: []))
                    return finish(success ? .done : .notDone, answer: text)
                }
                // The same action that failed `repeatsAllowed` times on this page is not run again: the brain is told
                // to try something else (browser-use breaks loops by the same rule, in its prompt and its failures).
                let tried = "\(look.page.url)|\(action)"
                if failed[tried, default: 0] >= settings.repeatsAllowed {
                    results.append("Not done: this exact action already failed \(settings.repeatsAllowed) times on this page; "
                                   + "it will not be run again. Try a different approach.")
                    continue
                }
                let before = await hands.address()
                let result = try await perform(action, on: look.page)
                if result.text.hasPrefix("Not done") || result.text.hasPrefix("Error") { failed[tried, default: 0] += 1 }
                results.append(result.text)
                readState += result.read
                if result.ended { return finish(.handedOver, answer: result.text) }
                var changed = action.changesPage
                if !changed, result.mayChangePage { changed = await hands.address() != before }
                if changed, place < actions.count - 1 {
                    results.append("Remaining actions skipped: the page changed.")
                    break
                }
            }
            history.add(.init(evaluation: turn.evaluation, memory: turn.memory, nextGoal: turn.nextGoal,
                              results: results))
        }
    }

    private func finish(_ ending: BrainOutcome.Ending, answer: String) -> BrainOutcome {
        outcome.ending = ending
        outcome.answer = answer
        log("[Brain] ending=\(ending.rawValue) steps=\(outcome.steps) asked=\(outcome.asked.count) sent=\(outcome.sent)")
        return outcome
    }

    /// One model call; its AgentOutput turn, or nil when none came.
    private func think(_ messages: [CDPValue]) async throws -> BrainTurn? {
        let reply = try await brain.think(messages, tools: [settings.table ? BrainPrompt.tableTool : BrainPrompt.tool])
        guard case .answered(let answer) = reply else {
            log("[Brain] no answer: \(ProLLMClient.logName(reply, cancelled: Task.isCancelled))")
            return nil
        }
        let call = answer.toolCalls.first { $0.name == "AgentOutput" } ?? answer.toolCalls.first
        return call.flatMap { BrainTurn(arguments: $0.arguments) }
    }

    private struct Result {
        var text: String
        var read: [String] = []
        /// A click or Enter: whether it left the page is read from the address after it.
        var mayChangePage = false
        /// The errand ended at it.
        var ended = false
    }

    private func element(_ index: Int, on page: ObservedPage) -> ObservedElement? {
        page.elements.first { $0.index == index }
    }

    private static func label(_ element: ObservedElement) -> String {
        let words = element.name.isEmpty ? element.text : element.name
        return "[\(element.index)] \(element.role) \"\(words.prefix(60))\""
    }

    /// What the hands made of an action, as its result reads and as the outcome keeps it.
    private func acted(_ acted: BrainActed, done: String) -> Result {
        if let question = acted.asked {
            outcome.asked.append(question)
            outcome.answersGiven.append(acted.kind != .userSaidNo)
        }
        if acted.sent { outcome.sent = true }
        switch acted.kind {
        case .done:
            return Result(text: done + (acted.sent ? " (sent with the user's Yes)" : ""), mayChangePage: true)
        case .notDone:
            return Result(text: "Not done: " + (acted.note.isEmpty ? "the page did not take it." : acted.note))
        case .userSaidNo:
            return Result(text: "Not done: The user said no. Do not try this action again.")
        case .ended:
            return Result(text: acted.note.isEmpty ? "This is the user's part; the errand ends here." : acted.note,
                          ended: true)
        }
    }

    private func perform(_ action: BrainAction, on page: ObservedPage) async throws -> Result {
        switch action {
        case .navigate(let url, _):
            guard let address = Self.webAddress(url) else {
                return Result(text: "Error: only http and https addresses can be opened.")
            }
            // An address the model wrote is asked about as a link is — its words, then Jev — never taken as a search
            // the app built (Codex review of 2026-10-19, P1-1).
            let open = AgentAction(operation: .open, target: nil, destination: address, payload: nil, isPlannedSearch: false)
            return acted(try await hands.act(open, on: page), done: "Opened \(address)")
        case .search(let query, let engine):
            let open = AgentAction(operation: .open, target: nil, destination: Self.searchAddress(query, engine: engine),
                                   payload: nil, isPlannedSearch: true)
            return acted(try await hands.act(open, on: page), done: "Searched \(engine) for \"\(query)\"")
        case .click(let index):
            guard let target = element(index, on: page) else { return Result(text: "Error: element \(index) is not on the page.") }
            let click = AgentAction(operation: target.role == "link" && target.href != nil ? .open : .click,
                                    target: target, destination: target.href, payload: nil, isPlannedSearch: false)
            return acted(try await hands.act(click, on: page), done: "Clicked \(Self.label(target))")
        case .input(let index, let text, let clear):
            guard let target = element(index, on: page) else { return Result(text: "Error: element \(index) is not on the page.") }
            let written = clear ? text : (target.value ?? "") + text
            let type = AgentAction(operation: .type, target: target, destination: nil, payload: written, isPlannedSearch: false)
            let hand = try await hands.act(type, on: page)
            if hand.kind == .done { lastTyped = (target, written) }
            var result = acted(hand, done: "Typed \"\(written.prefix(80))\" into \(Self.label(target))")
            result.mayChangePage = false
            return result
        case .selectDropdown(let index, let text):
            guard let target = element(index, on: page) else { return Result(text: "Error: element \(index) is not on the page.") }
            let select = AgentAction(operation: .select, target: target, destination: nil, payload: text, isPlannedSearch: false)
            var result = acted(try await hands.act(select, on: page), done: "Selected \"\(text.prefix(80))\" in \(Self.label(target))")
            result.mayChangePage = false
            return result
        case .scroll(let down, let pages, _):
            try await hands.scroll(down: down, pages: min(max(pages, 0.5), 10), on: page)
            return Result(text: "Scrolled \(down ? "down" : "up") \(pages) page(s)")
        case .sendKeys(let keys):
            guard keys.lowercased() == "enter" else {
                return Result(text: "Not done: only Enter can be pressed, in a field just typed into.")
            }
            guard let typed = lastTyped else { return Result(text: "Not done: type into a field first, then press Enter.") }
            return acted(try await hands.enter(after: typed.field, typed: typed.text, on: page), done: "Pressed Enter")
        case .goBack:
            let back = AgentAction(operation: .back, target: nil, destination: nil, payload: nil, isPlannedSearch: false)
            return acted(try await hands.act(back, on: page), done: "Went back")
        case .switchTab, .closeTab:
            return Result(text: "Not done: the errand works in one tab. Use navigate and go_back instead.")
        case .wait(let seconds):
            let wait = min(max(seconds, 0), settings.longestWait)
            try await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            return Result(text: "Waited \(wait) seconds")
        case .findText(let text):
            let found = try await hands.evaluate(BrainScripts.scrollToText(text))
            return Result(text: found == "true" ? "Scrolled to \"\(text.prefix(60))\"" : "Text \"\(text.prefix(60))\" not found on the page")
        case .searchPage(let pattern, let regex, let caseSensitive, let context, let max):
            let found = BrainScripts.search(try await hands.pageText(), pattern: pattern, caseSensitive: caseSensitive,
                                            contextChars: context, maxResults: max)
            return Result(text: "Searched the page for \"\(pattern.prefix(60))\"" + (regex ? " as plain text: patterns are not supported" : ""),
                          read: ["search_page \(pattern):\n\(found)"])
        case .findElements(let selector, let attributes, let max, let includeText):
            let found = try await hands.evaluate(BrainScripts.findElements(selector: selector, attributes: attributes,
                                                                           maxResults: max, includeText: includeText))
            return Result(text: "Found elements for \"\(selector.prefix(60))\"", read: ["find_elements \(selector):\n\(found)"])
        case .extract(let query, let start):
            return try await extract(query, from: start)
        case .recall(let question):
            let details = await recall(question)
            return Result(text: "Recalled the user's details for \"\(question.prefix(60))\"",
                          read: ["recall \(question): " + (details.isEmpty ? "nothing known" : details.joined(separator: "; "))])
        case .done:
            return Result(text: "Error: done must be the only action of its step.")
        case .notUnderstood(let names):
            return Result(text: "Error: not an action I can run: \(names.isEmpty ? "an empty item" : names). Each item names exactly one offered action with its parameters.")
        }
    }

    /// The whole page's text from `start`, read by the model for `query` (the reference's `extract`).
    private func extract(_ query: String, from start: Int) async throws -> Result {
        let text = BrainScripts.part(of: try await hands.pageText(), from: start, chars: settings.extractChars)
        let messages: [CDPValue] = [
            ["role": "system", "content": .string(BrainScripts.extractInstruction)],
            ["role": "user", "content": .string("<query>\n\(query)\n</query>\n<page_text>\n\(text)\n</page_text>")],
        ]
        guard case .answered(let answer) = try await brain.think(messages, tools: []), !answer.text.isEmpty else {
            return Result(text: "Error: the extraction failed.")
        }
        // A short answer is kept in the history for every later step, as the reference keeps it
        // (`long_term_memory` of `extract`, browser_use/tools/service.py, MIT); a longer one is shown once.
        if answer.text.count < settings.keptExtractChars {
            return Result(text: "Extracted \"\(query.prefix(60))\":\n\(answer.text)")
        }
        return Result(text: "Extracted \"\(query.prefix(60))\": \(answer.text.count) characters, shown once in <read_state>",
                      read: ["extract \(query):\n\(answer.text)"])
    }

    private enum Verdict { case accepted, rejected(String), unknown }

    /// The reference's judge (`browser_use/agent/judge.py`, MIT), asked whether the request is done as the answer
    /// says: the request, every step and what it came to, and the answer. No usable verdict, asked twice, is no
    /// confirmation: the done is rejected (Codex review 2 of 2026-10-19, P1).
    private func judge(_ answer: String, on page: ObservedPage) async throws -> Verdict {
        for _ in 0..<2 {
            let verdict = try await askJudge(answer, on: page)
            if case .unknown = verdict { continue }
            return verdict
        }
        return .rejected("the check could not confirm the result.")
    }

    /// The check reads the request, every step with the page the app read after it, the page the agent finished on
    /// — the one it called done on, which no step's page holds when done is its first call (blind run 1019c,
    /// 2026-10-19: a right answer read off the start page was "an empty trajectory") — and the answer.
    private func askJudge(_ answer: String, on page: ObservedPage) async throws -> Verdict {
        let trajectory = history.compact(limit: 60_000)
        let final = BrainHistory.excerpt(url: page.url, title: page.title, text: page.text)
        let messages: [CDPValue] = [
            ["role": "system", "content": .string(BrainJudge.instruction(today: today))],
            ["role": "user", "content": .string("<task>\n\(goal)\n</task>\n\n<agent_trajectory>\n\(trajectory)\n"
                                                 + "</agent_trajectory>\n\n<final_page>\nPage when the agent finished, as "
                                                 + "the app read it: \(final)\n</final_page>\n\n<final_result>\n\(answer)\n"
                                                 + "</final_result>\n\nEvaluate this agent execution given the criteria and "
                                                 + "respond with the exact JSON structure requested.")],
        ]
        guard case .answered(let reply) = try await brain.think(messages, tools: []),
              let verdict = BrainJudge.verdict(in: reply.text) else {
            log("[Brain] the check gave no verdict")
            return .unknown
        }
        log("[Brain] the check: \(verdict.passed ? "accepted" : "rejected")")
        return verdict.passed ? .accepted : .rejected(verdict.reason.isEmpty ? "the request is not done yet." : verdict.reason)
    }

    /// A search's address on `engine` — DuckDuckGo, Bing or Brave — the app builds from the query (the reference's
    /// `search`): a search engine that asks the agent to prove it is human is left for another.
    nonisolated static func searchAddress(_ query: String, engine: String) -> String {
        let base = ["bing": "https://www.bing.com/search", "brave": "https://search.brave.com/search"][engine]
            ?? "https://duckduckgo.com/"
        var parts = URLComponents(string: base)!
        parts.queryItems = [URLQueryItem(name: "q", value: query)]
        return parts.url!.absoluteString
    }

    /// The address as written when it is the web's, with https added when it names no scheme; nil for any
    /// other scheme.
    nonisolated static func webAddress(_ written: String) -> String? {
        let text = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let full: String
        if text.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil {
            guard let scheme = text.split(separator: ":").first?.lowercased(), ["http", "https"].contains(scheme) else {
                return nil
            }
            full = text
        } else {
            full = "https://" + text
        }
        guard let parts = URLComponents(string: full), parts.host?.isEmpty == false else { return nil }
        return full
    }
}
