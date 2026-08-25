import Foundation

/// ITER-027.6 — the INVESTIGATION loop behind proactive insights.
///
/// v1 made one blind LLM call over the latest screen — the model had nothing
/// non-obvious to say, so it echoed the screen back («Rerun Failed Agents»
/// while the user is looking at the failed-agents list; user verdict:
/// «бесполезные подсказки»). The reference product's content is different
/// because its MECHANIC is different: the model first investigates recent
/// history with tools, confirms what it found, and only then advises —
/// «you stashed changes 2h ago — git stash pop» comes from HISTORY, not from
/// the current frame.
///
/// This engine is pure: tools execute over an in-memory snapshot array and
/// the LLM round-trip is an injected `Transport`, so the whole loop is unit
/// tested without network or SwiftData. Adapted to our constraints (copy
/// methodology): structured search tools instead of raw SQL (no GRDB here),
/// text confirmation via `get_screen_text` instead of a vision screenshot
/// pass (our proxy models are text-only today).
enum InsightInvestigator {

    /// One screen-history record the tools can search. `id` for the model is
    /// the array index — stable within a single run.
    struct Snapshot: Equatable {
        let time: Date
        let app: String
        let window: String
        let ocr: String
    }

    /// One model turn from the tools endpoint.
    struct ModelTurn {
        let text: String
        let toolName: String?
        /// Parsed arguments of the first tool call (empty when none).
        let toolArgs: [String: Any]
        /// Raw arguments JSON string — echoed back in the assistant message.
        let toolArgsRaw: String
        let toolCallId: String?

        init(text: String, toolName: String?, toolArgs: [String: Any] = [:],
             toolArgsRaw: String = "{}", toolCallId: String? = nil) {
            self.text = text
            self.toolName = toolName
            self.toolArgs = toolArgs
            self.toolArgsRaw = toolArgsRaw
            self.toolCallId = toolCallId
        }
    }

    /// The LLM round-trip: (messages, tools) → one turn. Injected so tests
    /// script the conversation.
    typealias Transport = (_ messages: [[String: Any]], _ tools: [[String: Any]]) async throws -> ModelTurn

    /// One record pulled from the user's own store during investigation.
    /// ITER-069 — these ride back to the caller so retrieved claims can be
    /// grounded: without them, a comment citing a stored requirement was
    /// silenced as ungrounded because the evidence allowlist never saw it.
    struct RetrievedRef: Equatable {
        let id: String
        let text: String
    }

    enum Outcome: Equatable {
        case advice(ExtractedInsight, retrieved: [RetrievedRef])
        case none(reason: String)
    }

    /// Hard cap on model turns — a runaway loop costs money every round.
    static let maxRounds = 5
    static let searchLimitCap = 20
    static let snippetChars = 200
    static let fullTextChars = 4000
    static let defaultLookbackMinutes = 120.0

    // MARK: - Tool schemas (OpenAI function format)

    static func toolSchemas() -> [[String: Any]] {
        func tool(_ name: String, _ description: String, _ props: [String: [String: Any]], required: [String]) -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": name,
                    "description": description,
                    "parameters": [
                        "type": "object",
                        "properties": props,
                        "required": required,
                    ],
                ],
            ]
        }
        return [
            tool("search_screen_history",
                 "Search the user's screen-activity history from the last 2 hours. Returns matching records with id, time, app, window title and a 200-char OCR snippet. Use this to investigate what the user was ACTUALLY doing before advising.",
                 [
                    "app_contains": ["type": "string", "description": "Filter: app name contains this (case-insensitive). Optional."],
                    "text_contains": ["type": "string", "description": "Filter: OCR text or window title contains this (case-insensitive). Optional."],
                    "minutes_back": ["type": "number", "description": "How far back to search, minutes (max 120). Default 120."],
                    "limit": ["type": "number", "description": "Max records (max 20). Default 10."],
                 ], required: []),
            tool("get_screen_text",
                 "Fetch the FULL OCR text of one history record by its id (from search_screen_history). Confirm your hypothesis here BEFORE advising — never advise from a snippet alone.",
                 ["id": ["type": "number", "description": "Record id from search results."]], required: ["id"]),
            tool("provide_advice",
                 "Surface ONE specific, non-obvious insight to the user. Only after investigating. Same quality bar as the system prompt: specific to their activity AND something they likely don't already know.",
                 [
                    "advice": ["type": "string", "description": "1-2 sentences, ≤100 chars, start with the actionable part."],
                    "headline": ["type": "string", "description": "≤5 words, notification preview."],
                    "reasoning": ["type": "string", "description": "Why this matters now — cite what you found while investigating."],
                    "category": ["type": "string", "description": "productivity | communication | learning | other"],
                    "source_app": ["type": "string", "description": "App where the context was observed."],
                    "confidence": ["type": "number", "description": "0.60-1.00. Calibrate: 0.90+ = preventing a clear mistake; 0.75-0.89 = highly relevant non-obvious tip; 0.60-0.74 = useful but the user might already know."],
                 ], required: ["advice", "category", "source_app", "confidence"]),
            // ITER-069 — descriptions ported from the shipped MetaChat tool
            // schemas (same store, same meaning), scoped down to the proactive
            // budget: one call each.
            tool("search_tasks",
                 "Find the user's OPEN tasks matching a free-text query. Returns top matches with description, assignee, due date. ONE call per run: use it when the screen may relate to something the user already committed to.",
                 [
                    "query": ["type": "string", "description": "Free-text query (person name, project, action verb, etc.)."],
                 ], required: ["query"]),
            tool("search_memories",
                 "Find the user's saved facts, decisions and requirements matching a free-text query. ONE call per run: use it when the screen may conflict with or fulfil something the user decided earlier.",
                 [
                    "query": ["type": "string", "description": "Free-text query (topic, requirement, decision, person)."],
                 ], required: ["query"]),
            tool("no_advice",
                 "Nothing worth surfacing after investigation. This ends the analysis — the correct outcome for MOST runs.",
                 ["context_summary": ["type": "string", "description": "One line: what the user is doing."]], required: []),
        ]
    }

    // MARK: - Tool execution (pure)

    static func executeSearch(snapshots: [Snapshot], appContains: String?, textContains: String?,
                              minutesBack: Double?, limit: Int?, now: Date) -> String {
        let lookback = min(max(minutesBack ?? defaultLookbackMinutes, 1), defaultLookbackMinutes)
        let cap = min(max(limit ?? 10, 1), searchLimitCap)
        let cutoff = now.addingTimeInterval(-lookback * 60)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"

        var rows: [String] = []
        for (i, s) in snapshots.enumerated() {
            guard s.time >= cutoff else { continue }
            if let a = appContains, !a.isEmpty,
               !s.app.localizedCaseInsensitiveContains(a) { continue }
            if let t = textContains, !t.isEmpty,
               !s.ocr.localizedCaseInsensitiveContains(t),
               !s.window.localizedCaseInsensitiveContains(t) { continue }
            let snippet = String(s.ocr.prefix(snippetChars)).replacingOccurrences(of: "\n", with: " ")
            rows.append("id=\(i) [\(fmt.string(from: s.time))] \(s.app) — \(String(s.window.prefix(60))) | \(snippet)")
            if rows.count >= cap { break }
        }
        return rows.isEmpty ? "No matching records." : rows.joined(separator: "\n")
    }

    static func executeGetText(snapshots: [Snapshot], id: Int) -> String {
        guard id >= 0, id < snapshots.count else {
            return "Error: no record with id=\(id)."
        }
        let s = snapshots[id]
        return "[\(s.app) — \(s.window)]\n" + String(s.ocr.prefix(fullTextChars))
    }

    // MARK: - The loop

    /// Read-only bridge to the user's store. Injected so the loop stays pure
    /// and the privacy/owner filters stay where they already live —
    /// `ChatToolExecutor` — instead of growing a second copy here.
    typealias StoreSearch = @MainActor (_ query: String) async -> String

    static func run(snapshots: [Snapshot], systemUnused: Void = (), userPrompt: String,
                    now: Date = Date(), transport: Transport,
                    searchTasks: StoreSearch? = nil,
                    searchMemories: StoreSearch? = nil) async -> Outcome {
        var messages: [[String: Any]] = [["role": "user", "content": userPrompt]]
        let tools = toolSchemas()
        // Codex 2026-08-10 — the investigation is a CONTRACT, not a suggestion:
        // without these the model could answer provide_advice on turn one and
        // reproduce the exact screen-echo card this loop exists to prevent.
        var didSearch = false
        var didConfirmRead = false
        // ITER-069 §5 — one store lookup per kind per run. The chat loop may
        // browse; a proactive run buys exactly one connection to the user's
        // tasks and one to their memories, or it stops.
        var usedTaskSearch = false
        var usedMemorySearch = false
        var retrieved: [RetrievedRef] = []

        for round in 1 ... maxRounds {
            let turn: ModelTurn
            do {
                turn = try await transport(messages, tools)
            } catch {
                return .none(reason: "transport error: \(error.localizedDescription)")
            }

            guard let tool = turn.toolName, let callId = turn.toolCallId else {
                // Tools are mandatory in this loop — a bare text answer is the
                // model dodging the contract. Silence beats junk.
                return .none(reason: "no tool call in round \(round)")
            }

            switch tool {
            case "provide_advice":
                // Advice is unlocked only by a completed investigation: a
                // search AND a successful full-text read to confirm it. A
                // snippet is not evidence, and the current frame is not an
                // insight. Nudge back to the tools instead of accepting.
                guard didSearch, didConfirmRead else {
                    let missing = !didSearch
                        ? "call search_screen_history first"
                        : "confirm your hypothesis with get_screen_text on a specific record first"
                    appendToolExchange(&messages, turn: turn, tool: tool, callId: callId,
                                       result: "Rejected: you must investigate before advising — \(missing). Advice based only on the current screen is an echo, not an insight; call no_advice if the history holds nothing.")
                    continue
                }
                guard let advice = turn.toolArgs["advice"] as? String, !advice.isEmpty,
                      let confidence = doubleArg(turn.toolArgs["confidence"]) else {
                    return .none(reason: "malformed provide_advice args")
                }
                let insight = ExtractedInsight(
                    body: advice,
                    headline: turn.toolArgs["headline"] as? String,
                    reasoning: turn.toolArgs["reasoning"] as? String,
                    category: (turn.toolArgs["category"] as? String) ?? "other",
                    sourceApp: (turn.toolArgs["source_app"] as? String) ?? "",
                    confidence: confidence
                )
                return .advice(insight, retrieved: retrieved)

            case "no_advice":
                return .none(reason: (turn.toolArgs["context_summary"] as? String) ?? "no_advice")

            case "search_screen_history":
                let result = executeSearch(
                    snapshots: snapshots,
                    appContains: turn.toolArgs["app_contains"] as? String,
                    textContains: turn.toolArgs["text_contains"] as? String,
                    minutesBack: doubleArg(turn.toolArgs["minutes_back"]),
                    limit: intArg(turn.toolArgs["limit"]),
                    now: now
                )
                didSearch = true
                appendToolExchange(&messages, turn: turn, tool: tool, callId: callId, result: result)

            case "get_screen_text":
                let id = intArg(turn.toolArgs["id"]) ?? -1
                let result = executeGetText(snapshots: snapshots, id: id)
                // Only a SUCCESSFUL read counts as confirmation — an error
                // ("no record with id=…") must not unlock advice.
                if !result.hasPrefix("Error") { didConfirmRead = true }
                appendToolExchange(&messages, turn: turn, tool: tool, callId: callId, result: result)

            case "search_tasks":
                guard let searchTasks else {
                    appendToolExchange(&messages, turn: turn, tool: tool, callId: callId,
                                       result: "Error: task search is not available in this run.")
                    continue
                }
                guard !usedTaskSearch else {
                    appendToolExchange(&messages, turn: turn, tool: tool, callId: callId,
                                       result: "Rejected: one task search per run. Use what you have or call no_advice.")
                    continue
                }
                usedTaskSearch = true
                let query = (turn.toolArgs["query"] as? String) ?? ""
                let result = await searchTasks(query)
                // An error result reaches the model as feedback but never the
                // evidence allowlist — a failed search proves nothing.
                if !result.hasPrefix("Error") {
                    retrieved.append(.init(id: "t\(retrieved.count)", text: result))
                }
                appendToolExchange(&messages, turn: turn, tool: tool, callId: callId, result: result)

            case "search_memories":
                guard let searchMemories else {
                    appendToolExchange(&messages, turn: turn, tool: tool, callId: callId,
                                       result: "Error: memory search is not available in this run.")
                    continue
                }
                guard !usedMemorySearch else {
                    appendToolExchange(&messages, turn: turn, tool: tool, callId: callId,
                                       result: "Rejected: one memory search per run. Use what you have or call no_advice.")
                    continue
                }
                usedMemorySearch = true
                let query = (turn.toolArgs["query"] as? String) ?? ""
                let result = await searchMemories(query)
                // An error result reaches the model as feedback but never the
                // evidence allowlist — a failed search proves nothing.
                if !result.hasPrefix("Error") {
                    retrieved.append(.init(id: "m\(retrieved.count)", text: result))
                }
                appendToolExchange(&messages, turn: turn, tool: tool, callId: callId, result: result)

            default:
                appendToolExchange(&messages, turn: turn, tool: tool, callId: callId,
                                   result: "Error: unknown tool \(tool).")
            }
        }
        return .none(reason: "rounds exhausted (\(maxRounds))")
    }

    // MARK: - Helpers

    private static func appendToolExchange(_ messages: inout [[String: Any]], turn: ModelTurn,
                                           tool: String, callId: String, result: String) {
        messages.append([
            "role": "assistant",
            "tool_calls": [[
                "id": callId,
                "type": "function",
                "function": ["name": tool, "arguments": turn.toolArgsRaw],
            ]],
        ])
        messages.append(["role": "tool", "tool_call_id": callId, "content": result])
    }

    /// Tool arguments are MODEL-GENERATED and may be anything, including
    /// "NaN"/"Infinity" (Codex 2026-08-10 — `Double("NaN").map(Int.init)`
    /// TRAPS, i.e. crashes the app). Non-finite values are rejected here so
    /// no caller can convert them.
    private static func doubleArg(_ value: Any?) -> Double? {
        let parsed: Double?
        if let d = value as? Double { parsed = d }
        else if let i = value as? Int { parsed = Double(i) }
        else if let s = value as? String { parsed = Double(s) }
        else { parsed = nil }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    /// Finite-and-clamped integer conversion — `Int(1e30)` traps too.
    private static func intArg(_ value: Any?) -> Int? {
        guard let d = doubleArg(value) else { return nil }
        return Int(min(max(d, -1_000_000), 1_000_000))
    }
}
