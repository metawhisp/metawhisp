# WAL — Write-Ahead Log

**Backlog:** открытые треки перечислены в `specs/BACKLOG.md` (source of truth). Ни одна работа не начинается без OK user'а.

**Session handoff:** `specs/HANDOFF.md` — обязательно прочитать при старте новой сессии (после BOOT/KARPATHY/BACKLOG).

**Shipped in session 2026-04-19 (summary):** Phases 0-3 end-to-end (Conversations, Screen pipeline, Readers), sidebar reorg 9→6 tabs, MetaChat brand + RAG + typing animation, Phase 6 voice questions (long-press Right ⌘ → TTS answer) with redesigned floating UI + STOP/Space/Esc controls. Phase 4/5/7/8 planned in BACKLOG. E4 Gmail + E5 unified runner deferred. Premium cloud TTS deferred to Phase 6+.

## Current Phase
**Iteration 2: File Indexing** — подгрузка папок пользователя → извлечение фактов → обогащение UserMemory → персональные советы. Планируется. Ждёт 3 scope-решений от пользователя (Q1/Q2/Q3 в sessions/2026-04-18-project-state.md §5).

**Предыдущая (Iteration 1):** Memory system + Insights — имплементировано, ждёт live-теста.

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
- [memory-extractor-align]: MemoryExtractor переписан под проверенный pattern. **Trigger:** fires on each voice transcription ≥20 chars (mirror `AdviceService.triggerOnTranscription`), НЕ periodic timer каждые 10 мин. **Input:** voice transcript, screen OCR больше не input для memories (garbage in → garbage out, prompt отвергал UI junk типа "0 clawd / SEO SKILL ~ 口、"). **Prompt:** adapted из — categorization test Q1→Q2, temporal ban ("Thursday"/"next week"), transient verb ban ("is working on"/"is building"), hedging ban, strict dedup with "contradiction is EXCEPTION → extract", mandatory double-check. **Cap:** max 2 memories per extraction. **Dedup window:** все non-dismissed memories (было 20, 1000). **Verify:** diagnostic script `/tmp/mw_test_extractor.py` — на idealfactual transcript ("Я CTO Overchat, использую Swift strict concurrency") вернул 2 memories с confidence=1.0. На non-factual ("я думаю", "покажи html") вернул [] — корректно. **Files:** `Services/Intelligence/MemoryExtractor.swift`, `Services/System/TranscriptionCoordinator.swift:37-41`, `App/AppDelegate.swift:90-93, 286-289, 382-388`. EXTRACT NOW кнопка теперь extract'ит из последнего transcript в History.

## In Progress
- [FEAT-0001§meeting-recording] (UX polish):
  - DONE: mic+system mix (Services/Audio/MeetingRecorder.swift)
  - DONE: фильтр галлюцинаций (App/AppDelegate.swift § stopMeetingRecording)
  - DONE: RMS < 0.0005 skip, RMS < 0.003 + isHallucination pattern match
  - DONE: waveform indicator во время записи — `MeetingWaveform` в Views/MenuBar/MenuBarView.swift (spec://audio/FEAT-0001#ui-contract.waveform)
  - DONE: Copy/Export/Delete на карточках meetings — `MeetingCardView` в Views/Windows/InsightsView.swift (spec://audio/FEAT-0001#ui-contract.copy-export)
  - TODO: auto-detection созвона → нотификация "Start recording?"

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
