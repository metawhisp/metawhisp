# ITER-039 — Local LLM для Free tier

**Goal:** ослабить Pro paywall — вместо «нет ключа = ничего LLM не работает» дать юзеру **скачать local model** на маке, и большинство фич заработает локально без cloud затрат и без BYOK.

**User commit 2026-05-12:** «давай для free-моделей добавим опцию скачать с huggingface супер-быструю модель, чтобы локально в макбуке, не сильно загружала мак но давала юзеру быструю скорость и высокое качество».

Plus 3 extras: (1) UI shows multiple models with characteristics, (2) compatibility badge per Mac specs, (3) footer status pip reflects local vs cloud state.

## Что **должно работать локально** после ITER-039

После juзер скачал модель + сделал её Active:

| Фича | Sub-system | Затраты на Pro proxy после ITER-039 |
|------|------------|--------------------------------------|
| Structured text mode (буллеты, абзацы) | TextProcessor | 0 (был $0.005/dictation) |
| Translation между языками | TextProcessor | 0 (был $0.005) |
| Memory extraction | MemoryExtractor | 0 |
| Task extraction | TaskExtractor | 0 |
| MetaChat (без semantic search) | ChatService | 0 |
| Screen extractor (batch) | ScreenExtractor | 0 |
| Realtime screen reactor | RealtimeScreenReactor | 0 |
| StructuredGenerator (meeting recap) | StructuredGenerator | 0 |
| MeetingCoach (live coach) | MeetingCoachService | 0 |
| Proactive insights | ProactiveContextService | **Still Pro-only** (per-screen-capture cost insane locally) |
| Embeddings (semantic search) | EmbeddingService | **Apple NL framework on-device** (built-in, free) |
| Daily summary | DailySummaryService | 0 |
| Weekly pattern detector | WeeklyPatternDetector | 0 |

## Models — 5 опций для catalog

Все verified реальные на `mlx-community` HF (2026-05-12).

| Slot | HF ID | Params | DL | RAM | Speed (M1) | Quality | Languages | Best for |
|------|-------|--------|----|----|------------|---------|-----------|----------|
| Default | `mlx-community/Phi-4-mini-instruct-4bit` | 3.8B | 2.2 GB | 3 GB | 135 tok/s | ★★★★★ | EN+RU+multi | general, M1+/8GB+ |
| Lightweight | `mlx-community/gemma-4-e2b-it-4bit` | E2B effective | 1.5 GB | 5 GB | 158 tok/s | ★★★★ | EN+OK multi | speed-priority, weak Macs |
| Multilingual | `mlx-community/Qwen3-4B-Instruct-2507-4bit` | 4B | 2.3 GB | 3 GB | 80 tok/s | ★★★★★ | RU best | heavy Russian users |
| Quality | `mlx-community/Qwen3-7B-Instruct-2507-4bit` | 7B | 4.2 GB | 6 GB | 50 tok/s | ★★★★★ (HumanEval 76.0) | EN+RU excellent | 16GB+ RAM, complex reasoning |
| Built-in | Apple Foundation Models | ~3B equiv | 0 | native | native | — | EN+others | macOS 26+ users, zero-config |

## Architecture

### Layer 1 — System detection + compatibility

`Services/System/SystemSpecs.swift` — NEW. Static funcs:
- `chipName() -> String` — «M1», «M2 Pro», «M3 Max», «M4 Pro», «M5 Max»...
- `totalRAMGB() -> Int`
- `macOSVersion() -> (major: Int, minor: Int)`
- `supportsFoundationModels() -> Bool` (macOS ≥ 26)

`Services/LLM/ModelCompatibility.swift` — pure func:
- `func verdict(for model: ModelSpec, on system: SystemSpecs) -> Verdict`
  - `.recommended` — model.minRAMGB ≤ system.RAM AND chip era matches
  - `.slow` — minRAMGB exceeded by ≤30% OR older chip
  - `.tooHeavy` — minRAMGB exceeded by >30%

### Layer 2 — Model registry + storage

`Services/LLM/ModelRegistry.swift` — static catalog. Each `ModelSpec`:
```swift
struct ModelSpec {
    let id: String              // "phi-4-mini" — internal
    let hfRepoID: String        // "mlx-community/Phi-4-mini-instruct-4bit"
    let displayName: String     // "Phi-4 Mini Instruct"
    let vendor: String          // "Microsoft"
    let params: String          // "3.8B"
    let downloadSizeBytes: Int64
    let ramPeakGB: Int
    let speedM1: Int            // tok/s on M1
    let quality: Int            // 1-5 stars
    let languages: [String]     // ["EN", "RU", "multilingual"]
    let minMacRAMGB: Int
    let bestForTagline: String  // "Default — general purpose"
    let isFoundationModels: Bool
}
```

`Services/LLM/MLXModelManager.swift` — @MainActor:
- `func downloadModel(_ spec: ModelSpec) async throws` — URLSession resumable download from HF Hub
- `func deleteModel(_ id: String) async`
- `func isDownloaded(_ id: String) -> Bool`
- `func storagePath(for id: String) -> URL` (`~/Library/Application Support/MetaWhisp/LocalLLM/<id>/`)
- `@Published var downloadProgress: [String: Double]` — per-model progress 0..1

### Layer 3 — Inference

`Services/LLM/LocalLLMService.swift` — @MainActor:
```swift
final class LocalLLMService: ObservableObject {
    @Published var isModelLoaded: Bool = false
    @Published var activeModelID: String?
    @Published var lastError: String?
    
    func loadActiveModel() async  // reads settings.localLLMActiveModelID
    func switchToModel(_ id: String) async
    func complete(system: String, user: String) async throws -> String
    func unload()  // free RAM
}
```

Two implementations underneath:
- **MLX path** (Phi-4, Gemma 4, Qwen 3): uses `mlx-swift` Swift Package, loads model from disk, calls `mlx_lm.generate`-equivalent
- **Foundation Models path** (macOS 26+): uses Apple's `LanguageModel` Swift API, no model loading needed

`Services/LLM/FoundationModelsAdapter.swift` — wrapper for the Apple API. Falls back gracefully when not available.

### Layer 4 — Existing service integration

Add **third fallback path** в каждый existing service that has `hasLLMAccess`:

```swift
private var hasLLMAccess: Bool {
    !settings.activeAPIKey.isEmpty
    || LicenseService.shared.isPro
    || (settings.localLLMEnabled && localLLMService.isModelLoaded)  // NEW
}

// In each Service:
if isPro { ... call Pro proxy ... }
else if !apiKey.isEmpty { ... call OpenAI/Groq direct ... }
else if localLLMService.isModelLoaded { ... call localLLMService.complete(...) ... }
else { ... silent skip / placeholder ... }
```

Affected services (in order of priority for Phase 2):
1. TextProcessor (Structured mode) — Phase 1 must
2. MemoryExtractor — Phase 2
3. TaskExtractor — Phase 2
4. ChatService — Phase 2 (non-semantic basic chat)
5. StructuredGenerator — Phase 2
6. MeetingCoachService — Phase 2
7. ScreenExtractor — Phase 2 (warn user, can slow Mac)
8. RealtimeScreenReactor — Phase 2 (warn)
9. DailySummaryService — Phase 2
10. WeeklyPatternDetector — Phase 2

NOT integrated: `ProactiveContextService` (too many calls), `EmbeddingService` (use `NLEmbedding` instead).

### Layer 5 — Settings UI

`Views/Windows/MainSettingsView.swift` — new section **AI MODELS** between Account and Transcription Engine:

```
AI MODELS — Local (Free, no API key needed)
═══════════════════════════════════════════

✓ [Phi-4-mini-instruct]                     [Active]
  Microsoft • 3.8B • AWQ-4bit MLX • 2.2 GB
  ⚡ 135 tok/s • 📦 3 GB RAM
  ★★★★★ • EN + RU + multilingual
  ✓ Recommended for your M2 Pro / 16 GB
  [Active ▼]  [Test prompt]  [Delete]

[Gemma 4 E2B]                              [DL 1.5 GB]
  Google • TurboQuant-MLX • 1.5 GB
  ⚡ 158 tok/s • 📦 5 GB RAM
  ★★★★ • EN + decent multi
  ✓ Recommended for your Mac
  [Download]  [Test prompt — locked]

[Qwen 3 4B]                                [DL 2.3 GB]
  ...
  ✓ Recommended for your Mac
  [Download]  [Test prompt — locked]

[Qwen 3 7B]                                [DL 4.2 GB]
  ...
  ⚠ Slow on your Mac — try 4B variant first
  [Download]  [Test prompt — locked]

Apple Foundation Models
  ✗ Requires macOS 26 — you're on macOS 14.5
  (or ✓ Available — using as default)
```

Per-card states:
- Not downloaded: shows specs + Download button + compatibility badge
- Downloading: progress bar in card, cancel button
- Downloaded: shows specs + Make Active / Active / Delete / Test prompt buttons
- Active: highlighted card, all services route through this model
- Foundation Models: not downloadable but selectable when available

### Layer 6 — Footer pip update (sidebar)

`Views/Windows/MainWindowView.swift` — `processingModeLabel` / `processingModeColor` currently shows `on-device` / `cloud` / `on-device+cloud`. Add **local** state when juзер на local LLM:

| State | When | Pip label | Color |
|-------|------|-----------|-------|
| `local` | localLLMEnabled + no Pro/BYOK | "local" | green (idle) |
| `local+cloud` | local for processing + Pro/BYOK for transcription | "local+cloud" | orange (processing) |
| `on-device` | (existing) | "on-device" | green |
| `cloud` | (existing) | "cloud" | blue |
| `on-device+cloud` | (existing) | "on-device+cloud" | orange |

Adds 2 new label values + corresponding colors.

### Test prompt button (per-card)

Single fixed input (in both EN + RU):
```
EN: "First, finish the report. Second, send to Sam. Third, update the deck."
RU: "Во-первых, купить продукты. Во-вторых, заехать на заправку. В-третьих, забрать посылку."
```

Per-card button:
- Shows model's output inline in card (collapsible)
- Shows time taken (e.g. «1.3 sec, 87 tok/s»)
- Side-by-side: user can run on multiple downloaded models, compare outputs/times

## Phases

### Phase 1 (today, foundation — ~2 hours)
1. SystemSpecs detection
2. ModelRegistry static catalog
3. ModelCompatibility verdicts
4. AppSettings extensions
5. Footer pip update — show «local» / «local+cloud» states
6. Settings UI section with cards + compat badges (Download buttons disabled — placeholder)

**Outcome:** user opens Settings → AI Models section → sees catalog + compat badges. Nothing actually downloadable yet. Visual progress visible.

### Phase 2 (~1 day)
1. `mlx-swift` Swift Package dependency
2. MLXModelManager — HF Hub download via URLSession with progress
3. LocalLLMService skeleton — load/unload/complete
4. Settings UI wired: real Download / Make Active / Delete buttons

**Outcome:** user can download + activate a model. No services use it yet.

### Phase 3 (~1 day)
1. Wire LocalLLMService into TextProcessor — third fallback
2. Wire into MemoryExtractor, TaskExtractor, ChatService
3. Wire into StructuredGenerator, MeetingCoach
4. Wire into ScreenExtractor, RealtimeScreenReactor (with warnings)
5. Wire into DailySummary, WeeklyPattern

**Outcome:** with active local model, juзер's dictations actually get Structured locally. No Groq/Pro-proxy hit.

### Phase 4 (~0.5 day)
1. Apple Foundation Models adapter (macOS 26+ detection + LanguageModel API)
2. Per-card «Test prompt» button + result preview
3. Smoke test full pipeline

**Outcome:** users on macOS 26 don't even need to download — Foundation Models auto-selected.

### Phase 5 — v1.3.5 release (~30 min)
1. Bump Info.plist 1.3.4 → 1.3.5
2. `bash build.sh` → notarize → DMG
3. `gh release create v1.3.5` + upload DMG
4. Update src/appcast.xml in metawhisp/MetaWhisp.com
5. Sparkle pushes update to existing v1.3.4 users

## Open questions

1. **Default Active model** for a new install — `phi-4-mini` или skip and let user pick? **Default: skip** — show «No model active» state, prompt user to pick. Avoids 2GB download without consent.
2. **macOS 26 Foundation Models** — auto-activate when detected? **Yes** — zero-cost, zero-friction.
3. **Storage cap** — should we warn if total downloads exceed e.g. 10 GB? **Yes** — show running total в Settings + warning chip if >10 GB.

## Acceptance

1. Open Settings → AI Models → see 5 cards with full characteristics
2. Each card shows compat badge matching user's Mac
3. Download a model → progress bar → moves to «Downloaded» state
4. Make Active → footer pip changes from "cloud" to "local" (or "local+cloud" if both)
5. Dictate list — get bulleted output processed by local model, no Groq call in logs
6. Switch active model — next dictation routed through new model
7. Delete model — disk freed, can re-download
8. Foundation Models on macOS 26+ — works without download
9. v1.3.5 ships to Sparkle, existing v1.3.4 users get update notification

## Sources

- mlx-community on HuggingFace: https://huggingface.co/mlx-community
- Phi-4-mini-instruct-4bit: https://huggingface.co/mlx-community/Phi-4-mini-instruct-4bit
- gemma-4-e2b-it-4bit: https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit
- Qwen3-4B-Instruct: https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit
- Apple WWDC 2025 — Foundation Models framework
- mlx-swift on GitHub: https://github.com/ml-explore/mlx-swift
- Speed benchmarks: localaimaster, insiderllm, llmcheck.net
