# ITER-037 — MCP Server (Claude / Cursor / ChatGPT integration)

**Проблема:** юзер хочет, чтобы Claude Desktop / Cursor / ChatGPT могли «помнить» всю историю работы из MetaWhisp без копипаста — единая внешняя память для любого LLM client'а.

**Зависимости:** делается **после** ITER-035 (Obsidian sync). Без markdown vault нет легкого way дать LLM clients доступ. С vault — большая часть нужного покрыта **бесплатно** через official Anthropic filesystem-MCP.

## Strategy decision (must read before coding)

Две архитектуры. Решение ниже определяет всё.

### Option A — Filesystem-MCP only (NO custom code)

Юзер подключает official MCP server в свой Claude Desktop / Cursor config:
```jsonc
// ~/Library/Application Support/Claude/claude_desktop_config.json
{
  "mcpServers": {
    "metawhisp-vault": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/MetaWhisp-vault"]
    }
  }
}
```

Claude / Cursor читают / search'ят markdown файлы напрямую. **Никакого нашего кода.** Работает out-of-the-box после ITER-035.

**Покрывает:** «найди мою заметку про X», «что я записал про Sam», «открой conversation от вторника».

**Не покрывает:** semantic search по embeddings, structured queries (count, date-range aggregation), live notifications.

**Effort:** **0 дней.** Только напишем `specs/integrations/CLAUDE-DESKTOP-SETUP.md` с config template.

### Option B — Native MetaWhisp MCP server

Свой stdio MCP server на Swift / Node, читает напрямую `MetaWhisp.store` SwiftData DB. Exposes specialized tools:
- `search_memories(query, limit)` — semantic через embedding
- `search_conversations(query, since)` — full-text + date filter
- `list_tasks(status, due_within)`
- `get_entity_history(name)` — лет ITER-036 entity index
- `ask_metawhisp(question)` — proxy в ChatService (через локальный LLM или Pro proxy)

**Покрывает:** всё что Option A + semantic + structured. Native experience.

**Effort:** ~2 дня (Swift MCP SDK exists; SwiftData read access; stdio JSON-RPC).

### Recommendation

**Делаем A первым.** Юзер сразу получает работающую integration после ITER-035 — без нового кода. Если **в реальности** какие-то use cases плохо покрываются filesystem-MCP — пилим B incrementally.

**Tomorrow's start:** Option A (config docs + smoke test). Option B remains в backlog как ITER-037.B если понадобится.

## Scope (Option A)

### 1. `specs/integrations/CLAUDE-DESKTOP-SETUP.md` — NEW

Step-by-step:
1. Установить `npm` (если нет) — для `npx` запуска filesystem-MCP
2. Включить ITER-035 sync в MetaWhisp + указать vault path
3. Запустить `bulkExportAll()` чтобы заполнить vault
4. Открыть `~/Library/Application Support/Claude/claude_desktop_config.json` (создать если нет)
5. Добавить блок:
   ```jsonc
   {
     "mcpServers": {
       "metawhisp-vault": {
         "command": "npx",
         "args": ["-y", "@modelcontextprotocol/server-filesystem", "<АБСОЛЮТНЫЙ ПУТЬ К VAULT/MetaWhisp>"]
       }
     }
   }
   ```
6. Restart Claude Desktop
7. Verify в Claude: «Read MetaWhisp/README.md» → ответ с содержимым → integration работает

### 2. `specs/integrations/CURSOR-SETUP.md` — NEW

Аналогичный setup для Cursor:
- Cursor → Settings → MCP → Add new MCP server
- Same config

### 3. `specs/integrations/CHATGPT-SETUP.md` — NEW (caveat)

ChatGPT Desktop сейчас НЕ поддерживает MCP нативно (на момент 2026-05-12 — нужно проверить). Если нет — фолбэк рекомендация:
- Использовать ChatGPT Custom Connectors API (web-based)
- Или интеграция через Raycast / Alfred plugin который читает vault

**TODO at start:** проверить актуальность ChatGPT MCP support до начала иттерации.

### 4. `Views/Windows/MainSettingsView.swift`

Под Obsidian sync section добавить блок **EXTERNAL LLM ACCESS**:
- Link button «Setup Claude Desktop» → opens `https://metawhisp.com/docs/claude-desktop` (или local file)
- Link button «Setup Cursor» → same
- Маленькое info-описание: «Эти инструкции подключают любой MCP-совместимый LLM client к твоему MetaWhisp vault»

### 5. Update website docs

На `metawhisp/MetaWhisp.com` под `/docs/` создать страницы:
- `claude-desktop.md`
- `cursor.md`
- `chatgpt.md` (если applicable)

**Memory rule «не трогать сайт»:** добавление doc страниц через PR с явным согласованием юзера — отдельная сессия. Можно держать локально на macOS first → linked-from-Settings.

## Scope (Option B — native MCP, deferred)

NB: записан для будущего, не делаем сегодня/завтра. Только если Option A окажется недостаточно.

### B1. `Tools/metawhisp-mcp/` — NEW package (separate from main app)

Swift Package Manager project:
- `Package.swift` deps: official MCP Swift SDK (when published; пока альтернатива — Node TypeScript SDK)
- Binary target: `metawhisp-mcp` executable

### B2. Read-only DB access

- Opens `~/Library/Application Support/MetaWhisp.store` (SwiftData/CoreData SQLite) read-only
- Schema mapping: повторить SwiftData @Model'ы в plain Swift structs
- NB: SwiftData migration — может ломать MCP при schema change. Mitigation: pin к schemaVersion.

### B3. Tools list

```jsonc
{
  "tools": [
    {"name": "search_memories", "description": "Semantic search across user's notes/memories", "inputSchema": {...}},
    {"name": "search_conversations", "description": "Full-text + date filter across conversations", "inputSchema": {...}},
    {"name": "list_tasks", "description": "Filter user's tasks", "inputSchema": {...}},
    {"name": "get_recent_screen_activity", "description": "What user has been looking at recently", "inputSchema": {...}}
  ]
}
```

### B4. Distribution

- Bundle в MetaWhisp.app под `Contents/MacOS/metawhisp-mcp`
- При установке — auto-add в `~/Library/Application Support/Claude/claude_desktop_config.json`
- В Settings → «Enable MCP server» toggle

## Acceptance (Option A)

1. После ITER-035 bulk export → юзер настраивает Claude Desktop по step-by-step из docs → restart
2. В Claude Desktop спрашивает: «Что у меня в файле MetaWhisp/README.md?» → отвечает с реальным содержимым
3. «Покажи последние 3 task'а из MetaWhisp/Tasks» → читает folder, выдаёт filenames + extracted content
4. «Что обсуждалось на standup в этот вторник?» → ищет в Conversations/2026-05-12*.md → находит → summarises
5. Юзер делает новую voice note в MetaWhisp → через ≤2 сек файл появляется в vault → Claude видит его на следующем запросе (file system watching)

## Out of scope

- Two-way write (Claude **создаёт** task в MetaWhisp через MCP) — отдельная итерация когда write-API stable
- Live realtime SSE / streaming — filesystem-MCP не поддерживает; нужен Option B
- Cross-machine sync vault (vault на iCloud Drive / GitHub repo для multi-device access) — outside scope

## Implementation checklist (Option A)

- [ ] **Step 1 — Verify ITER-035 sync working:** делать только после того как Obsidian export deployed + smoke-tested
- [ ] **Step 2 — Check MCP versions:** что-то могло поменяться. Проверить `@modelcontextprotocol/server-filesystem` latest version + ChatGPT MCP support status
- [ ] **Step 3 — Write Claude Desktop setup doc:** в `specs/integrations/` + копия для web (когда apply changes к сайту)
- [ ] **Step 4 — Write Cursor setup doc**
- [ ] **Step 5 — Smoke test Claude Desktop:** на своей машине: install MCP, restart, ask sample queries
- [ ] **Step 6 — Smoke test Cursor**
- [ ] **Step 7 — UI links в Settings:** «Setup external LLM access»
- [ ] **Step 8 — Decide on Option B:** если Option A покрывает 80%+ use cases → close iter; иначе start B planning

## Estimated effort (Option A)

- Docs: 0.5 дня
- Smoke testing на trzh клиентах: 0.5 дня
- UI integration: 0.25 дня
- Total: **~1.25 дня** (но 0 days codding на main app — только docs + UI links)

## Estimated effort (Option B — если понадобится)

- Native MCP server: ~2 дня
- Distribution + auto-config: ~0.5 дня
- Total: **~2.5 дня** дополнительно поверх Option A
