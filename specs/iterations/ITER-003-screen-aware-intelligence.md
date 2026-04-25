# ITER-003 — Screen-Aware Intelligence

**Проблема:** `ScreenContext` пишется каждые 30 сек (778+ строк в DB), но intelligence-сервисы его **не читают**:
- `ChatService` (MetaChat) не видит OCR — нельзя спросить "что я читал про X сегодня?"
- `MemoryExtractor` / `TaskExtractor` видят только `appName`/`windowTitle` метадату, не OCR — надиктовал "купи это" глядя на Amazon → task без контекста.

**Цель:** дать трём intelligence-сервисам доступ к screen OCR как к контексту. Минимальный surgical fix. Не делаем realtime reactive (гэп #3) и embeddings (гэп #4) — они отдельным треком после этого.

## Scope (3 правки + 1 bonus)

### 1. ChatService RAG расширение
- `Services/Intelligence/ChatService.swift`:
  - `+weak var screenContext: ScreenContextService?` (+ update `configure`)
  - `+fetchScreenContextLast24h() -> [(app:String, title:String, text:String)]` — SwiftData fetch `ScreenContext` за последние 24ч, cap 30 rows, сортировка по timestamp DESC, ocrText truncated до 200 chars/запись. Reference: `Chat/ChatPrompts.swift` SQL pattern.
  - В `buildUserPrompt` добавить `<recent_screen_activity>…</recent_screen_activity>` блок после `<pending_tasks>`.
- `App/AppDelegate.swift`: `chatService.screenContext = screenContext` в `setupServices`.

### 2. MemoryExtractor screen-enrichment
- `Services/Intelligence/MemoryExtractor.swift` в `buildPrompt` (после existing memories block):
  - Читать `screenContext?.recentContexts.last?.ocrText` (last 500 chars).
  - Splice как `<current_screen app="..." title="...">...</current_screen>` — чтобы LLM мог enrich voice transcript контекстом ("remind me to buy this" + OCR "Amazon iPhone 15" → memory "User wants iPhone 15").

### 3. TaskExtractor screen-enrichment
- `Services/Intelligence/TaskExtractor.swift`: параллельная правка в `buildPrompt`. Tasks extracted from voice теперь обогащены current screen state.

### 4. Dashboard card "LAST 24H ON SCREEN" (bonus, +30min)
- `Views/Windows/DashboardView.swift`:
  - Новая карточка: top-5 apps по суммарному времени на экране (group `ScreenObservation` by `appName`, sum `endedAt-startedAt`) за 24ч.
  - SF Symbol + app name + duration ("3h 12m"). Пустое состояние "No screen activity yet".

## Privacy / Cost guards

- OCR в chat prompt: max 30 записей × 200 chars = 6 KB. В пределах текущего 24 KB prompt cap.
- OCR в memory/task prompts: max 500 chars (одна запись, самая последняя). Почти бесплатно.
- Blacklist (Passwords/1Password) уже enforced в `ScreenContextService` — не капчерится → не попадёт в prompts by construction.
- Dashboard card читает уже-существующий `ScreenObservation`, zero new LLM calls.

## Acceptance criteria

1. **Chat screen-awareness:** открыть Chrome с документацией по Swift → через 1 мин написать в MetaChat "что я изучал на экране?" → ответ упоминает Swift / конкретный topic из OCR.
2. **Voice → task with screen:** открыть Amazon страницу с iPhone → надиктовать "remind me to order this" → TaskItem содержит "iPhone" или название продукта из OCR (не пустой "order this").
3. **Voice → memory with screen:** открыть блог про AI → надиктовать "this is interesting" → UserMemory содержит конкретный topic.
4. **Dashboard:** после часа активности → card показывает top-5 apps с длительностями.
5. Build green; `~/Library/Logs/MetaWhisp.log` без новых warning.

## Не делаем (отдельные треки)

- Realtime per-window-change extraction (#3)
- Embeddings / semantic search (#4)
- Retention / auto-purge (#5)
- Video chunks (#6)
