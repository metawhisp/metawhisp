# MetaWhisp Backlog — Путь к Omi parity

**Source of truth** для открытых треков. Единственное место где живёт приоритизация.

**Последний deep research:** 2026-04-19 — читал реальный Omi desktop Swift app (`desktop/Desktop/Sources/`), prompt files, models. Предыдущие оценки scope были критически неполны — извинения user'у записаны.

---

## Методология (железная)

1. **Analyze Omi** — открыть реальный Swift файл в их desktop app прежде чем писать строку кода.
2. **Copy first** — копируем structure / prompt / model as-is.
3. **Adapt only to our constraints** — SwiftData vs их GRDB, no cloud backend у нас, no agent integration в MVP.
4. **Verify** — success criteria до кода.
5. **Inspiration only after parity.**

**Anti-patterns (not allowed):**
- Speculation про features которые я не прочитал в Omi repo
- Отрицание features которые у Omi есть, без deep search
- Bundle multiple tracks

---

## Omi desktop app — real inventory (2026-04-19 research)

Omi desktop app (`desktop/Desktop/Sources/`) имеет **40+ top-level Swift files + 15 directories**. Это не MVP — это зрелый продукт. Ниже — group by area.

### Data layer (`Rewind/Core/` — 15 files, GRDB SQLite + video)

| File | Size | Что |
|---|---|---|
| `RewindDatabase.swift` | 136 KB | Monolithic DB manager + video storage |
| `ActionItemStorage.swift` | 59 KB | Tasks (with embeddings, recurrence, agents) |
| `TranscriptionStorage.swift` | 30 KB | Transcripts storage |
| `VideoChunkEncoder.swift` | 24 KB | **Video recording** chunks (H.264) |
| `MemoryStorage.swift` | 23 KB | Memories storage |
| `RewindStorage.swift` | 22 KB | Screenshot / video / OCR storage |
| `ProactiveStorage.swift` | 18 KB | Proactive extractions |
| `TaskChatMessageStorage.swift` | 14 KB | Chat linked to tasks |
| `StagedTaskStorage.swift` | 12 KB | Staged (not yet committed) tasks |
| `GoalStorage.swift` | 9 KB | Goals (boolean/scale/numeric) |

### Data models (real field lists from Omi code)

**Screenshot** (`RewindModels.swift`):
```
id, timestamp, appName, windowTitle,
imagePath (legacy) OR videoChunkPath + frameOffset,  // VIDEO STORAGE
ocrText, ocrDataJson (bounding boxes),
isIndexed, focusStatus ("focused"|"distracted"),
extractedTasksJson, adviceJson,
skippedForBattery
```

**MemoryRecord**:
```
backendId, backendSynced,                  // cloud sync
content, category (system|interesting|manual),
tagsJson (["tips", "focus"]), visibility, reviewed,
manuallyAdded, conversationId, screenshotId,  // FK links
confidence, reasoning, sourceApp, contextSummary,
currentActivity, inputDeviceName, headline,
isRead, isDismissed, deleted
```

**ActionItemRecord** (massive):
```
backendId, backendSynced,
description, completed, deleted, priority (high|medium|low),
conversationId, screenshotId,
dueAt, recurrenceRule (daily|weekdays|weekly|biweekly|monthly),
recurrenceParentId,                         // recurring chain
tagsJson, category,
embedding: Data (3072 Float32 — Gemini embedding-001),   // VECTOR SEARCH
sortOrder, indentLevel (0-3),               // nested hierarchy
relevanceScore (0-100),                     // AI prioritization
agentStatus (pending|processing|completed|failed),  // AGENT INTEGRATION
agentSessionName (tmux session),            // Claude agent works on task
agentPrompt,
deletedBy ("user"|"ai_dedup")               // AI dedup
```

**GoalRecord**:
```
title, goalDescription, goalType (boolean|scale|numeric),
targetValue, currentValue, minValue, maxValue, unit
```

**IndexedFileRecord** (FileIndexing):
```
path, filename, fileExtension, fileType (10 categories),
sizeBytes, folder (Downloads/Documents/Desktop), depth,
createdAt, modifiedAt, indexedAt
```

**LocalKGNodeRecord + LocalKGEdgeRecord** (Knowledge Graph / Brain Map):
```
nodeId, label, nodeType, aliases → LocalKGEdgeRecord (source, target, label)
```

**ProactiveExtractionRecord**:
```
screenshotId, type (memory|task|insight),
content, category, priority, confidence, reasoning,
sourceApp, contextSummary
```

**ObservationRecord** ("every screenshot analysis produces observation"):
```
screenshotId, appName, contextSummary, currentActivity,
hasTask, taskTitle, sourceCategory, sourceSubcategory
```

### Services layer (readers + AI + capture)

- `AppleNotesReaderService.swift` — **Apple Notes integration**
- `GmailReaderService.swift` — **Gmail**
- `CalendarReaderService.swift` — **Calendar**
- `FileIndexing/FileIndexerService.swift` (23 KB) — **File Indexing** с UI (23 KB view)
- `ScreenCaptureService.swift` — screen capture (video chunks)
- `ScreenActivitySyncService.swift` — sync screen activity to backend
- `AudioCaptureService.swift`, `AudioLevelMonitor.swift`, `AudioMixer.swift`
- `SystemAudioCaptureService.swift`
- `TranscriptionService.swift`, `TranscriptionRetryService.swift`, `LiveTranscriptMonitor.swift`
- `VADGateService.swift` — Voice Activity Detection
- `DesktopAutomationBridge.swift` — system automation
- `BrowserExtensionSetup.swift` — Chrome extension integration
- `MemoryExportService.swift` — export memories
- `APIClient.swift`, `APIKeyService.swift`, `AuthService.swift`

### AI / Proactive (massive)

- `ProactiveAssistants/ProactiveAssistantsPlugin.swift` — 68 KB (!)
- `ProactiveAssistants/Assistants/`, `Core/`, `Services/`, `UI/` subdirectories
- `Chat/ChatPrompts.swift` — **85 KB** all prompts
- `Chat/ACPBridge.swift` — 34 KB (Agent Communication Protocol?)
- `Chat/ClaudeAuthSheet.swift` — Claude OAuth UI

### UI

- `MainWindow/SidebarView.swift`, `SettingsSidebar.swift`
- `MainWindow/Pages/` directory
- `MainWindow/Components/` directory
- `MainWindow/RewindOnlyView.swift`
- `FloatingControlBar/` — floating bar (push-to-talk, TTS)
- `LiveNotes/` — live transcript view (3 files)
- `Onboarding*` — 20+ onboarding files

### Other

- `WAL/` — Write-Ahead Log for crash safety
- `Stores/` — Redux-like state stores
- `Bluetooth/` — BLE (wearable)
- `Theme/` — design tokens

---

## Honest gap analysis — MetaWhisp vs Omi desktop

### ✅ ЕСТЬ у нас (rough parity)

- Voice dictation (Right ⌘) — HistoryItem
- Meeting recording (mic + system audio)
- Screen OCR (text only, single snapshot)
- Memory extraction from voice (Phase 0)
- Task extraction from voice (B1, testing pending)
- Chat RAG (B2 as MetaChat, testing pending)
- Basic UI: Sidebar + tabs (Dashboard/History/Insights/Memories/MetaChat/Settings)
- Developer ID signing, Sparkle updates

### ❌ НЕТ у нас

**Storage & Sync:**
- GRDB (SQLite with migrations) vs our SwiftData — не критично, SwiftData работает
- Video chunk storage + video frame offsets — у нас только OCR text, no video
- Backend cloud sync (`backendId`, `backendSynced`) — **у нас чисто local, это осознанное решение**
- Vector embeddings (Gemini embedding-001, 3072d) — у нас только text match
- WAL / crash safety — у нас простой SwiftData

**Data richness:**
- Tags для memories + tasks
- Priority (high/medium/low) + relevance score 0-100
- Recurrence rules (daily/weekdays/weekly/biweekly/monthly)
- Nested hierarchy (sortOrder + indentLevel 0-3)
- Focus status tracking ("focused"|"distracted")
- AI dedup (`deletedBy: ai_dedup`)
- ObservationRecord per screenshot (even when no task found)

**Entities absent entirely:**
- **Conversation** (root aggregator)
- **Goal** (boolean/scale/numeric targets)
- **Knowledge Graph** (nodes + edges = Brain Map)
- **LiveNotes** (real-time transcript panel)
- **ProactiveExtraction** (unified memory/task/insight from screen)
- **StagedTask** (draft tasks)

**Agent integration:**
- Claude Code OAuth + "Your Claude Account" provider
- Agent работает на tasks через tmux (`agentStatus`, `agentSessionName`, `agentPrompt`)
- Browser Extension (Chrome) для AI
- DesktopAutomationBridge
- Dev Mode (AI modifies app source code)

**Readers (external data sources):**
- Apple Notes (`AppleNotesReaderService`)
- Gmail (`GmailReaderService`)
- Calendar (`CalendarReaderService`)
- File Indexing (`FileIndexerService` — indexes Downloads/Documents/Desktop)

**UX:**
- Floating Bar (push-to-talk, TTS with voice Sloane, 1.4x speed)
- Daily Summary at scheduled time (10PM)
- Per-category notifications (Focus/Task/Insight/Memory)
- Rewind timeline UI with search + date picker
- Brain Map graph visualization
- Tasks с Today/No Deadline/recurrence grouping
- Onboarding: DataSources / Exports / FileScan / Goal / Language / Floating Bar shortcut

**Infrastructure:**
- VAD Gate (skip silence in transcription)
- TierManager (subscription tiers)
- Proactive Assistants Plugin system
- ACP Bridge (Agent Communication Protocol)

---

## Realistic roadmap

### Phase 0: Foundation ✅ DONE
- Memory voice-trigger refactor
- Developer ID signing
- AppDelegate.shared
- B1 Tasks implementation (testing pending)
- B2 MetaChat implementation (testing pending)
- MetaChat typing animation + branding

### Phase 1: Core entity parity (Conversations as root) 🔨 IN PROGRESS

Ставим Conversation как root entity — все downstream linked to it. Без этого Phase 2+ не имеет смысла.

- **C1.1** ⏸️ TESTING PENDING — Conversation SwiftData model + auto-grouping (10-min silence) + HistoryItem.conversationId FK. Implementation complete 2026-04-19:
  - `Models/Conversation.swift` — model with forward-compat fields (title/overview/category/starred nil-able for C1.2/C1.4)
  - `Models/HistoryItem.swift` — added `conversationId: UUID?`
  - `Services/Intelligence/ConversationGrouper.swift` — assign/closeStale/closeConversation logic. Dictation gap = 600s. Meeting = always own conversation, closed on create (single-shot).
  - `Services/Data/HistoryService.swift` — schema +Conversation
  - `Services/System/TranscriptionCoordinator.swift` — calls grouper.assign after save
  - `App/AppDelegate.swift` — creates + wires grouper; meeting flow also assigns + now fires memory/task triggers (previously only advice)
  - **Verify commands:** `sqlite3 ~/Library/Application\ Support/MetaWhisp.store "SELECT * FROM ZCONVERSATION;"` after dictation
  - **Success criteria:** 3 dictations within 5 min → 1 Conversation with 3 HistoryItem rows carrying same conversationId. Wait 15 min, dictate → 2nd Conversation.
- **C1.2** ⏸️ TESTING PENDING — Structured generation (title/overview/category/emoji on close). Implementation 2026-04-19:
  - `Models/Conversation.swift` — added `emoji: String?` alongside existing forward-compat title/overview/category
  - `Services/Intelligence/StructuredGenerator.swift` — NEW, copies Omi `get_transcript_structure` prompt (`backend/utils/llm/conversation_processing.py:588-647`) with single-user simplifications. Adaptations: removed speaker/photos/calendar, kept title Title Case ≤10 words + overview + emoji + category (33 values).
  - `Services/Intelligence/ConversationGrouper.swift` — `scheduleStructuredGeneration(for:)` fires on every close path (stale timeout, explicit close, meeting single-shot create). 300ms delay before LLM call so HistoryItem persist completes.
  - `App/AppDelegate.swift` — create + configure StructuredGenerator.
  - **Verify:** after conversation closes (10 min silence OR meeting stop), conversation row has non-nil title/overview/category/emoji. Check: `sqlite3 ~/Library/Application\ Support/MetaWhisp.store "SELECT ZEMOJI, ZCATEGORY, ZTITLE, substr(ZOVERVIEW,1,80) FROM ZCONVERSATION WHERE ZSTATUS='completed' ORDER BY ZFINISHEDAT DESC LIMIT 3;"`
- **C1.3** ⏸️ TESTING PENDING — Conversation FK across all downstream entities. Implementation 2026-04-19:
  - `Models/UserMemory.swift` — added `conversationId: UUID?`
  - `Models/TaskItem.swift` — added `conversationId: UUID?` (alongside existing `sourceTranscriptId`)
  - `Models/ScreenContext.swift` — added `conversationId: UUID?` (field only; linking logic deferred to Phase 2)
  - `Services/Intelligence/MemoryExtractor.swift` — `triggerOnTranscription(…, conversationId:)` propagates FK to parseResponse → new UserMemory rows carry FK
  - `Services/Intelligence/TaskExtractor.swift` — same pattern for TaskItem
  - `Services/System/TranscriptionCoordinator.swift` — after grouper.assign, read `item.conversationId` and pass to both extractors
  - `App/AppDelegate.swift` — meeting flow does the same
  - **Per-conversation-close re-extraction NOT done in C1.3** — kept per-transcript trigger for immediate UX. Conversation-level extraction (full context LLM call after close) is a separate decision — see "Open question" below.
  - **Verify:** new UserMemory/TaskItem after dictation should have non-nil `conversationId` matching an active Conversation. Check: `sqlite3 ~/Library/Application\ Support/MetaWhisp.store "SELECT ZCONTENT, ZCONVERSATIONID FROM ZUSERMEMORY WHERE ZCREATEDAT > (strftime('%s','now')-978307200-3600) ORDER BY ZCREATEDAT DESC LIMIT 5;"`

**Open question for C1.3 follow-up:** Omi fires extractors on conversation CLOSE (full context). We fire per-transcript (immediate UX). Consequence: our LLM sees one transcript at a time and may miss cross-transcript patterns ("купить молоко" + later "и хлеба" in same conversation → should maybe merge into one task "Купить молоко и хлеб"). Decide later whether to add on-close re-extraction pass.
- **C1.4** ⏸️ TESTING PENDING — Conversations tab UI. Implementation 2026-04-19:
  - `Views/Windows/ConversationsView.swift` — NEW. Date-grouped list (TODAY/YESTERDAY/Apr 18...), filter chips (ALL/STARRED), row with SF Symbol icon + title + overview + category chip + star button + time. Click row → inline expand with linked transcripts + tasks + memories + status/source chips + discard button.
  - `Views/Windows/MainWindowView.swift` — added `.conversations` tab right after Dashboard with icon `bubble.left.and.bubble.right`. Moved MetaChat icon to `message` (they had same icon conflict).
  - Adaptations from Omi: monochrome SF Symbols (not color emoji), simpler 2-chip filter (ALL/STARRED) vs Omi's 5+1 (33 categories too many for top bar). Category chip appears inline next to title.
  - **Verify:** after any voice dictation → Conversations tab → row appears (initially "In progress…" title until conversation closes and StructuredGenerator populates fields). After 10 min silence + next dictation → previous conversation title/overview filled.

### Phase 2: Screen pipeline ↔ Omi Rewind parity 🎯 NEXT AFTER PHASE 1

**User priority (2026-04-19):** "продолжаем но про экран запоминаем и сделаем позже" — Phase 2 is the committed next major after Phase 1 C1.x completes. User asked about `ScreenContext` usage — current state is 778 records in DB, not used by any service (MetaChat/MemoryExtractor/TaskExtractor/AdviceService all skip screen). Phase 2 unlocks auto-memories/tasks/insights from screen (Obsidian/Notion/Claude/ChatGPT content while user reads them) without requiring voice dictation.

Наш ScreenContext (OCR snapshots) — очень bare vs Omi Rewind (video chunks + OCR + task/memory extraction per screenshot).

- **R1** ⏸️ TESTING PENDING — ScreenObservation infrastructure + hourly batch extractor. Implementation 2026-04-19:
  - `Models/ScreenObservation.swift` — NEW. Mirrors Omi's `Rewind/Core/ObservationRecord.swift`: id, screenContextId FK, appName, windowTitle, contextSummary, currentActivity, hasTask, taskTitle, sourceCategory, focusStatus, startedAt, endedAt, createdAt.
  - `Services/Intelligence/ScreenExtractor.swift` — NEW. Batches ScreenContext into "visits" (consecutive same-app, 5-min gap threshold), caps at 20 visits/batch, sends to Pro proxy. Prompt adapted from Omi observation extraction: per-visit contextSummary + currentActivity + hasTask + category + focusStatus.
  - `Services/Data/HistoryService.swift` — schema +ScreenObservation.
  - `Models/AppSettings.swift` — `screenExtractionEnabled: Bool = true`, `screenExtractionInterval: Double = 3600`.
  - `App/AppDelegate.swift` — creates + configures + starts periodic timer if enabled.
  - **Cost profile:** 60 min × ~2 raw snapshots/min ≈ 120 records → collapse to ~15 visits → 1 LLM call/hour instead of 120.
  - **Adaptations from Omi:** Omi analyzes per-snapshot (cheap because wearable captures slow); we batch to fit Pro-proxy economics. Output shape identical (observation + hasTask + taskTitle).
  - **R2 will extend:** same LLM call also returns memories[] and tasks[] extracted from screen — UserMemory/TaskItem get `screenContextId` FK (like they have conversationId). Not in R1.
  - **Verify after 1 hour:** `sqlite3 ~/Library/Application\ Support/MetaWhisp.store "SELECT ZAPPNAME, substr(ZCONTEXTSUMMARY,1,60), ZHASTASK, ZSOURCECATEGORY, ZFOCUSSTATUS FROM ZSCREENOBSERVATION ORDER BY ZCREATEDAT DESC LIMIT 10;"`
- **R2** ⏸️ TESTING PENDING — auto-memories + auto-tasks from screen. Implementation 2026-04-19:
  - `Models/UserMemory.swift` — added `screenContextId: UUID?` (sibling of conversationId; nil for voice-extracted memories, set for screen-extracted).
  - `Models/TaskItem.swift` — added `screenContextId: UUID?`.
  - `Services/Intelligence/ScreenExtractor.swift` — same LLM call now returns **observations + memories + tasks** together (one batch, 3 arrays). visitIndex links each memory/task to source visit's ScreenContext.
  - Dedup: Swift-side cheap exact-content check against last 100 memories/tasks (LLM also does semantic dedup via prompt). Threshold 0.6 confidence for memory acceptance.
  - **Unlocks user's ask** ("знать все проекты из Obsidian/Notion/Claude/ChatGPT") — when user reads these apps, hourly batch extracts memories like "User works on Overchat SEO strategy" from GA4 dashboard reading.
  - **Verify after 1 hour of varied screen activity:**
    ```bash
    sqlite3 ~/Library/Application\ Support/MetaWhisp.store \
      "SELECT ZCONTENT, ZSOURCEAPP FROM ZUSERMEMORY WHERE ZSCREENCONTEXTID IS NOT NULL ORDER BY ZCREATEDAT DESC LIMIT 10;"
    sqlite3 ~/Library/Application\ Support/MetaWhisp.store \
      "SELECT ZTASKDESCRIPTION, ZSOURCEAPP FROM ZTASKITEM WHERE ZSCREENCONTEXTID IS NOT NULL ORDER BY ZCREATEDAT DESC LIMIT 10;"
    ```
- **Sidebar reorg** ⏸️ TESTING PENDING (2026-04-19). User feedback: 9 tabs too many, Rewind and Screen Context visually overlap.
  - `Views/Windows/LibraryView.swift` — NEW hub with section picker (CONVERSATIONS / SCREEN / MEMORIES / HISTORY). Sub-views render their own headers inside.
  - `Views/Windows/TasksView.swift` — NEW standalone top-level (promoted from InsightsView section). Same TaskItem rendering — checkbox + due badge + dismiss + sourceApp.
  - `Views/Windows/RewindView.swift` — header renamed "REWIND" → "SCREEN" per user naming.
  - `Views/Windows/MainWindowView.swift` — sidebar trimmed 9 → 6 tabs: Dashboard / Library / Tasks / MetaChat / Dictionary / Settings. Removed cases: .conversations, .rewind, .history, .insights, .memories (now live inside Library or Tasks).
  - `Services/System/NotificationService.swift` — notification tap now opens `.tasks` instead of `.insights`.
  - Legacy files `InsightsView.swift`, `ConversationsView.swift`, `RewindView.swift`, `MemoriesView.swift`, `HistoryView.swift` kept in code — referenced by LibraryView (4 sub-views) or dead but compiling (InsightsView).
  - **Screen Context section** from old Insights → deleted as top-level surface. Raw OCR still visible via Library → Screen → click row → OCR SNAPSHOT section in expanded detail.
  - Dictionary kept top-level per absence of decision — can move to Settings in Phase 5 polish.
  - **Verify:** sidebar shows 6 items; click Library → 4 inner tabs work; click Tasks → shows task list directly; old notification on task tap opens Tasks tab.

- **R3** ⏸️ TESTING PENDING — Rewind timeline UI. Implementation 2026-04-19:
  - `Views/Windows/RewindView.swift` — NEW. Date-grouped list of ScreenObservations (TODAY/YESTERDAY/date). Search bar over app+summary+activity+category+title. Filter chips: TODAY / YESTERDAY / THIS WEEK / ALL. Row with time+duration · SF Symbol (checklist if hasTask else category-based) · app+title · contextSummary. Click → expand with detected task, linked TaskItem (checkboxes), linked UserMemory, OCR snapshot preview (600 chars selectable).
  - `Views/Windows/MainWindowView.swift` — added `.rewind` tab (icon `clock.arrow.2.circlepath`) after Conversations.
  - Adaptations from Omi: no video scrubber (OCR-only corpus), no draggable timeline seek — list + expand is enough for desktop.
  - **Verify:** after ~1h of activity → Rewind tab shows observations grouped by date, each row summarizes a visit. Expand to see OCR + linked extractions.
- **R4** (large) Video chunk storage — рассмотреть. Omi пишет video, мы только screenshot. Skip for MVP, revisit.

### Phase 3: External readers (Apple Notes / Files / Calendar / Gmail)

Omi readers — самый близкий аналог "auto-подтягивать memories из Obsidian/Notion" что user хочет.

- **E1** ⏸️ TESTING PENDING — File Indexing + memory extraction from user-picked folders. Implementation 2026-04-19:
  - `Models/IndexedFile.swift` — mirrors Omi's `IndexedFileRecord` (path, filename, fileExtension, fileType, sizeBytes, folder, depth, createdAt/modifiedAt/indexedAt/contentExtractedAt). Static helpers: category by ext (10 types), isExtractable(md/txt/rtf/markdown).
  - `Services/Indexing/FileIndexerService.swift` — Omi-aligned scan: actor-like @MainActor service, skip-folder list (.git/node_modules/.venv/...), package-extensions (.app/.framework) as leaves, maxDepth=8 (user vaults deeper than Omi's 3), maxFileSize=500MB, batch save every 200. Periodic every 6h.
  - `Services/Indexing/FileMemoryExtractor.swift` — second pass: reads .md/.txt content (up to 12K chars), sends to Pro proxy with Omi-strict memory prompt, saves UserMemory with `sourceFile` FK. Max 15 files per run, confidence ≥ 0.7.
  - `Models/UserMemory.swift` — added `sourceFile: String?`.
  - `Models/AppSettings.swift` — `fileIndexingEnabled: Bool = false`, `indexedFoldersCSV: String`, `fileIndexingInterval: Double = 21600`, + helper methods `addIndexedFolder/removeIndexedFolder`, computed `indexedFolders: [String]`.
  - `Services/Data/HistoryService.swift` — schema +IndexedFile.
  - `Views/Windows/FilesView.swift` — NEW. Lists files grouped by folder, SF Symbol icons by fileType, size + modified date, checkmark on extracted rows. SCAN NOW button runs both passes.
  - `Views/Windows/LibraryView.swift` — added 5th picker case `FILES`.
  - `Views/Windows/MainSettingsView.swift` — new "FILE INDEXING" toggle + folder list with ADD FOLDER (NSOpenPanel) + SCAN NOW buttons.
  - `App/AppDelegate.swift` — creates + configures both services; auto-starts periodic scan if enabled.
  - **Adaptation note:** user explicitly asked only user-picked folders (Obsidian vault), no auto-scan of Downloads/Documents. We diverge from Omi's onboarding pipeline accordingly.
  - **Verify:** Settings → File Indexing toggle on → Add Folder (pick your Obsidian vault) → SCAN NOW → wait 30-60 sec → Library → FILES shows indexed files → Memories tab shows extracted facts with `sourceFile` matching file paths.
  - **Check DB:** `sqlite3 ~/Library/Application\ Support/MetaWhisp.store "SELECT ZFILENAME, ZFOLDER FROM ZINDEXEDFILE LIMIT 10;"` and `"SELECT ZCONTENT, ZSOURCEFILE FROM ZUSERMEMORY WHERE ZSOURCEFILE IS NOT NULL LIMIT 10;"`
- **E2** ⏸️ TESTING PENDING — Apple Notes reader + memory extraction. Implementation 2026-04-19:
  - `Services/Indexing/AppleNotesReaderService.swift` — NEW. AppleScript bridge (Process + osascript) fetches up to 40 recent notes (id/title/body/folder/modified), parses `<<<END>>>`-delimited output. Filters new notes via `sourceFile: "apple-note:<id>"` dedup. Sends each note body (max 4K chars) to Pro proxy with Omi-strict memory prompt. Saves UserMemory with sourceApp="Apple Notes", sourceFile="apple-note:\<id\>". Min confidence 0.7, max 3 memories per note.
  - `Models/AppSettings.swift` — `appleNotesEnabled: Bool = false`, `appleNotesInterval: Double = 43200` (12h default).
  - `Views/Windows/MainSettingsView.swift` — Apple Notes section with toggle + SCAN NOW button.
  - `App/AppDelegate.swift` — create + configure + start periodic if enabled.
  - **Adaptation from Omi:** Omi reads NoteStore.sqlite directly via GRDB (requires Full Disk Access); we use AppleScript (requires Automation permission prompt, simpler, full body access). Tradeoff: dependent on Notes.app running; slightly slower than SQLite but no new dependencies.
  - **Permission flow:** first SCAN NOW triggers macOS "MetaWhisp wants to control Notes" dialog. User approves once.
  - **Verify:** Settings → Apple Notes toggle on → SCAN NOW → approve Automation dialog → wait 30-60 sec → Memories tab shows extracted facts from recent notes with sourceFile prefix "apple-note:". Check: `sqlite3 ~/Library/Application\ Support/MetaWhisp.store "SELECT ZCONTENT, ZSOURCEFILE FROM ZUSERMEMORY WHERE ZSOURCEFILE LIKE 'apple-note:%' LIMIT 10;"`
- **E3** ⏸️ TESTING PENDING — Calendar reader via EventKit. Implementation 2026-04-19:
  - `Services/Indexing/CalendarReaderService.swift` — NEW. EventKit-based: requestFullAccessToEvents (macOS 14+), predicateForEvents window=-30d…+14d. For each upcoming non-cancelled non-declined event → create TaskItem with dueAt=startDate + sourceApp="Calendar". Dedup by (title.lowercase, hourBucket). Also sends last 80 events to LLM for pattern memories ("User has weekly 1-on-1 with Vlad on Tuesdays"), sourceApp="Calendar" + sourceFile="calendar".
  - `Models/AppSettings.swift` — `calendarReaderEnabled: Bool = false`, `calendarReaderInterval: Double = 21600` (6h).
  - `Resources/Info.plist` — added `NSCalendarsFullAccessUsageDescription` + legacy `NSCalendarsUsageDescription`.
  - `Views/Windows/MainSettingsView.swift` — CALENDAR toggle + SCAN NOW.
  - `App/AppDelegate.swift` — create + configure + start periodic.
  - **Adaptation from Omi:** Omi's `CalendarReaderService.swift` reads Google Calendar via browser-cookie scraping + Python SAPISID auth — fragile, cross-browser. We diverge to EventKit (Apple-native) — covers iCloud / Google / Exchange via system-aggregated calendars. No browser dependency. First run prompts for Calendar permission via standard macOS dialog.
  - **Verify:** Settings → Calendar toggle on → SCAN NOW → approve Calendar permission → wait 30-60 sec → Tasks tab shows upcoming events with correct dueAt; Memories tab shows pattern memories for recurring meetings. Check `sqlite3 ~/Library/Application\ Support/MetaWhisp.store "SELECT ZTASKDESCRIPTION, ZDUEAT FROM ZTASKITEM WHERE ZSOURCEAPP='Calendar' LIMIT 10;"` and similar for ZUSERMEMORY WHERE ZSOURCEFILE='calendar'.
- **E4** ⏭️ DEFERRED (2026-04-19) — Gmail. OAuth Google + Gmail API is a large scope compared to E1-E3 and Omi uses fragile browser-cookie path. User opted to skip for now. Revisit when email context becomes critical. Possible alternative paths: (A) full OAuth Google implementation, (B) Apple Mail via AppleScript (matches E2 pattern), (C) stay skipped — Apple Mail + Notes + Calendar cover most cases.
- **E5** ⏭️ DEFERRED (2026-04-19) — Unified periodic runner. Not critical: each reader (E1/E2/E3) already has its own timer via AppDelegate. Revisit if timer coordination becomes a concern (overlapping LLM calls, conflicting scans).

### Phase 4: Knowledge Graph (Brain Map)

- **KG1** LocalKGNode + LocalKGEdge SwiftData models
- **KG2** Entity extraction from memories → auto-populate nodes (people, projects, concepts)
- **KG3** Edge inference (who knows who, what uses what)
- **KG4** Graph visualization UI (force-directed layout like Omi screenshot)

### Phase 5: Goals + Task richness

- **G1** Goal SwiftData model (boolean/scale/numeric) + UI card
- **T1** Add to TaskItem: tags, priority, recurrenceRule, sortOrder, indentLevel
- **T2** Today / No Deadline / Overdue grouping
- **T3** AI dedup — detect semantic duplicates, auto-dismiss

### Phase 6+ — Voice communication roadmap (deferred, tracked)

User explicit ask 2026-04-19: premium TTS + more Omi voice features revisited after Phase 6 MVP ships.
- **Premium TTS (OpenAI / ElevenLabs)** — Omi's "Sloane" voice is cloud TTS, not AVSpeechSynthesizer. Options: (a) direct OpenAI API with user's key, (b) new Pro-proxy endpoint `/api/pro/tts`. Revisit after AVSpeechSynthesizer MVP ships.
- **Research Omi voice-communication features** — user flagged "у Omi есть много функций про голосовые коммуникации". Deeper read of Omi's FloatingControlBar + ACPBridge needed. Candidates: streaming transcription, voice selector with cloud voices, wake-word, voice commands / macros, multi-speaker diarization, voice-to-action.

### Phase 6: Voice questions + TTS ⏸️ TESTING PENDING

**Shipped 2026-04-19.** MVP scope only: long-press Right ⌘ → voice question → TTS reply via AVSpeechSynthesizer.
**Deferred to Phase 6+:** premium cloud TTS (OpenAI / ElevenLabs for Omi-level "Sloane" voice), floating bar UI, streaming transcription, wake-word, voice commands.

- `Services/TTS/TTSService.swift` — NEW. AVSpeechSynthesizer wrapper. Picks voice by user setting or heuristic (Cyrillic text → ru-RU, else system locale). Rate mapping 0.5x–2.0x → AVSpeechUtterance rate range. Exposes `availableVoices()` filtered to en + ru families for Settings picker.
- `Services/System/HotkeyService.swift` — extended. Right ⌘ Toggle mode now distinguishes tap (`< 0.4s` → dictation toggle as before) from long-press (≥ `voiceQuestionHoldMs` default 500ms → voice question). Two new callbacks `onVoiceQuestionStart` / `onVoiceQuestionStop`. Timer cancelled if any other key arrives during hold.
- `Services/System/TranscriptionCoordinator.swift` — added `voiceQuestionMode: Bool` flag + `startVoiceQuestion()` / `stopVoiceQuestion()` methods. When flag set, transcription path routes finalText to `chatService.send(..., source: .voice)` instead of clipboard paste. Also added `weak var chatService: ChatService?`.
- `Services/Intelligence/ChatService.swift` — `send(_:source:)` now takes `Source` enum (.typed / .voice). After AI reply saved, speaks aloud via `ttsService` if `ttsVoiceQuestions` (source=voice) or `ttsTypedQuestions` (source=typed) toggle is on.
- `Models/AppSettings.swift` — `ttsVoiceQuestions: Bool = true`, `ttsTypedQuestions: Bool = false`, `voiceQuestionHoldMs: Double = 500`, `ttsVoice: String = ""` (empty = system default), `ttsSpeed: Double = 1.0`.
- `Views/Windows/MainSettingsView.swift` — new VOICE section with the two SPEAK-answers toggles, voice picker (system default + TTSService.availableVoices filtered to en/ru), preview button, speed slider.
- `App/AppDelegate.swift` — creates `ttsService`, wires `coordinator.chatService = chatService`, `chatService.ttsService = ttsService`, passes `onVoiceQuestionStart/Stop` to `hotkeyService.register`.
- **UX notes:** Right ⌘ short tap (existing dictation flow) now has a 500ms observation window — tap must be <0.4s to fire. Between 0.4s and 0.5s → neither fires (safety gap). Long-press mode triggers at 500ms if still held with no other keys.
- **Verify:** toggle VOICE ON → hold Right ⌘ 500ms+ → speak "what do I know about Overchat" → release → answer appears in MetaChat AND speaks aloud. Short tap Right ⌘ → normal dictation. Left ⌘ untouched.

### Phase 6+: Proactive + Floating Bar (deferred)

- **P1** Floating Bar (borderless floating window with push-to-talk + text input) — addresses user's "hotkey from anywhere" ask (P5 previous)
- **P2** TTS (speak AI answers aloud) with voice selector
- **P3** Proactive suggestions engine (like "Next step → Ask omi" card on Home)

### Phase 7: Daily Summary + Notifications polish

- **N1** Daily Summary at scheduled time (per Omi settings — configurable, default 10PM)
- **N2** Per-category notification toggles (Focus/Task/Insight/Memory)
- **N3** Insight Notifications system

### Phase 8: Agent integration (Claude OAuth + task agent)

- **A1** Claude OAuth provider ("Your Claude Account") — copy Omi's `ClaudeAuthSheet`
- **A2** Workspace selector (project directory for chat context)
- **A3** Agent-on-task (Claude processes task description → does work). tmux integration copy from Omi
- **A4** Browser Extension / automation

### Phase 9: Beyond MVP

- Conversations visibility (private/shared/public)
- Speaker diarization
- Folders
- BLE Omi wearable
- Vector embeddings + RAG improvements
- Dev Mode (AI modifies own source code)
- Apple Foundation Models local LLM

---

## What's currently in flight

### Testing Pending (не блокирует)

**B1 Tasks** — 1 task in DB ("Протестировать"), confirms pipeline works. Formal 3 test scenarios (explicit/vague/dedup) not run yet. Indirect verification via B2: MetaChat correctly retrieved the task through RAG.

**B2 MetaChat** — ✅ VERIFIED 2026-04-19 by user. 8 messages in DB across 3 rounds. RAG pulled UserMemory (MetaWhisp, Clawdick), TaskItem (Протестировать), honestly declined out-of-scope requests (web browsing). Moving to Done.

**C1.1 Conversation grouping** — just deployed 2026-04-19, awaiting live verification after user dictates.

### Unresolved from prior conversations

- **Manual Add Memory** — user said "никто не будет пользоваться этим, надо auto" — **skipped**, focus на auto extraction paths (Phase 3 readers + Phase 2 screen pipeline)
- **C1.1 started but not committed** — `Models/Conversation.swift` created, not yet wired. Must decide: continue or rewrite as part of Phase 1 restart with full C1.x plan

---

## Protocol (железный)

1. **Session start:** read `BOOT.md` → `KARPATHY.md` → `WAL.md` → `BACKLOG.md` полностью.
2. **Track selection:** user выбирает ровно 1 track at a time.
3. **Before coding:** open corresponding Omi Swift file, read implementation. Reflect in scope proposal as "Omi reference: `path/to/file.swift:NNN`".
4. **Scope:** concrete file list + success criteria. Wait user OK.
5. **Code:** surgical changes only.
6. **Verify:** diagnostic script or manual test against success criteria.
7. **Done:** update BACKLOG + WAL.

New ideas → `Proposed`, no auto-start.
