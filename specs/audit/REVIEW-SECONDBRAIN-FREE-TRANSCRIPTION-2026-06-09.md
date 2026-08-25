# Code Review: Second Brain + локальная транскрибация (Free) — 2026-06-09

Скоуп: Services/Transcription, Services/License, Services/Intelligence, Services/Indexing, Services/Export, Services/MCP, Onboarding.
Кросс-чек с `specs/audit/SECOND-BRAIN-REVIEW-2026-06-07.md` и `FULL-APP-AUDIT-2026-05-31.md`.
Номера строк приблизительные — перепроверять перед правкой.

---

## TL;DR

**Free-версия сломана out-of-the-box:** онбординг позволяет завершить настройку без работающего движка транскрибации (кнопка DOWNLOAD модели — фейковая, симулирует прогресс таймером). Пользователь жмёт Right ⌘ и получает ошибку.

**Second Brain функционально полон, но операционно хрупок:** тихие потери данных (extractors скипаются при параллельном закрытии разговоров, `try? save()` глотает ошибки), внешние поверхности (Obsidian, MCP snapshot) расходятся с БД, weekly digest генерируется, но недоступен в UI.

**Лицензирование:** `isPro = true` ставится из кэша Keychain до серверной верификации — гейт обходится локально.

---

## P1 — Критично (блокирует пользователей / потеря данных)

### FREE-1. Онбординг: кнопка скачивания модели не скачивает модель
`Views/Windows/Onboarding/OnboardingModelPage.swift:89–102`
`startDownload()` симулирует прогресс через `Timer`, ставит `transcriptionEngine = "ondevice"` — модель не скачана. Free-пользователь завершает онбординг, транскрибация падает с "No model loaded".
**Фикс:** вызывать `ModelManagerService.shared.startDownload()`, биндить реальный `phase` к UI, блокировать NEXT пока `isDownloaded(modelId) == false`.

### FREE-2. Онбординг завершается без работающего движка
`Views/Windows/OnboardingWindowController.swift:16–22`, `OnboardingTryItPage.swift`
`complete()` безусловен; try-it page не проверяет готовность движка и не блокирует переход при ошибке. Cloud-таб: TextField для API-ключа read-only (`.constant("")`), VERIFY ничего не верифицирует (`OnboardingModelPage.swift:108–120`).
**Фикс:** гейт на завершение — хотя бы один работающий путь (модель скачана / ключ валиден / Pro активен); рабочий ввод и реальная валидация ключа; try-it показывает ошибку и не пускает дальше.

### LIC-1. `isPro` ставится без серверной верификации
`Services/License/LicenseService.swift:32–46` (`isPro = licenseKey != nil && !empty`)
Стейл/подложенный ключ в Keychain = Pro на всю сессию до завершения async `verify()`. Offline grace не ограничен по времени (строки 141–156).
**Фикс:** раздельный стейт cached vs verified; Pro-маршруты только по verified; TTL для offline grace (например 72 ч).

### SB-1. Параллельное закрытие разговоров теряет memories/tasks
`Services/Intelligence/ConversationGrouper.swift:225–234`
Extractors проверяют `isRunning` и молча выходят — второй разговор не обрабатывается. Дыры в Second Brain без следов.
**Фикс:** персистентная очередь извлечения per-conversation (pending/running/done/failed) + backfill при запуске.

### SB-2. Мутации из чата «успешны» при упавшем save
`Services/Intelligence/ChatToolExecutor.swift:230–255, 269–273, 334–367, 621–623`
`try? ctx.save()` + `ok = true` всегда. Чат говорит «Marked done», БД не изменилась. Мутации не триггерят re-export Obsidian / MCP snapshot.
**Фикс:** throw на ошибке save, `ok = false`; централизованный mutation-сервис с хуками Obsidian/MCP.

### SEC-1. Секреты: fallback на plaintext `~/.secrets` остаётся навсегда (AUD-024 не закрыт)
`Models/AppSettings.swift:340–393`
Миграция в Keychain одноразовая; при пустом Keychain `load()` читает plaintext-файл. API-ключи и лицензия остаются читаемыми на диске.
**Фикс:** после подтверждённой миграции удалять `.secrets`; убрать постоянный fallback.

---

## P2 — Высокий (рассинхрон, стейл-данные, UX free-версии)

### SB-3. Obsidian и MCP snapshot расходятся с БД
- `Services/MCP/MCPSnapshotService.swift:91–95` — `snapshotNow()` никогда не вызывается после мутаций (лаг до 5 мин для Claude Desktop).
- `Views/Windows/TasksView.swift:312–316, 247–249`, `MemoriesView.swift:200–204, 303–307`, `Services/Export/ObsidianExporter.swift:398–403` — complete/edit/dismiss не ре-экспортят .md; нет удаления файла памяти.
**Фикс:** единая точка мутаций (см. SB-2) → re-export + snapshot refresh.

### SB-4. File RAG отдаёт удалённые файлы
`Services/Indexing/FileIndexerService.swift:111–157, 186–192`; ChatService RAG (~:1097–1110)
Скан не удаляет записи исчезнувших путей; RAG не проверяет существование файла. Удалённые заметки утекают в контекст чата.
**Фикс:** реконсиляция путей при каждом скане + tombstone; проверка существования в RAG.

### SB-5. Apple Notes: стоп на 40 заметках + повторная обработка пустых
`Services/Indexing/AppleNotesReaderService.swift:20–21, 79–87, 183–203, 350–358`
Хард-кап 40; «processed» = существует UserMemory → заметки без результата гоняются в LLM каждый скан; правки заметок не переиндексируются.
**Фикс:** пагинация по modifiedAt; отдельный processing-state (lastResult/lastError/modifiedAt).

### SB-6. Weekly Patterns недостижимы в UI + одна битая JSON = 6 дней без digest
`WeeklyPatternDetector.swift:80–83, 151–162, 282–301, 346–364`; `MainSettingsView.swift:2053`
PatternDigest пишется, UI-потребителя нет; нотификация ведёт не туда; parse-fail сохраняется как «успех» и блокирует ретраи 6 дней.
**Фикс:** UI-секция для digest; nil при parse-fail; корректный роутинг нотификации.

### SB-7. Regenerate daily summary удаляет старый recap до создания нового
`Services/Intelligence/DailySummaryService.swift:90–105, 118–157`
Delete → generate может вернуть nil (нет LLM / не Pro / пустой день) → recap потерян.
**Фикс:** generate во временный объект, замена только после успешного save.

### SB-8. Тогглы Second Brain не применяются до перезапуска
`App/AppDelegate.swift:729–792, 855–910`; `MainSettingsView.swift:1323–1343, 1934–2045`
Daily/Weekly/FileIndexing/AppleNotes/Calendar стартуют только при launch; onChange-обзёрверов нет.
**Фикс:** центральный settings-observer, start/stop шедулеров на лету.

### FREE-3. Вводящие в заблуждение ошибки в cloud-режиме
`Services/Transcription/CloudWhisperEngine.swift:~58`; `TranscriptionCoordinator.swift:313–315`
Отсутствие API-ключа кидает `.modelNotLoaded` → «No model loaded. Download a model first». Нет paywall/upsell-сообщений на гейтнутых фичах — только криптичные ошибки.
**Фикс:** отдельный `TranscriptionError.noAPIKey`; для free на Pro-фичах — явный экран «доступно в Pro» вместо ошибки.

### FREE-4. Download phase = .done без проверки модели на диске
`Services/Transcription/ModelManagerService.swift:82–112`
Прерванная загрузка может оставить UI в done-состоянии; нет ретрая.
**Фикс:** верификация `isDownloaded()` перед `.done`, иначе `.failed` + retry.

### FREE-5. Pro-таб онбординга: покупка без подтверждения активации
`OnboardingModelPage.swift:147–165`
Открывает браузер и ничего не ждёт; deep-link активация происходит молча.
**Фикс:** подписка на `$isPro` + автопереход / кнопка «Проверить активацию».

---

## Галлюцинации транскрибации (добавлено 2026-06-09 по репорту: RU-речь → беглый EN-бред в диктовках и долгих созвонах)

### TR-3 (P1). EN-prompt bias не загейчен везде — основной кандидат на причину
- Митинги: `App/AppDelegate.swift:1421` — `BrandGlossary.canonicalNames()` (English-only) передаётся в **каждый** чанк безусловно. В диктовке этот фикс есть (`TranscriptionCoordinator.swift:278` + `TranscriptionLanguageResolver.shouldIncludeBrandGlossary`), в митингах — нет.
- Диктовка: `Services/System/TranscriptionCoordinator.swift:268` — значения correction dictionary идут в prompt без гейта по языку.
- Механизм: английский initial_prompt смещает декодер к `<|en|>` → русская речь выходит как fluent English nonsense (задокументировано в `TranscriptionLanguageResolver.swift:23–25` как root cause RU→EN).
**Фикс:** гейтить ВСЕ promptWords (glossary + corrections) через `shouldIncludeBrandGlossary` в обоих путях.

### TR-4 (P2). Ограничить temperature fallback
`Services/Transcription/WhisperKitEngine.swift:63–75` — `temperature: 0`, но `temperatureFallbackCount` не задан (дефолт WhisperKit ретраит до t=1.0). Высокотемпературный выход = связный бессмысленный текст.
**Фикс:** `temperatureFallbackCount: 1` (или 0) + дропать сегмент, не прошедший пороги.

### TR-5 (P2). Использовать метрики уверенности вместо только паттерн-листа
- Cloud: `CloudWhisperEngine.swift:214–224` — `verbose_json` запрашивается, но `avg_logprob` / `no_speech_prob` / `compression_ratio` не парсятся и не используются.
- Local: результаты WhisperKit содержат те же метрики per-segment — игнорируются.
**Фикс:** дропать сегменты с `no_speech_prob > 0.5 && avg_logprob < -1.0`, `compression_ratio > 2.4`. Паттерн-лист оставить как второй слой.

### TR-6 (P2). Пиновать язык на весь митинг
`AppDelegate.swift:1407` — при language="auto" каждый 5-мин чанк детектит язык заново → флип-флоп RU/EN внутри одной записи.
**Фикс:** детект на первом озвученном чанке → пин для остальных чанков обоих стримов.

### TR-7 (P3). Tiny-модель для RU
Онбординг предлагает Tiny (40 MB) как равноправный вариант — для русского у Tiny катастрофический уровень галлюцинаций. Рекомендовать large-v3-turbo по умолчанию, предупреждение в UI при выборе Tiny + не-EN языке.

---

## P3 — Средний / низкий

- **SB-9.** Extractors сохраняют пустые/whitespace memories и tasks — `TaskExtractor.swift:510–540`, `MemoryExtractor.swift:423–441`, `FileMemoryExtractor.swift:212–215`. Фикс: trim + reject empty.
- **SB-10.** Счётчик «N active» в TasksView включает завершённые — `TasksView.swift:24–26, 100–101`.
- **TR-1.** Фильтр галлюцинаций может дропать легитимные короткие реплики («музыка» и т.п.) в митингах — `WhisperKitEngine.swift:94–190`. Фикс: ослабить для длинных записей.
- **TR-2.** Устаревший комментарий в `TranscriptionLanguageResolver.swift:25–28` (баг уже починен).

---

## Что уже исправлено (статус прошлых аудитов)

- **AUD-025** (токен в query/логах) — ✅ исправлено: Authorization header, токен не логируется.
- **AUD-026** (стейл Pro-креды) — частично: Keychain чистится, но offline grace без TTL (см. LIC-1).
- **AUD-024** (plaintext секреты) — частично (см. SEC-1).
- Все 13 находок `SECOND-BRAIN-REVIEW-2026-06-07.md` подтверждены в коде, ни одна не исправлена.

---

## Мастер-чек-лист (порядок работ)

### Итерация 1 — Free работает out-of-the-box
- [ ] FREE-1: реальная загрузка модели в онбординге
- [ ] FREE-2: валидация движка на try-it и при завершении онбординга; рабочий ввод API-ключа
- [ ] FREE-3: понятные ошибки + paywall-сообщения вместо криптичных ошибок
- [ ] FREE-4: верификация модели на диске, retry загрузки

### Итерация 2 — целостность данных Second Brain
- [ ] SB-1: очередь извлечения + backfill
- [ ] SB-2: централизованные мутации, ошибки save не глотаются
- [ ] SB-3: re-export Obsidian + MCP snapshot из mutation-сервиса
- [ ] SB-7: безопасный regenerate daily summary

### Итерация 3 — лицензия и безопасность
- [ ] LIC-1: verified vs cached isPro, TTL offline grace
- [ ] SEC-1: добить миграцию секретов, удалить `.secrets`
- [ ] FREE-5: подтверждение активации Pro в онбординге

### Итерация 4 — индексация и синтез
- [ ] SB-4: реконсиляция file index, RAG не отдаёт удалённое
- [ ] SB-5: Apple Notes пагинация + processing-state
- [ ] SB-6: UI для weekly digest, ретраи при битом JSON
- [ ] SB-8: тогглы применяются без перезапуска

### Итерация 5 — галлюцинации транскрибации
- [ ] TR-3: гейт EN-prompt (glossary + corrections) по языку в диктовке и митингах
- [ ] TR-4: ограничить temperature fallback
- [ ] TR-5: фильтрация по avg_logprob / no_speech_prob / compression_ratio (local + cloud)
- [ ] TR-6: пин языка на весь митинг
- [ ] TR-7: предупреждение про Tiny для не-EN

### Итерация 6 — полировка
- [ ] SB-9, SB-10, TR-1, TR-2

### Тесты для добавления
- [ ] Два разговора закрываются одновременно → оба извлечены
- [ ] save падает в ChatToolExecutor → пользователь видит ошибку, успеха нет
- [ ] complete/edit/dismiss → БД, Obsidian, MCP обновлены атомарно
- [ ] Удалённый файл отсутствует в RAG после скана
- [ ] Apple Notes: 100 заметок, первые 40 обработаны → скан продолжается с 41-й
- [ ] Битый weekly JSON → ретрай не блокируется на 6 дней
- [ ] Regenerate fail → старый summary сохранён
- [ ] Онбординг: нельзя завершить без работающего движка
- [ ] Стейл-ключ в Keychain offline → Pro-маршруты не активны после TTL
