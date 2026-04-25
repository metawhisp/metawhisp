# ITER-006 — Realtime Screen Reaction

**Проблема:** ScreenExtractor batch раз в час. Юзер открыл страницу с "Pay invoice" — нотификация прилетит через 0-60 мин (часто с parse fail — никогда). Reference реагирует **в течение минуты** на каждую смену окна.

**Gap #3** из ITER-003 audit. Копируем reference pattern:
- `ProactiveAssistantsPlugin.swift:65-71` — change-gated distribution to 4 assistants.
- `TaskAssistant.swift` — per-screenshot task extraction.

В этой итерации только **Task assistant**. Focus/Insight/Memory — отдельные треки после проверки value.

## Scope

### 1. `Models/AppSettings.swift`
- `+realtimeScreenReactionEnabled: Bool = false` (off by default — Pro-only cost, user opts in).

### 2. `Services/Screen/ScreenContextService.swift`
- `+var onContextPersisted: ((ScreenContext) -> Void)?` callback. Fires после `persistContext` на каждую новую запись.

### 3. `Services/Intelligence/RealtimeScreenReactor.swift` — NEW
- `@MainActor class RealtimeScreenReactor: ObservableObject`
- `configure(modelContainer:)`.
- `react(to context: ScreenContext)` async — guards + debounce + LLM + insert + notify.
- **Guards:**
  - `settings.realtimeScreenReactionEnabled` = true
  - OCR ≥ 100 chars (skip login screen / empty tabs)
  - Not during active meeting recording (`meetingRecorder.isRecording`)
  - App not in blacklist (system sensitive apps — Passwords, 1Password, etc.)
- **Debounce:** per-app cooldown 60 sec (match reference). In-memory `[String: Date]` map.
- **Rate limit:** global sliding window, max 30 LLM calls/hour. Drop extras silently.
- **Dedup:** skip if TaskItem with same lowered-description exists in last 24h.
- **Prompt:** short single-window classification — `{"hasTask": bool, "description": ≤12w verb-first, "dueAt": ISO-Z|null}`. Default hasTask=false.
- **On hit:** insert `TaskItem(sourceApp=app, screenContextId=ctx.id)` + `NotificationService.postNewTask(task, source: "Screen")`.

### 4. `App/AppDelegate.swift`
- Instantiate `realtimeScreenReactor`.
- `configure(modelContainer:)` in setupServices.
- Wire `screenContext.onContextPersisted = { [weak self] ctx in Task { await self?.realtimeScreenReactor.react(to: ctx) } }`.

### 5. `Views/Windows/MainSettingsView.swift`
- В Intelligence section (под SCREEN CONTEXT) — `toggleRow("REALTIME TASK DETECTION")`.
- Sub-label: "LLM checks each new window for actionable tasks. Max 30 checks/hour. Pro only."
- Показывается только когда `screenContextEnabled` ON.

## Cost profile

- Short prompt ~500 tokens + response ~100 = 600 tokens/call.
- 30 calls/hour × 24h = 720/day × 600 = 432K tokens/day.
- gpt-4o-mini $0.15/1M = ~$0.065/day = ~**$2/month max**. Внутри Pro proxy.
- Реально: с debounce 60s и skip на повторные окна — ~10 calls/hour в среднем.

## Acceptance

1. Toggle ON → открыть новую страницу с явным task ("Pay invoice $450 by Friday") в браузере → в течение ≤90 сек прилетает notification "New task from Screen: Pay invoice".
2. Листаешь тот же таб назад-вперёд → debounce блокирует повторные LLM calls (log: `[RealtimeReactor] Debounce: Chrome, last fired 23s ago`).
3. Открыл Zoom (meeting recording active) → no LLM calls (log: `[RealtimeReactor] Skipped: meeting active`).
4. Открыл Passwords.app → no LLM calls (log: `[RealtimeReactor] Skipped: app blacklisted`).
5. 30 calls за час → rate limit kicks in (log: `[RealtimeReactor] Rate limit: 30 calls in last hour`).

## Not in scope (future)

- Focus assistant (sustained-attention detection)
- Insight assistant (interesting article surfacing)
- Memory assistant (facts extraction per-window — currently batch via ScreenExtractor is fine)
- Video call frame-throttle (we don't record video)
