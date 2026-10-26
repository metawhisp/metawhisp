import Foundation

/// An open tab as the step state lists it: the last four characters of its target id, as the reference shows tabs.
struct BrainTab: Equatable, Sendable {
    let id: String
    let url: String
    let title: String
    let current: Bool
}

/// The steps so far, as the brain reads them back each step (`<agent_history>`).
struct BrainHistory: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        let evaluation: String
        let memory: String
        let nextGoal: String
        let results: [String]
        /// The page the app read after the step — its address, title and first words — the check's evidence of
        /// what the brain's words rest on (2026-10-19: a text-only check called true findings made up). The brain
        /// itself sees the page whole, so its own history leaves this out.
        var pageAfter: String? = nil
    }

    /// How many characters of a page's text the check is shown for a step.
    static let pageAfterChars = 800
    static let pageAfterLabel = "Page after the step, as the app read it: "

    private(set) var steps: [Step] = []

    mutating func add(_ step: Step) { steps.append(step) }

    /// The page the app read after the last step, for the check.
    mutating func notePage(url: String, title: String, text: String) {
        guard !steps.isEmpty else { return }
        steps[steps.count - 1].pageAfter = Self.excerpt(url: url, title: title, text: text)
    }

    /// A page as the check is shown it: its address, title and first words on one line each.
    static func excerpt(url: String, title: String, text: String) -> String {
        let words = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "\(url) — \(title)\n" + String(words.prefix(pageAfterChars))
    }

    /// Every step for the check, oldest first — the brain's words, the app's action results and the page the app
    /// read after each step — within `limit` characters while each step keeps 80 characters of words: over the
    /// limit, each one's evaluation, results and page, without its memory and next goal — no step is dropped, so a
    /// No early in the errand is read at its end (Codex review 2 of 2026-10-19, P2). Each step's frame — tags,
    /// labels, line breaks — is counted first; the rest is shared by the steps, a third of a step's share to its
    /// evaluation, a third to the page, the rest to its results (Codex review 3 of 2026-10-19, P2).
    func compact(limit: Int) -> String {
        let full = description(forTheCheck: true)
        guard full.count > limit else { return full }
        var frames = max(0, steps.count - 1)
        for (number, step) in steps.enumerated() {
            frames += "<step_\(number + 1)>".count + "</step_\(number + 1)>".count + "Evaluation: ".count
            frames += step.results.count * "Result: ".count + step.results.count + 2
            if step.pageAfter != nil { frames += Self.pageAfterLabel.count + 1 }
        }
        let each: Int = max(80, (limit - frames) / max(1, steps.count))
        var blocks: [String] = []
        for (number, step) in steps.enumerated() {
            let page = step.pageAfter.map { String($0.prefix(each / 3)) }
            let share: Int = (each - each / 3 - (page?.count ?? 0)) / max(1, step.results.count)
            var lines: [String] = ["<step_\(number + 1)>", "Evaluation: " + String(step.evaluation.prefix(each / 3))]
            for result in step.results { lines.append("Result: " + String(result.prefix(max(0, share)))) }
            if let page { lines.append(Self.pageAfterLabel + page) }
            lines.append("</step_\(number + 1)>")
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n")
    }

    /// `<step_n>` blocks, oldest first, as the brain reads them.
    var description: String { description(forTheCheck: false) }

    /// `<step_n>` blocks, oldest first; for the check, with the page the app read after each step.
    func description(forTheCheck: Bool) -> String {
        steps.enumerated().map { number, step in
            let results = step.results.enumerated().map { "Action \($0.offset + 1)/\(step.results.count): \($0.element)" }
            let page = forTheCheck ? step.pageAfter.map { [Self.pageAfterLabel + $0] } ?? [] : []
            return (["<step_\(number + 1)>", "Evaluation of Previous Step: \(step.evaluation)", "Memory: \(step.memory)",
                     "Next Goal: \(step.nextGoal)", "Action Results:"] + results + page + ["</step_\(number + 1)>"])
                .joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

/// The brain's own plan (`plan_update`, `current_plan_item`): every item before the current one counts as done.
struct BrainPlan: Equatable, Sendable {
    private(set) var items: [String] = []
    private(set) var current = 0

    /// A new plan; its current item is `current`, or the first.
    mutating func update(items: [String], current: Int?) {
        self.items = items
        self.current = min(max(0, current ?? 0), max(0, items.count - 1))
    }

    mutating func move(to item: Int) {
        guard !items.isEmpty else { return }
        current = min(max(0, item), items.count - 1)
    }

    var description: String {
        guard !items.isEmpty else { return "[empty plan, fill it with plan_update when applicable]" }
        return items.enumerated().map { place, item in
            (place < current ? "[x] " : place == current ? "[>] " : "[ ] ") + item
        }.joined(separator: "\n")
    }
}

extension BrainPrompt {
    /// The one tool the brain answers with: the reference's AgentOutput, each action item an object naming exactly
    /// one action (`browser_use/tools/views.py` parameter models, MIT), plus `recall`. Its schema holds only the
    /// keywords the Pro server's route takes: "exactly one key" is said in words, and `BrainAction` reads an item by
    /// its one action name (2026-10-20: `minProperties`/`maxProperties` made the route refuse every step).
    static let tool: CDPValue = agentOutput(actions)

    /// The tool of an errand the user asked a table of: its done also takes the table's columns and rows — the
    /// reference's structured output, whose done carries the data in the shape asked (`output_model_schema`, MIT).
    static let tableTool: CDPValue = agentOutput(.object((actions.object ?? [:]).merging(["done": tableDone]) { $1 }))

    private static func agentOutput(_ actions: CDPValue) -> CDPValue { [
        "type": "function",
        "function": [
            "name": "AgentOutput",
            "description": "Your assessment of the last step, your memory, your next goal and the actions to run now.",
            "parameters": [
                "type": "object",
                "properties": [
                    "thinking": ["type": "string"],
                    "evaluation_previous_goal": ["type": "string"],
                    "memory": ["type": "string"],
                    "next_goal": ["type": "string"],
                    "current_plan_item": ["type": "integer"],
                    "plan_update": ["type": "array", "items": ["type": "string"]],
                    "action": [
                        "type": "array",
                        "minItems": 1,
                        "description": "Actions to run in order. Each item is an object with exactly one key: the action's name.",
                        "items": ["type": "object", "properties": actions],
                    ],
                ],
                "required": ["evaluation_previous_goal", "memory", "next_goal", "action"],
            ],
        ],
    ] }

    private static func action(_ description: String, _ properties: [String: CDPValue] = [:],
                               required: [String] = []) -> CDPValue {
        var schema: [String: CDPValue] = ["type": "object", "description": .string(description),
                                          "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { CDPValue.string($0) }) }
        return .object(schema)
    }

    private static let index: CDPValue = ["type": "integer", "description": "Element index from browser_state"]

    private static let actions: CDPValue = [
        "navigate": action("Navigate to a URL in the errand's tab.", ["url": ["type": "string"]], required: ["url"]),
        "search": action("Search the web for a query.",
                         ["query": ["type": "string"],
                          "engine": ["type": "string", "enum": ["duckduckgo", "bing", "brave"],
                                     "description": "duckduckgo by default; bing or brave when one shows a CAPTCHA"]],
                         required: ["query"]),
        "click": action("Click element by index.", ["index": index], required: ["index"]),
        "input": action("Input text into element by index. Clears existing text by default; pass text=\"\" to clear only, or clear=False to append.",
                        ["index": index,
                         "text": ["type": "string", "description": "Text to enter. With clear=True, text=\"\" clears the field without typing."],
                         "clear": ["type": "boolean", "description": "Clear existing text before typing. Set to False to append instead."]],
                        required: ["index", "text"]),
        "select_dropdown": action("Set the option of a <select> element.",
                                  ["index": index, "text": ["type": "string", "description": "exact text/value"]],
                                  required: ["index", "text"]),
        "scroll": action("Scroll the page by pages. down=True/False (True=scroll down, False=scroll up, default=True). Optional: pages=0.5-10.0 (default 1.0). High pages (10) reaches bottom.",
                         ["down": ["type": "boolean"], "pages": ["type": "number"]]),
        "send_keys": action("Press Enter in the field you just typed into: it sends that field's search, or its form through the form's own button (a send asks the user first). Only Enter can be pressed.",
                            ["keys": ["type": "string", "description": "Enter"]], required: ["keys"]),
        "go_back": action("Go back"),
        "wait": action("Wait for x seconds.", ["seconds": ["type": "number"]]),
        "find_text": action("Scroll to text.", ["text": ["type": "string"]], required: ["text"]),
        "search_page": action("Search page text for a pattern (like grep). Zero LLM cost, instant. Returns matches with surrounding context. Use to find specific text, verify content exists, or locate data on the page. The pattern is plain text.",
                              ["pattern": ["type": "string", "description": "Text to search for in page content"],
                               "case_sensitive": ["type": "boolean", "description": "Case-sensitive search (default: case-insensitive)"],
                               "context_chars": ["type": "integer", "description": "Characters of surrounding context per match"],
                               "max_results": ["type": "integer", "description": "Maximum matches to return"]],
                              required: ["pattern"]),
        "find_elements": action("Query DOM elements by CSS selector (like find). Zero LLM cost, instant. Returns matching elements with tag, text, and attributes. Use to explore page structure, count items, get links/attributes. Use attributes=[\"href\",\"src\"] to extract specific attributes.",
                                ["selector": ["type": "string", "description": "CSS selector to query elements (e.g. \"table tr\", \"a.link\", \"div.product\")"],
                                 "attributes": ["type": "array", "items": ["type": "string"], "description": "Specific attributes to extract (e.g. [\"href\", \"src\", \"class\"]). If not set, returns tag and text only."],
                                 "max_results": ["type": "integer", "description": "Maximum elements to return"],
                                 "include_text": ["type": "boolean", "description": "Include text content of each element"]],
                                required: ["selector"]),
        "extract": action("LLM extracts structured data from the whole page's text. Use when: on right page, know what to extract, haven't called before on same page+query. Can't get interactive elements. Use start_from_char if previous extraction was truncated to extract data further down the page.",
                          ["query": ["type": "string"],
                           "start_from_char": ["type": "integer", "description": "Use this for long pages to start from a specific character (not index in browser_state)"]],
                          required: ["query"]),
        "recall": action("Read the user's own details (name, email, phone, company, address) that the user told this app. Returns what it knows, or nothing.",
                         ["question": ["type": "string"]], required: ["question"]),
        "done": action(doneSays, ["text": doneText, "success": doneSuccess], required: ["text"]),
    ]

    private static let doneSays = "Complete task. Only report actions you performed and data you extracted in this session."
    private static let doneText: CDPValue = ["type": "string", "description": "Final message to the user. ONLY report data you directly observed in browser_state or tool outputs during this session. Do NOT use training knowledge to fill gaps — if information was not found on the page, say so explicitly. Give the links of the pages it comes from."]
    private static let doneSuccess: CDPValue = ["type": "boolean", "description": "True if user_request completed successfully"]

    /// A table errand's done: the text and the success of the plain one, and the table.
    private static let tableDone = action(
        doneSays + " The user asked for a table: give its columns and one row per item, every cell copied from what you observed in this session.",
        ["text": doneText, "success": doneSuccess,
         "columns": ["type": "array", "items": ["type": "string"],
                     "description": "The table's column names, in order. Give the link of the page each item comes from a column of its own."],
         "rows": ["type": "array", "items": ["type": "array", "items": ["type": "string"]],
                  "description": "One row per item, its cells in the columns' order; an empty cell where the page showed nothing."]],
        required: ["text", "rows"])

    /// One step's message: the request, the history, the plan, the browser, what the last step read, and the
    /// step count — the reference's `get_user_message` without screenshots. A control the previous look did not
    /// have, on the same page, is starred.
    static func state(goal: String, history: BrainHistory, plan: BrainPlan, tabs: [BrainTab], page: ObservedPage,
                      previous: ObservedPage?, readState: [String], step: Int, maxSteps: Int, today: String) -> String {
        var text = "<user_request>\n\(goal)\n</user_request>\n\n"
        let past = history.description
        text += "<agent_history>\n" + (past.isEmpty ? "" : past + "\n") + "</agent_history>\n\n"
        text += "<agent_state>\n<plan>\n\(plan.description)\n</plan>\n</agent_state>\n"
        text += "<browser_state>\n"
        if let current = tabs.first(where: \.current) { text += "Current tab: \(current.id)\n" }
        text += "Available tabs:\n"
        for tab in tabs { text += "Tab \(tab.id): \(tab.url) - \(tab.title.prefix(30))\n" }
        text += "\n"
        text += "Interactive elements" + (page.truncated ? " (more on the page than shown: scroll, or use find_elements)" : "")
            + ":\n" + elements(of: page, previous: previous) + "\n"
        text += "Page text:\n" + (page.text.isEmpty ? "" : page.text + "\n")
            + (page.textCut ? "[Text cut: scroll, use search_page or extract for the rest]" : "[End of page]") + "\n"
        text += "</browser_state>\n"
        if !readState.isEmpty { text += "<read_state>\n" + readState.joined(separator: "\n") + "\n</read_state>\n" }
        text += "<step_info>Step\(step) maximum:\(maxSteps)\nToday:\(today)</step_info>\n"
        return text
    }

    /// Every control on its own line, its own words under it, a section's heading before its first control.
    static func elements(of page: ObservedPage, previous: ObservedPage?) -> String {
        guard !page.elements.isEmpty else { return "empty page" }
        let seen: Set<ElementIdentity>? = previous.flatMap { before in
            before.liveAddress == page.liveAddress ? Set(before.elements.map(before.identity(of:))) : nil
        }
        var lines: [String] = []
        var heading: String?
        for element in page.elements {
            if let section = element.heading, !section.isEmpty, section != heading { lines.append("## \(section)") }
            heading = element.heading ?? heading
            let isNew = seen.map { !$0.contains(page.identity(of: element)) } ?? false
            lines.append((isNew ? "*" : "") + "[\(element.index)]<\(element.role)" + attributes(of: element, on: page) + " />")
            let words = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { lines.append("\t" + String(words.prefix(150))) }
        }
        return lines.joined(separator: "\n")
    }

    private static func attributes(of element: ObservedElement, on page: ObservedPage) -> String {
        var parts: [String] = []
        let words = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !element.name.isEmpty, element.name != words { parts.append("name=\(element.name.prefix(80))") }
        if let type = element.inputType, !type.isEmpty, !["submit", "button"].contains(type) { parts.append("type=\(type)") }
        if let href = element.href { parts.append("href=\(shown(href, from: page.url))") }
        if let value = element.value { parts.append("value=\"\(value.prefix(80))\"") }
        if let checked = element.checked { parts.append(checked ? "checked" : "unchecked") }
        if let options = element.options {
            parts.append("options=\"" + options.prefix(12).joined(separator: "|") + (options.count > 12 ? "|…" : "") + "\"")
        }
        if element.submits == true { parts.append("submits") }
        if let row = element.context, !row.isEmpty { parts.append("row=\"\(row.prefix(80))\"") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    /// A link on the page's own host by its path; any other by its whole address — at most 120 characters.
    private static func shown(_ href: String, from pageURL: String) -> String {
        guard let link = URLComponents(string: href), let here = URLComponents(string: pageURL),
              link.host != nil, link.host == here.host else { return String(href.prefix(120)) }
        var path = link.percentEncodedPath.isEmpty ? "/" : link.percentEncodedPath
        if let query = link.percentEncodedQuery { path += "?" + query }
        if let fragment = link.percentEncodedFragment { path += "#" + fragment }
        return String(path.prefix(120))
    }
}
