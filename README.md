# MetaWhisp

**Open-source voice-to-text for macOS. Press a key, speak, text appears at your cursor.**

MetaWhisp is a free, open-source native macOS menu bar app. It transcribes speech on your Mac with OpenAI's Whisper through [WhisperKit](https://github.com/argmaxinc/WhisperKit) and pastes the text into the app you're typing in. With on-device transcription and the local AI model, nothing leaves your Mac. Cloud features are optional; [Privacy](#privacy) lists what each one sends and where.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2B-black) ![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-blue)

## How It Works

1. Press **Right Command** from any app
2. Speak
3. Press **Right Command** again
4. Text is automatically pasted at your cursor

That's it. Works in any app that accepts paste: editors, browsers, terminals, messengers. Prefer holding the key while you talk? Switch to push-to-talk in Settings.

## Features

**Transcription**
- Whisper large-v3 on your Mac's GPU and CPU, in WhisperKit's turbo build (about 3.2 GB, downloaded once). The Base model (about 150 MB) installs first, so you can dictate while the big one downloads.
- Tiny, Base and Small are there if you want a lighter model
- 100 languages with auto-detection (99 on the smaller models), or pin one of 11 in Settings
- Hallucination filtering (YouTube artifacts, silence patterns, text mixing three or more scripts); flagged text goes to the clipboard instead of being pasted

**Text Processing**
- **Raw** — verbatim transcription (the default; a Pro subscription switches it to Structured once)
- **Clean** — removes Russian filler words, offline
- **Structured** — AI-powered cleanup with grammar fixes and formatting
- The AI runs on an optional local model (Phi-4 Mini, or Apple Foundation Models on macOS 26 with Apple Intelligence on), on your own OpenAI or Cerebras key, or on Pro

**Translation**
- Right Option tap — record and translate
- Right Option hold (1.5s) — translate selected text in any app
- 11 languages: EN, RU, ES, FR, DE, ZH, JA, KO, PT, IT, UK, plus a Gen Z slang rewrite
- Uses the same AI as Structured mode

**Meetings and Calls** (off by default)
- Records your microphone and the Mac's sound on the Mac, labelled **Me** and **Them**
- With Auto-detect calls and Auto-start turned on, spots Zoom, Teams, Meet and other calls and starts recording by itself
- A recap after the call (decisions, action items, next steps) when an AI is set up
- With your own Deepgram or Gemini key, everyone on the call gets their own name in the transcript

**MetaChat and Memory**
- Ask about what you said: dictations, meetings, tasks and memories (needs an AI)
- In toggle mode (the default), hold **Right Command** to ask out loud; answers are read aloud (natural voices with Pro)
- Tasks from promises in your conversations, memories (off by default) and goals you set
- Pro adds a daily summary, weekly patterns (off by default) and search by meaning

**Screen Context** (off by default)
- Reads text from the window in front, in every app except the ones you exclude (or only the apps you list), so MetaChat can answer about it
- The Apple Passwords, Keychain Access, 1Password and Bitwarden apps are never read

**Keyboard Layout Fix**
- Fixes a word typed in the wrong layout (English ↔ Russian); on by default, needs the Accessibility permission

**Smart Dictionary**
- Learns a correction once you make the same edit twice
- Built-in brand recognition (44 brands)
- Text snippets (e.g., "my email" expands to your actual email)
- Fuzzy matching with case preservation

**Dashboard & Analytics**
- Words, transcriptions, translations, WPM, time saved
- Activity charts by day/week/month
- Records: streak, best day, longest recording

**System Integration**
- Lives in the menu bar; a Dock icon shows only while the main window is open
- Floating recording pill overlay (5 styles)
- Sound presets (Default, Bass, Signature) or your own sounds
- Toggle (the default) or Push-to-Talk mode
- An MCP server (metawhisp-mcp, built from source, not in the DMG; turn on MCP Server in Settings) lets Claude Desktop, Cursor and other MCP clients search your memories, tasks and conversations
- Obsidian export; indexing of Apple Notes, Calendar and folders you pick
- Auto-updates via Sparkle

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1 or later)
- About 60 MB for the app, plus about 3.2 GB for the default model (the smallest model is under 100 MB)

## Building from Source

```bash
# Clone
git clone https://github.com/MetaWhisp/MetaWhisp.git
cd MetaWhisp

# Build (release mode for ML performance)
swift build -c release

# Create the signed app bundle (needs a Developer ID certificate)
bash build.sh

# The bundle is at .build/arm64-apple-macosx/release/MetaWhisp.app
# To install a build over /Applications/MetaWhisp.app, keeping the replaced one for --rollback: bash hot-swap.sh
```

### Dependencies

Resolved automatically via Swift Package Manager:

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device speech recognition
- [Sparkle](https://github.com/sparkle-project/Sparkle) — auto-updates

## Project Structure

```
App/                    # App entry point, AppDelegate, menu bar
Models/                 # Data models (settings, history, conversations, tasks, memories, goals)
Services/
  Audio/                # Microphone and system audio capture (16kHz PCM)
  Cloud/                # LLM client (OpenAI/Cerebras compatible)
  Data/                 # Persistence (SwiftData)
  Export/               # Obsidian export
  Indexing/             # Apple Notes, Calendar and folder indexing
  Intelligence/         # MetaChat, tasks, memories, summaries, meeting recaps
  License/              # Pro subscription management
  LLM/                  # Local models (MLX, Apple Foundation Models)
  MCP/                  # Data snapshot for the MCP server
  Processing/           # Text processing, corrections, filler removal
  Screen/               # Screen context
  System/               # Hotkeys, text insertion, sounds, coordinator
  TTS/                  # Read-aloud
  Transcription/        # WhisperKit engine, cloud engine, model manager
  UI/                   # Shared UI state
Sources/MetaWhispMCP/   # The MCP server binary
Views/
  Components/           # Charts, recording overlay, reusable UI
  FloatingVoice/        # Voice-question overlay
  MeetingCoach/         # Live meeting coach
  MeetingRecap/         # Post-meeting recap
  MenuBar/              # Status bar popover
  Notifications/        # In-app notification cards
  Windows/              # Main window, settings, history, dashboard, onboarding
Helpers/                # Design system, notch detection, text analyzer
Resources/              # App icon, sounds, Info.plist, entitlements
Tests/                  # Unit tests
```

## Architecture

```
Hotkey → TranscriptionCoordinator → WhisperKit (on-device, the default)
              ↓                     or cloud: Pro, or your own Groq/OpenAI key
         TextProcessor (Raw / Clean / Structured / translation)
              ↓                     AI: local model, your OpenAI/Cerebras key, or Pro
         Brand glossary → CorrectionDictionary → History → TextInsertionService → Cmd+V auto-paste
                                                    ↓
                                   Intelligence (tasks, memories, recaps, summaries) → MetaChat
```

The app records audio at 16kHz mono PCM, transcribes it with WhisperKit on the GPU, optionally processes the text (offline filler removal, AI cleanup, translation), applies the brand glossary and your learned corrections, saves it to history, and pastes the result via simulated Cmd+V.

## Configuration

During setup MetaWhisp downloads the Base model, then the default one (about 3.2 GB). A new install keeps them in `~/Library/Application Support/MetaWhisp/huggingface/models/argmaxinc/whisperkit-coreml/`; an install from before 1.4 keeps using `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`.

**Free** (no account needed):
- Unlimited on-device transcription, all models
- Raw and Clean modes, history, dashboard, dictionary, auto-paste
- Structured mode, translation and MetaChat with the local model or your own OpenAI or Cerebras key
- Meeting recording on your Mac
- Cloud transcription with your own Groq or OpenAI key

**Pro** ($7.77/month or $30/year):
- Cloud transcription (Whisper large-v3-turbo on Groq): 5,400 minutes a month; after that, meetings stop and short dictations keep working
- Built-in cloud AI, no keys needed
- Daily summary, weekly patterns, search by meaning, natural voices

## Privacy

With on-device transcription and the local AI model, nothing leaves your Mac: not your audio, not your text. Data goes out only through something you add:
- **Pro:** audio goes to MetaWhisp's server, which passes it to Groq. Text for the built-in AI goes there too: titles and recaps of your dictations and meetings, tasks, the daily summary, search by meaning, and any AI feature you use. Pro switches transcription to the cloud once, the first time it is turned on on a Mac; if you pick on-device afterwards, it stays. While you're signed in, it checks your license at launch and every 12 hours, sending your Mac's hardware ID, and reports the length of each meeting transcribed through Pro.
- **Your own Groq or OpenAI key, with Cloud transcription on:** audio goes to that provider.
- **Your own OpenAI or Cerebras key:** text goes to that provider for Structured mode, translation, MetaChat, titles and recaps, and tasks (on by default), plus any AI feature you turn on. An OpenAI key added for transcription is used here too, unless Cerebras is your AI provider.
- **Your own Deepgram or Gemini key:** meeting audio goes to that provider, even with on-device transcription.
- **Screen Context with a cloud AI:** screen text goes to that provider.
- **MCP server (off by default):** the app you connect, such as Claude Desktop, gets the memories, tasks and conversation summaries it asks for.

Two kinds of request carry none of your audio or text: automatic update checks (Sparkle, via metawhisp.com and GitHub) and Hugging Face, for model files. The app has no analytics or crash-reporting SDK.

## License

MIT

## Links

- Website: [metawhisp.com](https://metawhisp.com)
- Download: [metawhisp.com/downloads/MetaWhisp.dmg](https://metawhisp.com/downloads/MetaWhisp.dmg)
- Privacy policy: [metawhisp.com/privacy](https://metawhisp.com/privacy/)
- Twitter: [@hypersonq](https://x.com/hypersonq)
