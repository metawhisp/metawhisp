# Подключить Claude Desktop к MetaWhisp vault

После того как MetaWhisp синхронизирует voices / meetings / tasks / memories в Obsidian vault (ITER-035), любой MCP-совместимый AI клиент может читать эту «вторую память» как папку с markdown файлами. Не нужен кастомный сервер, не нужен билд — только конфиг.

Эта инструкция — для **Claude Desktop**. Аналогичная для Cursor в `CURSOR-SETUP.md`.

## Что получишь

В Claude Desktop сможешь спрашивать:
- *«Какие у меня были созвоны на этой неделе?»* — Claude прочитает `MetaWhisp/2026-05-DD/meetings/` файлы за неделю.
- *«Что я записывал про MetaWhisp проект?»* — Claude найдёт все `Memories/MetaWhisp/*.md`.
- *«Покажи мой список активных задач»* — `MetaWhisp/<сегодня>/tasks/`.
- *«Прочитай мой созвон с Sam в среду и вытащи action items»* — file read + summarize.

Claude видит только содержимое vault'а (read-only). Он не может записать обратно в MetaWhisp; для этого нужен ITER-037 Option B (отдельная итерация, native Swift MCP server).

## Требования

- macOS 13+
- Claude Desktop установлен → https://claude.ai/download
- В MetaWhisp Settings → **Obsidian Sync** включён, путь к vault указан, и хотя бы раз нажат **«Export everything to vault»** (иначе vault пустой)

## Шаги

### 1. Установи Node.js (если не стоит)

`filesystem-MCP` от Anthropic запускается через `npx`. Проверь:

```bash
which node
which npx
```

Если пусто — установи Node 22+:
```bash
brew install node
```

### 2. Найди абсолютный путь к твоему MetaWhisp vault

Открой MetaWhisp Settings → Obsidian Sync. Скопируй путь который там показан. К нему добавь `/MetaWhisp` — это поддиректория где живут аппкины файлы (мы не даём Claude доступ ко **всему** vault'у, только к MetaWhisp данным).

Пример полного пути:
```
/Users/android/Documents/Obsidian Vault/MetaWhisp
```

### 3. Открой конфиг Claude Desktop

```bash
open ~/Library/Application\ Support/Claude/
```

Найди (или создай) файл `claude_desktop_config.json`. Если файла нет:

```bash
mkdir -p ~/Library/Application\ Support/Claude
touch ~/Library/Application\ Support/Claude/claude_desktop_config.json
```

### 4. Добавь MetaWhisp MCP server в конфиг

Открой `claude_desktop_config.json` в любом редакторе. Если файл пустой — вставь:

```jsonc
{
  "mcpServers": {
    "metawhisp-vault": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "/АБСОЛЮТНЫЙ/ПУТЬ/К/ТВОЕМУ/Obsidian Vault/MetaWhisp"
      ]
    }
  }
}
```

**Замени** путь в последнем `args` на свой реальный.

Если у тебя уже есть другие MCP серверы в этом файле — просто добавь блок `"metawhisp-vault": {...}` внутрь существующего `"mcpServers"` объекта.

### 5. Перезапусти Claude Desktop

Cmd-Q → запусти снова. При первом запуске Claude скачает `@modelcontextprotocol/server-filesystem` пакет (это 1-2 секунды).

### 6. Проверь что работает

В Claude Desktop спроси:

> *Read the file MetaWhisp/README.md from my vault.*

Если Claude в ответе показывает структуру vault'а — всё подключено. Если говорит «I don't have access to files» — значит конфиг не подхватился, проверь:

- Файл `claude_desktop_config.json` валидный JSON (запусти `cat ~/Library/Application\ Support/Claude/claude_desktop_config.json | python3 -m json.tool` — должен распечататься без ошибок).
- Путь существует (`ls "/АБСОЛЮТНЫЙ/ПУТЬ"` — должен показать `README.md`, `2026-05-DD/`, `Memories/`, etc).
- Перезапустил Claude **полностью** (Cmd-Q, не только закрыть окно).

## Безопасность

- Filesystem-MCP **read-only по умолчанию** в этой версии. Claude не может **записать** в твой vault или удалить.
- Доступ ограничен **только указанным путём** — `/MetaWhisp` папкой, не всему vault'у с другими твоими заметками.
- Никакие данные не уходят за пределы локальной машины (если ты сам не попросишь Claude что-то опубликовать).

## Что дальше

- **Чтобы Claude увидел свежие данные** — просто диктуй / записывай созвоны в MetaWhisp как обычно. ITER-035 v2 hooks автоматически пишут новые файлы в vault, Claude увидит их на следующем запросе.
- **Если хочешь semantic search** (Claude должен сам найти упоминания «Маши» через embedding, без точного name match) — это пока не покрывается filesystem-MCP. Будет в ITER-036 RAG lifetime chat (через ChatService внутри MetaWhisp) ИЛИ в native Swift MCP server (ITER-037 Option B, отдельная итерация).

## Если что-то не работает

- **«Cannot find module» в Claude logs** — `npx` не в PATH. Запусти `which npx` в Terminal; если пусто — `brew install node`.
- **«ENOENT: no such file or directory»** — путь к vault'у неверный или vault не существует. Проверь через `ls`.
- **«Permission denied»** — Claude Desktop первый раз качает npm пакет; может потребоваться permission для `~/.npm`. Запусти `npm config get cache` и убедись что папка читаемая.
- **Список MCP серверов в Claude Desktop не показывает metawhisp-vault** — конфиг не подхватился. JSON валиден? Файл в правильном месте?
