# TDD — Test-Driven Development paired with Karpathy

**Source pair:** This protocol travels TOGETHER with `specs/KARPATHY.md`. Reading
one without the other = bug behaviour, not preference.

---

## Why TDD pairs with Karpathy

Karpathy's four principles map onto the red-green-refactor loop without any
adaptation. They reinforce each other:

| Karpathy | TDD step | Result |
|---|---|---|
| **1. Think Before Coding** | RED — write the failing test that describes intent | The test IS the surfaced understanding. No silent assumptions. |
| **2. Simplicity First** | GREEN — write the LEAST code that turns the test green | Minimum solution. No speculative branches, no flexibility nobody asked for. |
| **3. Surgical Changes** | REFACTOR — clean up only what your green code created | The test guards the existing contract; you only edit code your changes introduced. |
| **4. Goal-Driven Execution** | The test list IS the success criterion | Loop until tests pass. No ambiguity about "done". |

So: **before any non-trivial change, write the test first. Before any bug fix,
write a test that reproduces the bug.** That's not bureaucracy — it's the
Karpathy "Goal-Driven Execution" principle in operation.

---

## When TDD applies (in MetaWhisp)

✅ **Pure-function logic** — parsers, validators, hallucination filters,
   string/date/RMS calculations, state-machine transitions.

✅ **Service-layer business rules** — conversation grouping windows, retry
   policy, dedup logic, prompt-output parsers.

✅ **Bug fixes** — the bug-reproducing test goes in BEFORE the fix. Stays in
   the suite forever as a regression guard.

✅ **Anything where you'd otherwise add a "manual verify in app" comment.**

❌ **DOES NOT apply** to:

- SwiftUI `View` body code — visual regressions need manual swap-test, not
  unit assertions.
- TCC-gated services (mic, screen, calendar) — require live system permissions.
- LLM prompts themselves — output is non-deterministic; only the *parser* of
  the LLM output is testable.
- NSWindow / NSPanel / hosting-view lifecycle — runtime behavior, manual.
- Pro-proxy network calls — would need a mock server harness; out of scope v1.

When unsure: ask "is this a pure function of its inputs?" → if yes, TDD it.

---

## The loop (one-track-at-a-time per Karpathy)

```
1. RED      Write a failing test that captures the next tiny behavior.
            Build runs; test runs; test FAILS.
2. GREEN    Write the simplest production code that passes that test.
            All existing tests still pass.
3. REFACTOR Clean up the green code. Tests still pass on every keystroke.
4. COMMIT   Spec section + tests + production code + (if applicable) WAL note.
```

If you're tempted to write production code without a test in front of you,
re-read step 1. Karpathy "Think Before Coding" is being violated.

---

## Setup in this project

- **Test target:** `MetaWhispTests` declared in `Package.swift`.
- **Path:** `Tests/MetaWhispTests/`.
- **Framework:** XCTest (Swift Testing in v2 once we move to Swift 6 toolchain).
- **Run:** `swift test` (debug). ~30s incremental after first cold build.
- **Imports:** test files use `@testable import MetaWhisp` to reach
  `internal` symbols (most of our service-layer code is `internal`).

The main `MetaWhisp` target excludes `Tests/` so a normal `swift build` does
not compile or link the test code.

---

## File-naming convention

```
Tests/MetaWhispTests/
  SmokeTests.swift                           — proof of life for infrastructure
  Services/Audio/MeetingRecorderTests.swift  — mirrors source path
  Services/System/HallucinationFilterTests.swift
  Services/Intelligence/ConversationGrouperTests.swift
  ...
```

Mirror the source layout. Test class name = `<Type>Tests`. Test method names
read as English sentences: `func test_mix_concatenatesShorterTailWhenSystemLonger()`.

---

## Anti-patterns (per Karpathy "Simplicity First")

- ❌ Testing implementation details — assert on outputs, not internal state.
- ❌ Mocks for things that aren't mocked yet — write a real test of a real
  pure function before reaching for mocking machinery.
- ❌ Test "frameworks" / abstract base classes for tests — keep tests flat.
- ❌ Speculative test for code you "might add later" — write tests as you
  write production code, not before features are agreed.
- ❌ Test code that shouldn't be tested (UI/TCC/network) — move logic OUT of
  those layers into testable pure functions, then test those.

---

## Karpathy + TDD success looks like

- A bug report → reproducing test → fix → test goes green → ship. No detours.
- A new pure-function feature → the test list is written first → code follows
  one test at a time → refactored → committed.
- Every test in the suite has a clear caller (no orphan tests for code that
  was deleted).
- `swift test` is fast enough that you run it on every save.
- The test suite catches at least one regression a week that would otherwise
  have shipped.
