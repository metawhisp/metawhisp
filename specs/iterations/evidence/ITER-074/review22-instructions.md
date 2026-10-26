# ITER-074 — review round 22 fix (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Do exactly what is written; change
nothing else; add only the files listed. Tests English only. JavaScript lives in `#"""…"""#` raw strings.
"Replace A with B": A matches the file exactly once. Type no invisible characters; every line is plain text.

## The problem (confirmed in the code)
"card no" and "cardno" are matched standing alone, which asks for a word start too: `name="debitCardNo"` is
read "debitCardNo", the start before "Card" is a letter, and a card number field with no other hint is
reported with its value. "card no" must match wherever it starts, and only where it ends (a space, the edge or
a seam) — "card note" still never matches.

---------------------------------------------------------------------------------------------------------
## PHASE A — test (must FAIL on the current code)
---------------------------------------------------------------------------------------------------------

### A1. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`, in `testTheUsualNamesOfASecretAreKnown`,
replace
```swift
        let payment = ["CVV2", "CVC2", "MM/YYYY", "Card #", "Card No.", "cardNo"]
```
with
```swift
        let payment = ["CVV2", "CVC2", "MM/YYYY", "Card #", "Card No.", "cardNo", "debitCardNo"]
```
End of phase A. Reply with the file you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fix (`Services/Agent/ObserverScript.swift`, raw string `walk`)
---------------------------------------------------------------------------------------------------------

### B1. Replace
```
      // Words that name a secret only standing alone — "otp", never "hotpot";
      // "card no", never "card note". Each end is a space, the edge or a seam,
      // and a seam inside is read as nothing, so every way the page may draw
      // its seams counts without trying each one.
```
with
```
      // Words that name a secret only standing alone — "otp", never "hotpot".
      // Each end is a space, the edge or a seam, and a seam inside is read as
      // nothing, so every way the page may draw its seams counts without
      // trying each one.
```

### B2. Replace
```
      const paymentShortWords = standingAlone(['card no', 'cardno', 'cvv', 'cvc', 'csc', 'cvv2', 'cvc2', 'mmyy',
        'mm yy', 'mmyyyy', 'mm yyyy']);
```
with
```
      const paymentShortWords = standingAlone(['cvv', 'cvc', 'csc', 'cvv2', 'cvc2', 'mmyy', 'mm yy', 'mmyyyy',
        'mm yyyy']);
      // Words that name a secret wherever they start, but only where a word
      // ends — "card no" in "debitCardNo" or before a seam, never in "card
      // note". The end is a space, the edge or a seam; a seam inside is read
      // as nothing.
      const endingAWord = (list) => new RegExp('(?:' + list.map((word) => Array.from(word).join(SEAM + '?')).join('|') +
        ')(?=$|[ ' + SEAM + '])', 'iu');
      const paymentWordEnds = endingAWord(['card no', 'cardno']);
```

### B3. Replace
```
        paymentPhrases.test(runTogether(words)) || paymentShortWords.test(words);
```
with
```
        paymentPhrases.test(runTogether(words)) || paymentShortWords.test(words) || paymentWordEnds.test(words);
```
End of phase B. Reply with the file you changed.
