# Project State Dump — 2026-04-18

Полный снимок проекта MetaWhisp. Используй для онбординга новых сессий / напоминания о текущем состоянии.

---

## 1. Что это за проект {#what}

**MetaWhisp** — macOS menu bar app для voice-to-text.
Основной flow: Right ⌘ → голос → WhisperKit транскрипция → текст в активный инпут.

**Расширяется до** ассистента (privacy-first, локально):
- Memory system (знает тебя)
- Insights (персональные советы)
- Meeting Recording (запись созвонов с mic+system audio mix)
- Screen Context (OCR активного окна)
- File Indexing (индексация твоих папок → memories)
- Goals / Focus / Tasks (планируется)

**Stack:** Swift 6 / SwiftUI / SwiftData / WhisperKit / ScreenCaptureKit / Apple Vision / Cloudflare Workers backend / Groq Llama 3.3.

---

## 2. Текущее состояние кода {#state}

### Работает стабильно ✅
- **Voice-to-text core** — Right ⌘ → WhisperKit (on-device OR cloud Pro) → Cmd+V в инпут
- **Meeting Recording** — mic + system audio mix через SCStream, waveform, автодетект Zoom/Teams/Meet
- **Screen Context** — ScreenCaptureKit + Apple Vision OCR, blacklist (банки, password managers), whitelist mode
- **AI Advice** — no_advice escape, bad examples в промпте, через Pro proxy
- **Memory system** — UserMemory SwiftData + MemoryExtractor (strict accept/reject)
- **Permissions** — активный TCC триггер (CGRequestScreenCaptureAccess + SCShareableContent)
- **Insights UI** — таб с секциями Advice / Meetings / Screen Context, dismiss, mark-read
- **Memories UI** — отдельный таб в sidebar с filter (System / Interesting / All), edit, delete
- **Notifications** — macOS system notifications при advice generation (click → Insights tab)

### В процессе / требует live-теста ⏳
- **Iteration 1 end-to-end тест** — Memories extraction + advice. Код deployed, user тестирует как использует app
- **GENERATE NOW / EXTRACT NOW кнопки** — для instant-теста (bug fixed с @MainActor in)

### Планируется ❌
- **Iteration 2: File Indexing** — **СЕЙЧАС СТАРТУЕМ**
- Floating Ask AI (hotkey → mini AI popup)
- Persona (синтез из Memory)
- Focus Session Tracking
- Goals daily generation
- Tasks extraction

---

## 3. Архитектура {#architecture}

### Директории
```
App/                  Lifecycle (AppDelegate)
Services/
  Audio/              AudioRecordingService, SystemAudioCaptureService, MeetingRecorder
  Transcription/      WhisperKitEngine, CloudWhisperEngine
  Processing/         TextProcessor, CorrectionDictionary
  Cloud/              OpenAIService (LLM)
  Screen/             ScreenContextService
  Intelligence/       AdviceService, MemoryExtractor
  System/             TranscriptionCoordinator, HotkeyService, TextInsertionService,
                      SoundService, PermissionsService, NotificationService
  Data/               HistoryService (SwiftData container)
  License/            LicenseService
Models/               AppSettings, HistoryItem, UserMemory, AdviceItem, ScreenContext
Views/                MenuBar/ Windows/ Components/
specs/                spec-driven docs
api/                  Cloudflare Worker (api.metawhisp.com)
```

### Что трогать НЕ надо
- `TranscriptionCoordinator.isAlwaysHallucination` / `isHallucination` — используются в 2 местах
- Существующий voice-to-text pipeline (Right ⌘ → текст) — работает, не ломать
- bundle ID `com.metawhisp.app` — к нему привязаны TCC entries
- `website/` и `api/` — не трогать без явного запроса

### Backend endpoints (api.metawhisp.com)
- `POST /api/pro/transcribe` — Pro transcription via Deepgram
- `POST /api/pro/process` — text processing / translate
- `POST /api/pro/advice`.3
- `GET /api/usage` — balance / history

### Pro subscription limits (just fixed)
- `dailyAllowance = 60` min/day (accrual rate)
- `maxBalance = 1800` min (было 600, сегодня поднял)
- Error messages now accurate

---

## 4. Что случилось в прошлой сессии {#session-log}

### Реализовано (Iteration 1)
1. **UserMemory SwiftData model** — categories system + interesting, soft delete
2. **MemoryExtractor**, strict accept/reject lists, 10-min timer, dedup 20 recent
3. **MemoriesView** — отдельный таб в sidebar, toggle `memoriesEnabled` независимый
4. **AdviceService rewrite**, bad examples, no_advice escape)
5. **Memory injection** в advice prompt (личные факты → персональные советы)
6. **Previous advice window** 5 → 20 (anti-repetition)
7. **Backend `/api/pro/advice`** — новый endpoint, deployed
8. **Backend fixes** — MAX_PROMPT_LEN 8000→32000, maxBalance 600→1800
9. **EXTRACT NOW / GENERATE NOW кнопки** — с debug logs и @MainActor
10. **Auto-restart ScreenContext** — когда permission grant'ится в runtime (applicationDidBecomeActive)

### Ключевые bugfixes сессии
- `Task { @MainActor in }` — без этого NSApp.delegate возвращал nil в SwiftUI views
- Backend MAX_PROMPT_LEN 8000 был слишком мал для advice с OCR контентом → HTTP 400
- ScreenContext не рестартился после runtime grant permission
- Infinite loop в AudioRecordingService observer → guard `configObserver == nil`

### Болевые точки сессии
- **TCC permissions сбрасывались 4-5 раз** из-за ad-hoc подписи менявшейся между rebuild
- Potential fix: **self-signed cert** (отложено — user не захотел прямо сейчас)
- Apple Developer paid subscription отсутствует — только бесплатный tier

---

## 5. Что дальше — Iteration 2: File Indexing {#next}

### User priority (заявлен ранее)
1. ✅ Memories foundation (Iter 1 — done)
2. ⏭️ **File Indexing + Knowledge Graph** — СЕЙЧАС
3. Floating Ask AI
4. Persona
5. Focus / Goals

### Iteration 2 scope — ждёт решений пользователя

**3 вопроса по scope** (ответ нужен для старта):

#### Q1: Типы файлов
- A) только `.md` + `.txt` (Obsidian-style)
- B) A + `.pdf` через PDFKit
- C) A + B + `.docx` + код (.swift/.js/.py)

Рекомендация: **A**

#### Q2: Когда сканировать
- A) Вручную "Scan now" кнопка
- B) При добавлении папки + re-scan кнопка
- C) FSEvents авто (сложно)

Рекомендация: **B**

#### Q3: Где показывать результат
- A) В Memories tab с фильтром "From Files"
- B) Отдельный Files tab
- C) Секция в Settings

Рекомендация: **A**

### Out of scope (ОТЛОЖЕНО)
- Knowledge Graph визуализация
- Full-text search
- Embeddings / vector search
- Auto-update при изменении файлов
- Intents / Spotlight integration

---

## 6. Рабочие правила — Karpathy Principles {#rules}

Обязательны. See `specs/KARPATHY.md`.

1. **Think Before Coding** — не выбирать молча, спрашивать
2. **Simplicity First** — никакой speculation, минимум кода
3. **Surgical Changes** — трогать только что нужно
4. **Goal-Driven Execution** — verifiable success criteria до кода

### "Global changes" (требуют обсуждения) только если
- Small fix не двигает метрики 2-3 попытки
- Новая принципиальная функция
- Contract change в нескольких слоях
- Privacy / security invariant под угрозой

### Default режим
Приложение работает. Минимальные surgical-правки. Не переписываем, не добавляем abstraction layers без нужды.

---

## 7. Как стартовать следующую сессию {#bootstrap}

1. Прочитать `specs/KARPATHY.md` — принципы работы
2. Прочитать `specs/WAL.md` — state continuation
3. Прочитать этот файл (`sessions/2026-04-18-project-state.md`) — контекст
4. Запустить `swift build` — убедиться что компилируется
5. Если в WAL указана задача — продолжить. Если нет — спросить user.

---

## 8. Key docs map {#docs}

| Файл | Что |
|------|-----|
| `specs/KARPATHY.md` | Принципы работы (обязательно первым) |
| `specs/BOOT.md` | Session bootstrap |
| `specs/WAL.md` | Текущее состояние + next TODO |
| `specs/common/main.md` | Архитектура + ключевые решения |
| `specs/common/structure.md` | Module map |
| `specs/iterations/ITER-001.md` | Memory + Insights (done) |
| `specs/modules/audio/FEAT-0001.md` | Meeting Recording (done) |
| `specs/modules/intelligence/FEAT-0002.md` | Screen Context (done) |
| `specs/modules/intelligence/FEAT-0003.md` | AI Advice (done) |
| `specs/modules/system/FEAT-0004.md` | Permissions (done) |
| `specs/modules/audio/PROP-0001.md` | AudioSource protocol (done) |
| `specs/SPEC-PROTOCOL.md` | Spec-driven правила |
| `specs/WAL-PROTOCOL.md` | WAL правила |
