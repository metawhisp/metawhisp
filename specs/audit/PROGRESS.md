# Full App Audit Progress

## Baseline

- Commit: `90738e968b40b52d417e43ef43c392b3aa8ce25c`
- Mode: report-only audit; no application source edits
- Report: `specs/audit/FULL-APP-AUDIT-2026-05-31.md`

## Master Checklist

- [x] Read `AGENTS.md`, BOOT, KARPATHY, TDD, WAL and architecture context
- [x] Create clean detached audit worktree
- [x] Create report with baseline, stories and previously proven findings
- [x] Audit lifecycle, storage and meeting pipeline
- [x] Audit conversations, PLAN, COPY and tasks
- [x] Audit chat, intelligence, LLM routing and privacy
- [x] Audit integrations, UI lifecycle and release configuration
- [x] Re-run static checks, build and tests on clean `HEAD`
- [x] Finalize handoff backlog and manual verification matrix

## Current Iteration

Complete: report-only full-app static audit is ready for bugfix handoff.

## Audit Summary

- Proven findings: `64`
- Priorities: `19 P1`, `39 P2`, `6 P3`
- Live-verification hypotheses: `3`
- Manual-only verification matrix: documented
- Application source edits: none

## Known Proven Bugs

- AUD-001: dual-stream leading-silence timestamp offset lost
- AUD-002: failed meeting chunks silently persisted
- AUD-003: local PLAN truncates transcript to 2000 characters
- AUD-004: PLAN skips BYOK fallback
- AUD-005: stale PLAN completion can populate another conversation
- AUD-006: workspace prompt over-trusts generic window title
- AUD-007: persistent-store failure silently degrades to volatile memory
- AUD-008: STOP during meeting startup can resurrect capture
- AUD-009: manual meeting can inherit stale call context
- AUD-010: meeting silence decisions use boosted UI level as raw RMS
- AUD-011: dictation discards sanitized pipeline value
- AUD-012: suspect-text recovery bypasses verified clipboard writes
- AUD-013: regenerate can erase summary while another generation is running
- AUD-014: concurrent structuring request is silently dropped
- AUD-015: structuring failures with nil fields are excluded from backfill
- AUD-016: full-transcript paths use inconsistent 200-item slices
- AUD-017: common task mutations leave Obsidian markdown stale
- AUD-018: MCP presents staged OCR candidates as pending tasks
- AUD-019: voice task extraction accepts blank descriptions
- AUD-020: Tasks active counter includes completed rows
- AUD-021: Screen Context blacklist/whitelist UI is not wired
- AUD-022: Screen OCR captures the full display instead of the active window
- AUD-023: voice MetaChat captures OCR while Screen Context is off
- AUD-024: API and license secrets are stored outside macOS Keychain
- AUD-025: license/session tokens enter query strings and logs
- AUD-026: inactive-license responses leave cached Pro credentials on disk
- AUD-027: MetaChat mutations report success when persistence fails
- AUD-028: MCP refresh-on-write contract is not implemented
- AUD-029: MCP snapshot is always emitted without opt-in
- AUD-030: memory edits/deletes leave Obsidian stale
- AUD-031: Daily Summary regeneration deletes the old recap too early
- AUD-032: inverted goal rating bounds can crash Goals
- AUD-033: Rating goals initialize/reset outside their range
- AUD-034: task and memory extraction drop concurrent conversations
- AUD-035: full-conversation extraction is truncated
- AUD-036: feature toggles require relaunch for several services
- AUD-037: Weekly Patterns digest has no reachable UI
- AUD-038: malformed Weekly Patterns output suppresses retry
- AUD-039: MetaChat ignores active local LLM
- AUD-040..053: memory validation, integrations, stale indexed data, Obsidian,
  private logs and screen-history retention findings are recorded in the report
- AUD-054: onboarding local transcription download is simulated
- AUD-055: onboarding cloud API-key verification is a no-op
- AUD-056: onboarding permissions do not gate NEXT
- AUD-057: disabling Local AI does not unload or stop local routing
- AUD-058: unsupported Apple Foundation Models can be activated
- AUD-059: MLX cancellation can clobber the next download state
- AUD-060: local-model load failures are hidden after activation
- AUD-061: Calendar consent copy promises removed task creation
- AUD-062: packaged integration help cannot find setup docs
- AUD-063: release readiness does not enforce Sparkle feed publication
- AUD-064: release smoke ends before local-model auto-load completes

## Bugfix Session Log

### Fixed + committed (16 findings) — branch `architecture-phase-1-3`

Privacy / secrets cluster (11):
- AUD-018 staged OCR candidates excluded from MCP snapshot
- AUD-021 Screen Context blacklist/whitelist wired
- AUD-022 capture only the front app's windows
- AUD-023 no OCR for voice questions when Screen Context off
- AUD-024 secrets → real macOS Keychain + safe migration (`a5f817a`)
- AUD-025 tokens out of URLs/logs
- AUD-026 clear persisted license on authoritative inactive response (`7a307fb`)
- AUD-029 MCP snapshot opt-in + purge + 0600 (`0ba5e22`)
- AUD-042 Obsidian Sync OFF stops the v2 exporter
- AUD-050 private content out of durable logs
- AUD-051 stored OCR retired from MetaChat when Screen Context off

Data-loss / crash cluster (5):
- AUD-002 mark meeting transcript incomplete when chunks fail (`4a16469`)
- AUD-016 stop truncating "full transcript" at 200 items (`eeefb38`)
- AUD-032 inverted goal bounds can't crash Goals (`8cd6690`)
- AUD-035 extract from the whole conversation, not first 100 rows (`2f46953`)
- AUD-043 stable id suffix in Obsidian filenames, no overwrite (`e36fbdf`)

All committed atomically with tests where unit-testable. Suite: 404 green.

**NOT LIVE until a signed 1.3.10 build** — secrets are still plaintext in
`~/Library/Application Support/MetaWhisp/.secrets` on disk until the migration
runs in a signed app; every other fix activates only when a build with this code
ships. Keychain/MCP-toggle/degraded-storage UI cannot be verified by `swift test`
(needs a hot-swap).

### AUD-007 — ROOT CAUSE found (NOT yet fixed; deferred to its own task)

The audit's "surface a degraded-storage warning" is symptom-treatment. The real
cause: **there is NO SwiftData migration plan** (verified: 0 hits for
`SchemaMigrationPlan`/`VersionedSchema`; `HistoryService.swift:16` builds the
container with no `migrationPlan:`). The app relies on implicit lightweight
migration, which silently handles additive/optional changes but THROWS on
breaking ones (non-optional field w/o default, rename, type/relationship change).
On the first release that ships such a `@Model` change, an existing user's
on-disk store can't be opened → `catch` falls back to `isStoredInMemoryOnly` →
their history vanishes on restart.

Verified current state (2026-06-01): the live store
`~/Library/Application Support/MetaWhisp.store` is **119 MB and written today** →
persistence is HEALTHY right now; degraded mode is NOT active. So this is a
**latent time-bomb**, not an active incident.

Root-cause fix (dedicated task, must be tested on a COPY of the real 119MB store
so V1 doesn't itself break the healthy DB):
1. Define `VersionedSchema` V1 capturing the current 14 models exactly.
2. Add `SchemaMigrationPlan` (empty stages for V1 baseline); pass
   `migrationPlan:` to `ModelContainer`.
3. Each future `@Model` change adds Vn + a migration stage.
4. Keep a degraded-mode flag + visible warning as a backstop for the genuinely
   unrecoverable cases (disk corruption, disk full) migration can't fix.

## Remaining open findings

Not started: AUD-007 (above), AUD-008, and the P2/P3 remainder (Obsidian
orphans AUD-044, file-index staleness AUD-045, Apple Notes AUD-047/048/049,
onboarding AUD-054..056, local-model AUD-057..060, release AUD-063/064, etc.).
See `FULL-APP-AUDIT-2026-05-31.md` for the full list.

## Next Step

Decide: (a) build/notarize 1.3.10 to make the 16 committed fixes live (secrets →
Keychain, crash fix, data-loss fixes), and/or (b) take AUD-007 migration plan as
a dedicated, store-copy-tested task. Continue remaining findings one per
RED → GREEN → atomic commit.

## Website SEO Audit Addendum

Added 2026-06-02: report-only production SEO review is recorded in
`specs/audit/SEO-SITE-AUDIT-2026-06-02.md`.

- Proven website findings: `11`
- Priorities: `4 P1`, `5 P2`, `2 P3`
- Marketing-site source checkout: not present locally
- Website source edits: none
- Manual follow-up: Lighthouse/Core Web Vitals, Search Console and legal review

## Second Brain Review Addendum

Added 2026-06-07: report-only current-code review is recorded in
`specs/audit/SECOND-BRAIN-REVIEW-2026-06-07.md`.

- Proven Second Brain findings: `13`
- Priorities: `2 P1`, `9 P2`, `2 P3`
- Application source edits: none
- Main risk cluster: silent skips/stale side effects across extraction,
  MetaChat mutations, Obsidian, MCP, file RAG and Apple Notes state

## Full Project Code Review Addendum

Added 2026-07-09: report-only current-code review is recorded in
`specs/audit/FULL-PROJECT-CODE-REVIEW-2026-07-09.md`.

- Proven current-code findings: `14`
- Priorities: `4 critical`, `8 major`, `2 minor`
- Application source edits: none
- Build/test execution: not run; `specs/HANDOFF.md` forbids `swift build` /
  `swift test` without explicit user request
- Main risk clusters: privacy-contract mismatch for screen/file context,
  durable logs with private content, auth deep-link without state, Pro
  transcription prompt in URL query, local-LLM-over-cloud fallback policy,
  swallowed saves around user-visible state, and release/repo hygiene

## Feature-by-Feature Review Addendum

Added 2026-08-16: report-only feature and product-block review is recorded in
specs/audit/FEATURE-BLOCK-BY-BLOCK-REVIEW-2026-08-16.md.

- Covered: 29 product blocks, 192 Swift source files, and 93 XCTest files.
- Active findings: 3 critical, 11 major, 3 minor.
- Static syntax parse: passed for app, MCP target, and tests.
- Build/test execution: not run; specs/HANDOFF.md requires explicit user authorization for swift build / swift test.
- Application source edits: none.
- Current fix order: privacy/auth/cloud-data boundaries, data preservation, integration correctness, then release/repository enforcement.

## Screen-Aware Agent Quality Review Addendum

Added 2026-08-23: report-only comparison and current-code review is recorded in
`specs/audit/SCREEN-AWARE-AGENT-QUALITY-REVIEW-2026-08-23.md`.

- Reference baseline: fresh public snapshot from 2026-08-23; external names and local clone paths are omitted from the report.
- MetaWhisp baseline: `a4bf18ded608d9d1efa7e6dcb0df3f73900097ce`.
- Findings: `7 P0`, `7 P1`, `1 P2`.
- Main root cause: multiple partial screen-intelligence loops share OCR but not one visit identity, grounding contract, decision authority, delivery lifecycle or evaluation harness.
- Highest-priority fixes: stale-context fences and newest-context coalescing, faithful focused-window capture, evidence refs, unified delivery, fail-closed whitelist and replay benchmark.
- Deliverables: comparison matrix, current/target Mermaid diagrams, six architecture decisions, five user stories, six implementation iterations, NFRs and 22 corner cases.
- Owner-readable behavior, UI proposal, seven primary acceptance tests and plain-language outcomes for all 22 corner cases: `specs/audit/SCREEN-AGENT-PLAIN-LANGUAGE-SPEC-RU-2026-08-23.md`.
- Application source edits: none.
- Build/test execution: not run; project rules require explicit user authorization.
