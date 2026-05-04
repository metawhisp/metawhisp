# Roadmap — MetaWhisp as a "second brain" capture layer

Long-form vision distilled from a 2026-05-02 session. The goal: user talks
all day → MetaWhisp captures + structures → Obsidian vault stores → Claude /
any LLM tool can query the vault for context.

```
voice → MetaWhisp → SwiftData → Obsidian (markdown) ← Claude / Cursor / etc.
                                                       (any LLM tool)
```

## Phases at a glance

| Phase | Theme | Time | Status |
|---|---|---|---|
| 1 + 2 | Auto-record reliability (gate, calendar, dictation pause, manual mode, back-to-back) | shipped 2026-05-02 in 1.3.1 | ✅ |
| **3** | Voice everywhere captured (no goes-into-the-void cases) | ~2 weeks | next |
| **4** | Obsidian as universal store (every entity → md file) | ~3-4 weeks | |
| **5** | Chat = portal to second brain (universal RAG) | ~2 weeks | |
| **6** | Interop (MCP server, Obsidian plugin, webhooks) | ~3 weeks | |
| **7** | Polish + scale (mobile, search, archive tier) | ongoing | |

---

## Phase 3 — Voice everywhere captured

**Problem:** voice questions exist in the DB but aren't visible in main chat
history. Long rapid-fire dictations don't have a fast path to "save as note".

| # | Feature | What changes |
|---|---|---|
| **3.1** | Voice questions render in Chat tab | Each long-press ⌘ Q+A persists as `ChatMessage` with `source: "voice"`, displayed inline in chat. DB write already happens; just need the UI surface. |
| **3.2** | "Rapid notes" hotkey (e.g. double-tap ⌘) | Long dictation, no LLM post-processing, lands directly as note. Inbox flow. |
| **3.3** | Auto-classification of dictation | LLM tags each dictation: `task` / `memo` / `question` / `note`. Routes to correct bin automatically. User stops thinking "which hotkey for what". |
| **3.4** | Inbox tab for ambiguous captures | Anything LLM can't confidently classify → Inbox. User triages weekly. |

---

## Phase 4 — Obsidian as universal store

**Problem:** today only `MeetingObsidianWriter` exports per-meeting markdown.
Memories, tasks, goals, chat history, screen observations stay locked in
SwiftData. No way for external LLM tools to read them.

### Vault structure (proposed)

```
ObsidianVault/
└── _MetaWhisp/                         (everything created by app)
    ├── Conversations/2026-05-03 — Митинг с Машей.md
    ├── Memories/Знания/Я работаю в Selzy с 2024.md
    ├── Memories/Люди/Маша — продакт менеджер.md
    ├── Tasks/active.md                 (open tasks, sorted by due)
    ├── Tasks/archive/2026-05.md        (closed)
    ├── Goals/Daily/Стандап 9:00.md
    ├── ChatHistory/2026-05-03.md
    ├── Daily/2026-05-03.md             (aggregator — all today's captures)
    └── llms.txt                         (vault README for LLMs)
```

### Tasks

| # | Feature | Description |
|---|---|---|
| **4.1** | Conversation → md file | Title from `displayTitle`, frontmatter (calendar event, attendees, duration, source), body = transcript with `Me:`/`Them:` lines. |
| **4.2** | UserMemory → md file | Hierarchy by `kind/subject`. Linkable from other notes via Obsidian's `[[wikilinks]]`. |
| **4.3** | TaskItem → checkbox row in `active.md` | Obsidian Tasks plugin compatible (`- [ ] Send draft to Sam 📅 2026-05-10`). |
| **4.4** | Daily journal aggregator | One file per day with all captures (dictations, voice questions, completed tasks, meetings) chronological. |
| **4.5** | Bidirectional sync | File watcher in app; edit task in Obsidian → flows back to SwiftData. Check box in md → `completed=true`. |
| **4.6** | `llms.txt` vault root | Machine-readable description of structure so any LLM tool understands. |

---

## Phase 5 — Chat as portal to second brain

**Problem:** chat currently sees a few last conversations / memories /
tasks via embedding-RAG (limit 100-200). To use MetaWhisp as second brain,
chat needs to retrieve from the FULL history.

| # | Feature | Description |
|---|---|---|
| **5.1** | Universal RAG context | Embedding-based retrieval over ALL conversations / memories / tasks / goals / screen observations of all time. Top-K reranking by recency + relevance. |
| **5.2** | "Add to Obsidian" tool | In chat: "сохрани это в заметку про Х" / "создай новую заметку Y" → LLM writes md file in vault. |
| **5.3** | Schedule reminder via chat | "напомни через 2 часа купить молоко" → TaskItem with `dueAt`. (Already partial; harden.) |
| **5.4** | Streaming chat responses | Already partial via OpenAI / Cerebras streaming; finish across all paths. |
| **5.5** | Multi-modal drag-and-drop | Image / PDF / mp3 → chat ingests. PDF + audio transcribed; image OCR'd; all into RAG. |

---

## Phase 6 — Interop with other AI tools

**Problem:** Obsidian vault is a silo unless other tools can query it.

| # | Feature | Description |
|---|---|---|
| **6.1** | MCP server for MetaWhisp data | Claude Code, Cursor, Claude Desktop, Cline can query MetaWhisp via Model Context Protocol. Tool: "find meetings with Маша last month" → returns md sections from vault. |
| **6.2** | Obsidian plugin (lightweight) | Sidebar panel "Ask MetaWhisp" — answers from vault using the user's API key. No need to switch to MetaWhisp.app. |
| **6.3** | Webhook export | On every new event (conversation closed, task added, memory captured) post webhook to Make / n8n / Zapier. Build flows: meeting recap → Slack post automatically. |

---

## Phase 7 — Polish + scale (ongoing)

| # | Feature | Description |
|---|---|---|
| **7.1** | Diff-based Obsidian sync | Don't rewrite md if content unchanged; otherwise git/iCloud sync conflicts. |
| **7.2** | Privacy per-vault | Tag certain conversations / memories as `excludeFromExport`. Sensitive material stays local-only. |
| **7.3** | Background indexing tier | Conversations 60+ days old → archive mode (not in RAM, but searchable via embeddings). |
| **7.4** | iPhone capture app | The `MetaWhispPhone` repo. Voice on the move → syncs to vault. (Memory: project_iphone_app planned April 2026.) |
| **7.5** | Global search UI | Cmd-K everywhere — fuzzy match conversations, memories, tasks, file contents. |

---

## Quick wins (each ≤1 day, do anytime)

Pick from these when looking for visible progress:

1. **Voice questions in Chat tab (3.1)** — already in DB, just render.
2. **Daily.md aggregator (4.4)** — per-entity md generators exist; bundle them.
3. **"Add to Obsidian" chat tool (5.2)** — extend `ChatToolExecutor`.
4. **`llms.txt` in vault root (4.6)** — static text file describing structure.

---

## Recommended ordering

- **Month 1:** Phase 3 + Phase 4.1-4.4 (one-way export to Obsidian, no
  bidirectional yet). End state: dictate → vault → Claude can read it.
- **Month 2:** Phase 4.5 (bidirectional) + Phase 5 (chat upgrades). End
  state: edit in either app, single coherent flow.
- **Month 3:** Phase 6 (MCP / plugin) + start Phase 7.4 (mobile). End state:
  ecosystem-level integration.

---

## Open questions for product direction

- **Auto-classification confidence threshold** — at what LLM confidence do we
  put a dictation in Inbox vs auto-route? Tunable per user?
- **Obsidian path strategy** — single hardcoded vault or user-pickable?
  Multiple vaults (work / personal)?
- **Bidirectional sync conflict resolution** — Obsidian wins always? Last-write?
  Per-field?
- **MCP server hosting** — local-only (MetaWhisp.app exposes a port) or
  cloud-bridged for cross-device access? Privacy implications.
