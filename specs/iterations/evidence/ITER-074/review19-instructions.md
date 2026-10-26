# ITER-074 — review round 19 fix (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Do exactly what is written; change
nothing else; add only the files listed. Tests English only. JavaScript lives in `#"""…"""#` raw strings.
"Replace A with B": A matches the file exactly once. Type no invisible characters; every line is plain text.

## The two problems (confirmed in the code)
1. The markup reading puts a component's shadow root in between the words around it: in
   `Pass<x-tail>word</x-tail>`, with `x-tail` drawing only `*`, it reads "Pass", "*", "word" — "Pass word" —
   and "passw" misses. Each tree of the markup (the label's own tree, and every shadow root) must be read on
   its own, so no tree breaks the words of another.
2. After normalizing, a label like `MM <span>/</span> YY` leaves a run of spaces and seams ("MM", space, seam,
   space, seam, space, "YY"), and the short word "mm yy" cannot match it. A run of spaces and seams must become
   one space when it holds a space, else one seam.

---------------------------------------------------------------------------------------------------------
## PHASE A — fixtures and test (must FAIL on the current code)
---------------------------------------------------------------------------------------------------------

### A1. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-41.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Forty-One</title></head>
<body>
<main>
  <h1>Account</h1>
  <label for="t">Pass<x-tail id="tail">word</x-tail></label>
  <input id="t" type="text" value="SECRET-TAIL">
</main>
<script>
  document.getElementById('tail').attachShadow({ mode: 'open' }).innerHTML = '<span aria-hidden="true">*</span>';
</script>
</body>
</html>
```

### A2. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-42.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Forty-Two</title></head>
<body>
<main>
  <h1>Billing</h1>
  <label for="e">MM <span>/</span> YY</label>
  <input id="e" type="text" value="SECRET-EXPIRY">
</main>
</body>
</html>
```

### A3. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`
Insert right before the line `    // MARK: - Shadow DOM, dialogs, hostile text`:
```swift
    /// A component's own drawing never breaks the words its markup holds
    /// ("Pass" and a component holding "word" that draws only "*"), and
    /// "MM / YY" reads as the expiry it is however its tags fall (review
    /// round 19).
    @MainActor
    func testMarkupWordsAndSpacedShortWordsStayWhole() async throws {
        let tail = try await observe("https://site-41.test/")
        XCTAssertTrue(tail.flags.loginForm)
        XCTAssertFalse(tail.elements.contains { ($0.value ?? "").contains("SECRET") })
        let expiry = try await observe("https://site-42.test/")
        XCTAssertTrue(expiry.flags.paymentForm)
        XCTAssertFalse(expiry.elements.contains { ($0.value ?? "").contains("SECRET") })
    }

```
End of phase A. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fix (`Services/Agent/ObserverScript.swift`, raw string `walk`)
---------------------------------------------------------------------------------------------------------

### B1. Replace the block that starts with the line
`      // A node's children as its markup holds them — a shadow host's shadow`
and ends with the `      };` that closes `const composedText = (root) => {` (this block holds `heldChildren`,
`SEAM` and `composedText`, 22 lines) with:
```
      // Where one text node meets the next. The page may draw a seam as a
      // break ("Enter" | "OTP" on two lines) or as nothing ("Pass" | "word"),
      // so the words are matched both ways at once (see `standingAlone`).
      const SEAM = String.fromCharCode(0x200B);
      // A run of breaks and seams is one break when it holds a space, else one
      // seam: "MM / YY" reads "MM YY" however its tags fall.
      const breakRun = new RegExp('[ ' + SEAM + ']+', 'gu');
      // The text of each tree under a node as its markup holds it — the
      // node's own tree, then every shadow root in it, nested ones included —
      // each read on its own, so a word no slot shows still counts and a
      // component's drawing never breaks the words around it. Null when the
      // time budget runs out.
      const heldText = (root) => {
        const readings = [];
        const trees = [root];
        // A shadow root met on the way is left for a reading of its own.
        const ownChildren = (node) => {
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
      // All the text a label holds, as the page draws it and as its markup
      // holds it, every seam marked, the readings kept apart by a space. Null
      // when the time budget runs out.
      const composedText = (root) => {
        const drawn = textNodes(root, drawnChildren);
        if (drawn === null) return null;
        const held = heldText(root);
        if (held === null) return null;
        return drawn.join(SEAM) + ' ' + held;
      };
```

### B2. In the comment right above `const fieldWords = (node) => {`, replace
```
      // hyphen, a zero-width space), which the page may draw as nothing or as
      // a break: it becomes a seam.
```
with
```
      // hyphen, a zero-width space), which the page may draw as nothing or as
      // a break: it becomes a seam. A run of both is then one break or one
      // seam (`breakRun`).
```
and replace the line
```
        return words.join(' ').replace(/[^\p{L}\p{N}\p{Cf}]+/gu, ' ').replace(/\p{Cf}+/gu, SEAM);
```
with the two lines
```
        return words.join(' ').replace(/[^\p{L}\p{N}\p{Cf}]+/gu, ' ').replace(/\p{Cf}+/gu, SEAM)
          .replace(breakRun, (run) => (run.includes(' ') ? ' ' : SEAM));
```
End of phase B. Reply with the file you changed.
