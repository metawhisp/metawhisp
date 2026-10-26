# ITER-074 — review round 14 fix (instructions for the coding model)

Repository: /Users/android/Code/MetaWhisp. You CANNOT build or run tests. Do exactly what is written; change
nothing else. Tests English only. JavaScript lives in `#"""…"""#` raw strings. "Replace A with B": A matches the
file exactly once.

## The problem (confirmed in the code)
A form's submit label comes from `firstSubmitter(form)`, which takes the first submit control in the form —
even one inside someone's writing or inside a sensitive field, which the observer otherwise never reports. So
`<span role="combobox" aria-label="Password"><button aria-label="SECRET">x</button></span>` inside a form gives
every other control of that form the submit label "SECRET".

---------------------------------------------------------------------------------------------------------
## PHASE A — fixture and test (must FAIL on the current code)
---------------------------------------------------------------------------------------------------------

### A1. `Tests/MetaWhispTests/Fixtures/Agent/pages/site-28.html`
Replace
```
  <button id="leaky-too">
```
with
```
  <form action="https://site-28.test/sign-in" method="post">
    <span class="box" role="combobox" aria-label="Password" tabindex="0"><button aria-label="SECRET-SUBMIT">x</button></span>
    <input type="email" aria-label="Email">
  </form>
  <button id="leaky-too">
```

### A2. `Tests/MetaWhispTests/Services/Agent/ObserverFormsTests.swift`
Insert right before the line `    // MARK: - Shadow DOM, dialogs, hostile text`:
```swift
    /// A submit button inside a sensitive field never names its form: no
    /// reported word — name, text, row, heading or submit label — comes from
    /// it (review round 14).
    @MainActor
    func testASubmitButtonInsideASensitiveFieldNeverNamesItsForm() async throws {
        let page = try await observe("https://site-28.test/")
        XCTAssertNotNil(named("Email", in: page))
        XCTAssertFalse(page.elements.contains { element in
            [element.name, element.text, element.context ?? "", element.heading ?? "",
             element.formSubmitLabel ?? ""].contains { $0.contains("SECRET") }
        })
    }

```
End of phase A. Reply with the list of files you changed.

---------------------------------------------------------------------------------------------------------
## PHASE B — the fix
---------------------------------------------------------------------------------------------------------

### B1. `Services/Agent/ObserverScript.swift` (raw string `walk`)
Replace
```
      const firstSubmitter = (form) => {
        const controls = formElementsOf(form);
        for (let i = 0; i < controls.length && i < 200; i++) {
          if (isSubmitter(controls[i])) return controls[i];
        }
        return null;
      };
```
with
```
      // The form's first submitter that could itself be reported: one inside
      // someone's writing or a sensitive field is part of it, and its words
      // never name the form.
      const firstSubmitter = (form) => {
        const controls = formElementsOf(form);
        for (let i = 0; i < controls.length && i < 200; i++) {
          const control = controls[i];
          if (isSubmitter(control) && !insideWriting(control) && !insideSensitiveField(control)) return control;
        }
        return null;
      };
```
End of phase B. Reply with the file you changed.
