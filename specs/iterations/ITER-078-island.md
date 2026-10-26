# ITER-078 — The Island: the voice window, reshaped

**Status:** plan approved by the owner on 2026-09-28 («Да, строй»).
**Design:** canvas "Jev agent interface", board 7 "Form factor: Island"
(https://claude.ai/artifact/3XkwVKjpPRLYcpJ2bGvvj1), chosen by the owner on 2026-09-28 («давай добавим
пока island»).

## Owner decisions (2026-09-28)
1. **What it replaces.** The Island replaces the voice window (hold Right ⌘ for a voice question) in every
   phase: listening, transcribing, thinking, the answer, and an error. The errand phases (working, done)
   join it when the agent is wired (ITER-076 Stage 3.2).
2. **Where.** Top centre, just under the menu bar — where the voice window is today. It covers nothing in
   the menu bar and behaves the same on every screen.
3. **Colour.** It follows the appearance, like MetaWhisp's other windows (the option the owner chose said
   so): light glass with dark text in light, dark glass with light text in dark. MetaWhisp's own Theme
   setting decides it — with "System" the island follows macOS.

## What does not change
- The triggers, the phases and the flow (`VoiceQuestionState`), transcription, MetaChat and speech.
- Clicks outside the Island reach the app below (the two-window pattern), Esc closes it, Space stops the
  speech, the answer and the error close themselves after 6 and 4 seconds as today.
- The window keeps `.fullScreenAuxiliary` (the window-Space rule).

## User stories
1. As a user holding Right ⌘, I see a small island grow under the menu bar, with a wave made of characters
   that follows my voice, so I know it hears me.
2. As a user who released ⌘, I see the island stretch while a stream of bits runs; when the words are
   ready they decode out of the bits, so I see what it heard.
3. As a user waiting for the answer, I see the island pinch into a short pulsing capsule, so I know it is
   thinking.
4. As a user reading the answer, the island unfolds into a panel with my question and the answer — it
   scrolls when long — with Stop while it speaks and Esc to close.
5. As a user whose question failed, the island shakes once and goes flat, saying why in full, and "Hold
   Right ⌘ to try again" only when asking again can fix it (too quiet, too short, nothing heard — not a
   dead microphone or a missing engine).
6. As a user with Reduce Motion on, the island changes size without bounce, does not shake or breathe,
   the bits do not cycle and the question shows at once; the wave still follows the voice, since it is
   the only sign the microphone hears.

## Acceptance
- Shapes, from the mock: a seed 44×14 grows to listening 300×44; transcribing up to 668×56; thinking
  200×40; the answer panel 480 wide, growing with the answer up to 360 tall, then scrolling; the error
  panel 480 wide and 60 tall, growing to 120 for a long message (review of ITER-078: a cut message hid
  its fix).
- Light and dark as MetaWhisp's appearance is set, switching live.
- It sits 10 pt under the menu bar, and clear of the notch when a full-screen app hides the menu bar.
- The wave follows `AudioRecordingService.audioLevel`; the words decode from the real transcript only —
  no invented text. A voice question never shows fake progress.
- The mock's [Try again] button is left out: a voice question starts only by holding Right ⌘, so the
  error says so instead.
- Labels in English.

## Checklist
- [x] 1. `VoiceIsland` (pure: stages, shapes, the wave, the bit stream, the decode, the ticker) and
  `VoiceIslandPresenter` (the clock, the voice's levels, the shape over time). 13 unit tests, written first.
- [x] 2. `VoiceIslandView`: every stage in both appearances, Reduce Motion. Checked by rendering each stage
  in light and dark to images.
- [x] 3. `FloatingVoiceWindowController` hosts it in place of `FloatingVoiceView` (removed): both windows
  animate to the shape together, top centre 10 pt under the menu bar; the shadow window follows the
  corner radius and glows red while listening, faint red on an error.
- Review round 1 (NOT ACCEPT, 1 P1 and 5 P2), all fixed, tests first where a test can see it: the shadow
  window reached above the menu bar and macOS moved it down, so the shadow and the glow fell 50 pt below
  the island (`IslandShadowPanel` keeps its frame); the shadow and glow are drawn only outside the glass;
  the error panel grows with its message and the retry hint shows only when it helps (decided where the
  question fails); each answer is measured at the panel's own width, afresh; the island clears the notch
  in full screen; VoiceOver skips the bits and reads the question; the whole island shakes on an error.
- Review round 2 (NOT ACCEPT, 1 P1): the error's shake ran beside the move to the error's shape and left
  the panel where the move began — up to 140 pt off centre, against the menu bar. Fixed with a test on
  the real windows (it failed first): the island shakes only once it has settled in the error's shape,
  and any placement first stops a shake still running.
- Review round 3 (NOT ACCEPT, 1 P1): a move that grows the island lands on its target before it formally
  ends, so an error arriving in those ~90 ms was still shaken by that older move's end. Fixed with a
  second window test (it failed twice first): only the latest move may shake. The error text takes up to 5 lines, filling the
  120 pt panel. A failure the app cannot tell apart (a transcription or chat error) gets no retry hint.
- Known, not from this iteration: pressing Esc while listening and then releasing ⌘ opens the island
  again, and a missing microphone permission leaves "Listening…" until Esc.
- Differences from the mock, on purpose: the thinking capsule shows only the ticker — the mock's label
  named Jev, and a voice question is not answered by Jev yet; the answer panel is new (the mock had none)
  and follows the working panel's style.
- [ ] 4. Gate, a read-only review, then the swap onto the owner's app with a five-line note on what to
  try. No release to users until the owner says so.
