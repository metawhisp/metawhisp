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
- [x] ITER-064B — replay-набор: 16 director-кейсов + 5 adapter-кейсов через production-мост
- [x] ITER-065 — context visits, focused capture, privacy and freshness (065.9 живая матрица — частично: запуск/захват/миграция проверены, ручная матрица человеком не выполнялась)
  - [x] 065.1 визит: идентичность, поколение, самоистекающая свежесть — `e372f32`, `4ab7346`
  - [x] 065.2 fail-closed политика — закрыт в 064A (`a6f2a48`, `e7896b6`)
  - [x] 065.3 фокусное окно и его монитор — `de08192`, `4ab7346`
  - [x] 065.4 отпечаток содержимого + тайминги — `9f1be75`
  - [x] 065.5 OCR с главного потока в фон + bounds — `b436baa`
  - [x] 065.6 типизированные исходы захвата, сохранение до колбэка — `e11baaf`
  - [x] 065.7 очередь newest-value, пропуски прогонов, дедлайн — `5ac25a9`, `4ab7346`
  - [ ] 065.8 проводка в продакшен (shadow)
  - [ ] 065.9 живой прогон на подписанной сборке — требует сборки
- [~] ITER-066 — директор, evidence, adapter, полярность, quote-containment в обоих таск-путях.
  Открыто из ревью Codex: реактор всё ещё сам вставляет staged-задачи (мимо директора);
  didSearch/didConfirmRead в инвестигаторе; prompt V1 descriptor не создан
- [~] ITER-067 — durable item (V4/V5), delivery authority, Inbox, исходы taймаут/закрытие/вытеснение.
  Открыто: отдельные Run/Delivery-записи, пункт меню, retention для новой сущности
- [~] ITER-068 — якорь + замороженный контекст + баннер. Открыто: действия с подтверждением (задачи из карточки)
- [ ] ITER-069 — ЗАБЛОКИРОВАНО: спека требует явного одобрения владельца на cloud multimodal endpoint до реализации
- [x] ITER-070 — 5 причин фидбэка, Quiet/Balanced/Frequent, пауза, семантический дедуп отклонённого
- [x] ITER-071 — границы визитов по окну, чекпойнт не теряет и не перескакивает, save-fail не засчитывается
- [~] ITER-072 — health-статус в Inbox + честная копия в Settings + pacing UI. Открыто: онбординг, полный rollout-процесс

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

## Журнал — 2026-08-25, автономный проход

```text
Сделано: 064B (replay: 16+5 кейсов), 066 (директор/evidence/полярность/adapter),
067+068 фиксы по ревью Codex (presented-честность, исходы карточки, якорь),
070 (фидбэк+pacing), 071 (экстрактор), 072 (health), V5-миграция.

Инцидент: ITER-070 добавил поля в ScreenAgentItem без версии схемы → стор не
открылся, 11 минут in-memory сессии (~1 потерянная запись). Починено V5 +
замороженная V4-форма + тест «стор предыдущей версии обязан открыться». Живой
стор проверен: 8687/1520/2668/12680 строк целы.

Replay-набор на первом прогоне поймал: директор повторял внедрённый со страницы
API-ключ (добавлен unsafeContent + carriesSecret); эхо-фикстура была слабой.
Adapter-кейсы поймали: минимум длины цитаты в 3 символа глушил обоснованные
кейсы и пропускал выдуманный счёт (понижен до 2).

Гейт: 1112 тестов, 0 падений, 45 критических сюит, PASS.
Приложение пересобрано и установлено после каждого блока.

Открыто (главное): реактор вставляет staged-задачи мимо директора;
didSearch/didConfirmRead; Run/Delivery как отдельные записи; retention для
ScreenAgentItem; 069 заблокирован на одобрении владельца.
```
