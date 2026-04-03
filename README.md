# MetaWhisp

**On-device voice-to-text for macOS. Press a key, speak, text appears at your cursor.**

MetaWhisp is a native macOS menu bar app that transcribes speech locally on Apple Silicon using [WhisperKit](https://github.com/argmaxinc/WhisperKit) (OpenAI's Whisper). No cloud, no latency, no data leaves your Mac.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2B-black) ![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-blue)

## How It Works

1. Press **Right Command** from any app
2. Speak
3. Press **Right Command** again
4. Text is automatically pasted at your cursor

That's it. Works in any text field — editors, browsers, terminals, messengers.

## Features

**Transcription**
- 100% on-device via Metal GPU — no internet required
- 5 Whisper models: Tiny (40 MB) to Large V3 Turbo (950 MB)
- 30+ languages with auto-detection
- Hallucination filtering (YouTube artifacts, silence patterns, multi-script gibberish)

**Text Processing**
- **Raw** — verbatim transcription
- **Clean** — removes filler words locally (no API)
- **Structured** — AI-powered cleanup with grammar fixes and formatting

**Translation**
- Right Option tap — record and translate
- Right Option hold (1.5s) — translate selected text in any app
- 11 languages: EN, RU, ES, FR, DE, ZH, JA, KO, PT, IT, UK

**Smart Dictionary**
- Auto-learns corrections from your edits
- Built-in brand recognition (40+ brands)
- Text snippets (e.g., "my email" expands to your actual email)
- Fuzzy matching with case preservation

**Dashboard & Analytics**
- Words, transcriptions, translations, WPM, time saved
- Activity charts by day/week/month
- Records: streak, best day, longest recording

**System Integration**
- Lives in menu bar — zero UI intrusion
- Floating recording pill overlay (4 styles)
- Custom sound presets (Default, Bass, Signature)
- Push-to-Talk or Toggle mode
- Auto-updates via Sparkle

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1, M2, M3, M4)
- ~50 MB app + 40–950 MB for the Whisper model

## Building from Source

```bash
# Clone
git clone https://github.com/MetaWhisp/MetaWhisp.git
cd MetaWhisp

# Build (release mode for ML performance)
swift build -c release

# Create app bundle
bash build.sh

# App is installed to ~/Applications/MetaWhisp.app
```

### Dependencies

Resolved automatically via Swift Package Manager:

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device speech recognition
- [Sparkle](https://github.com/sparkle-project/Sparkle) — auto-updates

## Project Structure

```
App/                    # App entry point, AppDelegate, menu bar
Models/                 # Data models (settings, history, transcription result)
Services/
  Audio/                # Microphone recording (AVAudioEngine, 16kHz PCM)
  Cloud/                # LLM client (OpenAI/Cerebras compatible)
  Data/                 # History persistence (SwiftData)
  License/              # Pro subscription management
  Processing/           # Text processing, corrections, filler removal
  System/               # Hotkeys, text insertion, sounds, coordinator
  Transcription/        # WhisperKit engine, cloud engine, model manager
Views/
  Components/           # Charts, recording overlay, reusable UI
  MenuBar/              # Status bar popover
  Windows/              # Main window, settings, history, dashboard, onboarding
Helpers/                # Design system, notch detection, text analyzer
Resources/              # App icon, sounds, Info.plist, entitlements
```

## Architecture

```
Hotkey → TranscriptionCoordinator → WhisperKit (on-device)
              ↓                     or CloudWhisper (Pro)
         TextProcessor → CorrectionDictionary → TextInsertionService
              ↓                                       ↓
         LLM (clean/structure/translate)          Cmd+V auto-paste
```

The app records audio at 16kHz mono PCM, transcribes via WhisperKit using Metal GPU acceleration, optionally processes the text (filler removal, AI cleanup, translation), applies learned corrections, and pastes the result via simulated Cmd+V.

## Configuration

On first launch, MetaWhisp downloads the selected Whisper model (~40–950 MB) to `~/Library/Application Support/MetaWhisp/Models/`.

**Free features** (no API key needed):
- On-device transcription (all models)
- Raw and Clean processing modes
- Full history and analytics
- Correction dictionary
- All hotkeys and auto-paste

**Features requiring API key** (set in Settings):
- Structured mode (OpenAI or Cerebras)
- Translation

## License

MIT

## Links

- Website: [metawhisp.com](https://metawhisp.com)
- Download: [metawhisp.com/downloads/MetaWhisp.dmg](https://metawhisp.com/downloads/MetaWhisp.dmg)
- Twitter: [@hypersonq](https://x.com/hypersonq)
