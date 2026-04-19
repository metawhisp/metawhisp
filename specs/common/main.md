# Архитектура MetaWhisp {#root}

## 1. Что это {#purpose}

Voice-to-text macOS приложение в menu bar. Нажал Right ⌘, сказал, отпустил → текст появляется в активном приложении. Работает полностью **on-device** через WhisperKit + Metal GPU. Опциональный cloud-режим (Groq/OpenAI) для Pro подписки.

**Расширенная версия (эта сессия):** добавлены фичи, которые обычно делают "privacy-invasive" cloud-приложения — запись созвонов, контекст экрана, AI-советы — но **с локальной обработкой**. Cloud-альтернативы шлют всё в Firebase/Pinecone/OpenAI. MetaWhisp держит у себя.

## 2. Tech stack {#stack}

| Слой | Технология |
|------|-----------|
| Language | Swift 6 |
| UI | SwiftUI |
| Build | Swift Package Manager (`Package.swift`) |
| ML (on-device) | WhisperKit + Metal |
| OCR | Apple Vision (VNRecognizeTextRequest) |
| Screen capture | ScreenCaptureKit (macOS 14+) |
| System audio | SCStream `.audio` output (macOS 14+) |
| Storage | SwiftData (SQLite) |
| Hotkeys | NSEvent global monitors |
| Auto-updates | Sparkle |
| LLM (cloud) | OpenAI / Cerebras / Deepgram (Pro proxy) |
| Backend | Cloudflare Workers (`api/` — НЕ трогать без явного запроса) |

## 3. Директория-слоистость {#layers}

```
App/                  # Lifecycle (AppDelegate, MetaWhispApp entry)
Services/             # Domain logic — по подпапкам
  Audio/              # AudioRecordingService, SystemAudioCaptureService, MeetingRecorder, AudioSource
  Transcription/      # WhisperKitEngine, CloudWhisperEngine, ModelManagerService
  Processing/         # TextProcessor, CorrectionDictionary, CorrectionMonitor
  Cloud/              # OpenAIService (LLM), CloudTranscriptionProvider
  Screen/             # ScreenContextService (OCR via Vision)
  Intelligence/       # AdviceService (LLM поверх screen + transcripts)
  System/             # TranscriptionCoordinator, HotkeyService, TextInsertionService, SoundService, PermissionsService
  Data/               # HistoryService (SwiftData container)
  License/            # LicenseService (Pro activation)
Models/               # AppSettings, HistoryItem, TranscriptionResult, ScreenContext, AdviceItem
Views/                # SwiftUI views
  MenuBar/            # Popover (MenuBarView, PopoverRootView)
  Windows/            # Main window (Dashboard, History, Insights, Dictionary, Settings)
  Components/         # Reusable UI (ActivityChart, RecordingOverlay, PillVariants)
Helpers/              # DesignSystem (MW), NotchDetector, TextAnalyzer
Resources/            # Info.plist, MetaWhisp.entitlements, Sounds/, AppIcon.icns
specs/                # Spec-driven docs (this directory)
.human/               # Private notes (AI-ignored via .claudeignore)
api/                  # Cloudflare Worker backend (не трогать без запроса)
website/              # Marketing landing (не трогать без запроса)
```

## 4. Ключевые решения {#decisions}

### 4.1. AudioSource протокол {#decisions.audio-source}
Оба источника звука (микрофон, системное аудио) имеют одинаковый интерфейс: `start()`, `stop() -> [Float]`, `audioLevel`, `audioBars`. Это позволило `TranscriptionCoordinator` работать с любым источником без branching.

Выходной формат ВСЕГДА 16kHz mono Float32 PCM — чтобы WhisperKit получал одно и то же.

### 4.2. Hallucination filter — static на TranscriptionCoordinator {#decisions.hallucination}
Whisper (OpenAI модель) галлюцинирует на тишине/шуме фразами типа "Продолжение следует", "Субтитры от Amara.org", "Subscribe". Фильтр — `isAlwaysHallucination()` + `isHallucination()` — static методы на `TranscriptionCoordinator`, переиспользуются meeting recording через `AppDelegate.stopMeetingRecording()`.

Порог RMS для применения pattern-фильтра: 0.003 (около-тишина). Всегда-галлюцинации (YouTube-артефакты) режутся независимо от RMS.

### 4.3. MeetingRecorder микширует mic + system audio {#decisions.meeting-mix}
Без микширования голос пользователя терялся — он идёт в микрофон → в Zoom → по сети, не в колонки. System audio captures ТОЛЬКО что играет из колонок (другие участники).

Решение: параллельно запускаем оба `AudioSource`, на stop() складываем sample-by-sample с soft-clipping в [-1, 1]. Если mic permission нет — `micOnlyMode = true`, запись только system audio + предупреждение в UI.

### 4.4. Screen context — никогда не сохраняем скриншоты {#decisions.screen-privacy}
В отличие от cloud-аналогов, MetaWhisp не хранит JPEG. Pipeline:
1. ScreenCaptureKit → CGImage (в памяти)
2. Vision OCR → текст
3. Сохраняем ТОЛЬКО текст + метаданные (app name, window title, timestamp) в SwiftData
4. CGImage освобождается GC

Blacklist по умолчанию: `com.apple.Passwords`, 1Password, Bitwarden, Keychain Access.

### 4.5. AI Advice использует существующий LLM {#decisions.advice-llm}
Не плодим новых провайдеров. AdviceService вызывает `OpenAIService.complete()` с тем же `apiKey` и `LLMProvider`, что и обычная обработка текста (Pro proxy / Groq / OpenAI / Cerebras).

### 4.6. PermissionsService — активный TCC триггер {#decisions.permissions}
macOS НЕ показывает диалог разрешения только от наличия `NSScreenCaptureUsageDescription` в Info.plist. Нужно активно вызвать API который триггерит диалог:
- `CGRequestScreenCaptureAccess()` — старый TCC
- `SCShareableContent.excludingDesktopWindows(...)` — ScreenCaptureKit (отдельная TCC запись с macOS 14+)

`PermissionsService.requestScreenRecording()` делает оба вызова. Триггерится на toggle в Settings (не на первом клике Record).

### 4.7. Один билд, в `~/Applications`, без sudo {#decisions.build}
`build.sh` ставит `.app` в `~/Applications/MetaWhisp.app`. TCC привязан к bundle signature — при стабильном ad-hoc подписе разрешения сохраняются между rebuild'ами.

НЕ использовать sudo в build scripts — root-owned файлы блокируют последующие rebuild'ы до ручной очистки.

## 5. Инварианты {#invariants}

- Один запущенный instance MetaWhisp в системе (guard в AppDelegate)
- Bundle ID: `com.metawhisp.app` (привязан к TCC entries)
- Запись и транскрипция НИКОГДА не блокируют main thread дольше ~50ms (всё через `Task {}`)
- Ошибки async setup (SCStream, CoreAudio) ВСЕГДА surface в UI (lastError @Published)
- Hallucination filter применяется ко ВСЕМ output'ам транскрипции (обычная запись + meeting)

## Changelog
- [2026-04-16] Initial architecture doc after Intelligence Expansion sprint
