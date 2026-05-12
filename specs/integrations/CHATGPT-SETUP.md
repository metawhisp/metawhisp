# Подключить ChatGPT к MetaWhisp vault

**Caveat:** на момент 2026-05-12 ChatGPT Desktop **не поддерживает MCP** так как Claude Desktop / Cursor. У OpenAI свой Connectors API (web-based), которая работает по-другому.

Если на момент чтения этой инструкции что-то изменилось — проверь обновления на https://platform.openai.com/docs.

## Вариант 1 — ChatGPT Custom GPT с File Search (доступно сейчас)

Этот вариант работает прямо сегодня. Но он **загружает файлы в OpenAI** — твои данные уйдут на их серверы (с одной стороны — ты так и используешь ChatGPT, с другой — voices/meetings содержат личное).

1. Сделай **bulk export** в MetaWhisp Settings.
2. В Obsidian vault найди папку `MetaWhisp/`, зазипуй её:
   ```bash
   cd ~/Documents/Obsidian\ Vault
   zip -r metawhisp-export-$(date +%Y-%m-%d).zip MetaWhisp/
   ```
3. Перейди на https://chatgpt.com/gpts/editor → Create new GPT.
4. Configure → Knowledge → Upload files → загрузи zip (или развёрнутую папку).
5. Дай GPT название типа «My MetaWhisp Memory».
6. В Instructions укажи: *«Use the uploaded MetaWhisp vault to answer questions about my dictations, meetings, tasks, and memories. Reference filename when citing.»*
7. Сохрани, потом обращайся к этому GPT когда хочешь поднять контекст из MetaWhisp.

**Минусы:** нужно периодически re-uploadить когда vault обновится. Файлы статичные в OpenAI.

## Вариант 2 — Подождать MCP support в ChatGPT Desktop

Anthropic анонсировал MCP в late 2024, OpenAI пока не подхватили (либо подхватили — но я писал это в мае 2026, проверь актуально). Если ChatGPT Desktop добавит MCP — конфиг будет аналогичен Claude Desktop / Cursor (тот же `filesystem-MCP` пакет).

Подключиться можно будет через `/Library/Application Support/ChatGPT/` или подобный путь.

## Вариант 3 — Использовать Claude / Cursor вместо ChatGPT для этих кейсов

Если у тебя есть Claude или Cursor — они **уже** поддерживают MCP. Для запросов «найди что я говорил про X в моих воксах» — лучше через них. ChatGPT держи для других задач.

## Зачем существует этот файл если работающего варианта нет

Так что ты не тратил час на поиск «как же подключить ChatGPT к MetaWhisp» и не нашёл — теперь знаешь сразу: пока никак, вернись через 3-6 месяцев или используй Custom GPT с file upload как workaround.
