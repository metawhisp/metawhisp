# ITER-074 — review round 16 fix (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Do exactly what is written; change
nothing else; add only the files listed. Tests English only. JavaScript lives in `#"""…"""#` raw strings.
"Replace A with B": A matches the file exactly once.

## The problem (confirmed in the code)
`composedText` reads a label through open shadow roots but never follows a `<slot>` to the nodes assigned to
it. A component whose shadow root holds `<label for="q"><slot name="caption"></slot></label><input id="q">`,
filled from the page with `<span slot="caption">Password</span>`, leaves the field unmarked, and on an
otherwise clean page its value is reported. The same holds for an `aria-labelledby` label filled by a slot.

---------------------------------------------------------------------------------------------------------
## PHASE A — fixtures and test (must FAIL on the current code)
---------------------------------------------------------------------------------------------------------

### A1. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-31.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Thirty-One</title></head>
<body>
<main>
  <h1>Profile</h1>
  <x-field id="native"><span slot="caption">Password</span></x-field>
</main>
<script>
  document.getElementById('native').attachShadow({ mode: 'open' }).innerHTML =
    '<label for="q"><slot name="caption"></slot></label><input id="q" value="SECRET-SLOT">';
</script>
</body>
</html>
```

### A2. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-32.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Thirty-Two</title></head>
<body>
<main>
  <h1>Profile</h1>
  <x-field id="referenced"><span slot="caption">Password</span></x-field>
</main>
<script>
  document.getElementById('referenced').attachShadow({ mode: 'open' }).innerHTML =
    '<span id="cap"><slot name="caption"></slot></span><input aria-labelledby="cap" value="SECRET-SLOT-REF">';
</script>
</body>
</html>
```

### A3. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`
Insert right before the line `    // MARK: - Shadow DOM, dialogs, hostile text`:
```swift
    /// A label a component fills through a slot still says what a field is
    /// for — a native label or an aria-labelledby one — on a page with no
    /// other secret (review round 16).
    @MainActor
    func testASlottedLabelStillMarksAFieldSensitive() async throws {
        for address in ["https://site-31.test/", "https://site-32.test/"] {
            let page = try await observe(address)
            XCTAssertTrue(page.flags.loginForm, address)
            XCTAssertFalse(page.elements.contains { ($0.value ?? "").contains("SECRET") }, address)
        }
    }

```
End of phase A. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fix (`Services/Agent/ObserverScript.swift`, raw string `walk`, inside `composedText`)
---------------------------------------------------------------------------------------------------------

### B1. Replace
```
          const children = Array.from(node.childNodes || []);
          if (node.shadowRoot) children.unshift(node.shadowRoot);
```
with
```
          // A slot shows the nodes assigned to it — or, with none, its own
          // fallback content — exactly as the page draws it.
          const assigned = node.localName === 'slot' && typeof node.assignedNodes === 'function'
            ? node.assignedNodes({ flatten: true }) : [];
          const children = assigned.length > 0 ? Array.from(assigned) : Array.from(node.childNodes || []);
          if (node.shadowRoot) children.unshift(node.shadowRoot);
```
### B2. In the comment right above `const composedText = (root) => {`, replace
```
      // All the text an element holds, its open shadow roots included — the
      // way a component draws a label — read whole, without recursion. Null
      // when the time budget runs out.
```
with
```
      // All the text an element holds, its open shadow roots and the nodes
      // its slots show included — the way a component draws a label — read
      // whole, without recursion. Null when the time budget runs out.
```
End of phase B. Reply with the file you changed.
