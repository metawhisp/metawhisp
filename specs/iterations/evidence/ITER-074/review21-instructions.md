# ITER-074 — review round 21 fix (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Do exactly what is written; change
nothing else; add only the files listed. Tests English only. JavaScript lives in `#"""…"""#` raw strings.
"Replace A with B": A matches the file exactly once. Type no invisible characters; every line is plain text.

## The two problems (confirmed in the code)
1. `card.?(number|no(?![a-z0-9]))` asks for a word end after "no", but phrases are matched on the words read
   run together, where a seam is read as nothing: `Card No<span style="display:block">Required</span>` reads
   "Card NoRequired", the word end is missed, and the card number's value is reported. A word that needs a word
   end must be matched standing alone, where a seam counts as a break.
2. `#` is read as " number " before the length limit is checked, so a field made of `#` grows eightfold before
   it is rejected. The limit must count the words as the page wrote them, before any replacement.

---------------------------------------------------------------------------------------------------------
## PHASE A — fixtures and tests (they must FAIL on the current code)
---------------------------------------------------------------------------------------------------------

### A1. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-50.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Fifty</title></head>
<body>
<main>
  <h1>Billing</h1>
  <label for="q">Card No<span style="display:block">Required</span></label>
  <input id="q" type="text" value="typed-value">
</main>
</body>
</html>
```

### A2. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-51.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Fifty-One</title></head>
<body>
<main>
  <h1>Notes</h1>
  <label for="h" id="hashes"></label>
  <input id="h" type="text" value="typed-value">
</main>
<script>
  document.getElementById('hashes').textContent = '#'.repeat(20000);
</script>
</body>
</html>
```

### A3. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`
(a) In `testTheUsualNamesOfASecretAreKnown`, replace
```swift
        let payment = ["CVV2", "CVC2", "MM/YYYY", "Card #"]
```
with
```swift
        let payment = ["CVV2", "CVC2", "MM/YYYY", "Card #", "Card No.", "cardNo"]
```
(b) Insert right before the line `    // MARK: - Shadow DOM, dialogs, hostile text`:
```swift
    /// "Card No" keeps its word end wherever the page breaks after it — a
    /// seam before "Required" drawn on its own line — so the field is a card
    /// number (review round 21).
    @MainActor
    func testCardNoBeforeASeamIsACardNumber() async throws {
        let page = try await observe("https://site-50.test/")
        XCTAssertTrue(page.flags.paymentForm)
        XCTAssertFalse(page.elements.contains { $0.value == "typed-value" })
    }

    /// The limit counts the words as the page wrote them, before "#" is read
    /// as "number": a label of 20,000 "#" is read in full, names no secret,
    /// and the page's values are read (review round 21).
    @MainActor
    func testTheLimitCountsTheWordsAsThePageWroteThem() async throws {
        let page = try await observe("https://site-51.test/")
        XCTAssertFalse(page.flags.paymentForm)
        XCTAssertTrue(page.elements.contains { $0.value == "typed-value" })
    }

```
End of phase A. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fix (`Services/Agent/ObserverScript.swift`, raw string `walk`)
---------------------------------------------------------------------------------------------------------

### B1. Replace
```
      // Past this many characters a field's words are not read: the field
      // counts as unchecked, as when the time budget runs out, so no page can
      // make the matching below run long.
```
with
```
      // Past this many characters — counted as the page wrote them, before
      // "#" is read as "number" — a field's words are not read: the field
      // counts as unchecked, as when the time budget runs out, so no page can
      // make the matching below run long.
```

### B2. Inside `fieldWords`, replace
```
        // "#" reads as the word it stands for: "Card #" names a card number.
        const joined = words.join(' ').replace(/#/g, ' number ');
        if (joined.length > WORDS_LIMIT) return null;
        return joined.replace(/[^\p{L}\p{N}\p{Cf}]+/gu, ' ').replace(/\p{Cf}+/gu, SEAM)
          .replace(breakRun, (run) => (run.includes(' ') ? ' ' : SEAM));
```
with
```
        const joined = words.join(' ');
        if (joined.length > WORDS_LIMIT) return null;
        // "#" reads as the word it stands for: "Card #" names a card number.
        return joined.replace(/#/g, ' number ').replace(/[^\p{L}\p{N}\p{Cf}]+/gu, ' ')
          .replace(/\p{Cf}+/gu, SEAM).replace(breakRun, (run) => (run.includes(' ') ? ' ' : SEAM));
```

### B3. Replace
```
      // Words that name a secret wherever they stand, inside a longer word
      // too ("Passwort"): matched on the words read run together.
```
with
```
      // Words that name a secret wherever they stand, inside a longer word
      // too ("Passwort"): matched on the words read run together, so none of
      // them may ask for a word end — a seam there is read as nothing.
```
and replace
```
      const paymentPhrases = /(card.?(number|no(?![a-z0-9]))|cc.?num|credit.?card|security.?code|expir(y|ation)|valid.?(thru|through|until))/i;
```
with
```
      const paymentPhrases = /(card.?number|cc.?num|credit.?card|security.?code|expir(y|ation)|valid.?(thru|through|until))/i;
```

### B4. Replace
```
      // Short words that name a secret only standing alone — "otp", never
      // "hotpot". Each end is a space, the edge or a seam, and a seam inside
      // is read as nothing, so every way the page may draw its seams counts
      // without trying each one.
```
with
```
      // Words that name a secret only standing alone — "otp", never "hotpot";
      // "card no", never "card note". Each end is a space, the edge or a seam,
      // and a seam inside is read as nothing, so every way the page may draw
      // its seams counts without trying each one.
```
and replace
```
      const paymentShortWords = standingAlone(['cvv', 'cvc', 'csc', 'cvv2', 'cvc2', 'mmyy', 'mm yy', 'mmyyyy',
        'mm yyyy']);
```
with
```
      const paymentShortWords = standingAlone(['card no', 'cardno', 'cvv', 'cvc', 'csc', 'cvv2', 'cvc2', 'mmyy',
        'mm yy', 'mmyyyy', 'mm yyyy']);
```
End of phase B. Reply with the file you changed.
