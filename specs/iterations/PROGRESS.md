# Iteration Progress

## Active specification

`ITER-062-layout-auto-switch.md`

## Current iteration

Planning complete. Product source has not changed.

## Master checklist

- [x] Competitor and platform research
- [x] User stories, permission contract, production architecture
- [x] UI, visual feedback, privacy metrics, and test gates
- [ ] I0 signed TCC/event-tap proof
- [ ] I1 pure mapper/confidence TDD
- [ ] I2 replacement gateway/input-source TDD
- [ ] I3 controller/auto/Double Shift TDD
- [ ] I4 UI/metrics
- [ ] I5 release verification

## Known constraints

- Automatic global correction cannot operate until macOS permits the required
  Accessibility/Input Monitoring path. The setting defaults to requested ON,
  not falsely active.
- No raw typed content may be retained or logged.
- Existing working-tree changes are user-owned and out of scope.

## Next step

I0: prove the TCC/event-tap behaviour in a Developer-ID signed installed app
without implementing the product feature.
