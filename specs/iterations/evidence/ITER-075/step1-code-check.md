# ITER-075 Step 1 — code check (2026-09-25)

Read-only check of the current code, the app log and the store, made for the plan's Step 1.
- The orchestrator re-checked the store counts: 45 meetings `inProgress`, and 149 completed
  meetings with no title.
- The orchestrator also re-checked the misleading "dropped" log line (StructuredGenerator.swift:235-236).
- Line numbers are for commit 7d5748b.

Extended by the Codex review of the plan (`codex-plan-review.md`: F2, F7, F10); the plan is the source of truth.

## 1. Current behaviour

### Calendar: the occurrence and its end
1. The app's event ID is `EKEvent.eventIdentifier`, used as-is (AppDelegate.swift:2830-2834).
   - Every occurrence of a series shares it. Only detached occurrences get their own `/RID=` ID.
   - The tick's `eventStartingNow` / `eventInProgress` (CalendarReaderService.swift:85-102, :66-83) hold the right occurrence, but only its ID and title are kept.
2. At start, AppDelegate.swift:2972-2977 re-reads the event through `store.event(withIdentifier:)` (CalendarReaderService.swift:108-112), which returns the series' first occurrence.
   - From 09-22 18:40 to 09-25, 19 of 24 start-time arms had an end in the past, so the end check fired after 1 s.
   - `currentEvent(at:)` (:117-131) has no callers.
3. The 10-minute floor (AppDelegate.swift:3057-3063) reads `meetingRecorder.recordingStartedAt`.
   - That value is set only inside `start()`'s async Task (MeetingRecorder.swift:366-376, :456).
   - So it is nil at the first arm (:2977), and the floor never applies there.
4. The first fire always shows a card: `recentAudioActive` is true while `silentSince` is nil (AppDelegate.swift:3095; MeetingRecorder.swift:992-995).
   - Cards come at +1 s, +10 min and +15 min, then `silentExtend` or `hardStop` (CalendarEndStopDecision.swift:103-111).
   - The card counter is reset for every recording (AppDelegate.swift:2963).
   - The logs hold 31 overrun cards.

### Retries and the gate
5. Retries (CalendarAutoStartRetry.swift:32-46): any stop not made by hand is retried while the event runs, even after audio was captured.
   - Today one occurrence produced 3 recordings and 4 cards.
6. The gate's state is keyed by the series ID and kept only in memory: `lastCalendarEventID`, `calendarAttempts`, `declinedEvents` (MeetingAutoStartGate.swift:57, :60, :70).
   - A hand stop blocks retries of every later occurrence until relaunch.
   - Attempts are never released.
   - BackToBackTransition.swift:70 cannot split two occurrences of one series.
7. A relaunch restarts a running event about a minute after launch.
   - On 09-22 the owner then stopped it by hand.
   - On 09-25: launch at 11:51:36, retry at 11:52:46.

### Call labels and the grouper
8. The call label (`currentMeetingCallContext`) is set at countdown end (AppDelegate.swift:2956) and read at save time (:2577). It is not cleared on stop (:1908-1912).
   - Manual start (:1658-1675) does not touch it, so a manual recording inherits the last label.
   - Today at 12:00, meeting A's transcript was saved under meeting B's label, because B had already started.
9. The reopen rule (ConversationGrouper.swift:132-153) reopens a row when the label string matches and `saveTime − recent.updatedAt ≤ 600 s`, with no status filter.
   - `updatedAt` is also written by StructuredGenerator, CalendarReaderService, ProjectAggregator and UI edits.
   - Generic labels join unrelated calls.
   - A reopened row is set `inProgress`, and `scheduleOnClose` never runs for it.
10. Nothing closes a meeting.
    - `closeConversation(id:)` (:104-114) has no callers.
    - `closeStaleConversations` (:78-101) skips non-dictations (:91).
    - Stuck rows are skipped by embeddings, calendar links and the project backfill, and are shown as LIVE.
    - Store: 45 meetings are `inProgress`, all with `finishedAt` NULL; 12 of 115 in the last 30 days.
11. `scheduleOnClose` (ConversationGrouper.swift:225-236) waits 2 s, runs `generate`, then the memory and task extractors. It fires only for fresh meeting rows and for dictation closes.

### Summaries and the project backfill
12. StructuredGenerator.swift:235 (`guard !isRunning else { return }`) drops a second run silently.
    - The log line "dropped — another generation already in flight" (:236) comes after that guard, so it prints on runs that were NOT dropped.
    - Today's blank recaps come from the "No LLM access" exit (:237-240). That exit also skips the calendar link that supplies the title.
    - No exit records a state or re-queues.
    - The periodic backfill is off (:177-181).
    - Store: 14 meetings in 30 days have no title.
13. `backfillProjects` (ProjectAggregator.swift:555-624, 15 s after launch) takes the newest 200 completed, titled rows with no project.
    - It sets title, overview, category and emoji to nil and saves (:587-597) before `generate`, and restores them only after it returns.
      - On 09-22, a quit mid-pass left one row blank for good.
    - There is no "checked" marker, so the same 200 rows are re-sent every launch; the pass took 5.5 min.
    - A short transcript overwrites a real title with "Quick note".
    - The same blank-first pattern is in `curativePass` (ProjectAggregator.swift:316-321) and `backfillPlaceholders` (StructuredGenerator.swift:149-154).

### Recovery and the "Recording saved" card
14. Recovery WAVs:
    - Quit while recording writes `meeting-<stamp>-me/them.wav` with no label, occurrence or start time.
    - Quit during transcription saves nothing (MeetingShutdown.swift:35 requires `isRecording`).
    - A failed chunk is saved as `recording-<second>.wav`, the same pattern as dictation; two failures in the same second overwrite each other.
    - Nothing imports these files. `cleanupStaleRecoveryWavs` (AppDelegate.swift:3234-3272) deletes them after 7 days.
15. "Recording saved" is posted in `onAutoStop` (AppDelegate.swift:1051-1056) before the stop path discards the recording or finds it empty.

## 2. Changes
1. Occurrence lookup:
   - A `CalendarOccurrence {eventID, occurrenceDate, title, start, end, key}` is built from the occurrences the tick already has. It is carried through `Decision.calendarReady(occurrence:)` into the start, and the end stop is armed with `occurrence.end`.
   - `event(forIdentifier:)` and `currentEvent(at:)` are deleted.
   - A re-read at fire time uses `events(matching: predicateForEvents(withStart: sessionStart−4h, end: now+60s, calendars: nil))`, filtered by identifier and occurrence date, inside a pure `CalendarOccurrencePicker`.
2. Floor: `firstFire = max(end + 60 s, sessionStart + 600 s, now + 1 s)`. `sessionStart` is taken synchronously at start.
3. New `CalendarOccurrenceLedger`, persisted as JSON in App Support. Each entry is dropped at `end + 1 h`, which is its release.
   - Per occurrence key it holds attempts, declined, captured, overrunCards and cardsDismissed.
   - The gate uses it in place of its memory-only state. A hand stop survives a relaunch and ends with the occurrence.
   - No retry once a stop kept audio.
4. Cards:
   - Count per occurrence and remove the per-recording reset.
   - The decision returns `.silentExtend` once cards are suppressed.
   - A dismissed card (not a timed-out one) suppresses the rest.
5. A `MeetingSession {generation, label, occurrence?, startedAt, stoppedAt, source}` is set at start and cleared at stop. It is passed into `persistMeetingTranscript(…, session:)` and `assign(historyItem:session:)`.
6. Grouper:
   - Fresh rows take their times, label and calendar fields from the session.
   - Rows are appended only for the same occurrence key, within 600 s of `finishedAt`.
   - An append completes the row and enqueues it; meeting rows never become `inProgress`.
   - `AppDelegate.shared` calls are replaced by an injected `ConversationProcessing`.
7. Repair: a one-time `closeStuckMeetings()` turns every `meeting && inProgress` row into `completed`, with `finishedAt` = its last item, and enqueues it. Its flag is set only after a successful save. `closeConversation(id:)` is deleted.
8. Structured queue: `ExtractionQueueStore("structured-generation-queue.json")`, at most 3 failed attempts, backoff 1/5/30 min, a persisted failed set.
   - No LLM or no key → `.retryLater`, re-drained when Pro, a key or the local model appears, and at launch.
   - Parse error or throw → `.failedAttempt`.
   - Success or a short transcript → `.completed`.
   - Every caller enqueues. Regenerate goes to the front.
   - The misleading log line moves into its real branch.
   - Untitled meetings are enqueued once.
   - The Library shows "waiting for Pro" or "summary failed", never a blank.
9. Backfills:
   - The blank-first writes are removed. The old fields stay until a result replaces them.
   - A short transcript keeps an existing real title.
   - `project-backfill-checked.json` skips checked rows until their transcript grows.
10. Recovery:
    - A manifest (label, occurrence, start, files; for a chunk, its item, offset and channel) sits beside every rescued file, and chunk file names are unique.
    - `MeetingShutdown.plan(…, finalizingSamples:)` also rescues audio being transcribed.
    - `MeetingRecoveryImporter` imports at launch. Files are deleted only after a successful save, and after 3 failed attempts a card names the folder.
    - The 7-day cleaner skips files that a pending manifest still references.
11. "Recording saved" is posted only after the save succeeds. The discard and empty paths post their real reason.

## 3. Tests to write first (calendars pinned to UTC)
1. `CalendarOccurrencePickerTests`: a weekly series first held on 2025-12-05 resolves, on 2026-09-25, to that day's occurrence.
2. `CalendarEndStopScheduleTests`: a past end gives a first fire at +600 s, never at +1 s.
3. `CalendarOccurrenceLedgerTests`:
   - 3 recordings give at most 3 cards; a dismissed card suppresses the rest.
   - The next occurrence starts at 0.
   - An entry is gone at end + 1 h; a declined entry survives a reload.
4. Gate:
   - Declining Monday does not block Tuesday.
   - A relaunch does not restart a declined running occurrence.
   - No retry after captured audio.
5. Grouper:
   - A's transcript saved after B started keeps A's label.
   - Appends happen only for the same key; two generic sessions give two rows.
6. `closeStuckMeetings` completes every stuck meeting once.
7. Structured queue:
   - Two enqueues during a drain both run.
   - A no-LLM run stays queued and drains when Pro turns on.
   - 3 failures land in the failed set.
8. Project backfill never writes a nil title and never re-selects a checked row.
9. Recovery:
   - A quit mid-transcription rescues the audio.
   - The importer rebuilds one meeting.
   - The cleaner skips referenced files.
   - "Recording saved" appears only after a save.

## 4. Spec corrections
- The blanking is at ProjectAggregator.swift:593-597, :316-321 and StructuredGenerator.swift:149-154. StructuredGenerator.swift:593-597 is prompt text.
- The stuck count: 45 in total and 12 of 115 in 30 days. The plan's "11 of 111" should read "all 45".
- The "dropped" line is misleading: today's blank recaps are no-LLM exits that nothing retries, and they also lose the calendar title.
- The 1 s fire always shows a card. Stops come at the 10- and 15-minute re-fires or as `hardStop`. The broken first-arm floor is missing from the plan.
- The reopen rule compares against `updatedAt`, which any write changes.
- Missing from the plan:
  - the retry after a recording that captured audio;
  - the series-keyed, memory-only gate state.
- The "minimum length" is 40 transcript characters (StructuredGenerator.swift:51), not a duration.

## 5. Open questions
1. Are `eventIdentifier` and `occurrenceDate` stable when a "this and following" edit splits a series mid-meeting? This needs a live check.
2. Should a manual recording during a calendar occurrence take that occurrence? A code comment says no (AppDelegate.swift:296-301).
3. No auto-restart after a stop that captured audio, for example a long silent pause mid-meeting. Does the owner accept that?
