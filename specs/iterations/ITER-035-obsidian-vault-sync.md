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

**Vault layout (confirmed by user 2026-05-12 morning):**

Two top-level patterns:
- **Date-first** для transient artefacts (voices, meetings, tasks) — chronological view.
- **Project-first** для durable knowledge (memories) — knowledge base view.

```
<obsidianVaultPath>/MetaWhisp/
  README.md                              # — описание структуры, generated once

  2026-05-12/                            # день — корень для time-bound entities
    meetings/
      14h00--standup-with-sam.md         # отдельный файл на каждый meeting
      16h30--client-call-acme.md
    voices/
      09h15--MetaWhisp.md                # project tag из Conversation.primaryProject
      11h22--Untagged.md                 # если project не присвоен
    tasks/
      T-0001--починить-окно.md           # ID-prefixed for stability; 2-way delete (см. ниже)
      T-0002--релизнуть-1-3-4.md

  Memories/                              # knowledge base — project-first, date-second
    MetaWhisp/
      2026-05-12--user-prefers-bullets.md
      2026-05-11--auto-promote-pro.md
    AcmeCorp/
      2026-05-08--quarterly-deadline.md
    General/                             # default project, если UserMemory.project == nil
      2026-05-12--bought-milk.md

  Insights/                              # отдельная папка под ITER-027 surfaced insights
    2026-05-12/
      09h22--credentials-visible.md
```

**Two-way delete behaviour для tasks:**
- Юзер mark task as completed (checkbox) → файл **остаётся**, frontmatter `completed: true` обновляется.
- Юзер dismiss task / delete task → файл **удаляется с диска**.
- Cleanup на bulk export: orphaned `Tasks/T-NNNN.md` файлы (нет соответствующего row в SwiftData) удаляются.

**Project-tag derivation:**
- **Voices/Meetings:** `Conversation.primaryProject` (already в SwiftData) → string used as filename suffix. Если nil → `"Untagged"`.
- **Memories:** NEW field `UserMemory.project: String?` (см. Step 1b ниже). Default `"General"`.

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

- [ ] **Step 1 — AppSettings extensions:** добавить `obsidianVaultPath: String = ""`, `obsidianSyncEnabled: Bool = false`, `obsidianLastFullSyncAt: Date?`, `obsidianIncludeScreenActivity: Bool = false` в `AppSettings.swift`
- [ ] **Step 1b — UserMemory.project field:** добавить `var project: String?` в `Models/UserMemory.swift`. SwiftData lightweight migration (Optional field → no schema version bump). Default nil → render as `Memories/General/...`
- [ ] **Step 2 — Pure rendering:** `Services/Export/ObsidianMarkdownRenderer.swift` — pure-function `static func render(_ entity: ExportableEntity) -> String` для каждого type (HistoryItem, Conversation, TaskItem, UserMemory, ExtractedInsight). Test первым: `ObsidianMarkdownRendererTests.swift` со всеми happy + edge cases (long text, emoji, кириллица в slug, missing fields)
- [ ] **Step 3 — Filename helpers:** pure functions
  - `slugForFilename(_ text: String) -> String` — strip emoji, keep кириллица, kebab-case, max 60 chars, collapse repeated dashes
  - `dateFolder(_ date: Date) -> String` → `"2026-05-12"`
  - `timestampPrefix(_ date: Date) -> String` → `"14h00"` для within-day ordering
  - все pure, full test coverage
- [ ] **Step 4 — Service shell:** `Services/Export/ObsidianExporter.swift` (@MainActor) с API skeleton: `bulkExportAll()`, `exportConversation(_:)`, `exportHistoryItem(_:)`, `exportTask(_:)`, `exportMemory(_:)`, `exportInsight(_:)`, `deleteTaskFile(_:)`. Логирует через NSLog, не пишет файлы пока
- [ ] **Step 5 — File IO:** реальная запись через FileManager. Создание date-folder + sub-folder если не существуют. Atomic write через `.atomicWrite`. Тесты через temp dir
- [ ] **Step 6 — Bulk export + cleanup:** `bulkExportAll()` итерирует все non-dismissed entities. Plus: scan vault для orphaned `Tasks/T-*.md` → delete (no SwiftData row). Idempotent: re-running не дублирует, overwrite same-id files
- [ ] **Step 7 — Subscribe to changes:** wire в `HistoryService`, `ConversationGrouper`, `TaskExtractor`, `MemoryExtractor`, `InsightStorage`. После `ctx.save()` — `Task { await obsidianExporter.exportXxx(id) }`. **Tasks dismiss/delete** — отдельный hook на `TaskItem.isDismissed` change → `deleteTaskFile(id)`
- [ ] **Step 8 — UI:** в `MainSettingsView.swift` секция **OBSIDIAN SYNC**: folder picker (NSOpenPanel), toggle, bulk export button, optional screen activity toggle. Progress bar для bulk export через `@Published var stats`
- [ ] **Step 9 — README generator:** при первом export пишем `MetaWhisp/README.md` с описанием structure + tagging conventions + frontmatter schema
- [ ] **Step 10 — Manual smoke:** записать 5 voices (с/без project tag), 1 meeting, 2 tasks (одну dismiss), 3 memories → проверить структуру в Finder + Obsidian. Verify two-way delete для tasks
- [ ] **Step 11 — Bulk export smoke:** прогнать на всей DB (5000+ items) → time-to-complete + spot-check correctness. Verify orphan cleanup
- [ ] **Step 12 — Spec close:** обновить WAL.md + commit + push

**Karpathy reminder:** не пилить Step 4-5 пока Step 2 не зелёный по тестам. Pure rendering — это самое важное правильное место для tests.

## Estimated effort

- Code: ~1.5 дня (~12 hours active).
- Testing + integration: ~0.5 дня.
- Total: **~2 дня** до production-ready.
