# MetaWhisp — AI Coprocessor Entry Point

**FIRST STEPS (всегда):**
1. Прочитай `specs/BOOT.md` — полные правила сессии
2. Прочитай `specs/WAL.md` — текущее состояние и следующий TODO
3. Запусти `swift build` — убедись что проект компилируется
4. Если не билдится — сообщи ДО начала работы

Вся методология — spec-driven (redbook): `specs/` — source of truth, код — compiled binary.

**Key docs:**
- `specs/BOOT.md` — правила сессии, критические запреты
- `specs/WAL.md` — continuation state (DONE / TODO / Issues)
- `specs/common/main.md` — архитектура и ключевые решения
- `specs/common/structure.md` — module map
- `specs/modules/<mod>/FEAT-XXXX.md` — спеки фич
- `specs/WAL-PROTOCOL.md` — правила WAL
- `specs/SPEC-PROTOCOL.md` — иерархия конфликтов (human > spec > code > tests)

**В конце сессии — ВСЕГДА** обнови `specs/WAL.md`.

---

# Code Rules

- Do not fix symptoms before identifying the root cause.
- Fix at the source-of-truth (owner layer), not where the symptom appears.
- Avoid child-layer compensation (fallbacks, patches, duplicated logic, branching).
- Always do ultra-deep system research end-to-end before fixing:
  - top-down: route → page → container → orchestration → state
  - bottom-up: function → hook → service → API → DB
- Diagnose by layers:
  data/contracts → business logic → async/timing → UI state → integration → architecture
- If a bug appears in a child, inspect the parent/owner layer first.
- When changing a mechanic, align all directly coupled layers:
  contracts, handlers, queries, cache, serializers, loading/error states
- Be skeptical of one-file fixes; justify why other layers are unaffected.
- For frontend issues, inspect the full flow:
  route → layout → page → hooks → API → backend
- Prefer systemic fixes, but keep changes proportional.
- If re-architecture is required, define scope, risks, compatibility, and rollout order.
