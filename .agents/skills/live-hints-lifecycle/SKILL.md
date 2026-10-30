---
name: live-hints-lifecycle
description: Use when changing live meeting answer requests, card publication, cancellation, or screen-context privacy.
---

# Live hints lifecycle

- `LiveMeetingAdvisor` constructs the environment; `LiveHintsMeeting` owns one session token and routes accepted transcript lines.
- Take a user request identity synchronously at the action, before scheduling or awaiting work. Recheck identity, generation, session token, and request handle before dispatch and publication.
- The session token stops the whole meeting. Request handles cancel individual requests; disabling automatic answers must leave manual answers, transcription, batching, and memo folding alive.
- Only transcript-provenance answer cards enter history and advance the answered boundary. Action cards never do. Screen cards cannot be expanded or enter transcript history.
- The screen capture closure is injected from the existing app-owned capture service through the advisor and environment. Recheck the Screen Context setting after capture. OCR belongs to the single press and must never enter reusable state or logs.
- Card callers use `MeetingAnswerRoute.stream`; memo retains `answer`. Local completion emits one whole delta. The card owns the whole-stream deadline and cancels the stream reader without invalidating the request handle, so valid deadline partials can still publish.
- Each card stream has a child transport handle. Cancel it before terminal cleanup/publication, and on every exit; cancelling the parent request also cancels this child.
- `MeetingAnswerStreamFilter` owns all draft visibility: hold think fragments and skip prefixes, latch suppression, gate answers on their bold headline, and keep actions invisible until the final contract passes. A failed terminal never publishes a valid-looking partial.
- Draft publication and cleanup use the request UUID plus generation. Numeric counters alone do not identify requests across sessions.
- `clearDraft` finishes a request even before its first delta; incomplete filtered prefixes use nonterminal `hideDraft`. Carry the synchronously captured monotonic request start through drafts and answers.
- `MeetingCoachState` is the sole owner of displayed answers. Preserve the nonactivating panel, keyboard release sequence, and the existing final transcript path.
- Tests inject routes, clocks, capture closures, and gates. Test race outcomes with gates rather than real transports or visible windows. Preserve the existing live engine `countUsage: false` guards.

## Gotchas

- A late result can outlive a stopped session and arrive while a new session shares the same coach state. Generation and request ownership must guard cleanup as well as publication.
- `AppSettings` uses persisted property wrappers; observe the persisted Screen Context key directly in the card for immediate visibility changes.
- The memo uses the non-card route. The suggested-question rail was removed; do not restart a background suggestions service.
- The controller owns two nonactivating surfaces with shared 300 ms hover and a held-top answer viewport. Rendering tests use `ordersWindows: false`. Ordering and attachment tests keep production ordering enabled and inject `panelOrdering` to model visibility and child detachment; never show windows in headless checks.
- Hidden answer and shadow panels stay detached. Attach only presented surfaces, position them, then apply final ordering; attachment to a visible parent can itself show a child.
- The controller measures an immutable render snapshot before installing it in one native/SwiftUI transition. A measurement-only Ask field has no focus callback. Native editor text and Send feedback remain local; typing, speaker polling, elapsed time and wave samples do not request geometry.
- A coalesced invalidation may arrive after a request finishes. Recheck measured draft ownership immediately before installation, including after measurement callbacks; retire its diagnostics interval and schedule a fresh snapshot when ownership changed.
- Observe the state's explicit render inputs, then compare layout inputs separately from header/chip feedback. Content-only commits preserve active native animation ownership. Equal-height new answer/tab identities still reset scroll. When a parent animates its origin, submit dependent child frame targets even if a child's frame currently equals its target.
- Transition diagnostics accept only closed kinds and counts; balance canceled and superseded signpost intervals. Count each coordinated geometry transaction once, not each setter, and keep counts owned by that transition. Settled tests also compare raw frame writes after deferred layout and native notifications so late corrections cannot hide behind a summary.
- Transcript-tail caching belongs to `MeetingCoachState` and is invalidated by `transcriptDidChange` or provider replacement; the session remains the accepted-line owner. Cache Markdown only for the displayed block revision. Do not read the transcript provider for an Answers snapshot. Lifecycle methods reset derived caches; retained answers keep their existing state policy and may be rendered again while hiding.
- Speaker, elapsed time and wave observations belong to capsule subviews. Wave inputs are throttled before main delivery; counting only published bars does not verify this boundary. Hosts without size-report consumers must not schedule measurement tasks.
- `recordingSurface` follows recording generation and the hints setting. `panelHidden` survives settings off/on within that generation; neither Hide nor Transcript changes answer eligibility.
- Release the native editor before removing Ask. Unsent text survives session replacement; the advisor clears it when recording ends.
- Transcript is a computed last-four projection over accepted session lines, with stable ordering for equal start times. No card-owned transcript store.
- Every accepted-line UI publication after an await rechecks the session stop token and recording generation.
- Render tests need `METAWHISP_RENDER_DIR`; they are an explicitly allowed opt-in skip in the regression gate. The renderer proves offscreen structure, not live Space, focus-return, or click-through acceptance.
