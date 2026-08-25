# Omi vs MetaWhisp Screen Agent — продуктовый benchmark и рекомендации

**Дата:** 2026-08-23
**Формат:** product research, не инженерный code review
**Статус:** исследование завершено; реализация MetaWhisp не начиналась
**Omi snapshot:** публичный macOS-код, commit `db024a528427e0ffaac564bff75744470ca94ac0`

## 0. Как читать этот отчет

Здесь разделены три уровня уверенности:

- **Наблюдается в публичном коде Omi** — можно указать конкретный state transition, prompt или UI handoff.
- **Наблюдается в текущем коде MetaWhisp** — подтверждено локальным статическим аудитом репозитория.
- **Продуктовый вывод** — объяснение, как это влияет на пользователя и что стоит изменить.

Закрытый backend Omi, реальные текущие выборки качества и поведение каждого выпущенного cohort здесь не выдаются за известный факт. Публичный код прямо показывает, что новый context-bucket/director path включен в dev и beta, а stable остается на fallback assistants. Кроме того, legacy assistants продолжают существовать рядом. Поэтому разные пользователи и сборки Omi могут получать разное поведение; ниже новый path используется как наиболее зрелый архитектурный benchmark, а не как обещание одинакового production UX для всех.

Связанные документы:

- технические доказательства MetaWhisp: `specs/audit/SCREEN-AWARE-AGENT-QUALITY-REVIEW-2026-08-23.md`;
- простая продуктовая спецификация: `specs/audit/SCREEN-AGENT-PLAIN-LANGUAGE-SPEC-RU-2026-08-23.md`;
- полный порядок работ для Claude: `specs/SCREEN-AGENT-CLAUDE-EXECUTION-PLAN-2026-08-23.md`.

## 1. Executive summary

### Главный вывод

Omi ощущается экранным агентом не потому, что у него есть один особенно хороший prompt. Ощущение создается связной цепочкой:

```text
наблюдение
  -> устойчивый эпизод/контекст
  -> факты, а не пересказ экрана
  -> решение «молчать или вмешаться»
  -> ограниченный поиск по истории
  -> проверка ссылок и актуальности
  -> карточка
  -> та же карточка становится ходом того же чата
  -> действие или follow-up имеют сохраняемый результат
```

В MetaWhisp уже есть почти все отдельные ингредиенты: OCR, история экрана, извлечение задач, proactive insight, task ranking, MetaChat с tools/confirmation/undo и popup. Но они работают как несколько продуктов. Именно поэтому пользователь видит случайную карточку, а не последовательное поведение одного помощника.

### Что уже можно переиспользовать в MetaWhisp

- стабильную диктовку и meeting capture — они не участвуют в этой переделке;
- Apple Vision OCR и Screen Recording plumbing;
- staged tasks и `TaskPrioritizationService`;
- MetaChat с read tools, confirmation, receipts и undo;
- `TaskFulfillment` как заготовку deterministic evidence validation;
- текущий non-activating popup как короткий preview;
- retention/delete и owner/purge seams, которые нужно расширить, а не заменить.

### Чего не хватает

1. Единого идентификатора текущего просмотра окна.
2. Одного владельца решения «показать или молчать».
3. Доказательства для каждого пользовательского утверждения.
4. Единого журнала `generated -> presented/suppressed/failed -> opened/actioned`.
5. Сохраняемой связи карточки с MetaChat.
6. Общей реальности для realtime-помощи и batch work analysis.
7. Replay-набора и human-reviewed dogfood до изменения prompts.

## 2. Какую работу пользователь нанимает Omi выполнять

С продуктовой точки зрения Omi продает не «анализ скриншотов», а четыре jobs-to-be-done.

### Job 1 — не потерять обязательство

Пользователь переписывается, соглашается что-то сделать и переключается дальше. Агент должен превратить забываемое обещание в управляемый кандидат задачи.

Желаемый результат для пользователя:

- назван конкретный человек и deliverable;
- старые сообщения не выдаются за новое обещание;
- запрос другому участнику не становится задачей пользователя;
- одна переписка может дать несколько отдельных commitments;
- duplicate/refinement/completion различаются.

В публичном Omi это видно в task-extraction workflow: сначала выделяется latest exchange, затем выполняется поиск похожих задач, затем вызывается typed `extract_task` или `no_task_found`. Источник: [`TaskAssistantSettings.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/ProactiveAssistants/Assistants/TaskExtraction/TaskAssistantSettings.swift).

### Job 2 — заметить неочевидную ошибку или shortcut

Пользователь не просит помощи явно, но находится перед видимой ошибкой, конфликтом или неочевидным следующим шагом.

Желаемый результат:

- совет относится к конкретному экрану;
- он добавляет то, чего пользователь еще не видит;
- он меняет следующий шаг;
- обычный экран заканчивается молчанием.

Omi задает высокий порог: `provide_advice` только для специфичного и неочевидного вывода; `no_advice` — нормальный исход. В legacy Insight path модель сначала исследует OCR/history, выбирает конкретный screenshot, визуально проверяет гипотезу и дополнительно ищет более поздние кадры, чтобы не советовать уже решенное. Источники: [`InsightAssistantSettings.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/ProactiveAssistants/Assistants/Insight/InsightAssistantSettings.swift), [`InsightAssistant.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/ProactiveAssistants/Assistants/Insight/InsightAssistant.swift).

### Job 3 — ответить на вопрос, пока пользователь его формулирует

Самый сильный Omi-like сценарий — не «пересказать страницу», а заметить, что пользователь пишет вопрос, найти ответ в его истории и подставить полезный факт до отправки.

Например:

```text
Пользователь пишет в Slack:
«А какой URL у dev dashboard?»

Omi находит URL в прошлой переписке/памяти и показывает:
«Dev dashboard: https://…»
```

В новом context-director Omi вопрос пользователя становится validated fact с высокой notify-worthiness; затем выполняется максимум один retrieval hop, а retrieved refs входят в allowlist именно этого model call. Источники: [`ContextBucketRollup.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/ProactiveAssistants/Core/ContextBucketRollup.swift), [`ContextProactivityEngine.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/ProactiveAssistants/Core/ContextProactivityEngine.swift).

### Job 4 — продолжить помощь, не объясняя эпизод заново

Пользователь получает карточку и спрашивает: «Почему?», «Что выбрать?», «Что ответить?». Система должна помнить именно карточку, а не просто смотреть на новый текущий экран.

В Omi proactive card сначала записывается в canonical chat journal; клик по всей карточке открывает chat view с этим assistant turn. Для ближайшего typed или voice запроса добавляются текст карточки, source/provenance и, где доступно, durable delivery provenance; блок помечен как untrusted reference, а не инструкция. Важное ограничение: сам assistant turn durable, но `storedNotificationMessages`/`pendingNotificationContext`, которые связывают клик с полным контекстом, являются process-memory state. Поэтому generic notification continuity после restart слабее, чем выглядит в одном непрерывном сеансе. MetaWhisp должен сделать item/thread link полностью persistent. Источники: [`FloatingControlBarState.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/FloatingControlBar/FloatingControlBarState.swift), [`FloatingControlBarWindow.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/FloatingControlBar/FloatingControlBarWindow.swift), [`ChatProvider.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/Providers/ChatProvider.swift).

## 3. Omi: пользовательский flow по состояниям

### Шаг 1 — контекст становится эпизодом

Omi не рассматривает каждый screenshot как независимый объект. `ContextVisitCoordinator` открывает visit с generation, закрывает его при смене контекста, исключении, sleep/lock и пересоздает после resume. Это делает возможным ответ на вопрос «к какому эпизоду относился вывод?»

Пользовательский эффект: меньше смешивания двух окон и возможность отменить/подавить поздний результат.

### Шаг 2 — после dwell экран превращается в факты

Новый path различает:

- summary — что вообще происходило;
- facts — commitment, request, deadline, blocker, failure, decision или changed status;
- notify-worthiness — можно ли вообще покупать дорогой director call.

Prompt отдельно запрещает превращать «открыта панель» и «виден sidebar» в actionable facts. Пустой список facts объявлен корректным ответом.

Пользовательский эффект: меньше карточек, которые просто описывают экран.

### Шаг 3 — interruption budget резервируется до дорогого решения

Omi проверяет master toggle, frequency, paywall, cooldown, rolling daily budget, duplicate delivery и availability поверхности. Начатая попытка получает durable row; crash/abandoned attempt позже переводится в terminal failure.

Пользовательский эффект: один chatty assistant не должен бесконечно перебивать, а generated и actually delivered не смешиваются.

### Шаг 4 — один director выбирает один исход

Новый director возвращает один тип:

```text
suggest | insight | task_candidate | resurface | silence
```

Prompt начинается с причин молчания и требует, чтобы карточка либо отвечала на вопрос, который пользователь пишет, либо меняла его следующий шаг. Она обязана называть конкретный referent и иметь supplied refs.

Пользовательский эффект: разные specialists перестают конкурировать за внимание напрямую.

### Шаг 5 — при необходимости выполняется один поиск

Director может запросить один lookup. Полученные items имеют namespace refs; второй director call видит только этот bounded context. Повторного lookup loop нет.

Пользовательский эффект: агент связывает текущую работу с памятью, но не зависает в бесконечном исследовании.

### Шаг 6 — код проверяет grounding и freshness

Omi фильтрует model-returned refs по реально переданному allowlist, проверяет owner и visit freshness после async boundaries, отделяет model decision от policy approval и presentation.

Пользовательский эффект: model confidence сам по себе не является разрешением перебить пользователя.

### Шаг 7 — карточка становится частью чата

Карточка отображается в floating bar, целиком кликабельна и записывается как assistant turn в main chat journal. Следующий typed/voice вопрос в том же process lifetime получает эту карточку как untrusted provenance context. Полная generic context-to-thread identity пока не является одной durable сущностью после restart.

Пользовательский эффект: notification — начало agent flow, а не одноразовый toast.

### Шаг 8 — новый и legacy paths сосуществуют

`ContextBucketsFeature` включает новый director для dev/beta и оставляет stable на fallback assistants; отдельные Insight, Suggestion, Memory и Task assistants также остаются в дереве продукта. Это разумная rollout стратегия, но не конечная информационная архитектура.

Пользовательский риск: одинаковая настройка Omi может давать разные стандарты решения и continuity в разных каналах/сборках. MetaWhisp должен использовать shadow/rollback, но после dogfood оставить один user-visible delivery owner.

## 4. Сравнение Omi и MetaWhisp сегодня

| Пользовательское ожидание | Omi public current | MetaWhisp current | Что ощущает пользователь MetaWhisp |
|---|---|---|---|
| Один эпизод текущего окна | Visit + generation/fence | `ScreenContext` без visit/generation | Нельзя доказать, что совет про текущий экран |
| Изменение внутри стабильного title | event/change path с fallback refresh | capture только при raw app/title change | Новое сообщение/ошибка может не анализироваться |
| Конкретное focused window/display | контекстная identity и captured frame | первый display, front-app windows | Второй монитор/два окна легко перепутать |
| Факты отдельно от описания | summary + validated facts | плоский OCR; batch prompt смешивает observation/task/memory | Агент пересказывает экран и смешивает ответственности |
| Один финальный decision maker | context director | Reactor, Proactive, Extractor, Promotion решают отдельно | Дубли и разные стандарты качества |
| Молчание как нормальный outcome | explicit `silence`/`no_advice` | filters есть, но общего outcome/reason нет | Нельзя измерить, где агент правильно промолчал |
| Grounded user-visible claim | entry/fact/retrieved allowlists | search/read факт есть, claim-source binding нет | «Почему это?» не имеет проверяемого ответа |
| Bounded retrieval | один hop в director path | Chat умеет search; proactive investigator может делать длинный loop | Proactive медленный и оторван от Chat tools |
| Delivery truth | durable attempt/model/policy/delivered states | шестисекундный in-memory popup | Generated легко принять за показанное; карточка теряется |
| Notification -> same chat | card journaled; nearby typed/voice follow-up gets provenance, but full generic context link is process-memory and incomplete after restart | string listener без emitter/source; proactive `onTap:nil` | Клик не продолжает помощь вообще |
| Typed/voice continuity | оба могут получить recent card context | fresh screen главным образом для voice; typed использует иной context | Один агент кажется двумя разными |
| Task candidate lifecycle | Omi развивается к candidate/workstream state, но legacy promotion тоже существует | staged -> silent promotion примерно до 5 active | Пользователь может получить задачу без подтверждения |
| Frequency/pacing | общий frequency/cooldown/daily budget | несколько cooldown/interval settings | Непонятно, как сделать агента тише |
| Work history | visit/bucket/workstream строятся вокруг общей identity | hourly extractor заново группирует app + 5 min | Daily analysis и realtime могут говорить о разном |
| Privacy source policy | есть filters, но публичная issue history показывает риск рассинхронизации | empty whitelist фактически capture-all; copy не отражает cloud OCR | Нельзя уверенно понять границу наблюдения |
| Quality evolution | prompts содержат benchmark evidence и versioning; есть test runners | нет full replay harness | Prompt меняется «по ощущениям» |

## 5. Почему MetaWhisp сейчас «не работает как Omi»

### Причина 1 — пять мозгов вместо одного агента

Текущая цепочка MetaWhisp:

```text
ScreenContextService
  -> RealtimeScreenReactor
  -> ProactiveContextService / InsightInvestigator

Отдельно:
  -> hourly ScreenExtractor
  -> TaskPrioritization
  -> TaskPromotion
  -> MetaChat RAG/tool loop
```

Каждый контур по-своему решает, что является фактом, задачей, insight и успехом. Пользователь не видит общую сущность «вот один эпизод, одно решение и одно продолжение».

### Причина 2 — система не знает, какой экран остается актуальным

MetaWhisp стартует анализ по app/title, теряет новые контексты, пока предыдущий run занят, и не несет generation token через все awaits. Значит, даже хороший prompt отвечает на слабую постановку: «вот OCR, возможно уже не текущий».

### Причина 3 — prompt просит доказать то, чего вход не содержит

Realtime task prompt пытается различать left/right chat bubbles, но OCR уже потерял geometry. Model вынуждена угадывать автора/адресата. Уверенный JSON не превращает догадку в визуальное доказательство.

### Причина 4 — search используется как ритуал, а не как доказательство

`InsightInvestigator` требует search и full read, но финальный claim не обязан ссылаться на конкретный record/quote. Формально агент «исследовал», но пользовательский вывод может быть из другой части контекста.

### Причина 5 — карточка не является продуктовым объектом

`MWNotification` содержит title/body/closure. У нее нет run, visit, evidence, thread, delivery outcome или feedback identity. После timeout/restart пользователь не может восстановить карточку и задать вопрос о ней.

### Причина 6 — агент умеет действовать, но proactive path не подключен к нему

Существующий MetaChat уже имеет read tools, bounded loop, mutation confirmation, audit, receipts и undo. Однако proactive insight не становится MetaChat turn. Создание еще одного агента усугубило бы проблему; нужно подать карточку в уже существующий runtime.

### Причина 7 — work analysis строит другую реальность

Hourly `ScreenExtractor` заново объединяет контексты по app и пяти минутам, использует несовместимую индексацию и может продвинуть checkpoint после save failure. Это не «долгая память realtime агента», а параллельный анализатор с другими правилами.

## 6. Что именно стоит перенять у Omi

### 6.1. Перенять state transitions

1. `ContextVisit` с immutable ID и generation.
2. Отдельные observation/fact candidates.
3. Один director с `silence` как первым классом результата.
4. Runtime-issued evidence refs и allowlist validation.
5. Не более одного bounded retrieval hop.
6. Durable delivery lifecycle до popup.
7. Notification как canonical chat turn.
8. Typed/voice follow-up с frozen provenance.
9. Общий pacing budget и recent-delivery dedup.
10. Replay, versioned prompts и human-reviewed dogfood.

### 6.2. Перенять prompt shape, не текст

Хороший порядок prompt:

```text
1. Объявить screen/history content недоверенными данными.
2. Сначала перечислить причины молчания.
3. Разделить «видимое описание» и «изменяющий действие факт».
4. Выбрать один typed decision.
5. Назвать конкретный referent в title и body.
6. Вернуть только supplied evidence IDs.
7. Не заявлять об исполненном действии без receipt.
```

Промт не должен отвечать за privacy, freshness, owner scope, quote membership, dedup budget или idempotency. Это code gates.

### 6.3. Перенять notification-to-agent continuity

Target MetaWhisp:

```text
ScreenAgentItem persisted
  -> popup preview
  -> MetaChat Inbox
  -> openOrCreate ScreenAgentThread
  -> original visit/evidence injected as frozen untrusted context
  -> existing MetaChat tools
  -> confirm/cancel/fail/success/undo receipt
```

Не передавать только строку и не auto-submit вопрос от имени пользователя.

## 7. Что у Omi не стоит копировать буквально

### 7.1. Screenshot/history privacy model

Omi умеет загружать и хранить screenshots для Rewind/vision. В публичном issue tracker был зафиксирован класс риска, когда Rewind exclusions и proactive upload exclusions расходились. Для MetaWhisp безопаснее один общий fail-closed privacy gate до capture/upload и ephemeral image only. Источник: [Omi issue #7098](https://github.com/BasedHardware/omi/issues/7098).

### 7.2. Длинный SQL + vision agent loop

Legacy Insight допускает до семи text investigation iterations и до пяти visual/cross-reference iterations с длинными timeouts. Это может давать сильный research result, но не укладывается в своевременную подсказку. MetaWhisp MVP ограничивает proactive одним search + одним exact read и общим deadline.

### 7.3. Model confidence как threshold

Legacy Omi фильтрует advice по self-reported confidence. В MetaWhisp confidence можно использовать для ranking, но не для safety/delivery разрешения.

### 7.4. Prompt, который считает совет AI чужим запросом

Omi task prompt допускает AI assistant как «someone», который предложил пользователю действие. Это увеличивает recall, но рискует превращать рекомендации ChatGPT/Claude в личные commitments. MetaWhisp должен требовать явное принятие пользователем.

### 7.5. Недавний ушедший контекст как допустимый

Новый Omi director считает завершенный visit свежим до 60 секунд и разрешает показать self-contained banner после переключения. Это осознанный recall/latency trade-off. Для MetaWhisp стартовый контракт строже: смена окна отменяет показ. Позже можно отдельно протестировать режим `recent but labelled`, но нельзя молча размыть zero-stale gate.

### 7.6. Balanced/default-on миграцию без собственного consent proof

Текущий Omi содержит migration к Balanced frequency. MetaWhisp не должен автоматически включать новый cloud/visual/capture scope существующим пользователям. Сначала opt-in upgrade card и явная сверка старых разрешений.

### 7.7. Автономное внешнее исполнение в первом релизе

Omi уже расширяет desktop agent до file/screen/search actions. MetaWhisp должен сначала доказать read -> suggest -> confirm internal mutation. Email/DM/browser/file/shell control требуют отдельной permission и receipt архитектуры.

### 7.8. Параллельные legacy и new user-visible paths как постоянную архитектуру

Feature flag, beta bundle и rollback adapter нужны при миграции. Но после доказанного cutover MetaWhisp не должен годами оставлять Reactor, Proactive, batch extractor и новый Director равноправными отправителями карточек. Rollback может переключить владельца; одновременно показывать от двух владельцев нельзя.

## 8. Целевой пользовательский flow MetaWhisp

### Первый запуск

1. Пользователь сначала успешно проверяет диктовку.
2. Видит короткий synthetic пример ценности Screen Agent.
3. Выбирает разрешенные apps.
4. Отдельно выбирает text-cloud и visual-image processing.
5. Дает macOS Screen Recording permission или нажимает `Not now`.
6. Выполняет безопасный test capture.

### Фоновая работа

1. Focused window открывает visit.
2. После 750 ms settle принимается frame; 3-second probe ловит stable-title changes.
3. Privacy/freshness gates разрешают analysis.
4. Specialists возвращают typed candidates.
5. Director выбирает `silence` или один item.
6. Validator проверяет evidence, referent, owner, dedup и deadline.
7. Item сначала сохраняется, затем delivery recheck решает, показывать ли popup.
8. Popup не крадет focus; item остается в MetaChat Inbox.

### Продолжение

1. Пользователь открывает карточку из popup или Inbox.
2. MetaChat открывает тот же thread и original frozen context.
3. `Why this?` показывает source/evidence, а не chain-of-thought.
4. `Look at current screen` — отдельное явное действие.
5. Task/complete/memory action проходит edit + confirmation.
6. Пользователь получает persisted receipt или честную ошибку/undo.

### Анализ работы

1. Hourly/daily analysis читает те же canonical visits.
2. Отличает activity, progress evidence, open loop и confirmed action.
3. Показывает capture gaps и excluded intervals.
4. Не выставляет moralizing productivity score.

## 9. User stories и программа реализации

| User story | Ценность | Итерация |
|---|---|---|
| Как пользователь, я хочу, чтобы качество измерялось до prompt tuning | Изменение можно сравнить, а не оценивать по одному красивому примеру | `ITER-064` |
| Я хочу подсказку только от актуального focused window | Нет поздней помощи из закрытого окна | `ITER-065` |
| Я хочу один конкретный доказанный комментарий или тишину | Меньше шума и выдумок | `ITER-066` |
| Я хочу найти карточку после timeout/restart | Подсказка становится durable value | `ITER-067` |
| Я хочу продолжить карточку в том же агенте и подтвердить действие | Не надо пересказывать; нет самовольных mutations | `ITER-068` |
| Я хочу visual understanding и одну связь с памятью только с consent | Агент понимает UI, не изображает зрение из OCR | `ITER-069` |
| Я хочу объяснить ошибку и управлять частотой | Агент обучается правильному классу проблемы | `ITER-070` |
| Я хочу честно понять, над чем работал и что осталось | Daily analysis совпадает с realtime reality | `ITER-071` |
| Я хочу понятную настройку, status и безопасный upgrade | Доверие и контролируемый rollout | `ITER-072` |

## 10. Prompt architecture MetaWhisp

### Prompt 1 — Observation

Описывает наблюдаемые факты, не советует и не создает задачи.

Output:

```json
{
  "decision": "observed|empty|blocked|failed",
  "facts": [
    {
      "kind": "commitment|request|deadline|blocker|failure|decision|changed_state",
      "statement": "...",
      "evidence_refs": ["runtime-id"]
    }
  ]
}
```

### Prompt 2 — Commitment specialist

Ищет только явное принятие пользователем, прямой неотвеченный запрос ему или доказанное выполнение существующей задачи. `assignee=unknown/other` всегда означает no task.

### Prompt 3 — Retrieval router

Выбирает один read scope и возвращает источники. Не пишет ответ и не имеет mutation tools.

### Prompt 4 — Director/composer

Получает только validated candidates/sources; возвращает один `silence|suggestion|taskProposal|taskCompletionProposal|resurface` и evidence refs.

### Prompt 5 — Critic

Может оценить specificity/actionability/novelty/tone, но final allow/block остается deterministic. Privacy, stale, evidence, owner, mutation и deadline не передаются на усмотрение judge-модели.

### Version contract

Каждый prompt descriptor хранит:

- prompt ID/version/hash;
- schema version;
- actual model/route;
- token/tool/deadline budgets;
- гипотезу изменения;
- baseline report;
- rollback version.

Один experiment меняет одну основную переменную: prompt, model, threshold или retrieval budget, но не все сразу.

## 11. Метрики, которые отвечают на продуктовый вопрос

### North-star для dogfood

```text
helpful reviewed presentations / all reviewed presentations
```

`generated` не входит в denominator. `unreviewed` остается unmeasured.

### Guardrail metrics

- stale presentations: 0;
- excluded/no-consent presentations or uploads: 0;
- ungrounded/wrong-owner items: 0;
- screen-derived unconfirmed mutations: 0;
- duplicate mutation receipts: 0;
- popup -> Inbox -> same thread continuity: 100%;
- evidence + named referent for each presented item: 100%;
- p95 settled-context-to-popup: <=10 seconds;
- interruption rate by pacing preset;
- repeated semantic idea rate;
- explicit `outdated` feedback count as freshness defect, not taste.

### Release sample

- 60 executable replay cases;
- >=100 eligible shadow contexts;
- >=50 actually presented and reviewed dogfood items;
- proposed usefulness >=80%;
- full named signed-app scenario matrix;
- explicit owner decision `live | opt-in only | hold`.

## 12. Product priority and sequencing

### Must-have before any new prompt/UI

1. Replay contracts.
2. Visit/generation/freshness.
3. Evidence allowlist.
4. One director.

### Must-have before user-visible dogfood

5. Durable delivery/item.
6. Inbox and same-thread chat.
7. Explicit task confirmation/receipts.

### Value expansion after trust is proven

8. Visual mode and bounded retrieval.
9. Feedback/dedup/pacing.
10. Canonical work analysis.
11. Onboarding/settings/rollout.

### Что не делать первым

- не переписывать диктовку;
- не менять модель «на более умную» без baseline;
- не копировать Omi prompt целиком;
- не добавлять новый agent/chat service;
- не делать permanent screenshots ради visual mode;
- не строить красивые карточки до durable identity;
- не включать всем до shadow и dogfood.

## 13. Итоговая продуктовая рекомендация

MetaWhisp не нужно становиться клоном Omi. Ему нужно забрать наиболее ценный принцип Omi — **notification является продолжением накопленного контекста и первым ходом агента** — и совместить его с более строгой local-first/private моделью MetaWhisp.

Правильный первый релиз очень узкий:

> MetaWhisp видит один разрешенный актуальный контекст, обычно молчит, иногда показывает одну доказанную карточку, сохраняет ее в Inbox и продолжает в существующем MetaChat; любые изменения данных происходят только после подтверждения.

Если этот loop не доказан, добавление более длинных prompts, большей памяти, vision и autonomous tools лишь увеличит количество убедительных ошибок. Если доказан — те же visit, evidence, delivery и thread contracts становятся фундаментом для более сильного work analysis и будущих действий.

## 14. Основные публичные источники Omi

- Product/download claim: [Omi Desktop](https://www.omi.me/pages/download).
- Repository positioning: [BasedHardware/omi](https://github.com/BasedHardware/omi).
- Current visit identity: [`ContextVisitCoordinator.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/ProactiveAssistants/Core/ContextVisitCoordinator.swift).
- New director cohort/kill-switch boundary: [`ContextBucketsFeature.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/ProactiveAssistants/Core/ContextBucketsFeature.swift).
- Fact/director prompts: [`ContextBucketRollup.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/ProactiveAssistants/Core/ContextBucketRollup.swift).
- Director/retrieval/grounding/delivery: [`ContextProactivityEngine.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/ProactiveAssistants/Core/ContextProactivityEngine.swift), [`ContextDeliveryAuthority.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/ProactiveAssistants/Core/ContextDeliveryAuthority.swift).
- Notification/chat continuity: [`FloatingControlBarState.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/FloatingControlBar/FloatingControlBarState.swift), [`FloatingControlBarWindow.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/FloatingControlBar/FloatingControlBarWindow.swift), [`ChatProvider.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/Providers/ChatProvider.swift).
- Insight flow/prompts: [`InsightAssistant.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/ProactiveAssistants/Assistants/Insight/InsightAssistant.swift), [`InsightAssistantSettings.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/ProactiveAssistants/Assistants/Insight/InsightAssistantSettings.swift).
- Task extraction prompt: [`TaskAssistantSettings.swift`](https://github.com/BasedHardware/omi/blob/db024a528427e0ffaac564bff75744470ca94ac0/desktop/macos/Desktop/Sources/ProactiveAssistants/Assistants/TaskExtraction/TaskAssistantSettings.swift).
- Public privacy-boundary issue: [#7098](https://github.com/BasedHardware/omi/issues/7098).
- Public product changelog mentioning persistent notification chats and proactive insights: [Omi changelog](https://feedback.omi.me/changelog/phone-calls-bluetooth-overhaul-offline-sync-and-more).
