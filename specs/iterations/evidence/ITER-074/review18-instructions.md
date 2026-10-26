# ITER-074 — review round 18 fix (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Do exactly what is written; change
nothing else; add only the files listed. Tests English only. JavaScript lives in `#"""…"""#` raw strings.
"Replace A with B": A matches the file exactly once.

## The two problems (confirmed in the code)
1. The markup reading of a label (`heldChildren`) never enters a shadow root, so a word held inside a nested
   component that no slot shows (`x-outer` → shadow root → `<x-inner>OTP</x-inner>`, and `x-inner` draws only
   `*`) is never read.
2. Where one text node meets the next — a seam — the page may draw a break or nothing. The reader decides every
   seam the same way (all run together, or all apart), so a label mixing both — `Enter` on its own line, then
   `O<b>TP</b>` — reads "EnterOTP" or "Enter O TP", and `\botp\b` matches neither. An invisible format
   character — a soft hyphen in `Pass&shy;word` — is turned into a space, so "passw" misses too.

The fix: every seam is marked (U+200B) and read both ways at once. Long words are matched on the words read run
together; short words must stand alone, where each end may be a space, the edge or a seam, and a seam inside the
word is read as nothing.

---------------------------------------------------------------------------------------------------------
## PHASE A — fixtures and tests
---------------------------------------------------------------------------------------------------------

### A1. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-37.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Thirty-Seven</title></head>
<body>
<main>
  <h1>Verify</h1>
  <label for="n"><x-outer id="outer"></x-outer></label>
  <input id="n" type="text" value="SECRET-NESTED">
</main>
<script>
  const outer = document.getElementById('outer').attachShadow({ mode: 'open' });
  outer.innerHTML = '<x-inner id="inner">OTP</x-inner>';
  outer.getElementById('inner').attachShadow({ mode: 'open' }).innerHTML = '<span aria-hidden="true">*</span>';
</script>
</body>
</html>
```

### A2. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-38.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Thirty-Eight</title></head>
<body>
<main>
  <h1>Verify</h1>
  <label for="m"><span style="display:block">Enter</span><span>O<b>TP</b></span></label>
  <input id="m" type="text" value="SECRET-MIXED">
</main>
</body>
</html>
```

### A3. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-39.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Thirty-Nine</title></head>
<body>
<main>
  <h1>Account</h1>
  <label for="s">Pass&shy;word</label>
  <input id="s" type="text" value="SECRET-SHY">
</main>
</body>
</html>
```

### A4. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-40.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Forty</title></head>
<body>
<main>
  <h1>Recipes</h1>
  <label for="d"><span>Hot</span><span>pot</span> and shotput recipes</label>
  <input id="d" type="text" value="hotpot-search">
</main>
</body>
</html>
```

### A5. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`
Insert right before the line `    // MARK: - Shadow DOM, dialogs, hostile text`:
```swift
    /// Every seam is read both ways at once — where one tag's text meets the
    /// next, or at an invisible character such as a soft hyphen — and a word
    /// held in a nested component that no slot shows still counts (review
    /// round 18).
    @MainActor
    func testEverySeamIsReadBothWays() async throws {
        for address in ["https://site-37.test/", "https://site-38.test/", "https://site-39.test/"] {
            let page = try await observe(address)
            XCTAssertTrue(page.flags.loginForm, address)
            XCTAssertFalse(page.elements.contains { ($0.value ?? "").contains("SECRET") }, address)
        }
    }

    /// A short word names a secret only standing alone: "otp" inside "Hotpot"
    /// — even split across tags — or "shotput" flags nothing, and the field's
    /// value is still read (review round 18).
    @MainActor
    func testAShortWordInsideALongerOneFlagsNothing() async throws {
        let page = try await observe("https://site-40.test/")
        XCTAssertFalse(page.flags.loginForm)
        XCTAssertFalse(page.flags.paymentForm)
        XCTAssertTrue(page.elements.contains { $0.value == "hotpot-search" })
    }

```
End of phase A. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fix (`Services/Agent/ObserverScript.swift`, raw string `walk`)
---------------------------------------------------------------------------------------------------------

### B1. Replace
```
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
with
```
      // A node's children as its markup holds them — a shadow host's shadow
      // root and its own children, nested components included — so a word no
      // slot shows still counts.
      const heldChildren = (node) => {
        const children = Array.from(node.childNodes || []);
        if (node.shadowRoot) children.unshift(node.shadowRoot);
        return children;
      };
      // Where one text node meets the next. The page may draw a seam as a
      // break ("Enter" | "OTP" on two lines) or as nothing ("Pass" | "word"),
      // so the words are matched both ways at once (see `standingAlone`).
      const SEAM = '<U+200B>';
      // All the text a label holds, as the page draws it and as its markup
      // holds it, every seam marked, the two readings kept apart by a space.
      // Null when the time budget runs out.
      const composedText = (root) => {
        const drawn = textNodes(root, drawnChildren);
        if (drawn === null) return null;
        const held = textNodes(root, heldChildren);
        if (held === null) return null;
        return drawn.join(SEAM) + ' ' + held.join(SEAM);
      };
```

### B2. In the comment right above `const fieldWords = (node) => {`, replace
```
      // page is read. Every run of anything but letters and digits becomes
      // one space, so "Verification⏎   code" and "card_number" read as the
      // words they are.
```
with
```
      // page is read. Every run of anything but letters and digits becomes
      // one space, so "Verification⏎   code" and "card_number" read as the
      // words they are — except a run of invisible format characters (a soft
      // hyphen, a zero-width space), which the page may draw as nothing or as
      // a break: it becomes a seam.
```
and replace
```
        return words.join(' ').replace(/[^\p{L}\p{N}]+/gu, ' ');
```
with
```
        return words.join(' ').replace(/[^\p{L}\p{N}\p{Cf}]+/gu, ' ').replace(/\p{Cf}+/gu, SEAM);
```

### B3. Replace
```
      const passwordWords = /(passw|passcode|\bpwd\b|one.?time.?(code|pass)|\botp\b|verification.?code|confirmation.?code|\b2fa\b|two.?factor|auth(entication)?.?code)/i;
      const paymentWords = /(card.?(number|no)|cc.?num|credit.?card|\bcvv\b|\bcvc\b|\bcsc\b|security.?code|expir(y|ation)|\bmm ?yy\b|valid.?(thru|through|until))/i;
```
with
```
      // Words that name a secret wherever they stand, inside a longer word
      // too ("Passwort"): matched on the words read run together.
      const passwordPhrases = /(passw|passcode|one.?time.?(code|pass)|verification.?code|confirmation.?code|two.?factor|auth(entication)?.?code)/i;
      const paymentPhrases = /(card.?(number|no)|cc.?num|credit.?card|security.?code|expir(y|ation)|valid.?(thru|through|until))/i;
      // Short words that name a secret only standing alone — "otp", never
      // "hotpot". Each end is a space, the edge or a seam, and a seam inside
      // is read as nothing, so every way the page may draw its seams counts
      // without trying each one.
      const standingAlone = (list) => new RegExp('(?:^|[ ' + SEAM + '])(?:' +
        list.map((word) => Array.from(word).join(SEAM + '?')).join('|') + ')(?=$|[ ' + SEAM + '])', 'iu');
      const passwordShortWords = standingAlone(['pwd', 'otp', '2fa']);
      const paymentShortWords = standingAlone(['cvv', 'cvc', 'csc', 'mmyy', 'mm yy']);
      // The words read run together: every seam read as nothing.
      const runTogether = (words) => words.split(SEAM).join('').replace(/ {2,}/g, ' ');
```

### B4. Replace
```
      const isPasswordField = (node, words) => asksForPassword(node) || passwordWords.test(words);
      const isPaymentField = (node, words) => autocompleteTokens(node).some((token) => token.startsWith('cc-')) ||
        paymentWords.test(words);
```
with
```
      const isPasswordField = (node, words) => asksForPassword(node) ||
        passwordPhrases.test(runTogether(words)) || passwordShortWords.test(words);
      const isPaymentField = (node, words) => autocompleteTokens(node).some((token) => token.startsWith('cc-')) ||
        paymentPhrases.test(runTogether(words)) || paymentShortWords.test(words);
```
End of phase B. Reply with the file you changed.


# ITER-074 — review round 18 fix, correction (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Change nothing else.

In `Services/Agent/ObserverScript.swift` the line that starts with `      const SEAM = ` holds the zero-width space
as an invisible literal character between its quotes. An invisible character in source cannot be reviewed and an
editor can strip it silently. Replace that whole line with exactly this ASCII-only line (six leading spaces):

      const SEAM = String.fromCharCode(0x200B);

Do not type any invisible character. Reply with the file you changed.
