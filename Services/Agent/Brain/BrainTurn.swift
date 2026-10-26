import Foundation

/// One action the brain asks for (owner decision of 2026-10-19: one model decides every step). The names and
/// parameters are the open-source browser-use agent's (`browser_use/tools/views.py` at aa093a8, MIT), plus
/// `recall`, which reads the user's own details. Indexes are the `index` of the page's elements as the step showed
/// them.
enum BrainAction: Equatable, Sendable {
    case navigate(url: String, newTab: Bool)
    case search(query: String, engine: String)
    case click(index: Int)
    case input(index: Int, text: String, clear: Bool)
    case selectDropdown(index: Int, text: String)
    case scroll(down: Bool, pages: Double, index: Int?)
    case sendKeys(String)
    case goBack
    case switchTab(id: String)
    case closeTab(id: String)
    case wait(seconds: Double)
    case findText(String)
    case searchPage(pattern: String, regex: Bool, caseSensitive: Bool, contextChars: Int, maxResults: Int)
    case findElements(selector: String, attributes: [String]?, maxResults: Int, includeText: Bool)
    case extract(query: String, startFromChar: Int)
    case recall(question: String)
    case done(text: String, success: Bool, table: BrainTable? = nil)
    /// An item that names no offered action, names two, or lacks what its action needs: by the names it held.
    case notUnderstood(String)

    /// It always leaves the page it was asked on: the actions after it in the step are skipped.
    var changesPage: Bool {
        switch self {
        case .navigate, .search, .goBack, .switchTab: true
        default: false
        }
    }

    /// Read from one item of the action list: an object with exactly one key, the action's name, its parameters
    /// under it — or one written flat (GLM-5.3 and Kimi K3, blind set of 2026-10-19): the name under "action",
    /// "type" or "name" with the parameters beside it, or no name at all and parameters that name one action alone —
    /// an index with a text is an input, an index alone a click. A name that is no action is never guessed from the
    /// parameters beside it.
    init(item: [String: Any]) {
        if item.count == 1, let (name, value) = item.first {
            self = Self.read(name, value as? [String: Any] ?? [:]) ?? Self.readFlat(item) ?? .notUnderstood(name)
        } else {
            self = Self.readNamed(item) ?? Self.readFlat(item) ?? .notUnderstood(item.keys.sorted().joined(separator: ", "))
        }
    }

    /// Every action's name, as the tool offers them.
    static let names: Set<String> = ["navigate", "search", "click", "input", "select_dropdown", "scroll", "send_keys",
                                     "go_back", "switch", "close", "wait", "find_text", "search_page", "find_elements",
                                     "extract", "recall", "done"]

    /// An item that names one action with its parameters under it and strays beside it — "query" repeated outside a
    /// "search" — is that action; one that names two is not understood.
    private static func readNamed(_ item: [String: Any]) -> BrainAction? {
        let named = item.filter { names.contains($0.key) }
        guard named.count == 1, let (name, value) = named.first, let parameters = value as? [String: Any] else { return nil }
        return read(name, parameters)
    }

    private static let nameKeys = ["action", "type", "name"]

    private static func readFlat(_ item: [String: Any]) -> BrainAction? {
        var parameters = item
        for key in nameKeys { parameters[key] = nil }
        if let name = nameKeys.lazy.compactMap({ string(item[$0]) }).first { return read(name, parameters) }
        guard parameters["index"] != nil, Set(parameters.keys).isSubset(of: ["index", "text", "clear"]) else { return nil }
        return read(parameters.count == 1 ? "click" : "input", parameters)
    }

    private static func read(_ name: String, _ p: [String: Any]) -> BrainAction? {
        switch name {
        case "navigate": return string(p["url"]).map { .navigate(url: $0, newTab: bool(p["new_tab"]) ?? false) }
        case "search":
            let engine = string(p["engine"])?.lowercased()
            return string(p["query"]).map { .search(query: $0, engine: ["bing", "brave"].contains(engine ?? "") ? engine! : "duckduckgo") }
        case "click": return int(p["index"]).map { .click(index: $0) }
        case "input":
            guard let index = int(p["index"]), let text = string(p["text"]) else { return nil }
            return .input(index: index, text: text, clear: bool(p["clear"]) ?? true)
        case "select_dropdown":
            guard let index = int(p["index"]), let text = string(p["text"]) else { return nil }
            return .selectDropdown(index: index, text: text)
        case "scroll":
            return .scroll(down: bool(p["down"]) ?? true, pages: double(p["pages"]) ?? 1, index: int(p["index"]))
        case "send_keys": return string(p["keys"]).map { .sendKeys($0) }
        case "go_back": return .goBack
        case "switch": return string(p["tab_id"]).map { .switchTab(id: $0) }
        case "close": return string(p["tab_id"]).map { .closeTab(id: $0) }
        case "wait": return .wait(seconds: double(p["seconds"]) ?? 3)
        case "find_text": return string(p["text"]).map { .findText($0) }
        case "search_page":
            guard let pattern = string(p["pattern"]) else { return nil }
            return .searchPage(pattern: pattern, regex: bool(p["regex"]) ?? false,
                               caseSensitive: bool(p["case_sensitive"]) ?? false,
                               contextChars: int(p["context_chars"]) ?? 150, maxResults: int(p["max_results"]) ?? 25)
        case "find_elements":
            guard let selector = string(p["selector"]) else { return nil }
            return .findElements(selector: selector, attributes: (p["attributes"] as? [Any])?.compactMap(string),
                                 maxResults: int(p["max_results"]) ?? 50, includeText: bool(p["include_text"]) ?? true)
        case "extract":
            return string(p["query"]).map { .extract(query: $0, startFromChar: int(p["start_from_char"]) ?? 0) }
        case "recall": return string(p["question"]).map { .recall(question: $0) }
        case "done":
            return string(p["text"]).map { .done(text: $0, success: bool(p["success"]) ?? true, table: table(p)) }
        default: return nil
        }
    }

    private static func string(_ value: Any?) -> String? { value as? String }

    /// The table a done gives (a table errand's): its columns and its rows, every cell as text — a number as the
    /// model wrote it, a missing cell empty; nil when it gives no row with a cell.
    private static func table(_ p: [String: Any]) -> BrainTable? {
        let rows = (p["rows"] as? [Any] ?? []).compactMap { ($0 as? [Any])?.map(cell) }.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return nil }
        return BrainTable(columns: (p["columns"] as? [Any] ?? []).map(cell), rows: rows)
    }

    private static func cell(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return isFlag(number) ? (number.boolValue ? "true" : "false") : number.stringValue }
        guard !(value is NSNull), let data = try? JSONSerialization.data(withJSONObject: value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// JSON's true and false, told from the numbers 1 and 0, which Swift would also cast to Bool.
    private static func isFlag(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    private static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber, isFlag(number) { return number.boolValue }
        if let text = value as? String { return ["true": true, "false": false][text.lowercased()] }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return isFlag(number) ? nil : number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = double(value), number.rounded() == number, abs(number) < 1e9 else { return nil }
        return Int(number)
    }
}

/// The table a table errand's done gives: its column names, then one row per item, every cell as text.
struct BrainTable: Equatable, Sendable {
    var columns: [String]
    var rows: [[String]]
}

/// One step's answer: what the brain made of the last step, what it keeps, where it goes next, its plan, and
/// the actions to run in order — the reference's AgentOutput (`browser_use/agent/views.py`, MIT).
struct BrainTurn: Equatable, Sendable {
    var thinking: String?
    var evaluation: String
    var memory: String
    var nextGoal: String
    var currentPlanItem: Int?
    var planUpdate: [String]?
    var actions: [BrainAction]

    /// Read from the AgentOutput call's arguments; nil when they are not an object with a non-empty action list.
    init?(arguments: String) {
        guard let data = arguments.data(using: .utf8),
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var list = fields["action"] as? [Any]
        if list == nil, let text = fields["action"] as? String, let data = text.data(using: .utf8) {
            list = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        }
        guard let items = list, !items.isEmpty else { return nil }
        thinking = fields["thinking"] as? String
        evaluation = fields["evaluation_previous_goal"] as? String ?? ""
        memory = fields["memory"] as? String ?? ""
        nextGoal = fields["next_goal"] as? String ?? ""
        currentPlanItem = (fields["current_plan_item"] as? NSNumber)?.intValue
        planUpdate = (fields["plan_update"] as? [Any])?.compactMap { $0 as? String }
        actions = items.map { BrainAction(item: $0 as? [String: Any] ?? [:]) }
    }
}
