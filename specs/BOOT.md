# Начальная загрузка

Ты — AI-сопроцессор в паре человек-AI на проекте **MetaWhisp** (macOS app).

**БАЗОВЫЙ РЕЖИМ РАБОТЫ — Karpathy Principles.** Читать ПЕРВЫМ.

## Первые шаги (ВСЕГДА)
1. **Прочитай `specs/KARPATHY.md`** — 4 принципа, нарушение = баг поведения
2. Прочитай `specs/WAL.md` — текущее состояние и следующий TODO
3. Прочитай `specs/common/main.md` — архитектурный контекст
4. Запусти: `swift build`
5. Если не компилируется — сообщи ДО начала работы

## Критические напоминания из Karpathy

- **Приложение уже работает** — default = минимальные surgical-фиксы, не переписывание
- **Speculation запрещена** — не писать "как бы могло быть"-архитектуры до подтверждения что minimum fix не работает
- **Success criteria до кода** — каждое изменение с измеримой verification
- **Global changes только** если minimum failed 2-3 раза ИЛИ новая фича ИЛИ contract change ИЛИ privacy invariant (см. KARPATHY.md § MetaWhisp-specific application)

## Идентичность проекта
- **Что это:** macOS menu bar app для voice-to-text транскрипции + meeting recording + screen context + AI advice
- **Stack:** Swift 6, SwiftUI, SPM, WhisperKit, SwiftData, ScreenCaptureKit, Apple Vision
- **Спецификации:** `specs/` (spec:// URI)
- **Реализация:** `App/`, `Services/`, `Models/`, `Views/`, `Helpers/`, `Resources/`
- **Backend:** Cloudflare Workers (`api/`) — трогаем ТОЛЬКО по явному запросу

## Сборка и тесты
- **Dev build:** `swift build` (быстрая компиляция, нет .app)
- **Release build + install + launch:** `./build.sh` (полный цикл)
- **Где живёт app:** `~/Applications/MetaWhisp.app` (НЕ `/Applications`)

## Протокол коммуникации
- Адресуемость: `spec://<модуль>/<DOC>#<секция>.<подсекция>`
- Один коммит = одна секция спеки + код + (если применимо) тесты
- При разногласии со спекой: реализуй как в спеке + `<!-- REVIEW: причина -->`

## Критические правила
- **НЕ ТРОГАЙ** `TranscriptionCoordinator.isAlwaysHallucination` / `isHallucination` — фильтры устоявшиеся, переиспользуются
- **НЕ ЛОМАЙ** протокол `AudioSource` — к нему привязаны `AudioRecordingService`, `SystemAudioCaptureService`, `MeetingRecorder` косвенно
- **НЕ ТРОГАЙ** текущий pipeline обычной записи (Right ⌘ → WhisperKit → clipboard) — работает стабильно
- **НЕ МЕНЯЙ** bundle ID `com.metawhisp.app` — привязаны TCC разрешения
- **НЕ ДОБАВЛЯЙ** root-owned файлы (никаких `sudo` в build.sh) — блокирует rebuild
- **НЕ ТРОГАЙ** `website/` и `api/` без явного запроса
- **ОБНОВЛЯЙ** WAL.md в конце сессии — всегда

## Паттерн сессии
Прочитай WAL → определи TODO → прочитай секцию спеки → реализуй → `swift build` → обнови WAL → отчитайся
