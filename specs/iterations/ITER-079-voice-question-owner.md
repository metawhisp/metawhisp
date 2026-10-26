# ITER-079 — one owner for a voice question

**Status:** done 2026-09-28 (`5d4a794`), on the owner's Mac, not released. The owner asked to check the whole long-press flow ("проверь весь флоу"),
then for a complete, working product ("мне надо нормальное полноценное решение"). The Island (ITER-078)
is how the agent will start, so its hangs are fixed first.

## What the check found (code and the app's log, 2026-09-28)
The owner's voice question at 20:16 worked: the answer's text 4.4 s after releasing ⌘, the voice 6.2 s
after. The code has four ways to hang or to show the wrong answer:
1. **No microphone.** `startVoiceQuestion` shows "Listening…" before the recording starts. When it cannot
   start — no microphone permission, or the recorder throws — nothing says so, and the island listens
   until Esc.
2. **Esc does not cancel.** `dismiss()` resets only the island. The recording and the transcription go
   on, and `transcribing()` / `thinking()` accept a closed question, so it comes back and is answered.
3. **A busy or unset chat.** `ChatService.send` returns silently when another message is being answered,
   when there is no AI access, or when the API key is empty. The island waits on "thinking" forever.
   MetaChat loses a typed message the same way while a voice question is answered: its box is already
   cleared.
4. **A second question.** A new question does not cancel the first one's send, and `answered()` refuses
   only an idle island: the first answer lands under the second question, and the second is dropped.

## The cause
Three layers write the question's phases — `TranscriptionCoordinator`, `ChatService` and the island's
window — and nothing owns the question as a whole. Each early exit has to remember to report, and four
of them do not.

## The fix, at the owner
- **`VoiceQuestionState` owns the question.** Each question has an id. Every step names it, and a step
  for a question that was closed or replaced changes nothing. Closing or replacing a question tells the
  coordinator, which stops its recording. `answer(_:transcript:within:ask:speak:)` asks, and turns every
  outcome of the ask into the answer or an error; nothing within the limit is an error too.
- **`TranscriptionCoordinator` records and transcribes for that id.** A recording that cannot start ends
  the question in an error. The id is carried to the transcript, and a closed question's transcript is
  dropped before anything is saved or pasted.
- **`ChatService.send` says what happened:** `answered`, `busy`, `noAccess`, `failed`, `empty`. The island
  and the voice answer's speech are no longer its business. MetaChat puts a busy message back in its box.

## User stories
1. As a user without microphone access, holding Right ⌘ shows an error that says how to allow it — not
   "Listening…" forever.
2. As a user who pressed Esc while speaking or while it transcribes, the question is gone: the
   microphone stops at once, nothing is sent, nothing comes back.
3. As a user asking while MetaChat is busy, or with no AI set up, the island says why and ends. A typed
   MetaChat message is never lost either.
4. As a user who asks again before the answer came, I get the answer to the new question; the old one is
   dropped.
5. As a user whose answer never comes, the island ends with an error after 2 minutes.

## Decisions (mine, by the owner's rules; he can change them)
- The limit for an answer is 120 s. A stalled request already times out after 60 s a round; the limit
  only ends what nothing else ends.
- Esc means cancel: a closed question's audio and transcript are dropped, not saved.
- A busy MetaChat is an error with "Hold Right ⌘ to try again": asking again fixes it.
- A question that ran out of time ends on the island, but its send goes on, so the reply still lands in
  MetaChat; a new question stops such a send.

## What Esc keeps
- Before the question is sent: nothing — not its audio, its transcript, the clipboard, the history, a
  recovery file or an error.
- After it is sent: the question stays in History and in MetaChat, as asked; its answer is dropped, and
  a send cancelled this way leaves no error row.

## Checklist
- [x] 1. Seams, behaviour unchanged: the coordinator takes its cloud engine and the microphone-settings
  opener, so tests drive it without the network or System Settings.
- [x] 2. Red tests: no microphone, a recorder that throws, Esc while listening, Esc while transcribing,
  a busy MetaChat — 5 tests, 9 failures on the old code.
- [x] 3. The fix. The gate passed with 2129 tests.
- [x] Review round 1 (a read-only Claude agent): ACCEPT, 6 P2 and 5 P3, all fixed:
  - P2-1: closing a question now cancels its transcription and frees the coordinator at once; a long
    press while a voice question is transcribed replaces it; a long press while a dictation is
    transcribed says so on the island; a closed question's transcription leaves `stage` alone.
  - P2-2: the result and a post-processing error are recorded only after the check that the question
    is still open (a `TranscriptPostProcessor` seam lets a test hold post-processing).
  - P2-3: a new question stops the old answer's speech before the microphone starts.
  - P2-4: `send` asks MetaChat's one access rule (`LLMAccess.hasForChat`) before it saves anything, so
    `.noAccess` means nothing was saved, and MetaChat gives such a message back to its box.
  - P2-5: tests for the chain (a new send waits for the replaced one to unwind), a replaced question's
    id, a send closed while it waits, the spoken answer and the speech setting, Esc before the
    transcription, during post-processing and before a failed transcription, and `send`'s outcomes.
  - P2-6: the auto-dismiss closes only the question it was set for (`dismiss(ifStill:)`).
  - P3: the coordinator takes its island state (tests use their own); `phase`, `transcript` and the
    send task are private to the owner; a proposed change says "Open MetaChat to confirm."; the island
    shows transcribing whichever control stopped the recording; a cancelled send leaves no error row.
  - Each fix was broken on purpose once and its test failed, 10 of 10. The first run pointed the result's
    mutation at the wrong test; moving both assignments back above the check fails
    `testEscWhilePostProcessingKeepsNothing`.
- [x] Review round 2: ACCEPT, 2 P2 and 5 P3, all fixed:
  - P2-A: a long press refused because a dictation is transcribed no longer closes the question the island
    shows; the note appears only on an idle island.
  - P2-B: after Esc, a new recording is never ended by the old question's work (tested at every closed
    check); `.busy` and `.noAccess` are tested against a real store; the window's own auto-dismiss is tested
    with an old question.
  - P3: the busy notes no longer repeat "Hold Right ⌘ to try again"; the dictation pill hides while the
    island shows and comes back when it closes; a late send is not cancelled, so its reply reaches MetaChat,
    and a new question stops it; any speech stops before the microphone starts; the recovery audio saver is
    injected, so no test writes to a real folder; `LLMAccess`'s doc says it is MetaChat's gate.
  - Each round-2 fix was broken on purpose once and its test failed, 9 of 9.
- [x] 4. Gate (2148 tests, PASS), commit `5d4a794`, swapped onto the owner's app on 2026-09-28 at 22:25 (not released).
