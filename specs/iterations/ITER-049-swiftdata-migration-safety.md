# ITER-049 — SwiftData data-safety (AUD-007)

> Latent data-loss risk: `HistoryService` builds the store with **no `migrationPlan:`**
> and falls back to a **silent in-memory container** on any open failure — the user's
> on-disk history is bypassed and that session's writes vanish on quit. Live store is
> healthy (164 MB) → latent bomb, not an active incident.
> Codex review: `/tmp/mw-aud007-codex-out.txt` (2026-06-14).

## Approach (ordered — safe-fail BEFORE migrations, per Codex)

- **A — Safe-fail** (stop the silent loss; highest leverage, independent of migrations)
  - **A1** Make the failure visible + preserve the file (backup + degraded overlay).
  - **A2** Block silent writes while degraded (no false "saved").
- **B — V1 anchor** VersionedSchema V1 (current 14 models) + SchemaMigrationPlan + `migrationPlan:`. **Prove on a COPY of the real 164 MB store** that it opens with zero migration. Ship V1-only.
- **C — V2 discipline** (process, documented) every future `@Model` change = new Vn + tested stage; freeze V1 at first V2.

## Corner cases / test matrix
- Fresh/empty store → creates V1.
- Real 164 MB store → opens, 0 migrations, all 14 row counts preserved (critical proof).
- WAL: copy `.store` + `-wal` + `-shm` together; ignore `.backup-2026-04-25`.
- Manual UUID FKs (HistoryItem.conversationId, TaskItem.*, AuditLog.chatMessageId) — not SwiftData relationships.
- `DailySummary` "unique date" is a comment, NOT `@Attribute(.unique)` — adding the constraint later = breaking change needing dedup.
- Raw-value strings (IndexedFile.fileType, TaskItem.status): new case ok; rename = data migration.
- Downgrade (store V2, app V1) → safe-fail, not wipe. Disk-full mid-migration → safe-fail.

## Checklist
### A1 — visible failure + file preservation  ✅ DONE (2026-06-14)
- [x] `StoreBackup.preserveUnopenableStore` + tests (copies store+sidecars, leaves original, missing sidecars ok, timestamped, distinct dirs).
- [x] `StoreHealth` enum + `StoreBackup` helper.
- [x] `HistoryService`: `@Published health`; on catch → preserve file + set `.degraded` + keep in-memory shell.
- [x] `StoreRecoveryOverlay` + `MainWindowView` overlay when degraded (reason · backup path · Reveal · Quit).
- [x] build + 5/5 tests green.
- [x] **Review (multi-agent, 4 agents):** 1 confirmed P3 — partial-sidecar copy reported as complete backup → fixed (all-or-nothing: nil + cleanup if any present file fails; new test). Swift-correctness + regression lenses clean.
### A2 — degraded = read-only shell  ✅ DONE (2026-06-14)
- [x] TDD caught `allowsSave:false` CRASHES in-memory container creation (/dev/null read-only, NSCocoaError 257) → rejected; kept writable in-memory + targeted guards. (`DegradedContainerTests`)
- [x] `HistoryService.save/delete/deleteAll` short-circuit on `health` (no false success).
- [x] `AppDelegate` gates 8 background starters + `screenContext.startMonitoring` on store health (healthy → identical).
- [x] **Owner-layer mutation gate:** `MutationService.commit` throws `MutationError.storeDegraded` in degraded → no volatile save, no Obsidian re-export, no MCP snapshot overwrite. Backed by process-wide `StoreHealthSignal` (singletons can't reach HistoryService). Defense-in-depth guard in `MCPSnapshotService.writeSnapshot`. (`MutationServiceDegradedTests`)
- [x] 23/23 tests green.
- [x] **Review round 1 (6 agents):** P1 — event-driven MCP overwrite via voice hotkey bypassing overlay (MutationService→snapshotNow) + P3 screenContext ungated → both fixed. **Round 2 (re-verify, 2 agents): 0 findings.**
### B — V1 anchor  ✅ DONE (2026-06-15)
- [x] `MetaWhispSchemaV1: VersionedSchema` (14 models, 1.0.0) + `MetaWhispMigrationPlan` (schemas=[V1], stages=[]). `Models/MetaWhispSchema.swift`.
- [x] `HistoryService` success path → `Schema(versionedSchema: MetaWhispSchemaV1.self)` + `ModelContainer(for:migrationPlan:configurations:)`, named `"MetaWhisp"` config kept.
- [x] Synthetic proof: a store written with the OLD bare `Schema([...])` reopens under V1 with rows intact (no wipe). `SchemaMigrationTests`.
- [x] **REAL-STORE PROOF (the gate):** copied the live 164 MB store (+wal+shm) → opened the copy under V1+migrationPlan → **no migration, no error, data intact: memories=1286, tasks=906, conversations=833, history=6789.** Introducing V1 is a no-op for existing users.
- [x] API verified against the SDK swiftinterface before coding.
- [x] hot-swapped 2026-06-17 (PID 23191): live binary opened the real store under V1 — no DEGRADED, no migration, data intact (MCP snapshot 500 mem / 303 tasks / 100 conv), license pro=YES, background jobs running (storeHealthy → A2b gates are no-ops). Final Codex sign-off over the whole feature: SHIP.
- Freezing rule documented in MetaWhispSchema.swift for the first V2.
### C — V2 discipline (doc)
- [ ] Rule + freeze procedure.

## PROGRESS
- 2026-06-14: plan written, Codex-reviewed. Starting A1 (TDD).
- 2026-06-14: A1 done (commit 11cdac3) + multi-agent review (1 P3 fixed). A2 done (commit a7316d3) + 2 review rounds (P1 voice-path MCP overwrite + P3 fixed).
- 2026-06-14: **Full A1+A2 review (Codex + multi-agent)** caught 4 more degraded-session writes A2 missed → fixed (commit 5f58d8b): extraction-queue drain, one-shot @AppStorage migration flags, screenContext gate completeness, StoreBackup same-second collision. Codex re-verified all 4 closed, no healthy-path regression. **Part A COMPLETE.** Next: Part B (V1 anchor).
