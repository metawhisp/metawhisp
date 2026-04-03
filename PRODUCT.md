# MetaWhisp — Product Overview

## What is MetaWhisp?
macOS menu bar app for voice-to-text. Press a key, speak, text appears at your cursor. Works in any app.

## Core Features

### Transcription
- **On-device** (WhisperKit large-v3-turbo) — free, private, no internet, Apple Silicon
- **Cloud** (Groq Whisper) — faster, more accurate, requires Pro subscription
- **30+ languages** with auto-detection
- **Global hotkey**: Right ⌘ (tap to start/stop)

### Translation
- **Voice translate**: Right ⌥ tap — speak in any language, get text in target language
- **Text translate**: Right ⌥ hold (1.5s) — translates selected text
- 11 supported languages: EN, RU, ES, FR, DE, ZH, JA, KO, PT, IT, UK

### Text Processing Modes
- **Raw** — verbatim transcription (free, on-device)
- **Clean** — removes fillers, fixes grammar (uses LLM)
- **Structured** — reformats dictation as clean written text, never executes commands

### Smart Features
- **Auto-paste** — text inserted at cursor automatically via Cmd+V
- **Correction Dictionary** — auto-learns word corrections from user edits
  - Tab: Corrections (auto-learned + manual)
  - Tab: Brands (40+ built-in: Google, LinkedIn, ChatGPT... + custom)
  - Tab: Snippets (text expansion: "my email" → actual email, "meeting link" → URL)
- **Floating recording overlay** — 4 pill styles (Capsule, Island Aura, Island Expand, Edge Glow)
- **Custom sounds** — upload your own start/stop recording sounds

### Dashboard & Statistics
- **Metrics**: Words, Transcriptions, Translations, WPM, Saved Time, Recorded Audio
- **Chart**: Independent from period filter, DAYS/WEEKS/MONTHS grouping
- **Records**: Streak, Best Day, Popular Time, Longest Recording, Peak Words
- **Periods**: All Time, Today, This Week, Monthly
- **Saved Time formula**: `(words / 30 WPM × 60s) - (audio + processing)` — time saved vs typing

### Account & Subscription
- **Auth**: Google Sign-In + Magic Link (email)
- **Plans**: Monthly ($7.77/mo) and Annual ($30/yr, save 68%)
- **Minutes**: 60 min/day accrued, accumulate up to 600 max balance
- **License**: Activated via deep link `metawhisp://auth?token=...`
- **Subscription info** shown in app Settings (renewal date, plan)

### Onboarding
- 5-screen animated flow on first launch
- Screens: Welcome → Transcribe demo → Translate demo → Choose Engine → Ready
- Typewriter effects, animated pill, staggered reveals, checkmark draw animation

## Tech Stack

### App
- **Language**: Swift 6, SwiftUI
- **Audio**: AVFoundation, AudioToolbox
- **ML**: WhisperKit (on-device Whisper)
- **Hotkeys**: Raw NSEvent flag monitoring (Right ⌘, Right ⌥)
- **Text insertion**: Accessibility API (AXUIElement) + Cmd+V
- **Data**: SwiftData (local history)
- **Distribution**: Direct .dmg download (no App Store yet)

### API
- **Runtime**: Cloudflare Workers
- **Database**: Cloudflare D1 (SQLite)
- **Payments**: Stripe (Express Checkout Element + Payment Element)
- **Email**: Resend (magic links)
- **AI**: Cerebras (Qwen-3, text processing), Groq (Whisper, cloud transcription)

### Website
- **Generator**: Eleventy (11ty)
- **Hosting**: Cloudflare Pages
- **Domain**: metawhisp.com
- **Analytics**: Google Analytics (G-20LL3E97VX)
- **SEO**: Organization + WebSite + SoftwareApplication + BreadcrumbList schemas

## What's NOT Done Yet
- [ ] Blog content strategy (SEO articles)
- [ ] Video demo on landing page
- [ ] Comparison pages (vs Whisper Transcription, vs macOS Dictation)
- [ ] Referral / trial system
- [ ] Crash reporting (TelemetryDeck / Sentry)
- [ ] CI/CD pipeline

## Links
- Website: https://metawhisp.com
- API: https://api.metawhisp.com
- Twitter: https://x.com/hypersonq
- Staging: https://staging.metawhisp.pages.dev
