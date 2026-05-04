# Prompt Audit — MetaWhisp vs Reference (2026-04-26)

Baseline-снимок состояния LLM-промптов перед ITER-024…032 sweep. Цель — устранить дрифт (см. memory `feedback_copy_first_methodology.md` + `feedback_no_shortcuts.md`).

Audit conducted by parallel general-purpose agents reading both codebases. Re-run after sweep to confirm closure.

---

## Сервисы с LLM-промптами (12 шт)

### Voice / Conversation / Chat

| # | Сервис | Промпт | Reference |
|---|---|---|---|
| 1 | MemoryExtractor | `Services/Intelligence/MemoryExtractor.swift:149-259` | `omi/backend/utils/prompts.py:12-362` (`extract_memories_prompt`) |
| 2 | TaskExtractor | `Services/Intelligence/TaskExtractor.swift:151-310` | `omi/backend/utils/llm/conversation_processing.py:301-585` (`extract_action_items`) |
| 3 | StructuredGenerator | `Services/Intelligence/StructuredGenerator.swift:319-418` | `omi/backend/utils/llm/conversation_processing.py:588-670` (`get_transcript_structure`) |
| 4 | ChatService | `Services/Intelligence/ChatService.swift:243-385` | `omi/backend/utils/llm/chat.py:303-742` (RAG + agentic) |

### Screen / Advice / Daily / External

| # | Сервис | Промпт | Reference |
|---|---|---|---|
| 5 | AdviceService | `Services/Intelligence/AdviceService.swift:158-294` (Standard + Coach) | `omi/desktop/.../Insight/InsightAssistantSettings.swift:25-86` |
| 6 | ScreenExtractor | `Services/Intelligence/ScreenExtractor.swift:321-389` | **Нет batch-эквивалента**. Сравним против `MemoryAssistant` + `TaskAssistant` в Omi |
| 7 | RealtimeScreenReactor | `Services/Intelligence/RealtimeScreenReactor.swift:228-284` | `omi/desktop/.../TaskExtraction/TaskAssistantSettings.swift:117-274` |
| 8 | LiveMeetingAdvisor | `Services/Intelligence/LiveMeetingAdvisor.swift:1-165` (нет своего промпта) | **Нет эквивалента** (наш novel) |
| 9 | DailySummaryService | `Services/Intelligence/DailySummaryService.swift:616-747` (5 агентов) | `omi/backend/utils/llm/external_integrations.py:215-269` (single prompt) |
| 10 | CalendarReaderService | `Services/Indexing/CalendarReaderService.swift:365-393` | `omi/desktop/.../CalendarReaderService.swift` (browser cookies) |
| 11 | FileMemoryExtractor | `Services/Indexing/FileMemoryExtractor.swift:126-157` | `omi/backend/utils/prompts.py:364-456` (`extract_memories_text_content_prompt`) |
| 12 | AppleNotesReaderService | `Services/Indexing/AppleNotesReaderService.swift:241-266` | `omi/desktop/.../AppleNotesReaderService.swift:38-150+` |

---

## Что мы потеряли (drift findings)

### MemoryExtractor — 6 gaps
1. `headline` cap: у нас ≤6 слов → у Omi ≤5.
2. **IDENTITY RULES** отсутствуют (нельзя выдумать family members, распознавать nicknames). `prompts.py:22-28`.
3. **LOGIC CHECK** отсутствует (sanity на возраст, локации, family contradictions). `prompts.py:290-297`.
4. Banned-language list **неполный** — добавить filler phrases ("indicating a…", "suggesting a…", "reflecting a…", "showcasing").
5. NEVER-EXTRACT **8 категорий → 3** в нашем коде. Потеряли: NEWS, GENERAL KNOWLEDGE, PRODUCT DOCS, CUSTOMER FACTS, INTERNAL METRICS, ORG RESTRUCTURING, COLLEAGUE FACTS WITHOUT RELATIONSHIP, GENERIC RELATIONSHIPS.
6. Worked examples: ~6 vs Omi ~30.

### TaskExtractor — 2 gaps
1. **REFERENCE_TIME rule** отсутствует — Omi: «if `started_at` >7 days before `current_time`, use `current_time`» (`conversation_processing.py:525`). Bug-class на regenerate / backfill.
2. Bullet «real-time exchange resolves within minutes → 0 items» отсутствует.

### StructuredGenerator — 2 gaps
1. 5 ITER-021 полей (`decisions / action_items / participants / key_quotes / next_steps`) имеют ~1-2 примера каждое. У Omi на title/overview ~5-10 примеров каждый. Density критическая для anchoring.
2. Per-field language reinforcement отсутствует. RU транскрипт → participants могут оказаться EN.

### ChatService — 2 gaps
1. **`<response_style>` length budget** отсутствует. У Omi (`chat.py:533-550`): «default 2-8 lines, voice 1-3, "I don't know" 1-2 lines max».
2. Robotic-phrasing bans: «in the logs», «in your captured calls», «according to the data» (`chat.py:608-611`). У нас бан только «based on the available memories».

### AdviceService — 2 gaps
1. **`headline ≤5w`** field отсутствует. Notification truncates `content` сейчас. `InsightAssistant.swift:927-941`.
2. **WORKFLOW step framing** + CORE QUESTION отсутствуют (`InsightAssistantSettings.swift:28-36`). У нас прыжок сразу в правила.

### ScreenExtractor — 1 gap
1. **Title-rejection retry loop** отсутствует. Когда LLM пишет vague title типа "Investigate", Omi (`TaskAssistant.swift:807-833`) кормит rejection обратно. Мы dropам через post-filter.

### RealtimeScreenReactor — 1 BIG gap
1. **PATTERN-1 USER COMMITMENT detection** отсутствует. Omi различает «пользователь сказал "Sure, I'll do it"» (PATTERN 1) vs «кто-то прислал unaddressed запрос» (PATTERN 2). У нас только PATTERN 2. + chat-direction reading rules (right=outgoing/USER vs left=incoming/OTHER).

### DailySummaryService — 3 missing fields
1. `unresolved_questions[≤3]` (cross-day question tracking) отсутствует.
2. `day_emoji` отсутствует (UI sugar).
3. **`conversation_ids` back-pointers** в каждом highlight отсутствуют — нет clickthrough к источнику.

### AppleNotesReaderService — 1 gap
1. **`classifierNoise` + `isLikelyAttachment` filter** отсутствует. Apple Notes attachments создают image-OCR junk типа "Document Documents Papers", «Chart Charts Graph Graphs» — будут шумные memories.

---

## Что у нас лучше Omi (KEEP — наши innovations)

1. **GROUND TRUTH RULE** в ChatService — свои прошлые слова ассистента не факты.
2. **Ellipsis / short-follow-up rule** — handles "го", "да", "ок".
3. **Anti-preamble HARD-FORBIDDEN list** в StructuredGenerator (только что added).
4. **9 типизированных context-блоков** в RAG vs Omi 1 блок.
5. **A/B/C ownership taxonomy** в TaskExtractor.
6. **CONVERSATION-WIDE CONTEXT** rules для cross-fragment dedup.
7. **Confidence: 0-1** field в memories (post-filter), Omi через resolve_memory_conflict.

## Наши novel designs (Omi нет)

1. **LiveMeetingAdvisor** — partial transcribe → advice mid-meeting.
2. **ScreenExtractor 3-в-1 batch** — observations + memories + tasks одним LLM call.
3. **DailySummary 5-agent** split — специалист на каждое поле.
4. **AdviceService Coach mode** + memory-weave semantic ranking.
5. **CalendarReaderService.linkConversation** — Conversation ↔ EKEvent через time-overlap × title Jaccard.
6. **EventKit-first calendar reader** vs Omi browser-cookies.
7. **AppleScript-based Notes reader** vs Omi direct SQLite (требует Full Disk Access).

---

## Plan: ITER-024…032 fixes

10 итераций по Карпати. Каждая: read reference fully → copy → adapt → build → verify.

| ITER | Сервис | Действие | Cost |
|---|---|---|---|
| 024 | MemoryExtractor | restore 8 NEVER-EXTRACT + IDENTITY/LOGIC RULES + filler phrases ban + headline≤5w + more examples | prompt only |
| 025 | TaskExtractor | + REFERENCE_TIME + real-time-exchange exclusion | prompt only |
| 026 | ChatService | + `<response_style>` length budget + robotic-phrase ban | prompt only |
| 027 | StructuredGenerator | + good/bad examples × 5 ITER-021 fields + per-field language note | prompt only |
| 028 | RealtimeScreenReactor | + PATTERN-1 USER COMMITMENT framing + chat-direction reading + раз-blanket-skip messengers | prompt + filters |
| 029 | AdviceService | + `headline ≤5w` field + WORKFLOW framing | prompt + parser + UI |
| 030 | AppleNotesReader | + classifierNoise + isLikelyAttachment filter | code only |
| 031 | DailySummaryService | + `unresolved_questions` agent + `day_emoji` + `conversation_ids` back-pointers per item | schema + 5 prompts + UI |
| 032 | ScreenExtractor | + title-rejection retry loop | architecture |

---

## Re-audit cadence

Раз в 2 недели или после крупного refactor — повторять параллельно через 2 general-purpose агента (один на voice family, другой на screen/daily/readers). Diff против этого baseline покажет новый drift. Закладываем напоминание в WAL после ITER-032.

---

## Источники

- Voice/conversation audit agent: 132K tokens, 21 tool uses
- Screen/advice audit agent: 238K tokens, 43 tool uses
- Reference codebase: `/Users/android/Code/omi/` (Python backend + Swift desktop)
