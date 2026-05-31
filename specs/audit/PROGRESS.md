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

## Next Step

Hand `FULL-APP-AUDIT-2026-05-31.md` to the bugfix agent. Take one finding per
RED -> GREEN -> REFACTOR iteration and atomic commit. Run the manual-only matrix
alongside the automated regressions before the next release.
