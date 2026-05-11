# ITER-035 — Obsidian Vault Sync (one-way, app → vault)

**Проблема:** все юзерские данные (voices, meetings, tasks, memories, conversations, insights) живут только в SwiftData store на одной машине. Нельзя:
- открыть свою «вторую память» в Obsidian / Logseq / любом markdown editor
- забэкапить в Git
- скормить ChatGPT/Claude/Cursor через filesystem-MCP

Решаем one-way sync: SwiftData → markdown файлы в указанной пользователем папке Obsidian vault. App = source of truth. Edits в Obsidian (пока) не синкаются обратно — это ITER-038+.

## Reference patterns

- **Daily-publish bot** в `/Users/android/.openclaw/meet-recorder/TranscribeAI/website/scripts/daily-publish.py` — пример bulk-export процесса с git commit. Похожий pattern: subscribe на изменения, рендерим в markdown, пишем в файл.
- **Obsidian community conventions:** YAML frontmatter с обязательными `id`, `type`, `created`, `tags`. Folder-based organisation. Wikilinks `[[note-name]]` для cross-references.
- **omi memory architecture (reference memory note):** Conversation = root entity, все остальное (Memories, Tasks, DailySummary) ссылается через `conversation_id`. Mirror в нашем folder layout.

## Scope

### 1. `Models/AppSettings.swift`
- `+obsidianVaultPath: String = ""` — пустая строка = sync выключен.
- `+obsidianSyncEnabled: Bool = false` — toggle для UI.
- `+obsidianLastFullSyncAt: Date?` — для bulk export gating.

### 2. `Services/Export/ObsidianExporter.swift` — NEW (@MainActor)

**API:**
```swift
@MainActor
final class ObsidianExporter: ObservableObject {
    @Published var isExporting = false
    @Published var lastError: String?
    @Published var stats: ExportStats = .empty  // counts by entity type

    func configure(modelContainer: ModelContainer)
    func bulkExportAll() async             // initial — все entities
    func exportConversation(_ id: UUID) async
    func exportHistoryItem(_ id: UUID) async
    func exportTask(_ id: UUID) async
    func exportMemory(_ id: UUID) async
}
```

**Vault layout:**
```
<obsidianVaultPath>/MetaWhisp/
  README.md                    # — описание структуры, generated once
  Conversations/
    2026-05-12--standup-with-sam.md
    2026-05-12--quick-note.md
  Voices/
    2026-05-12-21h05--quick-note.md
  Tasks/
    T-001--починить-окно.md
    T-002--собрать-релиз.md
  Memories/
    M-2026-05-08--sam-prefers-async.md
  Insights/
    I-2026-05-12--credentials-visible.md
  Screen/                      # optional, off by default — отдельный toggle
    2026-05-12.md              # daily aggregate
```

**Markdown rendering rules:**
- YAML frontmatter с `id`, `type`, `created`, `updated`, `source_app` (если есть), `conversation_id` (если линк), `tags`
- Body: cleaned transcription text (для HistoryItem/Conversation) или structured описание (для Task/Memory)
- Cross-references через wikilinks: `[[Conversations/2026-05-12--standup-with-sam]]` если есть `conversation_id`
- Filename: kebab-case + date prefix для grouping в Obsidian
- Slug извлекается из первых 5 слов transcript / title / content (см. `slugForFilename(_:)`)

### 3. SwiftData subscription wiring

В `HistoryService`, `ConversationGrouper`, `TaskExtractor`, `MemoryExtractor`, `InsightStorage` — после `ctx.save()`:
```swift
if AppSettings.shared.obsidianSyncEnabled {
    Task { @MainActor in
        await obsidianExporter.exportXxx(id)
    }
}
```

Не блокируем основной save. Errors silent (NSLog, не throw).

### 4. Bulk export script (one-shot)

`bulkExportAll()` — итерирует все non-dismissed entities, рендерит файлы. UI button «Export all to vault» в Settings. Прогресс через `@Published var stats`.

**Idempotent:** если файл с тем же `id` уже есть — overwrite (file is source mirror, not user-edited).

### 5. `Views/Windows/MainSettingsView.swift`

В Intelligence section добавить раздел **OBSIDIAN SYNC**:
- `Folder picker` → NSOpenPanel chooseDirectory. Запоминает в `obsidianVaultPath`.
- Toggle `Sync to Obsidian` → `obsidianSyncEnabled`.
- Button `Export all existing data` → вызывает `bulkExportAll()`. Прогресс bar.
- Sub-toggle `Include screen activity` → отдельный switch для дорогого Screen/ folder.

### 6. `App/AppDelegate.swift`

- Instantiate `obsidianExporter`.
- `configure(modelContainer:)` в setupServices.
- Wire callbacks через NotificationCenter ИЛИ через @ObservedObject + `objectWillChange` listeners.

## Edge cases

- **Vault path invalid / permissions denied** → `lastError` shows in UI, sync silently disables until path fixed.
- **Filesystem случилась — например vault on external drive unmounted** → fail gracefully, retry on next change.
- **Очень длинный transcript (>50KB)** → truncate body, добавить marker `[Truncated; full text in MetaWhisp]`.
- **Symbols in slug** (emoji, кириллица) → keep кириллица, strip emoji.
- **Conflict in filename** (два voice notes за одну минуту) → suffix `-2`, `-3`.

## Out of scope (defer to ITER-038)

- Two-way sync (Obsidian edits → back to SwiftData)
- Embedded media (screenshots, audio waveforms) в markdown
- Custom user templates per entity type
- Selective sync (per-conversation toggle)

## Acceptance

1. Toggle ON + указать `~/Documents/Vault` → создаётся папка `~/Documents/Vault/MetaWhisp/` со структурой
2. Запись voice note → через ≤2 сек появляется `Voices/<date>-<slug>.md` с правильным frontmatter
3. Создание task (через voice trigger) → `Tasks/T-NNN-slug.md`
4. Дальше mark task as done в app → файл обновляется (`completed: true` в frontmatter)
5. Bulk export 5000+ history items → проходит без ошибок, vault весит реальный размер
6. Открыть vault в Obsidian → структура папок отображается, wikilinks работают
7. Удалить vault folder → app не падает; на следующем write пере-создаёт пустую структуру

## Implementation checklist

- [ ] **Step 1 — Models:** добавить `obsidianVaultPath` / `obsidianSyncEnabled` / `obsidianLastFullSyncAt` в `AppSettings.swift`
- [ ] **Step 2 — Pure rendering:** `ObsidianMarkdownRenderer.swift` — pure-function `func render(_ entity: ExportableEntity) -> String`. Тесты сразу: `ObsidianMarkdownRendererTests.swift` для каждого entity type
- [ ] **Step 3 — Filename helper:** `slugForFilename(_ text: String, date: Date) -> String` — pure, тестируется
- [ ] **Step 4 — Service shell:** `ObsidianExporter.swift` с API skeleton, без реальной записи (NSLog only)
- [ ] **Step 5 — File IO:** реальная запись через FileManager. Test через temp dir
- [ ] **Step 6 — Bulk export:** `bulkExportAll()` итерация всех таблиц
- [ ] **Step 7 — Subscribe to changes:** wire в HistoryService / ConversationGrouper / TaskExtractor / MemoryExtractor / InsightStorage
- [ ] **Step 8 — UI:** Settings раздел с folder picker + toggle + bulk export button
- [ ] **Step 9 — README generator:** при первом export пишем `MetaWhisp/README.md` со structure docs
- [ ] **Step 10 — Manual smoke:** записать 5 voices, 1 meeting, 2 tasks → проверить vault структуру в Finder + Obsidian
- [ ] **Step 11 — Bulk export smoke:** прогнать на всей DB (5000+ items) → проверить time-to-complete + correctness
- [ ] **Step 12 — Spec close:** обновить WAL.md + memory с прогрессом

**Karpathy reminder:** не пилить Step 4-5 пока Step 2 не зелёный по тестам. Pure rendering — это самое важное правильное место для tests.

## Estimated effort

- Code: ~1.5 дня (~12 hours active).
- Testing + integration: ~0.5 дня.
- Total: **~2 дня** до production-ready.
