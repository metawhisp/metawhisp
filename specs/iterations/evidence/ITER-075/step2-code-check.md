# ITER-075 Step 2 — code check (2026-09-25)

Read-only check of the current code and the store for the plan's Step 2, starting from
`codex-chat-audit-final.md`.

The orchestrator re-checked three facts:
- `searchConversations` fetches titled rows only, and a failed fetch returns an empty result.
- `{{CURRENT_UTC}}` is filled only on the Pro path and in the unused `callProProxy`.
- 149 completed meetings have no title.

Line numbers are for commit 7d5748b.

Extended by the Codex review of the plan (`codex-plan-review.md`: F3, F4, F11); the plan is the source of truth.

## 1. Current behaviour

### Store
1. The store is SwiftData (schema V1–V9, `Models/MetaWhispSchema.swift:360-431`) on a Core Data
   SQLite file, `~/Library/Application Support/MetaWhisp.store` (WAL, 447 MB).
   - The app has no `import SQLite3`, no full-text search and no Accelerate.
2. Transcripts are in `HistoryItem.text/processedText`.
   - Decisions, action items and participants are JSON strings on `Conversation`
     (`Conversation.swift:92-110`).
   - The calendar snapshot holds title, start, end and attendees. An attendee's e-mail is kept only
     when the name is empty.
3. FTS5 is available.
   - `/usr/lib/libsqlite3.dylib` 3.51.0 reports ENABLE_FTS5.
   - `unicode61` folds Cyrillic case, and the `trigram` tokenizer works.
4. Store counts, read-only:
   - 574 meeting transcripts, averaging 14,237 characters (the longest is 120,019); 75% are longer
     than 1,500.
   - 477 meetings are completed and 45 are `inProgress`.
   - 149 completed meetings have no title.
   - Decisions exist on 164 meetings, action items on 188.

### How the chat retrieves
5. Chat context is the same for typed and voice questions.
   - The query vector comes from the current message only.
   - Meetings: the newest 50 meeting items (about 7 days) are ranked by the 1,200-character
     conversation vector. The newest one is always forced in, 3 are kept, and each is cut to 1,500
     characters.
   - The meeting block carries no decisions or action items, yet the prompt calls it the "full
     transcript".
   - The whole prompt is capped at 24,000 characters (7,000 on the local path).
6. The other fetchers:
   - memories: every row, ranked by cosine;
   - tasks: open ones only;
   - dictations: the newest 6, with no query;
   - files: a token substring match;
   - screen: the newest 15 OCR rows of the last 24 hours.
7. Chat tools:
   - `searchTasks` drops done tasks.
   - `searchConversations` fetches only titled rows and ranks on title + overview, with no date
     argument. Titled dictations (1,012) outnumber titled meetings (367) in its 5 default slots.
   - No tool returns a transcript.
8. Ranking: a lowercase substring match per token, and cosine top-K with no floor.
   - A failed query embedding silently falls back to keywords.
   - The only relevance floor in retrieval is AdviceService's 0.45.
9. A failed fetch reads as empty: `(try? ctx.fetch(...)) ?? []` gives `ok:true, count:0`.

### Embeddings and names
10. Embeddings go through the Pro proxy only: `POST /api/pro/embed`, up to 100 texts per call.
    - A conversation vector covers title, overview and the first 1,200 characters.
    - Vectors are raw Float32 on each row, compared with a scalar cosine loop.
    - There is no on-device embedding model.
11. Names: transliteration exists for projects only (`ProjectAliasNormalizer`).
    - MCP matches the whole query as one substring, so any multi-word query returns nothing
      (`Sources/MetaWhispMCP/main.swift:295-300, 362-368`).

### Dates and the tool loop
12. Dates:
    - Pro gets UTC and a zone id, with no local date or weekday.
    - BYOK sends `{{CURRENT_UTC}}` and `{{USER_TZ}}` unreplaced.
    - The local path has no clock.
    - Tool timestamps mix UTC and local time.
13. The tool loop: a read-only call on the last round runs, but the loop then ends without another
    model call.
    - Pro returns the earlier text plus a cap note.
    - The text loop falls back to a generic answer.
    - The repeated-call guard also exits without an answer.
14. MCP reads a JSON snapshot written every 5 minutes. It holds no transcripts.
15. The screen agent's store search goes through `executeReadOnly`. Its own screen search scans an
    in-memory array. AdviceService ranks memories itself. AgentRun has no retrieval collaborator.

## 2. Changes
1. **Query frame and dates.** New `Services/Intelligence/Retrieval/`: `QueryFrame`,
   `RelativeDateResolver` and `QueryFrameBuilder`.
   - The resolver is pure, with the calendar injected, and resolves relative dates in the owner's
     time zone.
   - The Russian table waits for owner decision 3.
   - A follow-up question inherits the previous turn's name and date.
2. **Side index.** New `SideIndex` over `import SQLite3`: one file next to the store (so the Dev
   build gets its own), mode 0600.
   - Tables: docs, chunks, `chunks_fts` (FTS5, unicode61 with diacritics removed), `chunk_vec`,
     aliases with a trigram table, and meta.
   - It is not a SwiftData entity, so derived data needs no schema version.
3. **Indexer.** New `RetrievalIndexer`, a `@ModelActor` that reads SwiftData and writes only the
   side index.
   - Per conversation (untitled and in-progress included): one summary doc, plus transcript chunks
     of up to 1,200 characters with 200 of overlap, split on speaker lines.
   - It also indexes dictations, tasks (open and done), memories and files.
   - Full build into a temp file, then an atomic rename. At launch it reconciles by id, updatedAt
     and a hash.
   - Dirty marks, debounced, come from the grouper, the generator and the mutation service.
4. **Alias index.** New `AliasIndex`, built from:
   - projects, calendar titles and attendees, participants, assignees and memory subjects;
   - `ProjectAliasNormalizer.canonicalize`, reused rather than copied;
   - the meeting's own transcript tokens, matched by equal key or Levenshtein ≤ 2.

   Unconfirmed variants only widen recall. Merges are stored only when the owner confirms, in a new
   `EntityAlias` (schema V10).
5. **Search.** New `RetrievalService.search(frame, budget) async throws -> RetrievalResult`.
   - Each hit carries its kind, ids, title, local start, attendees, decisions, action items,
     snippets, score and reasons. The result also reports coverage.
   - The date is a hard filter.
   - Signals: bm25 over the query and alias variants, cosine above a `semanticFloor` (vDSP), and
     alias hits, merged with reciprocal-rank fusion.
   - Every hit is re-checked against the store. `read(conversationId, page)` returns the full
     transcript. Every failure throws.
6. **ChatService.** `send` builds the frame and runs `search` before any model call.
   - The prompt blocks come from hits.
   - The old fetchers and ranking are deleted.
   - Block format changes go to the owner together with the prompt diff.
7. **ChatToolExecutor.** The search tools become thin adapters over `search`.
   - New arguments: `when`, `from`, `to` and `includeDone`. `when` is resolved by the resolver,
     never by the model.
   - New tool `readConversation(id, page)`. A failure returns `ok:false`.
   - Every hand-kept tool list is updated.
8. **Last round.** It becomes answer-only in both loops. The transports are injected so the loops can
   be tested.
9. **`PromptClock`.** One local date, weekday, time, offset and zone for the Pro, BYOK and local
   paths.
   - The resolved range goes in as data.
   - The wording goes to the owner.
10. **Other consumers.** AdviceService moves to `search`; MCP is answered by the app over a 0600 Unix
    socket.
11. **Sources.** `ChatMessage.sourcesJSON` (V10): the bubble and the voice popup show the cited call,
    date and time from the result, not from the model's text.
12. **Wiring.** AppDelegate creates the indexer and the service, and injects them.

## 3. Tests to write first
1. `RelativeDateResolverTests`: "last Friday" in UTC+3; "yesterday" across a UTC date change;
   across a DST change.
2. `QueryFrameBuilderTests`: a follow-up inherits the previous turn's name and date.
3. `SideIndexTests`: FTS5 through `import SQLite3`; a phrase at character 30,000 is found; a Latin
   query finds Cyrillic text.
4. `AliasIndexTests`: two scripts are one entity; an ASR variant never merges on its own.
5. `RetrievalServiceTests`:
   - a date + name question ranks the right meeting first;
   - untitled and in-progress meetings are found;
   - there is a floor;
   - the newest meeting is not forced in when a date is given.
6. `RetrievalErrorTests`: a throwing fetch is an error, never `count:0`.
7. `RetrievalIndexerTests`: a full build equals an incremental one, and the store is never written.
8. `ChatAgenticLoopTests`: a last-round search reaches one more model call.
9. `PromptClockTests`: no `{{` in any sent prompt, and all paths carry the same local date.
10. Schema: `readConversation` appears in every tool list; V9 → V10 migrates on a copy of the store.
11. Evaluation on the owner's 20+ labelled questions (local file, not committed): 90% in the top 3.

## 4. Spec / audit corrections
- The last-round loss is in the BYOK/local text loop too, not only in the Pro loop.
- "No relevance threshold" is true for the chat only. The app has seven separate search/ranking
  routines.
- Pro gets UTC plus a zone id, not a local date.
- The tool list is kept in six lists and several switches, not five places.
- "Pro or a local model for embeddings": no local embedding model exists, and embedding needs Pro.
  Without Pro, only text, alias and date matching run.
- The screen agent's own search scans an in-memory array; it does not need replacing.
- MCP requires the whole query verbatim.

## 5. Open questions
1. Consent: chunk embeddings would send whole transcripts to `/api/pro/embed`. Today only the first
   1,200 characters are sent.
2. Which model is behind `/api/pro/embed`, and does `/chat-with-tools` accept a call with no tools?
3. Date rules: "last Friday" said on a Friday; "on Tuesday"; the first day of the week.
4. MCP transport: a socket to the running app, or a read-only library over the side index?
5. Where the owner confirms or merges aliases.
6. The semantic floor and the fusion weights, both taken from the labelled set.
