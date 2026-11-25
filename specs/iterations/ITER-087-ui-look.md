# ITER-087 — the new look on the 1.4.7 layout

Status: plan, waiting for the owner's approval. Branch `feat/ui-look` (lane `lane-look`) from `d9b6d2b`
(= shipped 1.4.7). Reference: design canvas board 10, version 19 (the owner on 2026-11-25: «кайф давай внесем
изменения»).

## Owner decisions (2026-11-25)
1. Every screen at once, through the design system — not screen by screen.
2. The accent stays the user's choice (Settings accent picker). The new look takes the chosen accent everywhere;
   nothing hard-codes mint.
3. New users get Mint by default (today Mono). An existing choice is kept.
4. The main window and the menu-bar popover change together (no new items in the popover). Onboarding and the
   recording indicator are not touched; the blue "Transcribing" stage goes to BACKLOG.
5. When the tests pass: a test build on the owner's Mac; release 1.4.8 only on his word.

## Cause of the flat grey look (confirmed by reading the code, 2026-11-25)
- `PageWash` (`Views/Components/GlassPrimitives.swift`) is the window's wall: a 0.07 grey with a slate-blue radial.
- Three screens cover it whole with an opaque `MW.bg`: `DictionaryView:51`, `HistoryView:30`,
  `MainSettingsView:83`. Dashboard does so only in its empty state (`StatisticsView:565`); `TasksView:320` paints a
  task-candidate card with it and a square stroke (the old BLOCKS card).
- Surfaces with no wall paint `MW.bg` as their ground: the popover (`MenuBarView:25`), the About Me sheet
  (`AboutMeView:34`), the app picker (`AppPickerView:60`).
- Panels, chips and the sidebar are system materials (`.thinMaterial` …), which read grey on a grey wall.
(Corrected while starting step 1: the first draft said six screens cover the wall; three do.)

Owner layer: `Helpers/DesignSystem.swift` (tokens, `mwCard`, `mwBadge`, `glassChip`, `Keycap`, `BlocksButton`) and
`Views/Components/GlassPrimitives.swift` (`SidebarItem`, `GlassChipButton`, `SegmentedGlass`, `PageWash`).
Screens change only where they paint over the wall or hard-code caps text.

## User stories
- US1 — As a user in the dark theme I see a near-black wall with a glow in my accent and panels drawn by a thin
  edge, so the app looks current. Accept: no screen of the window or the popover paints a flat grey; no blue in
  the wall or the panels.
- US2 — As a user in the light theme I see white frosted panels on a light wall with soft shadows instead of
  frames. Accept: panels are white, the accent appears only on live things (switches, bars, selection).
- US3 — As a user I find everything where it was. Accept: each screen keeps its blocks and their order; renders
  match the 1.4.7 screenshots in layout.
- US4 — As a user I read labels and numbers in full. Accept: at the minimum window width (~960 pt) the Dashboard
  tile labels and the Settings hotkey titles show without "…".
- US5 — As a new user I get the Mint accent; as an existing user I keep mine. Accept: default `accentColor` is
  `mint`; a stored value is untouched.

## Steps (one commit each; tests and `bash scripts/regression.sh` after each)
1. **Palette as a value.** `MW.Palette(dark:accent:)` holds the wall, panel, edge, highlight, selection and label
   colours; the `MW` tokens read it. RED first: no blue-dominant colour in the wall, panel or edge of either theme;
   dark wall near-black; light panel white; selection built from the accent.
2. **Wall.** `PageWash` draws the palette wall plus an accent glow at the top right; the blue radial goes. The three
   screens and Dashboard's empty state stop painting `MW.bg`; the popover, the About Me sheet and the app picker
   take `PageWash` as their ground. A source guard keeps `.background(MW.bg)` out of the views (onboarding, left
   alone by decision 4, is the one exception). The Tasks candidate card moves to step 3 (it is a panel).
3. **Panels.** `mwCard` / `blocksPanel` and the sidebar draw the palette panel (dark: a faint white gradient, a
   1 pt edge, a top highlight; light: white with a soft shadow) instead of a system material.
4. **Selection and controls.** `SidebarItem`, `SegmentedGlass`, `GlassChipButton`, `glassChip`, `BlocksButton`:
   selected = accent tint and ring (dark) / white pill with a shadow (light). The Settings ON/OFF box becomes a
   switch in the accent; the task checkbox grows to 16 pt and the close × gets a 20 pt hit area.
5. **Type.** `mwBadge` / `blocksLabel` = SF Mono caps micro-label (section headers and tile captions only); big
   numbers in SF Pro bold with tabular digits; chips, buttons and row titles in sentence case (inventory: 98 caps
   literals in 18 view files and 46 `.uppercased()` calls; section labels stay caps). Split per screen.
6. **Accent default.** `accentColor` defaults to `mint`. RED test first.
7. **Check.** Off-screen PNG renders (the `METAWHISP_RENDER_DIR` pattern of `MainSettingsHotkeyRenderTests`) of
   Dashboard, Tasks, Settings and the popover, dark and light, at 960 and 1280 pt, compared with board 10; the
   regression gate; a Codex review (at most 3); a test build on the owner's Mac; release on his word.

## Corner cases (checked after every step)
Accent Mono (the glow becomes white or black), accent Electric (the user's own blue is allowed), theme Auto
flipping while the window is open, the minimum window width, the store-recovery overlay readable on the new wall,
the popover over a bright desktop.

## Risks
- Step 5 touches many files; it goes screen by screen, and tests that pin caps text change in the same commit as
  the behaviour they pin.
- Without system materials the panels no longer blur what is behind them; nothing sits behind them but the wall.

## Estimate
Steps 1–4 about 5 h, step 5 3–4 h, step 6 15 min, step 7 about 2 h with a cold build: about 1.5 working days.
