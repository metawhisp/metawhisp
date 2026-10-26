# ITER-074 — review round 12 fixes (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp (Swift package). You CANNOT build or run tests: the orchestrator
compiles and sends you the errors. Do exactly what is written; change nothing else; add no other files.

## Hard rules
1. Tests are English only — no Cyrillic characters in any test file.
2. Never put `try await` or `await` inside `XCTAssert…(…)` arguments. Assign to a `let` first.
3. JavaScript lives inside Swift raw strings `#"""` … `"""#`; inside them a backslash is literal.
4. When a step says "replace A with B", A must match the file exactly once. When it says "replace the whole
   function F", replace from F's first line down to its closing brace (inclusive) and nothing else.

## The five problems (all confirmed in the code)
1. The errand's cancellable task ends before the Sheet is made, so Stop during the paste or the read-back
   cancels nothing and the ending can stay `.done`; opening the first tab has no Stop/ceiling check.
2. An action that reached the page is logged only after its postcondition is checked; a Stop right after a
   click cancels that check with a thrown error, so the click is never recorded (§7.4 wants the last action
   and its postcondition reported).
3. A paid call (Choose, Risk, writer) checks neither the ceilings nor the time left: after the expiry another
   paid call can start, and its deadline can run past the expiry.
4. In `nameOf`, image `alt` text is read from every descendant image — hidden ones and ones inside a
   sensitive field too.
5. `isGrant` lets any cookie word anywhere exempt the whole action (an address `…/authorize?cookie=1`), and
   only approved actions bind the words the checks saw, so a button can turn into "Allow access" between the
   check and the act.

---------------------------------------------------------------------------------------------------------
## PHASE A — tests, fixtures and compile stubs (the new tests must FAIL on the current code)
---------------------------------------------------------------------------------------------------------

### A1. `Tests/MetaWhispTests/Fixtures/Agent/pages/site-28.html`
Replace
```
  <button aria-labelledby="vault">Unlock</button>
```
with
```
  <button aria-labelledby="vault">Unlock</button>
  <button id="leaky"><span role="combobox" aria-label="Password" hidden><img alt="SECRET-HIDDEN" width="10" height="10" src="data:image/gif;base64,R0lGODlhAQABAAAAACw="></span></button>
  <button id="leaky-too"><span class="box" role="combobox" aria-label="Password" tabindex="0"><img alt="SECRET-SENSITIVE" width="10" height="10" src="data:image/gif;base64,R0lGODlhAQABAAAAACw="></span></button>
```

### A2. `Tests/MetaWhispTests/Services/Agent/SafetyGuardTests.swift`
Insert right before the line `    func testNegationsAndScopesAreRead() {`:
```swift
    /// A cookie word exempts only a label that is itself about cookies; an
    /// address that grants is a grant whatever its query says (review round 12).
    func testACookieWordInAnAddressExemptsNothing() {
        func click(_ name: String, href: String) -> AgentAction {
            AgentAction(operation: .click, target: element(name: name, href: href), destination: nil, payload: nil,
                        isPlannedSearch: false)
        }
        XCTAssertTrue(SafetyGuard.isGrant(click("Allow access", href: "https://id.test/oauth/authorize?cookie=1")))
        XCTAssertTrue(SafetyGuard.isGrant(click("Continue", href: "https://id.test/oauth/authorize?cookie=1")))
        XCTAssertFalse(SafetyGuard.isGrant(click("Allow all cookies", href: "https://a.test/settings")))
    }

```

### A3. `Tests/MetaWhispTests/Services/Agent/ActionScriptTests.swift`
Insert right before the line `    @MainActor\n    func testAnApprovedActionIsTakenWhenNothingChanged() async throws {` — i.e. right
before the `@MainActor` line that precedes `func testAnApprovedActionIsTakenWhenNothingChanged()`:
```swift
    /// Every action is bound to the page and the words the checks saw, not
    /// only an approved one: a button whose label stays "Confirm payment" but
    /// whose text changes between the check and the act is not pressed
    /// (review round 12).
    @MainActor
    func testAnActionIsNotTakenWhenItsWordsChangedAfterTheCheck() async throws {
        let (bridge, tab) = try await open("https://site-26.test/")
        let page = try await observe(bridge, tab)
        let pay = try XCTUnwrap(named("Confirm payment", in: page))
        _ = try await bridge.run("document.getElementById('pay').textContent = 'Pay $100'; ''", in: tab)
        let script = try XCTUnwrap(ActionScript.source(for: action(.click, on: pay), on: page))
        let outcome = try ActionOutcome.decode(try await bridge.run(script, in: tab))
        XCTAssertEqual(outcome.outcome, .gone)
        let title = try await bridge.run("document.title", in: tab)
        XCTAssertEqual(title, "Site Twenty-Six", "nothing was paid")
    }

```

### A4. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`
Insert right before the line `    // MARK: - Shadow DOM, dialogs, hostile text`:
```swift
    /// An image's words count as they are shown: an image hidden, or inside a
    /// sensitive field, names nothing (review round 12).
    @MainActor
    func testAnImageInAHiddenOrSensitiveFieldNamesNothing() async throws {
        let page = try await observe("https://site-28.test/")
        XCTAssertFalse(page.elements.contains { $0.name.contains("SECRET") || $0.text.contains("SECRET") })
    }

```

### A5. `Tests/MetaWhispTests/Services/Agent/AgentRunTests.swift`
(a) Insert right before the line `    // MARK: - Ceilings (§8)`:
```swift
    /// Stop during the paste: the errand ends as stopped at once — nothing is
    /// read back — and the record keeps the Sheet the rows went into.
    @MainActor
    func testStopDuringThePasteEndsTheErrandAsStopped() async throws {
        let bridge = WebViewBridge()
        let button = StopButton()
        let sheet = StoppingSheet(button: button, pressDuring: .paste)
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }))
        button.run = run
        let record = await run.run()
        XCTAssertEqual(record.ending, .stopped)
        XCTAssertNotNil(record.sheet, "the paste happened, so the record keeps the Sheet")
        XCTAssertEqual(sheet.readBacks, 0, "nothing more is done after Stop")
    }

    /// An action that reached the page is recorded even when Stop comes right
    /// after it, and its postcondition is still checked (§7.4).
    @MainActor
    func testAnActionThatReachedThePageIsRecordedEvenIfStopFollows() async throws {
        let button = StopButton()
        let bridge = StopAfterAnAction(button: button)
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        })
        let run = AgentRun(plan: try plan(search: "https://site-26.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        button.run = run
        let record = await run.run()
        XCTAssertEqual(record.ending, .stopped)
        XCTAssertEqual(record.steps.last?.operation, "click", "the click that reached the page is recorded")
        XCTAssertEqual(record.steps.last?.outcome, .acted, "its postcondition was checked, and held")
    }

```
(b) Insert right before the line `    // MARK: - Helpers`:
```swift
    /// No paid call starts after the expiry, and a call's deadline never runs
    /// past it (review round 12).
    @MainActor
    func testNoPaidCallStartsAfterTheExpiry() async throws {
        let bridge = WebViewBridge()
        let engine = SlowCountingEngine()
        let limits = AgentBudget.Limits(steps: 40, activeSeconds: 600, spendMicros: 500_000, expiry: .seconds(1))
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }),
                           limits: limits)
        let record = await run.run()
        XCTAssertEqual(record.ending, .ceiling)
        XCTAssertEqual(engine.calls, 1, "the only paid call was the one begun before the expiry")
    }

```
(c) In the `// MARK: - Helpers` section, replace the whole `StoppingSheet` class (from the line
`    /// A fixture sheet that presses Stop while it is being created.` down to its closing brace) with:
```swift
    /// A fixture sheet that presses Stop while it is being created, or while
    /// the rows are being pasted.
    @MainActor
    private final class StoppingSheet: SheetDestination {
        enum Moment { case create, paste }

        private let inner = FixtureSheet()
        private let button: StopButton
        private let moment: Moment
        private(set) var pastes = 0
        private(set) var readBacks = 0

        init(button: StopButton, pressDuring moment: Moment = .create) {
            self.button = button
            self.moment = moment
        }

        func create(title: String) async throws -> URL {
            if moment == .create { button.press() }
            return try await inner.create(title: title)
        }

        func paste(_ text: String, into sheet: URL) async throws {
            pastes += 1
            try await inner.paste(text, into: sheet)
            if moment == .paste { button.press() }
        }

        func readBack(_ sheet: URL) async throws -> SheetReadBack {
            readBacks += 1
            return try await inner.readBack(sheet)
        }
    }

    /// The fixture browser, pressing Stop right after an action script has
    /// reached the page.
    @MainActor
    private final class StopAfterAnAction: BrowserBridge {
        let inner = WebViewBridge()
        private let button: StopButton
        private var pressed = false

        init(button: StopButton) { self.button = button }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            let result = try await inner.run(javascript, in: tab)
            if !pressed, javascript.contains("const expected") {
                pressed = true
                button.press()
            }
            return result
        }
    }

    /// A decision engine that takes 1.2 s to choose — longer than the errand's
    /// time — and counts every paid call it gets.
    private final class SlowCountingEngine: DecisionEngine, @unchecked Sendable {
        let name = "scripted"
        let worstCaseUSD = 0.001
        private let lock = NSLock()
        private var count = 0

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        private func counted() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func choose(_ request: ChooseRequest) async throws -> ChooseAnswer {
            counted()
            try await Task.sleep(for: .milliseconds(1_200))
            return ScriptedEngine.pick(request.candidates.first { $0.action.destination == "https://site-1.test/" })
        }

        func risk(of action: AgentAction, onPage url: String) async throws -> RiskAnswer {
            counted()
            return RiskAnswer(irreversible: 0.05, usage: nil)
        }
    }
```

No production-code stubs are needed in phase A: every new test compiles against today's API.

End of phase A. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fixes (make every test pass; change nothing else)
---------------------------------------------------------------------------------------------------------

### B1. Grants — `Services/Agent/SafetyGuard.swift`
Replace the whole `static func isGrant(_ action: AgentAction) -> Bool { … }` with:
```swift
    static func isGrant(_ action: AgentAction) -> Bool {
        guard let target = action.target else { return false }
        func grants(_ words: [String]) -> Bool {
            words.contains { grantWords.contains($0) || russianGrantStems.contains(where: $0.hasPrefix) }
        }
        // A label is exempt only when it is itself about cookies ("Allow all
        // cookies"); an address that grants is a grant whatever its query says.
        let labels = [target.name, target.text, target.formSubmitLabel].compactMap { $0 }
        let labelGrants = labels.contains { label in
            let found = words(in: decoded(label))
            return grants(found) && !found.contains { $0.hasPrefix("cookie") || $0.hasPrefix("куки") }
        }
        let addressGrants = [target.formAction, target.href].compactMap { $0 }.contains { grants(words(in: decoded($0))) }
        return labelGrants || addressGrants
    }
```

### B2. Every action is bound — `Services/Agent/ActionScript.swift`
1. Replace the doc comment of `struct Approval` (the three `///` lines right above `struct Approval: Equatable {`)
   with:
```swift
    /// What the checks — and, for an irreversible action, the user — saw
    /// (§7.1). Every element action and every planned search is bound to it
    /// in the same script as the act: the page is still that page, and the
    /// element still shows the same words and submit label. Without an
    /// approval, the action is bound to what the checks saw on `page`.
```
2. In `source(for:on:approval:)` replace
```swift
            guard let target = action.target else { return navigate(to: destination, approvedOn: approval?.pageURL) }
```
with
```swift
            guard let target = action.target else {
                return navigate(to: destination, approvedOn: approval?.pageURL ?? page.url)
            }
```
3. In the same function replace every `approval: approval)` argument passed to `onElement(` (three calls)
   with `binding: approval ?? binding(of: target, on: page))`.
4. Right after the closing brace of `static func back(to previous: URL) -> String? { … }` add:
```swift

    /// What the checks saw on `page` for `target`.
    private static func binding(of target: ObservedElement, on page: ObservedPage) -> Approval {
        Approval(pageURL: page.url, text: target.text, formSubmitLabel: target.formSubmitLabel)
    }
```
5. In `private struct Expected` replace
```swift
        let approved: Bool
        let approvedPageURL: String?
        let approvedText: String?
        let approvedSubmitLabel: String?
```
with
```swift
        let boundPageURL: String
        let boundText: String
        let boundSubmitLabel: String?
```
6. In `onElement` replace the parameter `approval: Approval?` with `binding: Approval`, and in its
   `Expected(...)` call replace
```swift
                                destination: destination, approved: approval != nil,
                                approvedPageURL: approval?.pageURL, approvedText: approval?.text,
                                approvedSubmitLabel: approval?.formSubmitLabel)
```
with
```swift
                                destination: destination, boundPageURL: binding.pageURL,
                                boundText: binding.text, boundSubmitLabel: binding.formSubmitLabel)
```
7. In the raw string `elementAction` replace
```
      if (expected.approved && String(location.href).slice(0, MAX_URL) !== expected.approvedPageURL) {
        return { outcome: 'gone' };
      }
      const fields = ['role', 'name', 'href', 'heading', 'context', 'formAction', 'formMethod'];
      const stillApproved = (element) => !expected.approved || (element.text === expected.approvedText &&
        (element.formSubmitLabel ?? null) === (expected.approvedSubmitLabel ?? null));
```
with
```
      if (String(location.href).slice(0, MAX_URL) !== expected.boundPageURL) return { outcome: 'gone' };
      const fields = ['role', 'name', 'href', 'heading', 'context', 'formAction', 'formMethod'];
      const stillBound = (element) => element.text === expected.boundText &&
        (element.formSubmitLabel ?? null) === (expected.boundSubmitLabel ?? null);
```
   and in the `report.elements.forEach(...)` just below replace `&& stillApproved(element)` with
   `&& stillBound(element)`.

### B3. Image names — `Services/Agent/ObserverScript.swift` (raw string `walk`, inside `nameOf`)
Replace
```
          const images = node.getElementsByTagName('img');
          for (let i = 0; i < images.length && i < MAX_IMAGES; i++) {
            imageAlts += ' ' + (images[i].getAttribute('alt') || '');
          }
```
with
```
          // An image's words count as they are shown: not hidden, not inside
          // someone's writing, not inside a sensitive field.
          const images = node.getElementsByTagName('img');
          for (let i = 0, used = 0; i < images.length && i < MAX_TEXT_NODES && used < MAX_IMAGES; i++) {
            const image = images[i];
            if (inWriting(image) || insideSensitive(image) || !visible(image)) continue;
            imageAlts += ' ' + (image.getAttribute('alt') || '');
            used += 1;
          }
```

### B4. The record can correct its last step — `Services/Agent/ErrandRecord.swift`
Right after the closing brace of `mutating func append(…) { … }` add:
```swift

    /// Corrects the last step's outcome: an action is recorded the moment it
    /// reaches the page, and its postcondition may turn out not to hold.
    mutating func markLastStep(_ outcome: Outcome) {
        guard let last = steps.popLast() else { return }
        steps.append(Step(operation: last.operation, targetRole: last.targetRole, fingerprint: last.fingerprint,
                          outcome: outcome, confidence: last.confidence, engine: last.engine,
                          milliseconds: last.milliseconds, costUSD: last.costUSD))
    }
```

### B5. The loop — `Services/Agent/AgentRun.swift`
1. Replace the whole `func run() async -> ErrandRecord { … }` and the whole
   `private func errand() async -> ErrandRecord.Ending { … }` (they are next to each other, with the doc line
   `    /// The errand in its own task, which Stop cancels.` between them) with:
```swift
    func run() async -> ErrandRecord {
        budget = AgentBudget(startedAt: .now, limits: limits)
        lastCheckpoint = workClock.now
        guard !stopping else { return finish(.stopped) }
        let body = Task { await self.errand() }
        work = body
        let ending = await body.value
        work = nil
        return finish(stopRequested ? .stopped : ending)
    }

    /// The errand in its own task — the Sheet included — which Stop cancels.
    private func errand() async -> ErrandRecord.Ending {
        let tab: BrowserTab
        do {
            try checkpoint()
            tab = try await parts.bridge.openTab(plan.searches[0])
        } catch is CeilingReached {
            return .ceiling
        } catch {
            return stopping ? .stopped : .failed
        }
        var ending: ErrandRecord.Ending
        do {
            ending = try await settle(tab, leaving: nil, on: plan.searches[0]) ? try await loop(in: tab) : .failed
            // An errand that finished on its last step still ends at a ceiling
            // reached on the way (§8).
            if ending == .done || ending == .stuck { try checkpoint() }
        } catch is CeilingReached {
            ending = .ceiling
        } catch {
            ending = stopping ? .stopped : .failed
        }
        try? await parts.bridge.closeTab(tab)
        // The rows go into a Sheet when the errand finished or got stuck —
        // not after Stop, and not at a ceiling: then the errand stops (§8).
        guard ending == .done || ending == .stuck, !scratchpad.rows.isEmpty else { return ending }
        return await writeSheet() ?? ending
    }
```
2. In `step(in:)`:
   (a) replace
```swift
        switch await paid(engine.worstCaseUSD, within: Self.decisionDeadline, usage: { $0.usage },
                          { try await engine.choose(request) }) {
        case .stopped: return .stopped
        case .overBudget: return .ceiling
```
   with
```swift
        switch try await paid(engine.worstCaseUSD, within: Self.decisionDeadline, usage: { $0.usage },
                              { try await engine.choose(request) }) {
        case .overBudget: return .ceiling
```
   (b) replace
```swift
            switch await collectRow(in: tab, subgoal: subgoal) {
            case .stopped: return .stopped
            case .overBudget: return .ceiling
```
   with
```swift
            switch try await collectRow(in: tab, subgoal: subgoal) {
            case .overBudget: return .ceiling
```
   (c) replace
```swift
            switch await paid(engine.worstCaseUSD, within: Self.decisionDeadline, usage: { $0.usage },
                              { try await engine.risk(of: action, onPage: page.url) }) {
            case .stopped: return .stopped
            case .overBudget: return .ceiling
```
   with
```swift
            switch try await paid(engine.worstCaseUSD, within: Self.decisionDeadline, usage: { $0.usage },
                                  { try await engine.risk(of: action, onPage: page.url) }) {
            case .overBudget: return .ceiling
```
   (d) replace
```swift
        var outcome = try await act(action, on: target, set: set, in: tab, approval: approval)
        if approval != nil, outcome == .acted { outcome = .confirmed }
        log(action, outcome, choice.confidence, began)
        progress.record(action, newRow: newRow, subgoalFinished: newRow)
        return progress.isStuck ? .stuck : nil
```
   with
```swift
        switch try await dispatch(action, on: target, set: set, in: tab, approval: approval) {
        case .finished(let outcome):
            log(action, outcome, choice.confidence, began)
        case .sent(let check):
            // The action is on the page: it is recorded at once, so a Stop that
            // comes next cannot lose it, and its postcondition is still checked
            // and reported (§7.4).
            log(action, approval == nil ? .acted : .confirmed, choice.confidence, began)
            if await !postcondition(check) { record.markLastStep(.failed) }
        }
        progress.record(action, newRow: newRow, subgoalFinished: newRow)
        return progress.isStuck ? .stuck : nil
```
3. Replace
```swift
    private enum Paid<T> { case answered(T), missed, overBudget, stopped }

    /// A paid call (§8): its worst case is reserved first — refused if it
    /// would cross the ceiling — and its real cost settled after. A timeout
    /// or an error is a miss.
    private func paid<T: Sendable>(_ worstCaseUSD: Double, within limit: Duration, usage: (T) -> EngineUsage?,
                                   _ work: @escaping @Sendable () async throws -> T) async -> Paid<T> {
        guard !stopping else { return .stopped }
        guard let reservation = budget.reserve(worstCaseUSD: worstCaseUSD) else { return .overBudget }
        let result = await Deadline.run(within: limit, work)
```
   with
```swift
    private enum Paid<T> { case answered(T), missed, overBudget }

    /// A paid call (§8), made only while Stop is not pressed and no ceiling is
    /// reached: its worst case is reserved first — refused if it would cross
    /// the spend ceiling — its deadline never runs past the expiry, and its
    /// real cost is settled after. A timeout or an error is a miss.
    private func paid<T: Sendable>(_ worstCaseUSD: Double, within limit: Duration, usage: (T) -> EngineUsage?,
                                   _ work: @escaping @Sendable () async throws -> T) async throws -> Paid<T> {
        try checkpoint()
        guard let reservation = budget.reserve(worstCaseUSD: worstCaseUSD) else { return .overBudget }
        let result = await Deadline.run(within: min(limit, budget.timeLeft(now: .now)), work)
```
4. Replace
```swift
    private enum RowResult { case added, notAdded, overBudget, stopped }
```
   with
```swift
    private enum RowResult { case added, notAdded, overBudget }
```
   then replace
```swift
    private func collectRow(in tab: BrowserTab, subgoal: AgentPlan.Subgoal) async -> RowResult {
```
   with
```swift
    private func collectRow(in tab: BrowserTab, subgoal: AgentPlan.Subgoal) async throws -> RowResult {
```
   and replace
```swift
        switch await paid(writer.worstCaseUSD, within: Self.writerDeadline, usage: { $0.usage },
                          { try await writer.row(columns: columns, subgoal: subgoal, excerpt: excerpt) }) {
        case .stopped: return .stopped
        case .overBudget: return .overBudget
```
   with
```swift
        switch try await paid(writer.worstCaseUSD, within: Self.writerDeadline, usage: { $0.usage },
                              { try await writer.row(columns: columns, subgoal: subgoal, excerpt: excerpt) }) {
        case .overBudget: return .overBudget
```
5. Replace the whole `private func act(_ action: AgentAction, on page: ObservedPage, set: CandidateSet, in tab: BrowserTab,`
   function (two signature lines, down to its closing brace) AND the whole
   `private func verify(_ action: AgentAction, on page: ObservedPage, leaving before: String, moved: Bool?,`
   function together with its doc comment (the two `///` lines starting `/// The operation's own postcondition`)
   with:
```swift
    /// What sending an action led to: finished — nothing reached the page, or
    /// nothing there to check — or sent, with what its postcondition needs.
    private enum Dispatch {
        case finished(ErrandRecord.Outcome)
        case sent(Postcheck)
    }

    /// What checking an action's postcondition needs once it reached the page.
    private struct Postcheck {
        let action: AgentAction
        let page: ObservedPage
        let before: String
        let moved: Bool?
        /// Where the tab must end: an open's destination, or back's address.
        let expected: URL?
        let tab: BrowserTab
    }

    /// Sends the action to the page, with Stop and the ceilings checked right
    /// before it goes.
    private func dispatch(_ action: AgentAction, on page: ObservedPage, set: CandidateSet, in tab: BrowserTab,
                          approval: ActionScript.Approval?) async throws -> Dispatch {
        switch action.operation {
        case .wait:
            try await Task.sleep(for: Self.waitStep)
            return .finished(.acted)
        case .more:
            skip = set.nextSkip ?? 0
            return .finished(.acted)
        case .done, .stuck:
            return .finished(.acted)
        case .back:
            skip = 0
            guard visited.count >= 2 else { return .finished(.unsupported) }
            let previous = visited[visited.count - 2]
            guard let script = ActionScript.back(to: previous) else { return .finished(.unsupported) }
            let before = try await marker(tab)
            try checkpoint()
            _ = try ActionOutcome.decode(try await parts.bridge.run(script, in: tab))
            visited.removeLast()
            return .sent(Postcheck(action: action, page: page, before: before, moved: nil, expected: previous, tab: tab))
        case .open, .click, .type, .select, .scroll:
            skip = 0
            guard let script = ActionScript.source(for: action, on: page, approval: approval) else {
                return .finished(.unsupported)
            }
            let before = try await marker(tab)
            try checkpoint()
            let result = try ActionOutcome.decode(try await parts.bridge.run(script, in: tab))
            switch result.outcome {
            case .gone: return .finished(.gone)
            case .ambiguous: return .finished(.ambiguous)
            case .unsupported: return .finished(.unsupported)
            case .done: break
            }
            if action.isPlannedSearch, let destination = action.destination {
                pendingSearches.removeAll { $0.absoluteString == destination }
            }
            let expected = action.operation == .open ? action.destination.flatMap(URL.init(string:)) : nil
            return .sent(Postcheck(action: action, page: page, before: before, moved: result.moved,
                                   expected: expected, tab: tab))
        }
    }

    /// The postcondition of an action that reached the page (§6.5), checked
    /// even after Stop (§7.4): in a task Stop does not cancel, bounded by the
    /// page deadline. A failed one is a miss, never repeated blindly.
    private func postcondition(_ check: Postcheck) async -> Bool {
        await Task { (try? await self.verify(check)) ?? false }.value
    }

    private func verify(_ check: Postcheck) async throws -> Bool {
        let action = check.action
        let page = check.page
        let tab = check.tab
        switch action.operation {
        case .open, .back:
            guard let expected = check.expected else { return false }
            return try await settle(tab, leaving: check.before, on: expected, honourStop: false)
        case .scroll:
            return check.moved == true
        case .click:
            // A click may start a navigation: give it a moment to begin.
            try await Task.sleep(for: .milliseconds(300))
            guard try await settle(tab, leaving: nil, on: nil, honourStop: false), let target = action.target else {
                return false
            }
            let after = try await observe(tab)
            let element = after.element(matching: page.identity(of: target))
            let region = { (observed: ObservedPage) in
                observed.elements.filter { $0.region == target.region }.map(\.fingerprint)
            }
            return after.url != page.url || region(after) != region(page) || element?.checked != target.checked
                || element?.value != target.value || element?.text != target.text
        case .type, .select:
            guard let target = action.target, let payload = action.payload else { return false }
            let after = try await observe(tab)
            let shown = after.element(matching: page.identity(of: target))?.value
            return shown == payload.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        case .wait, .more, .done, .stuck:
            return true
        }
    }
```
6. In `settle`, replace
```swift
    /// Waits for the page (§11). With `previous` — a marker taken before a
    /// navigation — the page must first be another one; with `target`, it
    /// must end on the same site, redirects allowed (§6.5). False when that
    /// does not happen in time: a miss.
    private func settle(_ tab: BrowserTab, leaving previous: String?, on target: URL?) async throws -> Bool {
        let deadline = ContinuousClock.now + Self.pageDeadline
        while ContinuousClock.now < deadline {
            if stopping { return false }
```
   with
```swift
    /// Waits for the page (§11). With `previous` — a marker taken before a
    /// navigation — the page must first be another one; with `target`, it
    /// must end on the same site, redirects allowed (§6.5). False when that
    /// does not happen in time: a miss. A postcondition checked after Stop
    /// passes `honourStop: false`.
    private func settle(_ tab: BrowserTab, leaving previous: String?, on target: URL?,
                        honourStop: Bool = true) async throws -> Bool {
        let deadline = ContinuousClock.now + Self.pageDeadline
        while ContinuousClock.now < deadline {
            if honourStop, stopping { return false }
```
7. Replace the whole `private func writeSheet() async { … }` together with its doc comment (the four `///`
   lines starting `/// The rows go into a new Sheet and are read back (§6.6): every cell`) with:
```swift
    /// The rows go into a new Sheet and are read back (§6.6): every cell
    /// must show its canonical value and none may hold a formula. Stop and
    /// the ceilings are checked right before the Sheet is made, right before
    /// the paste and right after it. Nil: written and read back as pasted;
    /// otherwise the ending it leaves.
    private func writeSheet() async -> ErrandRecord.Ending? {
        let rows = scratchpad.rows.map(\.cells)
        do {
            try checkpoint()
            let address = try await parts.sheet.create(title: plan.sheetTitle)
            try checkpoint()
            try await parts.sheet.paste(SheetCells.pasteText(rows: rows, empty: plan.emptyCell), into: address)
            record.sheet = address
            try checkpoint()
            let shown = try await parts.sheet.readBack(address)
            let intact = !shown.holdsFormula
                && SheetCells.readBackMatches(expected: rows, displayed: shown.cells, empty: plan.emptyCell)
            return intact ? nil : .failed
        } catch is CeilingReached {
            return .ceiling
        } catch {
            return stopping ? .stopped : .failed
        }
    }
```

End of phase B. Reply with the list of files you changed.
