import Foundation
import SwiftData

/// Generates Structured (title/overview/category/emoji) for a closed Conversation.
/// Mirrors `get_transcript_structure` (`backend/utils/llm/conversation_processing.py:588`).
/// Fired by ConversationGrouper.close(). Fire-and-forget async.
/// Adaptations:
/// - Removed speaker/CalendarMeetingContext handling (single-user desktop).
/// - Removed photos parameter (no wearable camera).
/// - Removed Calendar Events extraction (belongs to Phase 7 calendar integration).
/// - Kept: title (Title Case ≤10 words), overview, emoji (specific vivid), category (33 values).
/// spec://BACKLOG#C1.2
@MainActor
final class StructuredGenerator: ObservableObject {
    /// ITER-041 — per-conversation extraction schema is the most complex
    /// in the codebase (title+project+category+decisions+nextSteps+
    /// participants+keyQuotes). 8B-instant failed parse in production
    /// (2026-05-28 17:13 — 2 consecutive parse failures right after the
    /// mini migration). Moved to medium tier; still ~7× cheaper than the
    /// heavy default since this is the highest-volume background caller.
    static let llmTier: LLMTier = .medium
    static let llmServiceId: String = "StructuredGenerator"

    @Published var isRunning = false
    @Published var lastError: String?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?

    /// Set by AppDelegate after both services exist. Used to embed the conversation
    /// once title/overview are populated so semantic MetaChat retrieval can find it
    /// via cosine similarity (not just substring match).
    /// spec://iterations/ITER-011-conversation-embeddings
    weak var embeddingService: EmbeddingService?

    /// Set by AppDelegate. Used to canonicalize the LLM-generated project label
    /// against existing aliases (or insert a new one) right after structured-gen
    /// completes, so the Projects view sees the cluster on first render.
    /// spec://iterations/ITER-014-project-clustering
    weak var projectAggregator: ProjectAggregator?

    /// Set by AppDelegate. After a meeting/dictation closes we ask the calendar
    /// reader to find a matching EKEvent in the time neighborhood and snapshot
    /// its identifier + title + attendees onto the Conversation. Lets MetaChat
    /// answer "о чём говорили на standup в среду?" by event lookup.
    /// spec://iterations/ITER-018-calendar-cross-ref
    weak var calendarReader: CalendarReaderService?

    /// Minimum transcript character count to bother the LLM. Short chats get title="Quick note".
    private let minTranscriptChars = 40

    /// ITER-021 — periodic backfill (catches conversations stuck on "Quick note" /
    /// "(empty)" between app launches). Default 30 min — frequent enough that a
    /// user opening a 2h-old meeting sees the right title, rare enough to not
    /// thrash the proxy. Cancelled in deinit-equivalent via `stopPeriodicBackfill`.
    private var periodicBackfillTask: Task<Void, Never>?
    private let periodicBackfillInterval: TimeInterval = 1800  // 30 min

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// ITER-021 — Encode `[String]` to JSON for the new structured summary fields.
    /// Returns nil for empty/nil input so the UI can distinguish "not extracted"
    /// from "explicitly empty".
    static func encodeStringArray(_ items: [String]?) -> String? {
        guard let items, !items.isEmpty else { return nil }
        let cleaned = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return (try? String(data: JSONEncoder().encode(cleaned), encoding: .utf8))
    }

    /// Helper shared by the main path + retry path.
    /// In-memory filter instead of a SwiftData predicate — `$0.conversationId
    /// == conversationId` (where model is `UUID?` and captured is `UUID`)
    /// sometimes returned 0 rows on commit-race despite the row being saved
    /// moments earlier (2026-05-01 bug: 4359-char transcript in DB, predicate
    /// matched nothing, recap stuck on "Quick note (empty)"). Loading the
    /// recent 200 rows and filtering in Swift is reliable and cheap.
    /// `static` + `internal` so retroactive tests can call it directly.
    static func fetchHistoryItems(conversationId: UUID, in ctx: ModelContext) -> [HistoryItem] {
        // AUD-016 — fetch ALL rows ascending then filter, with NO cap. The former
        // newest-200 GLOBAL cap truncated long conversations and, when unrelated
        // recent rows filled the slice, could drop the target conversation's head
        // (or all of it). We still filter in Swift rather than predicate on the
        // Optional<UUID> — see the commit-race note above.
        let desc = FetchDescriptor<HistoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let candidates = (try? ctx.fetch(desc)) ?? []
        return candidates.filter { $0.conversationId == conversationId }
    }

    /// Backfill — retries generation for conversations stuck on placeholder fields.
    /// ITER-021: extended query — was `title == "Quick note"`, now also catches
    /// `overview == "(empty)"` (these are conversations where transcript existed
    /// but generation failed silently — exactly the bug the user hit on
    /// 2026-04-25 13:33: 3611 chars transcript + Quick note + empty overview).
    /// Run on launch AND periodically (see startPeriodicBackfill).
    func backfillPlaceholders() async {
        guard hasLLMAccess else { return }
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        // Match conversations where StructuredGenerator clearly hadn't run successfully:
        // - title is the "Quick note" placeholder, OR
        // - overview is the "(empty)" placeholder (LLM call failed but title written).
        // ITER-035-followup (2026-05-12) — also require structuredBackfillAttempted != true.
        // Before this guard, the backfill kept retrying the same short-transcript
        // conversations every launch + every 30 min → user reported $16/day Groq
        // spend from a runaway loop. Now each conversation gets at MOST one
        // backfill attempt regardless of outcome.
        //
        // NB: in-memory filter for `structuredBackfillAttempted` rather than
        // SwiftData predicate — `#Predicate` can't type-check optional-Bool
        // boolean compounds reliably, gave a timeout. Fetch broader set,
        // then `.filter` in Swift.
        var desc = FetchDescriptor<Conversation>(
            predicate: #Predicate {
                !$0.discarded
                && ($0.title == "Quick note" || $0.overview == "(empty)")
            }
        )
        desc.fetchLimit = 500  // wider fetch — in-memory filter narrows below
        let allCandidates = (try? ctx.fetch(desc)) ?? []
        let placeholders = Array(
            allCandidates
                .filter { $0.structuredBackfillAttempted != true }
                .prefix(100)
        )
        guard !placeholders.isEmpty else { return }
        NSLog("[StructuredGenerator] Backfilling %d placeholder conversations", placeholders.count)
        for conv in placeholders {
            // Mark attempted BEFORE LLM call so even on failure / cancel we don't
            // retry next pass. Successful generate() runs through with the flag
            // already set — harmless, it's checked only on selection.
            conv.structuredBackfillAttempted = true
            // Only retry if there's actually a real transcript available.
            let items = Self.fetchHistoryItems(conversationId: conv.id, in: ctx)
            let transcript = items.map { $0.displayText }.joined(separator: "\n")
            guard transcript.count >= minTranscriptChars else {
                // Short transcript — flag stays set, persist + skip LLM call.
                NSLog("[StructuredGenerator] backfill: conv %@ skipped — transcript %d chars < %d, marked attempted", conv.id.uuidString.prefix(8) as CVarArg, transcript.count, minTranscriptChars)
                try? ctx.save()
                continue
            }
            // Reset title/overview so generate() re-runs through the LLM path.
            conv.title = nil
            conv.overview = nil
            conv.category = nil
            conv.emoji = nil
            try? ctx.save()
            // Pass the transcript we already have — avoids generate() doing
            // a second DB fetch for the same data. `preferCloud: true` keeps
            // accumulated backfill OFF the local model — large prompts × N
            // conversations would otherwise freeze a freshly-activated Phi-4.
            await generate(conversationId: conv.id, knownTranscript: transcript, preferCloud: true)
        }
    }

    /// ITER-021 — Periodic backfill loop. Catches conversations that close while
    /// the proxy is briefly down: the launch backfill misses them (since they
    /// finish AFTER launch), and without periodic re-check they stay broken
    /// forever. 30-min cadence is rare enough to not load the proxy, frequent
    /// enough that a returning user sees titles update within minutes.
    ///
    /// ITER-035-followup (2026-05-12) — periodic loop disabled. Even with the
    /// `structuredBackfillAttempted` sticky flag added today, this loop fires
    /// the LLM 48 times/day (every 30 min) for any user who closes meetings
    /// between launches. Combined with the prior infinite-retry bug, drove
    /// $16/day Groq spend. Launch backfill alone catches legitimate
    /// transcribe-then-close-fast conversations on next app start, which
    /// covers the original case (user closes laptop after meeting). Cost
    /// now bounded by total conversation count, not by wall-clock time.
    func startPeriodicBackfill() {
        periodicBackfillTask?.cancel()
        NSLog("[StructuredGenerator] periodic backfill disabled (cost-control 2026-05-12); launch backfill remains")
        return
    }

    /// Cancel the periodic backfill (used on teardown / settings toggle off).
    func stopPeriodicBackfill() {
        periodicBackfillTask?.cancel()
        periodicBackfillTask = nil
    }

    /// ITER-021 — Public manual retry for the UI "Regenerate" button.
    /// Forces re-generation regardless of placeholder state. Used when the
    /// user looks at a meeting and the LLM previously chose a bad title /
    /// missed structured sections. Internally clears existing fields then
    /// calls the standard `generate(conversationId:)` path.
    func regenerate(conversationId: UUID) async {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conversationId })
        desc.fetchLimit = 1
        guard let conv = try? ctx.fetch(desc).first else { return }
        // Reset structured fields so generate() takes the full LLM path.
        conv.title = nil
        conv.overview = nil
        conv.category = nil
        conv.emoji = nil
        conv.primaryProject = nil
        conv.topicsJSON = nil
        conv.decisionsJSON = nil
        conv.actionItemsJSON = nil
        conv.participantsJSON = nil
        conv.keyQuotesJSON = nil
        conv.nextStepsJSON = nil
        try? ctx.save()
        await generate(conversationId: conversationId)
    }

    /// Generate title/overview/category/emoji for a conversation by id.
    /// Fire-and-forget — background task, writes result back to the Conversation record.
    ///
    /// `knownTranscript` is the in-memory text from the caller (e.g. fresh
    /// meeting from ConversationGrouper.assign). Passing it bypasses the
    /// cross-ModelContext race that produced "Quick note (empty)" placeholders
    /// when the new context didn't see the just-committed HistoryItem row.
    /// Backfill / manual paths leave it nil and fall back to the DB fetch.
    /// Run structuring for one conversation.
    ///
    /// - Parameter preferCloud: when `true`, bypasses the local-LLM path
    ///   even if `LocalLLMService.isReady`. Used by the launch backfill —
    ///   processing 10-50 accumulated conversations through a freshly
    ///   activated local model right after «Make active» froze user's
    ///   Mac 2026-05-13 (3k-token prefill × N conversations). Backfill
    ///   stays on cloud; only fresh user-initiated dictations route local.
    func generate(conversationId: UUID, knownTranscript: String? = nil, preferCloud: Bool = false) async {
        let t0 = Date()
        guard !isRunning else { return }
        NSLog("[StructuredGenerator] conv %@ dropped — another generation already in flight", conversationId.uuidString.prefix(8) as CVarArg)
        guard hasLLMAccess else {
            NSLog("[StructuredGenerator] No LLM access — skipping")
            return
        }
        guard let container = modelContainer else { return }

        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conversationId })
        descriptor.fetchLimit = 1
        guard let conv = try? ctx.fetch(descriptor).first else {
            NSLog("[StructuredGenerator] Conversation %@ not found", conversationId.uuidString.prefix(8) as CVarArg)
            return
        }

        // Skip if already generated (idempotent) — BUT allow re-generation when
        // the existing title is a placeholder ("Quick note") and a real transcript
        // has since landed. This recovers from the previous race condition where
        // StructuredGenerator fired before the HistoryItem was persisted.
        let isPlaceholder = (conv.title == "Quick note")
        if conv.title != nil && conv.overview != nil && !isPlaceholder {
        NSLog("[StructuredGenerator] conv %@ already structured — skipping", conversationId.uuidString.prefix(8) as CVarArg)
            return
        }

        // Prefer the caller-provided transcript when available — bypasses
        // the cross-ModelContext race that occasionally returns 0 items
        // even when the row IS persisted. Backfill / manual regenerate
        // paths still fall through to the DB fetch.
        var transcript: String
        if let known = knownTranscript, !known.isEmpty {
            transcript = known
            NSLog("[StructuredGenerator] Using caller transcript (%d chars) — no DB fetch", known.count)
        } else {
            // Fetch linked HistoryItems.
            let items = Self.fetchHistoryItems(conversationId: conversationId, in: ctx)
            transcript = items.map { $0.displayText }.joined(separator: "\n")

            // Retry once if transcript is empty — could still be mid-commit for meeting path.
            if transcript.isEmpty {
                try? await Task.sleep(for: .seconds(2))
                let ctx2 = ModelContext(container)
                let retryItems = Self.fetchHistoryItems(conversationId: conversationId, in: ctx2)
                transcript = retryItems.map { $0.displayText }.joined(separator: "\n")
                if !transcript.isEmpty {
                    NSLog("[StructuredGenerator] Transcript appeared on retry (%d chars)", transcript.count)
                }
            }
        }

        // CALENDAR LINK FIRST (2026-05-01 reorder). If this meeting has a
        // matching EKEvent, the recap title comes from the calendar event name
        // — no need for the LLM to invent one. We still run the LLM below for
        // overview / category / emoji (calendar doesn't have those). Doing
        // this BEFORE the LLM call closes the race where recap popup fires
        // (8s after stop) before the old fire-and-forget linker had finished.
        if conv.source == "meeting", let cc = conv.callContext, !cc.isEmpty,
           let calendarReader {
            await calendarReader.linkConversation(conversationId)
            // Pull the updated row into our context so subsequent saves don't
            // stomp the freshly-set calendar fields.
            if let refreshed = try? ctx.fetch(descriptor).first {
                conv.calendarEventId = refreshed.calendarEventId
                conv.calendarEventTitle = refreshed.calendarEventTitle
                conv.calendarEventStartDate = refreshed.calendarEventStartDate
                conv.calendarEventEndDate = refreshed.calendarEventEndDate
                conv.calendarAttendeesJSON = refreshed.calendarAttendeesJSON
            }
        }

        guard transcript.count >= minTranscriptChars else {
            // Too short — give a placeholder so UI has something to show.
            // Calendar event name still wins if linked (preserve user's
            // naming even on a sub-300-char meeting).
            conv.title = ConversationTitleResolver.resolve(
                calendarEventTitle: conv.calendarEventTitle,
                llmTitle: "Quick note"
            )
            conv.overview = transcript.isEmpty ? "(empty)" : String(transcript.prefix(80))
            conv.category = "other"
            conv.emoji = "bubble.left"  // SF Symbol, monochrome
            conv.updatedAt = Date()
            try? ctx.save()
            NSLog("[StructuredGenerator] Short transcript (%d chars) — placeholder title", transcript.count)
            return
        }

        isRunning = true
        defer { isRunning = false }

        let startedAt = conv.startedAt
        let userPrompt = buildPrompt(transcript: transcript, startedAt: startedAt)
        NSLog("[StructuredGenerator] ▶︎ conv %@ — transcript %d chars, prompt %d chars, engine=%@, preferCloud=%d", conversationId.uuidString.prefix(8) as CVarArg, transcript.count, userPrompt.count, (!preferCloud && LocalLLMService.shared.isReady) ? "local" : ((LicenseService.shared.isPro && LicenseService.shared.licenseKey != nil) ? "pro" : "byok"), preferCloud ? 1 : 0)

        do {
            let response: String
            // ITER-039 — local LLM takes priority for FRESH dictations
            // user just produced. Backfill paths (preferCloud=true) bypass
            // local because pumping 10-50 accumulated conversations through
            // a freshly-activated Phi-4 has frozen user's Mac in testing —
            // each conversation can be 2-5k tokens, KV cache compounds, GPU
            // queue saturates.
            if !preferCloud, LocalLLMService.shared.isReady {
                response = try await callLocalLLM(system: Self.systemPrompt, user: userPrompt)
            } else if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                response = try await callProProxy(system: Self.systemPrompt, user: userPrompt, licenseKey: licenseKey)
            } else {
                let apiKey = settings.activeAPIKey
                guard !apiKey.isEmpty else {
                    NSLog("[StructuredGenerator] No API key — skipping")
                    return
                }
                let provider = LLMProvider(rawValue: settings.llmProvider) ?? .openai
                response = try await llm.complete(
                    system: Self.systemPrompt,
                    user: userPrompt,
                    apiKey: apiKey,
                    provider: provider
                )
            }

            guard let parsed = parseResponse(response) else {
            NSLog("[StructuredGenerator] ⚠️ parse failed conv %@ — response %d chars after %.1fs, has-brace=%d", conversationId.uuidString.prefix(8) as CVarArg, response.count, Date().timeIntervalSince(t0), response.contains("{") ? 1 : 0)
                NSLog("[StructuredGenerator] ⚠️ Parse failed for conv %@", conversationId.uuidString.prefix(8) as CVarArg)
                return
            }

            // Calendar event name has priority over LLM-generated title —
            // user's own naming ("Standup C") beats LLM theme
            // inference ("Discussing Project Updates And Marketing").
            // 2026-05-07 user report. Fix scoped to new conversations only;
            // pre-existing rows keep their LLM-generated titles per user spec.
            conv.title = ConversationTitleResolver.resolve(
                calendarEventTitle: conv.calendarEventTitle,
                llmTitle: parsed.title
            )
            conv.overview = parsed.overview
            conv.category = parsed.category
            conv.emoji = validateSFSymbol(parsed.icon)
            // ITER-014 — write project + topics (canonical name resolved later
            // by ProjectAggregator; we store the raw LLM value for audit trail).
            if let rawProject = parsed.project?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawProject.isEmpty, rawProject.lowercased() != "null" {
                conv.primaryProject = rawProject
            } else {
                conv.primaryProject = nil
            }
            if let topics = parsed.topics, !topics.isEmpty {
                let cleaned = topics
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
                if !cleaned.isEmpty {
                    conv.topicsJSON = (try? String(data: JSONEncoder().encode(cleaned), encoding: .utf8))
                }
            }
            // ITER-021 — structured meeting summary sections.
            // Encode as JSON `[String]` for SwiftData (flat schema). Empty arrays
            // → store nil so UI can distinguish "not extracted yet" vs "empty".
            conv.decisionsJSON    = Self.encodeStringArray(parsed.decisions)
            conv.actionItemsJSON  = Self.encodeStringArray(parsed.actionItems)
            conv.participantsJSON = Self.encodeStringArray(parsed.participants)
            conv.keyQuotesJSON    = Self.encodeStringArray(parsed.keyQuotes)
            conv.nextStepsJSON    = Self.encodeStringArray(parsed.nextSteps)
            conv.updatedAt = Date()
            try? ctx.save()
            NSLog("[StructuredGenerator] ✅ [%@] (%@) project=%@ topics=%d: %@",
                  conv.emoji ?? "?",
                  parsed.category,
                  conv.primaryProject ?? "—",
                  parsed.topics?.count ?? 0,
                  parsed.title)
                  NSLog("[StructuredGenerator] ✅ conv %@ — %.1fs, response %d chars, title %d chars, overview %d chars, decisions=%d actions=%d participants=%d quotes=%d next=%d topics=%d project=%d", conversationId.uuidString.prefix(8) as CVarArg, Date().timeIntervalSince(t0), response.count, parsed.title.count, parsed.overview.count, parsed.decisions?.count ?? 0, parsed.actionItems?.count ?? 0, parsed.participants?.count ?? 0, parsed.keyQuotes?.count ?? 0, parsed.nextSteps?.count ?? 0, parsed.topics?.count ?? 0, conv.primaryProject == nil ? 0 : 1)

            // Embed the now-finalized conversation so MetaChat can semantically retrieve
            // it later. Fire-and-forget; nil embedding falls back to recency ordering.
            if let embeddingService {
                let source = EmbeddingService.buildConversationEmbeddingSource(for: conv, in: ctx)
                if !source.isEmpty {
                    embeddingService.embedConversationInBackground(conv, sourceText: source, in: ctx)
                }
            }

            // ITER-014 — eagerly seed the ProjectAlias row so this conversation's
            // project shows up in the Projects view immediately (rather than only
            // after the next listProjects() call would lazily resolve it).
            if let raw = conv.primaryProject?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty, let projectAggregator {
                _ = projectAggregator.resolveCanonical(raw)
            }

            // ITER-018 calendar link MOVED to the start of `generate()` (before
            // the LLM call) on 2026-05-01 — done synchronously so the recap
            // popup that fires 8s after meeting stop always has the calendar
            // title in place. Dictations (non-meeting) skip the link entirely
            // there. Nothing to do here on the post-LLM path anymore.
        } catch {
            lastError = error.localizedDescription
            NSLog("[StructuredGenerator] ❌ conv %@ failed after %.1fs — %@", conversationId.uuidString.prefix(8) as CVarArg, Date().timeIntervalSince(t0), error.localizedDescription)
            NSLog("[StructuredGenerator] ❌ Failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Prompt

    static let systemPrompt = """
    You are an expert content analyzer. Your task is to analyze the provided voice transcript and provide structure and clarity.

    ── CORE ANTI-HALLUCINATION DIRECTIVE (read first, applies to ALL fields) ──

    The transcript is the ONLY source of truth. Do NOT invent facts. Do NOT
    fill in plausible-sounding technical details (e.g. «geolocation push
    notifications», «chat functionality», «OAuth flow») unless those exact
    concepts are LITERALLY stated in the transcript. If the transcript is
    short, fragmented, or unclear, prefer GENERIC honesty («Quick check-in»,
    «Brief catch-up») over confident invention.

    ── MAIN-TOPIC vs PASSING-MENTION RULE ──

    A word mentioned ONCE or TWICE in a service phrase («у меня по X завал
    был», «потому что X не успел», «между делом по X занимался») is NOT the
    meeting's main topic. It's CONTEXT, not the subject.

    Generic patterns (use these abstract placeholders to learn the pattern;
    do NOT echo the literal placeholder names into your output):
    -  «I worked on <SIDE-PROJECT-X>, so I couldn't finish <MAIN-WORK-Y>»
       → main topic is <MAIN-WORK-Y> (the build/release/feature delay), NOT
       <SIDE-PROJECT-X>.
    -  «Met <PERSON-X> yesterday, they told me about <TOPIC-Z>» → main
       topic is <TOPIC-Z>, NOT <PERSON-X>.
    -  Brand / project / app names mentioned in apology or excuse position
       («busy with X», «behind on X», «X took longer than expected») are
       background context. The MAIN topic is whatever the speaker is
       actually trying to communicate: a status, decision, blocker, or ask.

    CRITICAL: do NOT use any project or brand name AS the title unless that
    name dominates the transcript word count AND the substantive content
    revolves around it. When in doubt, prefer a verb-based title that
    describes what the speaker was DOING or DECIDING.

    To qualify as main topic, the subject must:
    - Appear ≥30% of the transcript word-count, OR
    - Be the explicit answer to «what was this conversation about»
      (decisions, actions, key questions all centred on it).
    If neither — that word is CONTEXT, ignore for title/overview/project/topics.

    ── INSUFFICIENT-EVIDENCE FALLBACK ──

    When transcript is < 30 seconds OR no clear main topic emerges OR the
    main topic is just status-reporting («didn't get around to X», «still
    working on Y»):
    - title: «Quick check-in» / «Status update» / «Brief notes» (Title Case)
    - overview: literal 1-sentence factual summary of what was actually said,
      no embellishment. Example: «Status update — release delayed, more work
      on side project tomorrow.»
    - decisions / action_items / participants / key_quotes / next_steps:
      empty `[]` arrays. EMPTY is better than fabricated.

    ── ──

    For the TITLE: Write a clear, compelling headline (≤10 words) that captures the central topic and outcome. Use Title Case, avoid filler words, include a key noun + verb where possible (e.g., "Team Finalizes Q2 Budget" or "Debugging Memory Extraction Pipeline").

    HARD-FORBIDDEN titles (will be rejected — re-generate with more substance):
    - Single-noun generic words: "Invoice", "Meeting", "Sync", "Call", "Discussion", "Standup", "Talk", "Update".
    - Single category words: "Work", "Project", "Business", "Marketing", "Sales".
    - Anything ≤2 words that doesn't include a proper-noun (project / person / product) AND a verb-or-action noun.
    Even if "invoice" is the most-mentioned word in the transcript, the title must still describe WHAT specifically was discussed about it ("Stripe Invoice Webhook Bug", "Q2 Invoicing Pipeline Review", "Invoice Dispute With Vendor X"). A bare "Invoice" tells the user nothing — they already know there was a meeting; they need to know WHICH ONE.
    GOOD examples (specific, ≥3 informative words):
    ✅ "Stripe Webhook Bug — 5XX on PaymentIntent"
    ✅ "Sam Aligns Marketing on Q2 Roadmap"
    ✅ "Tech Interview With Maya Lee (Acme Wallet)"
    BAD examples (will be rejected):
    ❌ "Invoice" / "Sync" / "Meeting" / "Standup"
    ❌ "Marketing Sync" (still too generic — pick a specific topic discussed)
    ❌ "Q2 Plans" (which Q2? plans for what? include a project or person)
    ❌ Title that amplifies a passing-mention word (see PASSING-MENTION RULE above).
       Re-read the transcript: if the subject occupies < 30% of the talk,
       choose a different subject OR the insufficient-evidence fallback.

    For the OVERVIEW: Direct, factual 1-2 sentence summary. Lead with concrete content — what was built, decided, discussed, planned. Use specific project names, people, concrete actions. NEVER invent specifics — only use facts literally stated in the transcript.

    HARD-FORBIDDEN preambles (do NOT start the overview with these — they add zero info):
    - "The conversation is about ..."
    - "The team discusses ..."
    - "The discussion covers ..."
    - "This call is about ..."
    - "User talks about ..."
    - "It's a meeting where ..."
    GOOD examples:
    - "Redesigned Today summary card with arrow navigation and stats sub-row."
    - "Decided to ship Phase 6 voice questions; deferred premium TTS to Phase 6+."
    - "Sam + Alex aligned on Q2 budget; revisit headcount after week 3."
    BAD examples (will be rejected):
    - "The conversation is about redesigning the Today summary card."
    - "The team discusses Q2 budget and headcount."
    Begin with a verb, noun phrase, or person name. Skip the preamble.

    For the ICON: Select a SINGLE SF Symbol name (Apple's monochrome icon library) that vividly reflects the core subject. DO NOT output Unicode emoji — our app uses monochrome SF Symbols only. Choose a specific symbol over a generic one.

    Valid SF Symbol examples (pick one of these or another valid SF Symbol name):
    - "lightbulb" (new idea), "sparkles" (insight), "bubble.left" (discussion)
    - "chart.bar" (analytics), "chart.line.uptrend.xyaxis" (growth), "dollarsign.circle" (finance)
    - "ant" (bug), "hammer" (fix), "wrench.and.screwdriver" (maintenance)
    - "briefcase" (work), "building.columns" (business), "person.2" (social)
    - "book" (learning), "graduationcap" (education), "newspaper" (news)
    - "heart" (health/romance), "brain" (psychology), "leaf" (environment)
    - "airplane" (travel), "house" (home/real estate), "car" (transportation)
    - "pencil" (writing), "doc.text" (documents), "terminal" (code)
    - "calendar" (scheduling), "clock" (time), "bell" (notification)
    - "questionmark.circle" (question), "exclamationmark.triangle" (warning), "checkmark.circle" (done)
    - "target" (goal), "flag" (milestone), "star" (important)
    - "music.note" (music), "figure.run" (sports), "fork.knife" (food)
    - Fallback: "circle" if nothing specific fits.

    For the CATEGORY: Classify the content into EXACTLY ONE of these categories:
    personal, education, health, finance, legal, philosophy, spiritual, science, entrepreneurship, parenting, romantic, travel, inspiration, technology, business, social, work, sports, politics, literature, history, architecture, music, weather, news, entertainment, psychology, real, design, family, economics, environment, other

    For the PROJECT: Extract the PRIMARY product/project/codename this conversation is about.
    - GOOD: "ChatApp", "MetaWhisp", "Example Project", "Q2 Roadmap", "Migration to Postgres"
    - BAD: "work" (too generic — that's category), "discussion", "the team", "my company"
    - This is the most CONCRETE recurring entity — a specific product or initiative the user
      is building, planning, or operating. Not the employer / department / category.
    - If the conversation is personal, social, or doesn't center on a specific project → null.
    - If multiple projects mentioned → pick the one most discussed (≥60% of the talk).

    For the TOPICS: 0-3 short sub-topic tags (not full sentences). Lowercase, single word
    or short noun phrase each. Examples: ["pricing", "infra"], ["hiring", "interview"],
    ["api design"]. Empty array OK if nothing specific.

    ── ITER-021 STRUCTURED SUMMARY ──
    For the next 5 fields, extract from the transcript ONLY explicit, evidenced
    content. Empty array `[]` is BETTER than fabricated filler. Anti-hallucination
    rules apply identically to all 5 — never invent.

    DECISIONS — concrete choices/commitments made during the talk.
    - 0-5 items, each ≤14 words.
    - Format: action-led, past/perfective tense ("Switch to X", "Drop Y", "Approve Z").
    - Match transcript language (RU transcript → RU items).
    GOOD examples:
    ✅ "Switch to Stripe for billing"
    ✅ "Drop legacy admin panel — replace with Retool dashboard"
    ✅ "Hire backend engineer before end of Q2"
    ✅ "Перенести релиз на 15 мая, чтобы добить QA"
    ✅ "Цены на Pro поднять до $20/mo с июня"
    BAD examples (will be rejected):
    ❌ "Discussed pricing" (discussion ≠ decision)
    ❌ "Maybe move to Postgres" (uncertain → SKIP)
    ❌ "Talked about hiring" (no commitment)
    ❌ "Should consider switching" (modal, not a made decision)

    ACTION ITEMS — explicit commitments to do something AFTER this conversation.
    - 0-5 items, each ≤14 words.
    - Format: imperative verb + object ("Send X to Y", "Review Z").
    - Match transcript language.
    - These are HISTORY for the recap view, NOT actionable tasks. The Tasks tab
      gets populated separately by a different extractor — don't worry about overlap.
    GOOD examples:
    ✅ "Send Q2 roadmap to Sam by Friday"
    ✅ "Review SEO report — flag any drops over 10%"
    ✅ "Set up Stripe webhook integration"
    ✅ "Отправить Майку контракт до конца недели"
    ✅ "Подготовить демо для совета директоров"
    BAD examples:
    ❌ "Will think about it" (vague intent → SKIP)
    ❌ "We should follow up" (no owner, no concrete step → SKIP)
    ❌ "Maybe call Sam" (uncertain → SKIP)
    ❌ "Talk more about pricing" (that's a NEXT_STEP, not an action item)

    PARTICIPANTS — people NAMED in the transcript besides the speaker.
    - 0-10 items. Names AS SPOKEN ("Sam" stays Sam, "Майк" stays Майк, do NOT translate).
    - Match transcript language for casing/orthography.
    - Skip the speaker themselves (they're implicit).
    GOOD examples:
    ✅ ["Sam", "Alex", "Jordan from marketing"]
    ✅ ["Майк", "Вася", "Ольга (CTO Acme)"]
    BAD examples:
    ❌ ["the team"] (generic, not a name)
    ❌ ["кто-то", "someone"] (no identity)
    ❌ ["Sam (the cofounder)"] only if "the cofounder" wasn't said in the transcript
    ❌ ["Mike"] when transcript says "Майк" (do not transliterate — keep as spoken)

    KEY QUOTES — verbatim memorable lines worth re-reading.
    - 0-3 items, each ≤25 words.
    - Quote DIRECTLY from the transcript — exact wording, transcript language.
    - Pick lines that capture insight, a sharp decision, or vivid framing.
    - Skip filler/greetings. If nothing memorable → empty.
    GOOD examples:
    ✅ "If we don't ship Phase 6 by April, we lose the whole quarter."
    ✅ "Биллинг на Stripe — это не идеал, но альтернатив нет."
    ✅ "Customers stop caring about features after 30 days — pricing is the lever."
    BAD examples:
    ❌ "Hi everyone, hope you're doing well" (filler greeting)
    ❌ "I think Stripe might be a good idea" (paraphrased — must be verbatim)
    ❌ "We talked about a lot of things today" (generic)

    NEXT STEPS — forward-looking agenda items for a future conversation.
    - 0-3 items, each ≤14 words.
    - Format: topic phrase, NOT actions ("Pricing tier breakdown", not "Send pricing tiers").
    - Match transcript language.
    GOOD examples:
    ✅ "Pricing tier breakdown for Pro plan"
    ✅ "Feedback from beta users on onboarding"
    ✅ "Q3 hiring plan with Jordan"
    ✅ "Сравнение Postgres vs Mongo для следующего созвона"
    BAD examples:
    ❌ "Send invite" (that's an action item, not a next-meeting topic)
    ❌ "Discuss everything" (vague)
    ❌ "Q3 planning" (too broad — what specifically?)

    LANGUAGE RULE: All 5 fields above MUST match the transcript language. RU transcript →
    RU decisions/action_items/participants/key_quotes/next_steps. EN transcript → EN.
    Do NOT translate proper names — keep "Майк" if spoken as Майк, "Mike" if spoken as Mike.
    The TITLE/OVERVIEW also follow the transcript language.

    Return JSON:
    {"title": "...", "overview": "...", "icon": "sf.symbol.name", "category": "...",
     "project": "ChatApp" or null, "topics": ["pricing", "infra"],
     "decisions": [], "action_items": [], "participants": [], "key_quotes": [], "next_steps": []}

    CRITICAL OUTPUT RULE: Respond with ONLY the JSON object. No translation. No explanation. No preamble. No markdown fences. The "icon" value MUST be a valid SF Symbol name (lowercase with dots), NOT a Unicode emoji character.
    """

    private func buildPrompt(transcript: String, startedAt: Date) -> String {
        let isoFormatter = ISO8601DateFormatter()
        let started = isoFormatter.string(from: startedAt)

        // ITER-032.1 (2026-05-08) — supply existing project canonicals so
        // the LLM reuses established names instead of inventing variants.
        // `ProjectAggregator.listProjects(includeSingletons: false)` already
        // filters convCount ≥ 2, which is exactly the qualifying threshold
        // for the catalog hint. Empty hint when no established projects.
        var projectHint = ""
        if let pa = projectAggregator {
            let rows = pa.listProjects(includeSingletons: false)
                .map { (canonical: $0.canonicalName, convCount: $0.conversationCount) }
            projectHint = ExistingProjectCatalog.promptHint(from: rows)
        }
        let projectHintBlock = projectHint.isEmpty ? "" : "\n\n\(projectHint)\n"

        return """
        Started at: \(started)\(projectHintBlock)

        Transcript:
        ```
        \(transcript)
        ```
        """
    }

    // MARK: - Parse

    private struct StructuredJSON: Decodable {
        let title: String
        let overview: String
        let icon: String          // SF Symbol name — see system prompt
        let category: String
        // ITER-014 — optional: LLM may omit on older prompts.
        let project: String?
        let topics: [String]?
        // ITER-021 — structured meeting summary sections. All optional so
        // legacy prompts / partial failures degrade gracefully.
        let decisions: [String]?
        let actionItems: [String]?
        let participants: [String]?
        let keyQuotes: [String]?
        let nextSteps: [String]?

        // Tolerate LLM occasionally emitting "emoji" key despite our rules.
        enum CodingKeys: String, CodingKey {
            case title, overview, icon, category
            case emoji  // legacy key fallback
            case project, topics
            case decisions
            case actionItems = "action_items"
            case participants
            case keyQuotes = "key_quotes"
            case nextSteps = "next_steps"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            overview = try c.decode(String.self, forKey: .overview)
            category = try c.decode(String.self, forKey: .category)
            if let icon = try? c.decode(String.self, forKey: .icon) {
                self.icon = icon
            } else if let legacyEmoji = try? c.decode(String.self, forKey: .emoji) {
                self.icon = legacyEmoji  // best-effort; will render empty if Unicode
            } else {
                self.icon = "circle"
            }
            // Project/topics are optional so old prompts / graceful downgrade still parse.
            project = try? c.decode(String.self, forKey: .project)
            topics = try? c.decode([String].self, forKey: .topics)
            // ITER-021 — structured summary sections (all optional).
            decisions = try? c.decode([String].self, forKey: .decisions)
            actionItems = try? c.decode([String].self, forKey: .actionItems)
            participants = try? c.decode([String].self, forKey: .participants)
            keyQuotes = try? c.decode([String].self, forKey: .keyQuotes)
            nextSteps = try? c.decode([String].self, forKey: .nextSteps)
        }
    }

    private func parseResponse(_ response: String) -> StructuredJSON? {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StructuredJSON.self, from: data)
    }

    /// Extract first balanced JSON object from prose-padded text. Same as other extractors.
    private func extractJSONObject(from text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let start = stripped.firstIndex(of: "{") else {
            return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var depth = 0
        var inString = false
        var escape = false
        for idx in stripped[start...].indices {
            let ch = stripped[idx]
            if escape { escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(stripped[start...idx]) }
            }
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Action plan (2026-05-29 feature)

    /// On-demand "meeting write-up + action plan" for the conversation detail
    /// page. Free-form markdown (Summary + Action-plan checklist) the user can
    /// read or copy — replaces the manual "paste transcript into ChatGPT" loop.
    ///
    /// Runs on the HEAVY tier (user-facing quality, unlike the mini-tier
    /// structured extraction). Local LLM takes priority when loaded.
    func generateActionPlan(transcript: String, title: String?) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else {
            throw ProcessingError.apiError("Transcript too short for a plan")
        }
        let (system, user) = ConversationTextAssembler.actionPlanPrompt(transcript: trimmed, title: title)

        // Local LLM first (free + private) when active. ITER-051 F1.2 —
        // chunked map-reduce so an hour-long transcript's plan covers the
        // whole meeting, not the first ~2 minutes (old 2000-char cap).
        if LocalLLMService.shared.isReady {
            return try await LocalLLMService.shared.completeChunked(system: system, user: user)
        }
        guard LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey else {
            throw ProcessingError.apiError("Pro required to generate an action plan")
        }
        // The proxy takes one prompt at a time, and an 87-minute meeting is
        // longer than it accepts — the same reason the local path folds. Same
        // fold, so the plan covers the whole meeting on either engine
        // (2026-09-04; before this the Pro path sent 47 000 chars and got
        // HTTP 400 back).
        var skipped = 0
        var ofParts = 0
        let plan = try await ChunkedCompletion.run(
            system: system, user: user,
            chunkChars: ChunkedCompletion.graphemeBudget(for: user, unitLimit: LLMRequestBody.safePromptChars),
            // Skips accumulate across fold rounds while each round has its
            // own part count — keeping the largest is what makes "N of M"
            // true (independent review: two skips in a round of three then
            // one in a round of two read as "3 of 2").
            onChunkSkipped: { _, of, _ in skipped += 1; ofParts = max(ofParts, of) }
        ) { sys, usr, _ in
            try await self.callProAdvice(system: sys, user: usr, licenseKey: licenseKey,
                                         tier: .heavy, serviceId: "ActionPlan",
                                         timeout: 60, label: "Action-plan")
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plan.isEmpty else { throw ProcessingError.apiError("Empty plan from LLM") }
        NSLog("[StructuredGenerator] Action-plan pro ✅ plan %d chars, %d of %d sections skipped", plan.count, skipped, ofParts)
        // A plan that covers part of the meeting says so: dropping a section
        // quietly is the same lie as dropping the microphone quietly.
        guard skipped > 0 else { return plan }
        return plan + "\n\n_" + String(skipped) + " of " + String(ofParts)
            + " sections of this meeting could not be processed — the plan may be missing items from them._"
    }

    // MARK: - Pro proxy

    private func callProProxy(system: String, user: String, licenseKey: String) async throws -> String {
        // One JSON out (title/overview/…), so the fold does not apply here —
        // the same head+tail sandwich the local path uses, against the
        // proxy's own limit. Without it an hour-long meeting got HTTP 400 and
        // no title at all (2026-09-04).
        try await callProAdvice(system: system,
                                user: Self.headAndTail(user, limit: ChunkedCompletion.graphemeBudget(
                                    for: user, unitLimit: LLMRequestBody.safePromptChars)),
                                licenseKey: licenseKey,
                                tier: Self.llmTier, serviceId: Self.llmServiceId,
                                timeout: 30, label: "Structured")
    }

    /// Keep the beginning and the END of a transcript when it does not fit:
    /// the end of a meeting carries the decisions and the action items, and a
    /// head-only cut used to drop them.
    nonisolated static func headAndTail(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let marker = "\n[…transcript middle omitted…]\n"
        let room = max(0, limit - marker.count)
        let head = room * 2 / 3
        return String(text.prefix(head)) + marker + String(text.suffix(room - head))
    }

    /// One call to `POST /api/pro/advice`. A failure carries the proxy's own
    /// words: "HTTP 400" alone hid `Prompt too long (47178 chars, max 32000)`
    /// for two days and left the founder guessing (2026-09-04).
    private func callProAdvice(system: String, user: String, licenseKey: String,
                               tier: LLMTier, serviceId: String,
                               timeout: TimeInterval, label: String) async throws -> String {
        // The wire limit counts UTF-16 units. Everything above aims below it;
        // if a prompt still arrives over the line, say so plainly instead of
        // spending a call to be told "Prompt too long".
        guard user.utf16.count <= LLMRequestBody.maxPromptChars,
              system.utf16.count <= LLMRequestBody.maxPromptChars else {
            throw ProcessingError.apiError(
                label + " prompt too long for the proxy (" + String(user.utf16.count)
                    + " units, max " + String(LLMRequestBody.maxPromptChars) + ")")
        }
        let url = URL(string: "https://api.metawhisp.com/api/pro/advice")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let body = LLMRequestBody.proAdviceBody(
            system: system, user: user, tier: tier, serviceId: serviceId
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ProcessingError.apiError(
                "\(label) proxy HTTP \(http.statusCode)\(Self.proxyReason(data))")
        }
        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    /// The proxy answers `{"error": "…"}` on every failure it can name.
    nonisolated static func proxyReason(_ data: Data) -> String {
        struct ProxyError: Decodable { let error: String }
        if let decoded = try? JSONDecoder().decode(ProxyError.self, from: data), !decoded.error.isEmpty {
            return " — " + decoded.error.prefix(200)
        }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "" : " — \(raw.prefix(200))"
    }

    // Internal (was private) — ITER-050 B1.1: ProjectAggregator must check
    // access BEFORE wiping conversation fields it can't regenerate.
    var hasLLMAccess: Bool {
        // ITER-039 — `LocalLLMService.isReady` is the third clause. Free
        // users with a downloaded + activated MLX model now get
        // StructuredGenerator (structured-text cleanup, the most-used LLM
        // call in the app) working without any API key or Pro subscription.
        !settings.activeAPIKey.isEmpty
            || LicenseService.shared.isPro
            || LocalLLMService.shared.isReady
    }

    /// Route system + user prompt through the local Phi-4 (or whichever
    /// MLX model is loaded).
    ///
    /// **Prompt size hard cap (2026-05-13 freeze incident).** The transcript
    /// can hit 5k+ chars in real use; combined with the structured-output
    /// system prompt that's ~3k+ tokens. Sending the whole thing to local
    /// Phi-4 froze the user's Mac for 30+ seconds (prefill on 32-layer GQA
    /// model with 3k context = massive KV-cache materialization + main-
    /// thread block). We cap at ~2k chars (~600-700 tokens) for the user
    /// transcript and let cloud handle the rare larger ones via Pro.
    ///
    /// **Output cap.** 384 tokens is enough for our structured JSON
    /// response (title + overview + actionItems + …). Anything bigger
    /// suggests the model is hallucinating off-track — fail fast.
    private func callLocalLLM(system: String, user: String) async throws -> String {
        // ITER-051 F1.2 — head+tail sandwich instead of a head-only 2000-char
        // cut: the response is one JSON (title/overview), so map-reduce
        // chunking doesn't apply here, but the END of a meeting (decisions,
        // action items) must inform the overview. 4000+2000 fits Phi-4's
        // context comfortably alongside the system prompt.
        let cappedUser: String
        if user.count > 6000 {
            cappedUser = String(user.prefix(4000))
                + "\n[…transcript middle omitted for local model…]\n"
                + String(user.suffix(2000))
        } else {
            cappedUser = user
        }
        let combined = system + "\n\n" + cappedUser
        var collected = ""
        for await chunk in LocalLLMService.shared.generate(
            prompt: combined,
            maxTokens: 384,
            temperature: 0.3
        ) {
            collected += chunk
        }
        if collected.isEmpty {
            throw NSError(domain: "LocalLLM", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Local model returned no tokens — check Settings → AI Models that Phi-4 is downloaded and active."
            ])
        }
        return collected
    }

    /// Ensure the LLM-supplied icon is an SF Symbol string, not a Unicode emoji.
    /// SwiftUI's `Image(systemName:)` silently renders empty if the name is wrong, so
    /// we catch obvious emoji (non-ASCII) early and fall back to a neutral default.
    private func validateSFSymbol(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Heuristic: SF Symbol names are ASCII lowercase + dots + digits. Emoji chars are non-ASCII.
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "."))
        if !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return trimmed
        }
        NSLog("[StructuredGenerator] ⚠️ Icon '%@' not a valid SF Symbol name, falling back", trimmed)
        return "bubble.left"  // neutral default
    }
}
