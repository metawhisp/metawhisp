# ITER-074 — review round 20 fix, part 2: the words that name a secret (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Do exactly what is written; change
nothing else; add only the files listed. Tests English only. JavaScript lives in `#"""…"""#` raw strings.
"Replace A with B": A matches the file exactly once. Type no invisible characters; every line is plain text.

## The problems (confirmed in the code)
1. Usual English names of a secret are missing: "CVV2" and "CVC2" (a digit follows the short word),
   "MM/YYYY", "Card #" ("#" is dropped, so no "number" follows "card"), "Authenticator code", "PIN",
   "Passphrase".
2. `card.?(number|no)` matches "Gift card note": "no" needs a word end after it.

---------------------------------------------------------------------------------------------------------
## PHASE A — fixture and tests (they must FAIL on the current code)
---------------------------------------------------------------------------------------------------------

### A1. New file `Tests/MetaWhispTests/Fixtures/Agent/pages/site-49.html` — exactly:
```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Site Forty-Nine</title></head>
<body>
<main>
  <h1>Details</h1>
  <label for="w" id="word"></label>
  <input id="w" type="text" value="typed-value">
</main>
<script>
  document.getElementById('word').textContent = new URLSearchParams(location.search).get('label') || '';
</script>
</body>
</html>
```

### A2. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`
Insert right before the line `    // MARK: - Shadow DOM, dialogs, hostile text`:
```swift
    /// The usual English names of a secret mark their field however they are
    /// written — "CVV2", "MM/YYYY", "Card #", "Authenticator code", "PIN",
    /// "Passphrase" — each on a page with no other secret (review round 20).
    @MainActor
    func testTheUsualNamesOfASecretAreKnown() async throws {
        let payment = ["CVV2", "CVC2", "MM/YYYY", "Card #"]
        let password = ["Authenticator code", "PIN", "Passphrase"]
        for label in payment + password {
            let query = try XCTUnwrap(label.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
            let page = try await observe("https://site-49.test/?label=\(query)")
            let flagged = payment.contains(label) ? page.flags.paymentForm : page.flags.loginForm
            XCTAssertTrue(flagged, label)
            XCTAssertFalse(page.elements.contains { $0.value == "typed-value" }, label)
        }
    }

    /// "Gift card note" names no card number: the field is ordinary and its
    /// value is read (review round 20).
    @MainActor
    func testAGiftCardNoteIsNotACardNumber() async throws {
        let page = try await observe("https://site-49.test/?label=Gift%20card%20note")
        XCTAssertFalse(page.flags.paymentForm)
        XCTAssertTrue(page.elements.contains { $0.value == "typed-value" })
    }

```
End of phase A. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fix (`Services/Agent/ObserverScript.swift`, raw string `walk`)
---------------------------------------------------------------------------------------------------------

### B1. Inside `fieldWords`, replace
```
        const joined = words.join(' ');
```
with
```
        // "#" reads as the word it stands for: "Card #" names a card number.
        const joined = words.join(' ').replace(/#/g, ' number ');
```

### B2. Replace
```
      const passwordPhrases = /(passw|passcode|one.?time.?(code|pass)|verification.?code|confirmation.?code|two.?factor|auth(entication)?.?code)/i;
      const paymentPhrases = /(card.?(number|no)|cc.?num|credit.?card|security.?code|expir(y|ation)|valid.?(thru|through|until))/i;
```
with
```
      const passwordPhrases = /(passw|passcode|passphrase|one.?time.?(code|pass)|verification.?code|confirmation.?code|two.?factor|auth(entication|enticator)?.?(app.?)?code)/i;
      const paymentPhrases = /(card.?(number|no(?![a-z0-9]))|cc.?num|credit.?card|security.?code|expir(y|ation)|valid.?(thru|through|until))/i;
```

### B3. Replace
```
      const passwordShortWords = standingAlone(['pwd', 'otp', '2fa']);
      const paymentShortWords = standingAlone(['cvv', 'cvc', 'csc', 'mmyy', 'mm yy']);
```
with
```
      const passwordShortWords = standingAlone(['pwd', 'otp', '2fa', 'pin']);
      const paymentShortWords = standingAlone(['cvv', 'cvc', 'csc', 'cvv2', 'cvc2', 'mmyy', 'mm yy', 'mmyyyy',
        'mm yyyy']);
```
End of phase B. Reply with the file you changed.


# ITER-074 — review round 20 fix, part 2, correction (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Change nothing else.
Type no invisible characters; every line is plain text.

Step B2 changed `passwordPhrases` but left `paymentPhrases` as it was; the test for "Gift card note" still
fails. In `Services/Agent/ObserverScript.swift` replace the line
```
      const paymentPhrases = /(card.?(number|no)|cc.?num|credit.?card|security.?code|expir(y|ation)|valid.?(thru|through|until))/i;
```
with
```
      const paymentPhrases = /(card.?(number|no(?![a-z0-9]))|cc.?num|credit.?card|security.?code|expir(y|ation)|valid.?(thru|through|until))/i;
```
Reply with the file you changed.
