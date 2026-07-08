# ITER-044: Apple Foundation Models — real on-device LLM (replace the stub) {#root}

> Статус: DRAFT / на ревью (Codex + человек). Dev-машина: macOS **26.5 (Tahoe)**, подтверждено `sw_vers`.
> Это план реализации. Точные сигнатуры FoundationModels API сверять с установленным macOS 26 SDK при кодинге — источник истины — ошибки компилятора.

---

## 0. TL;DR · Инварианты · Definition of Done {#top}

**Проблема.** `Services/LLM/LocalLLMService.swift:115-119` для модели `apple-foundation-models`
**безусловно** бросает `notSupportedYet("…ships separately — requires macOS Tahoe.")`. Настоящий
фреймворк Apple `FoundationModels` так и не подключён — это заглушка. Лог на каждом старте (даже на 26.5):
```
[ITER-039] auto-loading apple-foundation-models in background…
[ITER-039] ❌ auto-load failed: …ships separately — requires macOS Tahoe. — falling back to cloud
```
Итог: вся локальная интеллектуалка (memory/task/insight/chat/cleanup/advice/coach/reactor) реально
идёт через **облако (Pro)**, тумблер apple-foundation — no-op. При этом `ModelRegistry` показывает
её как `.recommended` на macOS 26+ (`ModelRegistry.swift:189-197`) → UI обещает, загрузка падает.

**Цель.** Реализовать бэкенд FoundationModels внутри `LocalLLMService`, чтобы на macOS 26+
`isReady == true` и `completeBlocking(...)` исполнялись **на устройстве** через Apple-фреймворк.
Потребители не меняются.

### 0.1 Инварианты {#top.invariants}
- **I1 — Потребители не трогаем.** Все 7 сервисов зовут `LocalLLMService.shared.isReady` +
  `completeBlocking(system:user:...)` (один — ещё `generate(...)`). Фикс делает обе ветки рабочими для
  FM; интерфейс не меняется (`MemoryExtractor:108-111`, `StructuredGenerator:777-778,858`,
  `AdviceService:106-108`, `MeetingCoachService:209-210`, `RealtimeScreenReactor:89-90`,
  `TaskExtractor:123`, цепочка Pro→BYOK→Local).
- **I2 — Availability-гард обязателен.** Deployment target = macOS 14. Ни один символ
  `FoundationModels` не должен исполняться < macOS 26 — всё под `if #available(macOS 26, *)` /
  `@available(macOS 26, *)`.
- **I3 — Graceful fallback.** FM недоступна (девайс не eligible / Apple Intelligence выключен /
  модель качается) ИЛИ guardrail-violation → не падаем, а кидаем восстановимую ошибку → потребитель
  уходит на cloud (как сейчас при `!isReady`).
- **I4 — Откат бесплатный.** Фича за существующим тумблером (`localLLMEnabled_iter039` +
  `localLLMActiveModelID_iter039`). Единственное изменение в проде — снос заглушки; при сбое FM
  авто-фоллбэк на cloud.

### 0.2 Definition of Done {#top.dod}
1. На macOS 26.5: выбор `apple-foundation-models` → грузится (лог `✅ ready`, не `❌`).
2. Реальная экстракция (memory/task) бежит **локально** (лог показывает local-путь, не cloud).
3. Availability-причины (device/AI-off/model-not-ready) маппятся в понятные ошибки; guardrail →
   fallback на cloud.
4. `swift build` зелёный (на toolchain с macOS 26 SDK); юнит-тесты роутинга/маппинга зелёные; guard-тест
   на `@available` зелёный.
5. Качество структурного JSON от ~3B-модели проверено на реальных транскриптах (иначе — оставить cloud
   для structured, FM — для лёгких задач).

---

## 1. Текущее состояние {#current}

- **Заглушка:** `LocalLLMService.swift:115-119` — `if spec.isFoundationModels { throw notSupportedYet(...) }`.
- **Реестр:** `ModelRegistry.swift` — запись `apple-foundation-models` (`isFoundationModels: true`,
  downloadSizeBytes 0, «native Apple Neural Engine»); `compatibilityVerdict` → `.recommended` при
  `macOSMajor >= 26` (`:189-197`).
- **Авто-загрузка:** AppDelegate уже зовёт `loadModel("apple-foundation-models")` на старте (лог
  `auto-loading…`). После фикса она просто **начнёт успешно грузиться — больше нигде wiring не нужен.**
- **Интерфейс, который надо удовлетворить:** `isReady: Bool`, `completeBlocking(system:user:maxUserChars:maxTokens:temperature:) async throws -> String`, `generate(prompt:maxTokens:temperature:) -> AsyncStream<String>`, `unloadModel()`.

---

## 2. Apple FoundationModels API (macOS 26+) — сверять с SDK {#api}

`import FoundationModels`. Ориентир (WWDC25; точные сигнатуры — по SDK):
- `SystemLanguageModel.default` + `.availability` → `.available` | `.unavailable(reason)`,
  reason ∈ `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady`.
- `LanguageModelSession(model:guardrails:tools:instructions:)` — `instructions` = system-блок.
- `session.respond(to:options:) async throws` → ответ с `.content: String`.
- `session.streamResponse(to:options:)` → async-последовательность (для `generate`).
- `GenerationOptions(temperature:, maximumResponseTokens:)`.
- `LanguageModelSession.GenerationError` (`.guardrailViolation`, `.exceededContextWindowSize`, …).
- Структурный вывод: `respond(to:generating: <Generable>.self)` — **Phase 2** (см. §5).

---

## 3. Дизайн — бэкенд-роутер внутри `LocalLLMService` {#design}

`LocalLLMService` становится роутером двух бэкендов: существующий **MLX** (Phi-3/4) и новый
**FoundationModels**.

- `private enum Backend { case mlx, foundationModels }` + `private var backend: Backend = .mlx`.
- FM-состояние держим в `@available(macOS 26, *)` обёртке. Свойства с `@available` хранить нельзя —
  поэтому **FM-сессия живёт в отдельном availability-аннотированном helper-типе**, на который
  `LocalLLMService` ссылается через `private var fmBackend: Any?` (каст на месте использования внутри
  `if #available`). Альтернатива — `if #available` ветки + приватный `@available` extension с
  методами; выбрать при кодинге, что чище компилируется.
- `loadModel(id:)` — FM-ветка вместо заглушки (§4).
- `completeBlocking(...)` — `switch backend`: FM → `fmComplete`, иначе MLX (как сейчас).
- `generate(...)` — `switch backend`: FM → `streamResponse`→`AsyncStream`, иначе MLX (нужно для
  `StructuredGenerator:858`).
- `unloadModel()` — чистить и `fmBackend`.

**Почему всё внутри `LocalLLMService`:** потребители завязаны на `isReady`+`completeBlocking`/`generate`
(I1). Сделать обе ветки рабочими для FM = нулевой blast-radius по потребителям.

---

## 4. Конкретные изменения {#changes}

### 4.1 `Services/LLM/LocalLLMService.swift` {#changes.service}
- `import FoundationModels` (системный фреймворк; использование — только под availability).
- `Backend` enum + `backend` + FM-state (`fmBackend: Any?`).
- **Заменить :115-119** на:
  ```swift
  if spec.isFoundationModels {
      guard #available(macOS 26, *) else {
          throw LocalLLMError.notSupportedYet("Apple Foundation Models requires macOS 26 (Tahoe).")
      }
      try loadFoundationModels()   // ставит backend=.foundationModels, isReady=true, currentModelID=id
      return
  }
  ```
- `@available(macOS 26, *) private func loadFoundationModels() throws`:
  - читает `SystemLanguageModel.default.availability`;
  - `.available` → создаёт `LanguageModelSession(instructions:…)` (или лениво при первом запросе),
    `backend=.foundationModels`, `isReady=true`, `lastError=nil`, лог `✅ ready`;
  - `.unavailable(reason)` → `throw LocalLLMError.notSupportedYet(mapFMUnavailable(reason))`.
- `@available(macOS 26, *) private func fmComplete(system:String, user:String, maxTokens:Int, temperature:Float) async throws -> String`:
  - сессия с `instructions: system`, `session.respond(to: user, options: GenerationOptions(temperature:, maximumResponseTokens: maxTokens))` → `.content`;
  - `catch GenerationError.guardrailViolation` (и прочие восстановимые) → `throw` восстановимую ошибку (потребитель уйдёт на cloud, I3).
- `completeBlocking(...)`: в начале — `if backend == .foundationModels, #available(macOS 26, *) { return try await fmComplete(...) }`, иначе текущий MLX-путь.
- `generate(...)`: аналогично — FM-ветка через `streamResponse` → мост в `AsyncStream`.
- `mapFMUnavailable(_:) -> String` — **чистая** функция (тестируемая): reason → текст
  («Включи Apple Intelligence в Системных настройках», «Устройство не поддерживает», «Модель ещё
  скачивается, попробуй позже»).

### 4.2 `Services/LLM/ModelRegistry.swift` {#changes.registry}
- Менять не обязательно (verdict уже `.recommended` на 26+). Опционально: пробросить под-причину
  доступности (AI выключен) в карточку Settings — чтобы текст был точнее. Низкий приоритет.

### 4.3 Сборка / линковка {#changes.build}
- `FoundationModels` — системный фреймворк macOS 26 SDK. SwiftPM: `import` + availability-гарды,
  явные `linkerSettings` обычно не нужны (системный авто-линк) — **проверить при сборке**.
- **Критично:** компиляция `import FoundationModels` требует **macOS 26 SDK** (Xcode 26 / совпадающие
  Command Line Tools). Проверить `xcrun --show-sdk-version` ≥ 26 до старта. Если toolchain старее —
  фича не скомпилится, нужен апдейт тулчейна (отдельный гейт).

---

## 5. Ограничения / риски {#risks}
- **Availability (I2)** — единственный реально опасный момент: любой незагарженный символ FM уронит
  приложение на < macOS 26. Закрывается `@available` + guard-тестом (§6).
- **Build SDK** — нужен macOS 26 SDK; иначе не собрать (см. 4.3).
- **Apple Intelligence** должен быть включён + девайс eligible; иначе `.unavailable` → fallback (I3).
- **Guardrails** Apple могут резать промпты (`guardrailViolation`) → catch + cloud-fallback.
- **Контекст** ~4k токенов; текущий `maxUserChars=2000` уже это учитывает; ловить
  `exceededContextWindowSize`.
- **Качество structured-JSON** у ~3B on-device может быть ниже cloud. У потребителей уже есть
  JSON-guard + cloud-fallback, но **проверить на реальных транскриптах**; при плохом JSON — оставить
  structured на cloud, а FM пустить на лёгкие задачи (gate/cleanup/advice).
- **Формат вывода** — потребители парсят JSON из текста; `respond(to:)` отдаёт текст → drop-in.
  Типизированный `@Generable` (убрал бы ручной парсинг) — **Phase 2**.

---

## 6. Тестируемость {#tests}
- **Чистое/юнитом:** `mapFMUnavailable(reason) -> String`; решение роутинга бэкенда по `model.id`
  (`backend(for: spec)`); комбинирование system+user. Вынести в pure-helper и покрыть.
- **Guard-тест** (как `WindowActivationGuardTests`): нет ли голого использования `FoundationModels`
  вне `@available`/`if #available` в `Services/` — защита I2.
- **НЕ юнитом:** сам инференс FM (нужен OS + Apple Intelligence) — ручной smoke.
- **Ручной smoke:** выбрать apple-foundation-models → лог `auto-load … ✅ ready`; триггернуть
  memory/task-экстракцию → лог показывает local-путь; глазами оценить качество вывода.

---

## 7. План итераций (TDD где можно) {#plan}
- [x] **044.1** — `LocalLLMBackend` enum + чистые хелперы (`FoundationModelsSupport.backend(for:)`, `message(for:)`) + `FMUnavailableReason` mirror + 6 юнит-тестов. Без вызовов FM. Файл `Services/LLM/FoundationModelsSupport.swift` (нет `import FoundationModels` — компилится на любой macOS).
- [x] **044.2** — `loadFoundationModels(id:)` (availability → isReady/backend), снос заглушки в `performLoad`, `fmReason(from:)` перевод Apple-reason. + guard-тест `FoundationModelsAvailabilityGuardTests` (scan `Services/`, зелёный: 0 незагарженных FM-символов = I2 подтверждён).
- [x] **044.3** — `completeBlocking` FM-ветка (`LanguageModelSession(instructions:)` → `respond(to:options:)` → `.content`); `GenerationError`/ошибки → recoverable `LocalLLMError` (I1/I3).
- [x] **044.4** — `generate` FM-ветка через `fmGenerate` (single-chunk `respond`, не token-stream — все потребители всё равно конкатенируют; FIFO-очередь + отмена сохранены).
- [x] **044.5 (UI)** — `MainSettingsView`: `«Coming soon»` → живая кнопка `foundationModelsActiveButton` (Make active/Active/Load now + inline-ошибка); миграция `.onAppear` теперь чистит FM-выбор только при `.incompatible` (<26).
- [ ] **044.6** — сборка (нужен macOS 26 SDK — **есть: SDK 26.2**) + ручной smoke (активировать FM → лог ✅ → локальная экстракция) + оценка качества JSON. **Ждёт явного OK на билд.**
- [ ] **044.7** *(pre-ship)* — проверить **weak-linking** `FoundationModels` на релизном бинаре (`otool -l | grep -A2 LC_LOAD_WEAK_DYLIB`), иначе app не стартует на macOS <26. Deployment target 14 → авто-weak ожидается, но подтвердить.
- [ ] **044.8** *(Phase 2, опц.)* — `@Generable` типизированный вывод → убрать ручной JSON-парсинг у потребителей.

### 7.1 Codex-ревью (2 раунда, 2026-07-08) {#plan.codex}
- **Раунд 1:** `swift build` зелёный (20.15s), `swift test` **573 tests, 0 failures** (мои 7 новых зелёные; guard-тест 1/1 = I2 ок). 2×P2:
  - *Stale backend при неудачной FM-загрузке* → **исправлено:** `resetLoadedModelState()` в `.unavailable`-ветке `loadFoundationModels` (сброс на cloud вместо тихого продолжения на старой MLX-модели).
  - *Нет cloud-fallback при runtime-сбое FM* → **частично исправлено:** re-check `availability` в `catch` `fmComplete`; глобальный отказ (AI выключен mid-session / assets pulled) → `resetLoadedModelState()` → cloud.
- **Раунд 2:** билд зелёный (пост-фикс компилится). Остаётся 1×P2 — **осознанное дизайн-решение** (см. ниже), не баг. (2 упавших теста — `TextInsertionClipboardTests`/`TranscriptionCoordinatorRecoveryTests` — sandbox-флейки Codex: нужен реальный pasteboard / writable Application Support; в раунде 1 те же тесты зелёные. Не связаны с ITER-044.)

### 7.2 Открытое дизайн-решение: prompt-specific FM-сбой {#plan.decision}
Codex настаивает: guardrail/context-сбой на конкретном промпте у Pro/BYOK-юзера должен уходить на cloud, а не просто `.failedAttempt`. **Оставлено как есть (вариант A)** для ITER-044:
- **A (принято):** local-first честный — FM обрабатывает что может; редкий промпт (harmful-контент / переразмер) падает и дропается после retry-капа, **как MLX сегодня**. Консистентно, чтит приватность opt-in-в-local, **ноль изменений у потребителей (I1)**.
- **B (будущая итерация, опц.):** cloud-fallback при любом local-сбое — трогает 7 потребителей (нарушает I1) И шлёт в облако промпт, который юзер выбрал держать on-device (утечка приватности opt-in). Отдельный скоуп + тумблер.
- Edge-case узкий: на нормальных транскриптах Apple-guardrail практически не срабатывает, а контекст (≤6000 симв ≈ 1800 токенов) влезает в окно FM.

---

## 8. Верификация и откат {#verify}
- **Верификация:** лог `auto-loading apple-foundation-models … ✅` + экстракция бежит локально + качество.
- **Откат:** тумблер `localLLMEnabled_iter039` / выбор другой модели → возврат на cloud мгновенно; при
  сбое FM availability/guardrail-catch уводит на cloud автоматически.

---

## Changelog
- [2026-07-08] Реализация 044.1–044.5. API сверено с реальным SDK-интерфейсом
  (`FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`, SDK 26.2), не по памяти.
  2 упрощения драфта, обоснованные фактами: (1) FM out-of-process → не нужен GCD-hop;
  (2) сессии stateless per-call → не нужно хранить FM-типизированное свойство (I2 закрыт тривиально,
  без `fmBackend: Any?`). Codex-ревью 2 раунда: билд+573 теста зелёные, 2×P2 исправлено, 1×P2 —
  дизайн-решение (§7.2). Осталось: 044.6 (билд+smoke, ждёт OK) + 044.7 (weak-link на релизе).
- [2026-06-04] §0–§8: первичный план замены заглушки apple-foundation-models
  (`LocalLLMService.swift:115-119`) на реальный бэкенд Apple FoundationModels. macOS 26.5 на dev-машине
  подтверждена. DRAFT — ждёт ревью Codex + человека.
