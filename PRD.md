# MetaWhisp PRD (Product Requirements Document)

## Context

MetaWhisp — нативное macOS menu bar приложение для on-device голосовой транскрипции. Пользователь нажимает глобальный хоткей, говорит, текст автоматически вставляется в любое приложение. Ядро работает локально на Apple Silicon через Metal GPU (WhisperKit/Whisper). Модель монетизации — freemium (Free: on-device, Pro: облачная транскрипция + LLM-обработка).

Проект состоит из 3 компонентов: **macOS App** (Swift 6/SwiftUI), **API** (Cloudflare Workers + D1), **Website** (Eleventy/11ty + Cloudflare Pages).

**Статус**: ЗАПУЩЕН. Есть платящие пользователи, Stripe live, подписка в App Store, Sparkle обновления работают.

---

## 1. Продукт

### 1.1 Vision
Самый быстрый и приватный способ превратить голос в текст на macOS. Нажал кнопку — сказал — текст на месте.

### 1.2 Target Audience
| Сегмент | Потребность |
|---------|------------|
| Контент-мейкеры (писатели, блогеры, devs) | Быстро надиктовать мысли без переключения контекста |
| Удалённые работники | Заметки во время звонков/митингов |
| Полиглоты | Встроенный перевод между языками |
| Privacy-ориентированные | Никакого облака для базовой транскрипции |
| Productivity-энтузиасты | Аналитика сэкономленного времени |

### 1.3 Платформа & Требования
- macOS 14+ (Sonoma)
- Apple Silicon (M1+)
- ~50 MB приложение + 40-950 MB модель
- Дистрибуция: .dmg (прямая загрузка) + нотаризация

---

## 2. Функциональные требования

### 2.1 Транскрипция ✅
| Требование | Статус | Детали |
|-----------|--------|--------|
| On-device транскрипция (WhisperKit) | ✅ | 5 моделей: Tiny→Large V3 Turbo, Metal GPU |
| Cloud транскрипция (Groq/OpenAI) | ✅ | Pro-only, серверный прокси |
| 30+ языков с автодетекцией | ✅ | 11 основных языков в UI |
| Фильтр галлюцинаций | ✅ | Toxic tokens, паттерны YouTube, dedup, тишина |
| Детекция тишины (skip пустых записей) | ✅ | RMS < 0.001 → discard |
| Pre-warm аудио движка | ✅ | Устраняет ~150ms cold start |

### 2.2 Глобальные хоткеи ✅
| Требование | Статус | Детали |
|-----------|--------|--------|
| Right ⌘ — запись/стоп | ✅ | Toggle + Push-to-Talk режимы |
| Right ⌥ (tap) — запись + перевод | ✅ | < 0.4s = translate mode |
| Right ⌥ (hold 1.5s) — перевод выделенного | ✅ | Accessibility API |
| Debounce быстрых нажатий | ✅ | 30ms cooldown |

### 2.3 Обработка текста ✅
| Требование | Статус | Детали |
|-----------|--------|--------|
| Raw mode (дословно) | ✅ | Без обработки |
| Clean mode (убрать паразиты) | ✅ | Локальный regex, без API |
| Structured mode (LLM-полировка) | ✅ | GPT-4o-mini / Cerebras Qwen-3 |
| Авто-вставка текста (Cmd+V) | ✅ | Accessibility API + CGEvent |
| Text style (Pro): lowercase, no period, no caps | ✅ | Настройки в Settings |

### 2.4 Перевод ✅
| Требование | Статус | Детали |
|-----------|--------|--------|
| Голосовой перевод | ✅ | Запись → транскрипция → перевод |
| Перевод выделенного текста | ✅ | SelectionTranslator |
| Автоопределение направления | ✅ | Кириллица ↔ Латиница |
| 11 целевых языков | ✅ | EN, RU, ES, FR, DE, ZH, JA, KO, PT, IT, UK |

### 2.5 Словарь коррекций ✅
| Требование | Статус | Детали |
|-----------|--------|--------|
| Auto-learning из правок пользователя | ✅ | CorrectionMonitor → CorrectionDictionary |
| Brands (34+ встроенных) | ✅ | Google, LinkedIn, ChatGPT и т.д. |
| Snippets (текстовые шаблоны) | ✅ | "my email" → actual email |
| Fuzzy matching (Levenshtein) | ✅ | Порог 1-2 символа |
| Сохранение регистра | ✅ | HELLO→WORLD, Hello→World |
| Prompt tokens для Whisper bias | ✅ | Подсказки из словаря |

### 2.6 Dashboard & Аналитика ✅
| Требование | Статус | Детали |
|-----------|--------|--------|
| Метрики: слова, транскрипции, переводы, WPM | ✅ | |
| Сэкономленное время | ✅ | (words/30WPM×60) - (audio+processing) |
| Графики активности (день/неделя/месяц) | ✅ | ActivityChartView |
| Рекорды: streak, best day, peak words | ✅ | |
| Фильтр периодов | ✅ | All Time, Today, Week, Month |

### 2.7 UI & UX ✅
| Требование | Статус | Детали |
|-----------|--------|--------|
| Menu bar icon + popover | ✅ | 300×300, статус + последняя транскрипция |
| Главное окно (4 вкладки) | ✅ | Dashboard, History, Dictionary, Settings |
| Recording overlay (4 стиля) | ✅ | Capsule, Island Aura, Island Expand, Edge Glow |
| Onboarding (8 экранов) | ✅ | Typewriter, анимации, выбор движка |
| Звуковая обратная связь | ✅ | Пресеты + кастомные звуки |
| Dark/Light/Auto тема | ✅ | DesignSystem.swift |

### 2.8 Аккаунт & Подписки ✅
| Требование | Статус | Детали |
|-----------|--------|--------|
| Google Sign-In | ✅ | JWT валидация |
| Magic Link (email) | ✅ | Resend, 20 мин expiry |
| Stripe подписки (LIVE) | ✅ | Рабочие платежи, есть подписчики |
| Monthly $7.77 / Annual $30 | ✅ | Stripe price IDs |
| Лимит минут (60/день, макс 600) | ✅ | Server-side enforcement (HTTP 429) |
| Deep link активация | ✅ | metawhisp://auth?token=... |
| Keychain хранение секретов | ✅ | |

### 2.9 Backend API ✅
| Требование | Статус | Детали |
|-----------|--------|--------|
| Auth endpoints (Google, Magic Link, Session) | ✅ | |
| Subscription CRUD | ✅ | |
| Stripe webhooks | ✅ | Signature verification |
| License verification | ✅ | machine_id binding |
| Usage tracking + enforcement | ✅ | Per-day minutes, 429 при исчерпании |
| Pro proxy (transcribe + process) | ✅ | Groq + Cerebras |
| CORS | ✅ | metawhisp.com only |

### 2.10 Website ✅
| Требование | Статус | Детали |
|-----------|--------|--------|
| Landing page (hero, features, how-it-works) | ✅ | |
| Pricing page | ✅ | |
| Account page (login/dashboard) | ✅ | |
| Download page | ✅ | |
| Privacy & Terms | ✅ | |
| SEO schema markup | ✅ | Organization, SoftwareApplication |
| Security headers (CSP, HSTS) | ✅ | |
| robots.txt, llms.txt | ✅ | |

### 2.11 Инфраструктура ✅
| Требование | Статус | Детали |
|-----------|--------|--------|
| Нотаризация (Apple Developer) | ✅ | Подписано и нотаризовано |
| Sparkle auto-updates | ✅ | appcast.xml, Ed25519 подпись |
| Code signing (hardened runtime) | ✅ | Entitlements для mic, network, JIT |

---

## 3. Возможности для развития (Growth Opportunities)

### 3.1 Высокий приоритет (P1) — ближайшие 1-2 месяца

| # | Фича | Влияние | Обоснование |
|---|------|---------|-------------|
| 1 | **Trial period** (7 дней Pro) | Конверсия | Пользователь пробует Pro → видит ценность → подписывается |
| 2 | **Blog / SEO контент** (5-10 статей) | Органический трафик | Сейчас нет входящего трафика из поиска |
| 3 | **Video demo на лендинге** | Конверсия лендинга | Показать продукт в действии за 30 сек |
| 4 | **Crash reporting** (TelemetryDeck / Sentry) | Качество | Visibility в проблемы юзеров в проде |
| 5 | **Product Hunt launch** | Awareness | Целевая аудитория там |

### 3.2 Средний приоритет (P2) — месяц 2-4

| # | Фича | Влияние |
|---|------|---------|
| 6 | Comparison pages (vs Dictation, vs Otter, vs Whisper Transcription) | SEO + позиционирование |
| 7 | Referral program | Органический рост |
| 8 | CI/CD pipeline (GitHub Actions) | Автоматизация сборки/релизов |
| 9 | Export history (CSV, Markdown) | Data portability |

### 3.3 Перспектива (P3) — месяц 4-6+

| # | Фича | Влияние |
|---|------|---------|
| 10 | iCloud sync истории | Multi-device удобство |
| 11 | Shortcuts / Automations integration | Power users |
| 12 | Custom LLM endpoints (Ollama, local) | Privacy-ориентированные юзеры |
| 13 | Streaming transcription (real-time) | UX improvement |
| 14 | App Store distribution | Расширение аудитории |
| 15 | Локализация сайта (EN/RU) | Международный рынок |
| 16 | Multiple recording profiles | Разные контексты |

---

## 4. Нефункциональные требования

### 4.1 Performance
| Метрика | Цель | Текущее |
|---------|------|---------|
| Время от нажатия до готовности записи | < 200ms | ✅ Pre-warm |
| Транскрипция 10 сек аудио (Large V3 Turbo) | < 3s | ✅ Metal GPU |
| Размер приложения (без моделей) | < 60 MB | ✅ ~50 MB |
| RAM в idle | < 100 MB | ⚠️ ~1-2 GB (WhisperKit loaded) |

### 4.2 Privacy & Security ✅
| Требование | Статус |
|-----------|--------|
| On-device транскрипция без сети | ✅ |
| API keys в Keychain | ✅ |
| Hardened runtime + нотаризация | ✅ |
| HTTPS only | ✅ |
| Webhook signature verification | ✅ |
| CSP headers на сайте | ✅ |

### 4.3 Reliability
| Требование | Статус |
|-----------|--------|
| Graceful fallback (SwiftData → in-memory) | ✅ |
| File logging (~/Library/Logs/) | ✅ |
| Error types (Transcription, Processing, Recording) | ✅ |
| Crash reporting | ❌ Пока не реализовано |

---

## 5. Архитектура

```
┌─────────────────────────────────────────────┐
│                 macOS App                     │
│                                               │
│  ┌───────────┐  ┌──────────┐  ┌───────────┐ │
│  │ HotkeyServ│→│Transcript.│→│TextProcess.│ │
│  │           │  │Coordinator│  │           │ │
│  └───────────┘  └────┬─────┘  └─────┬─────┘ │
│                      │              │        │
│           ┌──────────┴──────────┐   │        │
│           │                     │   │        │
│  ┌────────┴───┐  ┌─────────────┴┐  │        │
│  │WhisperKit  │  │CloudWhisper  │  │        │
│  │(on-device) │  │(Groq/OpenAI) │  │        │
│  └────────────┘  └──────────────┘  │        │
│                                     │        │
│  ┌─────────────┐  ┌───────────────┐│        │
│  │TextInsertion│  │CorrectionDict ││        │
│  │(Cmd+V)      │  │(auto-learn)   ││        │
│  └─────────────┘  └───────────────┘│        │
│                                     │        │
│  ┌─────────────┐  ┌───────────────┐│        │
│  │HistoryServ  │  │LicenseService ││        │
│  │(SwiftData)  │  │(Keychain)     ││        │
│  └─────────────┘  └───────┬───────┘│        │
└───────────────────────────┼────────┘
                            │
                    ┌───────▼──────────┐
                    │  Cloudflare API   │
                    │  (Workers + D1)   │
                    │                   │
                    │  Auth, License,   │
                    │  Subscriptions,   │
                    │  Pro Proxy,       │
                    │  Usage Tracking   │
                    └───────┬──────────┘
                            │
                    ┌───────▼──────────┐
                    │  Stripe, Groq,   │
                    │  Cerebras, Resend │
                    └──────────────────┘
```

### Ключевые файлы

| Компонент | Файл |
|-----------|------|
| Entry point | `App/AppDelegate.swift` |
| Оркестрация записи | `Services/System/TranscriptionCoordinator.swift` |
| On-device ML | `Services/Transcription/WhisperKitEngine.swift` |
| Cloud ML | `Services/Transcription/CloudWhisperEngine.swift` |
| Обработка текста | `Services/Processing/TextProcessor.swift` |
| Хоткеи | `Services/System/HotkeyService.swift` |
| Авто-вставка | `Services/System/TextInsertionService.swift` |
| Словарь | `Services/Processing/CorrectionDictionary.swift` |
| Лицензия | `Services/License/LicenseService.swift` |
| История | `Services/Data/HistoryService.swift` |
| API backend | `api/src/index.js` |
| DB schema | `api/schema.sql` |
| Website | `website/src/index.njk` |

---

## 6. Монетизация

### Free Tier
- On-device транскрипция (все модели)
- Raw + Clean режимы (Clean — локальный regex)
- Полная история и аналитика
- Словарь коррекций
- Все хоткеи и авто-вставка

### Pro Tier ($7.77/мес или $30/год, save 68%)
- Cloud транскрипция (быстрее, точнее)
- Structured mode (LLM-полировка)
- Перевод (голосовой + текстовый)
- Text style настройки
- 60 мин/день облачных минут (макс 600 баланс)
- Server-side enforcement (HTTP 429 при исчерпании)

### Аутентификация
- Google Sign-In (JWT)
- Magic Link (Resend email, 20 мин expiry)
- Deep link активация: `metawhisp://auth?token=...`
- Session: 30 дней, Keychain storage, machine_id binding

---

## 7. Метрики успеха (KPIs)

| Метрика | Цель (3 мес) |
|---------|-------------|
| Установки (DMG downloads) | 1,000+ |
| DAU (daily active users) | 200+ |
| Free → Pro конверсия | 5-10% |
| Retention D7 | 40%+ |
| Retention D30 | 25%+ |
| MRR | $500+ |
| NPS | 40+ |

---

## 8. Roadmap

### Phase 1: Рост (текущий, месяц 1-2)
- [ ] Trial period (7 дней Pro)
- [ ] Blog / SEO контент (5-10 статей)
- [ ] Video demo на лендинге
- [ ] Crash reporting (TelemetryDeck / Sentry)
- [ ] Product Hunt launch
- [ ] Comparison pages

### Phase 2: Масштабирование (месяц 3-4)
- [ ] Referral program
- [ ] CI/CD pipeline
- [ ] Export history
- [ ] App Store distribution

### Phase 3: Расширение (месяц 5-6+)
- [ ] iCloud sync
- [ ] Shortcuts integration
- [ ] Custom LLM endpoints
- [ ] Streaming transcription
- [ ] Локализация сайта
- [ ] Multiple recording profiles

---

## 9. Риски

| Риск | Вероятность | Влияние | Митигация |
|------|------------|---------|-----------|
| WhisperKit breaking changes | Низкая | Высокое | Pin версии, тесты |
| Groq/Cerebras downtime | Средняя | Среднее | Fallback на on-device |
| Stripe compliance | Низкая | Высокое | Корректные Terms/Privacy |
| Low conversion Free→Pro | Высокая | Высокое | Trial period, onboarding, value demo |
| RAM overhead (WhisperKit loaded) | Средняя | Среднее | Lazy load/unload моделей |

---

## 10. Вердикт

### ✅ Что ГОТОВО и работает (production)
- Полный core pipeline: запись → транскрипция → обработка → вставка
- On-device + Cloud транскрипция с usage enforcement
- 3 режима обработки (Raw/Clean/Structured)
- Перевод (голосовой + текстовый)
- Самообучающийся словарь (auto-learn + brands + snippets)
- Dashboard с аналитикой и рекордами
- Аккаунт/подписки (Google + Magic Link + Stripe LIVE)
- Backend API (auth, license, usage, proxy)
- Website с SEO, pricing, account
- Нотаризация + Sparkle auto-updates
- Платящие пользователи

### Итого
Продукт **полностью запущен и работает в production**. Все core-фичи реализованы. Фокус сейчас — на росте (trial, SEO, content marketing, Product Hunt) и качестве (crash reporting, CI/CD).
