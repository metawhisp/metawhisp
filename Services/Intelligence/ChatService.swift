import Foundation
import SwiftData

/// Chat with RAG over user's memories + recent transcripts + tasks.
/// System prompt adapted `_get_qa_rag_prompt` (`backend/utils/llm/chat.py:303`).
/// MVP: no streaming, no files, no voice — just text in / text out.
/// spec://BACKLOG#B2
@MainActor
final class ChatService: ObservableObject {
    @Published var isSending = false
    @Published var lastError: String?

    /// Where the user's message came from. Drives TTS on the AI reply.
    enum Source {
        case typed
        case voice
    }

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?
    /// Optional. When set, AI replies are spoken aloud per settings toggles.
    /// spec://BACKLOG#Phase6
    weak var ttsService: TTSService?
    /// Optional. When set, chat queries include recent ScreenContext OCR from the last 24h
    /// so the LLM can answer "what was I reading about X?" style questions.
    /// spec://iterations/ITER-003-screen-aware-intelligence#scope.1
    weak var screenContext: ScreenContextService?
    /// Used to enumerate active project clusters in the `<active_projects>` prompt block.
    /// spec://iterations/ITER-014-project-clustering
    weak var projectAggregator: ProjectAggregator?
    /// ITER-016 — executor for mutation tool calls extracted from LLM output.
    weak var toolExecutor: ChatToolExecutor?

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Send a user message, call LLM, persist both messages.
    /// `source` determines whether the AI reply is spoken aloud (respecting settings).
    func send(_ userText: String, source: Source = .typed) async {
        guard !isSending else { return }
        guard hasLLMAccess else {
            lastError = "Нет доступа к LLM (нужен Pro или API key)"
            return
        }
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true
        lastError = nil
        defer { isSending = false }

        // Persist user message first — UI queries will pick it up immediately.
        let userMsg = ChatMessage(sender: "human", text: trimmed)
        if let container = modelContainer {
            let ctx = ModelContext(container)
            ctx.insert(userMsg)
            try? ctx.save()
        }

        // Build context + RAG prompt.
        // Semantic retrieval (ITER-008): embed the user's question once and rank
        // memories + tasks by cosine similarity. Legacy rows without embeddings
        // fall back to recency-based retrieval.
        let queryVector = await embedQueryIfPossible(trimmed)
        let history = fetchChatHistory(limit: 20)
        let memories = fetchMemoriesForQuery(queryVector: queryVector, limit: 20)
        // Dictations and meetings live in separate blocks now — meetings are long
        // and structured (have a title + overview), dictations are short fragments.
        let recentTranscripts = fetchRecentDictations(limit: 6)
        // Cap meetings tighter — 3 × 1500 chars = 4500 leaves room for the question
        // sandwich and other context. The full transcript is still in the DB; the
        // LLM gets enough to summarize / quote the gist.
        let recentMeetings = fetchMeetingsForQuery(queryVector: queryVector, limit: 3, charsPerMeeting: 1500)
        let pendingTasks = fetchPendingTasksForQuery(queryVector: queryVector, limit: 15)
        let activeGoals = fetchActiveGoals()
        // ITER-014 — top project clusters give the LLM a "world map" so questions
        // like "что у меня с Overchat?" route to the right summary instantly.
        let activeProjects = projectAggregator?.listProjects().prefix(8).map { $0 } ?? []
        let screenSnippets = fetchScreenContextLast24h(limit: 15, maxCharsPerSnippet: 160)
        let relevantFiles = fetchRelevantFiles(query: trimmed, limit: 3, previewChars: 400)
        let responseLanguage = Self.detectLanguage(for: trimmed)

        // Diagnostic — figure out why the LLM sometimes deflects ("ask a clearer
        // question"): log what context it actually got. ITER-013: tasks now split.
        NSLog("[ChatService] Q=%@ ctx: mem=%d chars · tx=%d · mtg=%d · my=%d wait=%d · goals=%d · screen=%d · files=%d",
              String(trimmed.prefix(80)),
              memories.count, recentTranscripts.count, recentMeetings.count,
              pendingTasks.myTasks.count, pendingTasks.waitingOn.count,
              activeGoals.count, screenSnippets.count, relevantFiles.count)

        let userPrompt = buildUserPrompt(
            question: trimmed,
            responseLanguage: responseLanguage,
            memories: memories,
            transcripts: recentTranscripts,
            meetings: recentMeetings,
            tasks: pendingTasks,
            goals: activeGoals,
            projects: activeProjects,
            screenSnippets: screenSnippets,
            relevantFiles: relevantFiles,
            history: history
        )

        do {
            // ITER-017 — Two paths to extract a tool call:
            // (Pro)     /api/pro/chat-with-tools — native function-calling,
            //           returns a structured `tool_calls` array. Reliable.
            // (Non-Pro) /api/pro/advice OR direct LLM SDK with `<tool_call>` regex
            //           in text. Fragile but works without backend changes.
            // The downstream behaviour (validate → pending bubble → confirm → execute)
            // is identical between paths.
            var aiText = ""
            var pendingJSON: String? = nil
            var pendingPreview: String? = nil
            var nativeToolCall: ChatToolExecutor.ToolCall? = nil

            if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                NSLog("[ChatService] Sending via Pro proxy (native tool-use)")
                // ITER-017 v3 — bounded agentic loop. Read-only tools auto-execute
                // and feed result back; mutation tools save as pending and exit.
                let outcome = try await runAgenticLoop(
                    userPrompt: userPrompt,
                    licenseKey: licenseKey,
                    maxRounds: 5
                )
                aiText = outcome.text
                nativeToolCall = outcome.pendingMutation
                NSLog("[ChatService] loop done rounds=%d text=%d pending=%@",
                      outcome.roundsUsed, aiText.count, nativeToolCall?.tool ?? "—")
            } else {
                // Non-Pro: stay on the v1+v2 `<tool_call>` regex path with direct LLM SDK.
                let apiKey = settings.activeAPIKey
                guard !apiKey.isEmpty else {
                    lastError = "No API key"
                    return
                }
                let provider = LLMProvider(rawValue: settings.llmProvider) ?? .openai
                let response = try await llm.complete(
                    system: Self.systemPrompt,
                    user: userPrompt,
                    apiKey: apiKey,
                    provider: provider
                )
                let rawText = response.trimmingCharacters(in: .whitespacesAndNewlines)
                aiText = rawText

                // ITER-016 v1 — text-extracted tool_call (regex).
                if let executor = toolExecutor,
                   let call = ChatToolExecutor.parseToolCall(from: rawText) {
                    aiText = rawText.replacingOccurrences(
                        of: #"<tool_call>[\s\S]*?</tool_call>"#,
                        with: "",
                        options: .regularExpression
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    nativeToolCall = call
                }
            }

            // Single validate/queue path for both transports — keeps confirm UI consistent.
            if let executor = toolExecutor, let call = nativeToolCall {
                switch executor.validate(call) {
                case .success(let preview):
                    pendingJSON = encodeToolCall(call)
                    pendingPreview = preview
                    NSLog("[ChatService] 🔧 Tool call queued: %@ → %@", call.tool, preview)
                case .failure(let err):
                    NSLog("[ChatService] ⚠️ Tool call invalid (%@): %@", call.tool, err.localizedDescription)
                    if aiText.isEmpty {
                        aiText = "I tried to do that but: \(err.localizedDescription)"
                    } else {
                        aiText += "\n(I tried an action but: \(err.localizedDescription))"
                    }
                }
            }

            let aiMsg = ChatMessage(
                sender: "ai",
                text: aiText,
                pendingToolCallJSON: pendingJSON,
                pendingToolPreview: pendingPreview
            )
            // ITER-017 v2 — persist native call id + the userPrompt that produced it.
            // After execute we'll rebuild a 4-message conversation
            // [user → assistant_with_tool_call → tool_result → assistant_followup] so the
            // LLM can compose a natural-language reaction to the action it took.
            if let call = nativeToolCall, pendingJSON != nil {
                aiMsg.toolCallIdNative = call.id
                aiMsg.originatingUserPrompt = userPrompt
            }
            if let container = modelContainer {
                let ctx = ModelContext(container)
                ctx.insert(aiMsg)
                try? ctx.save()
            }
            NSLog("[ChatService] ✅ Got response (%d chars, pendingTool=%@, nativeId=%@)",
                  aiText.count, pendingPreview ?? "—", aiMsg.toolCallIdNative ?? "—")

            // For voice-source replies, surface the answer in the floating voice window.
            if source == .voice {
                VoiceQuestionState.shared.answered(aiText)
            }

            // TTS: speak the reply aloud if the relevant toggle is enabled.
            // Skip speaking when a tool is pending — user needs to read the confirm bubble.
            let shouldSpeak = (source == .voice && settings.ttsVoiceQuestions)
                           || (source == .typed && settings.ttsTypedQuestions)
            if shouldSpeak, !aiText.isEmpty, pendingPreview == nil {
                ttsService?.speak(aiText)
            }
        } catch {
            lastError = error.localizedDescription
            NSLog("[ChatService] ❌ Failed: %@", error.localizedDescription)
            let errMsg = ChatMessage(sender: "ai", text: "", errorText: error.localizedDescription)
            if let container = modelContainer {
                let ctx = ModelContext(container)
                ctx.insert(errMsg)
                try? ctx.save()
            }
            if source == .voice {
                VoiceQuestionState.shared.failed(error.localizedDescription)
            }
        }
    }

    /// Clear all chat history (soft — actually deletes).
    func clearHistory() {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        try? ctx.delete(model: ChatMessage.self)
        try? ctx.save()
    }

    // MARK: - System prompt

    /// Adaptations:
    /// - Removed plugin/app personality injection (single assistant).
    /// - Removed citation blocks (no vector search, no ranked retrieval).
    /// - Removed reports template (out of MVP scope).
    /// - Kept core <task>, <instructions>, <memories>, <user_facts>, <previous_messages>, <question_timezone>.
    static let systemPrompt = """
    <assistant_role>
    You are a READ-ONLY assistant for question-answering about the user's own activity,
    memories, tasks, goals, and notes. You can ANSWER QUESTIONS about anything in the
    context blocks. You CANNOT change anything — see <capabilities> below.
    </assistant_role>

    <capabilities>
    YOU CAN:
    - Answer questions using the context blocks below.
    - Quote, summarize, list, compare items from those blocks.
    - Resolve short follow-up messages against <previous_messages> (see ELLIPSIS rule).
    - CALL TOOLS to mutate the user's data when they EXPLICITLY ask for an action.
      (dismiss/complete a task, forget a memory, update a goal, add a task/memory.)
      The user must CONFIRM each tool call in the UI before it runs.

    YOU STILL CANNOT:
    - Send messages, emails, DMs, or post anywhere outside this app.
    - Browse the web, fetch URLs, get live weather / news / stock prices.
    - Open apps, run scripts, control the computer.
    - Call multiple tools in one turn (one tool per assistant message).
    - Delete things the user didn't explicitly ask to delete.

    When the user asks for an action you CANNOT do (web, send messages, etc.):
    - Explain in ONE sentence why + what they can do themselves.
    - DO NOT pretend you did it. Claiming an action you didn't take is a SEVERE failure.
    </capabilities>

    <available_tools>
    Emit EXACTLY this format when — and ONLY when — the user explicitly asks for an
    action. Put it at the END of your reply (after a plain-text one-line preamble
    explaining what you're about to do). The system strips the block from the
    displayed text, shows the user a confirm dialog, and runs the tool only on YES.

    Format:
    <tool_call>{"tool": "<name>", "args": {...}}</tool_call>

    Tool schemas:

    dismissTask        {"id": "<uuid from <my_tasks>/<waiting_on>>"}
        → soft-delete the task. Use when user says "убери задачу X", "delete task X",
          "dismiss X", "забудь про X".

    completeTask       {"id": "<uuid>"}
        → mark task done. Use when user says "пометь готово", "mark X done",
          "сделал X / I did X".

    dismissMemory      {"id": "<uuid from <user_facts>>"}
        → remove a stored fact. Use when user says "забудь что Y", "forget that Y".

    updateGoalProgress {"id": "<uuid from <active_goals>>", "delta": <int>}
        → boolean goals: +1 = mark done today, -1 = unmark.
        → scale goals (1-10): delta clamps to [1,10].
        → numeric goals: delta is the counter change (+5 = push-ups done, -1 = undo).

    addTask            {"description": "<≤15 words>", "dueAt": "<ISO8601Z>"|null, "assignee": "<name>"|null}
        → creates a new task. `assignee` non-null = waiting-on that person.

    addMemory          {"content": "<fact>", "category": "system"|"interesting"}
        → stores a durable fact about the user. "system" = about the user themselves;
          "interesting" = wisdom/quote worth remembering.

    READ-ONLY tools (auto-execute, no user confirm needed — the system runs them
    immediately and returns results back to you so you can chain into a mutation):

    searchTasks        {"query": "<text>", "limit"?: <int>}
        → returns matching tasks as JSON {items: [{id, description, assignee?, dueAt?}]}.
          USE THIS when user asks to mutate a task and the id isn't already in your
          context blocks. Example: user says "убери задачу про Майка" but no Mike
          task in <my_tasks>/<waiting_on> → call searchTasks(query: "Майк"), then
          call dismissTask with the id you find.

    searchMemories     {"query": "<text>", "limit"?: <int>}
        → returns {items: [{id, content, headline?}]}. Use before dismissMemory
          if id isn't in <user_facts>.

    searchConversations {"query": "<text>", "limit"?: <int>}
        → returns {items: [{id, title, overview, startedAt, project?}]}. Use when
          user references a past meeting without quoting its title verbatim.

    TOOL-USE RULES (strict):
    1. MUTATION tool_call ONLY on an explicit action verb from the user. Plain
       questions ("what are my tasks?") → NEVER a mutation tool.
    2. SEARCH tool_call is encouraged whenever you need an id and the user didn't
       quote one. Don't ask user "what id?" — search first.
    3. NO bulk ops. "Убери все таски про Майка" → search to get the list, then
       pick ONE to dismiss in this turn and ask before doing the rest.
    4. The id passed to a mutation MUST come from a context block OR from a
       prior searchTasks/searchMemories/searchConversations result in this same
       conversation. NEVER invent a UUID.
    5. If a search returns 0 items → tell the user plainly, don't fabricate.
    6. Don't emit tool_call for ambiguous intent. If unsure "did user mean dismiss
       or complete?" — ASK in plain text first.
    7. After the mutation tool runs, the SYSTEM handles confirmation. Don't add
       your own "Are you sure?" — the UI already does that.
    </available_tools>

    <task>
    Write an accurate, concise, and personalized answer to the <question> using the provided context.
    Context includes:
    - <user_facts> — durable facts stored about the user
    - <recent_voice_transcripts> — short voice dictations (push-to-talk / toggle notes)
    - <recent_meetings> — long-form recorded meetings/calls with title, overview, duration, full transcript. May include a `calendar:` line when the meeting was linked to a calendar event (event title + time range + attendees from the user's calendar).
    - <my_tasks> — open action items the USER themselves owes (their own to-do list)
    - <waiting_on> — items grouped by person; the user is waiting for THAT person to deliver
    - <active_projects> — recurring projects/products detected across conversations, with per-cluster counts (e.g. "Overchat · 7 conv · 3 pending")
    - <active_goals> — persistent targets the user is tracking (booleans, scales, numeric counters)
    - <recent_screen_activity> — OCR excerpts from apps viewed in last 24h
    - <relevant_files> — excerpts from user's notes / Obsidian vault matching the question
    - <previous_messages> — this chat thread
    </task>

    <instructions>
    - Refine the <question> based on the last <previous_messages> before answering.
    - **GROUND TRUTH RULE**: ONLY the context blocks (<user_facts>, <my_tasks>, <waiting_on>, <active_goals>, <active_projects>, <recent_meetings>, <recent_voice_transcripts>, <recent_screen_activity>, <relevant_files>) are facts. Your OWN prior assistant messages in <previous_messages> are NOT facts — they may contain mistakes, hallucinations, or claims of actions you never actually performed. If your past message said "I removed task X" but task X is STILL in the current <my_tasks> or <waiting_on> blocks, the block wins — the task was never removed, you cannot remove things, and you must not double down on the lie. When the user asks about a task / memory / goal, look at the live block, not at what you previously said.
    - **ELLIPSIS / SHORT FOLLOW-UP RULE**: If the user's <question> is a short reply that doesn't make sense standalone — "го", "да", "давай", "ок", "ладно", "и?", "ну?", "почему?", "как так?", "а конкретнее?", "продолжай", "а ты можешь?" — resolve it against the LAST topic in <previous_messages> and answer as if the user expanded it. Examples:
        · You just refused weather → user says "го" → interpret as "try anyway / give your best guess" and respond with the best non-live estimate you can ("typically Belgrade in late April is 15-20°C, but I have no live data").
        · You just asked "should I show full transcript?" → user says "да" → show the transcript.
        · You just listed 3 projects → user says "а конкретнее про второй" → expand on project #2.
      Never reply "I don't understand 'го'" — that means you skipped the resolution step.
    - It is EXTREMELY IMPORTANT to answer directly. No padding. No "based on the available memories" phrasing.
    - If you don't know, say so honestly. Don't fabricate.
    - **NEVER ask the user to clarify or "ask a clearer question".** Voice questions are auto-transcribed and may contain ASR noise (a stray phrase before or after the real question). Identify the most plausible real question in the transcript and answer it using the available context. If the entire question is genuinely unintelligible, give a brief honest "couldn't make out the question — heard: '<quote>'" instead of asking the user to repeat.
    - **MEETINGS / CALLS / СОЗВОН**: when the user asks about a call, meeting, созвон, or asks to "transcribe / summarize / кратко о последнем созвоне / транскрибируй", consult <recent_meetings>. For "transcribe"-type requests, reproduce the transcript text from the relevant meeting (the newest one if unspecified). For "summarize"-type requests, give a structured summary using the overview + transcript. Meetings are the ONLY source for calls/созвоны — do NOT confuse them with dictations or tasks. **Calendar lookup**: when the user references a meeting by its CALENDAR EVENT NAME ("о чём говорили на standup в среду", "что обсуждали на 1-on-1 с Vlad?"), match against the `calendar:` line of each meeting — that's the actual event title from the user's calendar (with attendees). When a meeting has both a `calendar:` line AND a structured title, prefer citing the calendar name (the user knows their calendar event names better).
    - **PROJECTS / ПРОЕКТЫ / РАБОТА**: when asked about projects, work, what user does, "что я делаю в жизни / какие у меня проекты / что у меня с X" — START from <active_projects> (that block is the aggregated truth across all conversations). Quote the canonical name, counts, and last-activity verbatim. Use <user_facts> and <recent_meetings> overviews to add one-line context per project. When the user asks about a SPECIFIC project ("что у меня с Overchat"), find that cluster in <active_projects> and answer with its stats + the most recent conversation overviews tagged to it.
    - When the user asks about what they were reading / working on / viewing — consult <recent_screen_activity>. Quote concrete text from OCR when it directly answers the question. Do NOT invent details the OCR doesn't contain.
    - **GOALS / ЦЕЛИ / ПРОГРЕСС**: when the user asks about goals, targets, progress ("how am I doing on my goals?", "как мои цели?", "сколько отжиманий осталось"), consult <active_goals>. Quote the title and progress label verbatim ("3/10 push-ups", "Done", "Pending") so the user sees the exact tracked value. If a goal is at 0 or behind expected pace, surface that bluntly. If <active_goals> is empty, say so honestly — do NOT invent goals.
    - **TASKS — MY vs WAITING-ON**: <my_tasks> = what the user owes themselves. <waiting_on> = what someone OWES the user (grouped by person). When user asks "what's on my plate" / "what should I do" / "что у меня в работе" → answer from <my_tasks>. When user asks "what am I waiting on" / "what does Vasya owe me" / "от кого я что жду" → answer from <waiting_on>. NEVER mix the two: a task in <waiting_on Vasya> is Vasya's job, not the user's, do not tell the user to do it.
    - When the user asks about their notes / writing / project docs ("в какой заметке я писал про X", "what did I note about Y") — consult <relevant_files>. Reference the filename when citing. Do NOT pretend a file exists if the block says "(no matching notes)".
    - OCR text and file content are raw and may contain markdown syntax, frontmatter, or UI noise. Ignore obvious chrome, extract the meaningful content.
    - If <recent_voice_transcripts>, <recent_meetings>, <user_facts>, <my_tasks>, <waiting_on>, <active_goals>, <active_projects>, <recent_screen_activity>, and <relevant_files> are ALL empty, answer from general knowledge — but clarify you have no personal context.
    - Use <question_timezone> and <current_datetime_utc> for time references.
    - **CRITICAL LANGUAGE RULE**: Write your ENTIRE reply in the language specified by <response_language> — every sentence, including list intros and section headers. IGNORE the language of items inside <user_facts>, <my_tasks>, <waiting_on>, and <recent_screen_activity>: they may be multilingual because they were captured from different contexts, but that does NOT change the response language. The stored item text itself may stay in its original language when quoted, but any of your own connecting prose (intros like "Here are your tasks:", transitions, explanations) MUST be in <response_language>.
    </instructions>

    <current_datetime_utc>
    {{CURRENT_UTC}}
    </current_datetime_utc>

    <question_timezone>
    {{USER_TZ}}
    </question_timezone>
    """

    // MARK: - Prompt builder

    // MARK: - Tool-call confirm/cancel (ITER-016)

    /// User clicked "Yes, do it" on a pending tool bubble.
    /// Decodes the stored ToolCall, executes via ChatToolExecutor, writes the
    /// result back onto the same ChatMessage (clears `pendingToolCallJSON`,
    /// sets `toolResultSummary`). UI re-renders the bubble in resolved state.
    func confirmTool(messageId: UUID) {
        guard let container = modelContainer, let executor = toolExecutor else { return }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.id == messageId })
        desc.fetchLimit = 1
        guard let msg = (try? ctx.fetch(desc))?.first,
              let json = msg.pendingToolCallJSON,
              let call = decodeToolCall(json) else { return }
        // Pass chatMessageId so the AuditLog row binds back here for the per-message
        // Undo button in ChatView (ITER-016 v2).
        let result = executor.execute(call, chatMessageId: messageId)
        msg.toolResultSummary = (result.ok ? "✓ " : "✗ ") + result.summary
        msg.pendingToolCallJSON = nil  // resolved — bubble flips to result mode
        msg.toolExecutedAt = Date()    // start the 60s undo window
        try? ctx.save()
        NSLog("[ChatService] 🔧 Tool executed: %@ → %@ (audit=%@)",
              call.tool, result.summary,
              result.auditId?.uuidString.prefix(8) as CVarArg? ?? "—")

        // ITER-017 v2 — multi-step continuation. If we have a native tool_call_id
        // AND the originating user prompt, replay [user → assistant(tool_call) → tool_result]
        // through the LLM so it can compose a natural-language followup.
        // Skipped for: legacy regex calls (no native id), failed mutations, missing prompt.
        if call.id != nil && msg.originatingUserPrompt != nil && result.ok {
            Task { @MainActor [weak self] in
                await self?.continueAfterToolExecution(
                    parentMessageId: messageId,
                    toolCall: call,
                    toolResult: result
                )
            }
        }
    }

    /// ITER-017 v2 — Round-2 inference: feed `tool_result` back to the LLM as a
    /// short conversation chain so it can produce a friendly followup like
    /// "Готово, убрал 'Reply to Mike' из задач. Что-то ещё?".
    ///
    /// Conversation shape sent:
    ///   [user        → original userPrompt]
    ///   [assistant   → empty content + tool_calls=[{id, name, args}]]
    ///   [tool        → tool_call_id, content = result.summary]
    ///
    /// We do NOT loop further in v1 — a second tool_call from this round becomes
    /// a NEW pending bubble that the user confirms again, but the chain stops there.
    /// True multi-step (search → mutate without explicit second confirm) is v3.
    private func continueAfterToolExecution(parentMessageId: UUID,
                                             toolCall: ChatToolExecutor.ToolCall,
                                             toolResult: ChatToolExecutor.ExecResult) async {
        guard LicenseService.shared.isPro,
              let licenseKey = LicenseService.shared.licenseKey,
              let container = modelContainer else { return }
        let ctx = ModelContext(container)

        // Re-fetch parent to read its persisted prompt + native id.
        var pdesc = FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.id == parentMessageId })
        pdesc.fetchLimit = 1
        guard let parent = (try? ctx.fetch(pdesc))?.first,
              let userPrompt = parent.originatingUserPrompt,
              let toolCallId = parent.toolCallIdNative ?? toolCall.id else {
            NSLog("[ChatService] continueAfterToolExecution: missing chain context — skip")
            return
        }

        // Build the 3-message conversation. Same systemPrompt as the original turn.
        let argsJSONStr: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: toolCall.args) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        }()
        let messages: [[String: Any]] = [
            ["role": "user", "content": userPrompt],
            [
                "role": "assistant",
                "content": "",
                "tool_calls": [[
                    "id": toolCallId,
                    "type": "function",
                    "function": [
                        "name": toolCall.tool,
                        "arguments": argsJSONStr,
                    ],
                ]],
            ],
            [
                "role": "tool",
                "tool_call_id": toolCallId,
                "content": toolResult.summary,
            ],
        ]

        do {
            let response = try await callProChatWithTools(
                system: Self.systemPrompt,
                messages: messages,
                tools: ChatToolExecutor.toolSchemas,
                licenseKey: licenseKey
            )

            let followupText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // If LLM emitted ANOTHER tool_call instead of text, we capture it as a new
            // pending bubble — but we don't auto-execute (user must confirm each mutation).
            var pendingJSON: String? = nil
            var pendingPreview: String? = nil
            if let executor = toolExecutor, let nextCall = response.toolCall {
                switch executor.validate(nextCall) {
                case .success(let preview):
                    pendingJSON = encodeToolCall(nextCall)
                    pendingPreview = preview
                case .failure:
                    break  // ignore malformed second call
                }
            }

            // Don't insert an empty followup with no tool_call (LLM had nothing to add).
            guard !followupText.isEmpty || pendingJSON != nil else {
                NSLog("[ChatService] 🔁 followup: LLM had nothing to add — skipping insert")
                return
            }

            let followup = ChatMessage(
                sender: "ai",
                text: followupText,
                pendingToolCallJSON: pendingJSON,
                pendingToolPreview: pendingPreview
            )
            followup.followupOfMessageId = parentMessageId
            if let nextCall = response.toolCall, pendingJSON != nil {
                followup.toolCallIdNative = nextCall.id
                followup.originatingUserPrompt = userPrompt  // chain shares the original prompt
            }
            ctx.insert(followup)
            try? ctx.save()
            NSLog("[ChatService] 🔁 followup inserted (text=%d chars, anotherTool=%@)",
                  followupText.count, pendingPreview ?? "—")
        } catch {
            NSLog("[ChatService] ❌ continueAfterToolExecution failed: %@",
                  error.localizedDescription)
        }
    }

    /// ITER-016 v2 — Revert the most recent tool execution tied to this chat message.
    /// Called by the chat-bubble Undo button. Updates the bubble's `toolResultSummary`
    /// to reflect the revert outcome.
    func undoTool(messageId: UUID) {
        guard let container = modelContainer, let executor = toolExecutor else { return }
        guard let entry = executor.auditEntry(forChatMessage: messageId) else { return }
        let undoMsg = executor.undo(auditId: entry.id)
        // Refresh the chat message so UI re-renders with the updated outcome line.
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.id == messageId })
        desc.fetchLimit = 1
        if let msg = (try? ctx.fetch(desc))?.first {
            msg.toolResultSummary = "↩︎ \(undoMsg)"
            try? ctx.save()
        }
        NSLog("[ChatService] ↩︎ Undo: %@", undoMsg)
    }

    /// User cancelled the pending tool. Marks the message as resolved with
    /// "Cancelled" and clears the pending state so the UI flips out of confirm mode.
    func cancelTool(messageId: UUID) {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.id == messageId })
        desc.fetchLimit = 1
        guard let msg = (try? ctx.fetch(desc))?.first else { return }
        msg.toolResultSummary = "✗ Cancelled"
        msg.pendingToolCallJSON = nil
        msg.toolExecutedAt = Date()  // cancellation is also a "resolution" — undo not relevant
        try? ctx.save()
    }

    private func encodeToolCall(_ call: ChatToolExecutor.ToolCall) -> String? {
        var dict: [String: Any] = ["tool": call.tool, "args": call.args]
        // ITER-017 v2 — preserve native id so multi-step continuation can correlate
        // it back as the matching tool_call_id in the round-2 messages array.
        if let nativeId = call.id { dict["id"] = nativeId }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeToolCall(_ json: String) -> ChatToolExecutor.ToolCall? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = obj["tool"] as? String else { return nil }
        var args: [String: String] = [:]
        if let a = obj["args"] as? [String: Any] {
            for (k, v) in a {
                if let s = v as? String { args[k] = s }
                else if let n = v as? NSNumber { args[k] = n.stringValue }
            }
        }
        // ITER-017 v2 — preserve native id roundtrip if present (decoded from
        // pendingToolCallJSON which we wrote at LLM-response time).
        let nativeId = obj["id"] as? String
        return ChatToolExecutor.ToolCall(id: nativeId, tool: tool, args: args)
    }

    /// ITER-013 — `tasks` is a `PendingTaskBundle`: `myTasks` and `waitingOn`
    /// render into separate prompt blocks so the LLM can answer
    /// "what's on my plate" vs "what am I waiting on" without conflating ownership.
    private func buildUserPrompt(
        question: String,
        responseLanguage: String,
        memories: String,
        transcripts: [String],
        meetings: [MeetingSnippet],
        tasks: PendingTaskBundle,
        goals: [GoalSnippet],
        projects: [ProjectSummary],
        screenSnippets: [ScreenSnippet],
        relevantFiles: [FileSnippet],
        history: [ChatMessage]
    ) -> String {
        // QUESTION SANDWICH — prepend AND append the question so it's anchored at
        // both ends of the prompt. Previously the question was only at the end,
        // and `prefix(24000)` was lopping it off when context was big — model
        // hallucinated answers to a question it never received.
        var parts: [String] = []

        parts.append("<response_language>\(responseLanguage)</response_language>")
        parts.append("")
        parts.append("<question>")
        parts.append(question)
        parts.append("</question>")
        parts.append("")
        parts.append("--- CONTEXT BELOW ---")

        parts.append("")
        parts.append("<user_facts>")
        parts.append(memories.isEmpty ? "(none stored)" : memories)
        parts.append("</user_facts>")

        // ITER-013 — Tasks split by ownership into two blocks.
        // <my_tasks>: what the USER owes themselves.
        // <waiting_on>: what someone else owes the user, grouped per person.
        parts.append("")
        parts.append("<my_tasks>")
        if tasks.myTasks.isEmpty {
            parts.append("(none)")
        } else {
            for t in tasks.myTasks { parts.append("- \(t)") }
        }
        parts.append("</my_tasks>")

        parts.append("")
        parts.append("<waiting_on>")
        if tasks.waitingOn.isEmpty {
            parts.append("(none)")
        } else {
            for group in tasks.waitingOn {
                parts.append("\(group.name):")
                for t in group.items { parts.append("  - \(t)") }
            }
        }
        parts.append("</waiting_on>")

        // Goals sit right after tasks — both are "user's commitments". Goals
        // are persistent; tasks are one-off.
        parts.append("")
        parts.append("<active_goals>")
        if goals.isEmpty {
            parts.append("(none)")
        } else {
            for g in goals {
                var line = "- [id:\(g.id.uuidString)] [\(g.typeLabel)] \(g.title) — \(g.progressLabel)"
                if !g.description.isEmpty { line += "  (note: \(g.description))" }
                parts.append(line)
            }
        }
        parts.append("</active_goals>")

        // ITER-014 — Active projects: compact cluster listing, gives the LLM a
        // "world map" of user's recurring themes so questions like "что у меня
        // с Overchat?" route to the right source immediately.
        parts.append("")
        parts.append("<active_projects>")
        if projects.isEmpty {
            parts.append("(none)")
        } else {
            let df = RelativeDateTimeFormatter()
            df.unitsStyle = .short
            for p in projects {
                var line = "- \(p.canonicalName) (\(p.conversationCount) conv"
                if p.pendingTaskCount > 0 { line += ", \(p.pendingTaskCount) pending" }
                if p.memoryCount > 0 { line += ", \(p.memoryCount) memories" }
                line += ", last: \(df.localizedString(for: p.lastActivity, relativeTo: Date())))"
                if !p.members.isEmpty {
                    line += " · with: \(p.members.sorted().prefix(4).joined(separator: ", "))"
                }
                parts.append(line)
            }
        }
        parts.append("</active_projects>")

        parts.append("")
        parts.append("<recent_voice_transcripts>")
        if transcripts.isEmpty {
            parts.append("(none)")
        } else {
            for (i, t) in transcripts.enumerated() {
                parts.append("[\(i + 1)] \(t)")
            }
        }
        parts.append("</recent_voice_transcripts>")

        parts.append("")
        parts.append("<recent_meetings>")
        if meetings.isEmpty {
            parts.append("(none)")
        } else {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            let timeDF = DateFormatter()
            timeDF.dateFormat = "HH:mm"
            for (i, m) in meetings.enumerated() {
                let durMin = Int(m.durationSeconds / 60)
                parts.append("[meeting \(i + 1)] \(df.string(from: m.date)) · \(durMin)m · \(m.title)")
                // ITER-018 — when conversation was linked to a calendar event,
                // surface the event title + time range + attendees so the LLM can
                // answer "о чём говорили на standup в среду?" by event name.
                if let calTitle = m.calendarTitle {
                    var calLine = "  calendar: \(calTitle)"
                    if let s = m.calendarStart, let e = m.calendarEnd {
                        calLine += " (\(timeDF.string(from: s))-\(timeDF.string(from: e)))"
                    }
                    if !m.calendarAttendees.isEmpty {
                        let names = m.calendarAttendees.prefix(5).joined(separator: ", ")
                        calLine += " · with: \(names)"
                    }
                    parts.append(calLine)
                }
                if !m.overview.isEmpty {
                    parts.append("  overview: \(m.overview)")
                }
                parts.append("  transcript:")
                parts.append("  \(m.text)")
                parts.append("")
            }
        }
        parts.append("</recent_meetings>")

        parts.append("")
        parts.append("<recent_screen_activity>")
        if screenSnippets.isEmpty {
            parts.append("(none)")
        } else {
            for s in screenSnippets {
                parts.append("[\(s.relativeTime)] \(s.appName) — \(s.windowTitle): \(s.text)")
            }
        }
        parts.append("</recent_screen_activity>")

        parts.append("")
        parts.append("<relevant_files>")
        if relevantFiles.isEmpty {
            parts.append("(no matching notes)")
        } else {
            for f in relevantFiles {
                parts.append("FILE: \(f.filename) (\(f.folderLabel))")
                parts.append(f.preview)
                parts.append("---")
            }
        }
        parts.append("</relevant_files>")

        parts.append("")
        parts.append("<previous_messages>")
        if history.isEmpty {
            parts.append("(new conversation)")
        } else {
            for m in history {
                let who = m.sender == "human" ? "User" : "Assistant"
                parts.append("\(who): \(m.text)")
            }
        }
        parts.append("</previous_messages>")

        // ── END CONTEXT — RE-STATE QUESTION SO MODEL ANSWERS THE RIGHT THING ──
        parts.append("")
        parts.append("--- END OF CONTEXT ---")
        parts.append("")
        parts.append("ANSWER THIS QUESTION using the context above (be direct, no padding, no asking for clarification):")
        parts.append(question)

        // Truncation strategy: if we exceed budget, drop the LARGEST middle blocks
        // (screen + meetings transcript bodies) — never the question or tasks.
        var combined = parts.joined(separator: "\n")
        if combined.count > 24000 {
            // First aggressive trim: drop screen activity entirely.
            combined = combined.replacingOccurrences(
                of: #"<recent_screen_activity>[\s\S]*?</recent_screen_activity>"#,
                with: "<recent_screen_activity>(trimmed for budget)</recent_screen_activity>",
                options: .regularExpression
            )
        }
        if combined.count > 24000 {
            // Still too big: trim relevant_files block.
            combined = combined.replacingOccurrences(
                of: #"<relevant_files>[\s\S]*?</relevant_files>"#,
                with: "<relevant_files>(trimmed for budget)</relevant_files>",
                options: .regularExpression
            )
        }
        // Final hard cap, but cut from MIDDLE not end — preserve question sandwich.
        if combined.count > 24000 {
            let head = String(combined.prefix(2000))
            let tail = String(combined.suffix(20000))
            combined = head + "\n... (middle trimmed) ...\n" + tail
        }
        return combined
    }

    // MARK: - Retrieval

    /// Embed the user's query once so downstream retrieval can rank by similarity.
    /// Returns nil when not Pro / network down / etc. — callers fall back to recency.
    private func embedQueryIfPossible(_ query: String) async -> [Float]? {
        guard LicenseService.shared.isPro, LicenseService.shared.licenseKey != nil else { return nil }
        guard let service = AppDelegate.shared?.embeddingService else { return nil }
        do {
            return try await service.embedOne(query)
        } catch {
            NSLog("[ChatService] Query embed failed (graceful): %@", error.localizedDescription)
            return nil
        }
    }

    /// Memories ordered for relevance. When a query vector is available, top-K is by
    /// cosine similarity. Legacy rows fall back to recency.
    /// Renders each memory with its enrichment metadata (headline + reasoning) when
    /// available — gives the LLM the WHY, not just the fact.
    private func fetchMemoriesForQuery(queryVector: [Float]?, limit: Int) -> String {
        guard let container = modelContainer else { return "" }
        let ctx = ModelContext(container)
        let desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let all = (try? ctx.fetch(desc)) ?? []
        let ordered = rankByRelevance(items: all,
                                      queryVector: queryVector,
                                      embedding: { $0.embedding },
                                      limit: limit)
        return ordered.map { mem -> String in
            // ITER-016 — include UUID so LLM can target this memory via `dismissMemory`.
            var line = "- [id:\(mem.id.uuidString)] \(mem.content)"
            if let h = mem.headline, !h.isEmpty {
                line = "- [id:\(mem.id.uuidString)] [\(h)] \(mem.content)"
            }
            if let r = mem.reasoning, !r.isEmpty {
                line += "  (why: \(r))"
            }
            if let tags = mem.tagsCSV, !tags.isEmpty {
                line += "  #\(tags.replacingOccurrences(of: ",", with: " #"))"
            }
            return line
        }.joined(separator: "\n")
    }

    /// Compact representation of a single screen snapshot for the LLM prompt.
    struct ScreenSnippet {
        let appName: String
        let windowTitle: String
        let text: String
        let relativeTime: String // e.g. "2h ago", "14m ago"
    }

    /// Fetch recent ScreenContext rows from the last 24h, truncated for prompt budget.
    /// Per `ITER-003` spec: cap 30 snippets × 200 chars ≈ 6 KB — fits the 24 KB prompt limit.
    /// Reference: `Chat/ChatPrompts.swift` SQL `SELECT substr(ocrText,1,200) FROM screenshots WHERE timestamp > now-24h`.
    private func fetchScreenContextLast24h(limit: Int, maxCharsPerSnippet: Int) -> [ScreenSnippet] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        let cutoff = Date().addingTimeInterval(-86400) // 24h
        var desc = FetchDescriptor<ScreenContext>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        desc.fetchLimit = limit
        let items = (try? ctx.fetch(desc)) ?? []
        let now = Date()
        return items.compactMap { ctx in
            // Skip near-empty OCR rows — they add noise, no signal.
            let trimmed = ctx.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 20 else { return nil }
            let clipped = trimmed.count > maxCharsPerSnippet
                ? String(trimmed.prefix(maxCharsPerSnippet)) + "…"
                : trimmed
            return ScreenSnippet(
                appName: ctx.appName,
                windowTitle: ctx.windowTitle,
                text: clipped.replacingOccurrences(of: "\n", with: " "),
                relativeTime: Self.relativeTimeString(from: ctx.timestamp, to: now)
            )
        }
    }

    /// Compact representation of a matched file for the LLM prompt.
    struct FileSnippet {
        let filename: String
        let folderLabel: String   // e.g. "~/Documents/Obsidian Vault" (tilde-abbreviated)
        let preview: String       // 400-char window around first match (or file head)
    }

    /// Substring search over `IndexedFile.contentText` + `filename`. Returns top-K matches
    /// with a centered preview (~400 chars) around the first keyword hit in content, so
    /// the LLM sees context, not just a filename.
    ///
    /// Strategy (intentionally simple — embeddings come in Part 2):
    /// 1. Tokenize query into meaningful words (≥3 chars, lowercased, dedup).
    /// 2. Score each file: +10 per token found in filename, +1 per content match.
    /// 3. Return top `limit` files with non-zero score, preview window around 1st content hit.
    ///
    /// Honest limitation: synonyms + multilingual mismatch lose here. "Заметки про Stripe"
    /// won't match a file that mentions only "payment processor". Part 2 = embeddings fix.
    /// spec://iterations/ITER-004-file-rag#scope.4
    private func fetchRelevantFiles(query: String, limit: Int, previewChars: Int) -> [FileSnippet] {
        guard let container = modelContainer else { return [] }
        let tokens = Self.tokenize(query: query)
        guard !tokens.isEmpty else { return [] }

        let ctx = ModelContext(container)
        // Fetch only files that have content stored. Narrows DB read from all IndexedFile rows
        // to only the extractable ones actually backfilled.
        var desc = FetchDescriptor<IndexedFile>(
            predicate: #Predicate<IndexedFile> { $0.contentText != nil },
            sortBy: [SortDescriptor(\.fileModifiedAt, order: .reverse)]
        )
        desc.fetchLimit = 2000  // cap — typical vault ≤ 1000 .md files.
        let candidates = (try? ctx.fetch(desc)) ?? []

        // Score + locate first content hit in one pass.
        struct Hit { let file: IndexedFile; let score: Int; let hitIndex: String.Index? }
        var hits: [Hit] = []
        for file in candidates {
            let lowerFilename = file.filename.lowercased()
            let lowerContent = (file.contentText ?? "").lowercased()

            var score = 0
            var firstContentHit: String.Index? = nil
            for token in tokens {
                if lowerFilename.contains(token) { score += 10 }
                if let r = lowerContent.range(of: token) {
                    score += 1
                    if firstContentHit == nil { firstContentHit = r.lowerBound }
                }
            }
            if score > 0 {
                hits.append(Hit(file: file, score: score, hitIndex: firstContentHit))
            }
        }

        let top = hits.sorted { $0.score > $1.score }.prefix(limit)
        return top.map { hit in
            let content = hit.file.contentText ?? ""
            let preview = Self.previewWindow(in: content, around: hit.hitIndex, chars: previewChars)
            let folderLabel = (hit.file.folder as NSString).abbreviatingWithTildeInPath
            return FileSnippet(filename: hit.file.filename, folderLabel: folderLabel, preview: preview)
        }
    }

    /// Split query into lowercased tokens ≥3 chars, dedup. Drops stopwords implicitly via
    /// length filter — "the"/"и"/"на" fail the threshold. Keeps things cheap; no full NLP.
    private static func tokenize(query: String) -> [String] {
        let lower = query.lowercased()
        // Split on any non-letter/digit character (works across Latin + Cyrillic).
        let raw = lower.components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
        var seen = Set<String>()
        var out: [String] = []
        for t in raw where t.count >= 3 && !seen.contains(t) {
            seen.insert(t)
            out.append(t)
        }
        return out
    }

    /// Extract a ~N-char window around a hit position, ellipsized at both ends.
    /// If no hit index (matched only filename), return file head.
    private static func previewWindow(in text: String, around hit: String.Index?, chars: Int) -> String {
        guard !text.isEmpty else { return "" }
        let half = chars / 2
        let start: String.Index
        let end: String.Index
        if let hit {
            let beforeCount = text.distance(from: text.startIndex, to: hit)
            let startDist = max(0, beforeCount - half)
            start = text.index(text.startIndex, offsetBy: startDist)
            let afterCount = text.distance(from: hit, to: text.endIndex)
            let endDist = min(afterCount, half)
            end = text.index(hit, offsetBy: endDist)
        } else {
            start = text.startIndex
            end = text.index(text.startIndex, offsetBy: min(chars, text.count))
        }
        var snippet = String(text[start..<end])
        // Normalize whitespace so markdown line breaks don't bloat the prompt.
        snippet = snippet.replacingOccurrences(of: "\n", with: " ")
                         .replacingOccurrences(of: "\t", with: " ")
        // Collapse repeated spaces with a regex-free pass.
        while snippet.contains("  ") {
            snippet = snippet.replacingOccurrences(of: "  ", with: " ")
        }
        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        return prefix + snippet.trimmingCharacters(in: .whitespaces) + suffix
    }

    /// Detect response language from the user's question. Stored memories/tasks may be
    /// in a different language (mixed EN/RU corpus) — we anchor on the **current question**
    /// so a Russian-heavy memory base doesn't force Russian replies to English questions.
    /// Simple heuristic: any Cyrillic char → Russian, else English. Good enough for our users.
    /// To extend: swap for NLLanguageRecognizer from NaturalLanguage framework.
    static func detectLanguage(for text: String) -> String {
        let isCyrillic = text.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        return isCyrillic ? "Russian" : "English"
    }

    /// "2h 14m ago", "14m ago", "just now" — used only inside prompt so LLM can weigh recency.
    private static func relativeTimeString(from: Date, to: Date) -> String {
        let secs = Int(to.timeIntervalSince(from))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        return m > 0 ? "\(h)h \(m)m ago" : "\(h)h ago"
    }

    /// Recent NON-meeting dictations only. Meetings use `fetchRecentMeetings` and
    /// land in their own `<recent_meetings>` block.
    private func fetchRecentDictations(limit: Int) -> [String] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.source != "meeting" },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        let items = (try? ctx.fetch(desc)) ?? []
        return items.map { $0.displayText }
    }

    /// A meeting bundle for the LLM prompt — date + Conversation title/overview +
    /// transcript text (capped per meeting to keep prompt budget under control).
    /// ITER-018: optional calendar event metadata when conversation was linked.
    struct MeetingSnippet {
        let date: Date
        let title: String
        let overview: String
        let durationSeconds: Double
        let text: String
        // Calendar cross-ref (nil when no event match). Snapshotted on Conversation,
        // rendered into <recent_meetings> as a parenthetical so LLM can cite
        // "Standup with Pasha (10:00-10:30)" verbatim.
        let calendarTitle: String?
        let calendarStart: Date?
        let calendarEnd: Date?
        let calendarAttendees: [String]
    }

    /// Top-K meetings ranked by semantic similarity to the query (ITER-011).
    ///
    /// Strategy:
    /// 1. Pull the last 50 meeting HistoryItems (recency-bounded so we don't embed-rank
    ///    the entire archive each time — old enough calls aren't useful context anyway).
    /// 2. If queryVector is available + the linked conversation has an embedding,
    ///    rank by cosine similarity to the query. Take top-K.
    /// 3. ALWAYS force-include the most recent meeting if not already in the top-K.
    ///    This preserves the "transcribe my last call" path — the literal latest call
    ///    must surface even if its content isn't semantically close to the query.
    /// 4. Fall back to pure recency when there's no queryVector or no embeddings exist
    ///    yet (legacy rows pre-backfill, non-Pro users).
    ///
    /// Each returned snippet bundles `Conversation.title`/`overview` + transcript prefix
    /// so the LLM gets both the structured summary AND concrete content (names/projects).
    private func fetchMeetingsForQuery(queryVector: [Float]?, limit: Int, charsPerMeeting: Int) -> [MeetingSnippet] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)

        // Pull a wider candidate window so semantic ranking has something to choose from.
        // 50 is enough for typical month-long usage; older meetings stay in the DB but
        // aren't competitive context anyway.
        let candidateWindow = max(limit * 10, 50)
        var historyDesc = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.source == "meeting" },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        historyDesc.fetchLimit = candidateWindow
        let candidates = (try? ctx.fetch(historyDesc)) ?? []
        guard !candidates.isEmpty else { return [] }

        // Build the conversation lookup once for all candidates.
        let convIds = candidates.compactMap { $0.conversationId }
        var convsById: [UUID: Conversation] = [:]
        if !convIds.isEmpty {
            let convDesc = FetchDescriptor<Conversation>(
                predicate: #Predicate { c in convIds.contains(c.id) }
            )
            for c in (try? ctx.fetch(convDesc)) ?? [] {
                convsById[c.id] = c
            }
        }

        // Rank by relevance when we can; fall back to recency.
        let ranked: [HistoryItem]
        if let q = queryVector {
            // Score each candidate by the similarity of its conversation embedding.
            // Items without an embedding (or without a linked conversation) get -1.
            let scored: [(HistoryItem, Float)] = candidates.map { item in
                let conv = item.conversationId.flatMap { convsById[$0] }
                guard let data = conv?.embedding, !data.isEmpty else {
                    return (item, Float(-1))
                }
                let vec = EmbeddingService.decode(data)
                guard !vec.isEmpty else { return (item, Float(-1)) }
                return (item, EmbeddingService.cosineSimilarity(q, vec))
            }
            // Degenerate case: zero embeddings exist yet (pre-backfill / non-Pro).
            // Don't pretend we ranked — fall back to recency so we don't return
            // an arbitrary subset of unscored items.
            let anyRealScore = scored.contains { $0.1 >= 0 }
            if !anyRealScore {
                ranked = Array(candidates.prefix(limit))
            } else {
                // Top-K by score, then force-include the literal latest meeting.
                // "Transcribe my last call" must keep working even if its content
                // isn't semantically close to the user's question.
                var topByScore = scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
                if let latest = candidates.first, !topByScore.contains(where: { $0.id == latest.id }) {
                    if topByScore.count >= limit { topByScore.removeLast() }
                    topByScore.insert(latest, at: 0)
                }
                ranked = Array(topByScore)
            }
        } else {
            // No query embedding — pure recency (covers non-Pro + transient embed failure).
            ranked = Array(candidates.prefix(limit))
        }

        return ranked.map { item -> MeetingSnippet in
            let conv = item.conversationId.flatMap { convsById[$0] }
            let raw = item.displayText
            let text = raw.count > charsPerMeeting
                ? String(raw.prefix(charsPerMeeting)) + "…"
                : raw
            // ITER-018 — pull calendar snapshot if the conversation was linked.
            let attendees: [String] = {
                guard let json = conv?.calendarAttendeesJSON,
                      let data = json.data(using: .utf8),
                      let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
                return arr
            }()
            return MeetingSnippet(
                date: item.createdAt,
                title: conv?.title ?? "(untitled meeting)",
                overview: conv?.overview ?? "",
                durationSeconds: item.audioDuration,
                text: text,
                calendarTitle: conv?.calendarEventTitle,
                calendarStart: conv?.calendarEventStartDate,
                calendarEnd: conv?.calendarEventEndDate,
                calendarAttendees: attendees
            )
        }
    }

    /// ITER-013 — pending tasks split by ownership for separate prompt blocks.
    /// MyTasks: assignee == nil (user owes themselves).
    /// WaitingOn: grouped by assignee name (someone owes the user).
    struct PendingTaskBundle {
        let myTasks: [String]
        let waitingOn: [(name: String, items: [String])]
        var totalCount: Int {
            myTasks.count + waitingOn.reduce(0) { $0 + $1.items.count }
        }
    }

    private func fetchPendingTasksForQuery(queryVector: [Float]?, limit: Int) -> PendingTaskBundle {
        guard let container = modelContainer else {
            return PendingTaskBundle(myTasks: [], waitingOn: [])
        }
        let ctx = ModelContext(container)
        // Main-list tasks only: not dismissed, not completed, not in the staged bin
        // (staged candidates shouldn't pollute the assistant's answer).
        let desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed && !$0.completed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let all = (try? ctx.fetch(desc)) ?? []
        let committed = all.filter { $0.status != "staged" && $0.status != "dismissed" }
        // Rank ALL committed by relevance to the query, then partition into MY vs
        // waiting-on AFTER ranking — so the top-K both lists draw from is the most
        // relevant slice of the user's whole task surface, not two independent ranks.
        let ordered = rankByRelevance(items: committed,
                                      queryVector: queryVector,
                                      embedding: { $0.embedding },
                                      limit: limit)
        // ITER-016 — prefix each line with the task UUID so LLM can reference it
        // in a `<tool_call>` block (dismissTask / completeTask need `args.id`).
        var my: [String] = []
        var waitingMap: [String: [String]] = [:]
        var waitingOrder: [String] = []
        for t in ordered {
            let line = "[\(t.id.uuidString)] \(t.taskDescription)"
            if t.isMyTask {
                my.append(line)
            } else if let name = t.assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                if waitingMap[name] == nil { waitingOrder.append(name) }
                waitingMap[name, default: []].append(line)
            }
        }
        let waitingOn: [(String, [String])] = waitingOrder.map { ($0, waitingMap[$0] ?? []) }
        return PendingTaskBundle(myTasks: my, waitingOn: waitingOn)
    }

    /// Compact representation of a tracked goal for the LLM prompt.
    /// `progressLabel` is verbatim from `Goal.progressLabel` so the LLM can quote it exactly
    /// ("3/10 push-ups", "Done", "7/10 (min 1)") without re-formatting.
    struct GoalSnippet {
        let id: UUID   // ITER-016 — exposed so LLM can target via updateGoalProgress
        let title: String
        let typeLabel: String      // "daily" | "rating" | "numeric" — short hint for LLM
        let progressLabel: String  // verbatim from Goal.progressLabel
        let description: String
    }

    /// All active (non-archived, non-deleted) goals, with stale daily-resets applied.
    /// We pull every active goal — count is small (≤20 in practice) and the LLM needs
    /// the full picture to answer "what are my goals?" without missing items.
    private func fetchActiveGoals() -> [GoalSnippet] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<Goal>(
            predicate: #Predicate<Goal> { $0.isActive && !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = 50
        let goals = (try? ctx.fetch(desc)) ?? []
        return goals.map { g in
            // Reset daily/scale goals that haven't been touched today before quoting them.
            g.resetIfNewDay()
            let typeLabel: String
            switch g.goalType {
            case "boolean": typeLabel = "daily"
            case "scale":   typeLabel = "rating"
            case "numeric": typeLabel = "numeric"
            default:        typeLabel = g.goalType
            }
            return GoalSnippet(
                id: g.id,
                title: g.title,
                typeLabel: typeLabel,
                progressLabel: g.progressLabel,
                description: g.goalDescription ?? ""
            )
        }
    }

    /// Generic semantic top-K: rank items by cosine similarity to queryVector; legacy
    /// items without an embedding get appended by their input order (already recency-sorted).
    private func rankByRelevance<T>(items: [T],
                                    queryVector: [Float]?,
                                    embedding: (T) -> Data?,
                                    limit: Int) -> [T] {
        guard !items.isEmpty else { return [] }
        guard let query = queryVector else {
            // No query vector → just take the most recent `limit`.
            return Array(items.prefix(limit))
        }
        // Split into (have-embedding) vs (no-embedding).
        var embedded: [(T, Float)] = []
        var legacy: [T] = []
        for item in items {
            if let data = embedding(item) {
                let vec = EmbeddingService.decode(data)
                if !vec.isEmpty {
                    embedded.append((item, EmbeddingService.cosineSimilarity(query, vec)))
                    continue
                }
            }
            legacy.append(item)
        }
        embedded.sort { $0.1 > $1.1 }
        // Take top-K embedded, then pad with recent legacy up to the cap.
        let embRanked = embedded.prefix(limit).map { $0.0 }
        let needFromLegacy = max(0, limit - embRanked.count)
        let legacyTail = legacy.prefix(needFromLegacy)
        return Array(embRanked) + Array(legacyTail)
    }

    /// Last N chat messages (oldest first for prompt readability).
    private func fetchChatHistory(limit: Int) -> [ChatMessage] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        let items = (try? ctx.fetch(desc)) ?? []
        return items.reversed()
    }

    // MARK: - Pro proxy

    private func callProProxy(system: String, user: String, licenseKey: String) async throws -> String {
        // Substitute template tokens in system prompt.
        let utc = ISO8601DateFormatter().string(from: Date())
        let tz = TimeZone.current.identifier
        let resolvedSystem = system
            .replacingOccurrences(of: "{{CURRENT_UTC}}", with: utc)
            .replacingOccurrences(of: "{{USER_TZ}}", with: tz)

        let url = URL(string: "https://api.metawhisp.com/api/pro/advice")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = ["system": resolvedSystem, "user": user]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw ProcessingError.apiError("Chat proxy HTTP \(http.statusCode): \(String(bodyStr.prefix(200)))")
        }
        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    // MARK: - ITER-017 v3 — Agentic loop

    /// Final outcome of the bounded inference loop.
    /// `pendingMutation` non-nil = LLM wants to perform a mutation; UI shows confirm bubble.
    /// Both can be present (LLM said "Я нашёл, сейчас уберу" + tool_call).
    struct AgenticOutcome {
        let text: String
        let pendingMutation: ChatToolExecutor.ToolCall?
        let roundsUsed: Int
    }

    /// Bounded agentic loop. Each iteration:
    /// - sends current `messages` + `tools` to /chat-with-tools
    /// - if LLM returns text only → loop ends, return text
    /// - if LLM returns a READ-ONLY tool_call → auto-execute, append assistant +
    ///   tool messages, loop again
    /// - if LLM returns a MUTATION tool_call → loop ends, return pending for confirm
    /// Hard cap `maxRounds` (default 5) protects against runaway / infinite chains.
    /// On hitting the cap we return whatever text we collected so far + a short note.
    private func runAgenticLoop(userPrompt: String,
                                 licenseKey: String,
                                 maxRounds: Int) async throws -> AgenticOutcome {
        var messages: [[String: Any]] = [["role": "user", "content": userPrompt]]
        var lastText = ""
        var rounds = 0

        while rounds < maxRounds {
            rounds += 1
            let resp = try await callProChatWithTools(
                system: Self.systemPrompt,
                messages: messages,
                tools: ChatToolExecutor.toolSchemas,
                licenseKey: licenseKey
            )
            let txt = resp.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !txt.isEmpty { lastText = txt }

            guard let call = resp.toolCall else {
                // Plain text — end of chain.
                return AgenticOutcome(text: lastText, pendingMutation: nil, roundsUsed: rounds)
            }

            if ChatToolExecutor.isReadOnly(call.tool) {
                // Auto-execute the search, append [assistant_with_tool_call, tool_result],
                // continue loop so the LLM can react to the data.
                guard let executor = toolExecutor else {
                    NSLog("[ChatService] loop: read-only call but no executor — abort")
                    return AgenticOutcome(text: lastText, pendingMutation: nil, roundsUsed: rounds)
                }
                let result = await executor.executeReadOnly(call)
                NSLog("[ChatService] 🔍 auto-exec %@ → ok=%@ (round %d)",
                      call.tool, result.ok ? "yes" : "no", rounds)

                let argsStr: String = {
                    guard let d = try? JSONSerialization.data(withJSONObject: call.args) else { return "{}" }
                    return String(data: d, encoding: .utf8) ?? "{}"
                }()
                let assistantMsg: [String: Any] = [
                    "role": "assistant",
                    "content": txt,
                    "tool_calls": [[
                        "id": call.id ?? "auto_\(rounds)",
                        "type": "function",
                        "function": ["name": call.tool, "arguments": argsStr],
                    ]],
                ]
                let toolMsg: [String: Any] = [
                    "role": "tool",
                    "tool_call_id": call.id ?? "auto_\(rounds)",
                    "content": result.summary,
                ]
                messages.append(assistantMsg)
                messages.append(toolMsg)
                continue
            }

            // Mutation — exit loop, hand off to confirm flow.
            return AgenticOutcome(text: lastText, pendingMutation: call, roundsUsed: rounds)
        }

        // Hit the round cap. Return what we have plus a soft note.
        let suffix = lastText.isEmpty ? "(I worked through several steps but ran out of tool budget.)" :
                     lastText + "\n\n(Cap reached — pause and let me know if you want to continue.)"
        return AgenticOutcome(text: suffix, pendingMutation: nil, roundsUsed: rounds)
    }

    // MARK: - ITER-017 — Native tool-use messages builder

    /// Build OpenAI-format `messages` array for `/api/pro/chat-with-tools`.
    /// v1: single-turn. The full assembled `userPrompt` (including <previous_messages>
    /// and all retrieval blocks) goes as ONE user message — same content as the
    /// legacy /advice path, just wrapped for the messages API shape.
    /// v2 (deferred): true multi-turn — feed tool_result back, let LLM chain calls
    /// (e.g. "search tasks → dismiss the matching one"). That path will append
    /// {role:"tool", tool_call_id:..., content:...} after each execution.
    private func buildNativeMessages(userPrompt: String, history: [ChatMessage]) -> [[String: Any]] {
        return [["role": "user", "content": userPrompt]]
    }

    // MARK: - ITER-017 — Native tool-use proxy

    /// Response from `/api/pro/chat-with-tools`. Mirrors backend shape.
    struct NativeChatResponse {
        let text: String
        let toolCall: ChatToolExecutor.ToolCall?
        /// "stop" | "tool_calls" | "length" | other.
        let finishReason: String
    }

    /// Calls the native tool-use endpoint. Single round-trip — caller decides
    /// what to do next (show text, queue tool for confirm, etc.).
    /// `messages` is the OpenAI-format conversation: `[{role, content?, tool_calls?, tool_call_id?}]`.
    private func callProChatWithTools(system: String,
                                       messages: [[String: Any]],
                                       tools: [[String: Any]],
                                       licenseKey: String) async throws -> NativeChatResponse {
        let utc = ISO8601DateFormatter().string(from: Date())
        let tz = TimeZone.current.identifier
        let resolvedSystem = system
            .replacingOccurrences(of: "{{CURRENT_UTC}}", with: utc)
            .replacingOccurrences(of: "{{USER_TZ}}", with: tz)

        let url = URL(string: "https://api.metawhisp.com/api/pro/chat-with-tools")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "system": resolvedSystem,
            "messages": messages,
            "tools": tools,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw ProcessingError.apiError("Chat-with-tools HTTP \(http.statusCode): \(String(bodyStr.prefix(200)))")
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProcessingError.apiError("Chat-with-tools: malformed response JSON")
        }
        let text = (obj["text"] as? String) ?? ""
        let finishReason = (obj["finish_reason"] as? String) ?? "stop"
        let toolCall = ChatToolExecutor.parseNativeToolCall(from: obj["tool_calls"] as? [[String: Any]])
        return NativeChatResponse(text: text, toolCall: toolCall, finishReason: finishReason)
    }

    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty || LicenseService.shared.isPro
    }
}
