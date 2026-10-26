# ITER-074 — review round 11 fixes (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp (Swift package). Read `specs/iterations/ITER-074-agent-layer.md`
§7.1, §7.2, §7.4, §8 if you need context. You CANNOT build or run tests: the orchestrator compiles and
sends you the errors. Do exactly what is written; do not change anything else, do not reformat, do not
rename, do not add files other than the ones listed.

## Hard rules
1. Tests are English only — no Cyrillic characters in any test file.
2. Never put `try await` or `await` inside `XCTAssert…(…)` arguments. Assign to a `let` first.
3. JavaScript lives inside Swift raw strings `#"""` … `"""#`; inside them a backslash is literal.
4. Use `ContinuousClock` / `SuspendingClock` and `Duration`, never `Date`, for anything measured.
5. Keep the existing doc-comment style: short `///` lines, wrapped at ~110 columns.
6. When a step says "replace A with B", A must match the file exactly once.

## The five problems (all confirmed in the code)
1. Stop only flips a flag: an await between the last check and an effect lets an action or the Sheet
   happen after Stop; an open question to the user is not cancelled; the ending can stay `.done`.
2. A Yes is checked on a fresh observation, then an await passes before the act, and the act script only
   compares the fingerprint fields — a button whose aria-label stays "Confirm payment" but whose text
   changes from "Pay $10" to "Pay $100" is still pressed.
3. The ceilings are checked only between steps: a question started at 29:59 can get a Yes at 31:58 and act.
4. A hidden field named "Password" is never classified (only visible fields are), so its content can become
   a visible button's name through `aria-labelledby`.
5. A grant ("Allow access") goes through the normal Yes/No question; §7.2 says the agent never grants
   anything — a grant is handed to the user and never asked about.

---------------------------------------------------------------------------------------------------------
## PHASE A — tests, fixtures and compile stubs (the new tests must FAIL on the current code)
---------------------------------------------------------------------------------------------------------

### A1. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-29.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Twenty-Nine</title></head>
<body>
<main>
  <h1>Connect Acme</h1>
  <p>Acme wants to access your files.</p>
  <form action="https://site-29.test/granted" method="post">
    <button type="submit">Allow access</button>
  </form>
  <a href="https://site-29.test/cancel">Cancel</a>
</main>
</body>
</html>
```

### A2. `Tests/MetaWhispTests/Fixtures/Agent/pages/site-26.html`
Replace
```
  <div id="notes" contenteditable="true" aria-label="Notes editor"
```
with
```
  <button id="pay" aria-label="Confirm payment" onclick="document.title = 'Paid'">Pay $10</button>
  <div id="notes" contenteditable="true" aria-label="Notes editor"
```

### A3. `Tests/MetaWhispTests/Fixtures/Agent/pages/site-28.html`
Replace
```
  <x-bare id="bare">Unrendered host text</x-bare>
```
with
```
  <x-bare id="bare">Unrendered host text</x-bare>
  <div id="vault" role="combobox" aria-label="Password" hidden>secret-in-label</div>
  <button aria-labelledby="vault">Unlock</button>
```

### A4. `Tests/MetaWhispTests/Services/Agent/SafetyGuardTests.swift`
Insert this block right before the line `    func testNegationsAndScopesAreRead() {`:
```swift
    // MARK: - Grants (§7.2, review round 11)

    /// The agent never grants anything: an action whose words grant — allow,
    /// grant, authorize — in what it shows or where it goes is the user's part.
    /// A label that names cookies is consent to cookies, not a grant
    /// (decision 15).
    func testAGrantIsRecognised() {
        func click(_ name: String, formAction: String? = nil) -> AgentAction {
            AgentAction(operation: .click, target: element(name: name, formAction: formAction), destination: nil,
                        payload: nil, isPlannedSearch: false)
        }
        XCTAssertTrue(SafetyGuard.isGrant(click("Allow access")))
        XCTAssertTrue(SafetyGuard.isGrant(click("Authorize Acme")))
        XCTAssertTrue(SafetyGuard.isGrant(click("Continue", formAction: "https://id.test/oauth/authorize")))
        XCTAssertFalse(SafetyGuard.isGrant(click("Allow all cookies")))
        XCTAssertFalse(SafetyGuard.isGrant(click("Send")))
        XCTAssertFalse(SafetyGuard.isGrant(AgentAction(operation: .scroll, target: nil, destination: nil, payload: nil,
                                                       isPlannedSearch: false)))
    }

```

### A5. `Tests/MetaWhispTests/Services/Agent/ActionScriptTests.swift`
Insert this block right before the line `    // MARK: - Review round 9: the page's own handlers, a cut address`:
```swift
    // MARK: - Review round 11: a Yes holds only for what was approved

    /// An approved action checks, in the same script as the act, that the
    /// page and the element's words are still what the user said yes to: a
    /// button whose label stays "Confirm payment" but now shows "Pay $100" is
    /// not pressed.
    @MainActor
    func testAnApprovedActionIsNotTakenWhenItsWordsChanged() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let pay = try XCTUnwrap(named("Confirm payment", in: page))
        let approval = ActionScript.Approval(pageURL: page.url, text: pay.text, formSubmitLabel: pay.formSubmitLabel)
        _ = try await bridge.run("document.getElementById('pay').textContent = 'Pay $100'; ''", in: tab)
        let script = try XCTUnwrap(ActionScript.source(for: action(.click, on: pay), on: page, approval: approval))
        let outcome = try ActionOutcome.decode(try await bridge.run(script, in: tab))
        XCTAssertEqual(outcome.outcome, .gone)
        let title = try await bridge.run("document.title", in: tab)
        XCTAssertEqual(title, "Site Twenty-Six", "nothing was paid")
    }

    @MainActor
    func testAnApprovedActionIsTakenWhenNothingChanged() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let pay = try XCTUnwrap(named("Confirm payment", in: page))
        let approval = ActionScript.Approval(pageURL: page.url, text: pay.text, formSubmitLabel: pay.formSubmitLabel)
        let script = try XCTUnwrap(ActionScript.source(for: action(.click, on: pay), on: page, approval: approval))
        let outcome = try ActionOutcome.decode(try await bridge.run(script, in: tab))
        XCTAssertEqual(outcome.outcome, .done)
        let title = try await bridge.run("document.title", in: tab)
        XCTAssertEqual(title, "Paid")
    }

```

### A6. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`
Insert this block right before the line `    // MARK: - Shadow DOM, dialogs, hostile text`:
```swift
    /// A hidden field's secret cannot become another element's name through
    /// aria-labelledby: a field is judged sensitive whether it is shown or not
    /// (review round 11).
    @MainActor
    func testAHiddenSecretNeverBecomesAName() async throws {
        let page = try await observe("https://site-28.test/")
        XCTAssertNotNil(named("Unlock", in: page))
        XCTAssertFalse(page.elements.contains { $0.name.contains("secret") || $0.text.contains("secret") })
    }

```

### A7. `Tests/MetaWhispTests/Services/Agent/AgentRunTests.swift`
(a) Insert this block right before the line `    // MARK: - Stop` (keep everything else):
```swift
    // MARK: - Grants

    /// A grant is never asked about and never taken: it is handed to the user
    /// (§7.2).
    @MainActor
    func testAGrantIsHandedToTheUserNotAskedAbout() async throws {
        let bridge = WebViewBridge()
        let answers = Answers()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Allow access" })
        })
        let run = AgentRun(plan: try plan(search: "https://site-29.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { request in
                                                    answers.asked.append(request)
                                                    return .yes
                                                }))
        let record = await run.run()
        XCTAssertEqual(record.ending, .needsUser)
        XCTAssertTrue(answers.asked.isEmpty, "a grant is not asked about")
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/granted" }, "nothing was granted")
        XCTAssertEqual(record.steps.last?.outcome, .handedOver)
    }

```
(b) Replace the whole existing `// MARK: - Stop` section — from the line `    // MARK: - Stop` down to the
test `testStopBeforeTheFirstStepDoesNothing` and its closing brace — with the block below, which keeps that
test unchanged and adds four more tests and the helpers they use. The class's final closing `}` must stay.
```swift
    // MARK: - Stop (§7.4)

    /// Stop before the run starts: nothing is opened and nothing is written.
    @MainActor
    func testStopBeforeTheFirstStepDoesNothing() async throws {
        let bridge = WebViewBridge()
        let sheet = FixtureSheet()
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }))
        run.stop()
        let record = await run.run()
        XCTAssertEqual(record.ending, .stopped)
        XCTAssertTrue(bridge.openedURLs.isEmpty)
        XCTAssertNil(sheet.title)
    }

    /// Stop pressed during the very last await before an action is sent: the
    /// action is not sent.
    @MainActor
    func testStopRightBeforeAnActionSendsNothing() async throws {
        let button = StopButton()
        let bridge = StopAtFirstMarker(button: button)
        let sheet = FixtureSheet()
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }))
        button.run = run
        let record = await run.run()
        XCTAssertEqual(record.ending, .stopped)
        XCTAssertFalse(bridge.inner.navigatedURLs.contains { $0.host == "site-1.test" }, "nothing was opened after Stop")
        XCTAssertNil(sheet.title)
        XCTAssertEqual(bridge.inner.openTabCount, 0)
    }

    /// Stop ends an open question at once — it does not wait for the answer.
    @MainActor
    func testStopDuringAQuestionEndsTheErrandAtOnce() async throws {
        let bridge = WebViewBridge()
        let button = StopButton()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" })
        })
        let run = AgentRun(plan: try plan(search: "https://site-7.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in
                                                    button.press()
                                                    try? await Task.sleep(for: .seconds(60))
                                                    return .yes
                                                }))
        button.run = run
        let clock = ContinuousClock()
        let started = clock.now
        let record = await run.run()
        XCTAssertEqual(record.ending, .stopped)
        XCTAssertLessThan(clock.now - started, .seconds(10), "Stop ended the question at once")
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/send-message" })
    }

    /// Stop while the Sheet is being made: nothing is pasted.
    @MainActor
    func testStopBeforeThePasteWritesNothing() async throws {
        let bridge = WebViewBridge()
        let button = StopButton()
        let sheet = StoppingSheet(button: button)
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }))
        button.run = run
        let record = await run.run()
        XCTAssertEqual(record.ending, .stopped)
        XCTAssertEqual(sheet.pastes, 0)
        XCTAssertNil(record.sheet)
        XCTAssertEqual(record.rows.count, 3, "what was collected is kept")
    }

    // MARK: - Ceilings (§8)

    /// Whatever the pauses, the errand ends at its expiry: a Yes that comes
    /// after it is not acted on.
    @MainActor
    func testAYesAfterTheExpiryIsNotActedOn() async throws {
        let bridge = WebViewBridge()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" })
        })
        let limits = AgentBudget.Limits(steps: 40, activeSeconds: 600, spendMicros: 500_000, expiry: .seconds(1))
        let run = AgentRun(plan: try plan(search: "https://site-7.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in
                                                    try? await Task.sleep(for: .milliseconds(1_500))
                                                    return .yes
                                                }),
                           limits: limits)
        let record = await run.run()
        XCTAssertEqual(record.ending, .ceiling)
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/send-message" }, "a Yes after the expiry counts for nothing")
    }

    /// At a ceiling the errand stops: what was collected is kept, and no
    /// Sheet is made.
    @MainActor
    func testAtACeilingNoSheetIsWritten() async throws {
        let bridge = WebViewBridge()
        let sheet = FixtureSheet()
        let limits = AgentBudget.Limits(steps: 2, activeSeconds: 600, spendMicros: 500_000, expiry: .seconds(1_800))
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }),
                           limits: limits)
        let record = await run.run()
        XCTAssertEqual(record.ending, .ceiling)
        XCTAssertEqual(record.rows.count, 1, "what was collected is kept")
        XCTAssertNil(sheet.title, "no Sheet at a ceiling")
    }

    // MARK: - Helpers

    /// Lets a test's bridge, question or sheet press Stop on the run it is
    /// part of.
    @MainActor
    private final class StopButton {
        var run: AgentRun?
        func press() { run?.stop() }
    }

    /// The fixture browser, pressing Stop the first time the run reads the
    /// page's marker after it has observed a page — the last await before an
    /// action is sent.
    @MainActor
    private final class StopAtFirstMarker: BrowserBridge {
        let inner = WebViewBridge()
        private let button: StopButton
        private var observed = false
        private var pressed = false

        init(button: StopButton) { self.button = button }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            let result = try await inner.run(javascript, in: tab)
            if javascript == ObserverScript.source { observed = true }
            if observed, !pressed, javascript.contains("performance.timeOrigin") {
                pressed = true
                button.press()
            }
            return result
        }
    }

    /// A fixture sheet that presses Stop while it is being created.
    @MainActor
    private final class StoppingSheet: SheetDestination {
        private let inner = FixtureSheet()
        private let button: StopButton
        private(set) var pastes = 0

        init(button: StopButton) { self.button = button }

        func create(title: String) async throws -> URL {
            button.press()
            return try await inner.create(title: title)
        }

        func paste(_ text: String, into sheet: URL) async throws {
            pastes += 1
            try await inner.paste(text, into: sheet)
        }

        func readBack(_ sheet: URL) async throws -> SheetReadBack { try await inner.readBack(sheet) }
    }
```

### A8. Compile stubs (production code) — just enough for the tests to build; behaviour unchanged
1. `Services/Agent/ErrandRecord.swift`, enum `Outcome`: after `case failed` add
   ```swift
        /// A grant or a wall — the user's part (§7.2); nothing was done.
        case handedOver
   ```
2. `Services/Agent/SafetyGuard.swift`, inside `enum SafetyGuard`, right before `    // MARK: - Private` add:
   ```swift
    /// STUB — replaced in phase B.
    static func isGrant(_ action: AgentAction) -> Bool { false }

   ```
3. `Services/Agent/ActionScript.swift`, inside `enum ActionScript`, right before `    /// The script for `action`, chosen from candidates built on `page`. Nil` add
   ```swift
    /// STUB — replaced in phase B.
    struct Approval: Equatable {
        let pageURL: String
        let text: String
        let formSubmitLabel: String?
    }

   ```
   and change the signature `static func source(for action: AgentAction, on page: ObservedPage) -> String? {`
   to `static func source(for action: AgentAction, on page: ObservedPage, approval: Approval? = nil) -> String? {`
   (the parameter is unused in phase A).
4. `Services/Agent/AgentPolicy.swift`, inside `struct AgentBudget`, right after
   `    struct Reservation: Equatable { fileprivate let id: Int }` add
   ```swift

    /// STUB — replaced in phase B.
    struct Limits: Equatable {
        let steps: Int
        let activeSeconds: TimeInterval
        let spendMicros: Int
        let expiry: Duration
        static let standard = Limits(steps: 40, activeSeconds: 600, spendMicros: 500_000, expiry: .seconds(30 * 60))
    }
   ```
5. `Services/Agent/AgentRun.swift`: change the init signature from
   ```swift
    init(plan: AgentPlan, errandID: UUID, collaborators: Collaborators,
         answerWindow: Duration = .seconds(ConfirmationRequest.answerWindow)) {
   ```
   to
   ```swift
    init(plan: AgentPlan, errandID: UUID, collaborators: Collaborators,
         answerWindow: Duration = .seconds(ConfirmationRequest.answerWindow),
         limits: AgentBudget.Limits = .standard) {
   ```
   (`limits` unused in phase A.)

End of phase A. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fixes (make every test pass; change nothing else)
---------------------------------------------------------------------------------------------------------

### B1. Grants — `Services/Agent/SafetyGuard.swift`
Replace the phase-A stub
```swift
    /// STUB — replaced in phase B.
    static func isGrant(_ action: AgentAction) -> Bool { false }
```
with
```swift
    /// §7.2: the agent never grants anything — OAuth, a permission prompt,
    /// «Allow access». Words that grant in what an action shows or where it
    /// goes make it the user's part: it is not asked about, it is handed over.
    /// A label that names cookies is consent to cookies, not a grant
    /// (decision 15).
    static let grantWords: Set<String> = ["allow", "grant", "authorize", "authorise"]
    static let russianGrantStems: [String] = ["разреш"]

    static func isGrant(_ action: AgentAction) -> Bool {
        guard let target = action.target else { return false }
        let texts = [target.name, target.text, target.formSubmitLabel, target.formAction, target.href]
        let found = texts.compactMap { $0 }.flatMap { words(in: decoded($0)) }
        if found.contains(where: { $0.hasPrefix("cookie") || $0.hasPrefix("куки") }) { return false }
        return found.contains { grantWords.contains($0) || russianGrantStems.contains(where: $0.hasPrefix) }
    }
```

### B2. Limits — `Services/Agent/AgentPolicy.swift`, `struct AgentBudget`
1. Replace the phase-A stub `Limits` (from `    /// STUB — replaced in phase B.` through its closing `    }`) with:
```swift
    /// The ceilings themselves: §8's values in the app; tests may lower them.
    struct Limits: Equatable {
        let steps: Int
        let activeSeconds: TimeInterval
        /// Millionths of a dollar, so sums land exactly on the ceiling.
        let spendMicros: Int
        let expiry: Duration

        static let standard = Limits(steps: 40, activeSeconds: 600, spendMicros: 500_000, expiry: .seconds(30 * 60))
    }
```
2. Replace
```swift
    static let maxSteps = 40
    static let maxActiveSeconds: TimeInterval = 600
    static let expirySeconds: TimeInterval = 30 * 60
    /// $0.50. Money is counted in millionths of a dollar, so sums land
    /// exactly on the ceiling instead of a rounding error beside it.
    private static let maxSpendMicros = 500_000

    let startedAt: ContinuousClock.Instant
```
with
```swift
    static let maxSteps = Limits.standard.steps
    static let maxActiveSeconds = Limits.standard.activeSeconds
    static let expirySeconds: TimeInterval = 30 * 60

    let startedAt: ContinuousClock.Instant
    let limits: Limits
```
3. Replace `    init(startedAt: ContinuousClock.Instant) { self.startedAt = startedAt }` with
```swift
    init(startedAt: ContinuousClock.Instant, limits: Limits = .standard) {
        self.startedAt = startedAt
        self.limits = limits
    }
```
4. In `reserve(worstCaseUSD:)` replace `<= Self.maxSpendMicros` with `<= limits.spendMicros`.
5. Replace the body of `func ceiling(now: ContinuousClock.Instant) -> Ceiling?` with
```swift
        if steps >= limits.steps { return .steps }
        if activeSeconds >= limits.activeSeconds { return .activeTime }
        if spentMicros >= limits.spendMicros { return .spend }
        if now - startedAt >= limits.expiry { return .expiry }
        return nil
```
6. Right after `ceiling(now:)` add
```swift

    /// Time left before the absolute expiry; zero once it has passed.
    func timeLeft(now: ContinuousClock.Instant) -> Duration {
        let left = limits.expiry - (now - startedAt)
        return left > .zero ? left : .zero
    }
```

### B3. The approved binding — `Services/Agent/ActionScript.swift`
1. Replace the phase-A stub `Approval` (the `/// STUB — replaced in phase B.` line and the struct) with
```swift
    /// What the user said yes to (§7.1). An approved action checks it in the
    /// same script as the act: the page is still the one the Yes was given
    /// on, and the element still shows the same words and submit label.
    struct Approval: Equatable {
        let pageURL: String
        let text: String
        let formSubmitLabel: String?
    }
```
2. In `source(for:on:approval:)`:
   - replace `            guard let target = action.target else { return navigate(to: destination) }` with
     `            guard let target = action.target else { return navigate(to: destination, approvedOn: approval?.pageURL) }`
   - replace `            return onElement(target, on: page, operation: .open, payload: nil, destination: destination)` with
     `            return onElement(target, on: page, operation: .open, payload: nil, destination: destination, approval: approval)`
   - replace `            return onElement(target, on: page, operation: .click, payload: nil, destination: nil)` with
     `            return onElement(target, on: page, operation: .click, payload: nil, destination: nil, approval: approval)`
   - replace `            return onElement(target, on: page, operation: action.operation, payload: payload, destination: nil)` with
     `            return onElement(target, on: page, operation: action.operation, payload: payload, destination: nil, approval: approval)`
3. In `back(to:)` replace `        return navigate(to: previous.absoluteString)` with
   `        return navigate(to: previous.absoluteString, approvedOn: nil)`.
4. In `private struct Expected`, after `        let destination: String?` add
```swift
        let approved: Bool
        let approvedPageURL: String?
        let approvedText: String?
        let approvedSubmitLabel: String?
```
5. Replace the signature line of `onElement`
```swift
    private static func onElement(_ target: ObservedElement, on page: ObservedPage, operation: AgentOperation,
                                  payload: String?, destination: String?) -> String? {
```
with
```swift
    private static func onElement(_ target: ObservedElement, on page: ObservedPage, operation: AgentOperation,
                                  payload: String?, destination: String?, approval: Approval?) -> String? {
```
and in its `Expected(...)` call replace `                                destination: destination)` with
```swift
                                destination: destination, approved: approval != nil,
                                approvedPageURL: approval?.pageURL, approvedText: approval?.text,
                                approvedSubmitLabel: approval?.formSubmitLabel)
```
6. Replace the whole `private static func navigate(to destination: String) -> String? { … }` with
```swift
    /// Opens `destination`. For an approved open, only on the page the Yes
    /// was given on.
    private static func navigate(to destination: String, approvedOn pageURL: String?) -> String? {
        guard let data = try? JSONEncoder().encode([destination, pageURL]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "(() => {\nconst [destination, approvedOn] = " + json + ";\n"
            + "if (approvedOn !== null && String(location.href).slice(0, "
            + String(ObserverScript.maxURLLength) + ") !== approvedOn) return JSON.stringify({ outcome: 'gone' });\n"
            + "location.assign(destination);\nreturn JSON.stringify({ outcome: 'done' });\n})()"
    }
```
7. In the raw string `elementAction`, replace
```
    const locate = () => {
      const { report, nodes } = observe();
      const fields = ['role', 'name', 'href', 'heading', 'context', 'formAction', 'formMethod'];
      const matches = [];
      report.elements.forEach((element, index) => {
        if (fields.every((field) => (element[field] ?? null) === (expected[field] ?? null))) matches.push(index);
      });
```
with
```
    const locate = () => {
      const { report, nodes } = observe();
      if (expected.approved && String(location.href).slice(0, MAX_URL) !== expected.approvedPageURL) {
        return { outcome: 'gone' };
      }
      const fields = ['role', 'name', 'href', 'heading', 'context', 'formAction', 'formMethod'];
      const stillApproved = (element) => !expected.approved || (element.text === expected.approvedText &&
        (element.formSubmitLabel ?? null) === (expected.approvedSubmitLabel ?? null));
      const matches = [];
      report.elements.forEach((element, index) => {
        if (fields.every((field) => (element[field] ?? null) === (expected[field] ?? null)) && stillApproved(element)) {
          matches.push(index);
        }
      });
```

### B4. Hidden secrets — `Services/Agent/ObserverScript.swift` (inside the raw string `walk`)
Replace
```
      // The fields found sensitive, filled by the check below. What they
      // hold never becomes any text the walk reports.
      const sensitive = new Set();
      const insideSensitive = (el) => {
        if (sensitive.size === 0) return false;
        for (let current = el; current; current = composedParent(current)) {
          if (sensitive.has(current)) return true;
        }
        return false;
      };
```
with
```
      // The fields the visible walk found sensitive: the report leaves them
      // out and the page's flags count them.
      const sensitive = new Set();
      // Whether an element is a field that is sensitive by its own words —
      // shown or hidden, because a hidden field's words can still be read
      // into another element's name. Out of time counts as sensitive.
      const secrecy = new Map();
      const sensitiveField = (el) => {
        if (secrecy.has(el)) return secrecy.get(el);
        const fieldLike = fieldTags.includes(el.tagName.toLowerCase()) || fieldRoles.includes(roleOf(el));
        let answer = false;
        if (fieldLike) {
          const words = fieldWords(el);
          answer = words === null || isPasswordField(el, words) || isPaymentField(el, words);
        }
        secrecy.set(el, answer);
        return answer;
      };
      // What a sensitive field holds never becomes any text the walk reports.
      const insideSensitive = (el) => {
        for (let current = el; current; current = composedParent(current)) {
          if (sensitive.has(current) || sensitiveField(current)) return true;
        }
        return false;
      };
```
(`fieldTags`, `fieldRoles`, `roleOf`, `fieldWords`, `isPasswordField`, `isPaymentField` are defined further
down in the same function; that is fine — `insideSensitive` is first called only after all of them exist.)

### B5. Stop, ceilings, the approval and grants — `Services/Agent/AgentRun.swift`
1. Properties: replace
```swift
    private var stepCost = 0.0
    private var waitedForUser: Duration = .zero
    private let workClock = SuspendingClock()
```
with
```swift
    private var stepCost = 0.0
    private let workClock = SuspendingClock()
    private var lastCheckpoint: SuspendingClock.Instant
    private var waitedSinceCheckpoint: Duration = .zero
    private let limits: AgentBudget.Limits
    /// The errand's own task: Stop cancels it, so a call or a question in
    /// flight ends at once.
    private var work: Task<ErrandRecord.Ending, Never>?

    /// A ceiling was reached right before an effect (§8).
    private struct CeilingReached: Error {}
```
2. In the init body, replace
```swift
        scratchpad = Scratchpad(columns: plan.columns, emptyCell: plan.emptyCell)
        budget = AgentBudget(startedAt: .now)
        pendingSearches = Array(plan.searches.dropFirst())
```
with
```swift
        scratchpad = Scratchpad(columns: plan.columns, emptyCell: plan.emptyCell)
        self.limits = limits
        budget = AgentBudget(startedAt: .now, limits: limits)
        lastCheckpoint = SuspendingClock.now
        pendingSearches = Array(plan.searches.dropFirst())
```
3. Replace
```swift
    /// Stop (§7.4): no further call is made and nothing more is sent to a
    /// page — checked before every call and every act.
    func stop() { stopRequested = true }
```
with
```swift
    /// Stop (§7.4): no further call is made and nothing more is sent to a
    /// page — checked before every call and every act, and a call or a
    /// question in flight is cancelled.
    func stop() {
        stopRequested = true
        work?.cancel()
    }
```
4. Replace the whole `func run() async -> ErrandRecord { … }` with
```swift
    func run() async -> ErrandRecord {
        budget = AgentBudget(startedAt: .now, limits: limits)
        lastCheckpoint = workClock.now
        guard !stopping else { return finish(.stopped) }
        let body = Task { await self.errand() }
        work = body
        let ending = await body.value
        work = nil
        let result = finish(stopRequested ? .stopped : ending)
        // The rows go into a Sheet when the errand finished or got stuck —
        // not after Stop, and not at a ceiling: then the errand stops (§8).
        guard result.ending == .done || result.ending == .stuck, !scratchpad.rows.isEmpty else { return result }
        await writeSheet()
        return record
    }

    /// The errand in its own task, which Stop cancels.
    private func errand() async -> ErrandRecord.Ending {
        let tab: BrowserTab
        do {
            tab = try await parts.bridge.openTab(plan.searches[0])
        } catch {
            return stopping ? .stopped : .failed
        }
        let ending: ErrandRecord.Ending
        do {
            ending = try await settle(tab, leaving: nil, on: plan.searches[0]) ? try await loop(in: tab) : .failed
        } catch is CeilingReached {
            ending = .ceiling
        } catch {
            ending = stopping ? .stopped : .failed
        }
        try? await parts.bridge.closeTab(tab)
        return ending
    }
```
5. Replace the whole `private func loop(in tab: BrowserTab) async throws -> ErrandRecord.Ending { … }` with
```swift
    private func loop(in tab: BrowserTab) async throws -> ErrandRecord.Ending {
        while scratchpad.rows.count < plan.rowsWanted {
            try checkpoint()
            if let ending = try await step(in: tab) { return ending }
        }
        return .done
    }

    /// Brings the work clock up to date — waits for the user left out — and
    /// throws at Stop or at a ceiling (§7.4, §8). Called before every step and
    /// right before every effect, so neither is noticed only after the fact.
    private func checkpoint() throws {
        if stopping { throw CancellationError() }
        let now = workClock.now
        budget.addActive(seconds: Self.seconds(now - lastCheckpoint - waitedSinceCheckpoint))
        lastCheckpoint = now
        waitedSinceCheckpoint = .zero
        if budget.ceiling(now: .now) != nil { throw CeilingReached() }
    }
```
6. In `step(in:)`:
   (a) Right after the block
```swift
        if action.operation == .done || action.operation == .stuck {
            log(action, .acted, choice.confidence, began)
            return action.operation == .done ? .done : .stuck
        }
```
   add
```swift

        // A grant is never taken and never asked about: it is the user's
        // part (§7.2).
        if SafetyGuard.isGrant(action) {
            log(action, .handedOver, choice.confidence, began)
            return .needsUser
        }
```
   (b) Replace
```swift
        var target = page
        var confirmed = false
```
   with
```swift
        var target = page
        var approval: ActionScript.Approval?
```
   (c) Replace
```swift
            target = fresh
            confirmed = true
```
   with
```swift
            target = fresh
            approval = ActionScript.Approval(pageURL: page.url, text: action.target?.text ?? "",
                                             formSubmitLabel: action.target?.formSubmitLabel)
```
   (d) Replace
```swift
        if stopping { return .stopped }
        var outcome = try await act(action, on: target, set: set, in: tab)
        if confirmed, outcome == .acted { outcome = .confirmed }
```
   with
```swift
        var outcome = try await act(action, on: target, set: set, in: tab, approval: approval)
        if approval != nil, outcome == .acted { outcome = .confirmed }
```
7. In `askUser(_:on:in:)` replace
```swift
        let confirm = parts.confirm
        let answer = await Deadline.run(within: answerWindow) { await confirm(request) } ?? nil
        waitedForUser += workClock.now - asked
```
   with
```swift
        let confirm = parts.confirm
        // No longer than the answer window, and never past the expiry (§8).
        let window = min(answerWindow, budget.timeLeft(now: .now))
        let answer = await Deadline.run(within: window) { await confirm(request) } ?? nil
        waitedSinceCheckpoint += workClock.now - asked
```
8. In `act(_:on:set:in:)`:
   (a) replace the signature
```swift
    private func act(_ action: AgentAction, on page: ObservedPage, set: CandidateSet,
                     in tab: BrowserTab) async throws -> ErrandRecord.Outcome {
```
   with
```swift
    private func act(_ action: AgentAction, on page: ObservedPage, set: CandidateSet, in tab: BrowserTab,
                     approval: ActionScript.Approval?) async throws -> ErrandRecord.Outcome {
```
   (b) in the `.back` case replace
```swift
            let before = try await marker(tab)
            _ = try ActionOutcome.decode(try await parts.bridge.run(script, in: tab))
```
   with
```swift
            let before = try await marker(tab)
            try checkpoint()
            _ = try ActionOutcome.decode(try await parts.bridge.run(script, in: tab))
```
   (c) in the `.open, .click, .type, .select, .scroll` case replace
```swift
            guard let script = ActionScript.source(for: action, on: page) else { return .unsupported }
            let before = try await marker(tab)
            let result = try ActionOutcome.decode(try await parts.bridge.run(script, in: tab))
```
   with
```swift
            guard let script = ActionScript.source(for: action, on: page, approval: approval) else { return .unsupported }
            let before = try await marker(tab)
            try checkpoint()
            let result = try ActionOutcome.decode(try await parts.bridge.run(script, in: tab))
```
9. Replace the whole `private func writeSheet() async { … }` with
```swift
    /// The rows go into a new Sheet and are read back (§6.6): every cell
    /// must show its canonical value and none may hold a formula. Stop and
    /// the ceilings are checked right before the Sheet is made and right
    /// before the paste.
    private func writeSheet() async {
        let rows = scratchpad.rows.map(\.cells)
        do {
            try checkpoint()
            let address = try await parts.sheet.create(title: plan.sheetTitle)
            try checkpoint()
            try await parts.sheet.paste(SheetCells.pasteText(rows: rows, empty: plan.emptyCell), into: address)
            record.sheet = address
            let shown = try await parts.sheet.readBack(address)
            if shown.holdsFormula
                || !SheetCells.readBackMatches(expected: rows, displayed: shown.cells, empty: plan.emptyCell) {
                record.ending = .failed
            }
        } catch is CeilingReached {
            record.ending = .ceiling
        } catch {
            record.ending = stopRequested ? .stopped : .failed
        }
    }
```
10. Remove every remaining use of `waitedForUser` (there should be none left after steps 5 and 7).

End of phase B. Reply with the list of files you changed.
