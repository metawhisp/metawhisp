# MetaWhisp — Brief for Landing Page & Promo Video

## What It Is

MetaWhisp is a native macOS app for instant voice transcription. Runs entirely on-device on Apple Silicon via Metal GPU (OpenAI's Whisper model). Lives in the menu bar, controlled by global hotkeys — press a key, speak, text appears in any app.

**Domain**: metawhisp.com
**Platform**: macOS 14+ (Apple Silicon)
**Pricing**: Freemium (free on-device, Pro for cloud features)

---

## Key Features (for Landing Page)

### 1. Instant Transcription — 100% On-Device
- Press Right ⌘ — speak — text auto-inserts into the current app
- Everything runs on-device via Metal GPU, no data leaves your Mac
- 5 Whisper models: Tiny (40 MB, fastest) to Large V3 Turbo (950 MB, most accurate)
- 11 languages: English, Russian, Spanish, French, German, Chinese, Japanese, Korean, Portuguese, Italian, Ukrainian

### 2. Smart Text Processing — 3 Modes
- **Raw**: verbatim transcription, no changes
- **Clean**: auto-removes filler words ("um", "like", "you know", "basically", etc.)
- **Structured**: AI-powered cleanup via LLM — removes fillers, fixes grammar, structures into clean sentences

### 3. Instant Translation
- **Quick tap Right ⌥**: record voice + translate immediately
- **Long press Right ⌥ (2 sec)**: translate selected text in any app
- Auto-detects direction: Cyrillic → English, Latin → Russian
- Powered by OpenAI GPT-4o-mini / Cerebras

### 4. Self-Learning Correction Dictionary
- Watches if you edit text after it's pasted
- Remembers corrections (especially proper nouns, brands, technical terms)
- Auto-applies learned corrections next time
- Manual dictionary management via UI

### 5. Detailed Analytics
- Dashboard with metrics: transcription count, total words, audio time, time saved
- Activity charts: by hour (today), by day (week/month), by month (all time)
- Filler word analysis: top 10 with frequency
- Most used words (bar chart)
- Records: longest transcription, fastest processing
- Trends: comparison with previous period (% change)

### 6. Menu Bar Integration
- Menu bar icon changes based on state (wave → recording → processing)
- Popover with quick access: status, last transcription, record button
- Floating pill overlay shows state on top of all windows
- Customizable sound feedback

---

## Controls (Hotkeys)

| Action | Key | Description |
|--------|-----|-------------|
| Record/Stop | Right ⌘ | Start/stop recording from any app |
| Record + Translate | Right ⌥ (tap) | Record and translate immediately |
| Translate Selection | Right ⌥ (hold 2s) | Translate selected text |

---

## Visual Style

### Colors
- **Primary accent**: orange (buttons, charts, badges)
- **States**: green (idle), red (recording), orange (processing), blue (post-processing/translation)
- **Background**: dark with glass morphism (native macOS translucent materials)

### UI Elements
- Capsule buttons with rounded corners
- ChatGPT-style shimmer animation during AI processing
- Pulsing animation while recording
- Vibrancy + blur background (native macOS material)
- SF Symbols icons throughout

### Recording Overlay
- Small floating pill on top of all windows
- Shows: colored status dot + text ("Recording", "Transcribing", "Done")
- Real-time audio level bar
- Auto-hides 0.8s after completion

---

## App Windows

### Main Window (700x500)
Sidebar navigation with 4 tabs:
1. **Dashboard**: recording status card + full statistics panel with charts
2. **History**: list of all transcriptions with search, copy, delete
3. **Dictionary**: learned corrections dictionary with management
4. **Settings**: model, language, processing mode, API key, sounds

### Menu Bar Popover (300x300)
- Colored status indicator
- Audio level during recording
- Last transcription preview
- Translation mode toggle
- Record/Stop button

---

## Technical Specs (for "Under the Hood" section)

- **Engine**: WhisperKit 0.9.0 (Apple Silicon optimized)
- **GPU**: Metal acceleration for ML inference
- **Audio**: 16 kHz, mono, PCM float32
- **Storage**: SwiftData (SQLite) — all local
- **API**: OpenAI GPT-4o-mini (only for Structured mode and translation)
- **Size**: ~50 MB app + 40-950 MB per model
- **RAM**: ~1-2 GB at rest
- **Code signing**: Hardened runtime with entitlements

---

## Target Audience

1. **Content creators**: writers, bloggers, developers — quickly dictate thoughts
2. **Remote workers**: notes during calls and meetings
3. **Polyglots**: built-in translation between languages
4. **Privacy-conscious users**: no cloud for transcription
5. **Productivity enthusiasts**: analytics show how much time you've saved

---

## Competitive Advantages

| MetaWhisp | Competitors (Otter, Whisper Transcription, etc.) |
|-----------|--------------------------------------------------|
| 100% on-device | Cloud-based, latency, privacy risks |
| Global hotkeys | Must switch to the app |
| Auto-paste into any app | Manual copy-paste |
| Self-learning dictionary | Static dictionaries or none |
| 3 processing modes | Usually one mode |
| Built-in analytics | No analytics |
| Instant selection translation | Separate translation apps |
| Native macOS (Metal GPU) | Electron/Web wrappers |

---

## Promo Video: Usage Scenarios

### Scenario 1: "Quick Thought"
Developer writing code → presses Right ⌘ → dictates a comment → text auto-inserts into the editor → continues coding. All in 3 seconds.

### Scenario 2: "Meeting Notes"
Person on a Zoom call → presses Right ⌘ → records key points → text inserts into Notion/notes. Nobody sees they're recording.

### Scenario 3: "On-the-Fly Translation"
Reading an article in English → selects a paragraph → holds Right ⌥ for 2 seconds → paragraph is replaced with translation right in the text field.

### Scenario 4: "Long Dictation"
Enables Structured mode → dictates 5 minutes of stream-of-consciousness → gets clean, structured text with zero filler words.

### Scenario 5: "Analytics"
Opens Dashboard → sees: "This week: 47 transcriptions, 12,000 words, 2 hours saved" → chart shows peak activity on Tuesdays.

---

## Communication Tone

- **Confident** but not aggressive
- **Technically literate** — audience knows what Metal GPU and Whisper are
- **Minimalist** — the app is about speed and simplicity, communication matches
- **Slightly bold** — "Your voice, instantly typed. No cloud. No BS."

---

## Landing Page Structure

### Hero Section
- Headline: "Your voice, instantly typed." (or variation)
- Subheadline: "On-device speech-to-text for macOS. Private. Fast. Intelligent."
- CTA: "Download Free" → DMG
- Visual: screenshot/animation of overlay on top of IDE or messenger

### Features Section
- 6 cards with icons (from key features above)
- Each with short description and illustration/animation

### How It Works
- 3 steps: Install → Press Right ⌘ → Speak → Text appears
- Animated demonstration

### Models / Privacy
- Model comparison table (Tiny → Large V3 Turbo) with sizes and descriptions
- Emphasis on "all local, zero cloud dependency"

### Analytics Preview
- Dashboard screenshot with charts
- "Track your productivity, not your data"

### Download
- DMG button
- System requirements: macOS 14+, Apple Silicon
- Size: ~50 MB (+ models)

### Footer
- Links: GitHub, Twitter, Email
- "Made with Metal GPU"

---

## What NOT to Include on Site/Video

- Do not mention "TranscribeAI" (old name)
- Do not show specific OpenAI API keys
- Do not show file paths like ~/Library/
- Do not go deep into SwiftData/SQLite — internal implementation
- Do not promise Windows/Linux versions
- Do not promise specific feature dates
