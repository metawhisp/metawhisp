# Iteration Progress

## Active specification

`ITER-062-layout-auto-switch.md`

## Current iteration

I3 in progress. The first local vertical slice is wired into the normal app:
it buffers one word in RAM, applies only conservative local RU↔EN confidence,
revalidates the focused AX text field, selects the target macOS input source,
and shows a 1.4-second non-activating toast. It also recognises two clean
Shift releases in 400ms, then converts the selection or only the immediate
previous word. It never logs or persists typed text. The remaining live check
is physical input in TextEdit; UI automation actions deliberately do not
traverse a listen-only event tap. Live diagnostics proved that the monitor and
EN→RU confidence path see the candidate but ran before the target app had
committed its separator, so the AX gateway safely returned `staleTarget`.
Automatic correction now waits 16ms, revalidates the focused field, and logs
only the outcome (never text). Double Shift delivery is also proven by live
logs; its failed manual conversion path previously depended on a full `AXValue`
read. It now reads only selected text or a 128 UTF-16-character Accessibility
window immediately before the caret, with the native-editor `AXValue` fallback
bounded to the same window. A live editor then acknowledged the AX text-write
but visibly retained the original text. The replacement path now verifies the
exact bounded range before emitting feedback; when direct AX mutation is not
real, it uses the shared selected-text paste seam, confirms the result, and
restores the full clipboard snapshot only if its change count is unchanged.
The first verified-replacement build then logged a candidate without an
outcome: the controller had cancelled its own pending correction on a later
key event. Pending automatic work is now cancelled only by shutdown or a
newer candidate; Double Shift also records a content-free gesture marker for
the live test. Controller dependency seams now allow deterministic async
tests to prove automatic and Double Shift dispatch reaches the text gateway
and switches input source only after a verified success (including a failed
replacement non-switch case). The focused test profile is 38/38 green and the
full package suite is 830 passed / 4 skipped / 0 failed. The installed
Developer-ID-signed local app is active; only the physical global event and
real AX editor mutation still require native keyboard input.

The first physical retry reached AX replacement but stopped immediately when
the clipboard fallback tried to call `copy()` on `NSPasteboardItem`; that
Objective-C exception left the correction without a terminal result. The
fallback now copies every available pasteboard representation explicitly,
waits 150 ms for the AX selection to commit, posts Command-V directly to the
checked target process, verifies before restoring the transaction, and
preserves an intervening user copy. Automatic correction retries exactly once
when the editor has not yet committed its separator, then otherwise fails
closed. The regression tests for both restoration branches and the stale-target
retry are green; the final local Developer-ID-signed build is installed and
awaits the same physical retry.

## Master checklist

- [x] Competitor and platform research
- [x] User stories, permission contract, production architecture
- [x] UI, visual feedback, privacy metrics, and test gates
- [ ] I0 signed TCC/event-tap proof — active state verified; physical-event
  delivery pending
- [x] I1 pure mapper/confidence TDD — 8 tests green
- [x] I2 replacement gateway/input-source TDD — 7 tests green
- [ ] I3 controller/auto/Double Shift TDD — automatic and Double Shift paths
  wired; signed-app physical event/AX proof remains
- [ ] I4 UI/metrics
- [ ] I5 release verification

## Known constraints

- Automatic global correction cannot operate until macOS permits the required
  Accessibility/Input Monitoring path. The setting defaults to requested ON,
  not falsely active.
- No raw typed content may be retained or logged.
- Existing working-tree changes are user-owned and out of scope.

## Next step

Repeat the original scenario in the editor where the toast appeared without a
text change. A toast must now mean the text changed. In TextEdit, switch to
English, type `ghbdtn` without a trailing space and press two clean Shift
taps; it should become `привет`, change the input source to Russian, and show
the EN → RU toast. Do not use a password or sensitive input for this check.
