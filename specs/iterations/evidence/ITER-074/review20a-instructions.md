# ITER-074 — review round 20 fix, part 1: where a label's words come from (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Do exactly what is written; change
nothing else; add only the files listed. Tests English only. JavaScript lives in `#"""…"""#` raw strings.
"Replace A with B": A matches the file exactly once. Type no invisible characters; every line is plain text.

## The problems (confirmed in the code)
1. The markup reading never follows a slot to the nodes it shows, so markup that a slotted component holds
   but does not draw (`<x-caption>OTP</x-caption>` whose shadow root draws only `*`) is never read.
2. Only text nodes are read: an image's `alt` ("OTP") or an element named by `aria-label` (an
   `aria-labelledby` target with `aria-label="One-time code"`) gives no words.
3. A component's `<style>` text is read as words and breaks a phrase: "Verification" + a component drawing
   `<style>…</style>code` reads "Verification host display inline code".
4. A control's own contents are read as label words: `<label>Topic <select>…<option>Reset password</option>`
   flags an ordinary topic select as a password field.
5. Nothing bounds the string work after the reading: a huge label or attribute is joined, replaced and matched
   whole. Past a limit the field must count as unchecked (null), as when the time budget runs out.

---------------------------------------------------------------------------------------------------------
## PHASE A — fixtures and tests (they must FAIL on the current code)
---------------------------------------------------------------------------------------------------------

### A1. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-43.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Forty-Three</title></head>
<body>
<main>
  <h1>Verify</h1>
  <x-field id="field"><x-caption id="caption">OTP</x-caption></x-field>
</main>
<script>
  document.getElementById('caption').attachShadow({ mode: 'open' }).innerHTML = '<span aria-hidden="true">*</span>';
  document.getElementById('field').attachShadow({ mode: 'open' }).innerHTML =
    '<label for="q"><slot></slot></label><input id="q" type="text" value="SECRET-SLOTTED">';
</script>
</body>
</html>
```

### A2. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-44.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Forty-Four</title></head>
<body>
<main>
  <h1>Verify</h1>
  <label for="i"><img alt="OTP" width="10" height="10" src="data:image/gif;base64,R0lGODlhAQABAAAAACw="></label>
  <input id="i" type="text" value="SECRET-ALT">
</main>
</body>
</html>
```

### A3. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-45.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Forty-Five</title></head>
<body>
<main>
  <h1>Verify</h1>
  <span id="t" aria-label="One-time code"></span>
  <input type="text" aria-labelledby="t" value="SECRET-ARIA">
</main>
</body>
</html>
```

### A4. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-46.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Forty-Six</title></head>
<body>
<main>
  <h1>Verify</h1>
  <label for="v">Verification <x-suffix id="suffix"></x-suffix></label>
  <input id="v" type="text" value="SECRET-STYLED">
</main>
<script>
  document.getElementById('suffix').attachShadow({ mode: 'open' }).innerHTML =
    '<style>:host{display:inline}</style>code';
</script>
</body>
</html>
```

### A5. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-47.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Forty-Seven</title></head>
<body>
<main>
  <h1>Support</h1>
  <label>Topic
    <select>
      <option>Billing</option>
      <option>Reset password</option>
    </select>
  </label>
  <label for="n">Name</label>
  <input id="n" type="text" value="visible-name">
</main>
</body>
</html>
```

### A6. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-48.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Forty-Eight</title></head>
<body>
<main>
  <h1>Notes</h1>
  <label for="l" id="long"></label>
  <input id="l" type="text" value="SECRET-LONG">
</main>
<script>
  document.getElementById('long').textContent = 'note '.repeat(24000);
</script>
</body>
</html>
```

### A7. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`
Insert right before the line `    // MARK: - Shadow DOM, dialogs, hostile text`:
```swift
    /// A label's words come from everything that names a field — markup a
    /// slot shows but a component does not draw, an image's alt text, an
    /// element named by aria-label — and never from a component's stylesheet
    /// (review round 20).
    @MainActor
    func testEverySourceOfALabelsWordsIsRead() async throws {
        for address in ["https://site-43.test/", "https://site-44.test/", "https://site-45.test/",
                        "https://site-46.test/"] {
            let page = try await observe(address)
            XCTAssertTrue(page.flags.loginForm, address)
            XCTAssertFalse(page.elements.contains { ($0.value ?? "").contains("SECRET") }, address)
        }
    }

    /// A control's own contents are not words about a field: a topic select
    /// offering "Reset password" flags nothing, and the page's values are read
    /// (review round 20).
    @MainActor
    func testAControlsContentsAreNotLabelWords() async throws {
        let page = try await observe("https://site-47.test/")
        XCTAssertFalse(page.flags.loginForm)
        XCTAssertTrue(page.elements.contains { $0.value == "visible-name" })
    }

    /// Words past the limit are not read: the field counts as unchecked, and
    /// no value on the page is read (review round 20).
    @MainActor
    func testWordsPastTheLimitLockEveryValue() async throws {
        let page = try await observe("https://site-48.test/")
        XCTAssertFalse(page.elements.contains { ($0.value ?? "").contains("SECRET") })
    }

```
End of phase A. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fix (`Services/Agent/ObserverScript.swift`, raw string `walk`)
---------------------------------------------------------------------------------------------------------

### B1. Replace
```
      // A node's children as the page draws them: a shadow host shows its
      // shadow root, which reaches the host's own children through slots, and
      // a slot shows the nodes assigned to it or, with none, its fallback.
      const drawnChildren = (node) => {
        if (node.shadowRoot) return [node.shadowRoot];
```
with
```
      // Elements whose text is no word about a field: code the page never
      // draws as text, and a control's own contents — a select's options,
      // what someone typed in a textarea.
      const wordless = ['script', 'style', 'noscript', 'template', 'select', 'textarea'];
      const isWordless = (node) => node.nodeType === 1 && wordless.includes(node.localName);
      // A node's children as the page draws them: a shadow host shows its
      // shadow root, which reaches the host's own children through slots, and
      // a slot shows the nodes assigned to it or, with none, its fallback.
      const drawnChildren = (node) => {
        if (isWordless(node)) return [];
        if (node.shadowRoot) return [node.shadowRoot];
```

### B2. Replace the whole `heldText` definition together with the comment above it — from the line
`      // The text of each tree under a node as its markup holds it — the` down to and including the `      };`
that closes `const heldText = (root) => {` — with:
```
      // The text of each tree under a node as its markup holds it — the
      // node's own tree, every shadow root in it and every node a slot in it
      // shows, nested ones included — each read on its own, so a word no slot
      // shows still counts and a component's drawing never breaks the words
      // around it. A text alternative (`aria-label`, `alt`, `title`) is a
      // reading of its own, as a screen reader names the element. Null when
      // the time budget runs out.
      const heldText = (root) => {
        const readings = [];
        const trees = [root];
        // A shadow root, or a node a slot shows, met on the way is left for a
        // reading of its own.
        const ownChildren = (node) => {
          if (isWordless(node)) return [];
          if (node.nodeType === 1) {
            for (const name of ['aria-label', 'alt', 'title']) {
              const value = node.getAttribute(name);
              if (value) readings.push(value);
            }
            if (node.localName === 'slot' && typeof node.assignedNodes === 'function') {
              for (const shown of node.assignedNodes({ flatten: true })) trees.push(shown);
            }
          }
          if (node.shadowRoot) trees.push(node.shadowRoot);
          return Array.from(node.childNodes || []);
        };
        while (trees.length > 0) {
          const parts = textNodes(trees.shift(), ownChildren);
          if (parts === null) return null;
          readings.push(parts.join(SEAM));
        }
        return readings.join(' ');
      };
```

### B3. In the comment right above `const fieldWords = (node) => {`, replace the line
```
      // bounds the reading; null means it ran out, and then no value on the
```
with
```
      // and `WORDS_LIMIT` bound the reading; null means one ran out: no value on the
```
and insert, right before the line `      // Every word that could name a field, shown or hidden and read whole:`, these lines:
```
      // Past this many characters a field's words are not read: the field
      // counts as unchecked, as when the time budget runs out, so no page can
      // make the matching below run long.
      const WORDS_LIMIT = 100000;
```

### B4. Inside `fieldWords`, replace
```
        return words.join(' ').replace(/[^\p{L}\p{N}\p{Cf}]+/gu, ' ').replace(/\p{Cf}+/gu, SEAM)
          .replace(breakRun, (run) => (run.includes(' ') ? ' ' : SEAM));
```
with
```
        const joined = words.join(' ');
        if (joined.length > WORDS_LIMIT) return null;
        return joined.replace(/[^\p{L}\p{N}\p{Cf}]+/gu, ' ').replace(/\p{Cf}+/gu, SEAM)
          .replace(breakRun, (run) => (run.includes(' ') ? ' ' : SEAM));
```
End of phase B. Reply with the file you changed.
