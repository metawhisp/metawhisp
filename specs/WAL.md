# WAL — Write-Ahead Log

**Backlog:** открытые треки перечислены в `specs/BACKLOG.md` (source of truth). Ни одна работа не начинается без OK user'а.

**Session handoff:** `specs/HANDOFF.md` — обязательно прочитать при старте новой сессии (после BOOT/KARPATHY/BACKLOG).

**Shipped in session 2026-04-19 (summary):** Phases 0-3 end-to-end (Conversations, Screen pipeline, Readers), sidebar reorg 9→6 tabs, MetaChat brand + RAG + typing animation, Phase 6 voice questions (long-press Right ⌘ → TTS answer) with redesigned floating UI + STOP/Space/Esc controls. Phase 4/5/7/8 planned in BACKLOG. E4 Gmail + E5 unified runner deferred.

**Shipped in session 2026-04-20 (summary so far):**
- Cleanup: rewrote 2 pushed commits to scrub external-reference name from titles + bodies, renamed branch `omi-architecture-phase-1-3` → `architecture-phase-1-3` (force-push), scrub commit `96bd8e2` across 37 repo files (165+/215−).
- Phase 6+ Premium TTS shipped: backend `/api/pro/tts` endpoint (OpenAI tts-1 proxy, 6 voices) + frontend dual-provider routing (cloud if Pro+enabled, else AVSpeech) + Settings Cloud Voice toggle gated on Pro. Awaiting user deploy of `api/` + `wrangler secret put OPENAI_API_KEY` before live test.

**Shipped in session 2026-04-23 (resumed):**
- ITER-010-A — UserMemory enrichment fields (`headline`, `reasoning`, `tagsCSV`); MemoryExtractor prompt + parser updated; ChatService renders memories with headline/reasoning/tags so MetaChat can quote both the fact and why it was stored.
- ITER-010-B — DailySummaryService rebuilt as multi-agent: 4 specialist LLM agents (`learnedAgent` / `decidedAgent` / `shippedAgent` / `energyAgent`) run in parallel via `async let`, then a follow-up `headlineAgent` synthesizes the headline from already-extracted sections. Each agent has its own focused system prompt with anti-cliché rules. Old monolithic `systemPrompt` + `buildPrompt` + `parseResponse` + `ParsedSummary` removed. New `DailySummary` fields `learnedJSON / decidedJSON / shippedJSON / energy` populated; legacy `overview` mirrors `energy` for compat.
- ITER-019 — Realtime advice during meeting recording:
  - **Goal:** advice fired ТОЛЬКО после `MeetingRecorder.stop()` потому что весь chunk транскрибится за один pass на close. На длинных звонках юзер сидит час без помощи. Делаем партиал-транскрибацию каждые 30s + кормим в `AdviceService.triggerOnTranscription(source:"meeting-live")`.
  - **Audio peek API:**
    - `Services/Audio/AudioRecordingService.swift` — `+var currentSampleCount: Int`, `+func peekSamples(from:)` — non-destructive read accumulated buffer.
    - `Services/Audio/SystemAudioCaptureService.swift` — same pair.
    - `stop()` всё ещё возвращает full recording для финальной транскрипции — peek просто читает срез.
  - **New service — `Services/Intelligence/LiveMeetingAdvisor.swift`:**
    - `configure(meetingRecorder:coordinator:adviceService:)`
    - Auto-arm/disarm через Combine subscription на `meetingRecorder.$isRecording` (`removeDuplicates` чтобы не дребезжало).
    - Periodic Task каждые `chunkSeconds` (default 30, clamped 10-120):
      - peek mic+sys samples since last offset
      - mix через `MeetingRecorder.mix(...)` (статический helper)
      - silence guard (`< 0.0008 RMS`) + min 1s samples
      - transcribe через `coordinator.activeEngine` (тот же engine что финальный pass)
      - hallucination filter (`isAlwaysHallucination` + `isHallucination` под низкий RMS)
      - на success — `adviceService.triggerOnTranscription(text, source: "meeting-live")` + advance offsets
      - на fail — НЕ advance offsets (retry на следующем chunk'е)
    - Reset offsets в 0 на disarm — fresh meeting читает с нуля.
    - `@Published var lastPartial`, `lastFireAt`, `isActive` — для UI status pill (можно добавить позже).
  - **Settings — `Models/AppSettings.swift`:**
    - `+liveMeetingAdviceEnabled: Bool = false` — opt-in (стоит ~$0.05 на час meeting'а под Pro proxy).
  - **Settings UI — `Views/Windows/MainSettingsView.swift`:**
    - Новый toggle "Live advice during meeting" в Meeting Recording секции под Recap notifications. Подпись объясняет cost ($0.05/h) + Pro only.
  - **AppDelegate — `App/AppDelegate.swift`:**
    - `+let liveMeetingAdvisor = LiveMeetingAdvisor()`
    - `liveMeetingAdvisor.configure(meetingRecorder:, coordinator:, adviceService:)` сразу после `adviceService.configure(...)`.
  - **Files touched:** `Services/Audio/AudioRecordingService.swift`, `Services/Audio/SystemAudioCaptureService.swift`, `Services/Intelligence/LiveMeetingAdvisor.swift` (NEW), `Models/AppSettings.swift`, `Views/Windows/MainSettingsView.swift`, `App/AppDelegate.swift`.
  - **Build:** clean.
  - **Costs / risks:**
    - 1 transcription call per 30s chunk → 120 calls на час meeting'а. Cloud preferred via active engine.
    - AdviceService уже имеет per-source cooldown (15 min default), so actual advice пишется реже.
    - On-device WhisperKit тоже сработает но медленнее (CPU). Pro path (cloud) рекомендован.
    - Если transcribe failed (network blip) — offset не двигается → следующий chunk re-attempts тот же буфер расширенным.

- ITER-018 — Calendar ↔ Conversation cross-reference:
  - **Goal:** автоматически линковать каждый закрытый Conversation к ближайшему по времени EKEvent (с весами time-overlap + title-similarity). Снапшот event title + time + attendees сохраняется на Conversation. MetaChat получает `calendar:` поле в `<recent_meetings>` блоке и может отвечать «о чём говорили на standup в среду» по имени календарного события (а не auto-сгенерированного title'а).
  - **Data model — `Models/Conversation.swift`:**
    - `+calendarEventId: String?` — `EKEvent.eventIdentifier`.
    - `+calendarEventTitle: String?` — snapshot title.
    - `+calendarEventStartDate: Date?` / `+calendarEventEndDate: Date?` — snapshot range.
    - `+calendarAttendeesJSON: String?` — JSON `[String]` имена участников (или email из URL fallback).
    - All Optional → SwiftData lightweight migration. Verified: 5 new ZCALENDAR* columns в БД после relaunch.
  - **Linker — `Services/Indexing/CalendarReaderService.swift`:**
    - NEW `linkConversation(_ convId: UUID) async` — pre-checks calendar auth, fetches conv, computes window `[startedAt - 5min, finishedAt + 5min]` (or last HistoryItem.createdAt + 5min when finishedAt nil), calls `store.predicateForEvents(...)`, scores each candidate.
    - Score = `0.6 × time-overlap-fraction + 0.4 × title-token-Jaccard` (lowercase tokens length ≥ 3). Threshold 0.5.
    - Snapshot match → save 5 fields to Conversation, log `[Calendar] ✅ linked conv X → event 'Y' (score Z)`.
    - Idempotent: skips if `calendarEventId != nil`.
    - NEW `backfillCalendarLinks() async` — bounded 90 days, 200 max. Walks completed convs without link, attempts each. Called from AppDelegate launch +25s delay (after embeddings + projects backfills).
    - NEW pure helpers `timeOverlapFraction(a:b:)` and `tokenJaccard(_:_:)` — reusable + unit-testable.
  - **Wiring:**
    - `Services/Intelligence/StructuredGenerator.swift` — `+weak var calendarReader: CalendarReaderService?`. After title/overview populate + project resolve → fire `Task { await calendarReader?.linkConversation(conv.id) }`. Non-meeting dictations rarely match — linker exits cheaply.
    - `App/AppDelegate.swift` — wires `structuredGenerator.calendarReader = calendarReader` и спавнит `backfillCalendarLinks()` спустя 25s после launch.
  - **MetaChat surfacing — `Services/Intelligence/ChatService.swift`:**
    - `MeetingSnippet` extended: `+calendarTitle, calendarStart, calendarEnd, calendarAttendees: [String]`.
    - `fetchMeetingsForQuery` decodes `calendarAttendeesJSON` and packs into snippet.
    - `<recent_meetings>` rendering adds `  calendar: <title> (HH:mm-HH:mm) · with: name1, name2` line when matched.
    - System prompt extended in MEETINGS rule: «Calendar lookup — when user references meeting by EVENT NAME, match against `calendar:` line. Prefer citing calendar name over auto-title».
  - **Files touched:** `Models/Conversation.swift`, `Services/Indexing/CalendarReaderService.swift`, `Services/Intelligence/StructuredGenerator.swift`, `Services/Intelligence/ChatService.swift`, `App/AppDelegate.swift`.
  - **Build:** clean.
  - **Risks:**
    - Threshold 0.5 calibrated empirically — may misss meetings with very generic titles ("Meeting") and few common tokens. Acceptable: time-overlap alone (no title similarity) gets 0.6 × overlap_fraction; full overlap = 0.6 score → just on threshold.
    - Multiple events in same time window → highest score wins. Edge: back-to-back meetings could grab the wrong one, but score formula prefers earlier-overlap when both 100% temporal-fit.
    - Privacy: only event TITLE + attendee NAMES snapshotted, no description/location/notes. Surfaced only inside MetaChat prompts (Pro proxy).

- ITER-022 G_dashboard v2 — Square day-picker + click-driven detail (2026-04-25):
  - **Trigger:** v1 swipe-carousel rejected by user: «карточки должны быть квадратные и переключаться по клику не по свайпу».
  - **Architecture rebuild (v1 → v2):**
    - **v1 was:** ScrollView pageable swipe with `containerRelativeFrame(count: 1)` — full-viewport rectangular cards, snap-to-card via gesture.
    - **v2 is:** `[picker row of square 80×80 mini-tiles]` + `[full-width detail card]`. Click on any tile → `selectedDay` state updates → detail card re-renders. Pure click-driven, zero swipe gestures.
  - **Components:**
    - `DailySummaryCarousel` (renamed but kept name for symmetry) — owns `@State selectedDay`, renders picker row + detail.
    - `MiniDayTile` (NEW) — 80×80 square. Layout: `[EEE day-of-week label] [day number large] [status icon]`. Selected = filled bg + accent border (textPrimary opacity 0.5). Status icons: `checkmark.circle.fill` if has summary, `circle.dotted` if past empty, `moon.zzz` for future.
    - `DetailCard` — full-width below picker. Shows full DailySummary render (headline + LEARNED / DECIDED / SHIPPED / ENERGY) for selected day, OR empty placeholder OR future placeholder. Local `@State localSummary` for instant UI updates after GENERATE.
  - **Picker:** ScrollViewReader + h-scroll, 14 days, `.onAppear { proxy.scrollTo(today, anchor: .center) }` so today centers on first show.
  - **Detail card features:**
    - Header: "TODAY'S SUMMARY / YESTERDAY / N DAYS AGO / TOMORROW" + date + REGENERATE/GENERATE button (or "scheduled HH:MM" for future).
    - Past empty day → "No summary recorded — tap GENERATE to build one from saved data" + clickable button (calls `generateForDate(_:)` retroactively).
    - Future → moon icon + "Tomorrow's recap will appear at HH:MM".
  - **Animation:** click-tile → `withAnimation(.easeInOut(0.15))` selectedDay = day → SwiftUI re-evaluates DetailCard binding.
  - **Files touched:** `Views/Windows/DashboardView.swift` (single file rewrite of carousel namespace).
  - **Build:** clean. Debug + release rebuilt. App relaunched.
  - **Visual confirmed (screenshot):**
    - 14 square tiles SUN 12 → TMRW 26 в горизонтальном ряду.
    - TODAY 25 selected (highlighted: filled bg + bright border).
    - YEST/TODAY/TMRW лейблы корректно различаются.
    - Status icons: ✓ для days with summary, moon for tomorrow.
    - Detail card: full-width "Memory issue and clarity review" + sections + REGENERATE.
    - Stats row + StatisticsView ниже работают.
  - **v1 (swipe) replaced cleanly** — no lingering carousel code.
- ITER-022 G_dashboard — Daily Summary как iOS-style карусель (2026-04-25):
  - **Trigger:** user-reported «главный экран бесполезный, не несёт ценности · криво пространство · хочу карусель Today/Yesterday/Tomorrow с peek краёв соседних дней (как iOS Photos gallery)».
  - **Diagnosis (Karpathy):**
    - 3 distinct problems в одной жалобе: (a) static today-only — нет navigation между днями; (b) right column (280pt) отжимает width у main card; (c) пустой today = visual clutter без value.
    - Owner layer = `DashboardView.swift` (UI) + `DailySummaryService.swift` (data access for arbitrary date).
  - **Architecture changes:**
    - **Service:** `DailySummaryService.generateNow()` теперь thin wrapper над new `generateForDate(_:)`. New `summary(for: Date) -> DailySummary?` public — UI carousel reads per day. `generateForDate` skips future dates (no data possible).
    - **UI:** `DailySummaryCard` (single static) → `DailySummaryCarousel` (full-width pageable horizontal scroll). Right column TodayStats + ScreenActivity moved BELOW carousel as horizontal split (full width reclaimed for the card).
  - **Carousel mechanics:**
    - 14 past days + today + tomorrow placeholder (15 cards total).
    - SwiftUI `ScrollView(.horizontal) { LazyHStack { ForEach … containerRelativeFrame(count: 1) } .scrollTargetLayout() } .scrollTargetBehavior(.viewAligned) .contentMargins(.horizontal, 32, for: .scrollContent) .scrollPosition(id: $currentDay)`.
    - macOS 14+ pageable scroll API — gives snap-to-card with peek of neighbours via 32pt content margin.
    - Default `currentDay = startOfDay(now)` set in @State + `.onAppear` hardening.
  - **DayCard states (per day type):**
    - **today + has summary** → full render (headline + LEARNED / DECIDED / SHIPPED / ENERGY) + REGENERATE button.
    - **today + no summary** → emptyPlaceholder + GENERATE button.
    - **past + has summary** → full render + REGENERATE.
    - **past + no summary** → empty msg "No summary recorded — tap GENERATE" + GENERATE button (works retroactively через `generateForDate(_:)`).
    - **future (tomorrow)** → "moon.zzz" icon + "Tomorrow's recap will appear at HH:MM" placeholder, no button.
  - **Day labels:** TODAY'S SUMMARY / YESTERDAY / N DAYS AGO / TOMORROW + dateLabel (e.g. "Apr 25").
  - **Local state:** `@State var localSummary` per DayCard — UI updates immediately after GENERATE without waiting for @Query refresh.
  - **Files touched:** `Services/Intelligence/DailySummaryService.swift`, `Views/Windows/DashboardView.swift`.
  - **Build:** clean. Debug + release rebuilt. App relaunched.
  - **Visual confirmed (screenshot):**
    - Full-width Today's Summary card with REGENERATE button.
    - Headline "Memory issue and clarity review" + LEARNED 2 items + DECIDED 1 item + ENERGY line "Low activity scattered apps".
    - Edge peek visible на левом краю (yesterday card thin sliver).
    - Stats row под carousel — TODAY (2/2/0/1) + LAST 24H ON SCREEN (Telegram 3h7m / Arc 1h55m / Claude 1h10m / loginwindow / Safari).
    - StatisticsView ниже работает (46 days streak, 90.1k words, 3.6k transcriptions).
  - **Old `DailySummaryCard` остался в файле** as dead code (no callers). Cleanup deferred.
- ITER-022 G5 — WeeklyPatternDetector cross-conversation digest (2026-04-25):
  - **Trigger:** advice audit → reference detects "3 meetings about pricing — same blocker keeps coming up" cross-context patterns. У нас DailySummary даёт single-day recap, StructuredGenerator single-conv. Никто не делает cross-week analysis. **Биguest gap** filled.
  - **Architecture (Karpathy — top-down + bottom-up):**
    - Top-down: scheduler (Sunday wall-clock) → `generate(window: 7d)` → fetch convs+memories+tasks → LLM → `PatternDigest` row → notification.
    - Bottom-up: new `@Model PatternDigest` (4 JSON arrays + counters + dates) → `WeeklyPatternDetector` service (~250 lines) → AppDelegate wire → Settings toggle + hour picker.
  - **`Models/PatternDigest.swift` (NEW @Model):** id, weekStartDate, windowDays, themesJSON, peopleJSON, stuckLoopsJSON, insightsJSON, conversationsAnalyzed, createdAt. Computed `themes/people/stuckLoops/insights` decoders. `isEmpty` для UI rendering.
  - **`Services/Data/HistoryService.swift`:** schema +`PatternDigest.self` в обе ветки.
  - **`Services/Intelligence/WeeklyPatternDetector.swift` (NEW):**
    - 5-min scheduler tick. Fires when (a) Sunday in user TZ, (b) wall-clock >= configured hour, (c) no digest within last 6 days (anti-spam).
    - `generate(postNotification:)` — fetch convs + memories + open tasks within `windowDays=7`. If <3 convs → write empty digest, post "Quiet week" notif.
    - LLM via Pro proxy. Single call (~$0.02 per weekly fire). Prompt cap 16KB.
    - Parser: 4 sections → JSON arrays with strict cleaning (trim, filter empty).
    - Notification fired on success: title "Weekly patterns ready", body summary counts + "open Insights".
  - **`Models/AppSettings.swift`:** `+weeklyPatternsEnabled: Bool = false`, `+weeklyPatternsHour: Int = 18` (Sunday 18:00 default).
  - **`App/AppDelegate.swift`:** `+let weeklyPatternDetector = WeeklyPatternDetector()` + configure + conditional `startScheduler()`.
  - **`Views/Windows/MainSettingsView.swift`:** new `weeklyPatternsSection` под dailySummarySection в AI tab. Toggle + DatePicker для hour + manual-trigger hint pointing to Insights tab.
  - **System prompt rules:** anti-fabrication aggressive («empty array better than filler»). Stuck-loop definition tight: «discussed ≥3× AND no decisions extracted». Person format: name + role/context. Themes ≥3 distinct convs.
  - **Risks mitigated:**
    - Cost: cap 30 convs × 200 chars overview + 30 memories + 30 tasks = ~12KB prompt. ~$0.02 per fire.
    - Empty week: explicit threshold check + "Quiet week" notif (sound nil чтобы не дёргало).
    - Subjective stuck-loop: prompt requires «no decisions extracted from those convs» — anchored in Conversation.decisionsJSON (ITER-021).
  - **Files touched:** `Models/PatternDigest.swift` (NEW), `Services/Data/HistoryService.swift`, `Models/AppSettings.swift`, `Services/Intelligence/WeeklyPatternDetector.swift` (NEW), `App/AppDelegate.swift`, `Views/Windows/MainSettingsView.swift`.
  - **Tests pass:**
    - Build clean, debug + release rebuilt.
    - Schema migration: ZPATTERNDIGEST table created с 11 columns на live DB.
    - AppDelegate wired correctly (lines 432-434).
    - Settings UI section present + DatePicker functional.
    - Setting keys: `weeklyPatternsEnabled` Bool default false, `weeklyPatternsHour` Int default 18.
    - App running, fresh launch 9:55 PM.
  - **Live verification deferred:** scheduler fires только в Sunday в configured hour. Manual GENERATE button — TODO (Insights tab UI integration отдельный mini-track).
- ITER-022 G4 — Coach mode opt-in (accountability prompt path) (2026-04-25):
  - **Trigger:** advice audit identified coach-style accountability как gap vs reference. Reference default = coach + memories proactive. Наш default = pure insight + anti-coach (банилось "Take a break / Stay hydrated"). Решение: opt-in toggle who switches prompt.
  - **Architecture decision:** keep philosophical default (anti-noise pure insight) **AND** offer opt-in coach mode for users who want push-back. Single source of switching = `AppSettings.adviceCoachMode`. Read at fire time so toggle takes effect immediately.
  - **Fix:**
    - `Models/AppSettings.swift`: `+@AppStorage("adviceCoachMode") var adviceCoachMode: Bool = false`.
    - `Services/Intelligence/AdviceService.swift`:
      - Renamed `static let systemPrompt` → `systemPromptStandard` (current behaviour, anti-coach).
      - `+static let systemPromptCoach` — accountability prompt:
        - WHEN TO PUSH: stated commitment slipping, repeated distraction pattern, goal at 0 mid-day, intent contradicted by action.
        - STILL BANNED: generic wellness ("drink water", "stretch"), mood judgment ("you seem anxious"), therapy tone, vague motivation, shaming.
        - GOOD: "Ship X promised by Friday — 6h left, you've checked Twitter 5×". BAD: "Stay focused!" / "You can do it!".
        - WHEN TO STAY SILENT: no commitment to anchor, repeats prior advice, healthy break, user in active recorded meeting (don't interrupt).
      - `+static var activePrompt: String` — runtime selector based on setting.
      - `generateAdvice` callsite uses `Self.activePrompt` + logs `mode=standard|coach`.
    - `Views/Windows/MainSettingsView.swift`: `+toggleRow("Coach mode", ...)` в adviceSection с conditional explanatory text.
  - **No external callers** of `AdviceService.systemPrompt` outside the service — rename safe.
  - **Files touched:** `AppSettings.swift`, `AdviceService.swift`, `MainSettingsView.swift`.
  - **Tests pass:**
    - Build clean. Debug + release rebuilt. App relaunched.
    - Setting key registered (Bool, default false, AppStorage).
    - Both prompts present + activePrompt selector wired.
    - UI toggle visible at `MainSettingsView.swift:1323`.
- ITER-022 G3 — Memory-weave в AdviceService (semantic memory ranking) (2026-04-25):
  - **Trigger:** advice audit identified that AdviceService включал memories в prompt **flat (15 most recent)**. Без cosine ranking → LLM видел irrelevant memory bullets ("user likes coffee" при advice про код) → tempted to shoehorn unrelated memory ИЛИ ignored entirely.
  - **Fix — `Services/Intelligence/AdviceService.swift`:**
    - `+weak var embeddingService: EmbeddingService?` — wired в AppDelegate.
    - `+fetchMemoriesForAdvice(contexts:extraContext:limit:) async -> [UserMemory]`:
      1. Build query string from latest screen context (appName + windowTitle + ≤600 chars OCR) + extraContext.
      2. Embed via Pro proxy (skip non-Pro → fall back to recent-N).
      3. Score each non-dismissed memory с embedding by cosine similarity.
      4. Threshold 0.45 — drop irrelevant. Empty array better than wrong memories.
      5. Top-`limit` (default 8) by score.
    - `buildAdviceUserContext(...)` теперь `async`, использует new ranker. Original block label updated to "USER MEMORIES (durable facts — weave only when materially relevant)".
    - `generateAdvice` callsite: `let contextBlock = await buildAdviceUserContext(...)`.
    - **System prompt: новая секция MEMORY-WEAVE** — explicit rules:
      «Reference a memory ONLY when it materially changes the advice». Concrete worked example («Stripe webhook test mode + memory 'Overchat uses Stripe billing' → "switch to test customers"»). Forbidden: shoehorning, "you said earlier...", verbatim quoting.
  - **AppDelegate wiring:** `adviceService.embeddingService = embeddingService` after configure.
  - **Risk mitigated:** "force-weave even when irrelevant" — threshold 0.45 + explicit anti-shoehorn rule.
  - **Files touched:** `AdviceService.swift`, `AppDelegate.swift`.
  - **Tests pass:**
    - Build clean. Wired correctly: `adviceService.embeddingService = embeddingService` line 502.
    - DB: **19/19** active memories with embedding (100% coverage from ITER-008/011 backfill) → semantic ranking will engage immediately.
    - Function signature correct (async returns `[UserMemory]`).
    - App running, 0% CPU idle, fresh relaunch 9:44PM.
- ITER-022 G1 — AdviceService categories расширены 4 → 11 (2026-04-25):
  - **Trigger:** advice audit comparing our prompts vs reference revealed our advice categorization was 4 classes (productivity / communication / learning / other) vs reference 11+. Health / financial / relationships / mental / security / career — все падали в `other`, теряя filter signal.
  - **Diagnostic finding (Karpathy):** existing DB distribution showed LLM был **CREATIVE** и уже сам генерил `health` (20 items!) и `security` (1) ДО legitimization. Old whitelist был unnecessarily ограничивающим — мы downgrade'или legitimate categorical signal в `other` parser fallback'ом. Расширение **формализует** behaviour LLM который уже происходил.
  - **Fix — `Services/Intelligence/AdviceService.swift`:**
    - System prompt: новый CATEGORIES section с 11 explicitly-defined types: `productivity / communication / learning / health / finance / relationships / focus / security / career / mental / other`. Каждая с строгой scope clarification (e.g. "health — ergonomics/credentials/screen-time, NOT 'drink water'"; "mental — observed pattern, NOT therapy/mood judgment").
    - Critical anti-noise note: WHEN-TO-STAY-SILENT rules **OVERRIDE** category fit. "health" не означает можно nag'ать — advice по-прежнему must be specific/actionable/non-obvious.
    - Static `Self.validCategories: Set<String>` — whitelist для parser normalization.
    - Parser: `let normalizedCategory = validCategories.contains(candidate.lowercased()) ? candidate.lowercased() : "other"` — defends against typos / hallucinated categories.
  - **Files touched:** `Services/Intelligence/AdviceService.swift` only.
  - **Build:** clean. Debug + release rebuilt. App relaunched.
  - **Test results:**
    - Grep clean — no consumer hardcoded old 4 categories (UI render is category-agnostic)
    - DB inspection: 81 productivity / 42 learning / 28 communication / 20 health / 2 other / 1 security baseline before fix
    - Live verification deferred to next 15-min periodic fire (new categories: finance/relationships/focus/career/mental will appear when warranted)
- ITER-021.2 — Tasks staged candidates 2-tap → 1-tap UX fix (2026-04-25):
  - **Trigger:** user-reported «зачем здесь галочка и крестик когда нажимаешь галочку то таска делается и нужно еще раз нажать галочку — почему нельзя нажимать просто галочку сразу чтобы task считалась сделанной». Two-click flow for what's intuitively a single "done" tap.
  - **Diagnosis:** UX-design disconnect. Visually a checkmark = done. Functionally it was promote (move to MY TASKS), then user had to tap ✓ AGAIN in the active list to mark done. Two clicks for the most-common intent ("I already did this").
  - **Fix — `Views/Windows/TasksView.swift` `candidateCard(_:)`:** 3 actions instead of 2:
    - **✓ DONE** (was: promote) — single-click sets `completed=true`, `completedAt=now`, `status="committed"`. Counts toward Shipped/Done stats. The right default for screen-extracted tasks reflecting work the user already did.
    - **+ SAVE FOR LATER** (new) — promote to MY TASKS active without completing. Use case: "будут делать потом". Old ✓ behavior preserved on this button.
    - **✗ DISMISS** — unchanged, hide as not relevant.
  - Header hint updated: `auto-extracted · ✓ done · + save for later · ✗ skip` so the 3 actions are self-documenting.
  - Each button has a `.help(...)` tooltip for hover discovery.
  - **Why default ✓ = done makes sense:** screen-extracted candidates almost always reflect work the user is currently doing or just finished (the OCR pipeline literally watches the screen during the action). Treating ✓ as "save for later" was inverted — the rare case got the default, the common case got two clicks.
  - **Files touched:** `Views/Windows/TasksView.swift` (single function rewrite).
  - **Build:** clean. App rebuilt + signed + relaunched.
- ITER-021.1 — Project deletion (2026-04-25):
  - **Trigger:** user-reported «есть проекты которые не нужны и их не существует но я не могу поправить — надо добавить возможность удалять» on the Projects view (14 clusters including noise like "Microsoft Clarity", "Atomic", "DRUGENERATOR").
  - **Diagnosis (Karpathy):** owner-layer = `ProjectAlias` row + raw `Conversation.primaryProject`. Two states must change atomically — alias gone AND linked conversations unlinked. Conversation rows themselves stay (transcript = user data, deleting a project ≠ deleting recordings).
  - **`Services/Intelligence/ProjectAggregator.swift`:** new `deleteProject(canonicalName:) -> Int` method:
    1. Find `ProjectAlias` by canonical name (returns 0 if already gone — idempotent).
    2. Fetch all `Conversation` with `primaryProject != nil`, filter case-insensitive against `alias.aliases`, set `primaryProject = nil` + bump `updatedAt`. Predicate-side OR-of-aliases awkward in SwiftData → in-memory filter (cheap, <100 rows typical).
    3. Delete the `ProjectAlias` row.
    4. Single `ctx.save()`. Returns count of unlinked convs for UI feedback.
  - **`Views/Windows/ProjectsView.swift` (ProjectDetailView):**
    - Header: red `DELETE` button (icon `trash`, red.opacity(0.85), red border).
    - Confirmation dialog: «Delete project "X"? \(N) conversations will become uncategorized. Linked tasks (T) and memories (M) NOT affected.» Destructive button + Cancel.
    - On confirm → `deleteProject(...)` → `onBack()` returns to grid.
  - **`ProjectsView.content`:** `onBack` callback now also triggers `Task { await refresh() }` so deleted cluster disappears from the grid immediately without waiting for next .task fire.
  - **What does NOT happen:** Conversations stay (transcripts intact). TaskItem/UserMemory FK to Conversation untouched. Re-classification: at the next `StructuredGenerator.generate(_:)` (manual REGENERATE in detail view, or on close of new convs) the LLM may re-extract a project for an unlinked conv — that's correct behaviour, lets the user re-categorize naturally.
  - **Files touched:** `Services/Intelligence/ProjectAggregator.swift`, `Views/Windows/ProjectsView.swift`.
  - **Build:** clean. App rebuilt + signed + relaunched.
- ITER-021 — Conversation structured summary + bugfix Quick note (2026-04-25):
  - **Trigger:** user-reported «созвон записывается как Quick note и empty, как посмотреть полную транскрипт, надо его структурировать ещё как-то». DB inspection found 2026-04-25 13:33:07 meeting stuck with 3611-char transcript but title="Quick note" + overview="(empty)" — `backfillPlaceholders()` had only run on app launch, never re-ran.
  - **3 distinct root causes diagnosed (Karpathy):**
    1. **Bug — backfill too narrow:** query was `title == "Quick note"` only, missed `overview == "(empty)"` cases where title was set but LLM call failed.
    2. **Bug — backfill timing:** ran only on launch. If user kept app running while meetings closed during a transient proxy outage, those stayed stuck forever.
    3. **Feature gap — flat overview:** `StructuredGenerator` produced 1-3 sentence prose but no decisions / action items / participants / quotes / next steps; no way to see full transcript ergonomically.
  - **Data model — `Models/Conversation.swift`:** +5 Optional JSON fields:
    - `decisionsJSON` — concrete decisions made (≤5 items, ≤14 words each).
    - `actionItemsJSON` — explicit commitments (display-only — TaskExtractor still creates separate TaskItem rows for the Tasks tab).
    - `participantsJSON` — named people besides the speaker.
    - `keyQuotesJSON` — verbatim memorable lines (≤25 words each).
    - `nextStepsJSON` — forward-looking topics for next meeting.
    - `decisions` / `actionItems` / `participants` / `keyQuotes` / `nextSteps` — computed accessors decoding JSON arrays.
  - **`StructuredGenerator.swift` — 4 layered fixes:**
    1. **System prompt extension** — new ITER-021 section adds 5 fields with strict anti-fabrication rules («empty array better than filler»).
    2. **`StructuredJSON` parser** — 5 new optional `[String]` fields with `key_quotes` / `action_items` / `next_steps` snake_case CodingKeys.
    3. **Writeback** — 5 new fields encoded via `Self.encodeStringArray(_:)` helper which trims, filters empty, returns nil for empty array (UI distinguishes "not extracted" from "explicitly empty").
    4. **`backfillPlaceholders` query expanded** — now matches `title == "Quick note" OR overview == "(empty)"` AND not discarded.
    5. **`startPeriodicBackfill()` / `stopPeriodicBackfill()`** — runs every 30 min via `Task.sleep`. Catches conversations that close while app is running but proxy was briefly down. Cancellable.
    6. **`regenerate(conversationId:)` public** — manual force-retry for the UI button. Resets all 11 LLM-populated fields then calls `generate(_:)`.
  - **NEW `Views/Windows/ConversationDetailView.swift`** — full-screen detail view replacing the previous inline-expand pattern:
    - Header — emoji + title + category/project/source chips + dates + REGENERATE/STAR buttons + overview prose.
    - Tab bar — SUMMARY / TRANSCRIPT / LINKED.
    - SUMMARY — 5 structured sections (decisions/action items/participants/key quotes/next steps), each rendered as Liquid Glass card; empty sections hidden; if all empty → friendly empty-state telling user to click REGENERATE.
    - TRANSCRIPT — full scrollable + selectable text per HistoryItem, time + language stamps, total chars summary.
    - LINKED — pending tasks split MY / WAITING-ON (ITER-013 ownership), memories with headline + content.
    - REGENERATE button calls `structuredGenerator.regenerate(_:)` then reloads; if result still placeholder → surfaces explicit error message.
  - **`ConversationsView.swift`** — replaced inline `expandedDetails` with state-driven push to `ConversationDetailView`:
    - `@State openedDetailId: UUID?` — when non-nil, list swaps for detail view + BACK button.
    - Row tap → set `openedDetailId = conv.id`. No more confusing toggle behaviour.
    - Added `chevron.right` affordance on every row so users know it's clickable.
    - Old `expandedDetails / linkedTranscripts / linkedTasks / linkedMemories` helpers retained as dead code (referenced by future quick-peek feature, deferred to v2).
  - **`AppDelegate.swift`** — wired `startPeriodicBackfill()` after the launch backfill task.
  - **Verified post-deploy:** stuck conversation 2026-04-25 13:33 was rewritten by backfill within ~25s of relaunch — title now "Team Discusses Content Manager" + overview real prose. 6 action_items, 2 decisions, 2 participants populated across recent conversations on first sweep. Schema columns confirmed via `PRAGMA table_info`.
  - **Files touched:** `Models/Conversation.swift`, `Services/Intelligence/StructuredGenerator.swift`, `Views/Windows/ConversationDetailView.swift` (NEW), `Views/Windows/ConversationsView.swift`, `App/AppDelegate.swift`.
  - **Build:** clean (3 pre-existing warnings only).
  - **Deferred to v2:** quick-peek inline expand on option-click; per-section regenerate; export to Markdown; full-text transcript search.
- 2026-04-25 — Dashboard freeze fix + adaptive layout + old-build diagnostic:
  - **Diagnostic context (Karpathy top-down + bottom-up):**
    - User reported «дашборд жестко зависает + ничего не вижу из мемориес/тасков». Two distinct problems revealed by investigation.
    - **Old build running:** `/Users/android/Applications/MetaWhisp.app` was the 22-Apr binary (pre-Phase 5 G1, pre-ITER-013-017). DB had **3539 history, 19 memories, 100 tasks, 3674 screen contexts, 52 conversations** — data was fine, exe was stale. Killed via `./build.sh` rebuild + reinstall + relaunch.
    - **SwiftData migration succeeded** on first launch of fresh build: ZGOAL, ZAUDITLOG, ZPROJECTALIAS tables added; ZASSIGNEE, ZPRIMARYPROJECT, ZTOPICSJSON, ZTOOLCALLIDNATIVE etc. columns added to existing tables. Lightweight migration (all-Optional fields) worked. DB backup: `MetaWhisp.store.backup-2026-04-25` (16.2 MB).
    - Backfill kicked off automatically: ITER-011 conversation embeddings (52/52 immediate, all had been embedded earlier session by old build), ITER-014 project classification (4 → 14 → ... rolling, ~5 min for 52 convs at 300ms LLM gap), ITER-013 task assignee (won't backfill — only new tasks get assignee from new prompt).
  - **Dashboard freeze (98.9% main-thread CPU on idle):** Sample profiler caught:
    ```
    StatisticsView.body → wpm.getter → stats → PeriodStats.init
    → TextAnalyzer.fillerCount → fillerWords → String.range(of:)
    ```
    1187/1567 main-thread samples in `_stringCompareInternal`.
    - **Root cause:** `PeriodStats.init` called `TextAnalyzer.fillerCount(in: items.map(\.text).joined(separator: " "))` on EVERY render. With 3500+ history items × avg 50 chars = ~177KB string scanned through filler-word list with `String.range(of:)` for each filler — **multi-million Unicode comparisons per render frame**. SwiftUI re-evaluates every computed prop (`wpm`, `stats`, etc.) on every render, so even a single state change re-triggered the whole scan.
    - **Fix v1 — drop `fillerPct` from `PeriodStats.init`:** removed the heavy `fillerCount` call from the hot path. The single consumer (`sharePeriodStats`) recomputes percentage on-demand from the already-async-cached `fillersCache: [(word, count)]` — `fillersCache.reduce(0) { $0 + $1.count }`.
    - **Fix v2 — cache ALL Calendar-heavy derived stats:** sample after fix v1 showed `bestDay`, `peakWordsDay`, `longestStreak`, `popularHour`, `streakDays` still doing per-render Calendar.startOfDay scans of 3500+ items. Introduced `DerivedStats` struct + `@State var derivedCache: DerivedStats` populated by `recomputeDerivedStats() async` running on `Task.detached(priority: .utility)`. The 5 expensive computed props now read from cache; getters return `.empty` defaults until first compute completes.
    - **Fix v3 — pre-filter `current`/`previous`:** `currentCache`/`previousCache` populated by `recomputeFilteredItems()` so body doesn't re-run `selectedPeriod.filter(allItems)` per frame.
    - **Result:** CPU 98.9% → 73% (active backfill + initial render) → **0.0% idle**. Freeze gone.
  - **Adaptive Dashboard layout:** original `HStack(DailySummaryCard, [TodayStatsCard|ScreenActivityCard].frame(width: 280))` clipped the right column when window was < ~700pt. Wrapped body in `GeometryReader`; threshold `twoColumnThreshold = 720`:
    - Wide → 2-column (current behavior, no clip).
    - Narrow → single-column stack (DailySummaryCard full-width above; TodayStatsCard + ScreenActivityCard stack below, side-by-side at ≥480pt or stacked further at < 480pt).
    - Title + statusStrip same adaptive treatment.
  - **Files touched:** `Views/Components/StatComponents.swift` (drop fillerPct from PeriodStats), `Views/Windows/StatisticsView.swift` (DerivedStats cache + recomputeDerivedStats + filter cache + getter redirects + dead legacy removal), `Views/Windows/DashboardView.swift` (GeometryReader + adaptive single/multi-column layout).
  - **Build:** clean. `.app` rebuilt + reinstalled to `/Users/android/Applications/MetaWhisp.app` + signed + launched.
- ITER-017 v3 — Search tools + auto-execute read-only + bounded agentic loop:
  - **Goal:** превратить chat из «угадай UUID или копируй вручную» в реальный agent. Юзер: «убери задачу про Майка» → LLM сам делает `searchTasks(query="Майк")` → получает list → выбирает right id → вызывает `dismissTask` → confirm → execute. Поднимает usability на порядок.
  - **3 read-only tools** (`Services/Intelligence/ChatToolExecutor.swift`):
    - `searchTasks(query, limit?)` — top-N matching task items.
    - `searchMemories(query, limit?)` — matching user_facts.
    - `searchConversations(query, limit?)` — matching past meetings/dictations.
    - All return JSON `{items: [...], count: N}` в `ExecResult.summary` (LLM парсит из tool_result content).
  - **`isReadOnly(_:)` + `readOnlyTools` Set** — узкий whitelist. Read-only tools:
    - **auto-execute без confirm** (нет mutation = нет рисков),
    - **bypass rate-limit** (read не вредит),
    - **не пишутся в AuditLog** (нет snapshot — undo нерелевантно),
    - **не имеют валидации** (любой query валиден).
  - **`executeReadOnly(_:) async -> ExecResult`** — отдельный path в `ChatToolExecutor`, async (для embedding fetch).
  - **`rankByQuery` generic helper** — semantic ranking когда есть `embeddingService` + Pro license:
    - Embed query → cosine vs item embeddings → top-N.
    - Fallback: substring/keyword token-overlap match (когда нет embedding'а или non-Pro).
    - Threshold: items с zero matches фильтруются (substring path).
  - **`ChatToolExecutor.configure` signature update:** `+embeddingService: EmbeddingService? = nil`.
  - **Bounded agentic loop — `ChatService.runAgenticLoop(userPrompt:licenseKey:maxRounds:)`:**
    - Local `messages: [[String: Any]]` array, начинается с `[{role:"user", content:userPrompt}]`.
    - Each round: `callProChatWithTools(...)`. Branches:
      - text only → loop ends, return text.
      - read-only tool_call → `executor.executeReadOnly(call)` → append `{role:"assistant", tool_calls:[…]}` + `{role:"tool", tool_call_id, content: result.summary}` → continue loop.
      - mutation tool_call → loop ends, return `pendingMutation` (handed off to existing confirm flow).
    - Hard cap `maxRounds = 5`. На превышении → возвращаем accumulated text + soft note "Cap reached — pause and let me know if you want to continue."
    - `AgenticOutcome { text, pendingMutation, roundsUsed }` — структурированный результат, лог `[ChatService] loop done rounds=3 text=128 pending=dismissTask`.
  - **`ChatService.send`** теперь вызывает `runAgenticLoop` для Pro path вместо одиночного `callProChatWithTools`. Non-Pro path unchanged (regex без loop).
  - **AppDelegate:** `chatToolExecutor.configure(modelContainer, embeddingService: embeddingService)` — wire'ит embeddings для semantic search.
  - **System prompt update:**
    - Новая READ-ONLY секция в `<available_tools>` с описанием 3 search'ей.
    - Tool-use rules расширены: «search encouraged whenever you need an id; id MUST come from context OR prior search result; if search returns 0 → say so plainly».
    - Mutation rules unchanged (explicit verb only, no bulk, no invented UUIDs).
  - **User stories (now possible):**
    - «убери задачу про Майка» → searchTasks → 2 results → LLM picks best match → dismissTask → confirm → execute → followup (ITER-017 v2).
    - «найди мои memories про Overchat» → searchMemories → text response с listing.
    - «о чём говорили в звонке про цены?» → searchConversations → returns top match → LLM quotes overview.
    - «забудь что я работаю в X» → searchMemories(query="X work") → dismissMemory → confirm.
  - **Files touched:** `Services/Intelligence/ChatToolExecutor.swift`, `Services/Intelligence/ChatService.swift`, `App/AppDelegate.swift`.
  - **Build:** clean.
  - **Risks (live-test):**
    - Loop cap 5 — если LLM зацикливается на search'ах, lo-fi degradation.
    - Search query LLM может generate'нуть слишком общий ("задача") → много results → LLM теряется. Решение в v4 — instruct LLM писать SPECIFIC queries (имя/проект/глагол).
    - Cost: каждый round = LLM round-trip + (для Pro) embedding round-trip. 5 rounds = до 10 API calls. Пока приемлемо при cap 5.
- ITER-017 v2 — Multi-step agentic loop (followup after tool execute):
  - **Goal:** превратить native tool-use из «one-shot» в нормальный agent-style flow. После confirm и execute LLM получает `tool_result` обратно через `{role:"tool"}` сообщение и может (а) дать осмысленный followup ("Готово, убрал. Что-то ещё?"), либо (б) вызвать ещё один tool — который снова уйдёт в confirm. Бесконечного loop пока нет (v3).
  - **Why minimum-surgical:** не делал full agent loop с auto-execute read-only search tools. Это даёт 80% value (LLM знает что tool сработал) at 30% complexity. Search-and-act цепочки — следующая итерация.
  - **Data model — `Models/ChatMessage.swift`:**
    - `+toolCallIdNative: String?` — native `tool_call_id` из Groq response. Нужен чтобы связать этот assistant turn с матчинговым `{role:"tool", tool_call_id:...}` ответом. Nil для legacy regex path (там нет native id).
    - `+originatingUserPrompt: String?` — persisted ON the assistant message (не пересобираем prompt в continuation, потому что retrieval blocks могли drift'нуть между ходами и LLM должен видеть ТОТ ЖЕ контекст).
    - `+followupOfMessageId: UUID?` — parent link для chain-rendering и chain-builder walk-back.
  - **`ChatToolExecutor.ToolCall`:** `+let id: String?` — native id, опциональное (regex path → nil → multi-step disabled для них).
  - **`parseNativeToolCall`** теперь захватывает `id` из first array element. `parseToolCall` (regex) → id = nil.
  - **`encodeToolCall` / `decodeToolCall`** roundtrip-ят native id через `pendingToolCallJSON` JSON, чтобы после restart confirmTool всё ещё знал correct id.
  - **`ChatService.send`:** при создании assistant message с pending tool — стора native call.id и full userPrompt в новых полях. Лог: `[ChatService] ✅ Got response (X chars, pendingTool=…, nativeId=call_abc123)`.
  - **`ChatService.confirmTool`:** после execute, если у нас есть native id + originating prompt + успех → fire-and-forget `Task` вызывает `continueAfterToolExecution(...)`.
  - **NEW `continueAfterToolExecution(parentMessageId:toolCall:toolResult:)`:**
    - Перечитывает parent assistant message из DB (для freshness — undo мог его поменять).
    - Билдит 3-message conversation: `user → assistant_with_tool_calls → tool_result`.
    - Вызывает `callProChatWithTools` round 2 с теми же `toolSchemas`.
    - Response branch:
      - text only → insert новый ChatMessage(text) с `followupOfMessageId = parent`.
      - text + ещё один tool_call → insert новый ChatMessage с pending state (юзер confirm'ит ещё раз; цикл стопается). Native id и originatingUserPrompt пробрасываются на followup тоже, чтобы chain мог продолжаться рекурсивно.
      - empty text + no tool → не вставляем ничего (LLM нечего добавить).
    - Errors грейсфул-логируются, не affect parent message.
  - **Какие User Stories теперь работают (примеры):**
    - «убери задачу X» → confirm → ✓ Dismissed task X → followup AI: «Убрал. Осталось Y задач, могу что-то ещё?»
    - «отметь сделанной задачу про деплой» → confirm → ✓ Marked done → followup: «Отлично, Shipped count за сегодня вырос до 4».
    - LLM может ОТКАЗАТЬСЯ продолжать (просто не вернёт followup) — это OK, мы insert'им nothing.
  - **Что НЕ работает в v1 (deferred to v3):**
    - Search tools (`searchTasks` / `searchMemories`) — без них «найди и убери таску про Майка» всё ещё требует точного UUID. Юзер должен сам сослаться на конкретный item из контекста.
    - Auto-execute read-only tools без confirm — следующий шаг.
    - Бесконечный loop с лимитом rounds — сейчас strictly 1 followup per confirm.
  - **Files touched:** `Models/ChatMessage.swift`, `Services/Intelligence/ChatToolExecutor.swift`, `Services/Intelligence/ChatService.swift`.
  - **Build:** clean (3 pre-existing warnings).
- ITER-017 — Native tool-use API + Proactive chip hover-extension:
  - **Goal A (Native tool-use):** перевести Pro-path с фрагильного `<tool_call>` regex на структурированный native function-calling protocol (Groq OpenAI-compatible API). Reliable parsing + готов к multi-step агентским паттернам в v2.
  - **Goal B (Hover-extension):** chip перестаёт исчезать пока курсор над ним — юзер успевает прочитать длинные memories.

  ### Native tool-use (Goal A)

  - **Backend — `api/src/index.js`:**
    - NEW `/api/pro/chat-with-tools` endpoint via `handleProChatWithTools(request, env)`.
    - Body: `{system, messages, tools, max_tokens?, temperature?}`. `tools` empty → plain chat без function-calling. Non-empty → `tool_choice: "auto"` + Groq parses tool_calls.
    - Response: `{text, tool_calls, finish_reason}`. Forwards Groq response verbatim для structured parsing на клиенте.
    - Validation: системный prompt required, messages array required (>= 1), tools required (`[]` ok). Payload soft cap 64000 chars.
    - Same Groq Llama-3.3-70b-versatile backend как `/advice` (no SDK switch).
    - **Deployed** to `api.metawhisp.com` через `wrangler deploy`. Smoke-test: `curl ... -d '{...fake auth...}'` → returns 401 invalid license, доказывая endpoint reachable + JSON parsing OK.
  - **Tool schemas — `Services/Intelligence/ChatToolExecutor.swift`:**
    - NEW static `toolSchemas: [[String: Any]]` — массив 6 OpenAI function schemas (dismissTask / completeTask / dismissMemory / updateGoalProgress / addTask / addMemory). Каждая: name, description (тщательно сформулировано чтобы Groq tool_choice="auto" корректно выбирал), parameters JSON Schema, required fields.
    - NEW static `parseNativeToolCall(from: [[String: Any]]?) -> ToolCall?` — извлекает первый element из `tool_calls` array, парсит nested `function.arguments` (JSON-encoded string в Groq response).
  - **Client transport — `Services/Intelligence/ChatService.swift`:**
    - NEW `NativeChatResponse` struct: `text, toolCall, finishReason`.
    - NEW `callProChatWithTools(system:messages:tools:licenseKey:)` — POSTs to `/api/pro/chat-with-tools`, parses response. 60s timeout, error includes HTTP code + body snippet.
    - NEW `buildNativeMessages(userPrompt:history:)` — v1 returns `[{role:"user", content: userPrompt}]`. История уже в `<previous_messages>` блоке внутри userPrompt — не дублируем. Multi-turn (v2 deferred) добавит `{role:"tool", tool_call_id:..., content:...}` после execute.
    - **`send(...)` rewrite:** Pro path → native tool-use. Non-Pro path → старый regex `<tool_call>` (backward compat, без backend dependency).
      - Унифицировано: оба пути собирают `nativeToolCall: ToolCall?` → одинаковая validate/queue логика → одинаковый pending-bubble UX.
      - Лог: `[ChatService] native finish=tool_calls text=0 toolCall=dismissTask` для diagnostic.
  - **Что лучше становится сразу:**
    - LLM не может «забыть» закрыть тег / вернуть broken JSON (теперь structured parsing).
    - Меньше промпт-инжиниринга: `<available_tools>` блок в system prompt можно ужать (deferred — оставил как есть пока, structured tool_choice="auto" работает с обоими instruction styles).
    - Финиш-reason `tool_calls` явно отделён от `stop` — UI/logging видит intent.
  - **Что НЕ делал в v1 (deferred to ITER-017 v2):**
    - Multi-step agentic loop (после execute → push tool_result в messages → продолжить inference). Сейчас один inference per send. Хочется когда юзер пишет «найди и убери таску про Майка» — LLM сделает search → dismiss с правильным id.
    - Settings toggle `useNativeToolCalling` — пока всегда native для Pro. Вынесем как opt-out если Groq косячит.

  ### Hover-extension (Goal B)

  - **Files:** `Views/Proactive/ProactiveChipView.swift` + `Views/Proactive/ProactiveChipWindow.swift`.
  - **`ProactiveChipView`:** `+onHoverChange: ((Bool) -> Void)?` callback, `.onHover { ... onHoverChange?($0) }` пробрасывает enter/exit наверх.
  - **`ProactiveChipWindow`:** `+handleHoverChange(_:)`. Enter → cancel `fadeTask`. Exit → `armFadeTimer()` (re-arm полным `visibleSeconds` окном, не leftover).
  - Семантика: пока курсор НА chip — таймер заморожен. Когда уходишь — стартует свежее 8s окно. Удобно если юзер случайно навёлся, потом ушёл — ещё успеет глянуть.

  - **Build:** clean (3 pre-existing unrelated warnings).
- ITER-016 v2 — Tool-calling polish: undo + rate-limit + audit log:
  - **Goal:** перевести client-side tool-calling из v1 «best effort» в production-grade. Undo для recovery от ошибочных confirm'ов, rate-limit от runaway loops, audit log для review «что AI сделал сегодня».
  - **Undo (in-bubble button):**
    - Каждая успешная execute() сохраняет PRE-MUTATION snapshot в `AuditLog.snapshotJSON` (минимально для revert: e.g. dismissTask → `{taskId, wasIsDismissed, wasStatus}`).
    - Окно 60s от момента execute (не LLM-ответа) — `ChatMessage.toolExecutedAt` set'ится при confirm.
    - UI: inline UNDO button в outcome-bubble, рендер обёрнут в `TimelineView(.periodic(by: 5))` чтобы кнопка автоматом исчезала по истечении окна без манипуляций юзера.
    - Click → `ChatService.undoTool(messageId:)` → `ChatToolExecutor.undo(auditId:)` → restore из snapshot, audit row помечается `undone = true` (append-only — не удаляем).
    - Refused undo (expired / already done / failed action) — surface'им reason в bubble (`✗ Already undone`, etc.).
  - **Rate limit:**
    - In-memory rolling window (60s, max 5 mutations) в `ChatToolExecutor.recentExecutionTimestamps`.
    - Проверка ДО side-effect, отказ с человеко-читаемым summary `Rate-limited (max 5 actions per minute)`.
    - Rejected attempts ВСЁ РАВНО audit'ятся (success: false) — для review «AI пытался спамить».
  - **Audit log (`Models/AuditLog.swift` NEW @Model):**
    - Поля: `id, timestamp, tool, argsJSON, resultSummary, success, snapshotJSON, undone, chatMessageId`.
    - Append-only: ни одной DELETE / mutate операции после insert (только `undone` flip).
    - Schema добавлен в `HistoryService` (main + in-memory fallback).
    - Static `AuditLog.undoWindowSeconds = 60` + computed `isUndoable: Bool` инкапсулируют политику.
  - **ChatToolExecutor signature:**
    - `execute(_ call: ToolCall, chatMessageId: UUID? = nil) -> ExecResult` — chatMessageId binds audit row к сообщению для UI undo lookup.
    - `ExecResult(ok, summary, auditId)` — auditId доступен caller'у для прямой ссылки.
    - `undo(auditId:)`, `auditEntry(forChatMessage:)` — публичный API для ChatService.
    - Helpers: `writeAudit`, `encodeSnapshot`, `decodeSnapshot` (JSONSerialization-based, толерантны к heterogeneous values).
  - **Files:** `Models/AuditLog.swift` (NEW), `Models/ChatMessage.swift` (+toolExecutedAt), `Services/Data/HistoryService.swift` (+AuditLog в schema), `Services/Intelligence/ChatToolExecutor.swift` (rate-limit + audit + snapshot + undo для всех 6 tools), `Services/Intelligence/ChatService.swift` (+undoTool, передаёт chatMessageId в execute), `Views/Windows/ChatView.swift` (UNDO button + TimelineView wrapper + undoVisible helper).
  - **Build:** clean.
  - **Что НЕ покрыл (deferred to v3):**
    - Audit View (отдельный экран «история действий AI») — данные есть в DB, UI ждёт.
    - Bulk undo (revert всех мутаций сессии) — обычно overkill, на запрос.
    - Native Anthropic tool-use API (вместо `<tool_call>` regex) — будет ITER-017 когда backend extend.
- ITER-015 — Proactive in-the-moment surfacing (peripheral chip в углу экрана):
  - **Goal:** пока юзер отвечает в Slack/Mail/Notion → в правом верхнем углу тихо появляется chip с 2-3 relevant memories / past decisions / waiting-on tasks. НЕ нотиф, НЕ sound, НЕ воровство фокуса. 8s auto-fade, click item → MetaChat с pre-filled query.
  - **Design decisions (Karpathy-style, explicit):**
    - Opt-in (feature off by default, high wow → high annoyance risk).
    - Whitelist-based composing-intent detection (not classifier) — короткий список апок (Slack/Mail/Messages/Notion/Linear/Figma/Obsidian/Outlook/Discord/Telegram/Loom/Spark/Airmail/Superhuman). Tighter than blacklist, ~zero false-positives.
    - Relevance threshold 0.55 cosine — лучше пустой чип чем шум.
    - Cooldown 5 мин default — никогда не spammy.
    - Sensitive-app blacklist в Settings (1Password / Keychain / Terminal / iTerm / Activity Monitor / System Settings default).
    - Min 80 chars OCR — маленькие окна не триггерят.
    - Chip — borderless `NSPanel` + `.nonactivatingPanel` stylemask + override `canBecomeKey/Main → false` (non-activating). User's frontmost app НЕ теряет фокус.
    - `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]` — чип виден на любом Space + поверх fullscreen.
  - **Files:**
    - `Services/Intelligence/ProactiveContextService.swift` (NEW) — основной пайп. `onNewContext(_:)` → gates → embed query → rank 3 types параллельно → threshold filter → top-3 → `ProactiveChipWindow.shared.show(...)`.
      - 3 retrievers: `rankedMemories` (все UserMemory с embedding'ом, cosine filter), `rankedConversations` (все Conversation с embedding'ом), `rankedWaitingTasks` (boost: только waiting-on tasks где имя assignee встречается в current OCR — когда ты пишешь Васе, напомнит что он должен).
      - SurfaceItem DTO с kind/title/subtitle/relevance/tapAction.
    - `Views/Proactive/ProactiveChipWindow.swift` (NEW) — `NonActivatingPanel` subclass + singleton controller. `show(items:source:)`, `hide()`, auto-fade Task (8s), positionTopRight.
    - `Views/Proactive/ProactiveChipView.swift` (NEW) — SwiftUI content. CONTEXT header + dismiss (×) + item rows (icon+title+subtitle). `.thinMaterial` glass + shadow.
    - `Models/AppSettings.swift` — `+proactiveEnabled`, `+proactiveCooldownMinutes` (default 5), `+proactiveBlacklist` (default "1Password,Keychain Access,Terminal,iTerm,Activity Monitor,System Settings").
    - `Views/Windows/MainSettingsView.swift` — NEW `proactiveSection` под screen-context в Integrations tab. Toggle + cooldown slider (1-30) + blacklist textfield + warning если Screen Context off.
    - `App/AppDelegate.swift` — `+let proactiveContextService`, configure с embeddingService, `screenContext.onContextPersisted` ветка зовёт `proactiveContextService.onNewContext(ctx)` после `realtimeScreenReactor.react`.
    - `Views/Windows/ChatView.swift` — `.onReceive(.proactivePrefillChat)` pre-fills input text когда chip item тапнут.
  - **Tap action:** `SurfaceTapAction.openChat(query:)` — chip скрывается, открывается MetaChat, через новый `Notification.Name.proactivePrefillChat` ChatView получает заготовленный вопрос типа `"Напомни что я жду от Паша"` / `"Расскажи про созвон \"Q2 budget sync\""`.
  - **Build:** clean (только pre-existing Sendable warning в MainWindowController, не от этой фичи).
  - **Risks (live-test):**
    - **Privacy:** OCR первых 1500 chars улетает в Pro-proxy для embedding'а. Opt-in + blacklist + cooldown снижают expose. В Settings явный дисклеймер не помешал бы (v2 todo).
    - **Composing-intent heuristic** не распознает непопулярные мессенджеры — добавятся в whitelist по фидбеку.
    - **NSPanel + level .statusBar + Chrome/tier-"read"** — на тиер-read браузерах клики должны работать потому что chip — OUR window (не их), но live-test подтвердит.
    - **Hover-extension** визуального таймера не реализован в v1 — чип жёстко 8s. Mouse-enter extends — это v2.
    - Пустой DB (Pro user без накопленных memories / conversations) → retrieval вернёт []  → chip никогда не покажется. Правильное поведение.
- ITER-016 — Conversational mutation v1 (client-side tool-calling без backend extend):
  - **Goal:** убрать hallucination ("убрано" когда не убрано) — дать MetaChat реально мутировать данные. Юзер пишет «убери задачу X» → confirm bubble → execute → видит результат.
  - **Approach:** client-side tool-call через structured JSON в тексте (`<tool_call>{"tool":"…","args":{…}}</tool_call>`). Pro-proxy не трогаем. Upgrade path: замена парсера на native Anthropic/OpenAI tools дропином.
  - **Tools (6 в v1):** dismissTask, completeTask, dismissMemory, updateGoalProgress, addTask, addMemory. Каждая — validate → confirm UI → execute → result.
  - **Data model — `Models/ChatMessage.swift`:** `+pendingToolCallJSON: String?`, `+pendingToolPreview: String?`, `+toolResultSummary: String?`. Optional → SwiftData lightweight migration. Pending ≠ nil → UI рисует confirm bubble. toolResultSummary ≠ nil → бабл в resolved state с outcome line.
  - **New service — `Services/Intelligence/ChatToolExecutor.swift` (NEW):**
    - `ToolCall` struct + `parseToolCall(from:)` (regex extract `<tool_call>…</tool_call>`).
    - `validate(_:) -> Result<String, ToolError>` — pre-flight (target exists + not already in state). Возвращает preview string типа `"Dismiss task \"Reply to Mike\""` для confirm UI.
    - `execute(_:) -> ExecResult` — actual SwiftData mutation + human-readable summary для followup bubble.
    - 6 tools полноценно implemented, с нормализацией args (dueAt ISO, assignee capitalization, etc.).
  - **ChatService изменения:**
    - `+weak var toolExecutor: ChatToolExecutor?`
    - В `send()` после LLM response: parseToolCall → если найден → validate → success → save message в PENDING state (strip `<tool_call>` из displayed text, set preview). Если validate fails → показать inline ошибку в тексте, no confirm.
    - `confirmTool(messageId:)` / `cancelTool(messageId:)` API — вызываются из UI buttons. Confirm → execute → flip message в resolved state.
    - TTS skipped для pending messages (юзер должен прочитать confirm).
    - IDs теперь ПРОБРАСЫВАЮТСЯ в prompt — `<my_tasks>/<waiting_on>/<user_facts>/<active_goals>` каждая строка префиксится `[id:<uuid>]` / `[<uuid>]` чтобы LLM мог референсить в tool_call.
  - **System prompt rewrite — ChatService.swift:**
    - `<capabilities>` переосмыслен: YOU CAN → добавлен «CALL TOOLS на explicit action». YOU STILL CANNOT: web, DMs, multi-tool, unasked deletes.
    - Новый блок `<available_tools>` с schema всех 6 tools + strict rules: explicit verb only, no bulk, no invented UUIDs, ask-before-ambiguous, no self-confirmation (UI handles).
  - **UI — `Views/Windows/ChatView.swift`:**
    - messageRow: если `pendingToolPreview != nil && pendingToolCallJSON != nil` → рендер preview + [YES, DO IT] / [CANCEL] buttons.
    - Если `toolResultSummary != nil` (уже execute'нут) → показать outcome line (`✓ …` зеленоватый или `✗ …` красный) вместо кнопок.
    - Кнопки вызывают `AppDelegate.shared?.chatService.confirmTool(messageId:)` / `cancelTool(messageId:)`.
  - **AppDelegate wiring:** `+let chatToolExecutor = ChatToolExecutor()`, configure + `chatService.toolExecutor = chatToolExecutor`.
  - **Files touched:** `Models/ChatMessage.swift`, `Services/Intelligence/ChatToolExecutor.swift` (NEW), `Services/Intelligence/ChatService.swift`, `Views/Windows/ChatView.swift`, `App/AppDelegate.swift`.
  - **Build:** clean (3 pre-existing warnings).
  - **v2 deferred (следующая сессия):** undo toast (10s window + snapshot), per-session rate-limit (max 5 mutations/min), `Models/AuditLog.swift` (append-only `{timestamp, tool, argsJSON, resultJSON}` для audit review), switch на native tool-use API когда backend extend.
  - **Risks (live-test):**
    - LLM может вырезать `<tool_call>` частично (broken JSON) → parser возвращает nil → chat показывает raw text. Acceptable fallback.
    - LLM может галлюцинировать UUID не из контекста → validate возвращает notFound → surface "Not found: abc123…". No mutation.
    - Edge: user пишет «убери таску» не указав конкретную → LLM по правилу 4 должен clarify в plain text, не tool_call. Зависит от LLM following rules.
- ITER-014 — Topic / project auto-clustering (Projects tab + MetaChat world map):
  - **Goal:** превратить плоский список созвонов в Projects-view с auto-detected кластерами. MetaChat получает `<active_projects>` блок чтобы отвечать «что у меня с Overchat» точно.
  - **Approach:** не k-means по embeddings (слепые кластеры без имён). Вместо — explicit label от LLM на close + merge aliases через centroid embeddings.
  - **Data model:**
    - `Models/Conversation.swift` — `+var primaryProject: String?`, `+var topicsJSON: String?` (JSON `[String]`). Оба Optional → SwiftData lightweight migration.
    - `Models/ProjectAlias.swift` — NEW @Model. `canonicalName`, `aliasesJSON` (включает canonical), `centroidEmbedding: Data?`. Helper `addAlias(_:)` с case-insensitive dedup.
    - `Services/Data/HistoryService.swift` — schema list включает `ProjectAlias.self` в обоих местах (main + in-memory fallback).
  - **Prompt — `Services/Intelligence/StructuredGenerator.swift`:**
    - Добавлены PROJECT и TOPICS секции с критериями («most concrete recurring entity, not category»). Ru/en примеры GOOD/BAD.
    - JSON schema `+"project": "..."|null, "topics": [...]`.
    - Parser `StructuredJSON` — оба поля optional (graceful downgrade для старых промптов).
    - Writeback в Conversation: тримит `project`, лёйтерит к lowercase + фильтрует empty topics.
  - **Service — `Services/Intelligence/ProjectAggregator.swift` (NEW):**
    - `listProjects() -> [ProjectSummary]` — агрегирует raw `Conversation.primaryProject` через raw→canonical map из `ProjectAlias`; считает linked tasks (my vs waiting-on) + memories + last activity + members (assignees от ITER-013).
    - `details(for: canonical) -> ProjectDetails` — выдаёт конкретные conversations + tasks + memories для detail view.
    - `resolveCanonical(_:)` — cheap path: exact-match case-insensitive across all aliases → reuse. Miss → новый `ProjectAlias`.
    - `backfillProjects(structuredGenerator:)` — re-run structured-gen для legacy `primaryProject == nil && status == "completed"` convs; seeds `ProjectAlias` через resolveCanonical. 300ms пауза между вызовами чтобы не DDOSить proxy.
    - `mergeAliases()` — periodic embedding-similarity pass: обновляет centroid на базе conv embeddings; пары с `cosine ≥ 0.88` мёрджатся (smaller → larger). Threshold 0.88 (looser чем dedup'овский 0.92 потому что project names короткие и контекст шире).
  - **UI — `Views/Windows/ProjectsView.swift` (NEW):**
    - Grid карточек (adaptive 280-360px), click → inline detail view.
    - Карточка: canonical name, counts (tasks/done/memories/conversations), relative last-activity, top members (assignees). REFRESH button.
    - Detail view — back button + 3 секции: CONVERSATIONS (emoji + title + overview), PENDING TASKS (description + «waiting on X»), KEY MEMORIES (headline + content).
    - EnvironmentObject(ProjectAggregator) через `MainWindowController.open(projectAggregator:)`.
  - **MainWindowView — `Views/Windows/MainWindowView.swift`:**
    - `SidebarTab.projects` (icon `folder.badge.person.crop`) между Library и Goals.
    - Routing в `detailContent` → ProjectsView().
  - **AppDelegate wiring:**
    - `let projectAggregator = ProjectAggregator()` + `configure(modelContainer:)`.
    - `structuredGenerator.projectAggregator = projectAggregator` — eager seed alias row на close.
    - `chatService.projectAggregator = projectAggregator` — listProjects() в send().
    - `mainWindow.open(..., projectAggregator:)` — прокидывает EnvironmentObject.
    - Launch task (15s delay, после embeddings backfill): `backfillProjects(structuredGenerator:)` → `mergeAliases()`.
  - **MetaChat — `Services/Intelligence/ChatService.swift`:**
    - `activeProjects = projectAggregator?.listProjects().prefix(8)` в send() → prompt block `<active_projects>`.
    - Render: `- Overchat (7 conv, 3 pending, 2 memories, last: 2d ago) · with: Pasha, Andrey`.
    - System prompt: `<task>` list расширен, `<active_projects>` упомянут в GROUND TRUTH, fallback-empty rule, PROJECTS routing rule усилен («START from <active_projects>»).
    - `buildUserPrompt` signature: `+projects: [ProjectSummary]`.
  - **Files touched:** `Models/Conversation.swift`, `Models/ProjectAlias.swift` (NEW), `Services/Data/HistoryService.swift`, `Services/Intelligence/StructuredGenerator.swift`, `Services/Intelligence/ProjectAggregator.swift` (NEW), `Views/Windows/ProjectsView.swift` (NEW), `Views/Windows/MainWindowView.swift`, `Views/Windows/MainWindowController.swift`, `App/AppDelegate.swift`, `Services/Intelligence/ChatService.swift`.
  - **Build:** clean (3 pre-existing warnings).
  - **Risks (live-test):**
    - Backfill cost: 100-500 LLM вызовов для юзера с существующей базой. Pro proxy ~$0.25 на 500 convs. Batched sequentially с 300ms паузой → ~5 мин на 500. Не блокирует UI.
    - Merge threshold 0.88: может ложно слить «Overchat» + «Overmind» (семантически близкие короткие имена). Митигация — manual override в v2 (эта фича не в скоупе).
    - `primaryProject` остаётся raw (не canonical) в `Conversation` — это audit trail. Canonical resolve только на read-path. Если alias row удалят, conversations не потеряются.
- ITER-013 — Action Items с owners (My / Waiting-on split):
  - **Goal:** разделить «что Я должен сделать» от «что мне должны». PM-style, два списка вместо одной кучи. Меняет фундаментальное правило старого extractor'а («только мои таски» — class C+ → SKIP).
  - **Data model — `Models/TaskItem.swift`:** `+var assignee: String?` (Optional → SwiftData lightweight migration). `nil` = MY task, non-empty = WAITING-ON owner. `+var isMyTask: Bool` computed для удобства филтрации в UI.
  - **Prompt rewrite — `Services/Intelligence/TaskExtractor.swift`:**
    - Заменил USER-IS-SUBJECT CHECK на OWNERSHIP CLASSIFICATION (3 класса A/B/C):
      - A — user is subject → assignee = null (MY)
      - B — explicit delegation OR user co-committed in "мы" → assignee = "<Name>" (WAITING-ON)
      - C — bare third-party mention with no link to user → SKIP (drops from output)
    - Добавлены примеры для русского + английского по каждому классу.
    - WORKFLOW обновлён (step 3 теперь classify, step 4 — назначить assignee).
    - JSON schema: `+ "assignee": "<Name>"|null` поле в каждой таске.
    - Parser нормализует assignee: trim + capitalize first letter, "null"/empty/whitespace → nil.
  - **UI — `Views/Windows/TasksView.swift`:**
    - `+var myTasks: [TaskItem]` + `+var waitingOnGroups: [(name, items)]` (groupБy assignee, sort by group size desc, tiebreak alphabetically).
    - Render — две новые секции внутри committed списка: «MY TASKS» сверху, потом «WAITING ON <NAME>» по группам.
    - `ownershipSectionHeader(label:count:)` — компактный uppercase-mono divider с counter chip.
    - Staged bin не трогается, остаётся отдельной REVIEW секцией.
  - **MetaChat — `Services/Intelligence/ChatService.swift`:**
    - `fetchPendingTasksForQuery` теперь возвращает `PendingTaskBundle { myTasks, waitingOn }` вместо `[String]`. Ranking всё ещё единый по relevance — partition в bundle ПОСЛЕ ранкинга, чтобы top-K приходил из самого релевантного среза.
    - Старый блок `<pending_tasks>` разделён на `<my_tasks>` + `<waiting_on>` (с группировкой по имени).
    - `buildUserPrompt` сигнатура обновлена (`tasks: PendingTaskBundle`).
    - System prompt: новое правило «TASKS — MY vs WAITING-ON» с ru/en примерами; GROUND TRUTH RULE и LANGUAGE RULE обновлены ссылаться на 2 новых блока.
  - **Backfill:** не нужен. Existing rows имеют `assignee == nil` → автоматически становятся MY tasks (корректно — старый extractor скипал не-юзер-таски).
  - **Other extractors (ScreenExtractor / RealtimeScreenReactor / CalendarReader):** не меняются. Их источники всегда MY tasks (default `assignee: nil` в TaskItem init).
  - **Files touched:** `Models/TaskItem.swift`, `Services/Intelligence/TaskExtractor.swift`, `Views/Windows/TasksView.swift`, `Services/Intelligence/ChatService.swift`.
  - **Build:** clean (only 3 pre-existing unrelated warnings).
  - **Risks (для live-теста):**
    - LLM может слишком жадно вытаскивать класс B из обычных упоминаний. Жёсткий критерий «explicit delegation OR co-commitment» — митигация в промпте, проверять на реальных диктовках.
    - Aliases: «Вася»/«Vasya»/«Василий» → 3 разные секции. Для v1 принято — будем мерджить в ITER-014 через ProjectAlias-style canonicalization.
- ITER-012 — Meeting auto-stop guarantee + per-meeting recap notification:
  - **Symptom (user 2026-04-23):** "созвон сейчас 7 часов записывался и не останавливался автоматически". User wants stop-within-1-min after any call ends + post-meeting summary with next steps.
  - **Root causes (3 layers):** (1) `AppDelegate.handleCallContext` else-branch was a no-op for manually-started recordings — only auto-recorded ones got auto-stopped on call-end transition; (2) call-end signal relies on a window-title transition that never fires when Chrome tab stays open after meeting ends; (3) no upper duration bound — could record indefinitely.
  - **Fix (3-layer defense in depth):**
    - Layer A — `AppDelegate.handleCallContext`: drop the `didAutoStartRecording` gate in the call-ended branch. Now ANY active recording stops within ~1s of the window-title transition. Posts `postMeetingAutoStopped(reason: .callEnded)` notification.
    - Layer B — `MeetingRecorder` silence backstop: new `armSilenceGuard()` watches `audioLevel` via 1Hz Combine timer. After `meetingSilenceStopMinutes` (default 3) of consecutive sub-threshold (`< 0.005` RMS) audio → fires `onAutoStop(.silenceTimeout)`. Catches "browser tab still open after meeting ended".
    - Layer C — `MeetingRecorder` max-duration safety: new `armMaxDurationGuard()` Task sleeps `meetingMaxDurationMinutes * 60` seconds, then fires `onAutoStop(.maxDurationReached)`. Hard cap at user-configurable 30-480 min (default 240 = 4h). Floor 5 min for sanity.
    - All three guards disarm on `stop()` (manual or auto) so a stale timer never fires against a fresh recording.
  - **Per-meeting recap (the "summary + next steps" ask):**
    - `NotificationService.postMeetingRecap(title:overview:taskCount:memoryCount:conversationId:)` — fires after extractors finish. Title: "Meeting recap: <conv.title>". Body: overview prefix(140) + " · X tasks · Y memories". Click → opens Library tab.
    - `AppDelegate.fireMeetingRecap(for:)` — runs ~8s after `conversationGrouper.assign` (gives StructuredGenerator + MemoryExtractor + TaskExtractor time to populate). Counts only committed (non-staged) tasks. Even with empty title/overview sends a minimal "Transcript saved" recap.
    - Click router updated: `NotificationService` checks `userInfo["target"]` and routes recap → `.library`, defaults → `.tasks`.
  - **Settings (3 new):**
    - `meetingMaxDurationMinutes: Double = 240` — slider 30-480.
    - `meetingSilenceStopMinutes: Double = 3` — slider 1-15.
    - `meetingRecapNotifications: Bool = true` — toggle.
    - All in MAIN SETTINGS → Meeting Recording section, gated by `meetingRecordingEnabled`.
  - **Files touched:** `Models/AppSettings.swift`, `Services/Audio/MeetingRecorder.swift`, `Services/System/NotificationService.swift`, `App/AppDelegate.swift`, `Views/Windows/MainSettingsView.swift`.
  - **Build:** clean (3 pre-existing unrelated warnings only).
- MetaChat hallucination fix (system prompt rewrite at `ChatService.swift:167+`):
  - **Symptom (user report 2026-04-23):** AI claimed «Задачу 'Ответить Майку' убрано из списка» when user said "убери ее", then doubled down with «была ранее убрана» when asked to show it. Also failed to resolve "го" after a weather refusal as "try anyway / give your best guess". Net: assistant fabricated actions + ignored ellipsis context.
  - **Root cause (3 holes in the system prompt):** (1) no explicit READ-ONLY contract — LLM treated `<pending_tasks>` as something it could mutate; (2) the "DO NOT use AI's own prior messages as factual references" line was too weak — when AI's past message claimed an action, AI re-read it and treated it as fact in the next turn; (3) "Refine question based on <previous_messages>" rule had no ellipsis examples, so 1-2 word follow-ups like "го" got the "I don't understand" cop-out.
  - **Fix (3 prompt sections):** (a) new `<capabilities>` block enumerates CAN (read/quote/list) vs CANNOT (mutate/create/send/browse/run) and explicitly forbids fake-action claims like "Задача убрана"; (b) new GROUND TRUTH RULE replaces the weak prior-message rule with: "live context blocks win — your past assistant words may be hallucinations or fake-action claims; if a task still appears in current `<pending_tasks>`, you did NOT remove it"; (c) new ELLIPSIS / SHORT FOLLOW-UP RULE with concrete worked examples ("го" after refusal → try best non-live estimate, "да" after offer → fulfill, "и?" → expand last point). Built clean.
  - **Files touched:** `Services/Intelligence/ChatService.swift` (only systemPrompt block).
- ITER-011 — Conversation embeddings shipped:
  - `Models/Conversation.swift` — `+var embedding: Data?` (1536d Float32 from text-embedding-3-small).
  - `Services/Intelligence/EmbeddingService.swift` — new `embedConversationInBackground(_:sourceText:in:)` for fire-and-forget on close + extended `backfillMissing()` to include conversations with `status == "completed"`. Source text built via static `buildConversationEmbeddingSource(for:in:transcriptCharLimit:)` = `title · overview · transcript-prefix(≤1200)`. New generic `backfillPaired(pairs:assign:ctx:kind:)` helper for items whose source text needs DB lookups.
  - `Services/Intelligence/StructuredGenerator.swift` — `+weak var embeddingService: EmbeddingService?`. After title/overview/category/emoji populate, fires `embedConversationInBackground` so the conversation is searchable in MetaChat immediately.
  - `App/AppDelegate.swift` — wires `structuredGenerator.embeddingService = embeddingService` after both configure.
  - `Services/Intelligence/ChatService.swift` — replaced `fetchRecentMeetings(limit:charsPerMeeting:)` with `fetchMeetingsForQuery(queryVector:limit:charsPerMeeting:)`. Strategy: pull last 50 meeting candidates → if query vector exists, rank by cosine on conversation embeddings, take top-K → ALWAYS force-include the literal latest meeting (preserves "transcribe last call"). Fall back to pure recency when no query vector or no embeddings yet.
  - **Net effect:** MetaChat questions like "что я решил про цены?" find the right call even when the transcript said "тарифы" / "pricing" / "стоимость" — bilingual semantic match. "Transcribe my last call" still hits the literal latest because of force-include.
  - **Cost:** one-time backfill ~$0.0005 for 50 conversations; ongoing ~$0.000004 per new meeting close. Effectively free under Pro proxy.
- Phase 5 G1 — Goals system shipped end-to-end:
  - `Models/Goal.swift` (boolean / scale / numeric, with `progressFraction`, `progressLabel`, `resetIfNewDay`).
  - Schema registered in `HistoryService` for both real and in-memory configs.
  - `Views/Windows/GoalsView.swift` — top-level tab with list + editor sheet (3 type-aware fields), checkbox / slider / +/- counter controls, archive + delete via menu, daily reset for boolean/scale at first read of the day.
  - Sidebar: 6→7 tabs (added `.goals` after Library).
  - ChatService: new `<active_goals>` block in user prompt right after `<pending_tasks>`; system prompt updated in 3 places (context list, GOALS handler instruction, "all empty" check).
  - DailySummaryService: `fetchActiveGoals` snapshots feed `energyAgent` (can comment "Behind on writing goal", "Quiet build day, all daily goals done") and `headlineAgent` (only when a goal crosses a meaningful threshold).
- Build green throughout (no new warnings beyond two pre-existing: Swift 6 isolation on `EmbeddingService.dedupThreshold` + deprecated `kIOMasterPortDefault` in LicenseService).

## Current Phase
**Iteration 3: Screen-Aware Intelligence** — дали ChatService / MemoryExtractor / TaskExtractor доступ к ScreenContext OCR (см. spec `iterations/ITER-003-screen-aware-intelligence.md`). Build green, ждёт live-теста: MetaChat "что я читал на экране?" + voice "купи это" глядя на Amazon. Dashboard card "LAST 24H ON SCREEN" сверху StatisticsView.

**Предыдущая (Iteration 2):** Call Auto-Detection — build green, ждёт live-теста на Google Meet.
**Iteration 1:** Memory system + Insights — имплементировано, ждёт live-теста.

## Completed
- [voice-to-text core]: работает стабильно, не трогать — mic → WhisperKit → clipboard
- [FEAT-0001§audio-source]: `AudioSource` протокол, conform `AudioRecordingService`, `TranscriptionCoordinator` принимает `any AudioSource`
- [FEAT-0001§hallucination-filter]: exposed `TranscriptionCoordinator.isAlwaysHallucination` + `isHallucination` + `calculateRMS` как internal static — переиспользуются meeting recording
- [FEAT-0001§meeting-mix]: `MeetingRecorder` микширует mic + system audio, soft-clip, graceful degradation в micOnlyMode
- [FEAT-0002§screen-context]: `ScreenContextService` — ScreenCaptureKit + Apple Vision OCR, SwiftData persistence, blacklist по умолчанию
- [FEAT-0003§advice-core]: `AdviceService` — периодический + trigger на транскрипцию, SwiftData модель `AdviceItem`
- [FEAT-0004§permissions]: `PermissionsService` — `CGRequestScreenCaptureAccess` + `SCShareableContent`, активный триггер TCC
- [build-pipeline]: `build.sh` — единый .app в `~/Applications`, подписан ad-hoc с entitlements
- [insights-ui]: таб "Insights" с секциями Advice / Meetings / Screen Context, dismiss + mark-read
- [realtime-toggle]: Settings toggle → запрос permission → запуск/остановка сервиса без перезапуска app
- [meeting-timer-fix]: заменил `Timer.publish` на `TimelineView` — не ресетится от re-render из-за audioLevel updates
- [permission-ux-fix]: убрал авто-открытие System Settings при permission denial — steals focus и закрывает popover. Теперь error banner кликабельный → пользователь сам открывает Settings. Логи: `[SystemAudio] No Screen Recording permission — requesting...` → `[Permissions] ScreenCaptureKit: The user declined TCCs...` → раньше popover закрывался молча. Теперь остаётся открытым с красным бэннером.
- [appdelegate-shared-fix]: EXTRACT NOW / GENERATE NOW падали с "SwiftUI context issue" — `NSApp.delegate as? AppDelegate` runtime-cast failed (SwiftUI @NSApplicationDelegateAdaptor бриджит через Obj-C protocol, dynamic cast не проходит). Fix: `AppDelegate.shared` weak static, устанавливается в `applicationDidFinishLaunching`. MemoriesView + InsightsView теперь берут ссылку через него. Лог подтверждения в `~/Library/Logs/MetaWhisp.log`: `[InsightsView] ❌ AppDelegate cast failed. NSApp.delegate class = Optional<NSApplicationDelegate>` (до fix).
- [developer-id-signing]: `build.sh` теперь подписывает всё под `Developer ID Application: Andrey Dyuzhov (6D6948Z4MW)` вместо ad-hoc. Sparkle nested binaries (XPCServices, Autoupdate, Updater.app, Sparkle) подписываются снизу вверх с `--preserve-metadata=identifier,entitlements,flags` чтобы сохранить `org.sparkle-project.*` identifier. Hardened runtime (`--options runtime`) включён. Fallback на ad-hoc если cert отсутствует (CI). **Эффект:** TeamIdentifier стабилен (6D6948Z4MW) между rebuild'ами → TCC больше не сбрасывается, weekly-reprompt больше не триггерится. **Одноразовая боль:** при переходе с ad-hoc на Developer ID system-wide TCC помнит старый "deny" для Screen Recording → dialog не появляется. Решение один раз: System Settings → Privacy → Screen Recording → добавить через `+`. После этого grant прилип к Developer ID sig, rebuild не сбрасывает.
- [b1-tasks-parity]: Advice→Tasks implemented . Новый `TaskItem` model + `TaskExtractor` service копирует `extract_action_items` (`backend/utils/llm/conversation_processing.py:301`). Trigger: voice transcription ≥20 chars (mirror memory trigger). Prompt: copied verbatim 345-540, удалены sections про Speaker 0/1/2 и CalendarMeetingContext (single-user adaptation). 2-day dedup window, future-only due_at parsing. UI: Insights → Tasks section с checkbox + due badges (TODAY/TOMORROW/OVERDUE). `AdviceService.startPeriodicAdvice` полностью отключён. `AdviceItem` records остаются в БД (138 шт) но скрыты от UI. Build green. Awaiting user verification scenarios (see BACKLOG#B1).
- [ITER-003§screen-aware-intelligence]: дал intelligence-сервисам доступ к screen OCR. **Проблема:** `ScreenContext` пишется каждые 30с (778+ строк) но `ChatService` не читал вообще, `MemoryExtractor`/`TaskExtractor` читали только metadata (appName/windowTitle), не OCR — надиктовал "купи это" → task без контекста. **Изменения:** (1) `ChatService` — `+weak var screenContext`, `+fetchScreenContextLast24h(limit:30, maxCharsPerSnippet:200)` → новый блок `<recent_screen_activity>` в промпте после `<pending_tasks>` (cap ~6KB). System prompt обновлён: "consult <recent_screen_activity>… do NOT invent details OCR doesn't contain". (2) `MemoryExtractor` + `TaskExtractor` — в `buildPrompt` splice `<on_screen_right_now app="" window="">` (≤500 chars, latest snapshot only). Prompts обновлены: "USE ONLY to resolve ambiguous references (this/that). DO NOT extract from screen alone — voice is source of truth". Пример: voice "remind me to order this" + OCR "iPhone 15 Pro Max" → task "Order iPhone 15 Pro Max". (3) `AppDelegate.setupServices` — `chatService.screenContext = screenContext` after configure. (4) `DashboardView` — new `ScreenActivityCard` subview (`@Query<ScreenObservation>` last 24h → group by appName → sum durations → top-5 tiles с durationLabel "3h 12m"). Empty state "No screen activity yet. Enable Screen Context in Settings." **Cost guard:** 30×200=6KB в chat prompt (в пределах 24KB cap); 500 chars в memory/task — почти бесплатно. Privacy: blacklist (Passwords/1Password) уже enforced в `ScreenContextService` → в промпты не попадёт. **Не сделано (отдельные треки):** realtime per-window-change extraction (гэп #3), embeddings (гэп #4), retention (#5), video chunks (#6). **Файлы:** `Services/Intelligence/ChatService.swift`, `Services/Intelligence/MemoryExtractor.swift`, `Services/Intelligence/TaskExtractor.swift`, `App/AppDelegate.swift`, `Views/Windows/DashboardView.swift`. Build green (2.81s). Spec: `specs/iterations/ITER-003-screen-aware-intelligence.md`. Awaiting live verify.
- [ITER-002§arc-meet-fix]: **Baseline ITER-002 shipped to source, user reported "не записываются звонки".** Diagnostic показал 2 RC: (RC1 primary) user запускал старый бинарь Apr 19 22:32 до ITER-002 — нужен `./build.sh`. (RC2) логи раскрыли Arc edge case — Arc window title для Google Meet = **только room code** ("gpq-mmkq-iaz"), без строки "Google Meet" → keyword lookup fails. Reference тоже этот case не ловит. **Fix:** добавил `meetRoomCodeRegex` (`^[a-z]{3}-[a-z]{3,4}-[a-z]{3}$`) как fallback в `SystemAudioCaptureService.detectCallContext` когда app is browser и keyword-match fail. Formato room code стабильный (Google Meet всегда 3-{3,4}-3 lowercase). Build green. Awaiting rebuild + test.
- [ITER-002§call-auto-detection]: auto-detect созвона → нотификейшн → optional 5s auto-start. **Hook:** `ScreenContextService.captureIfChanged` (piggy-back на существующий window-polling loop, у пользователя screen context всегда ON). **Детекция:** `SystemAudioCaptureService.detectCallContext(bundleID:appName:windowTitle:)` — native call apps (Zoom/Teams/FaceTime/Slack/Discord/Webex/GoToMeeting) + browser apps (Chrome/Safari/Arc/Firefox/Edge/Brave/Opera) + title keywords ("Google Meet", "meet.google.com", "Teams - Microsoft", "Zoom Meeting"). **State machine:** `lastCallContext` — callback `onCallContext(name?)` фаерит только на transition (nil→name, name→nil), debounce built-in. **Settings (2 toggles под MEETING RECORDING):** `autoDetectCalls` (existing dead toggle → wired) = показать нотификейшн; `callsAutoStartEnabled` (NEW) = через 5s start recording. **AppDelegate:** `handleCallContext` → `NotificationService.postCallDetected(appName:autoStart:)` + `autoRecordCountdownTask` 5s sleep → `meetingRecorder.start()`. `didAutoStartRecording` флаг отличает auto-record от manual → auto-stop только для auto-record. Skip если уже recording. Countdown cancellable если call ended до 5s. **Файлы:** `Models/AppSettings.swift`, `Services/Audio/SystemAudioCaptureService.swift`, `Services/Screen/ScreenContextService.swift`, `Services/System/NotificationService.swift`, `App/AppDelegate.swift`, `Views/Windows/MainSettingsView.swift`. Build green. Awaiting live test on Google Meet in Chrome.
- [memory-extractor-align]: MemoryExtractor переписан под проверенный pattern. **Trigger:** fires on each voice transcription ≥20 chars (mirror `AdviceService.triggerOnTranscription`), НЕ periodic timer каждые 10 мин. **Input:** voice transcript, screen OCR больше не input для memories (garbage in → garbage out, prompt отвергал UI junk типа "0 clawd / SEO SKILL ~ 口、"). **Prompt:** adapted из — categorization test Q1→Q2, temporal ban ("Thursday"/"next week"), transient verb ban ("is working on"/"is building"), hedging ban, strict dedup with "contradiction is EXCEPTION → extract", mandatory double-check. **Cap:** max 2 memories per extraction. **Dedup window:** все non-dismissed memories (было 20, 1000). **Verify:** diagnostic script `/tmp/mw_test_extractor.py` — на idealfactual transcript ("Я CTO Overchat, использую Swift strict concurrency") вернул 2 memories с confidence=1.0. На non-factual ("я думаю", "покажи html") вернул [] — корректно. **Files:** `Services/Intelligence/MemoryExtractor.swift`, `Services/System/TranscriptionCoordinator.swift:37-41`, `App/AppDelegate.swift:90-93, 286-289, 382-388`. EXTRACT NOW кнопка теперь extract'ит из последнего transcript в History.

## In Progress
- [FEAT-0001§meeting-recording] (UX polish):
  - DONE: mic+system mix (Services/Audio/MeetingRecorder.swift)
  - DONE: фильтр галлюцинаций (App/AppDelegate.swift § stopMeetingRecording)
  - DONE: RMS < 0.0005 skip, RMS < 0.003 + isHallucination pattern match
  - DONE: waveform indicator во время записи — `MeetingWaveform` в Views/MenuBar/MenuBarView.swift (spec://audio/FEAT-0001#ui-contract.waveform)
  - DONE: Copy/Export/Delete на карточках meetings — `MeetingCardView` в Views/Windows/InsightsView.swift (spec://audio/FEAT-0001#ui-contract.copy-export)
  - DONE: auto-detection созвона → нотификация + optional 5s auto-start (см. [ITER-002§call-auto-detection] в Completed). Ждёт live-теста на Google Meet.

- [FEAT-0002§screen-context] (верификация):
  - DONE: базовый pipeline (capture → OCR → persist)
  - DONE: UI для blacklist/whitelist — `AppPickerView` + `AppPickerRow` + `InstalledApps` в Views/Components/AppPickerView.swift, wired в MainSettingsView `screenContextAppList` (spec://intelligence/FEAT-0002#app-picker)
  - TODO: протестировать в реальности — пользователь включил, но не подтвердил работу
  - TODO: кнопка "Clear all contexts" в Insights

- [FEAT-0003§advice] (верификация):
  - DONE: каркас (трigger на транскрипцию + периодический)
  - DONE: wired `triggerOnTranscription` в `TranscriptionCoordinator` + meeting pipeline (spec://intelligence/FEAT-0003#triggers.transcription) — fire-and-forget, min 20 символов
  - DONE: macOS UserNotifications с click → Insights + markAsRead (spec://intelligence/FEAT-0003#notifications) — NotificationService, rate limit 1/min
  - DONE: Pro proxy — `/api/pro/advice` endpoint (api/src/index.js) + `callProProxy` в AdviceService + убрал warning для Pro в Settings. Pro-юзеры не вводят никаких ключей. Non-Pro — свой OpenAI/Cerebras ключ. Deployed к api.metawhisp.com
  - TODO: реально протестировать в life — advice не сгенерирован ни разу на живых данных
  - TODO: fallback на Apple Foundation Models (macOS 26+) когда нет API ключа

## Deferred Technical Debt

- **Apple Developer signing** (user has account, approved 2026-04-17)
  - Replace ad-hoc signing in `build.sh` → use Developer ID cert
  - Removes TCC permission reset on every rebuild (major UX annoyance)
  - Simplifies notifications (no more UNErrorDomain error 1 issues)
  - When: после завершения текущих итераций, до первого внешнего релиза

## Known Issues
1. **Дубликат "MEETING RECORDING" label** — пользователь сообщил, в коде только один (MenuBarView меню-бар strip). Не воспроизведён, жду скриншот.
   Affects: `Views/MenuBar/MenuBarView.swift` § meetingStrip

2. **Accessibility permission не автодобавляется** — TCC не регистрирует app в Accessibility списке после rebuild. Пользователю надо добавлять вручную через `+` в System Settings.
   Affects: `App/AppDelegate.swift` § setupServices (AXIsProcessTrustedWithOptions)

3. **Mic + main coordinator конфликт** — если meeting recording активно, Right ⌘ не запустит обычную запись (AudioRecordingService.start() в `isRecording=true` state). Не критично, но не задокументировано.
   Affects: `Services/Audio/AudioRecordingService.swift:117`

## Decisions Pending
- spec://audio/FEAT-0001#continuous-mode: включать ли непрерывный meeting mode с авто-сегментацией по VAD?
- spec://intelligence/FEAT-0003#local-llm: интегрировать Apple Foundation Models (требует macOS 26) для local advice без API ключей?
- spec://audio/PROP-0001#ble-wearable: делать ли BLE интеграцию с wearable reference как третий AudioSource?

## Iteration 1 (Memory + Insights) — implemented, ждёт user-теста

Реализовано всё по `specs/iterations/ITER-001.md`:
- `UserMemory` model + `MemoryExtractor` (prompt, strict accept/reject lists, 10-min timer)
- `MemoriesView` отдельным табом в sidebar + toggle `memoriesEnabled` (независимый от advice)
- `AdviceService` переписан : <100 chars, BAD EXAMPLES, `no_advice` escape, memory injection, окно previous advice = 20
- `EXTRACT NOW` / `GENERATE NOW` кнопки для instant-теста
- Backend `/api/pro/advice` — `MAX_PROMPT_LEN` 8000→32000, `maxBalance` 600→1800
- Auto-restart ScreenContext когда permission grant'ится в runtime (applicationDidBecomeActive)

## Что на столе — 3 опции для следующей сессии

1. **Self-signed cert в Keychain** — стабильная подпись между rebuild'ами, TCC permissions больше не сбрасываются (самая большая боль недавней сессии). Пользователь создаёт cert в Keychain Access, build.sh подписывает им.
2. **Live тест GENERATE NOW / EXTRACT NOW** — проверить что советы короткие/конкретные, memories не тривиальные, no_advice срабатывает
3. **Iteration 2: File Indexing** — user picks папки → extract text → write в UserMemory (обогащение personalization)

User предпочитает продуктовые фичи > infrastructure polish, но self-signed cert сэкономит часы в следующих итерациях.

## Session Context
**Start here:** Прочитать `specs/KARPATHY.md` (правила) + `specs/iterations/ITER-001.md` (текущий state реализации).
**User preference:** Karpathy principles, minimal visible changes, no speculation, each feature = verifiable success criteria.
**Recent session pain points:** TCC permissions сбрасывались 4-5 раз из-за ad-hoc signature changes. Apple Developer paid — нет. Self-signed cert — решение (deferred).
**Watch out:**
- НЕ ТРОГАЙ `TranscriptionCoordinator.isAlwaysHallucination` / `isHallucination` — используются meeting recording
- НЕ ЛОМАЙ существующий обычный pipeline (Right ⌘ → mic → clipboard) — основной flow пользователя
- НЕ ДОБАВЛЯЙ sudo в build scripts — блокирует rebuild из-за root-owned файлов
- НЕ городи архитектуру на будущее (Karpathy Simplicity First) — только то что нужно для текущей задачи
