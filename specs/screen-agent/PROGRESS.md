# Screen Agent implementation progress

## Status

Planning complete; application implementation not started.

Planning package now includes the Omi product benchmark, current-code audit,
plain-language user flows, one Claude master plan, nine numbered iteration
specs (`064...072`), and the repository-local execution skill.

## Active iteration

`ITER-065` — контексты-визиты, фокусный захват, приватность, свежесть.

Порядок итераций переупорядочен — см. `specs/screen-agent/EXECUTION-ORDER.md`.
Схема V4 перенесена из `ITER-064` в `ITER-067`; фикстуры сокращены с 60 до 15 и
переставлены после `ITER-065`.

The repository-wide `specs/iterations/PROGRESS.md` currently tracks another active feature. Do not overwrite or replace it. This file is the source of truth for the Screen Agent program.

## Master checklist

- [x] ITER-064A — подтверждённые дефекты (краш, fail-open allowlist, сдвиг отметки, сериализация)
- [ ] ITER-064B — contracts + replay (без SwiftData; после 065)
- [~] ITER-065 — context visits, focused capture, privacy and freshness
  - [x] 065.1 визит: идентичность, поколение, самоистекающая свежесть — `e372f32`, `4ab7346`
  - [x] 065.2 fail-closed политика — закрыт в 064A (`a6f2a48`, `e7896b6`)
  - [x] 065.3 фокусное окно и его монитор — `de08192`, `4ab7346`
  - [x] 065.4 отпечаток содержимого + тайминги — `9f1be75`
  - [x] 065.5 OCR с главного потока в фон + bounds — `b436baa`
  - [x] 065.6 типизированные исходы захвата, сохранение до колбэка — `e11baaf`
  - [x] 065.7 очередь newest-value, пропуски прогонов, дедлайн — `5ac25a9`, `4ab7346`
  - [ ] 065.8 проводка в продакшен (shadow)
  - [ ] 065.9 живой прогон на подписанной сборке — требует сборки
- [ ] ITER-066 — grounded director, candidate producers and prompt V1
- [ ] ITER-067 — persistent delivery and MetaChat Inbox
- [ ] ITER-068 — anchored MetaChat continuation and confirmed actions
- [ ] ITER-069 — same-frame visual reasoning and bounded retrieval
- [ ] ITER-070 — structured feedback, semantic dedup and pacing
- [ ] ITER-071 — canonical work analysis
- [ ] ITER-072 — settings, onboarding, shadow/dogfood rollout and release proof

## Baseline facts

- Screen Agent remains opt-in because `screenContextEnabled` is false by default.
- Current proactive output can be a six-second popup with no continuation.
- Current capture is app/raw-title-change gated and can miss stable-title content changes.
- Existing task and insight systems are independent producers; no shared visit or final decision authority exists.
- Existing MetaChat tool confirmation/undo is the action runtime to reuse.
- Existing `ITER-062` work and all dirty-worktree changes are user-owned and out of scope.

## Required progress entry after every slice

```text
Date/time:
Iteration/checklist item:
RED command + failing assertion:
GREEN command + exact passed/failed/skipped counts:
Build/full-suite state:
Live artifact and scenario:
Observed result:
Open issue/blocker:
Commit:
Next single item:
```

## Known product decisions

- One MetaWhisp identity; Screen Agent capability; MetaChat conversation; Inbox persistence.
- Empty allowlist is fail-closed.
- No persisted screenshots by default.
- One visit/generation, one director, one delivery authority.
- Evidence and silence are enforced in code.
- Screen-derived tasks require confirmation.
- External computer control is not part of this program.
- Default-on is a measured owner decision after dogfood, never an implementation default.

## Журнал

```text
Date/time: 2026-08-24 00:02 CEST
Iteration/checklist item: ITER-064A.1..4 — все четыре дефекта
RED:
  064A.1 swift test --filter ScreenExtractorVisitIndexTests → 4 теста, 3 падения
         (-1, Int.min, и -1 при пустом списке проходили старую проверку)
  064A.2 swift test --filter ScreenContextPolicyTests → 6 ошибок компиляции
         (нет isCaptureAllowed) + развёрнутое ожидание пустого allowlist
  064A.3 swift test --filter CaptureHighWaterMarkTests → 5 ошибок компиляции
  064A.4 swift test --filter ScreenContextFanoutTests → 2 теста, 1 падение
         (proactive не уложился в 0.5 с за реактором на 3 с)
GREEN: swift test → Executed 921 tests, 5 skipped, 0 failures (было 906)
Build: swift build — без ошибок
Live artifact: не выполнялся; проверка только сборкой и модульными тестами
Open issue: пустой allowlist теперь замолкает без видимого статуса в Settings → ITER-072
Commits: 3ee79a3, a6f2a48, 0fbc5eb, 9aa384e
Next single item: ревью Codex, затем ITER-065
```

## Журнал — ITER-065

```text
Date/time: 2026-08-24, вторая половина
Закрыто: 065.1, 065.3, 065.4, 065.5, 065.6, 065.7 (065.2 закрыт ранее в 064A)
Ревью Codex раунд 1: Request changes, 7 находок по 065.1/065.3/065.7 — все исправлены в 4ab7346
  критично: очередь без идентичности прогона (submit(A)→cancelAll→submit(C)→finish(A) ломал C)
  высоко:   дедлайна не было вообще; выбор окна проваливался наружу тремя способами;
            визит не истекал сам; монитор не в предикате; заголовок вместо windowID
Ревью Codex раунд 2: запущено по 065.4/065.5/065.6 + вопрос про 065.8
Гейт: 1011 тестов, 0 падений, 36 критических сюит, PASS
Открыто: 065.8 проводка; 065.9 живой прогон (нужна подписанная сборка — не выполнялся)
Не проверено: ничего из ITER-065 не работало на живом экране. Только модульные тесты.
Следующий шаг: дождаться раунда 2, затем 065.8
```
