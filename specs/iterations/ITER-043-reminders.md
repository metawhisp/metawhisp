# ITER-043: Напоминания второго мозга {#root}

> Статус: DRAFT / на согласовании. Автор-аналитик: AI. Решает человек (см. spec://SPEC-PROTOCOL).
> Источник аудита: код на v1.3.11 + живой `~/Library/Application Support/MetaWhisp.store` (snapshot 2026-06-03).

---

## 0. TL;DR · Инварианты · Definition of Done {#top}

**Проблема одной строкой.** Подсистема задач сегодня — это «только захват»: коммитмент превращается в `TaskItem`, кидается одна плашка при создании, и больше его **никто никогда не поднимает**. Сканера просрочки во всём коде нет. Итог по живой базе: **855 задач, выполнено за всё время 8 (≈1%)**; срок проставлен у **~12%**, и почти все эти даты **уже в прошлом** (будущих ≈ 0), потому что экстрактор выкидывает прошедшие даты. Хранилище — свалка, в которую пишут и не читают.

**Что делаем.** Превращаем захват в **петлю подотчётности**: сканер находит просроченное / на-сегодня / «завис в ожидании» → throttled-напоминание доходит до пользователя (in-app + OS) с пояснением «почему» → пользователь может Complete / Snooze / Dismiss прямо из напоминания → утренний/вечерний дайджест ведёт с обязательств, а не со счётчиков.

### 0.1 Инварианты (нарушать нельзя) {#top.invariants}

- **I1 — Никакого флуда на холодном старте.** На момент включения в базе уже ~105 просроченных + сотни «бессрочных» задач. Бэкфилл **молчаливый**: существующие задачи НЕ пушатся поштучно; вместо этого одна обзорная карточка «у тебя N открытых, X просрочено — разобрать?». Пуш-кадэнс начинается только с НОВЫХ коммитментов и тех, с которыми пользователь повзаимодействовал.
- **I2 — Жёсткий потолок пушей/день** (`reminderMaxPushPerDay`, дефолт 3). Переполнение уходит в дайджест, не в баннеры.
- **I3 — Тихие часы соблюдаются** (`reminderQuietHours*`): в тихое окно пуши не шлём, копим до утреннего дайджеста.
- **I4 — Никогда не дёргаем** completed / dismissed / staged / snoozed (до `snoozedUntil`) задачу.
- **I5 — Каждое напоминание объясняет себя** («просрочено 3 дня», «обещал Sam 2 мая», «30 дней без движения»). Без «почему» карточку не показываем.
- **I6 — Скан идемпотентен.** Повторный тик в тот же день не пере-нудит уже нуднутое (`nextNudgeAt`/`lastNudgedAt`).
- **I7 — Только аддитивные Optional-поля** на `TaskItem` → бесплатная lightweight-миграция SwiftData без versioning-плана (паттерн `TaskItem.swift:40-43`). Никаких удалений/переименований колонок.
- **I8 — Один рубильник.** `remindersEnabled=false` полностью глушит фичу (скан no-op, пуши не шлются), поля остаются. Откат мгновенный.

### 0.2 Definition of Done (верхнеуровнево) {#top.dod}

1. Все user stories §4 закрыты по своим критериям приёмки.
2. Ядро движка (`ReminderEngine`) — чистая функция, покрыта ≥30 unit-тестами (зелёные), включая все corner-cases §8.
3. Бэкфилл проверен на **копии** живого стора (≥800 задач) — флуда нет, одна обзорная карточка (инвариант I1).
4. `swift build` + `swift test` зелёные, линт проходит. Нет TODO-заглушек.
5. Проверено запуском: новый просроченный коммитмент → пуш в течение скан-интервала с корректным «почему»; Snooze убирает его до `snoozedUntil`; Complete закрывает.

---

## 1. Контекст и проблема {#problem}

### 1.1 Что есть сейчас {#problem.current}

Инвентарь подсистемы (file:line):

- **Модель** `Models/TaskItem.swift:16-95` — единственная сущность коммитмента. Поля: `taskDescription`, `completed`, `dueAt?`, `assignee?` (nil = моя задача, non-nil = «ждём от кого-то»), `status?` (`committed`/`staged`/`dismissed`/nil=committed), `isDismissed`, `completedAt?`, `createdAt/updatedAt`, FK `conversationId?`/`screenContextId?`. **Нет** snooze/recurrence/nudge/priority/follow-up полей (подтверждено схемой БД и grep по `Models/`).
- **Экстракция** `Services/Intelligence/TaskExtractor.swift` — голос/беседа → задачи на закрытии беседы; ownership A/B/C; **прошедшие due-даты выкидываются** (`:519-522`); на вставку → `NotificationService.postNewTask`.
- **Уведомления** `Services/System/NotificationService.swift` — всё уходит во внутренний `MWNotificationStack` (top-right, max 4). `hasPermission` всегда true, `requestPermission` — **no-op** (`:28-32`). Постеры: `postNewTask` (DND во время записи — **дропается, не откладывается**, `:42-45`), `postCallDetected`, `postMeetingAutoStopped`, `postAdvice` (1/мин). **Нет** `postReminder`/`postOverdue`/`postDigest`. `MWNotification.Kind` (`Views/Notifications/MWNotification.swift:40`) не имеет `.reminder`.
- **Проактив** `ProactiveContextService.swift` — триггерится от **screen-OCR**, не от списка задач; `AdviceService` «coach mode» заявляет commitment-tracking, но в контекст кладёт только memories + 5 кадров экрана + 3 транскрипта — `TaskItem`/`dueAt` не читает.
- **Дайджесты** `DailySummaryService.swift` (22:00, единственный реальный OS-баннер в приложении, `:495-513`) считает `tasksCreated/Completed`, но **не перечисляет открытые/просроченные обязательства**. `WeeklyPatternDetector.swift` — темы/люди/петли, задачи только как плоский контекст.
- **UI** `Views/Windows/TasksView.swift` — бейдж «OVERDUE/TODAY» (`:369-381`) **без действия**; `DashboardView.swift:1147-1183` — пассивная карточка «Tomorrow» (запрашивает завтра + бессрочные, **никогда сегодня/просрочку**).
- **Флаги** `Models/AppSettings.swift`: ON по дефолту только `tasksEnabled`, `dailySummaryEnabled`. Всё проактивное (`proactiveEnabled`, `adviceEnabled`, `weeklyPatternsEnabled`, `realtimeScreenReactionEnabled`) — OFF.

### 1.2 Живые данные (snapshot 2026-06-03, read-only копия стора) {#problem.data}

| Метрика | Значение |
|---|---|
| Всего задач | **855** |
| По статусу | committed 377 · staged 302 · dismissed 96 · null(=committed) 80 |
| Выполнено за всё время | **8 (≈1%)** |
| Открытых committed | ~383 |
| — со сроком (`dueAt`) | **~12% всех / ~3.7% открытых** |
| — без срока | **~96% открытых** |
| Просрочено и открыто | ~14; **будущих дат ≈ 0** |
| Возраст открытых | старейшая 45 дней; ~80 задач 30–60 дней без движения |
| Ownership (открытые) | мои ~360 · «ждём от кого-то» ~23 |

Числа — агрегатные; персональные тексты задач/имена в спеку не выносим.

### 1.3 Корневые причины «плохо работает» (ранжировано) {#problem.root}

1. **Нет скана просрочки нигде.** Ни один `FetchDescriptor<TaskItem>` не фильтрует `dueAt < now` внутри таймера. Прошедший срок = ноль выхода.
2. **Напоминания только pull.** Просрочка всплывает лишь когда сам откроешь чат (`ChatService.swift:1421`). Push-пути нет (`NotificationService` без overdue-постера; `Kind` без `.reminder`).
3. **Сроки почти не захватываются** (3.7%), и прошедшие **выкидываются** (`TaskExtractor.swift:519-522`) → даже будь скан, ему не на что срабатывать.
4. **Нет lifecycle-полей** (snooze/nudge/recurrence/priority) → нечем троттлить, откладывать, повторять.
5. **Проактив завязан на экран, не на задачи** → «ты обещал X» не сработает, если X не в последних 3 транскриптах.
6. **1% выполнения** → склад пишется и не читается; без воскрешения объём просто раздувает непрочитанную кучу.
7. **Дайджесты не ведут с обязательств** (только счётчики).
8. **DND без catch-up** — что всплыло во время записи, теряется навсегда (`NotificationService.swift:42-45`).

Вывод: **переиспользуем модель и экстракцию задач; всю петлю воскрешения (скан, push-постеры, `.reminder`-kind, lifecycle-поля, дайджест обязательств) надо построить — её нет.**

---

## 2. Цель и объём {#scope}

### 2.1 Что считаем «напоминанием второго мозга» {#scope.definition}

Система, которая **сама** удерживает обязательства пользователя во времени: ловит коммитмент с владельцем и сроком, периодически сканирует, что просрочено / на сегодня / зависло, и **проактивно (push)** возвращает это — дозированно, с пояснением и возможностью действовать в один тап — плюс ведёт с обязательств в утреннем/вечернем дайджесте. Принцип second brain: «brains are for having ideas, not storing them» — выгрузить удержание дедлайнов из головы пользователя в систему.

### 2.2 In scope — V1 {#scope.in}

- Захват срока: перестать выкидывать прошедшие даты; распознавать мягкие окна («к следующей неделе» → +7д).
- `ReminderEngine` — чистое ядро: классификация (dated / waiting-on / stale-no-date) + eligibility + throttle/backoff + snooze + quiet-hours + потолок/день.
- `ReminderScanService` — таймер + catch-up на запуске + **молчаливый бэкфилл** (I1).
- Доставка: in-app `.reminder`-карточка с действиями Complete/Snooze/Dismiss/Open + строка «почему»; OS-уведомление (UN) для дайджеста и когда пользователь away/idle (+ реальный permission).
- Дайджест: утренний бриф + секция «открытые/просроченные обязательства» в вечернем DailySummary.
- UI: «Today & Overdue» вместо пассивной «Tomorrow»-карточки; кнопка Snooze в TasksView; обзорный экран для бэкфилл-кучи.
- Новые настройки + дефолты; рубильник `remindersEnabled`.

### 2.3 Out of scope — следующие фазы {#scope.out}

- **Recurrence** (daily/weekdays/weekly/biweekly/monthly) — заложено в spec://BACKLOG, поле добавим в фазе 2. В V1 не реализуем.
- **Приоритизация важности** через LLM (ranking какой коммитмент важнее) — V1 сортирует по сроку/возрасту, поле `priority?` зарезервировано.
- **Agent-on-task** (tmux, spec://BACKLOG) — вне темы.
- **Связывание людей** (Person-entity, spec://iterations/ITER-042) — `assignee` остаётся строкой; «ждём от Sam» работает на строковом совпадении.

---

## 3. Продуктовые решения {#decisions}

Зафиксированы рекомендованные значения; человек может оспорить (REVIEW-маркер по протоколу).

- **D1 — Канал доставки: in-app + OS, не только in-app.** Обоснование: ITER-026 справедливо выпилил OS-баннеры для эфемерных карточек («сразу или никогда»). Но **смысл напоминания — дойти, даже когда ты не смотришь**. Поэтому: foreground-канал = in-app `.reminder`-карточка (единый стиль ITER-026); persist/away-канал = реальный `UNUserNotificationCenter` для (а) дайджеста и (б) напоминаний, когда главное окно не в фокусе / пользователь idle → попадает в Notification Center и не теряется. Узко реверсит ITER-026 только для reminders/digest.
- **D2 — Дефолт ON.** `remindersEnabled = true`. Это ядро ценности; безопасно из-за I1–I3 (молчаливый бэкфилл + потолок + тихие часы). _(Решение человека: ок ON или хотим opt-in?)_
- **D3 — Холодный старт: молчаливый бэкфилл + обзор + потолок** (I1, I2). Без этого фича «плохо работает» в первую же секунду (100+ баннеров).
- **D4 — Stale-no-date → только дайджест, без push.** 96% задач без срока; пушить по возрасту = нудить над переловленным мусором. «Моя задача, без срока, N дней без движения» идёт в дайджест («разобрать кучу»), не в баннер.
- **D5 — Кадэнс.** Утренний дайджест 9:00; вечерний = существующий DailySummary 22:00. Backoff просрочки: +1д → +3д → +7д → далее еженедельно (на задачу), сбрасывается при Snooze/действии. Тихие часы 22:00–9:00. Потолок 3 пуша/день.

---

## 4. User stories + критерии приёмки {#stories}

Формат: **As/I want/so that** + Given/When/Then.

- **US1 — Просрочка пушится.** _Как пользователь, хочу получать напоминание, когда мой коммитмент просрочен, чтобы молча его не уронить._
  AC: Given задача `committed`, `!completed`, `dueAt < now`, не snoozed, лимит дня не исчерпан, не тихие часы → When скан тикает → Then ровно одно `.reminder`-напоминание с текстом + «просрочено N дн», и `lastNudgedAt=now`, `nextNudgeAt` по backoff. Повторный тик в тот же день — НЕ пушит (I6).
- **US2 — Утренний бриф.** _…хочу утром видеть, что на сегодня + просрочено + зависло в ожидании, чтобы начать день со списка обязательств._
  AC: Given `reminderMorningDigestEnabled`, наступил `reminderMorningDigestHour` → Then один дайджест-итог: «Сегодня: …», «Просрочено: …», «Ждёшь от других: …», ведёт с обязательств (не счётчиков). Если нечего — не шлём.
- **US3 — Действие в один тап.** _…хочу Snooze/Complete/Dismiss прямо из напоминания, чтобы оно перестало нудить или закрылось._
  AC: Given показано напоминание → When Snooze(1д/до завтра/неделя) → Then `snoozedUntil` выставлен, до него задача не появляется. Complete → `completed=true,completedAt=now`. Dismiss → `status="dismissed"`. Действия доступны и в in-app карточке, и в OS-уведомлении (UN actions).
- **US4 — Прозрачность.** _…хочу, чтобы каждое напоминание объясняло, почему я его вижу, чтобы доверять системе._
  AC: каждое напоминание содержит «почему» из модели: просрочка N дн / «обещал {assignee} {дата}» / «N дней без движения». (Инвариант I5.)
- **US5 — Без флуда.** _…не хочу быть завален напоминаниями (холодный старт, лимит, тихие часы), чтобы фича оставалась пригодной._
  AC: на первом запуске с фичей при ≥800 существующих задач — **0 поштучных пушей**, одна обзорная карточка. В обычном режиме ≤ `reminderMaxPushPerDay` пушей/сутки; переполнение → дайджест. В тихие часы пушей нет.
- **US6 — Follow-up по «ждём от других».** _…когда кто-то мне что-то должен и тишина, хочу пинок напомнить._
  AC: Given задача с `assignee!=nil`, `!completed`, без движения ≥ `reminderWaitingOnDays` → Then напоминание «напиши {assignee} про {задача}».
- **US7 — Дойти, когда я не смотрю.** _…хочу, чтобы напоминание дошло, даже если окно не в фокусе или я отошёл._
  AC: Given главное окно не frontmost / пользователь idle / дайджест → Then помимо in-app карточки шлётся OS-уведомление (если permission выдан), оседает в Notification Center. Permission запрашивается по-настоящему (не no-op). Permission denied → graceful fallback на in-app только.
- **US8 — Сроки реально захватываются.** _…хочу, чтобы мои произнесённые дедлайны (включая «к следующей неделе») сохранялись, чтобы напоминаниям было на что срабатывать._
  AC: «купить до пятницы», «к следующей неделе», «завтra», «к концу дня» → `dueAt` проставлен (мягкие окна → `dueIsApproximate=true`). Прошедшая дата **сохраняется** и помечает задачу просроченной (не выкидывается).

---

## 5. Функциональные требования {#functional}

### 5.1 Жизненный цикл и классификация {#functional.lifecycle}

Eligible-к-напоминанию = `effectiveStatus=="committed" && !completed && !isDismissed && (snoozedUntil==nil || snoozedUntil<=now)`.

Класс:
- **DATED** — `dueAt!=nil`. Триггеры: due-today (утром в день срока); overdue (со следующего дня после `dueAt`, далее backoff D5). **push**.
- **WAITING_ON** — `assignee!=nil`, без движения ≥ `reminderWaitingOnDays`. Триггер «follow up». **push**.
- **STALE_NO_DATE** — `isMyTask && dueAt==nil && (now-updatedAt) ≥ reminderStaleDays·дней`. **только дайджест** (D4), без push.

### 5.2 Захват срока (изменения в экстракторе) {#functional.duecapture}

`spec://iterations/ITER-043#functional.duecapture` меняет `TaskExtractor`:
1. **Не выкидывать прошедшие даты** (убрать дроп `:519-522`): хранить `dueAt`, задача станет overdue естественно.
2. **Мягкие окна** в промпте парсинга срока: «к следующей неделе»→+7д, «на этой неделе»→ближайшая пятница, «завтра»→+1д, «к концу дня»→сегодня 18:00, «к концу месяца»→последний день месяца. Якорь относительных дат — таймстемп беседы.
3. Новое поле `dueIsApproximate: Bool?` (true для мягких окон → UI/почему показывает «≈»).

### 5.3 Движок напоминаний — чистое ядро {#functional.engine}

`ReminderEngine.events(tasks:[TaskInput], now:Date, settings:ReminderSettings, calendar:Calendar) -> [ReminderEvent]` — **чистая функция** (детерминированная, без I/O, без `Date()` внутри — `now` инжектится), по паттерну тестируемых `TaskExtractionFilters`/`TaskHygiene`.

Логика:
1. Фильтр eligibility (5.1) → класс.
2. Для DATED/WAITING_ON: годен ли к пушу сейчас = `nextNudgeAt==nil || nextNudgeAt<=now`, не тихие часы (`now` вне quiet-окна).
3. Сортировка приоритета: overdue(по убыванию дней) → due-today → waiting-on(по давности). 
4. Применить потолок `reminderMaxPushPerDay` с учётом уже отправленных сегодня (счётчик дня инжектится) → верх списка в push, остаток помечается `digestOnly`.
5. STALE_NO_DATE → всегда `digestOnly`.
6. На каждый push-`ReminderEvent` вернуть новое состояние nudge (`lastNudgedAt=now`, `nextNudgeAt=now+backoff(nudgeCount)`, `nudgeCount+1`) — **применяет сервис-обёртка**, ядро только вычисляет.

`ReminderEvent`: `{ taskId, kind: .overdue/.dueToday/.waitingOn/.staleDigest, whyText, push: Bool }`.

### 5.4 Доставка и действия {#functional.delivery}

- `MWNotification.Kind.reminder` (icon `bell.badge`, accent — отдельный) — добавить в `MWNotification.swift:40`.
- `NotificationService.postReminder(_ event:, task:)` — in-app карточка: title=задача, body=«почему», действия Complete/Snooze▾/Dismiss/Open. DND во время записи → **отложить в очередь, не дропать** (5.7).
- OS-канал (D1/US7): `UNUserNotificationCenter` + категория `MW_REMINDER` с `UNNotificationAction` Complete/Snooze. Слать при away/idle/не-frontmost и для дайджеста. Реальный `requestPermission()` (заменить no-op `NotificationService.swift:32`) + запрос в онбординге/при первом включении.
- Тап карточки/уведомления → активирует приложение, открывает Tasks/`Today & Overdue`.

### 5.5 Дайджест {#functional.digest}

- **Утро** (`reminderMorningDigestHour`, дефолт 9): новый лёгкий сервис (таймер-паттерн `DailySummaryService.startScheduler:41`). Содержимое: Сегодня · Просрочено(с возрастом) · Ждёшь-от-других-затихло · Топ stale-no-date «разобрать N». Пусто → не слать.
- **Вечер**: расширить `DailySummaryService.generate` — добавить секцию «Открытые/просроченные обязательства» (сейчас только `tasksCreated/Completed` счётчики, `:540-562`). Ведём с обязательств.

### 5.6 Прозрачность {#functional.why}

`whyText` (чистая функция от задачи+now): overdue→«просрочено N дн»; dueToday→«срок сегодня»; waitingOn→«ждёшь от {assignee} с {дата}»; stale→«N дней без движения»; `dueIsApproximate`→префикс «≈». (Инвариант I5.)

### 5.7 DND + catch-up {#functional.dnd}

Во время `meetingRecorder.isRecording` напоминания **кладём в in-memory очередь** (а не дропаем). На событие конца записи — flush: применить актуальный eligibility (могли быть закрыты) и показать с учётом потолка дня.

---

## 6. Модель данных {#model}

### 6.1 Новые поля `TaskItem` (все Optional — I7) {#model.taskitem}

```swift
var snoozedUntil: Date?       // не показывать до этого момента
var lastNudgedAt: Date?       // когда последний раз нуднули
var nextNudgeAt: Date?        // когда можно снова (backoff)
var nudgeCount: Int?          // nil == 0; для backoff-кривой
var dueIsApproximate: Bool?   // срок = мягкое окно («≈»)
var priority: Int?            // зарезервировано под сортировку дайджеста; V1 не выставляет
```

Обоснование Optional: повторяет осознанный паттерн `status` (`TaskItem.swift:40-43`) — SwiftData добавляет колонки lightweight-миграцией без versioning-плана. Сцеплено с риском spec://BACKLOG (нет VersionedSchema) — миграцию проверить на копии стора (см. §11, тест-гейт AUD-007).

### 6.2 Новые настройки `AppSettings` (стиль `@AppStorage`) {#model.settings}

```swift
@AppStorage("remindersEnabled") var remindersEnabled = true            // D2 — рубильник (I8)
@AppStorage("reminderMorningDigestEnabled") var reminderMorningDigestEnabled = true
@AppStorage("reminderMorningDigestHour") var reminderMorningDigestHour = 9
@AppStorage("reminderQuietHoursStart") var reminderQuietHoursStart = 22  // I3
@AppStorage("reminderQuietHoursEnd")   var reminderQuietHoursEnd   = 9
@AppStorage("reminderMaxPushPerDay")   var reminderMaxPushPerDay   = 3   // I2
@AppStorage("reminderStaleDays")       var reminderStaleDays       = 14  // D4
@AppStorage("reminderWaitingOnDays")   var reminderWaitingOnDays   = 4   // US6
@AppStorage("reminderOSNotifications") var reminderOSNotifications = true // D1/US7
@AppStorage("didReminderBackfill_iter043") var didReminderBackfill = false // I1, one-time guard
```

### 6.3 Миграция / бэкфилл {#model.migration}

При первом скане с `didReminderBackfill==false`: для всех eligible-задач выставить `nextNudgeAt` так, чтобы поштучные пуши **не пошли** (например `nextNudgeAt` = далеко в будущее / помечены «уже видены»), показать одну обзорную карточку (US5), затем `didReminderBackfill=true`. Дальше в кадэнс входят только новые/затронутые задачи.

---

## 7. Архитектура — где что лежит {#arch}

| Что | Где (file) | Изменение |
|---|---|---|
| Чистое ядро | `Services/Intelligence/ReminderEngine.swift` (NEW) | классификация+throttle+quiet+cap+backoff |
| Скан-сервис | `Services/Intelligence/ReminderScanService.swift` (NEW) | таймер + launch catch-up + бэкфилл + persist nudge-state |
| Поля задачи | `Models/TaskItem.swift` | +6 Optional полей (§6.1) |
| Захват срока | `Services/Intelligence/TaskExtractor.swift:354-361,510-541` | keep past dates + мягкие окна + `dueIsApproximate` |
| Постер | `Services/System/NotificationService.swift` | +`postReminder`; реальный `requestPermission`; DND→очередь+flush |
| Kind | `Views/Notifications/MWNotification.swift:40` | +`case reminder` (icon/accent/label) |
| OS-уведомления | `Services/System/NotificationService.swift` | `UNUserNotificationCenter` категория `MW_REMINDER` + actions |
| Утренний дайджест | `Services/Intelligence/MorningDigestService.swift` (NEW) | таймер-паттерн DailySummary |
| Вечерний дайджест | `Services/Intelligence/DailySummaryService.swift:540-562` | +секция «обязательства» |
| Today/Overdue UI | `Views/Windows/DashboardView.swift:1147-1183` + `TasksView.swift` | заменить «Tomorrow» на «Today&Overdue»; Snooze-действие |
| Обзор бэкфилла | `Views/Windows/TasksView.swift` | секция/экран «разобрать кучу» |
| Настройки | `Models/AppSettings.swift` | +флаги §6.2; UI в Settings |
| Wiring | `App/AppDelegate.swift` | старт `ReminderScanService`/`MorningDigestService` за `remindersEnabled` |

---

## 8. Граничные случаи {#corners}

1. Пустой список → ничего не шлём, дайджест не шлём.
2. **Холодный старт с сотнями просрочек** → молчаливый бэкфилл + 1 обзорная карточка (I1).
3. Задача закрыта/dismissed между сканом и показом → flush-проверка eligibility (5.7), не показываем.
4. Snoozed → невидима до `snoozedUntil`; ровно по истечении снова eligible.
5. Тихие часы → копим, отдаём в утренний дайджест (I3).
6. Потолок дня достигнут → остаток `digestOnly` (I2).
7. Двойной тик скана / релонч в середине дня → идемпотентность через `nextNudgeAt`/`lastNudgedAt` (I6).
8. Граница суток / таймзона → локальный `Calendar`, `weekStartsOn` уже есть.
9. Запись идёт (DND) → очередь + flush на конец (5.7), не дроп.
10. `assignee` пуст/мусор → трактуем как мою задачу (`isMyTask`).
11. Legacy `status==nil` → committed (`effectiveStatus`).
12. ~80 очень старых stale → только дайджест, не пуш (D4).
13. Дата в далёком будущем → не overdue, due-today сработает в свой день.
14. staged / 274 авто-скрытых кандидата → **никогда** не напоминаем (не committed).
15. Permission denied на OS-уведомления → in-app только, фича работает.
16. Перевод часов/смена системного времени → скан по локальному календарю, без «отрицательных» дней (clamp).
17. `remindersEnabled=false` в середине кадэнса → немедленно стоп (I8).

---

## 9. План итераций (TDD-чеклист) {#plan}

Каждая под-итерация: red→green, один логический коммит, pure-func прежде I/O. Сборку (`swift build/test`) запускаем **только по явной команде** человека.

- [ ] **043.1 — Ядро + поля.** +6 полей в `TaskItem`; `ReminderEngine` (чистая функция) + `ReminderSettings`/`ReminderEvent`/`TaskInput`. ≥30 unit-тестов (все классы, backoff, snooze, quiet, cap, бэкфилл, corner-cases §8). Поведение пользователя не меняется. _Тесты — без сборки приложения._
- [ ] **043.2 — Захват срока.** `TaskExtractor`: keep past dates + мягкие окна + `dueIsApproximate`. Юнит-тесты парс-слоя.
- [ ] **043.3 — Скан-сервис + бэкфилл + wiring.** `ReminderScanService` (таймер+catch-up), молчаливый бэкфилл (I1), persist nudge-state. AppDelegate за `remindersEnabled`.
- [ ] **043.4 — Доставка in-app.** `.reminder`-kind, `postReminder`, действия Complete/Snooze/Dismiss/Open, `whyText`.
- [ ] **043.5 — OS-уведомления.** Реальный permission, UN-категория+actions, тихие часы, DND-очередь+flush.
- [ ] **043.6 — Дайджест.** Утренний бриф + секция обязательств в вечернем DailySummary.
- [ ] **043.7 — UI.** «Today & Overdue» вместо «Tomorrow», Snooze в TasksView, экран бэкфилл-обзора, настройки.

Фаза 2 (отдельное ТЗ): recurrence, LLM-приоритизация, Person-linking для waiting-on.

---

## 10. Метрики успеха {#metrics}

- Completion rate: с ≈1% до целевого (например ≥15%) за 30 дней после включения.
- % просрочек, всплывших пользователю в течение 24ч (цель ~100% eligible в рамках потолка).
- Precision напоминаний: доля acted-on (Complete/Snooze) vs Dismiss; рост = доверие.
- Инвариант-метрика: пушей/сутки ≤ `reminderMaxPushPerDay` всегда (алерт при нарушении).
- Open-rate утреннего дайджеста.

## 11. Риски и откат {#risks}

- **Флуд** → I1 (молчаливый бэкфилл) + I2 (потолок). Главный риск, закрыт дизайном.
- **Усталость от нытья** → throttle/backoff + stale→дайджест + Snooze. 
- **Миграция SwiftData** (нет VersionedSchema, spec://BACKLOG) → поля Optional (I7); **обязательный тест на копии живого стора перед мерджем** (гейт AUD-007).
- **Трение permission** на OS-уведомления → graceful fallback на in-app (US7 AC).
- **Реверс ITER-026** для reminders → узко, задокументировано (D1), эфемерные карточки не трогаем.
- **Откат**: `remindersEnabled=false` глушит всё; поля остаются, данные целы (I8).

---

## Changelog

- [2026-06-03] §0–§11: первичная редакция ТЗ на основе аудита подсистемы (код v1.3.11 + живой стор). Статус DRAFT, ждёт решений человека по D1–D5 (§3).
