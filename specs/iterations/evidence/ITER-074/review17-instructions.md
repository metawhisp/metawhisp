# ITER-074 — review round 17 fix (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Do exactly what is written; change
nothing else; add only the files listed. Tests English only. JavaScript lives in `#"""…"""#` raw strings.
"Replace A with B": A matches the file exactly once.

## The problem (confirmed in the code)
`composedText` reads a shadow host twice — through its shadow root (whose slot shows the host's children) and
again through the host's own children — and glues every text node together. `<x-label>OTP</x-label>` with a
`<slot>` in its shadow root reads "OTPOTP", and `\botp\b` misses it; `<span>Enter</span><span>OTP</span>`
reads "EnterOTP" and misses too. On an otherwise clean page the field stays unmarked and its value is reported.

---------------------------------------------------------------------------------------------------------
## PHASE A — fixtures and test (must FAIL on the current code)
---------------------------------------------------------------------------------------------------------

### A1. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-33.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Thirty-Three</title></head>
<body>
<main>
  <h1>Verify</h1>
  <label for="q"><x-label id="native">OTP</x-label></label>
  <input id="q" type="text" value="SECRET-OTP">
</main>
<script>
  document.getElementById('native').attachShadow({ mode: 'open' }).innerHTML = '<slot></slot>';
</script>
</body>
</html>
```

### A2. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-34.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Thirty-Four</title></head>
<body>
<main>
  <h1>Verify</h1>
  <span id="cap"><x-label id="referenced">OTP</x-label></span>
  <input type="text" aria-labelledby="cap" value="SECRET-OTP-REF">
</main>
<script>
  document.getElementById('referenced').attachShadow({ mode: 'open' }).innerHTML = '<slot></slot>';
</script>
</body>
</html>
```

### A3. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-35.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Thirty-Five</title></head>
<body>
<main>
  <h1>Verify</h1>
  <label for="r"><span>Enter</span><span>OTP</span></label>
  <input id="r" type="text" value="SECRET-GLUED">
</main>
</body>
</html>
```

### A4. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`
Insert right before the line `    // MARK: - Shadow DOM, dialogs, hostile text`:
```swift
    /// A label's words keep their boundaries however the page draws them —
    /// through a component's slot, or split across tags — so a short word
    /// like "OTP" still marks its field (review round 17).
    @MainActor
    func testALabelsWordsKeepTheirBoundaries() async throws {
        for address in ["https://site-33.test/", "https://site-34.test/", "https://site-35.test/"] {
            let page = try await observe(address)
            XCTAssertTrue(page.flags.loginForm, address)
            XCTAssertFalse(page.elements.contains { ($0.value ?? "").contains("SECRET") }, address)
        }
    }

```
End of phase A. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fix (`Services/Agent/ObserverScript.swift`, raw string `walk`)
---------------------------------------------------------------------------------------------------------

### B1. Replace the whole `composedText` definition together with the comment above it — from the line
`      // All the text an element holds, its open shadow roots and the nodes` down to and including the
`      };` that closes `const composedText = (root) => {` — with:
```
      // All the text an element shows — a shadow host through its shadow
      // root, which reaches the host's children through slots, and a slot
      // through the nodes assigned to it or, with none, its fallback content
      // — read whole, without recursion. The words are read both run together,
      // as the page shows a word split across tags ("Pass" "word"), and apart,
      // as it shows separate words ("Enter" "OTP"), so a word boundary is kept
      // either way. Null when the time budget runs out.
      const composedText = (root) => {
        const parts = [];
        const stack = [root];
        while (stack.length > 0) {
          if (late()) return null;
          const node = stack.pop();
          if (node.nodeType === 3) {
            parts.push(node.nodeValue);
            continue;
          }
          let children;
          if (node.shadowRoot) {
            children = [node.shadowRoot];
          } else {
            const assigned = node.localName === 'slot' && typeof node.assignedNodes === 'function'
              ? node.assignedNodes({ flatten: true }) : [];
            children = assigned.length > 0 ? Array.from(assigned) : Array.from(node.childNodes || []);
          }
          for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]);
        }
        return parts.join('') + ' ' + parts.join(' ');
      };
```
End of phase B. Reply with the file you changed.


# ITER-074 — review round 17, part 2 (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Do exactly what is written; change
nothing else; add only the files listed. Tests English only. JavaScript lives in `#"""…"""#` raw strings.
"Replace A with B": A matches the file exactly once.

## Why
`composedText` must read a label the way the page draws it (a shadow host through its shadow root only, a slot
through its assigned nodes) — and, separately, the way its markup holds it, so a word the markup holds but no
slot shows (hidden text) still counts. Each reading is taken both run together and apart, and no reading runs
into another, so every word keeps its boundary.

---------------------------------------------------------------------------------------------------------
## PHASE G — a guard fixture (passes today; must keep passing)
---------------------------------------------------------------------------------------------------------

### G1. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-36.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Thirty-Six</title></head>
<body>
<main>
  <h1>Verify</h1>
  <label for="h"><x-icon id="unslotted">OTP</x-icon></label>
  <input id="h" type="text" value="SECRET-HELD">
</main>
<script>
  document.getElementById('unslotted').attachShadow({ mode: 'open' }).innerHTML = '<span aria-hidden="true">*</span>';
</script>
</body>
</html>
```

### G2. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`
Replace
```
        for address in ["https://site-33.test/", "https://site-34.test/", "https://site-35.test/"] {
```
with
```
        for address in ["https://site-33.test/", "https://site-34.test/", "https://site-35.test/",
                        "https://site-36.test/"] {
```
and in the doc comment right above `func testALabelsWordsKeepTheirBoundaries()` replace
```
    /// through a component's slot, or split across tags — so a short word
    /// like "OTP" still marks its field (review round 17).
```
with
```
    /// through a component's slot, split across tags, or held in markup no
    /// slot shows — so a short word like "OTP" still marks its field (review
    /// round 17).
```
End of phase G. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fix (`Services/Agent/ObserverScript.swift`, raw string `walk`)
---------------------------------------------------------------------------------------------------------

### B1. Replace the whole `composedText` definition together with the comment above it — from the line
`      // All the text an element holds, its open shadow roots and the nodes` down to and including the
`      };` that closes `const composedText = (root) => {` — with:
```
      // The text nodes under a node, in order, reaching each node's children
      // through `childrenOf` — read whole, without recursion. Null when the
      // time budget runs out.
      const textNodes = (root, childrenOf) => {
        const parts = [];
        const stack = [root];
        while (stack.length > 0) {
          if (late()) return null;
          const node = stack.pop();
          if (node.nodeType === 3) {
            parts.push(node.nodeValue);
            continue;
          }
          const children = childrenOf(node);
          for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]);
        }
        return parts;
      };
      // A node's children as the page draws them: a shadow host shows its
      // shadow root, which reaches the host's own children through slots, and
      // a slot shows the nodes assigned to it or, with none, its fallback.
      const drawnChildren = (node) => {
        if (node.shadowRoot) return [node.shadowRoot];
        const assigned = node.localName === 'slot' && typeof node.assignedNodes === 'function'
          ? node.assignedNodes({ flatten: true }) : [];
        return assigned.length > 0 ? Array.from(assigned) : Array.from(node.childNodes || []);
      };
      // A node's children as its markup holds them, one no slot shows included.
      const heldChildren = (node) => Array.from(node.childNodes || []);
      // All the text a label holds, as the page draws it and as its markup
      // holds it. Each is read run together, as the page shows a word split
      // across tags ("Pass" "word"), and apart, as it shows separate words
      // ("Enter" "OTP"); no reading runs into another, so every word keeps
      // its boundary. Null when the time budget runs out.
      const composedText = (root) => {
        const drawn = textNodes(root, drawnChildren);
        if (drawn === null) return null;
        const held = textNodes(root, heldChildren);
        if (held === null) return null;
        return [drawn.join(''), drawn.join(' '), held.join(''), held.join(' ')].join(' ');
      };
```
End of phase B. Reply with the file you changed.
