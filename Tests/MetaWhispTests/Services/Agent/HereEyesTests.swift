import XCTest
@testable import MetaWhisp

/// ITER-076 stage 11 — the eyes on the window the user looks at, read through the Accessibility API: which fields
/// they see, by which words each is named, which they leave alone, where they look, and what a combobox's options
/// are. The trees here are shaped as WebKit showed a profile form on 2026-10-07 (the stage's probe).
final class HereEyesTests: XCTestCase {

    private func text(_ words: String) -> HereNode { HereNode(role: "AXStaticText", value: words) }

    private func field(_ role: String = "AXTextField", title: String? = nil, description: String? = nil,
                       titleElement: String? = nil, value: String? = "", subrole: String? = nil,
                       enabled: Bool = true, children: [HereNode] = []) -> HereNode {
        HereNode(role: role, subrole: subrole, title: title, description: description, value: value,
                 titleElement: titleElement, enabled: enabled, children: children)
    }

    private func group(_ children: [HereNode]) -> HereNode { HereNode(role: "AXGroup", value: "", children: children) }

    /// A browser window: its own toolbar with an address field, and the page's web area holding `children`.
    private func window(_ children: [HereNode], page: String = "Edit your profile") -> HereNode {
        HereNode(role: "AXWindow", title: "Safari", children: [
            HereNode(role: "AXToolbar", children: [field(title: "Address", value: "")]),
            HereNode(role: "AXWebArea", description: page, children: children),
        ])
    }

    private func labels(_ children: [HereNode]) -> [String] {
        HereEyes.look(at: window(children)).fields.map(\.label)
    }

    // MARK: - The words that name a field

    /// A field's title names it first — its `<label>` as WebKit reads it — then its description (`aria-label`),
    /// then the words of the element that titles it.
    func testAFieldIsNamedByItsTitleThenItsDescriptionThenTheElementThatTitlesIt() {
        XCTAssertEqual(labels([field(title: "First Name", description: "Name", titleElement: "Given")]), ["First Name"])
        XCTAssertEqual(labels([field(title: "", description: "Twitter", titleElement: "Social")]), ["Twitter"])
        XCTAssertEqual(labels([field("AXTextArea", titleElement: "Bio")]), ["Bio"])
    }

    /// Else the nearest text before it in its parent: an unlabeled custom select such as Country.
    func testElseTheNearestTextBeforeItInItsParent() {
        XCTAssertEqual(labels([group([text("Country"), field("AXComboBox")])]), ["Country"])
    }

    /// A field alone in its wrapper takes the text before the wrapper — as WebKit showed an unlabeled combobox in
    /// its `div` (the stage's probe, 2026-10-07).
    func testAFieldAloneInItsWrapperIsNamedByTheTextBeforeTheWrapper() {
        XCTAssertEqual(labels([group([text("Job Title"), field(title: "Job Title"), text("Country"),
                                      group([field("AXComboBox")])])]), ["Job Title", "Country"])
    }

    /// An image between the text and its field is looked past.
    func testAnImageBetweenTheTextAndTheFieldIsLookedPast() {
        XCTAssertEqual(labels([group([text("Country"), HereNode(role: "AXImage"), field("AXComboBox")])]), ["Country"])
    }

    /// A control between a text and a field means the text is the control's, not the field's: the field has no
    /// name, and a field with no name is neither asked about nor named back — it is left alone.
    func testATextBeforeAnotherControlNamesNoField() {
        XCTAssertEqual(labels([group([text("Twitter"), field(title: "Twitter"), field()])]), ["Twitter"])
        XCTAssertEqual(labels([group([text("Agree"), HereNode(role: "AXCheckBox", title: ""), field()])]), [])
        XCTAssertEqual(labels([text("Country"), group([field(title: "Job Title"), field()])]), ["Job Title"],
                       "nor the text before the group: the control nearer is the field's neighbour")
    }

    /// A field nothing else names is named by its placeholder — many forms write their fields' names only there
    /// (2026-10-07) — but a text before it names it first.
    func testElseItsPlaceholderNamesIt() {
        XCTAssertEqual(labels([group([HereNode(role: "AXTextField", value: "", placeholder: "Your e-mail")])]),
                       ["Your e-mail"])
        XCTAssertEqual(labels([group([text("E-mail"), HereNode(role: "AXTextField", value: "", placeholder: "you@")])]),
                       ["E-mail"])
        XCTAssertEqual(labels([group([text("Agree"), HereNode(role: "AXCheckBox", title: ""),
                                      HereNode(role: "AXTextField", value: "", placeholder: "Phone")])]), ["Phone"],
                       "a control before it names nothing: its placeholder still does")
    }

    /// A field named by nothing — no title, description, titling element, text before it or placeholder — is left
    /// alone.
    func testAFieldNamedByNothingIsLeftAlone() {
        XCTAssertEqual(labels([group([field(title: nil, description: nil)])]), [])
        XCTAssertEqual(labels([HereNode(role: "AXHeading", children: [text("Edit your profile")]), group([field()])]), [],
                       "a heading is no field's name")
    }

    /// A name is read as a person reads it: spaces around it dropped.
    func testANameIsTrimmed() {
        XCTAssertEqual(labels([field(title: "  First Name \n")]), ["First Name"])
    }

    // MARK: - What the eyes leave alone

    func testASecureFieldIsLeftAlone() {
        XCTAssertEqual(labels([field(title: "Password", subrole: "AXSecureTextField"), field(title: "Nickname")]),
                       ["Nickname"])
    }

    func testAFieldThatHoldsAValueIsLeftAlone() {
        XCTAssertEqual(labels([field(title: "Nickname", value: "Already here"), field(title: "First Name", value: ""),
                               field(title: "Last Name", value: nil)]), ["First Name", "Last Name"])
    }

    func testADisabledFieldIsLeftAlone() {
        XCTAssertEqual(labels([field(title: "Disabled", enabled: false), field(title: "First Name")]), ["First Name"])
    }

    /// Only the page's fields: the browser's own address field, outside the web area, is never one.
    func testOnlyTheWebAreasFieldsAreSeen() {
        let look = HereEyes.look(at: window([field(title: "First Name")]))
        XCTAssertEqual(look.fields.map(\.label), ["First Name"])
    }

    /// A window with no web area — an app's own form, a chat's composer, a browser before it shows its page —
    /// offers no field (2026-10-13: read whole, Chrome's toolbar pop-ups were taken for the page's fields).
    func testAWindowWithNoWebAreaOffersNoField() {
        let native = HereNode(role: "AXWindow", title: "Contact", children: [group([field(title: "Name")])])
        XCTAssertEqual(HereEyes.look(at: native).fields.map(\.label), [])
        XCTAssertEqual(HereEyes.look(at: native).title, "Contact")
    }

    /// Text fields, text areas, comboboxes and pop-up buttons are fields; boxes, radios, buttons are not.
    func testTheFourRolesAreFieldsAndNothingElse() {
        let seen = HereEyes.look(at: window([
            field(title: "Text"), field("AXTextArea", title: "Area"), field("AXComboBox", title: "Combo"),
            field("AXPopUpButton", title: "Popup"), HereNode(role: "AXCheckBox", title: "Box", value: "0"),
            HereNode(role: "AXRadioButton", title: "Radio", value: "0"), HereNode(role: "AXButton", title: "Save"),
            HereNode(role: "AXSlider", title: "Volume", value: ""),
        ])).fields
        XCTAssertEqual(seen.map(\.label), ["Text", "Area", "Combo", "Popup"])
        XCTAssertEqual(seen.map(\.role), ["AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton"])
    }

    // MARK: - The page as the field's writer reads it

    /// The page's title — its web area's, as WebKit names it — and its words: every text of the page in its order,
    /// none from inside a field (a combobox holds its value as a text), at most 6,000 characters.
    func testThePageIsItsTitleAndItsWords() {
        let look = HereEyes.look(at: window([
            text("First Name"), field(title: "First Name"),
            text("Company"), field("AXComboBox", title: "Company", children: [text("typed by the user")]),
        ]))
        XCTAssertEqual(look.title, "Edit your profile")
        XCTAssertEqual(look.text, "First Name\nCompany")
        let long = HereEyes.look(at: window([text(String(repeating: "a", count: 7_000)), field(title: "Name")]))
        XCTAssertEqual(long.text.count, HereEyes.maxText)
        XCTAssertEqual(HereEyes.maxText, 6_000)
    }

    // MARK: - The window

    /// The window of the app the hands work in: its focused window, else its main window — a window on another
    /// full-screen Space is not in its `kAXWindows` list but is its main one (measured 2026-10-07) — else the
    /// frontmost of its windows: an app whose panel had closed answered neither, its form window listed
    /// (measured 2026-10-07, the test runner after the disclosure's tests).
    func testTheWindowIsTheFocusedOneElseTheMainOneElseTheFrontmost() {
        XCTAssertEqual(HereEyes.window(focused: "focused", main: "main", windows: ["front"]), "focused")
        XCTAssertEqual(HereEyes.window(focused: nil, main: "main", windows: ["front"]), "main")
        XCTAssertEqual(HereEyes.window(focused: nil, main: nil, windows: ["front", "back"]), "front")
        XCTAssertNil(HereEyes.window(focused: String?.none, main: nil, windows: []))
    }

    // MARK: - A combobox's options

    /// An option is what a list shows that can be pressed and whose title is exactly the text — as WebKit shows a
    /// `role=option` (a pressable text titled its words, in a list).
    func testAnOptionIsAPressableEntryOfAListTitledExactlyTheText() {
        let list = HereNode(role: "AXList", children: [
            HereNode(role: "AXStaticText", title: "Germany", value: "Germany", pressable: true),
            HereNode(role: "AXStaticText", title: "Georgia", value: "Georgia", pressable: true),
            HereNode(role: "AXStaticText", title: "Germany ", value: "Germany", pressable: true),
        ])
        let found = HereEyes.options(titled: "Germany", in: window([field("AXComboBox", title: "Country"), list]))
        XCTAssertEqual(found.count, 2, "the same words, trimmed")
        XCTAssertTrue(HereEyes.options(titled: "Ger", in: window([list])).isEmpty, "exactly the text")
    }

    /// A button, a link, a box, a field, or anything outside a list is never an option — and nothing inside a
    /// field: a combobox holds its own value as a text.
    func testNoControlAndNothingOutsideAListIsAnOption() {
        let tree = window([
            HereNode(role: "AXList", children: [HereNode(role: "AXButton", title: "Germany", pressable: true),
                                                HereNode(role: "AXLink", title: "Germany", pressable: true),
                                                HereNode(role: "AXCheckBox", title: "Germany", pressable: true),
                                                HereNode(role: "AXStaticText", title: "Germany", pressable: false)]),
            HereNode(role: "AXStaticText", title: "Germany", value: "Germany", pressable: true),
            field("AXComboBox", title: "Country", value: "Germany",
                  children: [HereNode(role: "AXStaticText", title: "Germany", value: "Germany", pressable: true)]),
            HereNode(role: "AXMenu", children: [HereNode(role: "AXMenuItem", title: "Germany", pressable: true)]),
        ])
        XCTAssertEqual(HereEyes.options(titled: "Germany", in: tree).map(\.role), ["AXMenuItem"])
    }
}
