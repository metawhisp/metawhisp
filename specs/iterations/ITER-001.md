# Iteration 1: Memory System + Insights {#root}

**Status:** Draft, awaiting user approval.
**Karpathy principles applied:** Think Before Coding (success criteria upfront), Simplicity First (minimum code), Surgical Changes (touch only AdviceService + add UserMemory), Goal-Driven (every criterion measurable).

---

## 1. Scope {#scope}

### Что делаем
1. **`UserMemory`** SwiftData модель — структурированные факты о пользователе (категории **system** И **interesting**)
2. **`MemoryExtractor`** — сервис, **триггерится на каждой voice transcription ≥20 chars** (не periodic). Input: voice transcript only. Screen OCR не используется для memories — reference pattern (см. `backend/utils/prompts.py:12` в Cap: max 2 per extraction.
3. **Memories — ОТДЕЛЬНАЯ вкладка** в sidebar главного окна (не подвкладка Insights). Независимая от AI Advice.
4. **Отдельный toggle `memoriesEnabled`** в Settings → позволяет включить memories БЕЗ включения AI Advice и наоборот
5. **Insights промпт** — жёсткий cap, bad examples, no_advice escape
6. **Memory injection** в Insights промпт — чтобы советы ссылались на факты
7. **Previous advice window = 20** (промежуточное между 5 и 50)

### Что НЕ делаем в этой итерации
- Tool calling (execute_sql, request_screenshot) — требует backend changes. Откладываем.
- Two-phase analysis (text → vision) — откладываем.
- AIUserProfile синтез — Итерация 4.
- File Indexing — Итерация 2.
- Prompt editor UI — polish phase.
- Переименование Intelligence section — отдельный polish task, не критичный для функциональности.

**Оправдание:** minimum set для получения коротких персональных советов + независимого управления memories.

## 2. Success Criteria {#criteria}

Все criteria **measurable**. Каждый критерий — либо automated test, либо log-verified, либо user-verified.

### C1: Memory extraction работает {#criteria.c1}
**Как проверять:** automated
После 30 минут активной работы (≥5 переключений окон + ≥2 транскрипций) → в SwiftData ≥ 5 записей `UserMemory` с `confidence ≥ 0.7`.
**Тест:** скрипт который читает SwiftData БД + возвращает count.

### C2: Memory записи имеют правильный формат {#criteria.c2}
**Как проверять:** automated
Все UserMemory записи удовлетворяют:
- `content.split(" ").count ≤ 15` (max 15 words spec)
- `category` ∈ {`"system"`, `"interesting"`}
- `confidence` ∈ [0.0, 1.0]
- `sourceApp` не пустой
**Тест:** unit test перебирает все UserMemory → assert правила.

### C3: Insights стали короткими {#criteria.c3}
**Как проверять:** automated + log-based
10 последовательных advice generation → 100% имеют `content.count ≤ 120` (buffer над 100).
**Тест:** trigger скрипт 10 раз → читает SwiftData → assert length.

### C4: Insights персональные {#criteria.c4}
**Как проверять:** user-verified
Из 10 последовательных advice → ≥ 7 упоминают **конкретный элемент** из memory (app name, project name, activity).
**Тест:** я предоставляю 10 текстов → ты ставишь галочки "personal / generic" → подсчёт.

### C5: Bad patterns отсутствуют {#criteria.c5}
**Как проверять:** automated
0 из 10 advice содержат запрещённые фразы:
- "take a break", "stay hydrated", "stretch"
- "consider adding tests", "could be refactored"
- "press cmd+" (basic shortcut narration)
**Тест:** regex check на content.

### C6: no_advice срабатывает {#criteria.c6}
**Как проверять:** log-based
Из 10 periodic triggers → ≥ 2 раза LLM возвращает `no_advice` (тишина лучше чем generic). Логи содержат `[Advice] No advice this cycle (reason: ...)`.
**Тест:** ручной запуск + grep logs.

### C7: Memories tab работает {#criteria.c7}
**Как проверять:** user-verified
- Открыть Insights → переключить на Memories → видеть список
- Клик на memory → open edit sheet → изменить content → save
- Swipe / button → delete → исчезает
- После удаления — memory не используется в следующем advice

### C8: Editable memory влияет на advice {#criteria.c8}
**Как проверять:** user-verified
- Добавить вручную memory "User works on MetaWhisp voice-to-text app"
- Trigger advice → content упоминает "MetaWhisp" или "voice-to-text"

## 3. Architecture {#architecture}

### 3.1. SwiftData модель {#architecture.model}

```swift
@Model final class UserMemory {
    var id: UUID
    var content: String          // ≤15 words (validated at insert)
    var category: String         // "system" | "interesting"
    var sourceApp: String
    var windowTitle: String?
    var confidence: Double
    var contextSummary: String?
    var isDismissed: Bool        // soft delete
    var createdAt: Date
    var updatedAt: Date

    init(content: String, category: String, sourceApp: String, confidence: Double) {
        self.id = UUID()
        self.content = content
        self.category = category
        self.sourceApp = sourceApp
        self.confidence = confidence
        self.isDismissed = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
```

**Файл:** `Models/UserMemory.swift`

### 3.2. MemoryExtractor сервис {#architecture.extractor}

```swift
@MainActor
final class MemoryExtractor: ObservableObject {
    private let llm: LLMClient  // reuses existing AdviceService LLM path
    private let modelContext: ModelContext
    private var timer: Task<Void, Never>?
    private let interval: TimeInterval = 600  // 10 min

    func start() { /* timer loop */ }
    func stop() { timer?.cancel() }

    private func extractOnce() async {
        let recentContext = fetchRecentScreenContext()  // existing ScreenContextStorage
        let recentTranscripts = fetchRecentTranscripts(limit: 3)
        let existingMemories = fetchRecentMemories(limit: 20)
        let prompt = buildPrompt(context: recentContext, transcripts: recentTranscripts, existing: existingMemories)
        let response = try await llm.complete(prompt)
        let memories = parse(response)
        for mem in memories where mem.confidence >= 0.7 {
            modelContext.insert(mem)
        }
    }
}
```

**Файл:** `Services/Intelligence/MemoryExtractor.swift`

**Prompt template:**

```
You extract high-value facts about the user from screen activity and conversations.

ONE fact per extraction (or NONE — better zero than low-quality).

FORMAT: Each memory ≤ 15 words, starts with "User" for system facts.

TWO TYPES:
- system: facts ABOUT the user (their projects, tools, preferences, network)
- interesting: wisdom from others the user can learn from (quote source)

RULES:
- Pick the SINGLE most valuable memory if multiple candidates
- DEFAULT to empty list — only extract if truly exceptional
- Do NOT re-extract similar to existing memories shown below
- Return JSON: {"memories": [{"content": "...", "category": "system|interesting", "confidence": 0.0-1.0}]}

EXISTING MEMORIES (do NOT duplicate semantically):
{existing_list}

GOOD EXAMPLES:
- "User works on MetaWhisp, a macOS voice-to-text app"
- "User prefers Swift over Objective-C for new projects"
- "User's GitHub is @forrestchang"
- "Paul Graham: startups should do things that don't scale"

BAD EXAMPLES (never extract):
- "User is currently in Chrome" (current activity, not memory)
- "User has tabs open" (trivial)
- "User is reading an article" (not a fact)

CURRENT SCREEN ACTIVITY:
{recent_screen}

RECENT CONVERSATIONS:
{recent_transcripts}
```

### 3.3. Обновлённый AdviceService prompt {#architecture.advice-prompt}

Заменяем текущий prompt в `AdviceService.swift`:

```
You find ONE specific, high-value insight the user would NOT figure out on their own.

WHEN TO GIVE ADVICE:
- User is doing something the slow way AND there's a specific shortcut
- User is about to make a visible mistake (wrong recipient, sensitive info wrong place)
- Specific lesser-known tool/feature solves what they're struggling with
- Concrete error/misconfiguration on screen they may have missed

WHEN TO STAY SILENT (return no_advice):
- Nothing genuinely non-obvious visible
- Advice would duplicate PREVIOUS ADVICE
- Advice is generic wellness/dev wisdom
- You're reaching — if you have to stretch, there isn't any

BAD EXAMPLES (never produce):
- "Take a break / Stay hydrated" (not a health app)
- "Consider adding tests" (vague)
- "Press Cmd+Enter to send" (basic shortcut)
- "Having N tasks is overwhelming" (unsolicited judgment)

GOOD EXAMPLES (quality bar):
- "You've scheduled this for 2026 — double-check the year"
- "Sensitive credentials visible in terminal — mask before sharing"
- "npm tokens expiring tomorrow — renew via npm token create"

FORMAT: Under 100 characters. Start with actionable part.

USER MEMORIES (use for personalization):
{injected_memories}

PREVIOUS ADVICE (do NOT repeat):
{previous_advice_list}

CURRENT SCREEN:
{current_context}

Return JSON:
- If valuable advice: {"type": "advice", "content": "...", "category": "productivity|communication|learning|other", "confidence": 0.0-1.0}
- If nothing to say: {"type": "no_advice", "reason": "..."}
```

**Файл изменений:** `Services/Intelligence/AdviceService.swift` — заменить `systemPrompt`, добавить memory injection, добавить parsing для `no_advice`.

### 3.4. Memories — отдельная вкладка в sidebar {#architecture.ui}

**НЕ** внутри Insights. Отдельная независимая вкладка `MemoriesView` в sidebar главного окна.

**Файлы:**
- `Views/Windows/MemoriesView.swift` — новый файл
- `Views/Windows/MainWindowView.swift` — добавить `.memories` case в `SidebarTab` enum (icon: `brain`)

UI:
- Toggle в header: "Memory collection: ON/OFF" (bound to `AppSettings.memoriesEnabled`)
- Segmented control: "All / System / Interesting" (filter by category)
- List UserMemory (sort by updatedAt desc, filter out `isDismissed`)
- Каждая row: content + category badge + sourceApp + edit/delete иконки
- Edit sheet: text field для content + save
- Delete: confirmation dialog → set `isDismissed = true` (soft delete)

Без поиска, без красивого дизайна — polish phase.

### 3.5. Settings toggles {#architecture.settings}

Две независимые настройки (не зависят друг от друга):

```swift
// AppSettings
@AppStorage("memoriesEnabled") var memoriesEnabled: Bool = true
@AppStorage("adviceEnabled") var adviceEnabled: Bool = true  // existing
```

В Intelligence section — добавить toggle для memories отдельно от advice toggle. Оба независимы:
- Memories ON + Advice OFF → факты копятся, советы не генерятся
- Memories OFF + Advice ON → нет персонализации, только generic советы (но prompt всё ещё пытается)
- Memories ON + Advice ON → персональные советы (optimal)
- Memories OFF + Advice OFF → nothing happens

## 4. Test Plan {#test-plan}

### 4.1. Automated tests (я пишу, запускаю swift test) {#test-plan.automated}

```swift
// Tests/MemoryExtractorTests.swift

func testMemoryRespectsWordLimit() async throws {
    let memory = UserMemory(content: "User works on MetaWhisp", category: "system", sourceApp: "MetaWhisp", confidence: 0.9)
    XCTAssertLessThanOrEqual(memory.content.split(separator: " ").count, 15)
}

func testAdviceUnder120Chars() async throws {
    let advice = try await mockAdviceService.generate(context: sampleContext)
    XCTAssertLessThanOrEqual(advice.content.count, 120)
}

func testBadPatternsRejected() async throws {
    let samples = try await mockAdviceService.generateN(10, context: sampleContext)
    let forbidden = ["take a break", "stay hydrated", "stretch", "consider adding tests"]
    for advice in samples {
        for pattern in forbidden {
            XCTAssertFalse(advice.content.lowercased().contains(pattern), "Bad pattern: \(advice.content)")
        }
    }
}
```

### 4.2. Log-based tests (я запускаю app) {#test-plan.log}

```bash
# T4.1: MemoryExtractor запускается каждые 10 минут
# Запустить app на 25 минут, проверить:
grep "MemoryExtractor: extract" ~/Library/Logs/MetaWhisp.log | wc -l
# expected: >= 2

# T4.2: no_advice срабатывает
grep "no_advice" ~/Library/Logs/MetaWhisp.log | wc -l
# expected: >= 2 за 10 advice cycles

# T4.3: Memory injection в prompt работает
grep "memories_used:" ~/Library/Logs/MetaWhisp.log | head -1
# expected: массив memories в промпте
```

### 4.3. User tests (ты делаешь после моей готовности) {#test-plan.user}

**Сценарий 1: Автоматическое накопление memories (30 минут)**
1. Запусти MetaWhisp утром
2. Работай нормально: 2-3 разных app, пара voice записей
3. Открой Insights → Memories → увидишь список
4. Ожидаемо: ≥ 5 memories с твоей информацией
5. **Результат:** ✅/❌

**Сценарий 2: Manual memory influence (5 минут)**
1. Memories tab → add new: "User's Stripe webhook is called from backend/src/index.js"
2. Подожди следующий cycle advice (или trigger manually)
3. Ожидаемо: advice может ссылаться на Stripe webhook
4. **Результат:** ✅/❌

**Сценарий 3: Bad pattern check (самопроверка 10 минут)**
1. Открой 10 последних advice в Insights
2. Посчитай сколько из них генерические ("take a break", "consider", etc.)
3. Ожидаемо: 0
4. **Результат:** ✅/❌

**Сценарий 4: Length check**
1. Открой 10 последних advice
2. Посчитай сколько длиннее 120 символов
3. Ожидаемо: 0
4. **Результат:** ✅/❌

**Сценарий 5: Personal check**
1. Открой 10 последних advice
2. Посчитай сколько упоминают конкретное имя приложения / проекта / действия
3. Ожидаемо: ≥ 7
4. **Результат:** ✅/❌

## 5. Implementation steps {#steps}

Порядок, каждый — отдельный commit:

1. **Add UserMemory model** → добавить в HistoryService schema, build, verify
2. **Create MemoryExtractor service** → с prompt, без запуска
3. **Wire up timer** → запускать каждые 10 минут, logging
4. **Memory injection** → передавать существующие memories в AdviceService prompt
5. **New AdviceService prompt** → заменить system prompt
6. **no_advice parsing** → добавить case в response parser
7. **Memories tab UI** → list + edit sheet + delete
8. **Run automated tests** → fix if fail
9. **Launch app + 30 min usage** → log-verify
10. **Give user test checklist** → run Scenarios 1-5

## 6. Risks & Open Questions {#risks}

### Risk 1: Memory extraction падает на тишине
Если скрин пустой / ничего интересного → LLM может галлюцинировать факты.
**Митигация:** confidence threshold 0.7 + existing_memories dedup + prompt "default to empty".

### Risk 2: Advice всё равно generic
Даже с prompt — Groq Llama может игнорировать constraints на низком temperature.
**Митигация:** automated test на bad patterns. Если FAIL — tune prompt ещё (например добавить explicit примеры с именами приложений).

### Risk 3: Backend endpoint `/api/pro/advice` не поддерживает новый JSON формат
Сейчас endpoint ждёт `{content, category, reasoning, confidence}`. Нам нужно добавить `{type: "advice"|"no_advice"}`.
**Решение:** backend update (небольшой edit api/src/index.js).

### ✅ Resolved by user (2026-04-17)

- **Memories separate from AI Advice** — отдельная вкладка в sidebar + отдельный toggle в Settings. Пользователь может управлять независимо.
- **Previous advice window = 20** (компромисс).
- **Categories: system + interesting оба** в первой итерации.

## 7. Changelog
- [2026-04-17] Initial draft spec. Awaiting user approval before implementation.
