# Подключить Cursor к MetaWhisp vault

Cursor (IDE на базе VSCode + Claude integration) поддерживает MCP servers через UI или config файл. Делает то же что Claude Desktop — даёт Claude доступ к твоему MetaWhisp vault как к набору markdown файлов.

## Что получишь

При работе с кодом — Cursor's встроенный Claude сможет ссылаться на твои voices / meetings / tasks:
- *«Я записывал что-то про этот баг раньше — найди»* → ищет в `Memories/` и `2026-*/voices/`.
- *«Что обсуждали на standup в среду про cache layer?»* → читает meetings/ файлы.
- *«Какие у меня TODO про Stripe?»* → ищет в `tasks/`.

Не делает: запись обратно в MetaWhisp (read-only filesystem-MCP).

## Требования

- Cursor установлен → https://cursor.sh
- В MetaWhisp Settings → Obsidian Sync включён, vault path указан, bulk export сделан

## Шаги

### 1. Запусти `npx` чтобы убедиться что Node 22+ установлен

```bash
node --version  # должно быть v18+ minimum, ideally v22+
npx --version
```

Если нет — `brew install node`.

### 2. Найди абсолютный путь к MetaWhisp vault

В MetaWhisp Settings → Obsidian Sync. Возьми путь, добавь `/MetaWhisp`.

Пример:
```
/Users/android/Documents/Obsidian Vault/MetaWhisp
```

### 3. Открой Cursor settings → MCP

Cmd-, (Settings) → найди раздел **MCP** в боковом меню. Если не видишь — нажми Cmd-Shift-P → введи «MCP» → выбери «MCP: Open Settings».

### 4. Добавь новый MCP server

Либо через UI кнопкой «+ Add new MCP server», либо открой файл `~/.cursor/mcp.json` напрямую и добавь:

```jsonc
{
  "mcpServers": {
    "metawhisp-vault": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "/АБСОЛЮТНЫЙ/ПУТЬ/К/Obsidian Vault/MetaWhisp"
      ]
    }
  }
}
```

### 5. Перезапусти Cursor

Cmd-Q → запусти снова.

### 6. Проверь

В Cursor chat:

> *Read MetaWhisp/README.md from my vault*

Должен ответить с содержимым.

## Notes

- Cursor может попросить разрешение «Cursor wants to access filesystem» в первый раз — это **наш** filesystem-MCP, разрешай.
- Path completion работает: если печатаешь в Cursor чате `@MetaWhisp/2026-05-12/` — он покажет список файлов на этот день.
- Cursor + filesystem-MCP ведёт себя так же как Claude Desktop, но имеет меньше context window — может быть медленнее на огромные файлы. Если у тебя в vault'е огромные транскрипты (>20K chars в одном файле) — Cursor может truncate'ить.

## Если не работает — см. troubleshooting в `CLAUDE-DESKTOP-SETUP.md` (общий для обоих клиентов).
