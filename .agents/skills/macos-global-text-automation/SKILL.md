---
name: macos-global-text-automation
description: Use when MetaWhisp observes global keyboard input, changes the active input source, or replaces text in another macOS app.
---

# MetaWhisp macOS global text automation

Use this skill for layout switching, global text correction, and any feature
that observes input or edits a focused application outside MetaWhisp.

## Scope and release environment

- MetaWhisp is a direct-download, Developer-ID-signed and notarized macOS app,
  not a sandboxed Mac App Store target. Keep its stable signing identity: TCC
  grants are tied to the code identity.
- The existing `HotkeyService` uses `NSEvent` monitors for Right Command and
  Right Option. New continuous keyboard observation must use a separately
  owned lifecycle service; do not mix its state machine into dictation hotkeys.
- The app already has a `TextInsertionService` with verified pasteboard writes
  and `SelectionTranslator` with a copy/paste flow. Do not duplicate either
  without first extracting a shared, tested text-replacement seam.

## Permission and privacy contract

- A user preference may default to enabled, but the effective global feature
  is inactive until macOS grants the required Accessibility/Input Monitoring
  access. Never imply that a denied TCC permission still permits global
  observation or replacement.
- Model this as explicit states: `off`, `needsPermission`, `active`, and
  `blocked`. A denial is not an error loop: explain the limitation and provide
  a user-initiated route to System Settings.
- Never persist or remotely transmit observed keystrokes, candidate words,
  selected text, passwords, or clipboard content. Product metrics must be
  aggregate counters only.
- Reject secure text fields and high-risk contexts before looking at word
  contents. Maintain a dedicated layout-switch app exclusion list; do not
  reuse the unrelated Screen Context blacklist.

## Interaction invariants

- Keep automatic correction, Double Shift correction, and explicit clipboard
  conversion as distinct modes behind one pure conversion engine.
- A correction must be high-confidence and undoable by the target app's
  standard `Command-Z`. Never auto-correct merely because conversion changes
  script.
- Preserve the user's pasteboard transactionally. Restore it only when its
  change count still proves that no other process or user copy has intervened.
- Use a dedicated, non-activating visual feedback controller. Do not overload
  `RecordingOverlayController` state or steal the front application's focus.
- Re-check the front app and focused control immediately before any synthetic
  replacement; abandon rather than paste into a changed target.

## Verification

- Pure mapping and confidence code gets XCTest first, including capitals,
  punctuation, emoji, deletes/navigation, low confidence, and an ordinary
  English word that must not become Cyrillic.
- Permission, event tap, selection replacement, and UI feedback require a
  Developer-ID-signed live-app manual matrix. A successful build or unit test
  does not prove macOS TCC behaviour.
- Exercise at least a native editor, Chromium browser, Safari, Slack/Telegram,
  VS Code, a password field, Terminal/iTerm, and an excluded app. Record
  unsupported-app failures honestly; do not silently fall back to a blind
  paste.

## Gotchas

- Do not implement a single-Shift global shortcut: it collides with normal
  uppercase typing. Detect two clean Shift press/release cycles with no
  intervening key instead.
- Do not use an LLM for auto-switch confidence. It adds latency, cost, and
  non-determinism to a local keyboard path.
- Adding a SwiftData model requires migration scrutiny. Prefer bounded
  UserDefaults aggregate metrics unless durable event history is explicitly
  required.
