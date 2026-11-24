# ITER-083 — a meeting knows which call it is

Status: approved by the owner on 2026-11-07 («начни делать по итерациям»). Branch `fix/meeting-identity` from
`fix/tasks-whole-meeting` (= shipped 1.4.5). Research, findings and the reviews behind it live outside the repo
(research folder, brief `MEETING-IDENTITY-2026-11-07`).

## Why
Measured on the owner's Mac on 2026-11-07:
- 42 of 105 meetings in 30 days carry their calendar event's name, although 23 of 24 recordings in a 4-day log
  window were started by a calendar event the app knew exactly. The two daily calls: 0 of 9 named in a week.
- A call cut at the next event's start is saved under the next event's name.
- 9 meetings show "in progress" forever; every one consists of 2–3 recordings, and the later recordings are in
  no summary or task.
- Calls are cut while still on (a calendar-end stop 76 min into a call seen 24 s before) and restarted, or split
  into two separate meetings when the second recording is longer than 10 min.

## Causes
- R1 — a recording has no identity of its own: the event lived in two AppDelegate fields the next recording
  overwrote before the earlier one was saved; the saved meeting got no event and one was guessed by time overlap;
  bounds and the resume gap came from save times; recurring occurrences shared one id in the gate.
- R2 — the app stops a call that is still on (two stops ignore the call detector) and restarts it.
- R3 — nobody owns a meeting's end: a resumed meeting is set "in progress" and nothing closes it.

## Decisions
- Attribution only from what is observed: only a calendar start carries an event. Fallback and manual recordings
  carry none, and no meeting saved with a recording context is ever guessed.
- A stop has a typed outcome (refusal, transition, ended, rollover, empty) that decides hold, retry and restart.
- A meeting is processed once, on its final content: at once after a refusal or transition, after a 10-minute
  settling window when the app ended it.
- The calendar title is used as the calendar shows it; an untitled event leaves the meeting its own title.
- The cut at the next event's start stays (all 4 such cuts in the log window were real transitions).
- 15 minutes of silence on both channels ends a recording even with a call window in front: the detector sees a
  window, not a connection. Accepted trade-off; the 240-minute cap stays.
- Out of scope: turning rescued audio into a meeting (no path does that today).

## User stories
1. As a user whose calls come from the calendar, I want each recorded call named like its event, so I find it by
   the name I gave it. AC: every recording started by an event is saved with that event (title, occurrence,
   attendees), also when saved after the next recording started.
2. As a user, I want a call that is still on never cut, and a call the app had to split saved as one meeting, so
   its summary and tasks cover all of it. AC: no stop while the call is seen, short of 15 min of silence or the
   cap; parts of one occurrence form one meeting, processed once.
3. As a user, I want "in progress" only while recording. AC: no meeting is left in progress.

## Iterations
- [x] I1 — RecordingContext: frozen at stop, passed to every save, written onto the meeting (event, occurrence
  key, origin, real start/stop); part intervals on `HistoryItem`, parts read in recording order; the guess guard
  for every guessing entry point; occurrence keys in the gate and the back-to-back check; raw title and attendees.
  Review: Kimi ×2 (`9f0a2ac`: schema V10 with frozen V1–V9 shapes, identity-gated resume, one part order).
- [x] I2 — stop outcomes; one end rule for the calendar-end and silence stops (a call seen holds the recording, 15
  quiet minutes end it anyway); the app-end hold on the window (app + call); retries end once something was
  delivered. The cap ends a recording as before (no rollover restart). Review: Codex ×2, ACCEPT (`dc6ce52`).
- [x] I3 — settling: a meeting is processed once — at once after a person's stop or the next event, after a 10-min
  window when the app ended it (the 60-s sweep); joins on real times by occurrence or call; no meeting set "in
  progress"; the stuck ones settled with their summary rewritten; settling waits for a continuation in flight and
  completes only once its processing is queued on disk; recap from processing. Review: Kimi ×3, ACCEPT
  (`ed77f76`, `45e1569`).
- [-] I4 — dropped: deleting a renamed meeting's old Obsidian note by its 8-character suffix was refused by Codex
  (4 P1); renames are rare after I3 and the duplicate is pre-existing. Parked in BACKLOG with the constraints.
- [x] I5 — schema V10 vs the install script (its own tripwire, N7): every build declares the schema it reads
  (`MWSchemaVersion`); a build that reads a newer schema than the installed one is not swapped in (its migration
  could not be rolled back) and comes through a release; `--rollback` refuses a kept build that reads less.
  Review: Codex ×2, ACCEPT (`c7728a2`, `9cfe891`).
- [x] Release review — the whole range by Codex, Kimi and MiniMax; their P1s fixed in `32b1cb1` + `d01ae30`
  (processing survives a quit, out-of-order parts, a failed start, a ceiling on every hold); the rest parked in
  BACKLOG.
- [ ] Release — full gate (on the owner's word: it shows windows), 1.4.6, three-day live check. V10 reaches the
  owner's Mac through the release, not a swap.

## Definition of Done
- Every iteration's tests were red before its fix and green after; mutations of each fix are caught.
- `bash scripts/regression.sh` → PASS, test count not lower (full gate on the owner's word).
- Review per iteration (Kimi and Codex alternating), no open P1.
- Live, three working days after install: every calendar-started recording saved with its event's name; no stop
  while a call was seen short of the 15-minute rule; no meeting left in progress; no duplicate tasks; the task
  extractor logs `calendar=yes` for every evented meeting.
