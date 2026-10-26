# ITER-074 — review round 15 fixes (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Do exactly what is written; change
nothing else; add only the files listed. Tests English only. JavaScript lives in `#"""…"""#` raw strings.
"Replace A with B": A matches the file exactly once.

## The two problems (confirmed in the code)
1. `firstSubmitter` skips a submitter inside a sensitive field but not a submitter that is itself sensitive:
   `<input type="submit" name="password" value="SECRET">` names its form, and every other control of that form
   gets the submit label "SECRET".
2. The words that decide whether a field is sensitive are read with `textContent`, which does not see a
   component's shadow root: `<label for="x"><x-label></x-label></label>` whose open shadow root says
   "Password" leaves the field unmarked, and on an otherwise clean page its value is reported.

---------------------------------------------------------------------------------------------------------
## PHASE A — fixtures and tests (they must FAIL on the current code)
---------------------------------------------------------------------------------------------------------

### A1. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-30.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Thirty</title></head>
<body>
<main>
  <h1>Account</h1>
  <label for="credential"><x-label id="shadow-label"></x-label></label>
  <input id="credential" type="text" value="SECRET-SHADOW">
</main>
<script>
  document.getElementById('shadow-label').attachShadow({ mode: 'open' }).innerHTML = '<span>Password</span>';
</script>
</body>
</html>
```

### A2. `Tests/MetaWhispTests/Fixtures/Agent/pages/site-28.html`
Replace
```
  <button id="leaky-too">
```
with
```
  <form action="https://site-28.test/other" method="post">
    <input type="email" aria-label="Work email">
    <input type="submit" name="password" value="SECRET-SELF">
  </form>
  <button id="leaky-too">
```

### A3. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`
Insert right before the line `    // MARK: - Shadow DOM, dialogs, hostile text`:
```swift
    /// A submit button that is itself sensitive never names its form either
    /// (review round 15).
    @MainActor
    func testASensitiveSubmitButtonNeverNamesItsForm() async throws {
        let page = try await observe("https://site-28.test/")
        let email = try XCTUnwrap(named("Work email", in: page))
        XCTAssertFalse((email.formSubmitLabel ?? "").contains("SECRET"))
    }

    /// A label a component draws in its shadow root still says what a field
    /// is for: the field is sensitive, the page is flagged, and no value is
    /// read (review round 15).
    @MainActor
    func testALabelDrawnInAShadowRootStillMarksAFieldSensitive() async throws {
        let page = try await observe("https://site-30.test/")
        XCTAssertTrue(page.flags.loginForm)
        XCTAssertFalse(page.elements.contains { ($0.value ?? "").contains("SECRET") })
    }

```
End of phase A. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fixes (`Services/Agent/ObserverScript.swift`, raw string `walk`)
---------------------------------------------------------------------------------------------------------

### B1. Replace
```
          if (isSubmitter(control) && !insideWriting(control) && !insideSensitiveField(control)) return control;
```
with
```
          if (isSubmitter(control) && !insideWriting(control) && !insideSensitive(control)) return control;
```
and replace the comment right above `const firstSubmitter = (form) => {`:
```
      // The form's first submitter that could itself be reported: one inside
      // someone's writing or a sensitive field is part of it, and its words
      // never name the form.
```
with
```
      // The form's first submitter that could itself be reported: one that is
      // sensitive, or sits inside someone's writing or a sensitive field, never
      // names the form.
```

### B2. Replace the whole `fieldWords` definition — from the comment line
`      // Every word that could name a field, shown or hidden and read whole:` down to and including the line
`        return words.join(' ').replace(/[^\p{L}\p{N}]+/gu, ' ');` and the `      };` line right after it — with:
```
      // All the text an element holds, its open shadow roots included — the
      // way a component draws a label — read whole, without recursion. Null
      // when the time budget runs out.
      const composedText = (root) => {
        let out = '';
        const stack = [root];
        while (stack.length > 0) {
          if (late()) return null;
          const node = stack.pop();
          if (node.nodeType === 3) {
            out += node.nodeValue;
            continue;
          }
          const children = Array.from(node.childNodes || []);
          if (node.shadowRoot) children.unshift(node.shadowRoot);
          for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]);
        }
        return out;
      };

      // Every word that could name a field, shown or hidden and read whole:
      // a word past a display cut-off, split across tags, or drawn in a
      // component's shadow root would pass as safe. Only the time budget
      // bounds the reading; null means it ran out, and then no value on the
      // page is read. Every run of anything but letters and digits becomes
      // one space, so "Verification⏎   code" and "card_number" read as the
      // words they are.
      const fieldWords = (node) => {
        const words = [node.getAttribute('name'), node.id, node.getAttribute('placeholder'),
          node.getAttribute('aria-label'), node.getAttribute('title')];
        const labels = labelsByReference(node).concat(node.labels ? Array.from(node.labels) : []);
        for (const label of labels) {
          const text = composedText(label);
          if (text === null) return null;
          words.push(text);
        }
        return words.join(' ').replace(/[^\p{L}\p{N}]+/gu, ' ');
      };
```
(Keep the exact existing first lines of `fieldWords` — `const words = [...]` and `const labels = ...` — as
written above; they are unchanged.)

End of phase B. Reply with the file you changed.
