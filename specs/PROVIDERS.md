# Pro Proxy Provider Chain

> Source-of-truth: the live Cloudflare Worker `metawhisp-api` (not in this repo).
> Last verified: 2026-05-20.

## Why chains exist

Each route on `api.metawhisp.com` calls 3rd-party AI providers. A single
provider can go down for billing reasons (spend alert, free quota exhausted,
account suspension) — not code. To keep the user productive, every route
tries providers in priority order. First success wins; first call logs the
provider used.

This is **not** retry-on-error-rate. The chain only advances on a thrown
exception OR non-2xx HTTP. Successful 200 responses are returned immediately.

## Transcription — `/api/pro/transcribe`

```
audio (WAV) ──► Deepgram Nova-3       ──► OK?  return text  [provider: "deepgram"]
                  │
                  ▼ fail
                Groq whisper-large-v3-turbo ──► OK?  return text  [provider: "groq"]
                  │
                  ▼ fail
                OpenAI whisper-1            ──► OK?  return text  [provider: "openai"]
                  │
                  ▼ fail
                HTTP 502 { error, details: { deepgram, groq, openai } }
```

| Provider | Binding | Model | Cost | Notes |
|---|---|---|---|---|
| Deepgram | `env.AI` (CF Workers AI) | `@cf/deepgram/nova-3` | 10k neurons/day free, then needs **Workers Paid ($5/mo)** | Fastest, best multilingual. Returns 429 once free quota exhausted. |
| Groq | `env.GROQ_API_KEY` | `whisper-large-v3-turbo` | Per-token, blocked by spend alerts | Returns 400 with `"Organization has blocked API access..."` when alert hits. |
| OpenAI | `env.OPENAI_API_KEY` | `whisper-1` | $0.006/min | Most expensive but most stable. Last line of defence. |

## LLM (process / advice / chat-with-tools) — `/api/pro/process`, `/api/pro/advice`, `/api/pro/chat-with-tools`

All three routes share the same helper `runChatCompletion(env, body)`:

```
chat body ──► Groq llama-3.3-70b-versatile ──► OK?  return  [provider: "groq"]
                │
                ▼ fail
              Cerebras llama-3.3-70b         ──► OK?  return  [provider: "cerebras"]
                │
                ▼ fail
              HTTP 502 { error, details: { groq, cerebras } }
```

Model id is normalised: Cerebras receives the Groq model name minus the
`-versatile` suffix (Groq's `llama-3.3-70b-versatile` → Cerebras's
`llama-3.3-70b`). Both providers expose OpenAI-compatible `/chat/completions`
including `tool_calls`.

| Provider | Binding | Model | Cost | Notes |
|---|---|---|---|---|
| Groq | `env.GROQ_API_KEY` | `llama-3.3-70b-versatile` | Per-token, blocked by spend alerts | Primary. Returns 400 when spend alert hits. |
| Cerebras | `env.CEREBRAS_API_KEY` | `llama-3.3-70b` | Per-token | Fallback. Same OpenAI-compat API, supports tool calls. |

## Response envelope changes

All proxy routes now return `provider: "<name>"` in success responses so the
client can surface which fallback fired. The app's `[CloudWhisper] PRO ✅`
log line stays unchanged, but downstream `[Insight]` / `[RealtimeReactor]`
can log the chosen provider for observability if needed.

On failure (all providers exhausted) the 502 envelope now carries
`details: { provider: errorMessage }` so future debugging does not need a
debug endpoint.

## Operational baseline as of 2026-05-20

- **Deepgram (CF AI):** ⛔ free quota exhausted on Cloudflare account. Workers Paid plan would restore.
- **Groq:** ⛔ spend alert blocking. Lift at https://console.groq.com/settings/billing.
- **OpenAI:** ✅ active.
- **Cerebras:** ✅ active.

Effective chains right now:
- Transcription: Deepgram (fail 429) → Groq (fail 400) → **OpenAI (200)**.
- LLM: Groq (fail 400) → **Cerebras (200)**.

## Testing

`scripts/test-transcribe-proxy.sh` — POSTs a real WAV to `/api/pro/transcribe`
with `MW_LICENSE_KEY` env var, asserts non-empty `text` in the 200 response.
Exit codes: 0 ok / 1 bad license / 2 all-providers-failed / 3 other HTTP / 4 missing license env. Use after any change to the worker, or after a billing flip.

## Editing rules

- **Do not** silently swap provider priority — change `PROVIDERS.md` first, then the worker, then redeploy.
- **Do not** remove a fallback "to simplify" — it's there because billing failures are recurring.
- **Adding a 4th provider** requires: new env binding, helper update, this doc entry, smoke test re-run.
