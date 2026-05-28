# ITER-040 — Fix wrong `Conversation.primaryProject` assignments

## Problem

Audit on 2026-05-23 (vault inspection after bulk re-export Obsidian):

10 of 18 auto-created project stubs point at conversations where **voice content does not mention the project at all**. Categorical pattern (real names redacted per repo policy):

| Wrong project tag (category) | Voice text reality |
|---|---|
| Org-tool A | unrelated «было / не было» question |
| Feature project B | unrelated UI/animation note |
| Site-rebuild | generic «когда напишешь?» question |
| Internal product C (text doesn't mention it) | unrelated «какой сегодня праздник?» |
| Hardware accessory | actual MetaWhisp screen-recording bug discussion |
| AI product D | feature request about MCP, not the project |
| Internal product E | generic «гипотеза, микротулзы» |
| Marketing tool | generic «сделай 5 вариантов хироблоков» |
| Dev sub-project | generic «node vs next» preference |
| Brand product F (typo variant) | brand-traffic discussion — typo-merge into wrong canonical |

Conversely, REAL project mentions in 7/18 stubs match correctly (where the text actually does mention the project).

Success rate ≈ 40%. That's the bug surface.

## Where the assignment happens (code inventory)

Project field on `Conversation.primaryProject` is set in one or more of:

- `Services/Intelligence/StructuredGenerator.swift` — extracts title + project + category from conversation via LLM
- `Services/Intelligence/ConversationGrouper.swift` — groups history items into conversations
- `Services/Intelligence/ProjectAliasNormalizer.swift` — canonicalizes project names (typo-merge)
- `Services/Intelligence/ProjectClusterDecision.swift` — decides merge clusters (per memory `2026-04-XX` HallucinatedName incident)
- `Services/Intelligence/ExistingProjectCatalog.swift` — lookup of canonical existing projects
- `Services/Intelligence/AliasCanonicalPicker.swift` — chooses canonical when alias merge happens

Suspicious behaviour to investigate (hypothesis only):

1. **Stale inheritance.** Once a conversation has any project, later voices in the same conversation inherit it — even if their text is unrelated. Possible cause: ConversationGrouper extends an old conversation rather than starting a new one on topic shift.
2. **LLM hallucination during structured extraction.** The system prompt may force a project field to be non-null; LLM picks something plausible-looking from neighbouring memory/screen context rather than the actual transcript.
3. **Weak-signal triggering.** A passing mention triggers cluster merge into an existing project. ProjectClusterDecision threshold may be too permissive.
4. **Typo-merge into wrong canonical.** Two slightly-different brand variants merging via Levenshtein lev=2 — already an open known issue from earlier sessions (`AliasCanonicalPicker` winner-pick by aliases count, not name quality). Should now be stricter — verify.

## Investigation plan (when this iteration starts)

1. **Audit dataset (read-only).**
   - Dump every `Conversation` from SwiftData with: id, started_at, primaryProject, full transcript (joined HistoryItem.processedText).
   - For each row mark MATCH=true if project name (or its known aliases) appears as a substring in the transcript (case-insensitive).
   - Count MATCH-false rate. Group by project. Find which projects are over-assigned (high false-rate).

2. **Find the assignment site.**
   - Add NSLog tracing to every `conversation.primaryProject = X` mutation in code, capturing call-site stack frame name and the input that drove it.
   - Trigger one wrong assignment and read trace.
   - Identify which service is doing the wrong assignment.

3. **Spec the fix.**
   - Decide: does the system have permission to make a project assignment when the LLM's confidence is low / the transcript signal is weak? Today the schema seems to default to "pick something." Better: default to nil and only assign on strong signal.

4. **Implement + test.**
   - Add a confidence threshold to project assignment.
   - Add a unit test using one of the wrong cases above as a fixture — assert primaryProject stays nil.
   - Re-run Obsidian bulk export — count wrong-stub creation drops below 5%.

## Out of scope for this iteration

- Cleaning up the historical wrong assignments in user's vault. That's a separate one-shot migration we can offer as a button («Re-assign projects for all past conversations»). Independent from preventing future wrong assignments.

## DoD

- Trace logs in place identifying every primaryProject mutation site.
- Confidence threshold or stricter signal logic in the assignment site.
- Unit test pinning at least 3 of the wrong-tagged voices as MATCH=nil after re-run.
- Vault re-export produces ≤2 false-positive project stubs.

## Related memory notes

- `~/.claude/projects/.../memory/feedback_no_extrapolation.md` — applies here, do NOT guess where the bug is, read the code first.
- `~/.claude/projects/.../memory/feedback_omi_first.md` — check how omi handles project inference, if at all.
- Earlier HallucinatedName incident in WAL.md — same shape, different surface.
