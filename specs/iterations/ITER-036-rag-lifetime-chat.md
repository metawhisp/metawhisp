# ITER-036 — RAG Chat по всей жизни («когда я с Машей последний раз говорил?»)

**Проблема:** MetaChat сейчас (`ChatService`) умеет RAG, но retrieval работает плохо для **named-entity + temporal** queries:
- «Когда я с Машей последний раз говорил?» — Маша может быть упомянута в 50 conversations, semantic ranking по embeddings не даёт чёткий «latest» ordering
- «Что обсуждали на standup на прошлой неделе?» — temporal phrase «на прошлой неделе» не превращается в date filter
- «Сколько я с Семёном встречался за последний месяц?» — counting query вообще не покрывается RAG

User уже verified что базовый MetaChat работает (memory note B2: «pulled UserMemory, TaskItem, honestly declined out-of-scope»). Это итерация = expansion existing functionality на entity + temporal axes.

## Reference patterns

- **`ChatService.swift`** в `Services/Intelligence/` — текущий RAG. Loads UserMemory (semantic) + recent ScreenContext + recent transcripts + pending tasks.
- **`ScreenExtractor.swift:471-472`** — нормализация LLM JSON (paranthесs strip). Тот же подход для query parsing.
- **omi memory architecture (reference memory note):** Conversation = root. Person = first-class entity (через `attendees` для meetings + extracted names из transcripts).

## Scope

### 1. `Models/EntityMention.swift` — NEW

```swift
@Model
final class EntityMention {
    var id: UUID
    var entityName: String          // canonical: "Maria" (lowercased indexing)
    var displayName: String         // as appeared: "Маша" / "Машка" / "Maria"
    var entityType: String          // "person" | "project" | "company"
    var sourceType: String          // "conversation" | "history" | "memory"
    var sourceId: UUID              // FK
    var firstMentionAt: Date
    var lastMentionAt: Date
    var mentionCount: Int
}
```

Индекс: `(entityName, lastMentionAt DESC)` для быстрого «когда последний раз».

### 2. `Services/Intelligence/EntityExtractor.swift` — NEW (@MainActor)

**API:**
```swift
@MainActor
final class EntityExtractor {
    func configure(modelContainer: ModelContainer)
    // Trigger: после каждого новой transcription / conversation save
    func extractFromHistory(_ id: UUID) async
    func extractFromConversation(_ id: UUID) async
    // Bulk: для existing data
    func backfillAll() async
}
```

**Strategy — гибрид:**
1. **Fast path (Apple NL):** `NLTagger.tagsForString(:tagSchemes: [.nameType])` — extract `personalName` / `organizationName` / `placeName`. На-device, бесплатно, fast. Покрывает ~70% случаев.
2. **LLM fallback (Pro):** для длинных transcripts (≥500 chars) — single short prompt: «Extract entities (people, projects) and aliases as JSON». Catch русские имена / typos где NLTagger fails.

**Aliasing:** «Маша», «Машка», «Маша-Маша» → canonical `"маша"`. Через простую normalisation (NFD + lowercase + collapse repeats). 

**Cross-source unification:** один Person entity ссылается на все upcoming/past `EntityMention.sourceId`'ы.

### 3. `Services/Intelligence/QueryParser.swift` — NEW (pure)

**Parses natural-language query into structured intent:**
```swift
enum QueryIntent: Equatable {
    case findLastMention(entityName: String)
    case findInDateRange(query: String, range: DateRange)
    case countMentions(entityName: String, since: Date?)
    case openEnded(text: String)  // fallback — текущий RAG path
}

enum DateRange {
    case lastNDays(Int)
    case lastWeek, lastMonth, today, yesterday
    case absolute(start: Date, end: Date?)
}

func parseQuery(_ q: String) -> QueryIntent
```

**Parse rules (pure regex + lookup):**
- Triggers «когда последний раз» / «when last» / «last time» → `findLastMention`
- «на прошлой неделе» / «last week» / «3 дня назад» / «yesterday» → `DateRange`
- «сколько раз» / «how many» → `countMentions`
- Иначе → `openEnded` → existing RAG

**Pure function, тестируется отдельно. 15+ test cases для разных формулировок.**

### 4. `Services/Intelligence/ChatService.swift` — расширение

В `send(_ query, source:)`:
```swift
let intent = QueryParser.parse(query)
switch intent {
case .findLastMention(let name):
    let last = entityIndex.lookupLastMention(entityName: name)
    let context = await fetchContextAround(mention: last, contextChars: 800)
    // Build prompt: "Юзер спрашивает '<query>'. Вот последнее упоминание: <context>"
case .findInDateRange(let q, let range):
    let convos = fetchConversations(in: range)
    let memos = fetchMemories(in: range)
    // Inject in prompt with explicit date range markers
case .countMentions(let name, let since):
    let n = entityIndex.countMentions(name: name, since: since)
    // Pure deterministic answer: "Вы упоминали <name> N раз с <since>"
case .openEnded(let text):
    // Existing path
}
```

LLM still talks — но мы даём ему **строго отфильтрованный** context, не общий semantic-similarity blob.

### 5. `Views/Windows/ChatView.swift` — UI hint

Помимо просто чата — лёгкая UI подсказка про новые capabilities:
- Placeholder text в TextField: «Спроси — когда я с Машей последний раз говорил, или что обсуждали на standup в среду»
- Под ответом «Last mention»: маленькая ссылка `[Open conversation →]` которая открывает Library detail с deeplink

### 6. `App/AppDelegate.swift`

- Instantiate `entityExtractor`.
- Wire trigger: после `historyService.save(...)` и `conversationGrouper.assign(...)` — async fire-and-forget `entityExtractor.extractFromXxx(id)`.
- На launch: `entityExtractor.backfillAll()` если флаг `didBackfillEntities == false`. One-shot для existing 5000+ history items.

### 7. `Models/AppSettings.swift`
- `+didBackfillEntities: Bool = false` — migration flag для backfill.
- `+ragLifetimeChatEnabled: Bool = true` — kill switch если QueryParser зашалит.

## Edge cases

- **Multilingual names** — «Maria» в EN transcript + «Маша» в RU transcript → одна и та же person. Aliasing layer связывает; NLTagger детектит оба.
- **Common names** («Sam», «Maria») — могут collide. Counter-mitigation: scope retrieval к conversations с явным контекстом (avoid false positives через nearby word frequency).
- **Empty entity index при первом запросе** — fallback к open-ended RAG + user message «No entity mentions indexed yet, ask again after a few minutes».
- **«Когда последний раз» без entity** — `«когда последний раз я обсуждал X?»` — extract topic X через keyword search, not entity index.

## Acceptance

1. Существующая DB (9 conversations + 5000+ history) → backfill extract entities → log: `[EntityExtractor] backfilled N persons, M companies from K records`
2. Запрос «когда я с Sam последний раз говорил?» (где Sam mentioned в недавних conversations) → ответ содержит дату + цитату из transcript + ссылку «Open conversation →»
3. Запрос «на прошлой неделе про что говорили?» → ответ summarises conversations between (today - 7) and today
4. Запрос «сколько я с Sam встречался за последний месяц?» → детерминированный ответ типа «3 встречи за период…»
5. Запрос «что такое quantum entanglement?» → falls back to open-ended RAG (off-topic для user data, LLM declines as before — verify не сломали legacy path)
6. Toggle `ragLifetimeChatEnabled = false` → новые intents отключаются, chat работает как до итерации
7. Performance: parse + lookup < 100ms на typical query (UI не лагает)

## Out of scope (defer)

- Voice queries — текущая итерация: text only. Voice through MetaChat — отдельный track.
- Suggested questions UI («Try asking: 'When did I last talk about X?'»)
- Cross-machine sync entity index — single-device first.
- Sentiment analysis по mentions

## Implementation checklist

- [ ] **Step 1 — Model:** `EntityMention.swift` + добавить в SchemaV1 / SwiftData model container
- [ ] **Step 2 — Pure parser:** `QueryParser.swift` + `QueryParserTests.swift` со 15 cases (RU + EN), все green
- [ ] **Step 3 — NLTagger wrapper:** `EntityNameNormalizer.swift` (pure) — NFD + lowercase + alias mapping. Тесты для «Маша/Машка/Maria»
- [ ] **Step 4 — Service shell:** `EntityExtractor.swift` API skeleton (no NL/LLM yet)
- [ ] **Step 5 — Fast path:** NLTagger integration — extract from transcript, dedup, write `EntityMention` rows
- [ ] **Step 6 — Backfill:** `backfillAll()` идиоматически — iterate all HistoryItem + Conversation + UserMemory, extract entities, save
- [ ] **Step 7 — Subscribe to new items:** wire async trigger в `HistoryService.save` + `ConversationGrouper.scheduleOnClose`
- [ ] **Step 8 — Index helpers:** `lookupLastMention(name:)` / `countMentions(name:since:)` — SwiftData queries with proper indexing
- [ ] **Step 9 — ChatService integration:** parse intent → route → fetch context → prompt LLM with structured payload
- [ ] **Step 10 — UI:** ChatView placeholder hint + «Open conversation» deeplink button
- [ ] **Step 11 — LLM fallback for long transcripts:** для transcripts ≥500 chars — Pro proxy call для LLM-based entity extraction. Wire into Step 5
- [ ] **Step 12 — Manual smoke:** записать 3 voice notes mentioning «Sam» → задать «когда я с Sam последний раз говорил» → проверить response
- [ ] **Step 13 — Edge case smoke:** common-name false positives, multilingual aliases, empty-index fallback
- [ ] **Step 14 — Spec close:** WAL + memory update

## Estimated effort

- Pure parser + tests: 0.5 дня
- Entity extractor (NL + bulk): 1 день
- ChatService integration: 0.5 дня
- LLM fallback + edge cases: 0.5 дня
- Manual smoke + tuning: 0.5 дня
- Total: **~3 дня**

## Open questions for tomorrow

1. **Aliasing UI** — нужен ли юзеру manual «Sam» и «Семён» это один человек контроль? Or auto-merge by similarity и доверять LLM? **Default: auto-merge, manual override через chat command «merge Sam Семён»** (separate UI later).
2. **Backfill time** — 5000+ history items × NLTagger ~10ms каждый = ~50s блокирующее окно. Делать background чтоб не зависал UI.
3. **LLM cost для бекfill** — если идём через LLM fallback на все 5000 → ~$1.50. Phase backfill: fast NL path для всех, LLM upgrade только для transcripts ≥500 chars (≈ 30% от total).
