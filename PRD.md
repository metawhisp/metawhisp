# MetaWhisp PRD (Product Requirements Document)

## Context

MetaWhisp is a native macOS menu bar app for on-device voice transcription. The user presses a global hotkey, speaks, and text is automatically inserted into any application. The core runs locally on Apple Silicon via Metal GPU (WhisperKit/Whisper). Monetization model: freemium (Free: on-device, Pro: cloud transcription + LLM processing).

The project consists of 3 components: **macOS App** (Swift 6/SwiftUI), **API** (Cloudflare Workers + D1), **Website** (Eleventy/11ty + Cloudflare Pages).

**Status**: LAUNCHED. Has paying users, Stripe live, app notarized, Sparkle updates working.

---

## 1. Product

### 1.1 Vision
The fastest and most private way to turn voice into text on macOS. Press a key — speak — text appears.

### 1.2 Target Audience
| Segment | Need |
|---------|------|
| Content creators (writers, bloggers, devs) | Quickly dictate thoughts without context switching |
| Remote workers | Notes during calls and meetings |
| Polyglots | Built-in translation between languages |
| Privacy-conscious | No cloud for basic transcription |
| Productivity enthusiasts | Analytics showing time saved |

### 1.3 Platform & Requirements
- macOS 14+ (Sonoma)
- Apple Silicon (M1+)
- ~50 MB app + 40-950 MB model
- Distribution: .dmg (direct download) + notarization

---

## 2. Functional Requirements

### 2.1 Transcription ✅
| Requirement | Status | Details |
|-------------|--------|---------|
| On-device transcription (WhisperKit) | ✅ | 5 models: Tiny→Large V3 Turbo, Metal GPU |
| Cloud transcription (Groq/OpenAI) | ✅ | Pro-only, server proxy |
| 30+ languages with auto-detection | ✅ | 11 primary languages in UI |
| Hallucination filtering | ✅ | Toxic tokens, YouTube patterns, dedup, silence |
| Silence detection (skip empty recordings) | ✅ | RMS < 0.0003 → discard |
| Audio engine pre-warming | ✅ | Eliminates ~150ms cold start |

### 2.2 Global Hotkeys ✅
| Requirement | Status | Details |
|-------------|--------|---------|
| Right ⌘ — record/stop | ✅ | Toggle + Push-to-Talk modes |
| Right ⌥ (tap) — record + translate | ✅ | < 0.4s = translate mode |
| Right ⌥ (hold 1.5s) — translate selection | ✅ | Accessibility API |
| Rapid press debounce | ✅ | 30ms cooldown |

### 2.3 Text Processing ✅
| Requirement | Status | Details |
|-------------|--------|---------|
| Raw mode (verbatim) | ✅ | No processing |
| Clean mode (remove fillers) | ✅ | Local regex, no API |
| Structured mode (LLM polish) | ✅ | GPT-4o-mini / Cerebras Qwen-3 |
| Auto-paste text (Cmd+V) | ✅ | Accessibility API + CGEvent |
| Text style (Pro): lowercase, no period, no caps | ✅ | Settings configurable |

### 2.4 Translation ✅
| Requirement | Status | Details |
|-------------|--------|---------|
| Voice translation | ✅ | Record → transcribe → translate |
| Selected text translation | ✅ | SelectionTranslator |
| Auto-detect direction | ✅ | Cyrillic ↔ Latin |
| 11 target languages | ✅ | EN, RU, ES, FR, DE, ZH, JA, KO, PT, IT, UK |

### 2.5 Correction Dictionary ✅
| Requirement | Status | Details |
|-------------|--------|---------|
| Auto-learning from user edits | ✅ | CorrectionMonitor → CorrectionDictionary |
| Brands (34+ built-in) | ✅ | Google, LinkedIn, ChatGPT, etc. |
| Snippets (text templates) | ✅ | "my email" → actual email |
| Fuzzy matching (Levenshtein) | ✅ | Threshold 1-2 characters |
| Case preservation | ✅ | HELLO→WORLD, Hello→World |
| Prompt tokens for Whisper bias | ✅ | Dictionary hints |

### 2.6 Dashboard & Analytics ✅
| Requirement | Status | Details |
|-------------|--------|---------|
| Metrics: words, transcriptions, translations, WPM | ✅ | |
| Time saved | ✅ | (words/30WPM×60) - (audio+processing) |
| Activity charts (day/week/month) | ✅ | ActivityChartView |
| Records: streak, best day, peak words | ✅ | |
| Period filter | ✅ | All Time, Today, Week, Month |

### 2.7 UI & UX ✅
| Requirement | Status | Details |
|-------------|--------|---------|
| Menu bar icon + popover | ✅ | 300×300, status + last transcription |
| Main window (4 tabs) | ✅ | Dashboard, History, Dictionary, Settings |
| Recording overlay (4 styles) | ✅ | Capsule, Island Aura, Island Expand, Edge Glow |
| Onboarding (8 screens) | ✅ | Typewriter, animations, engine selection |
| Sound feedback | ✅ | Presets + custom sounds |
| Dark/Light/Auto theme | ✅ | DesignSystem.swift |

### 2.8 Account & Subscriptions ✅
| Requirement | Status | Details |
|-------------|--------|---------|
| Google Sign-In | ✅ | JWT validation |
| Magic Link (email) | ✅ | Resend, 20 min expiry |
| Stripe subscriptions (LIVE) | ✅ | Active payments, paying subscribers |
| Monthly $7.77 / Annual $30 | ✅ | Stripe price IDs |
| Minute limits (60/day, max 600) | ✅ | Server-side enforcement (HTTP 429) |
| Deep link activation | ✅ | metawhisp://auth?token=... |
| Keychain secret storage | ✅ | |

### 2.9 Backend API ✅
| Requirement | Status | Details |
|-------------|--------|---------|
| Auth endpoints (Google, Magic Link, Session) | ✅ | |
| Subscription CRUD | ✅ | |
| Stripe webhooks | ✅ | Signature verification |
| License verification | ✅ | machine_id binding |
| Usage tracking + enforcement | ✅ | Per-day minutes, 429 on exhaustion |
| Pro proxy (transcribe + process) | ✅ | Groq + Cerebras |
| CORS | ✅ | metawhisp.com only |

### 2.10 Website ✅
| Requirement | Status | Details |
|-------------|--------|---------|
| Landing page (hero, features, how-it-works) | ✅ | |
| Pricing page | ✅ | |
| Account page (login/dashboard) | ✅ | |
| Download page | ✅ | |
| Privacy & Terms | ✅ | |
| SEO schema markup | ✅ | Organization, SoftwareApplication |
| Security headers (CSP, HSTS) | ✅ | |
| robots.txt, llms.txt | ✅ | |

### 2.11 Infrastructure ✅
| Requirement | Status | Details |
|-------------|--------|---------|
| Notarization (Apple Developer) | ✅ | Signed and notarized |
| Sparkle auto-updates | ✅ | appcast.xml, Ed25519 signature |
| Code signing (hardened runtime) | ✅ | Entitlements for mic, network, JIT |

---

## 3. Growth Opportunities

### 3.1 High Priority (P1) — Next 1-2 Months

| # | Feature | Impact | Rationale |
|---|---------|--------|-----------|
| 1 | **Trial period** (7-day Pro) | Conversion | User tries Pro → sees value → subscribes |
| 2 | **Blog / SEO content** (5-10 articles) | Organic traffic | No inbound search traffic currently |
| 3 | **Video demo on landing page** | Landing conversion | Show product in action in 30 sec |
| 4 | **Crash reporting** (TelemetryDeck / Sentry) | Quality | Visibility into production user issues |
| 5 | **Product Hunt launch** | Awareness | Target audience is there |

### 3.2 Medium Priority (P2) — Month 2-4

| # | Feature | Impact |
|---|---------|--------|
| 6 | Comparison pages (vs Dictation, vs Otter, vs Whisper Transcription) | SEO + positioning |
| 7 | Referral program | Organic growth |
| 8 | CI/CD pipeline (GitHub Actions) | Build/release automation |
| 9 | Export history (CSV, Markdown) | Data portability |

### 3.3 Future (P3) — Month 4-6+

| # | Feature | Impact |
|---|---------|--------|
| 10 | iCloud history sync | Multi-device convenience |
| 11 | Shortcuts / Automations integration | Power users |
| 12 | Custom LLM endpoints (Ollama, local) | Privacy-oriented users |
| 13 | Streaming transcription (real-time) | UX improvement |
| 14 | App Store distribution | Broader audience |
| 15 | Website localization (EN/RU) | International market |
| 16 | Multiple recording profiles | Different contexts |

---

## 4. Non-Functional Requirements

### 4.1 Performance
| Metric | Target | Current |
|--------|--------|---------|
| Key press to recording ready | < 200ms | ✅ Pre-warm |
| Transcription of 10s audio (Large V3 Turbo) | < 3s | ✅ Metal GPU |
| App size (without models) | < 60 MB | ✅ ~50 MB |
| RAM at idle | < 100 MB | ⚠️ ~1-2 GB (WhisperKit loaded) |

### 4.2 Privacy & Security ✅
| Requirement | Status |
|-------------|--------|
| On-device transcription without network | ✅ |
| API keys in Keychain | ✅ |
| Hardened runtime + notarization | ✅ |
| HTTPS only | ✅ |
| Webhook signature verification | ✅ |
| CSP headers on website | ✅ |

### 4.3 Reliability
| Requirement | Status |
|-------------|--------|
| Graceful fallback (SwiftData → in-memory) | ✅ |
| File logging (~/Library/Logs/) | ✅ |
| Error types (Transcription, Processing, Recording) | ✅ |
| Crash reporting | ❌ Not yet implemented |

---

## 5. Architecture

```
┌─────────────────────────────────────────────┐
│                 macOS App                     │
│                                               │
│  ┌───────────┐  ┌──────────┐  ┌───────────┐ │
│  │ HotkeyServ│→│Transcript.│→│TextProcess.│ │
│  │           │  │Coordinator│  │           │ │
│  └───────────┘  └────┬─────┘  └─────┬─────┘ │
│                      │              │        │
│           ┌──────────┴──────────┐   │        │
│           │                     │   │        │
│  ┌────────┴───┐  ┌─────────────┴┐  │        │
│  │WhisperKit  │  │CloudWhisper  │  │        │
│  │(on-device) │  │(Groq/OpenAI) │  │        │
│  └────────────┘  └──────────────┘  │        │
│                                     │        │
│  ┌─────────────┐  ┌───────────────┐│        │
│  │TextInsertion│  │CorrectionDict ││        │
│  │(Cmd+V)      │  │(auto-learn)   ││        │
│  └─────────────┘  └───────────────┘│        │
│                                     │        │
│  ┌─────────────┐  ┌───────────────┐│        │
│  │HistoryServ  │  │LicenseService ││        │
│  │(SwiftData)  │  │(Keychain)     ││        │
│  └─────────────┘  └───────┬───────┘│        │
└───────────────────────────┼────────┘
                            │
                    ┌───────▼──────────┐
                    │  Cloudflare API   │
                    │  (Workers + D1)   │
                    │                   │
                    │  Auth, License,   │
                    │  Subscriptions,   │
                    │  Pro Proxy,       │
                    │  Usage Tracking   │
                    └───────┬──────────┘
                            │
                    ┌───────▼──────────┐
                    │  Stripe, Groq,   │
                    │  Cerebras, Resend │
                    └──────────────────┘
```

### Key Files

| Component | File |
|-----------|------|
| Entry point | `App/AppDelegate.swift` |
| Recording orchestration | `Services/System/TranscriptionCoordinator.swift` |
| On-device ML | `Services/Transcription/WhisperKitEngine.swift` |
| Cloud ML | `Services/Transcription/CloudWhisperEngine.swift` |
| Text processing | `Services/Processing/TextProcessor.swift` |
| Hotkeys | `Services/System/HotkeyService.swift` |
| Auto-paste | `Services/System/TextInsertionService.swift` |
| Dictionary | `Services/Processing/CorrectionDictionary.swift` |
| Licensing | `Services/License/LicenseService.swift` |
| History | `Services/Data/HistoryService.swift` |

---

## 6. Monetization

### Free Tier
- On-device transcription (all models)
- Raw + Clean modes (Clean = local regex)
- Full history and analytics
- Correction dictionary
- All hotkeys and auto-paste

### Pro Tier ($7.77/mo or $30/yr, save 68%)
- Cloud transcription (faster, more accurate)
- Structured mode (LLM polish)
- Translation (voice + text)
- Text style settings
- 60 min/day cloud minutes (max 600 balance)
- Server-side enforcement (HTTP 429 on exhaustion)

### Authentication
- Google Sign-In (JWT)
- Magic Link (Resend email, 20 min expiry)
- Deep link activation: `metawhisp://auth?token=...`
- Session: 30 days, Keychain storage, machine_id binding

---

## 7. Success Metrics (KPIs)

| Metric | Target (3 months) |
|--------|-------------------|
| Installs (DMG downloads) | 1,000+ |
| DAU (daily active users) | 200+ |
| Free → Pro conversion | 5-10% |
| Retention D7 | 40%+ |
| Retention D30 | 25%+ |
| MRR | $500+ |
| NPS | 40+ |

---

## 8. Roadmap

### Phase 1: Growth (current, month 1-2)
- [ ] Trial period (7-day Pro)
- [ ] Blog / SEO content (5-10 articles)
- [ ] Video demo on landing page
- [ ] Crash reporting (TelemetryDeck / Sentry)
- [ ] Product Hunt launch
- [ ] Comparison pages

### Phase 2: Scaling (month 3-4)
- [ ] Referral program
- [ ] CI/CD pipeline
- [ ] Export history
- [ ] App Store distribution

### Phase 3: Expansion (month 5-6+)
- [ ] iCloud sync
- [ ] Shortcuts integration
- [ ] Custom LLM endpoints
- [ ] Streaming transcription
- [ ] Website localization
- [ ] Multiple recording profiles

---

## 9. Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| WhisperKit breaking changes | Low | High | Pin versions, tests |
| Groq/Cerebras downtime | Medium | Medium | Fallback to on-device |
| Stripe compliance | Low | High | Proper Terms/Privacy |
| Low Free→Pro conversion | High | High | Trial period, onboarding, value demo |
| RAM overhead (WhisperKit loaded) | Medium | Medium | Lazy load/unload models |

---

## 10. Verdict

### What's DONE and working (production)
- Full core pipeline: record → transcribe → process → paste
- On-device + Cloud transcription with usage enforcement
- 3 processing modes (Raw/Clean/Structured)
- Translation (voice + text)
- Self-learning dictionary (auto-learn + brands + snippets)
- Dashboard with analytics and records
- Account/subscriptions (Google + Magic Link + Stripe LIVE)
- Backend API (auth, license, usage, proxy)
- Website with SEO, pricing, account
- Notarization + Sparkle auto-updates
- Paying users

### Summary
The product is **fully launched and running in production**. All core features are implemented. Current focus is on growth (trial, SEO, content marketing, Product Hunt) and quality (crash reporting, CI/CD).
