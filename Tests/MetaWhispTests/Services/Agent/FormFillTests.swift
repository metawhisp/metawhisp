import XCTest
@testable import MetaWhisp

/// ITER-076 stage 7 (№ 69, 54, 56, 59, 180) — a web form as one whole, by its
/// structure: what each field asks for, which fields a preview fills, and
/// which written value is kept — never one the user's details and words do
/// not hold.
final class FormFillTests: XCTestCase {

    private static func field(_ index: Int, _ name: String, role: String = "textbox", inputType: String? = "text",
                              autocomplete: String? = nil, required: Bool = false, group: Int? = 7,
                              value: String? = "", formMethod: String? = "post",
                              formAction: String? = "https://site-440.test/thanks", frame: String? = nil,
                              opens: Bool? = false) -> ObservedElement {
        var element = ObservedElement(index: index, role: role, name: name, text: "", href: nil, inputType: inputType,
                                      heading: "Request a demo", region: .main, inViewport: true, context: nil,
                                      formAction: formAction, formMethod: formMethod, formSubmitLabel: "Request a demo",
                                      options: nil, checked: nil, submits: false, value: value)
        element.autocomplete = autocomplete
        element.required = required
        element.group = group
        element.frame = frame
        element.opens = opens
        return element
    }

    private static func button(_ index: Int, _ name: String, group: Int? = 7) -> ObservedElement {
        var element = ObservedElement(index: index, role: "button", name: name, text: name, href: nil, inputType: nil,
                                      heading: "Request a demo", region: .main, inViewport: true, context: nil,
                                      formAction: "https://site-440.test/thanks", formMethod: "post",
                                      formSubmitLabel: name, options: nil, checked: nil, submits: true)
        element.group = group
        return element
    }

    private static func page(_ elements: [ObservedElement], truncated: Bool = false) -> ObservedPage {
        ObservedPage(url: "https://site-440.test/", title: "Site Four Forty", truncated: truncated, flags: .none,
                     elements: elements)
    }

    // MARK: - What a field asks for

    /// By its autocomplete — the field name among the qualifiers a page may
    /// put around it — then its input type; a text area asks for a message.
    /// Nothing else names a field: no word of its label is read.
    func testAFieldsKindIsWhatItsStructureSays() {
        let cases: [(String?, String?, String, FormFill.Kind?)] = [
            ("name", "text", "textbox", .name),
            ("section-demo billing given-name", "text", "textbox", .firstName),
            ("family-name", "text", "textbox", .lastName),
            ("work email", "text", "textbox", .email),
            (nil, "email", "textbox", .email),
            ("tel-national", "text", "textbox", .phone),
            (nil, "tel", "textbox", .phone),
            ("organization", "text", "textbox", .company),
            ("organization-title", "text", "textbox", .jobTitle),
            (nil, "url", "textbox", .website),
            ("shipping street-address", "text", "textbox", .streetAddress),
            ("address-line1", "text", "textbox", .streetAddress),
            ("address-level2", "text", "textbox", .city),
            ("postal-code", "text", "textbox", .postalCode),
            ("country-name", "text", "textbox", .country),
            (nil, nil, "textbox", .message),
            ("on", "text", "textbox", nil),
            ("off", "text", "textbox", nil),
            (nil, "text", "textbox", nil),
            (nil, "search", "searchbox", nil),
            (nil, "date", "textbox", nil),
        ]
        for (autocomplete, type, role, kind) in cases {
            let field = Self.field(1, "Field", role: role, inputType: type, autocomplete: autocomplete)
            XCTAssertEqual(FormFill.kind(of: field), kind, "\(autocomplete ?? "-") \(type ?? "-")")
        }
        XCTAssertEqual(FormFill.Kind.allCases.map(\.rawValue),
                       ["name", "first name", "last name", "email", "phone", "company", "job title", "website",
                        "street address", "city", "postal code", "country", "message"],
                       "the fixed words MetaChat's line names them by")
    }

    // MARK: - The form a preview fills

    /// The form the chosen field is in: every field of its group that takes
    /// typing — empty or holding what the site put there — in the page's
    /// order, in the chosen field's frame, when it is a form of the user's
    /// details (an e-mail, a phone or a name field by structure) and the page
    /// was read whole. However few of them are empty (review round 1, C1).
    func testTheFormIsEveryFieldOfTheChosenFieldsGroupThatTakesTyping() throws {
        let first = Self.field(0, "First name", autocomplete: "given-name", required: true)
        let email = Self.field(1, "Work email", inputType: "email", required: true)
        let filled = Self.field(2, "Referral", value: "Partner")
        let company = Self.field(3, "Company", autocomplete: "organization")
        let picker = Self.field(4, "Preferred day", opens: true)
        let message = Self.field(5, "How can we help?", inputType: nil)
        let search = Self.field(6, "Find", role: "searchbox", inputType: "search", group: nil, formMethod: nil,
                                formAction: nil)
        let send = Self.button(7, "Request a demo")
        let other = Self.field(8, "Newsletter email", inputType: "email", group: 9)
        let page = Self.page([first, email, filled, company, picker, message, search, send, other])
        let form = try XCTUnwrap(FormFill.fields(around: first, on: page))
        XCTAssertEqual(form.map(\.name), ["First name", "Work email", "Referral", "Company", "How can we help?"])
        XCTAssertEqual(FormFill.fields(around: message, on: page)?.map(\.name), form.map(\.name))
        XCTAssertEqual(FormFill.fields(around: filled, on: page)?.map(\.name), form.map(\.name),
                       "a field the site filled is the form's too")
        XCTAssertNil(FormFill.fields(around: search, on: page), "a field in no group")
        XCTAssertEqual(FormFill.fields(around: other, on: page)?.map(\.name), ["Newsletter email"],
                       "one field of the user's details alone is a form of them")
        XCTAssertNil(FormFill.fields(around: picker, on: page), "a field that takes no typing is not Jev's to type in")
        XCTAssertNil(FormFill.fields(around: first, on: Self.page([first, email, company], truncated: true)),
                     "a page not read whole")
    }

    /// Review round 1, C1: a demo form whose e-mail the site already filled,
    /// beside one empty field, is still a form of the user's details — never
    /// typed field by field, around the preview.
    func testAFormWithOneEmptyFieldBesideAnEmailTheSiteFilledIsStillOneWhole() throws {
        let name = Self.field(0, "Full name", autocomplete: "name")
        let email = Self.field(1, "Work email", inputType: "email", value: "alex@example.test")
        let send = Self.button(2, "Request a demo")
        let form = try XCTUnwrap(FormFill.fields(around: name, on: Self.page([name, email, send])))
        XCTAssertEqual(form.map(\.name), ["Full name", "Work email"])
    }

    /// Review round 1, C1: a name field by structure marks a form of the
    /// user's details as an e-mail or a phone field does — whatever the
    /// e-mail field beside it is drawn as.
    func testANameFieldByStructureMarksAFormOfTheUsersDetails() throws {
        let name = Self.field(0, "Full name", autocomplete: "name")
        let email = Self.field(1, "Email")
        let form = try XCTUnwrap(FormFill.fields(around: email, on: Self.page([name, email])))
        XCTAssertEqual(form.map(\.name), ["Full name", "Email"])
        let first = Self.field(0, "First name", autocomplete: "given-name")
        let last = Self.field(1, "Last name", autocomplete: "family-name")
        XCTAssertNotNil(FormFill.fields(around: last, on: Self.page([first, last])))
    }

    /// A search of two fields holds no e-mail or phone: it is no form of the
    /// user's details, and gets no preview.
    func testATwoFieldSearchIsNoFormOfTheUsersDetails() {
        let from = Self.field(0, "From", autocomplete: "address-level2", formMethod: "get",
                              formAction: "https://site-446.test/results")
        let to = Self.field(1, "To", formMethod: "get", formAction: "https://site-446.test/results")
        XCTAssertNil(FormFill.fields(around: from, on: Self.page([from, to])))
    }

    /// A form's fields are the chosen field's frame's: one of the same group
    /// key in another document is another form.
    func testAFieldInAnotherFrameIsNoPartOfTheForm() {
        let first = Self.field(0, "First name")
        let email = Self.field(1, "Email", inputType: "email")
        let framed = Self.field(2, "Company", frame: "frame-1")
        XCTAssertEqual(FormFill.fields(around: first, on: Self.page([first, email, framed]))?.map(\.name),
                       ["First name", "Email"])
        XCTAssertNil(FormFill.fields(around: framed, on: Self.page([first, email, framed])))
    }

    // MARK: - What a written value comes to

    private static let facts = FormFacts.collect(memories: [
        .init(content: "My name is Sam Example", toldMetaChat: true, createdAt: .now),
        .init(content: "I work at AcmeCorp as head of design", toldMetaChat: true, createdAt: .now),
    ], proEmail: "sam.pro@example.test")
    private static let goal = "Request a demo on site four forty for AcmeCorp"

    private func accepted(_ written: String?, _ kind: FormFill.Kind?) -> FormFill.Value? {
        FormFill.accept(written, kind: kind, goal: Self.goal, facts: Self.facts)
    }

    /// A personal fact the structure names — a name, a company, a role, a
    /// city — is kept only when a detail or the user's words hold it, read as
    /// a person reads them; its source is where it stands.
    func testAPersonalFactIsKeptOnlyWhenTheDetailsOrTheGoalHoldIt() {
        XCTAssertEqual(accepted("Sam Example", .name), FormFill.Value(text: "Sam Example", source: .memories))
        XCTAssertEqual(accepted("sam  example", .name), FormFill.Value(text: "sam  example", source: .memories),
                       "case and spaces aside")
        XCTAssertNil(accepted("Alex Other", .name), "no detail holds it: invented")
        XCTAssertEqual(accepted("AcmeCorp", .company), FormFill.Value(text: "AcmeCorp", source: .memories),
                       "a detail first")
        XCTAssertEqual(accepted("site four forty", .city), FormFill.Value(text: "site four forty", source: .request))
        XCTAssertNil(accepted("Head of Sales", .jobTitle))
        XCTAssertNil(accepted(nil, .name), "nothing written")
        XCTAssertNil(accepted("   ", .company))
        XCTAssertEqual(accepted("sam.pro@example.test", nil),
                       FormFill.Value(text: "sam.pro@example.test", source: .proAccount))
    }

    /// A field the structure does not name keeps what was written only where
    /// the details or the user's words hold it, as a personal fact is kept
    /// (review round 1, C6): its source is where it stands. A value neither
    /// holds is invented — a company no memory names — and left empty.
    func testAValueOfAFieldTheStructureDoesNotNameIsKeptOnlyWhenTheDetailsOrTheGoalHoldIt() {
        XCTAssertEqual(accepted("Sam Example", nil), FormFill.Value(text: "Sam Example", source: .memories))
        XCTAssertEqual(accepted("AcmeCorp", nil), FormFill.Value(text: "AcmeCorp", source: .memories))
        XCTAssertNil(accepted("Globex", nil), "a company no detail and no word of the user's holds: invented")
        XCTAssertNil(accepted("Demo for AcmeCorp", nil), "words neither holds as they stand")
        XCTAssertEqual(accepted("a demo", nil), FormFill.Value(text: "a demo", source: .request),
                       "the user's own words")
    }

    /// Review round 1 (Kimi P2-3): a detail holds a value only as whole
    /// words — "Al" is no name a memory of "I always work late" holds — in
    /// any script: a name inside a sentence of a language written without
    /// spaces is still one of its words.
    func testAValueIsHeldOnlyAsWholeWordsInAnyScript() {
        let facts = FormFacts.collect(memories: [
            .init(content: "I always work late", toldMetaChat: true, createdAt: .now),
            .init(content: "私の名前は山田です", toldMetaChat: true, createdAt: .now),
            .init(content: "Call me on +1 555 010 0199", toldMetaChat: true, createdAt: .now),
        ], proEmail: nil)
        let goal = "Request a demo"
        XCTAssertNil(FormFill.accept("Al", kind: .firstName, goal: goal, facts: facts), "inside another word")
        XCTAssertNil(FormFill.accept("ways", kind: nil, goal: goal, facts: facts))
        XCTAssertEqual(FormFill.accept("山田", kind: .lastName, goal: goal, facts: facts),
                       FormFill.Value(text: "山田", source: .memories))
        XCTAssertNil(FormFill.accept("名", kind: .name, goal: goal, facts: facts), "part of a word in that script too")
        XCTAssertEqual(FormFill.accept("work late", kind: nil, goal: goal, facts: facts),
                       FormFill.Value(text: "work late", source: .memories))
        XCTAssertNil(FormFill.accept("Call +1 555 010 019", kind: nil, goal: goal, facts: facts),
                     "a phone cut short is no detail's")
    }

    /// The message is written from the request: kept as written, never marked.
    /// Any e-mail, phone or web address in any written value must stand in
    /// the details or the goal — a placeholder address is invented.
    func testContactDataNoDetailHoldsIsNeverKept() {
        XCTAssertEqual(accepted("We would like a demo for our team.", .message),
                       FormFill.Value(text: "We would like a demo for our team.", source: .request))
        XCTAssertNil(accepted("Write to name@example.com for the demo.", .message))
        XCTAssertNil(accepted("Call +1 555 010 0199", nil))
        XCTAssertEqual(accepted("Write to sam.pro@example.test", .message),
                       FormFill.Value(text: "Write to sam.pro@example.test", source: .request))
    }

    /// The page after sending, as MetaChat shows it: without its query and
    /// fragment when either holds a value typed in the form — as a form sent
    /// by GET carries them — and as it is otherwise.
    func testTheLinkAfterSendingDropsAQueryThatHoldsATypedValue() {
        let typed = ["Sam Example", "sam@example.test"]
        XCTAssertEqual(FormFill.link("https://site-440.test/thanks?name=Sam+Example&ok=1", holding: typed),
                       "https://site-440.test/thanks")
        XCTAssertEqual(FormFill.link("https://site-440.test/thanks?mail=sam%40example.test#top", holding: typed),
                       "https://site-440.test/thanks")
        XCTAssertEqual(FormFill.link("https://site-440.test/thanks#from=SAM%20EXAMPLE", holding: typed),
                       "https://site-440.test/thanks")
        XCTAssertEqual(FormFill.link("https://site-440.test/thanks?submitted=1#done", holding: typed),
                       "https://site-440.test/thanks?submitted=1#done")
        XCTAssertEqual(FormFill.link("https://site-440.test/thanks", holding: []), "https://site-440.test/thanks")
    }

    /// Review round 2, R2-5: a value the form held is kept out of the whole
    /// address — its path too, from the first part that holds one, as it is
    /// written there or encoded — and a link that holds none is as it is.
    func testTheLinkKeepsNoValueTheFormHeldAnywhereInTheAddress() {
        let held = ["Sam Example", "sam@example.test"]
        XCTAssertEqual(FormFill.link("https://site-462.test/thanks/sam@example.test", holding: held),
                       "https://site-462.test/thanks")
        XCTAssertEqual(FormFill.link("https://site-462.test/thanks/sam%40example.test/done?ok=1#top", holding: held),
                       "https://site-462.test/thanks")
        XCTAssertEqual(FormFill.link("https://site-462.test/to/Sam%20Example/x", holding: held),
                       "https://site-462.test/to")
        XCTAssertEqual(FormFill.link("https://site-462.test/SAM@EXAMPLE.TEST", holding: held), "https://site-462.test/")
        XCTAssertEqual(FormFill.link("https://site-462.test/thanks/done?ok=1#top", holding: held),
                       "https://site-462.test/thanks/done?ok=1#top")
    }

    /// Review round 3, R3-1: a value that stands in the path twice is cut at
    /// the first part that holds any value — the first time it stands there
    /// — so neither is kept.
    func testTheLinkCutsThePathWhereAValueFirstStands() {
        let held = ["Sam Example", "sam@example.test"]
        XCTAssertEqual(FormFill.link("https://site-462.test/thanks/sam@example.test/copy/sam@example.test",
                                     holding: held), "https://site-462.test/thanks")
        XCTAssertEqual(FormFill.link("https://site-462.test/a/Sam%20Example/b/sam%40example.test/c", holding: held),
                       "https://site-462.test/a")
        XCTAssertEqual(FormFill.link("https://site-462.test/a/sam%40example.test/b/Sam%20Example", holding: held),
                       "https://site-462.test/a")
    }

    /// The digest tells texts apart to their last unit (the observer's own,
    /// checked against it in `ObserverFormsTests`).
    func testTheDigestTellsTextsApartToTheirLastUnit() {
        XCTAssertNotEqual(FormFill.digest("Sam"), FormFill.digest("Sam "))
        XCTAssertNotEqual(FormFill.digest("ab"), FormFill.digest("ba"))
        XCTAssertEqual(FormFill.digest("Sam").count, 16)
    }

    /// E-mail, phone and web address are the code's own: the details'
    /// first, an e-mail from the Pro account when no memory holds one; a
    /// street address is never typed in this version (decision 7.2).
    func testEmailPhoneAndWebsiteComeFromTheFactsByCode() {
        let facts = FormFacts.collect(memories: [
            .init(content: "Call me on +1 555 010 0199", toldMetaChat: true, createdAt: .now),
            .init(content: "Our site is acme.example.com", toldMetaChat: false, createdAt: .now),
        ], proEmail: "sam.pro@example.test")
        XCTAssertEqual(FormFill.fact(.email, in: facts), FormFill.Value(text: "sam.pro@example.test", source: .proAccount))
        XCTAssertEqual(FormFill.fact(.phone, in: facts), FormFill.Value(text: "+1 555 010 0199", source: .memories))
        XCTAssertEqual(FormFill.fact(.website, in: facts), FormFill.Value(text: "acme.example.com", source: .memories))
        XCTAssertNil(FormFill.fact(.phone, in: .none))
        XCTAssertNil(FormFill.fact(.name, in: facts), "not the code's: a writer's")
        XCTAssertTrue(FormFill.Kind.streetAddress.neverTyped)
        XCTAssertFalse(FormFill.Kind.city.neverTyped)
    }
}
