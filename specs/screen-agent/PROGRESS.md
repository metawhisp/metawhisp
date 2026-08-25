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
- [~] ITER-069 — одобрено владельцем 2026-08-25 и реализовано:
  069.1-069.4 клиентская граница (согласие/кеш/vision-клиент/spatial-гард) + тесты
  069.5 production transport: /api/pro/vision на воркере, лестница провайдеров
        (groq-scout → groq-maverick → openai), проверен живым вызовом
  069.8 интеграция: один vision-вызов ровно на .needsVision, тот же валидатор
  Открыто: 069.6/069.7 bounded retrieval; 069.9 visual replay; 069.10 живая QA-матрица
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

## Журнал — 2026-08-25, финальное ревью Codex и фиксы

```text
Вердикт ревью: HOLD, 3×P0 — все подтверждены и закрыты (ca11ccc..HEAD):
  P0 очередь была мёртвым кодом → ScreenAgentRunQueue теперь ведёт proactive-путь
  P0 исторические инсайты глушились как ungrounded → history в evidence allowlist;
     specificity по headline+body; retract session-дедупа при отклонении директором
  P0 поздняя доставка игнорировала отзыв → preflight проверяет screenContextEnabled,
     TCC-permission и возраст результата (120 с)
  P1 границы токенов ("13"≠"2013", "Ann"≠"Anna"); полярность у сущности;
     дедуп не глушит новости (смена исхода/числа); эхо с новым body говорит;
     normalize складывает смарт-пунктуацию
  P1 путь чтения фидбэка был нерабочим (force-unwrap в предикате + try? скрывал) →
     плоский fetch + in-memory фильтр + backfill сигнатур V4-строк
  P1 метки визитов в промпте экстрактора приведены к zero-based контракту парсера
Data safety: CLEAN по вердикту ревью (V3→V4→V5, живой стор открыт, деградаций нет)
Гейт: 1118 тестов, 0 падений, 45 критических сюит, PASS
Приложение пересобрано и установлено, стор цел (8689 history, 34 insights)

Осталось открытым (честно):
  реактор вставляет staged-задачи мимо директора (заземлены, но не через него)
  Run/Delivery как отдельные записи; replay 21 кейс из требуемых 60
  dogfood-гейты (50 показов, ≥80% полезности) не начинались
  069 (visual) заблокирован: нужно явное одобрение владельца на cloud multimodal
```

## Журнал — 2026-08-25, ITER-069

```text
Владелец одобрил cloud multimodal («Давай делай, конечно»).
Сделано:
  spatial-гард: текстовый режим больше не утверждает «неактивно/справа/красным» —
    словарь EN+RU, «copyright»/«прекрасный» не срабатывают; с visual evidence проходит
  кеш кадров: ровно один, только память, ключ = context id, смерть при замене/
    истечении/purge/отзыве согласия/выходе; отдельное согласие screenAgentVisualConsent
  vision-клиент: same-frame proof в обе стороны, отзыв согласия mid-call
    отбрасывает ответ, сбой провайдера = сбой, не текстовая догадка
  воркер /api/pro/vision: первый прогон дал 404 — Groq уже снял модель;
    лестница scout→maverick→openai; живой вызов вернул корректные факты о
    тестовой форме (пустое поле, красная рамка, серая кнопка); старые
    эндпойнты проверены после обоих деплоев (transcribe 401 на мусорный ключ)
  интеграция: vision тратится ровно на .needsVision, решение перепринимает
    тот же директор с visual-фактами в evidence
Инцидент по пути: закоммитил сломанную сборку (объявление переменной не легло,
  использование легло) — гейт поймал на следующем прогоне, исправлено amend'ом.
Гейт: 1134 теста, 0 падений, 47 критических сюит, PASS
Осталось: bounded retrieval (069.6/7), visual replay (069.9), живая матрица (069.10)
```

## Журнал — 2026-08-25, вечер: батч-ревью Codex + deck до минимума DoD

```text
Ревью Codex по батчу (retrieval/pacing/announce/vision/event-capture): Request changes.
P0 закрыт: master-off теперь фенсит работу в полёте (settle-таски, re-check после
await'ов, epoch bump + сброс кадра в stopMonitoring, vision гибнет при выключении).
P1/P2 закрыты: reentrancy-флаг захвата; ошибка поиска не становится evidence;
дневной бюджет по deliveredAt и fail-closed; retention по capturedAt.

Deck 27 → 40 (минимум DoD выполнен) по распределению классов из ТЗ.
Новые кейсы поймали 4 дыры директора, все починены:
  перефразированное эхо (покрытие по словам + стемминг);
  русская морфология ломала дедуп (лёгкий стеммер RU/EN);
  платёжный приказ со страницы обходил эхо (гард unsafeContent);
  пустой токен: "".allSatisfy(isNumber) вакуумно true — солил все множества.
TEST-02 из продуктовой спеки — в deck в обе стороны (с retrieval и без).

Замер p95 инструментирован: NSLog latency= на каждом показе.

Гейт: 1149 тестов, 0 падений, 48 критических сюит, PASS. Приложение стоит.
Открыто: deck→60; Run/Delivery-записи; vision hypothesis/hash echo;
per-record retrieval refs; онбординг и подтверждение закрытия задач — решения владельца.
```

## Журнал — 2026-08-25, поздний вечер: deck 60, ревью-фиксы, echo-контракт vision

```text
Per-record retrieval refs: recordRefs() режет JSON поиска на по-записные refs
(t0..tN/m0..mM), только человекочитаемые поля. Закрыто три дыры разом: выдуманное
число заземлялось об "count": 8; пустой результат поиска читался как evidence;
терялась идентичность источника. Непарсибельный результат — прежний одиночный ref.

Vision echo-контракт (ITER-069 §4 как написано): запрос несёт generation (epoch
захвата) + SHA-256 кадра, клиент отвергает ответ без точного эха всех трёх полей.
Воркер эхоит — задеплоен, живьём проверено (generation/frame_hash вернулись).
По пути: Groq снёс ОБЕ llama-4 vision-модели (живые 404) — лестница теперь
qwen/qwen3.6-27b (единственная vision-модель в их доках) → gpt-4o-mini; проверено.

Deck 40 → 60: полный каталог ИТЕР-064 §5, распределение 15/12/10/8/6/5/4 теперь
АССЕРТИТСЯ (урезанный дек = красный билд). Директорские кейсы идут через продовый
адаптер — anchors/quote/referent выводятся, не пишутся руками. Это вскрыло два
продовых бага: (1) spatial-клейм умирал ungrounded ДО needsVision — vision-ретрай
не мог сработать никогда, порядок проверок исправлен; (2) пустой заголовок удваивал
body в claim — заглавная буква середины строки становилась «именем».

Ревью Codex по deck-40 (5 P1, 2 P2) — всё закрыто:
  стеммер: почта/почти→почт, notes→not — мин. остаток 4 (5 для одиночных RU);
  «не» больше не стоп-слово (негация = смысл); filler-body не спасает эхо;
  платёжный гард: маркер направления (to/на/по/счёт/кошелёк/IBAN…) перед
    назначением, ловит IBAN/телефон/ENS/«USD 500»/«оплатите», перестал жечь
    инвойсы за наличие цифр;
  semanticDuplicate теперь возвращается (реворд), duplicate = дословный повтор;
  закрыта/открыта и включена/выключена — в полярных парах;
  wrong_year: рантайм выдаёт date-ref (только год) — флагманский кейс «в
    приглашении 2025, сейчас 2026» заземлён честно, часы реплея запинены.

Гейт: 1153 теста, 0 падений, 48 критических сюит, PASS.
Приложение пересобрано и стоит (hot-swap, Developer ID).
Известное ограничение (Codex #6, зафиксировано): anchors проверяются по
объединению всех refs — клейм, смешивающий запись A и экран B, формально
заземлён. По-источниковая проверка отношений — вне текущего скоупа.
Открыто: Run/Delivery-записи; 10s-дедлайн поверх живых вызовов; p95 по
накопленным latency=; dogfood 5/50; онбординг и подтверждение закрытия — владелец.
```

## Журнал — 2026-08-25, ночь: второе враждебное ревью (7 P1 / 2 P2) → 6 дыр закрыто

```text
10s-дедлайн теперь связывает АКТИВНЫЙ ран, не только очередь: вочдог
освобождает слот по дедлайну, поздний finish приходит с чужим пермитом и
игнорируется. Поздний РЕЗУЛЬТАТ живёт только через прежние гарды
(тот же экран, purge-epoch, тумблеры) — свежесть по идентичности, не по часам.

Ревью Codex (коммиты per-record refs + vision echo): Request changes, 7 P1 / 2 P2.
Закрыто в этом проходе:
  {"items":null,...} парсился и падал в non-JSON-фолбэк — скаффолдинг
    возвращался в grounding; битый конверт теперь не заземляет ничего;
  поле-число стирало запись из evidence, хотя модель её видела — числа/булы
    теперь текст;
  post-await сверка шла с локальным кадром, не с кешем — выключение фичи
    mid-flight принимало инвалидированный ответ; кеш перепроверяется;
  любой visual-факт лицензировал любой spatial-клейм («Logo is blue»
    открывал «Submit is disabled») — лицензируют только факты, разделяющие
    контент с клеймом;
  pendingFrame УДАЛЁН: общий field позволял голосовому captureNow перезаписать
    poll-захват mid-OCR (пиксели B к строке A) и полноразмерному кадру пережить
    выключение Visual — кадр едет локалами вместе со своим снапшотом;
  wire-контракт запинен URLProtocol-стабом: тройка кодируется, отсутствующее
    эхо не может совпасть (fake-транспорт эхоил автоматически и прятал регресс).

Отложено осознанно, с записью:
  однозначные числа не anchors (кейс «Acme has 8 tasks») — задокументированный
    компромисс InsightReferent, старше этих коммитов; решать вместе с
    count-типизацией referent'а;
  union-grounding + непpersisted evidence ids — архитектурная пара к
    Run/Delivery-записям (следующий крупный блок);
  отмена URLSession при отзыве согласия — ответ и так гибнет на re-check;
    запрос уходил под согласием.

Гейт: 1160 тестов, 0 падений, 48 критических сюит, PASS. Hot-swap.
Открыто: Run/Delivery-записи (+evidence ids в durable-запись); deck: кейсы на
mid-flight инвалидацию и cross-record склейку; p95 ждёт живых показов; dogfood.
```

## Журнал — 2026-08-25, ночь-2: V6 — журнал запусков и доставок (план §4)

```text
ScreenAgentRun: каждый анализ-ран оставляет строку, тишины включая — trigger,
deadline, status, reason-код исхода, и evidence refs, которые решение реально
цитировало (раньше выбрасывались с раном — финдинг Codex закрыт).
ScreenAgentDeliveryRecord: доставка = событие со своей историей (queued/
presented/terminal/interaction), а не состояние, затираемое на item.
Retention/delete-all каскадируют журнал на том же часе, что и экраны.

Схем-дисциплина V5-инцидента соблюдена: V6 + lightweight stage; RED-тест
«V5-стор открывается под V6, журналы пусты и принимают строки»; прогон на
КОПИИ реального стора 189 МБ до установки — прошёл. После hot-swap живой стор
проверен sqlite'ом: обе таблицы созданы, 13787/1542/2679/9 строк целы.

Не журналируются преднамеренно: префлайт-отказы (pacing/blacklist/выключено) —
они не начинали анализа. beginRun после жёстких гейтов, completeRun через defer
на всех выходах: noProposal / reason-код тишины / item+citedIDs / invalidated.

Гейт: 1164 теста, 0 падений, 48 критических сюит, PASS.
Ревью Codex по V6-коммиту запущено (в полёте) — триаж следующим проходом.
Открыто: ревью-фиксы V6; deck-кейсы mid-flight/cross-record; p95; dogfood;
онбординг и подтверждение закрытия задач — решения владельца.
```

## Журнал — 2026-08-26: дек 65 + ревью V6 (7 P1 / 3 P2) → журнал перестал лгать

```text
069.9: дек получил глаза — 3 визуальных кейса через продовый vision-путь.
Третий поймал дыру при рождении: «Submit button is enabled» ЛИЦЕНЗИРОВАЛ
«Submit is disabled» (общий субъект = поддержка). Противоречащий факт теперь
опровержение: клейм уходит в needsVision, а не выезжает с печатью vision.
userRejected впервые под кейсом (раннер выводит сигнатуру путём записи
фидбека); литеральный duplicate закреплён отдельно от semanticDuplicate.

Ревью Codex по V6 (7 P1 / 3 P2, «журнал лжёт в нескольких таймлайнах»):
  run закрывается своим row-ID — закрытие по неуникальному contextID давало
    перекрёстное закрытие A/B с чужим исходом;
  краш-реконсиляция: следующий beginRun переводит просроченные running →
    abandoned; вочдог пишет expired только поверх running, поздний реальный
    исход перезаписывает его как более правдивый;
  преемник вочдога при занятом ассистенте журналируется assistantBusy,
    а не выдуманным noProposal;
  повторная попытка доставки оставляет duplicateRun-запись (событие без
    строки = ложь умолчанием); announce() пишет run+delivery (карточка,
    которую юзер ВИДЕЛ, нигде не существовала);
  interaction терминализирует delivery-запись; повторный confirmPresented
    не перетирает время показа и pacing-часы;
  vision fact-ID чеканятся локально — серверное поле могло пронести сырой
    экранный текст прямо в персистентный журнал;
  V5 заморожен по паттерну V4 + ловушка по пути: V6, наследуя V5.models,
    отгрузил бы в прод замороженный чужой класс под тем же именем сущности.
Отложено с записью: три часа retention (окно сирот ≤ минут, добирается
следующим свипом); provenance-колонки (trigger/promptVersion) — проводка
источника триггера через capture-слой отдельным проходом.

Гейт: 1170 тестов, 0 падений, 48 критических сюит, PASS. Hot-swap.
Следующее: ContextVisit (V7) → ITER-071; решения владельца прежние.
```
