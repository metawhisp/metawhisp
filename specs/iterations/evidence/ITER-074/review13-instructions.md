# ITER-074 — review round 13 fixes (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Do exactly what is written; change
nothing else; add no other files. Tests English only; never `await` inside `XCTAssert…(…)`; JavaScript lives in
`#"""…"""#` raw strings. When a step says "replace A with B", A matches the file exactly once.

## The three problems (all confirmed in the code)
1. `dispatch` counts an action as sent only when the bridge's reply arrives and decodes. If the page acted but
   the reply is lost — a timeout, an error, a reply that does not decode — the error unwinds the step and the
   action is never recorded nor checked.
2. The observer leaves out a sensitive field but still reports controls inside it with their own words — an
   `<input type="image" alt=…>` or a button's `aria-label` inside a field named "Password".
3. `isGrant` exempts any label that names cookies, so "Allow access to your account and cookies" is not a grant.

---------------------------------------------------------------------------------------------------------
## PHASE A — tests and fixture (they must FAIL on the current code)
---------------------------------------------------------------------------------------------------------

### A1. `Tests/MetaWhispTests/Fixtures/Agent/pages/site-28.html`
Replace
```
  <button id="leaky-too">
```
with
```
  <span class="box" role="combobox" aria-label="Password" tabindex="0"><input type="image" alt="SECRET-INPUT" width="10" height="10" src="data:image/gif;base64,R0lGODlhAQABAAAAACw="><button aria-label="SECRET-LABEL">x</button></span>
  <button id="leaky-too">
```

### A2. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`
Insert right before the line `    // MARK: - Shadow DOM, dialogs, hostile text`:
```swift
    /// A control inside a sensitive field is part of it and is not reported
    /// with its own words — an image button's alt, a button's aria-label
    /// (review round 13).
    @MainActor
    func testAControlInsideASensitiveFieldIsNotReported() async throws {
        let page = try await observe("https://site-28.test/")
        XCTAssertFalse(page.elements.contains { $0.name.contains("SECRET") || $0.text.contains("SECRET") })
    }

```

### A3. `Tests/MetaWhispTests/Services/Agent/SafetyGuardTests.swift`
Insert right before the line `    func testNegationsAndScopesAreRead() {`:
```swift
    /// A label is cookie consent only when it is about nothing but cookies:
    /// one that also grants access is a grant (review round 13).
    func testALabelThatGrantsMoreThanCookiesIsAGrant() {
        func click(_ name: String) -> AgentAction {
            AgentAction(operation: .click, target: element(name: name), destination: nil, payload: nil,
                        isPlannedSearch: false)
        }
        XCTAssertTrue(SafetyGuard.isGrant(click("Allow access to your account and cookies")))
        XCTAssertFalse(SafetyGuard.isGrant(click("Allow necessary cookies only")))
        XCTAssertFalse(SafetyGuard.isGrant(click("Allow all cookies")))
    }

```

### A4. `Tests/MetaWhispTests/Services/Agent/AgentRunTests.swift`
(a) Insert right before the line `    // MARK: - Ceilings (§8)`:
```swift
    /// An action whose reply is lost after it reached the page is still
    /// recorded, and its postcondition decides how it went (§6.5, §7.4).
    @MainActor
    func testAnActionWhoseReplyIsLostIsStillRecordedAndChecked() async throws {
        let bridge = LoseTheFirstActionReply()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        })
        let run = AgentRun(plan: try plan(search: "https://site-26.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        let click = try XCTUnwrap(record.steps.first { $0.operation == "click" }, "the click is recorded")
        XCTAssertEqual(click.outcome, .acted, "the page shows the click happened")
        XCTAssertEqual(bridge.inner.openTabCount, 0)
    }

```
(b) Insert right before the line `    /// A decision engine that takes 1.2 s to choose — longer than the errand's`:
```swift
    /// The fixture browser, losing the reply of the first action script: the
    /// page acts, and the bridge answers with a timeout.
    @MainActor
    private final class LoseTheFirstActionReply: BrowserBridge {
        let inner = WebViewBridge()
        private var lost = false

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            let result = try await inner.run(javascript, in: tab)
            if !lost, javascript.contains("const expected") {
                lost = true
                throw BrowserBridgeError.timedOut
            }
            return result
        }
    }

```
No production-code stubs are needed. End of phase A. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fixes
---------------------------------------------------------------------------------------------------------

### B1. `Services/Agent/AgentRun.swift`, function `dispatch`
1. Replace
```swift
            let before = try await marker(tab)
            try checkpoint()
            _ = try ActionOutcome.decode(try await parts.bridge.run(script, in: tab))
            visited.removeLast()
```
with
```swift
            let before = try await marker(tab)
            try checkpoint()
            // From here the page may act: whatever the reply, the action counts
            // as sent, and its postcondition decides (§6.5, §7.4).
            _ = try? await parts.bridge.run(script, in: tab)
            visited.removeLast()
```
2. Replace
```swift
            let before = try await marker(tab)
            try checkpoint()
            let result = try ActionOutcome.decode(try await parts.bridge.run(script, in: tab))
            switch result.outcome {
            case .gone: return .finished(.gone)
            case .ambiguous: return .finished(.ambiguous)
            case .unsupported: return .finished(.unsupported)
            case .done: break
            }
```
with
```swift
            let before = try await marker(tab)
            try checkpoint()
            // From here the page may act. A reply that says the element was
            // gone, ambiguous or unsupported means nothing happened; any other
            // reply — or none, when it is lost — means the action counts as
            // sent, and its postcondition decides (§6.5, §7.4).
            let reply = (try? await parts.bridge.run(script, in: tab)).flatMap { try? ActionOutcome.decode($0) }
            switch reply?.outcome {
            case .gone: return .finished(.gone)
            case .ambiguous: return .finished(.ambiguous)
            case .unsupported: return .finished(.unsupported)
            case .done, nil: break
            }
```
3. In the same function replace
```swift
            return .sent(Postcheck(action: action, page: page, before: before, moved: result.moved,
                                   expected: expected, tab: tab))
```
with
```swift
            return .sent(Postcheck(action: action, page: page, before: before, moved: reply?.moved,
                                   expected: expected, tab: tab))
```

### B2. `Services/Agent/ObserverScript.swift` (raw string `walk`)
1. Replace
```
      // What a sensitive field holds never becomes any text the walk reports.
      const insideSensitive = (el) => {
        for (let current = el; current; current = composedParent(current)) {
          if (sensitive.has(current) || sensitiveField(current)) return true;
        }
        return false;
      };
```
with
```
      // What a sensitive field holds never becomes any text the walk reports.
      const insideSensitive = (el) => {
        for (let current = el; current; current = composedParent(current)) {
          if (sensitive.has(current) || sensitiveField(current)) return true;
        }
        return false;
      };
      // A control inside a sensitive field is part of it: only the field is
      // judged, and it is not reported at all.
      const insideSensitiveField = (node) => {
        const parent = composedParent(node);
        return !!parent && insideSensitive(parent);
      };
```
2. Replace
```
        if (insideWriting(node) || !visible(node)) continue;
```
with
```
        if (insideWriting(node) || insideSensitiveField(node) || !visible(node)) continue;
```

### B3. `Services/Agent/SafetyGuard.swift`
1. Right after the line `    static let russianGrantStems: [String] = ["разреш"]` add:
```swift
    /// The words a cookie consent label is made of (§7.2). A label that names
    /// cookies and holds nothing but these is consent to cookies; a label with
    /// any other word — "access", "account" — is a grant, cookies or not.
    static let cookieConsentWords: Set<String> = [
        "allow", "accept", "agree", "all", "and", "only", "the", "these", "necessary", "essential", "required",
        "optional", "selected", "selection", "analytics", "marketing", "functional", "performance", "preference",
        "preferences", "statistics", "tracking", "advertising",
        "все", "только", "и", "файлы", "необходимые", "разрешить", "разрешите", "принять", "примите"
    ]
```
2. In `isGrant`, replace
```swift
        let labelGrants = labels.contains { label in
            let found = words(in: decoded(label))
            return grants(found) && !found.contains { $0.hasPrefix("cookie") || $0.hasPrefix("куки") }
        }
```
with
```swift
        let isCookieWord = { (word: String) in word.hasPrefix("cookie") || word.hasPrefix("куки") }
        let labelGrants = labels.contains { label in
            let found = words(in: decoded(label))
            guard grants(found) else { return false }
            let aboutCookiesOnly = found.contains(where: isCookieWord)
                && found.allSatisfy { isCookieWord($0) || cookieConsentWords.contains($0) }
            return !aboutCookiesOnly
        }
```
3. In the comment right above that code — `// A label is exempt only when it is itself about cookies ("Allow all` and the next line — replace
```swift
        // A label is exempt only when it is itself about cookies ("Allow all
        // cookies"); an address that grants is a grant whatever its query says.
```
with
```swift
        // A label is exempt only when it is about nothing but cookies ("Allow
        // all cookies"); an address that grants is a grant whatever its query
        // says.
```

End of phase B. Reply with the list of files you changed.
