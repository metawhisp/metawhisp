# ITER-074 — round 12, correction: the step ceiling is about starting a step

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Do exactly what is written; change
nothing else. Tests English only; never `await` inside `XCTAssert…(…)`.

## The problem
§8: "40 steps" means at most 40 Choose requests. The loop counts a step (`budget.countStep()`) right before
its Choose call, and every `checkpoint()` — including the one inside `paid()` for that very Choose, the ones
before the step's action, and the ones before the Sheet — treats `steps >= limit` as a ceiling. So the step
that reaches the limit is blocked at its own Choose, and an errand that finishes on its last allowed step
loses its Sheet. Only the check at the top of the loop, before a new step starts, may count steps; every
other check still covers Stop, active time, spend and the expiry.

---------------------------------------------------------------------------------------------------------
## PHASE A — tests (they must FAIL on the current code)
---------------------------------------------------------------------------------------------------------

### A1. `Tests/MetaWhispTests/Services/Agent/AgentPolicyTests.swift`
Insert right before the line `    /// Only the time the errand spends working counts towards 600 seconds;`:
```swift
    /// The step ceiling is about starting a new step: a check made inside a
    /// step leaves it out, and still sees every other ceiling.
    func testTheStepCeilingCanBeLeftOutInsideAStep() {
        var budget = AgentBudget(startedAt: start)
        for _ in 0..<40 { budget.countStep() }
        XCTAssertEqual(budget.ceiling(now: start), .steps)
        XCTAssertNil(budget.ceiling(now: start, countingSteps: false))
        XCTAssertEqual(budget.ceiling(now: start.advanced(by: .seconds(1_800)), countingSteps: false), .expiry)
    }

```

### A2. `Tests/MetaWhispTests/Services/Agent/AgentRunTests.swift`
Insert right before the line `    /// No paid call starts after the expiry, and a call's deadline never runs`:
```swift
    /// An errand that finishes on its last allowed step still finishes: that
    /// step's Choose, its row and the Sheet all happen.
    @MainActor
    func testTheLastAllowedStepStillFinishesTheErrand() async throws {
        let bridge = WebViewBridge()
        let sheet = FixtureSheet()
        let limits = AgentBudget.Limits(steps: 6, activeSeconds: 600, spendMicros: 500_000, expiry: .seconds(1_800))
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }),
                           limits: limits)
        let record = await run.run()
        XCTAssertEqual(record.ending, .done)
        XCTAssertEqual(record.rows.count, 3)
        XCTAssertEqual(sheet.title, "Competitors")
    }

```

### A3. Compile stub — `Services/Agent/AgentPolicy.swift`
Replace the signature line `    func ceiling(now: ContinuousClock.Instant) -> Ceiling? {` with
`    func ceiling(now: ContinuousClock.Instant, countingSteps: Bool = true) -> Ceiling? {`
(the new parameter is unused in phase A).

End of phase A. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fix
---------------------------------------------------------------------------------------------------------

### B1. `Services/Agent/AgentPolicy.swift`, `struct AgentBudget`
1. Replace the doc line right above `func ceiling(` — `    /// The first ceiling reached, or nil.` — with
```swift
    /// The first ceiling reached, or nil. The step ceiling is about starting
    /// a new step, so a check made inside a step passes `countingSteps: false`.
```
2. In `ceiling(now:countingSteps:)` replace `        if steps >= limits.steps { return .steps }` with
   `        if countingSteps, steps >= limits.steps { return .steps }`.

### B2. `Services/Agent/AgentRun.swift`
1. Replace the doc comment and the signature of `checkpoint()`:
```swift
    /// Brings the work clock up to date — waits for the user left out — and
    /// throws at Stop or at a ceiling (§7.4, §8). Called before every step and
    /// right before every effect, so neither is noticed only after the fact.
    private func checkpoint() throws {
```
   with
```swift
    /// Brings the work clock up to date — waits for the user left out — and
    /// throws at Stop or at a ceiling (§7.4, §8). Called before every step and
    /// right before every effect, so neither is noticed only after the fact.
    /// Only the check before a new step counts steps: the step ceiling is
    /// about starting one.
    private func checkpoint(countingSteps: Bool = false) throws {
```
2. In the same function replace `        if budget.ceiling(now: .now) != nil { throw CeilingReached() }` with
   `        if budget.ceiling(now: .now, countingSteps: countingSteps) != nil { throw CeilingReached() }`.
3. In `loop(in:)` replace
```swift
        while scratchpad.rows.count < plan.rowsWanted {
            try checkpoint()
```
   with
```swift
        while scratchpad.rows.count < plan.rowsWanted {
            try checkpoint(countingSteps: true)
```

End of phase B. Reply with the list of files you changed.
