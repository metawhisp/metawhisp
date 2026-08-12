# ITER-061 — Dead-mic observability

**Status:** implemented, full suite green (789 tests, 0 failures, 4 skipped). Not yet released.
**Date:** 2026-08-12

## The incident

The founder's mic stopped producing audio at ~18:23. Between 18:53 and 19:42, **eight
dictations and one meeting were recorded into nothing and silently discarded.** The app's
entire reaction was one log line per attempt:

```
[Coordinator] Recording stopped, 209600 samples, translate=NO
[Coordinator] Audio too quiet (RMS=0.00000), skipping transcription
```

RMS was bit-exact `0.00000` every time — 758 400 samples in the meeting's case. Not a quiet
room: no signal at all.

## Root cause: NOT in this app

Established by measurement, in this order:

| Check | Result |
| --- | --- |
| Default input device | MacBook Pro Microphone — correct |
| Input volume / mute (CoreAudio, per channel) | 1.0 / not muted |
| Exclusive capture (`kAudioDevicePropertyHogMode`) | free (`pid = -1`) |
| App restart (fresh process, fresh engine) | still bit-exact zero |
| `sudo killall coreaudiod` | **fixed it** — dictation immediately returned 633 chars |

The fault was in macOS's audio subsystem. A parallel 4-layer code investigation (16 agents,
adversarial verification) produced **12 candidate root causes inside the app and refuted all
12** — engine caching, converter downmix, device latching, the config-change observer. Each
died on the same evidence: a fresh process with a fresh engine and a fresh converter still
got zeros.

**Do not re-litigate those twelve.** The signature of this class of failure is
`RMS == 0` exactly, surviving an app restart, cleared by restarting `coreaudiod`.

## What WAS our bug

Not the silence — the blindness to it. Three separate layers could not tell a dead input
from a quiet room:

1. `TranscriptionCoordinator` compares RMS against `0.0003` and discards below it, setting
   no user-visible error at all.
2. Every meeting silence guard reads `max(mic, system)`, so a call playing through the
   system channel completely masks a dead mic.
3. `emptyTranscriptReason` classifies on sample **count**; 758 400 zero samples read as
   "captured".

Worse, the meeting never even reached that reporter: the other side arrived fine through
the system channel, so a **Them:-only transcript saved as if complete.**

And nothing anywhere logged which device was bound, at what sample rate, with how many
channels, or in what layout — which is why every hypothesis above died unprovable.

## Changes

- `Services/Audio/DeadMicDetector.swift` (new) — pure watchdog. `rms == 0` is exact:
  RMS is zero iff every sample is zero. Trips once after 1 s of digital silence, latches,
  re-arms on `reset()`.
- `Services/Audio/AudioRecordingService.swift`
  - `micHealthError` published; `deadMicMessage` names the remedy that worked in the field.
  - Logs the bind on **every** `start()`: device name + UID + id, sample rate, channel count,
    channel layout tag. This is the measurement whose absence cost a day.
  - Tap restructured: meters and the watchdog now run on the raw buffer whether or not
    conversion succeeded, and the converter's `NSError` is finally read and logged.
  - A recording that caught digital silence marks the engine suspect; `stop()` drops it so
    the next `start()` rebinds. Rebuild happens **between** recordings, never mid-tap —
    see the DEADLOCK RULES on `observeDeviceChanges`.
- `Services/Audio/AudioInputDevice.swift` — `boundInputDescription(for:)`, reads
  `kAudioOutputUnitProperty_CurrentDevice` back off the engine's input unit.
- `Services/Audio/MeetingRecorder.swift` — `isDigitalSilence(_:)` (judged on the RAW buffer,
  before `applyPauseMutes` writes its by-design zeros), published `micChannelWasSilent`,
  and a new `EmptyTranscriptReason.micDeliveredSilence`.
- `Services/System/TranscriptionCoordinator.swift` — digital silence is split out of the
  "too quiet" branch and now sets `lastError`.
- `App/AppDelegate.swift` — warns when a meeting saved successfully but **without your side**.

## Checklist

- [x] Failing tests first (`DeadMicDetectorTests`, 14 cases incl. corner cases)
- [x] `DeadMicDetector` implementation
- [x] Bind instrumentation on every `start()`
- [x] Tap restructure — meters + watchdog independent of conversion success
- [x] Converter `NSError` read and logged
- [x] Suspect engine dropped at `stop()`, off-main release
- [x] Coordinator splits digital silence from quiet, sets `lastError`
- [x] Meeting per-channel verdict + `micDeliveredSilence` + non-empty warning
- [x] `MeetingMicSilenceTests` (10 cases)
- [x] `swiftc -parse` clean on all 7 touched files
- [x] `swift test` green — 24 new cases pass, full suite 789 tests / 0 failures / 4 skipped
- [ ] Release + Sparkle

## Corner cases pinned by tests

Quiet room noise floor never trips; denormal-but-non-zero never trips; NaN never trips;
negative RMS never trips; zero-frame buffers carry no time; non-positive sample rate never
trips; the window is wall-clock so 48 kHz needs 3× the buffers of 16 kHz; the detector
latches after tripping and only re-arms on `reset()`; a mic dying mid-recording is caught;
pause-muted dictation windows cannot fake a dead-mic verdict.

## Deliberately NOT done

- **Mid-recording engine rebuild.** It was in the approved option text. Left out because
  (a) the evidence says it would not have helped — a fresh process didn't — and (b) tearing
  an engine down from the audio path is the exact shape that froze the app on 2026-07-22.
  Rebuild happens between recordings instead.
- **`object: nil` on the config-change observer** (`AudioRecordingService.swift:116`).
  Confirmed real: one service instance's engine event tears down the other's, which is why
  the log shows four resets on two threads. Not this incident's cause. Awaiting a decision.
- **`SystemAudioCaptureService.stop()` never calls `stopCapture()`** — every meeting leaks a
  live `SCStream`. Confirmed by reading; unrelated to the mic. Awaiting a decision.
