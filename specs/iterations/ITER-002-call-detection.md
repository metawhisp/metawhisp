# ITER-002 — Call Auto-Detection

**Цель:** Автоматически детектить созвон (Zoom/Teams/Meet/FaceTime/…) → показать нотификейшн → опционально начать запись.

**Принцип (Karpathy):** хук в уже работающий `ScreenContextService.captureIfChanged` (user держит screen context всегда on), не добавляем отдельный polling loop.

## Flow

1. `ScreenContextService` на каждом capture (смена окна) вычисляет `callContext: String?` из `(frontApp.bundleId, windowTitle)` — уже читает это для OCR.
2. Call detected = native call app (Zoom/Teams/FaceTime/Slack/Discord/Webex) ИЛИ browser app (Chrome/Safari/Arc/Firefox/Edge/Brave/Opera) + title содержит keyword ("Google Meet", "meet.google.com", "Teams - Microsoft").
3. Callback `onCallContext(name)` фаерит на **state change**: `nil → name` (call started) и `name → nil` (call ended).
4. `AppDelegate` подписывается, дебаунс уже embedded в state-change logic → сразу нотификейшн + optional auto-start.

## Settings (2 toggles под MEETING RECORDING)

- `autoDetectCalls` (existing dead toggle → wire): показать notification когда созвон задетектен.
- `callsAutoStartEnabled` (NEW): запись стартует автоматически через 5 сек после детекции. Зависит от `autoDetectCalls = ON`.

## UX matrix

| meetingRecordingEnabled | autoDetectCalls | callsAutoStartEnabled | поведение |
|---|---|---|---|
| OFF | * | * | нет детекции |
| ON  | OFF | * | только manual button |
| ON  | ON  | OFF | нотификейшн "Zoom detected — click to record" |
| ON  | ON  | ON | нотификейшн "Zoom detected. Recording in 5s…" → через 5s старт записи |

Auto-stop: при переходе `call → nil` (окно сменилось, созвон закрыт) если мы стартанули через auto-detect — вызываем `stopMeetingRecording`. Если пользователь стартанул вручную — не трогаем.

Skip если уже идёт запись (`meetingRecorder.isRecording || recorder.isRecording`).

## Файлы

- `Models/AppSettings.swift` — `@AppStorage("callsAutoStartEnabled")`.
- `Services/Audio/SystemAudioCaptureService.swift` — `detectCallContext(frontApp:windowTitle:)` (расширение existing `detectActiveMeetingApp`, добавляет browser keyword lookup).
- `Services/Screen/ScreenContextService.swift` — `var onCallContext: ((String?) -> Void)?`, вызов в `captureIfChanged` на state change.
- `App/AppDelegate.swift` — `handleCallDetected/handleCallEnded` + notification + 5s Task sleep → `meetingRecorder.start()`.
- `Views/Windows/MainSettingsView.swift` — replace "AUTO-DETECT CALLS" на two-toggle stack.

## Verification

1. Открыть Google Meet в Chrome → в течение 30s (screen context interval) → notification появляется.
2. AUTO-START = ON → через 5s после notification меня бар показывает "recording".
3. Закрыть вкладку Meet → через ~30s recording останавливается сам, транскрипт в History.
4. AUTO-START = OFF → notification только информативный, manual кнопка работает.
5. Если ручная запись идёт — детекция **не** триггерит вторую.
