# ITER-041 — LLM tier routing (mini/medium/heavy)

## Problem

Production Groq billing: $30.93 over 30 days on `llama-3.3-70b-versatile`
(verified 2026-05-28 via dashboard chart). All 11 background services route
through the same heavy model — even structured extraction (per-conversation
title+project+category, memory extraction, task extraction) which is well
within an 8B model's capability.

Reference (verified 2026-05-28 via `backend/utils/llm/clients.py` in the
reference codebase): 5 specific model clients are used — a cheap mini for
gates/classification/structured extraction, a medium for user-facing
generation, a high tier only for hard reasoning. Two-stage flow (cheap
gate → expensive generate) is used everywhere a notification could be
suppressed.

Our worker `metawhisp-api/index.js` hard-codes one model
(`llama-3.3-70b-versatile`) for all 3 LLM routes (`/api/pro/process`,
`/api/pro/advice`, `/api/pro/chat-with-tools`). No client-side tier
declaration, no gate step, no per-call telemetry to know which service
spends what.

## Goal

Reduce Pro-proxy LLM spend by ≥60% while keeping ALL user-visible features
working. Quality MUST stay equal or better on user-facing surfaces
(MeetingCoach, ChatService, Daily/Weekly synthesis). Extraction surfaces
(MemoryExtractor/TaskExtractor/StructuredGenerator) accept a small quality
delta if structured JSON fields stay valid.

Non-goals: local LLM tier (Phi-4 init unstable per WAL; Apple Intelligence
covers ~0.1% of installed base) — cloud-only architecture.

## Architecture — 3 tiers

| Tier | Primary (Groq) | Fallback (Cerebras) | $/1M in/out | Use cases |
|---|---|---|---|---|
| `mini` | `llama-3.1-8b-instant` | `llama-3.1-8b` | $0.05/$0.08 | gates, JSON-schema extraction, classification, dedup |
| `medium` | `openai/gpt-oss-20b` | `gpt-oss-120b` | $0.075/$0.30 | user-facing advice, proactive text, daily/weekly synthesis |
| `heavy` | `llama-3.3-70b-versatile` | `llama-3.3-70b` | $0.59/$0.79 | live meeting coach, user chat, function-calling |

Pricing verified 2026-05-28 via groq.com/pricing + artificialanalysis.ai/providers/cerebras.

## Worker contract — backward-compatible

Existing routes (`/api/pro/advice`, `/api/pro/process`,
`/api/pro/chat-with-tools`) accept two new optional fields:

```json
{
  "messages": [...],
  "tier": "mini" | "medium" | "heavy",   // optional, default "heavy"
  "service_id": "MemoryExtractor"        // optional, telemetry only
}
```

Missing `tier` → `heavy` (current behaviour). Missing `service_id` → logged
as `"unknown"`. ZERO regression risk for existing client code.

Response envelope gains 2 fields (existing fields preserved):

```json
{
  "choices": [...],
  "usage": { ... },
  "provider": "groq",
  "tier_used": "mini",                   // NEW
  "model_used": "llama-3.1-8b-instant"   // NEW
}
```

New route — 2-stage gate (Phase C):

`POST /api/pro/gate`:
```json
// Request
{
  "context": "string",
  "purpose": "proactive" | "advice" | "reactor" | "meeting_coach",
  "recent_topics": ["string", "string"]
}
// Response (always tier:mini under the hood)
{
  "is_relevant": false,
  "score": 0.23,
  "reasoning": "User is in flow on routine email, no actionable signal",
  "tier_used": "mini",
  "model_used": "llama-3.1-8b-instant"
}
```

Caller pattern:
```
score = gate(...)
if score >= 0.65:
    advice(..., tier="medium")
else:
    # skip — saved a medium-tier call
```

## Client contract — `LLMTier` enum + ProClient centralization

New file `Services/LLM/LLMTier.swift`:
```swift
enum LLMTier: String, Codable {
    case mini
    case medium
    case heavy
}
```

New file `Services/Network/ProClient.swift` — centralizes the 11 ad-hoc
URLSession calls currently scattered across services. Each call site passes
its tier + service_id. Old call-sites refactor incrementally; ProClient and
old paths coexist until migration done.

Per-service `defaultTier` (static let on each service):

| Service | Tier | Reasoning |
|---|---|---|
| `MemoryExtractor` | mini | structured JSON extraction |
| `TaskExtractor` | mini | structured JSON extraction |
| `StructuredGenerator` | mini | per-conversation title+project+category JSON |
| `WeeklyPatternDetector.dailyExtract` | mini | incremental theme extraction |
| `RealtimeScreenReactor.gate` | mini | NEW gate step (after regex heuristic) |
| `InsightAssistantService.gate` | mini | NEW gate step |
| `AdviceService.gate` | mini | NEW gate step |
| `LiveMeetingAdvisor.gate` | mini | NEW gate step |
| `AdviceService.generate` | medium | user-facing advice text |
| `InsightAssistantService.generate` | medium | proactive chip text |
| `RealtimeScreenReactor.generate` | medium | task extraction text |
| `WeeklyPatternDetector.synthesize` | medium | Sunday roll-up |
| `DailySummaryService` | medium | synthesis, not analysis |
| `MeetingCoachService.generate` | heavy | live overlay — quality critical |
| `LiveMeetingAdvisor.generate` | heavy | post-gate full advice |
| `ChatService` | heavy | user chat reasoning |
| `ChatService.toolCall` | heavy | function-calling |

## Fallback policy

Worker degrades **within the same tier** across providers (Groq → Cerebras),
NOT across tiers, unless the caller explicitly opts in.

```
heavy/groq fails → heavy/cerebras → if all fail: 502 with envelope
mini/groq fails → mini/cerebras → if all fail: 502
```

Critical paths (`MeetingCoachService`, `ChatService`) leave `fallback_tier`
unset — better an explicit 502 than a silent downgrade in user-visible
surfaces.

Background paths (Insight, Advice) MAY pass `fallback_tier: "mini"` so a
medium-tier outage gracefully degrades to mini quality instead of
disappearing entirely.

## Observability

Worker logs every call as a single JSON line (CF observability already on):

```js
{
  ts, service_id, tier_requested, tier_used,
  model_used, provider, fallback_used,
  prompt_tokens, completion_tokens, cost_estimate_usd,
  duration_ms
}
```

Acceptance: ability to filter `cf logs` by `service_id` and aggregate
spend / latency / fallback-rate per service per day.

## Phased rollout

### Phase A — Worker tier-routing skeleton (this iteration)

Touch only `index.js`:
- Add `TIER_MODELS` constant
- `transcribeAdvice` / `transcribeProcess` accept `tier` + `service_id`
- Default `tier="heavy"` if missing
- Response includes `tier_used` + `model_used`

**Verify:**
- `curl tier=mini` returns `model_used: "llama-3.1-8b-instant"`
- `curl tier=medium` returns `model_used: "openai/gpt-oss-20b"`
- `curl tier=heavy` and `curl` (no tier) both return `llama-3.3-70b-versatile`
- All existing routes unchanged behaviour for clients that don't send `tier`

### Phase B — Client extraction → mini (this iteration)

Touch:
- New `Services/LLM/LLMTier.swift`
- New `Services/Network/ProClient.swift` (or extend existing helper)
- Migrate `MemoryExtractor`, `TaskExtractor`, `StructuredGenerator` to send
  `tier: "mini"` + `service_id`

**Verify:**
- Unit tests: each service exports correct `defaultTier`
- Unit tests: `ProClient` builds body with tier+service_id
- Hot-swap + record one short dictation → check `[StructuredGenerator]`
  log shows tier=mini in payload
- A/B sanity: extract one historical conversation with both heavy + mini,
  diff JSON fields; if mini drops any required field → rollback

### Phase C — Gate route + 2-stage Proactive/Advice/Reactor (next iteration)

Touch:
- Worker: add `/api/pro/gate` route
- Client: rewrite `InsightAssistantService`, `AdviceService`,
  `RealtimeScreenReactor` to 2-stage

**Verify:**
- Gate returns `{is_relevant, score, reasoning}`
- Threshold default 0.65 (configurable via `AppSettings.proactiveGateThreshold`)
- Generate only fires when `score >= threshold`
- Unit tests for boundary (score=0.65, score=0.0, score=1.0)

### Phase D — LiveMeetingAdvisor gate (next iteration)

Touch:
- Add gate step in `LiveMeetingAdvisor.runChunk` BEFORE the 30s heavy call

**Verify:**
- Quiet 30s segment → gate score low → skip generate
- Real conversation segment → gate passes → generate fires

### Phase E (deferred)

Apple Intelligence (Foundation Models) bridge for macOS Tahoe+ devices —
revisit when Tahoe adoption ≥5%. Phi-4 local — revisit when init crash root
cause is fixed and stability verified.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| 8B model drops critical JSON field in extraction | medium | A/B verification on 20 historical conversations before committing |
| Gate over-filters real signals | medium | Tunable threshold via AppSettings; default 0.65 with a "lower" option |
| Provider-level outage during fallback chain | low | Existing fallback already covers Groq→Cerebras; tier degradation is opt-in |
| Worker deploy breaks existing clients | low | tier is OPTIONAL with sensible default; all existing call shapes preserved |
| Cost estimate diverges from Groq actual billing | low | Log raw tokens; verify weekly against Groq dashboard |

## DoD (Phase A + B — this iteration)

- Worker accepts `tier` field, returns `tier_used` + `model_used`, deployed
- 5 Swift unit tests (3 per-service tier + ProClient body + back-compat default)
- All 260 existing tests pass + ~5 new
- One A/B sanity check on real historical conversation (mini vs heavy
  extraction JSON diff)
- WAL updated with delta + cost projection update
