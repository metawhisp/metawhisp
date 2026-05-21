# Подключение MetaWhisp к Claude Desktop через MCP

После настройки Claude Desktop получает доступ к твоей памяти MetaWhisp напрямую — может искать твои meeting notes, задачи, факты о людях и проектах, и использовать их в любом разговоре.

## Что Claude умеет с подключённым MetaWhisp

- **`search_memories(query)`** — поиск по сохранённым memories (факты, мнения, цели)
  - «найди что я говорил про CTO ChatApp»
  - «какие у меня есть memories про Project Alpha»
- **`list_tasks(status)`** — текущие задачи (pending / completed / all)
- **`recent_conversations(limit, since_days)`** — последние созвоны с title + overview
- **`search_conversations(query)`** — поиск по митингам и voice notes
  - «найди созвон где обсуждали бюджет»
  - «о чём была встреча в понедельник»

## Установка

### 1. Убедись, что MetaWhisp запущен

MetaWhisp пишет snapshot своих данных в `~/Library/Application Support/MetaWhisp/mcp-snapshot.json` каждые 5 минут. MCP-сервер читает его и отвечает Claude.

Если snapshot ещё не существует — запусти/перезапусти MetaWhisp и подожди до 5 минут (или открой Settings → AI, это триггерит ранний снэпшот).

### 2. Найди путь к бинарнику

После сборки MetaWhisp бинарник лежит здесь:
```
/Applications/MetaWhisp.app/Contents/Resources/metawhisp-mcp
```

Если ставил из исходников через `swift build`:
```
<ПУТЬ К РЕПО>/.build/debug/metawhisp-mcp
```

### 3. Открой Claude Desktop config

```bash
open ~/Library/Application\ Support/Claude/
```

Если файла `claude_desktop_config.json` нет — создай. Если есть — добавь блок `metawhisp` в `mcpServers`.

### 4. Добавь сервер

Минимальный конфиг:

```jsonc
{
  "mcpServers": {
    "metawhisp": {
      "command": "/Applications/MetaWhisp.app/Contents/Resources/metawhisp-mcp"
    }
  }
}
```

Если у тебя уже есть другие MCP-сервера в конфиге, добавь только запись `"metawhisp": { ... }` внутрь существующего `mcpServers`.

### 5. Перезапусти Claude Desktop

Полностью закрой Claude Desktop (Cmd+Q) и открой снова. После запуска в правом нижнем углу окна чата должен появиться значок инструментов — клик покажет список MCP-серверов. `metawhisp` должна быть в списке зелёная.

### 6. Проверь

В новом чате с Claude спроси:
> Какие у меня есть pending tasks в MetaWhisp?

или

> Найди memories про <любая твоя тема>.

Claude автоматически вызовет `list_tasks` или `search_memories` и вернёт результат.

## Поиск проблем

**MCP сервер не появился в Claude Desktop**
- Проверь путь к бинарнику — он должен быть исполняемым: `ls -la /Applications/MetaWhisp.app/Contents/Resources/metawhisp-mcp`
- Если бинарник без прав на запуск: `chmod +x <путь>`
- Проверь логи Claude Desktop: `~/Library/Logs/Claude/mcp.log`

**«MetaWhisp snapshot not available»**
- Открой MetaWhisp, дождись 5 минут (или перезапусти приложение)
- Проверь что файл существует: `ls -la ~/Library/Application\ Support/MetaWhisp/mcp-snapshot.json`
- Если файла нет — посмотри логи MetaWhisp: `tail ~/Library/Logs/MetaWhisp.log | grep MCPSnapshot`

**Tools не вызываются**
- Claude иногда не понимает что инструменты доступны до явной просьбы — попробуй: «у тебя есть доступ к MetaWhisp через MCP, попробуй list_tasks»
- Сами имена инструментов: `search_memories`, `list_tasks`, `recent_conversations`, `search_conversations`

## Что НЕ делает MCP сервер (пока)

- **Не пишет** ничего в MetaWhisp — только чтение
- **Не имеет** semantic search через embeddings (только substring match)
- **Не реагирует** на live-события — снимок обновляется каждые 5 минут

Эти возможности приедут в следующих итерациях.

## Безопасность

- MCP сервер работает **локально**. Никаких сетевых соединений.
- Claude Desktop запускает бинарник как child process через stdio.
- Snapshot-файл лежит у тебя на диске. Никуда не отправляется.
- Чтобы отключить — убери блок `metawhisp` из `claude_desktop_config.json` и перезапусти Claude.
