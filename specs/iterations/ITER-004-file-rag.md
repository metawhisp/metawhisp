# ITER-004 — File Content Access

**Проблема:** 287 файлов из Obsidian vault проиндексированы, 8 memories извлечены — но чат не видит сырой контент. На вопрос «в какой заметке я писал про Stripe» MetaChat молчит.

**Цель:** дать MetaChat retrieval по содержимому .md/.txt файлов + поиск в Library → Files. Без embeddings в этой итерации (substring match) — они в Part 2.

## Scope (разбит на 2 части)

### Part 1 — сейчас (A + E basics)

1. **`Models/IndexedFile.swift`** — `+var contentText: String?` (cap 20KB/файл).
2. **`Services/Indexing/FileIndexerService.swift`** — `+backfillContent()` метод: для всех extractable (.md/.txt/.markdown/.rtf) файлов где `contentText == nil` читает с диска → сохраняет. Zero LLM calls. Fast.
3. **Settings → SCAN NOW кнопка** — последовательность теперь: `scanAll` → `backfillContent` → `FileMemoryExtractor.runPass`. Существующие 287 файлов получат `contentText` на следующем клике.
4. **`Services/Intelligence/ChatService.swift`** — `+fetchRelevantFiles(query:, limit: 3)` — substring match на `contentText` + `filename` (case-insensitive). Возвращает top-3 файла с 300-char preview вокруг совпадения. Splice в `buildUserPrompt` как `<relevant_files>` блок после `<recent_screen_activity>`. System prompt обновить — "consult <relevant_files> for raw notes content".
5. **`Views/Windows/FilesView.swift`** — `+` search box сверху: фильтр по `filename OR contentText.contains(query)`. Просто filter, без highlighting в этой итерации.

### Part 2 — отдельным треком

- **B:** embeddings (OpenAI `text-embedding-3-small` ~$0.02/1M tokens) → cosine similarity top-K → лучше substring для семантических вопросов. Replaces step 4 retrieval strategy, keeps contentText schema.
- **D:** Obsidian writeback — voice → append в `Daily Notes/<today>.md` под настраиваемый header. Новый `ObsidianWriterService`.

## Cost / storage guards

- `contentText` capped at 20KB/файл. 287 files × 20KB ≈ 5-6 MB worst case, ~1-2 MB realistic (Obsidian notes обычно < 5KB).
- Chat retrieval: top-3 files × 300 char preview = ~1KB в prompt. Трогает 24KB cap минимально.
- Backfill: чистый disk read, no API calls, max 200 files per pass.

## Acceptance criteria

1. После SCAN NOW → все .md файлы в Obsidian vault имеют `contentText != nil` в DB (`sqlite3 … 'SELECT count(*) FROM ZINDEXEDFILE WHERE ZCONTENTTEXT IS NOT NULL AND ZFILEEXTENSION="md"'`).
2. MetaChat: «что я писал про \<topic из твоих нот\>» → ответ цитирует конкретный параграф из заметки.
3. Library → Files: search box фильтрует по filename AND content в realtime.
4. Build green, не больше +10KB в .app размере.

## Out of scope (Part 2 или позже)

- Embeddings + semantic search
- Obsidian writeback (ни daily note, ни voice append)
- Highlighting matches in FilesView
- Pagination / чанкинг для больших файлов
