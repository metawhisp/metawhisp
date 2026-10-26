import XCTest
@testable import MetaWhisp

/// What an action visibly did, as the steps a model reads tell it (`effects.py`, MIT).
final class StepEffectTests: XCTestCase {
    private func control(_ key: Int?, _ role: String, _ name: String, value: String? = nil,
                         checked: Bool? = nil) -> ObservedElement {
        ObservedElement(index: key ?? 0, key: key, role: role, name: name, text: "", href: nil, inputType: nil,
                        heading: nil, region: .main, inViewport: true, context: nil, formAction: nil, formMethod: nil,
                        formSubmitLabel: nil, options: nil, checked: checked, value: value)
    }

    private func page(_ elements: [ObservedElement], url: String = "https://site-503.test/",
                      from: String? = "https://site-503.test/") -> ObservedPage {
        var page = ObservedPage(url: url, title: "Phones 503", truncated: false, flags: .none, elements: elements,
                                text: "")
        page.loadedFrom = from
        return page
    }

    /// A ticked box says so, then an unticked one: the state page text never shows.
    func testATickedAndAnUntickedBoxSayWhichWay() {
        let off = page([control(1, "checkbox", "Apple", checked: false), control(2, "checkbox", "Google", checked: false)])
        let on = page([control(1, "checkbox", "Apple", checked: true), control(2, "checkbox", "Google", checked: false)])
        XCTAssertEqual(StepEffect.summary(from: off, to: on), "changed Apple checked: false -> true")
        XCTAssertEqual(StepEffect.summary(from: on, to: off), "changed Apple checked: true -> false")
    }

    /// A redraw that replaces the box with a new element still compares it, by its one namesake that is gone —
    /// and the new element is shown, the old one removed, as the reference counts them by their ids.
    func testARedrawnBoxIsComparedWithItsOneNamesake() {
        let before = page([control(1, "checkbox", "Apple", checked: false), control(2, "button", "Add to cart")])
        let after = page([control(7, "checkbox", "Apple", checked: true), control(2, "button", "Add to cart")])
        XCTAssertEqual(StepEffect.summary(from: before, to: after),
                       "changed Apple checked: false -> true; showed 1 control: Apple; removed 1 control: Apple")
        // Two boxes of one name: neither stands in for the other.
        let twins = page([control(1, "checkbox", "Apple", checked: false), control(2, "checkbox", "Apple", checked: false)])
        let redrawn = page([control(8, "checkbox", "Apple", checked: true), control(9, "checkbox", "Apple", checked: false)])
        XCTAssertEqual(StepEffect.summary(from: twins, to: redrawn),
                       "showed 2 controls: Apple, Apple; removed 2 controls: Apple, Apple")
    }

    /// A value, the words of a control, the address — each said; long words cut at 60 characters.
    func testAValueWordsAndAnAddressAreSaid() {
        let long = String(repeating: "x", count: 70)
        let before = page([control(1, "combobox", "Order by", value: "Select"), control(2, "button", "Follow"),
                           control(3, "textbox", "Note", value: nil)])
        let after = page([control(1, "combobox", "Order by", value: "Lowest to highest"), control(2, "button", "Following"),
                          control(3, "textbox", "Note", value: long)], url: "https://site-503.test/?order=lowest")
        XCTAssertEqual(StepEffect.summary(from: before, to: after),
                       "went to https://site-503.test/?order=lowest; changed Order by value: Select -> Lowest to highest; "
                       + "Follow label: Follow -> Following; Note value: empty -> " + String(repeating: "x", count: 59) + "…")
    }

    /// Controls shown and removed are counted, four of them named.
    func testControlsShownAndRemovedAreCountedAndFourNamed() {
        let before = page([control(1, "checkbox", "Apple", checked: false)]
                          + (10...11).map { (key: Int) in control(key, "button", "Old \(key)") })
        let after = page([control(1, "checkbox", "Apple", checked: false)]
                         + (20...25).map { (key: Int) in control(key, "button", "Add \(key)") })
        XCTAssertEqual(StepEffect.summary(from: before, to: after),
                       "showed 6 controls: Add 20, Add 21, Add 22, Add 23 and 2 more; removed 2 controls: Old 10, Old 11")
    }

    /// Five changes: four said, the rest counted.
    func testMoreThanFourChangesAreCounted() {
        let names = ["A", "B", "C", "D", "E"]
        let before = page(names.enumerated().map { control($0.offset, "checkbox", $0.element, checked: false) })
        let after = page(names.enumerated().map { control($0.offset, "checkbox", $0.element, checked: true) })
        XCTAssertEqual(StepEffect.summary(from: before, to: after),
                       "changed A checked: false -> true; B checked: false -> true; C checked: false -> true; "
                       + "D checked: false -> true and 1 more")
    }

    /// Nothing changed is said too: a click that did nothing cannot pass for one that did.
    func testNothingChangedIsSaid() {
        let same = page([control(1, "checkbox", "Apple", checked: true)])
        XCTAssertEqual(StepEffect.summary(from: same, to: same), "nothing visible changed")
    }

    /// Another document numbers its controls from the start: its keys are not the earlier ones, so its controls
    /// are new — and one namesake on both sides is still compared.
    func testAnotherDocumentsKeysAreNotTheEarlierOnes() {
        let before = page([control(1, "checkbox", "Apple", checked: false), control(2, "button", "Go")])
        let after = page([control(1, "button", "Go"), control(2, "checkbox", "Apple", checked: true)],
                         url: "https://site-504.test/", from: "https://site-504.test/")
        XCTAssertEqual(StepEffect.summary(from: before, to: after),
                       "went to https://site-504.test/; changed Apple checked: false -> true; "
                       + "showed 2 controls: Go, Apple; removed 2 controls: Apple, Go")
    }

    /// A report made by hand has no keys and no document address: its controls are compared by their one
    /// namesake, and none is counted as shown or removed.
    func testAReportMadeByHandIsComparedByNamesakesOnly() {
        let before = page([control(nil, "textbox", "Search", value: nil), control(nil, "button", "Go")], from: nil)
        let after = page([control(nil, "textbox", "Search", value: "phones"), control(nil, "link", "Pixel 2")],
                         url: "https://site-503.test/search?q=phones", from: nil)
        XCTAssertEqual(StepEffect.summary(from: before, to: after),
                       "went to https://site-503.test/search?q=phones; changed Search value: empty -> phones")
        XCTAssertEqual(StepEffect.summary(from: before, to: before), "nothing visible changed")
    }

    /// Two frames may number their controls alike: a key two controls share matches neither.
    func testAKeyTwoFramesShareMatchesNeither() {
        func remember(_ checked: Bool) -> ObservedElement {
            var inFrame = control(1, "checkbox", "Remember me", checked: checked)
            inFrame.frame = "frame-1"
            return inFrame
        }
        let before = page([control(1, "checkbox", "Apple", checked: false), remember(false)])
        let after = page([control(1, "checkbox", "Apple", checked: false), remember(true)])
        XCTAssertEqual(StepEffect.summary(from: before, to: after), "changed Remember me checked: false -> true")
    }
}
