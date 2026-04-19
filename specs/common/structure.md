# Module Map {#root}

Карта модулей MetaWhisp со ссылками на спеки.

## audio/ {#audio}
Сервисы захвата аудио и их оркестрация.

| Файл | Ответственность | Спека |
|------|-----------------|-------|
| `Services/Audio/AudioSource.swift` | Протокол источника аудио | `spec://audio/PROP-0001` |
| `Services/Audio/AudioRecordingService.swift` | Mic capture (AVAudioEngine) | `spec://audio/PROP-0001#mic` |
| `Services/Audio/SystemAudioCaptureService.swift` | System audio (SCStream) | `spec://audio/PROP-0001#system` |
| `Services/Audio/MeetingRecorder.swift` | Mic+system mix для созвонов | `spec://audio/FEAT-0001` |

## transcription/ {#transcription}
Транскрипция и post-processing.

| Файл | Ответственность | Спека |
|------|-----------------|-------|
| `Services/Transcription/WhisperKitEngine.swift` | On-device ML | `spec://transcription/PROP-0002#ondevice` |
| `Services/Transcription/CloudWhisperEngine.swift` | Cloud transcription | `spec://transcription/PROP-0002#cloud` |
| `Services/System/TranscriptionCoordinator.swift` | Lifecycle orchestrator + hallucination filter | `spec://transcription/PROP-0003` |
| `Services/Processing/TextProcessor.swift` | Filler removal + LLM clean/translate | (legacy, стабильно) |
| `Services/Processing/CorrectionDictionary.swift` | Автообучаемые правки | (legacy, стабильно) |

## screen/ {#screen}
Захват и анализ экрана.

| Файл | Ответственность | Спека |
|------|-----------------|-------|
| `Services/Screen/ScreenContextService.swift` | Capture + OCR | `spec://screen/FEAT-0002` |
| `Models/ScreenContext.swift` | SwiftData модель | `spec://screen/FEAT-0002#model` |

## intelligence/ {#intelligence}
AI поверх собранных данных.

| Файл | Ответственность | Спека |
|------|-----------------|-------|
| `Services/Intelligence/AdviceService.swift` | Генерация советов через LLM | `spec://intelligence/FEAT-0003` |
| `Models/AdviceItem.swift` | SwiftData модель | `spec://intelligence/FEAT-0003#model` |

## system/ {#system}
Системная интеграция.

| Файл | Ответственность | Спека |
|------|-----------------|-------|
| `Services/System/PermissionsService.swift` | TCC управление | `spec://system/FEAT-0004` |
| `Services/System/HotkeyService.swift` | Global hotkeys | (legacy, стабильно) |
| `Services/System/TextInsertionService.swift` | Вставка через Cmd+V | (legacy, стабильно) |
| `Services/System/SoundService.swift` | Звуковые эффекты | (legacy, стабильно) |
| `Services/Data/HistoryService.swift` | SwiftData контейнер | — |

## ui/ {#ui}

| Директория | Что внутри |
|------------|-----------|
| `Views/MenuBar/` | Попап в menu bar (`MenuBarView`, `PopoverRootView`) |
| `Views/Windows/` | Главное окно (Dashboard, History, Insights, Dictionary, Settings) |
| `Views/Components/` | Переиспользуемое (ActivityChart, RecordingOverlay, PillVariants) |

## Changelog
- [2026-04-16] Initial module map
